import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

/// Actual hosted native timer probes, opt-in and deliberately capable of failing.
/// An app-host pass does not prove archived Live Activity or physical AOD fidelity.
@MainActor
final class WorkoutNativeRestLineExperimentTests: XCTestCase {
    func testConfirmedPayloadProvidesOriginalTargetAndAuxiliaryDatesStayPrivate() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let end = start.addingTimeInterval(90.25)
        let original = state(end: end, duration: 90.25)
        let interval = try XCTUnwrap(original.restCountdownInterval)
        let inner = try XCTUnwrap(WorkoutNativeRestMaskCoordinates.inner(
            interval: interval, width: 200, inset: 1.5))
        XCTAssertEqual(interval.lowerBound, start)
        XCTAssertEqual(inner.interval.lowerBound, start)
        XCTAssertEqual(inner.interval.upperBound.timeIntervalSinceReferenceDate,
                       end.timeIntervalSinceReferenceDate - 1.35375, accuracy: 0.000001)
        XCTAssertEqual(inner.width, 197)
        XCTAssertEqual(inner.height, 3)
        XCTAssertEqual(original.restEndsAt, end)
        XCTAssertEqual(original.restTotalSeconds, 90.25)
        XCTAssertEqual(original.restCountdownInterval, interval)
    }

    func testUnknownAndUnrepresentableDrawingInputsNeverInventIntervals() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let interval = start ... start.addingTimeInterval(90)
        XCTAssertNil(WorkoutNativeRestMaskCoordinates.valid(nil))
        XCTAssertNil(state(end: start, duration: nil).restCountdownInterval)
        XCTAssertNil(state(end: start, duration: 0).restCountdownInterval)
        XCTAssertNil(state(end: start, duration: 90, phase: .paused).restCountdownInterval)
        XCTAssertNil(WorkoutNativeRestMaskCoordinates.valid(start ... start))
        let widths: [CGFloat] = [0, -1, 3, .infinity, .nan]
        for width in widths {
            XCTAssertNil(WorkoutNativeRestMaskCoordinates.inner(
                interval: interval, width: width, inset: 1.5))
        }
        let smallest = start ... start.nextRepresentableDate
        XCTAssertNil(WorkoutNativeRestMaskCoordinates.inner(
            interval: smallest, width: .greatestFiniteMagnitude, inset: 1.5))
    }

    func testHostedExtractionMovesWithNativeControlWithoutReplacingRoot() async throws {
        try optIn()
        let now = Date.now
        let interval = now.addingTimeInterval(-4) ... now.addingTimeInterval(12)
        let width: CGFloat = 200
        let host = try HostedProbe(view: VStack(spacing: 16) {
            plainTimer(interval: interval).frame(width: width, height: 6)
            WorkoutNativeRestLineExperiment(interval: interval, accent: .white,
                track: .black, normalInsetEdge: nil, dimmed: false)
                .frame(width: width, height: 6)
        }.padding(12).background(.black), size: CGSize(width: 224, height: 52))
        defer { host.close() }
        let identity = ObjectIdentifier(host.controller)
        await observation(after: 0.15)
        let first = try host.capture()
        await observation(after: 4)
        let second = try host.capture()
        XCTAssertEqual(ObjectIdentifier(host.controller), identity)
        XCTAssertTrue(host.window.rootViewController === host.controller)
        for (name, frame) in [("first", first), ("later", second)] {
            let native = try frame.whiteBounds(x: 12, y: 15, width: width)
            let extracted = try frame.whiteBounds(x: 12, y: 37, width: width)
            XCTAssertEqual(extracted.right, native.right, accuracy: 1 / frame.scale,
                           "Extracted timer diverged from visible native control.")
            try frame.assertDark(x: native.right + 2, y: 37,
                through: 12 + width - 1, reason: "Track residue is not isolated fill.")
            // Host height is insufficient proof: measure actual center-column pixels.
            try frame.assertWhite(x: (12 + extracted.right) / 2, y: 34.5)
            try frame.assertWhite(x: (12 + extracted.right) / 2, y: 39.5)
            attach(frame, name: name + "-unchanged-native-timer", interval: interval)
        }
        let firstRight = try first.whiteBounds(x: 12, y: 37, width: width).right
        let secondRight = try second.whiteBounds(x: 12, y: 37, width: width).right
        XCTAssertGreaterThan(firstRight - secondRight, 25,
                             "Mask did not advance while the unchanged native timer drained.")
    }

    func testHostedSixPointMovingCapsMatchExplicitRadiusThreeReference() async throws {
        try optIn()
        let now = Date.now
        let interval = now.addingTimeInterval(-30_000) ... now.addingTimeInterval(30_000)
        let host = try HostedProbe(view: VStack(alignment: .leading, spacing: 16) {
            WorkoutNativeRestLineExperiment(interval: interval, accent: .white,
                track: .black, normalInsetEdge: nil, dimmed: false)
                .frame(width: 200, height: 6)
            // Static geometry oracle only, never a progress driver or accepted fallback.
            RoundedRectangle(cornerRadius: 3, style: .circular).fill(.white)
                .frame(width: 100, height: 6)
                .frame(width: 200, height: 6, alignment: .leading)
        }.padding(12).background(.black), size: CGSize(width: 224, height: 52))
        defer { host.close() }
        await observation(after: 0.15)
        let frame = try host.capture()
        let largestObservedDrift = max(abs(frame.before.timeIntervalSince(now)),
                                       abs(frame.after.timeIntervalSince(now))) * 200 / 60_000
        XCTAssertLessThan(largestObservedDrift, Double(1 / (8 * frame.scale)),
                          "Observation no longer supports this fixed geometric oracle.")
        // Compare actual antialiased fixed AND moving caps and top/bottom pixels.
        // The full-host clip cannot independently round the moving end.
        for x in [CGFloat(12), 12.5, 13, 14, 15, 16, 17, 108, 109, 110, 111, 111.5, 112] {
            for y in [CGFloat(12), 12.5, 13, 14, 15, 16, 17, 17.5] {
                try frame.assertColor(try frame.pixel(x: x, y: y + 22),
                                      x: x, y: y, accuracy: 0.05)
            }
        }
        attach(frame, name: "six-point-radius-three-native-versus-static-oracle", interval: interval)
    }

    func testHostedAODHasTransparentInteriorAndMeasuredInset() async throws {
        try optIn()
        let now = Date.now
        let interval = now.addingTimeInterval(-300) ... now.addingTimeInterval(300)
        let host = try HostedProbe(view: ZStack(alignment: .topLeading) {
            ProbeChecker()
            WorkoutNativeRestLineExperiment(interval: interval, accent: .white,
                track: .clear, normalInsetEdge: nil, dimmed: true)
                .frame(width: 200, height: 6).offset(x: 12, y: 12)
        }, size: CGSize(width: 224, height: 30))
        defer { host.close() }
        await observation(after: 0.15)
        let frame = try host.capture()
        // Reference pattern comes from actual host pixels outside the line at same x.
        // This catches painted interiors and subtraction escaping its isolated group.
        let x: CGFloat = 52
        let reference = try frame.pixel(x: x, y: 24)
        for y in [CGFloat(14), 15, 16] {
            try frame.assertColor(reference, x: x, y: y, accuracy: 0.03)
        }
        try frame.assertWhite(x: x, y: 12.5)
        try frame.assertWhite(x: x, y: 17.5)
        // Exact elapsed observation bracket, not an assumed static half-filled image.
        let low = 12 + 200 * CGFloat(interval.upperBound.timeIntervalSince(frame.after) / 600)
        let high = 12 + 200 * CGFloat(interval.upperBound.timeIntervalSince(frame.before) / 600)
        let endpoint = (low + high) / 2
        try frame.assertWhite(x: endpoint - 0.5, y: 15)
        try frame.assertColor(try frame.pixel(x: endpoint - 2, y: 24),
                              x: endpoint - 2, y: 15, accuracy: 0.03)
        try frame.assertColor(try frame.pixel(x: endpoint + 2, y: 24),
                              x: endpoint + 2, y: 15, accuracy: 0.03)
        attach(frame, name: "injected-dimmed-outline-transparency", interval: interval)
    }

    func testHostedShortFragmentUnknownAndExpiryDoNotLeakMasks() async throws {
        try optIn()
        let now = Date.now
        let short = now.addingTimeInterval(-108) ... now.addingTimeInterval(12)
        let expiring = now.addingTimeInterval(-4) ... now.addingTimeInterval(3)
        let host = try HostedProbe(view: VStack(alignment: .leading, spacing: 16) {
            WorkoutNativeRestLineExperiment(interval: short, accent: .white,
                track: .black, normalInsetEdge: nil, dimmed: true)
                .frame(width: 20, height: 6)
            WorkoutNativeRestLineExperiment(interval: expiring, accent: .white,
                track: .black, normalInsetEdge: nil, dimmed: true)
                .frame(width: 200, height: 6)
            WorkoutNativeRestLineExperiment(interval: nil, accent: .white,
                track: .white, normalInsetEdge: nil, dimmed: true)
        }.frame(width: 200, height: 50, alignment: .topLeading)
            .padding(12).background(.black),
            size: CGSize(width: 224, height: 74))
        defer { host.close() }
        await observation(after: 0.15)
        let nearZero = try host.capture()
        let bounds = try nearZero.whiteBounds(x: 12, y: 15, width: 20)
        XCTAssertLessThanOrEqual(bounds.right - 12, 3)
        try nearZero.assertDark(x: 16, y: 15, through: 31,
                               reason: "Short fragment has phantom full-track alpha.")
        await observation(after: 4)
        let expired = try host.capture()
        for y in [CGFloat(34.5), 37, 39.5, 59] {
            try expired.assertDark(x: 12, y: y, through: 211,
                                   reason: "Expired/unknown timer mask must be absent.")
        }
        attach(nearZero, name: "short-fragment", interval: short)
        attach(expired, name: "expiry-and-unknown", interval: expiring)
    }

    private func optIn() throws {
        guard ProcessInfo.processInfo.environment["ZERO_ONE_WIDGET_REST_MASK_PROBES"] == "1" else {
            throw XCTSkip("Native rest-mask experiment requires explicit opt-in.")
        }
    }

    /// One-shot observation scheduling only, not a view/progress driver or poll loop.
    private func observation(after seconds: TimeInterval) async {
        let ready = expectation(description: "One native-host observation")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: seconds + 3)
    }

    private func plainTimer(interval: ClosedRange<Date>) -> some View {
        ZStack {
            Color.black
            ProgressView(timerInterval: interval, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear).tint(.white)
        }
        .accessibilityHidden(true)
    }

    private func state(end: Date, duration: TimeInterval?,
                       phase: WorkoutActivityAttributes.ContentState.Phase = .rest)
        -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(exerciseName: "Synthetic probe", currentSet: 1,
            plannedSetsForExercise: 3, completedSets: 1, totalSets: 3,
            phase: phase, restEndsAt: end, pausedRestSeconds: nil, restTotalSeconds: duration)
    }

    private func attach(_ frame: ProbeFrame, name: String, interval: ClosedRange<Date>) {
        XCTContext.runActivity(named: name) { activity in
            let pixels = XCTAttachment(image: frame.image)
            pixels.name = name + ".png"; pixels.lifetime = .keepAlways; activity.add(pixels)
            let receipt = XCTAttachment(string: [
                "scope": "Actual app UIHosting snapshot; not Widget archiving or physical AOD acceptance.",
                "sourceSHAFromRunner": ProcessInfo.processInfo.environment["ZERO_ONE_REST_MASK_SOURCE_SHA"] ?? "Unavailable",
                "OS": ProcessInfo.processInfo.operatingSystemVersionString,
                "scale": String(Double(frame.scale)),
                "originalStart": String(interval.lowerBound.timeIntervalSinceReferenceDate),
                "originalDeadline": String(interval.upperBound.timeIntervalSinceReferenceDate),
                "observedBefore": String(frame.before.timeIntervalSinceReferenceDate),
                "observedAfter": String(frame.after.timeIntervalSinceReferenceDate),
                "rootInputReplacements": "0",
                "trueAODAndSuspendedActivity": "UNPROVEN"
            ].description)
            receipt.name = name + "-scope.txt"
            receipt.lifetime = .keepAlways; activity.add(receipt)
        }
    }
}

