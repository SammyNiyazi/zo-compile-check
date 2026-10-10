import AVFoundation
import SwiftUI
import UIKit

/// Proof 47 "Progress photo" and "Keep or retake": always dark, the last photo in
/// the same pose as a ghost to line up with, Front / Side / Back, a 3 s timer, the
/// library and the flip. Nothing is written to the Photos library.
enum ProgressPhotoPose: String, Codable, CaseIterable, Sendable {
    case front, side, back

    var title: String {
        switch self {
        case .front: "Front"
        case .side: "Side"
        case .back: "Back"
        }
    }
}

/// Pose per saved photo, beside the photo records (whose stored shape stays unchanged).
struct ProgressPhotoPoseStore {
    static let key = "01.progressPhoto.poses"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func poses() -> [UUID: ProgressPhotoPose] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([UUID: ProgressPhotoPose].self, from: data) else { return [:] }
        return stored
    }

    func set(_ pose: ProgressPhotoPose, for id: UUID) {
        var all = poses()
        all[id] = pose
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    /// The newest earlier photo in this pose; photos from before poses existed count as front.
    func ghost(for pose: ProgressPhotoPose, in records: [ProgressPhotoRecord]) -> ProgressPhotoRecord? {
        let all = poses()
        return records.sorted { $0.createdAt > $1.createdAt }.first { (all[$0.id] ?? .front) == pose }
    }
}

@MainActor
@Observable
final class ProgressCameraModel: NSObject {
    enum State: Equatable { case starting, running, unavailable }

    let session = AVCaptureSession()
    private(set) var state: State = .starting
    private(set) var position: AVCaptureDevice.Position = .back
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var continuation: CheckedContinuation<Data?, Never>?
    private let queue = DispatchQueue(label: "01.progressCamera")

    func start() async {
        guard await FoodCameraAccess.request() else { state = .unavailable; return }
        guard configure(position) else { state = .unavailable; return }
        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { session.startRunning(); done.resume() }
        }
        state = .running
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    func flip() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        if configure(next) { position = next }
    }

    @discardableResult
    private func configure(_ position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            return false
        }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        return true
    }

    func capture() async -> Data? {
        guard state == .running, continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    fileprivate func finish(_ data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

extension ProgressCameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in self.finish(data) }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

struct ProgressCameraView: View {
    let ghost: (ProgressPhotoPose) -> (image: UIImage, date: Date)?
    let onUse: (Data, ProgressPhotoPose) -> Void
    let onLibrary: () -> Void
    let onCancel: () -> Void

    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = ProgressCameraModel()
    @State private var pose: ProgressPhotoPose = .front
    @State private var usesTimer = true
    @State private var countdown: Int?
    @State private var captured: (data: Data, image: UIImage)?
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let captured {
                keepOrRetake(captured.image)
            } else {
                capture
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: Capture

    private var capture: some View {
        VStack(spacing: 0) {
            topBar(localization.string("Progress photo"))
            GeometryReader { proxy in
                ZStack {
                    if camera.state == .unavailable {
                        VStack(spacing: ZOSpace.m) {
                            Image(systemName: "camera").zoIcon(ZOIcon.feature)
                            Text("The camera isn't available. You can pick a photo from your library instead.")
                                .zoText(.body).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .padding(ZOSpace.x3)
                    } else {
                        CameraPreview(session: camera.session)
                        if let ghost = ghost(pose) {
                            Image(uiImage: ghost.image).resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .opacity(0.35)
                                .scaleEffect(x: camera.position == .front ? -1 : 1, y: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            VStack {
                                Spacer()
                                Label(localization.format("Line up with %1$@", .text(ghost.date.formatted(.dateTime.day().month(.wide)))),
                                      systemImage: "square.split.2x1")
                                    .labelStyle(ZOIconLabelStyle())
                                    .zoText(.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, ZOSpace.m)
                                    .frame(minHeight: 32)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(.bottom, ZOSpace.l)
                            }
                        }
                        HStack(spacing: proxy.size.width / 3) {
                            Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
                            Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        if let countdown {
                            Text(verbatim: "\(countdown)")
                                .zoText(.timerHero)
                                .foregroundStyle(.white)
                                .contentTransition(.numericText(value: Double(countdown)))
                                .accessibilityLabel(Text(localization.format("Photo in %1$lld", .integer(countdown))))
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
            HStack(spacing: ZOSpace.xl) {
                ForEach(ProgressPhotoPose.allCases, id: \.self) { option in
                    Button { pose = option } label: {
                        Text(localization.string(option.title).uppercased())
                            .zoText(.mini)
                            .foregroundStyle(option == pose ? .white : .white.opacity(0.55))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == pose ? .isSelected : [])
                }
            }
            .padding(.top, ZOSpace.s)
            HStack {
                round("photo.on.rectangle", label: "Choose from library", action: onLibrary)
                Spacer()
                Button(action: shoot) {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        .overlay(Circle().fill(.white).padding(6))
                }
                .buttonStyle(.plain)
                .disabled(camera.state != .running || isCapturing)
                .accessibilityLabel(Text(localization.string("Take the photo")))
                Spacer()
                round("arrow.triangle.2.circlepath.camera", label: "Switch camera") { camera.flip() }
                    .disabled(camera.state != .running || isCapturing)
            }
            .padding(.horizontal, ZOSpace.xxl)
            .padding(.vertical, ZOSpace.l)
        }
    }

    private func topBar(_ title: String) -> some View {
        ZStack {
            Text(title).zoText(.section).foregroundStyle(.white).accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: onCancel) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                    .buttonStyle(ZOButtonStyle(.round))
                    .accessibilityLabel(Text(localization.string("Close")))
                Spacer()
                if captured == nil {
                    Button { usesTimer.toggle() } label: {
                        Label(usesTimer ? "3 s" : localization.string("Off"), systemImage: "timer")
                            .labelStyle(ZOIconLabelStyle())
                            .zoText(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, ZOSpace.m)
                            .frame(minHeight: 36)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(localization.string(usesTimer ? "Timer, 3 seconds" : "Timer off")))
                }
            }
        }
        .padding(.horizontal, ZOSpace.l)
        .padding(.vertical, ZOSpace.s)
    }

    private func round(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).zoIcon(ZOIcon.row).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(localization.string(label)))
    }

    private func shoot() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            if usesTimer {
                for second in stride(from: 3, through: 1, by: -1) {
                    withAnimation(reduceMotion ? nil : .default) { countdown = second }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    try? await Task.sleep(for: .seconds(1))
                }
                countdown = nil
            }
            let data = await camera.capture()
            isCapturing = false
            guard let data, let image = UIImage(data: data) else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            captured = (data, image)
        }
    }

    // MARK: Keep or retake

    private func keepOrRetake(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            topBar(localization.format("%1$@ · %2$@", .text(localization.string(pose.title)),
                                       .text(Date.now.formatted(.dateTime.day().month(.wide)))))
            Image(uiImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel(Text(localization.string("Your new progress photo")))
            Text("Saved only in 01, not in your Photos library.")
                .zoText(.caption).foregroundStyle(.white.opacity(0.75))
                .padding(.top, ZOSpace.m)
            HStack(spacing: ZOSpace.m) {
                Button(localization.string("Retake")) { captured = nil }
                    .buttonStyle(ZOButtonStyle(.secondary))
                Button(localization.string("Use photo")) {
                    guard let captured else { return }
                    onUse(captured.data, pose)
                }
                .buttonStyle(ZOButtonStyle(.ink))
                .accessibilityIdentifier("progressCamera.use")
            }
            .padding(ZOSpace.l)
        }
    }
}
