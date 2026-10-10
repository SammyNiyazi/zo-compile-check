import AVFoundation
import SwiftUI
import UIKit

/// Proof 33 "Add a friend: the week code". Your number drawn as a training week,
/// and 01's own scanner for a friend's. No QR, no photo on the card.
struct WeekCodeView: View {
    let number: Int
    var showsDays = true
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        let bits = WeekCode.segments(for: number)
        VStack(spacing: 6) {
            Canvas { context, size in
                let k = size.width / WeekCode.totalWidth
                for index in 0 ..< WeekCode.segmentCount {
                    let group = Double(index / 5), position = Double(index % 5)
                    let x = (group * (WeekCode.groupWidth + WeekCode.day) + position * (WeekCode.segment + WeekCode.gap)) * k
                    let rect = CGRect(x: x, y: 0, width: WeekCode.segment * k, height: size.height)
                    // Faint segments sit near the middle level, so the camera reads three clear tones.
                    context.fill(Path(roundedRect: rect, cornerRadius: 3 * k),
                                 with: .color(bits[index] == 1 ? theme.textPrimary : theme.textPrimary.opacity(0.4)))
                }
            }
            .aspectRatio(WeekCode.totalWidth / WeekCode.height, contentMode: .fit)
            if showsDays {
                GeometryReader { proxy in
                    let k = proxy.size.width / WeekCode.totalWidth
                    ForEach(0 ..< 7, id: \.self) { day in
                        Text(verbatim: dayLetter(day)).zoText(.caption).foregroundStyle(theme.textSecondary)
                            .position(x: (Double(day) * (WeekCode.groupWidth + WeekCode.day) + WeekCode.groupWidth / 2) * k,
                                      y: proxy.size.height / 2)
                    }
                }
                .frame(height: 18)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: localization.format("Week code for member number %1$@",
                                                               .text(ClubPerson.memberNumber(number)))))
    }

    private func dayLetter(_ index: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = localization.locale
        return calendar.veryShortStandaloneWeekdaySymbols[(index + 1) % 7]
    }
}

/// Reads week codes from the back camera. Lower exposure keeps the three tones
/// apart on a bright screen (Sammy's iPhone test, 4 Oct: about 0.2 s).
final class WeekCodeScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.the01.weekcode")
    private var found = false
    var onNumber: (@MainActor (Int) -> Void)?

    func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            if session.inputs.isEmpty { configure() }
            found = false
            session.startRunning()
        }
    }

    func stop() { queue.async { [self] in session.stopRunning() } }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.setExposureTargetBias(max(device.minExposureTargetBias, -1.0), completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !found, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        // The sensor is landscape: a code held level in a portrait frame runs along the buffer's
        // height. Rows of the scan image are buffer columns from the middle of the view.
        let first = width * 3 / 10, last = width * 7 / 10, step = 3
        var gray: [UInt8] = []
        gray.reserveCapacity(((last - first) / step + 1) * height)
        var rows = 0
        for x in Swift.stride(from: first, to: last, by: step) {
            for y in 0 ..< height { gray.append(luma[(height - 1 - y) * stride + x]) }
            rows += 1
        }
        guard let number = WeekCode.decode(gray: gray, width: height, height: rows) else { return }
        found = true
        Task { @MainActor [onNumber] in onNumber?(number) }
    }
}

private struct WeekCodeCameraView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// "Add a friend": your week code to show, and a scanner for theirs. A found
/// number opens their card, with Follow.
@MainActor
struct ClubAddFriendView: View {
    let club: ClubStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var scanning = false
    @State private var scanner = WeekCodeScanner()
    @State private var found: ClubPerson?
    @State private var message: String?
    @State private var cameraDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                if scanning {
                    ZStack {
                        WeekCodeCameraView(session: scanner.session)
                        RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.9), lineWidth: 2)
                            .frame(height: 90).padding(.horizontal, ZOSpace.l)
                    }
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text("Hold your iPhone level over your friend's week code.")
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                } else if let me = club.me, let number = me.person.memberNo {
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        Text(verbatim: me.person.displayName).zoThemeText(.title)
                        Text(verbatim: "No. " + ClubPerson.memberNumber(number)).zoText(.caption).foregroundStyle(theme.textSecondary)
                        WeekCodeView(number: number)
                    }
                    .padding(ZOSpace.cardPadding)
                    .zoThemeCardSurface()
                    Text("Let a friend scan this at the gym. It only works in 01, and only finds your card.")
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                }
                if let message { Text(verbatim: localization.string(message)).zoText(.caption).foregroundStyle(theme.textSecondary) }
                if cameraDenied {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(ZOButtonStyle(.quiet))
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .navigationTitle(Text("Add a friend"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(scanning ? "Stop scanning" : "Scan a friend's code") { toggleScan() }
                .buttonStyle(ZOButtonStyle(scanning ? .secondary : .primary))
                .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
        .sheet(item: $found) { person in
            NavigationStack { ClubMemberView(club: club, accountID: person.accountID) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .onDisappear { scanner.stop() }
    }

    private func toggleScan() {
        if scanning { scanner.stop(); scanning = false; return }
        message = nil
        Task {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            cameraDenied = !granted
            guard granted else { message = "01 needs the camera to read a week code."; return }
            scanner.onNumber = { number in handle(number) }
            scanner.start()
            scanning = true
        }
    }

    private func handle(_ number: Int) {
        scanner.stop()
        scanning = false
        Task {
            if number == club.me?.person.memberNo { message = "That's your own code."; return }
            if let person = await club.member(number: number) { found = person }
            else { message = "No member with that code. It may be someone who left the Club." }
        }
    }
}