private extension Date {
    var nextRepresentableDate: Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.nextUp)
    }
}

private struct ProbeChecker: View {
    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [.red, .green]
            for index in 0..<Int(ceil(size.width / 8)) {
                context.fill(Path(CGRect(x: CGFloat(index) * 8, y: 0, width: 8,
                    height: size.height)), with: .color(colors[index % 2]))
            }
        }
    }
}

@MainActor
private final class HostedProbe {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private weak var priorKeyWindow: UIWindow?

    init<Content: View>(view: Content, size: CGSize) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw XCTSkip("An actual foreground scene is required; no host is fabricated.")
        }
        priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        controller = UIHostingController(rootView: AnyView(
            view.environment(\.colorScheme, .dark).ignoresSafeArea()))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        controller.view.backgroundColor = .clear
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
    }

    func capture() throws -> ProbeFrame {
        let scale = window.traitCollection.displayScale
        guard scale.isFinite, scale > 0 else { throw ProbeError.invalidPixels }
        let before = Date.now
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = controller.view.drawHierarchy(in: controller.view.bounds,
                                                 afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Actual hosted native hierarchy failed to draw.")
        return try ProbeFrame(image: image, scale: scale, before: before, after: .now)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        priorKeyWindow?.makeKey()
    }
}

private enum ProbeError: Error { case invalidPixels, absentFill }

private struct ProbeFrame {
    let image: UIImage
    let scale: CGFloat
    let before: Date
    let after: Date
    private let cg: CGImage

    init(image: UIImage, scale: CGFloat, before: Date, after: Date) throws {
        guard image.imageOrientation == .up else { throw ProbeError.invalidPixels }
        self.cg = try XCTUnwrap(image.cgImage)
        self.image = image; self.scale = scale; self.before = before; self.after = after
    }

    func pixel(x: CGFloat, y: CGFloat) throws -> [Double] {
        let px = Int(floor(x * scale)), py = Int(floor(y * scale))
        guard px >= 0, py >= 0, px < cg.width, py < cg.height else {
            throw ProbeError.invalidPixels
        }
        // Crop in the CGImage's image coordinates before decoding one pixel.
        // This avoids interpreting a full bitmap context's vertical coordinate system.
        let sample = try XCTUnwrap(cg.cropping(to: CGRect(
            x: CGFloat(px), y: CGFloat(py), width: 1, height: 1)))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var storage = [UInt8](repeating: 0, count: 4)
        let rendered = storage.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered, storage[3] == 255 else { throw ProbeError.invalidPixels }
        return (0..<3).map { Double(storage[$0]) / 255 }
    }

    func whiteBounds(x: CGFloat, y: CGFloat, width: CGFloat) throws
        -> (left: CGFloat, right: CGFloat) {
        var columns: [Int] = []
        for column in Int(x * scale)..<Int((x + width) * scale) {
            if try pixel(x: (CGFloat(column) + 0.5) / scale, y: y).min()! >= 0.95 {
                columns.append(column)
            }
        }
        guard let first = columns.first, let last = columns.last else { throw ProbeError.absentFill }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }

    func assertWhite(x: CGFloat, y: CGFloat) throws {
        XCTAssertGreaterThanOrEqual(try pixel(x: x, y: y).min()!, 0.95,
            "Expected measured canonical filled/border pixel; host frame alone is insufficient.")
    }

    func assertDark(x: CGFloat, y: CGFloat, through end: CGFloat, reason: String) throws {
        let first = Int(ceil(x * scale)), last = Int(floor(end * scale))
        guard first <= last else { return }
        for column in first...last {
            XCTAssertLessThanOrEqual(try pixel(x: (CGFloat(column) + 0.5) / scale, y: y).max()!,
                                     0.025, reason)
        }
    }

    func assertColor(_ expected: [Double], x: CGFloat, y: CGFloat, accuracy: Double) throws {
        let actual = try pixel(x: x, y: y)
        for channel in 0..<3 { XCTAssertEqual(actual[channel], expected[channel], accuracy: accuracy,
            "Transparent interior must reveal actual checker pixels, not a painted backing.") }
    }
}
