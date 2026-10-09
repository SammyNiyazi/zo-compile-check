import CoreGraphics
import Foundation
import Observation
import XCTest
@testable import ZeroOne

final class ContinuousVoiceHoldTests: XCTestCase {
    private let root = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let original = CGRect(x: 165, y: 741, width: 60, height: 60)

    func testVisualShiftDoesNotMakeOriginalStationaryFingerOutside() {
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        // The proof circle moves down, but the original ownership field remains valid.
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 195, y: 750)), false)
        XCTAssertFalse(hold.contains(id))
    }

    func testActualPhysicalLeftCancelTargetAndDragOutDiscard() {
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 89, y: 792)), true)
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 195, y: 620)), true)
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 135, y: 792)), true)
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 157, y: 792)), true)
    }

    func testCancelledReleaseCannotAuthorizeLaterOrEndANewerHold() {
        var hold = ContinuousVoiceHold()
        let oldID = UUID()
        let newID = UUID()
        hold.begin(oldID, controlBounds: original, physicalRootBounds: root)
        XCTAssertEqual(hold.end(oldID, at: nil), false)
        XCTAssertFalse(hold.contains(oldID))
        hold.begin(newID, controlBounds: original, physicalRootBounds: root)
        XCTAssertNil(hold.end(oldID, at: CGPoint(x: 89, y: 792)))
        hold.move(oldID, to: CGPoint(x: 0, y: 0))
        XCTAssertTrue(hold.contains(newID))
        XCTAssertFalse(hold.isCancelled)
        XCTAssertFalse(hold.canContinue(oldID, isSceneActive: true, isDockPresented: true))
        XCTAssertTrue(hold.canContinue(newID, isSceneActive: true, isDockPresented: true))
        XCTAssertFalse(hold.canContinue(newID, isSceneActive: false, isDockPresented: true))
        XCTAssertFalse(hold.canContinue(newID, isSceneActive: true, isDockPresented: false))
        hold.move(newID, to: CGPoint(x: 89, y: 792))
        XCTAssertFalse(hold.canContinue(newID, isSceneActive: true, isDockPresented: true))
    }

    func testPhysicalCancelGeometryRespectsNonzeroGlobalRootOrigin() {
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original.offsetBy(dx: 70, dy: 110),
                   physicalRootBounds: root.offsetBy(dx: 70, dy: 110))
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 159, y: 902)), true)
        hold.begin(id, controlBounds: original.offsetBy(dx: 70, dy: 110),
                   physicalRootBounds: root.offsetBy(dx: 70, dy: 110))
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 265, y: 860)), false)
    }

    func testVisualOffsetUsesMeasuredControlForTallDynamicTypeTabRows() {
        XCTAssertEqual(ContinuousVoiceHold.visualOffset(controlBounds: original, physicalRootBounds: root), 21)
        let raisedByTallTabs = original.offsetBy(dx: 0, dy: -25)
        XCTAssertEqual(ContinuousVoiceHold.visualOffset(controlBounds: raisedByTallTabs, physicalRootBounds: root), 46)
        let offset = ContinuousVoiceHold.visualOffset(controlBounds: raisedByTallTabs, physicalRootBounds: root)
        XCTAssertEqual(raisedByTallTabs.maxY + offset, root.maxY - 22)
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: CGRect(x: 165, y: 640, width: 60, height: 60), physicalRootBounds: root)
        // A large shift must not admit the gap between original and proof controls.
        XCTAssertEqual(hold.end(id, at: CGPoint(x: 195, y: 730)), true)
    }

    @MainActor
    func testRealCaptureReleaseProducesReviewAndRejectsLateCallbacks() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitFor("start1")
        service.completeStart(1)
        await phase(.listening, of: coordinator)
        service.emitTranscript("Add 250 ml", capture: 1)
        coordinator.pressEnded()
        await service.waitFor("stop1")
        let finalizingCancellations = service.cancelCount
        service.emitLevel(0.9, capture: 1)
        service.emitFailure(capture: 1)
        service.emitTranscript("legitimate final partial", capture: 1)
        XCTAssertEqual(coordinator.phase, .finalizing)
        XCTAssertEqual(coordinator.audioLevel, 0)
        XCTAssertEqual(coordinator.transcript, "legitimate final partial")
        XCTAssertEqual(service.cancelCount, finalizingCancellations)
        service.completeStop(1, transcript: "Add 250 ml")
        await phase(.transcriptConfirmation, of: coordinator)
        let cancellationCount = service.cancelCount
        service.emitTranscript("obsolete recognition", capture: 1)
        service.emitLevel(0.8, capture: 1)
        service.emitFailure(capture: 1)
        XCTAssertEqual(coordinator.phase, .transcriptConfirmation)
        XCTAssertEqual(coordinator.transcript, "Add 250 ml")
        XCTAssertEqual(coordinator.audioLevel, 0)
        XCTAssertEqual(service.cancelCount, cancellationCount)
        XCTAssertEqual(coordinator.confirmTranscript(), "Add 250 ml")
    }

    @MainActor
    func testEarlyReleaseInvalidatesSuspendedStartAndNeverListensLater() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitFor("start1")
        coordinator.pressEnded()
        XCTAssertEqual(coordinator.phase, .ready)
        service.emitTranscript("stale", capture: 1)
        service.completeStart(1)
        await service.waitFor("cancel2") // reset cleanup, then late-start cleanup
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(coordinator.transcript, "")
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(service.stopCount, 0)
    }

    @MainActor
    func testReleaseBeforeScheduledStartDoesNotStartObsoleteCapture() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        // No suspension lets the first start task reach the service before release.
        coordinator.pressBegan()
        coordinator.pressEnded()
        coordinator.pressBegan()
        await service.waitFor("start1")
        service.completeStart(1)
        await phase(.listening, of: coordinator)
        // Only the new hold can become listening; the obsolete scheduled start
        // must retire without touching the service or requiring another completion.
        XCTAssertEqual(service.startCount, 1)
        coordinator.reset()
    }

    @MainActor
    func testResetAndNewPressSerializeLateStartCleanupBeforeNewStart() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitFor("start1")
        coordinator.reset()
        coordinator.pressBegan()
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(coordinator.phase, .preparing)
        service.completeStart(1)
        await service.waitFor("start2")
        XCTAssertLessThan(service.events.firstIndex(of: "cancel2")!, service.events.firstIndex(of: "start2")!)
        let cancellationsBeforeOldCallbacks = service.cancelCount
        service.emitTranscript("old", capture: 1)
        service.emitLevel(0.9, capture: 1)
        service.emitFailure(capture: 1)
        XCTAssertEqual(service.cancelCount, cancellationsBeforeOldCallbacks)
        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertEqual(coordinator.transcript, "")
        service.completeStart(2)
        await phase(.listening, of: coordinator)
        XCTAssertEqual(service.cancelCount, cancellationsBeforeOldCallbacks)
        coordinator.reset()
    }

    @MainActor
    func testStaleThrownStartErrorCannotPresentOverQueuedNewHold() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitFor("start1")
        coordinator.reset()
        coordinator.pressBegan()
        service.completeStart(1, error: .recognitionFailed)
        await service.waitFor("start2")
        XCTAssertEqual(coordinator.phase, .preparing)
        service.completeStart(2)
        await phase(.listening, of: coordinator)
        coordinator.reset()
    }

    @MainActor
    func testResetAndNewPressWaitForOldStopBeforeTouchingSharedService() async {
        let service = OrderedSpeechService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitFor("start1")
        service.completeStart(1)
        await phase(.listening, of: coordinator)
        coordinator.pressEnded()
        await service.waitFor("stop1")
        coordinator.reset()
        coordinator.pressBegan()
        XCTAssertEqual(service.startCount, 1)
        service.completeStop(1, transcript: "obsolete stop")
        await service.waitFor("start2")
        XCTAssertLessThan(service.events.firstIndex(of: "stopReturn1")!, service.events.firstIndex(of: "start2")!)
        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertEqual(coordinator.transcript, "")
        service.completeStart(2)
        await phase(.listening, of: coordinator)
        coordinator.reset()
    }

    @MainActor
    func testLatePermissionAfterResetCannotMutatePhaseOrCapture() async {
        let service = OrderedSpeechService(access: .notDetermined)
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        let access = Task { await coordinator.requestAccess() }
        await service.waitFor("permission1")
        coordinator.reset()
        service.completePermission(1, outcome: .granted)
        await access.value
        XCTAssertEqual(coordinator.phase, .needsConsent)
        XCTAssertEqual(service.startCount, 0)
        // An explicit reopened dock resets from actual authorization; no automatic hold.
        coordinator.reset()
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(service.startCount, 0)
    }

    @MainActor
    func testReleaseDuringExplicitConsentCannotContinueWhenPermissionReturns() async {
        let service = OrderedSpeechService(access: .notDetermined)
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        let access = Task { await coordinator.requestAccess() }
        await service.waitFor("permission1")
        _ = hold.end(id, at: nil)
        service.completePermission(1, outcome: .granted)
        await access.value
        // The same root-owned ID gates continuation, even though access is now ready.
        XCTAssertFalse(hold.contains(id))
        if hold.canContinue(id, isSceneActive: true, isDockPresented: true), coordinator.phase == .ready {
            coordinator.pressBegan()
        }
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(service.startCount, 0)
    }

    @MainActor
    func testExplicitGrantContinuesSameLiveHoldWithoutAnotherBegin() async {
        let service = OrderedSpeechService(access: .notDetermined)
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        let access = Task { await coordinator.requestAccess() }
        await service.waitFor("permission1")
        service.completePermission(1, outcome: .granted)
        await access.value
        if hold.canContinue(id, isSceneActive: true, isDockPresented: true), coordinator.phase == .ready {
            coordinator.pressBegan()
        }
        await service.waitFor("start1")
        service.completeStart(1)
        await phase(.listening, of: coordinator)
        XCTAssertTrue(hold.contains(id))
        XCTAssertEqual(service.startCount, 1)
        _ = hold.end(id, at: nil)
        coordinator.pressEnded()
        await service.waitFor("stop1")
        service.completeStop(1, transcript: "My same hold request")
        await phase(.transcriptConfirmation, of: coordinator)
        XCTAssertEqual(coordinator.transcript, "My same hold request")
    }

    @MainActor
    func testTransientPermissionUIRetiresTouchWithoutCancellingChosenAccessFlow() async {
        let service = OrderedSpeechService(access: .notDetermined)
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        var hold = ContinuousVoiceHold()
        let id = UUID()
        hold.begin(id, controlBounds: original, physicalRootBounds: root)
        let access = Task { await coordinator.requestAccess() }
        await service.waitFor("permission1")
        // This is the root's transient inactive/gesture cancellation operation.
        hold.invalidate()
        XCTAssertFalse(access.isCancelled)
        XCTAssertEqual(coordinator.phase, .requestingAccess)
        service.completePermission(1, outcome: .granted)
        await access.value
        XCTAssertFalse(access.isCancelled)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertFalse(hold.canContinue(id, isSceneActive: true, isDockPresented: true))
        XCTAssertEqual(service.startCount, 0)
    }

    @MainActor
    private func phase(_ expected: VoiceAssistantPhase, of coordinator: VoiceAssistantCoordinator) async {
        if coordinator.phase == expected { return }
        let expectation = expectation(description: "Coordinator phase \(expected)")
        observePhase(expected, of: coordinator, expectation: expectation)
        await fulfillment(of: [expectation], timeout: 2)
    }

    @MainActor
    private func observePhase(_ expected: VoiceAssistantPhase, of coordinator: VoiceAssistantCoordinator,
                              expectation: XCTestExpectation) {
        if coordinator.phase == expected {
            expectation.fulfill()
            return
        }
        withObservationTracking {
            _ = coordinator.phase
        } onChange: {
            Task { @MainActor in
                self.observePhase(expected, of: coordinator, expectation: expectation)
            }
        }
    }
}

/// Each awaited operation completes only when the test explicitly resumes its continuation.
/// Events prove operation order without sleeps, clock assumptions or Task.yield polling.
@MainActor
private final class OrderedSpeechService: SpeechTranscriptionService {
    struct Callbacks {
        let transcript: @MainActor (String) -> Void
        let level: @MainActor (Double) -> Void
        let failure: @MainActor (VoiceInteractionError) -> Void
    }
    private(set) var accessState: SpeechAccessState
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var events: [String] = []
    private var permissionCount = 0
    private var starts: [Int: CheckedContinuation<Void, Error>] = [:]
    private var stops: [Int: CheckedContinuation<String, Never>] = [:]
    private var permissions: [Int: CheckedContinuation<SpeechAccessRequestOutcome, Never>] = [:]
    private var callbacks: [Int: Callbacks] = [:]
    private var waiters: [String: [XCTestExpectation]] = [:]

    init(access: SpeechAccessState = .granted) { accessState = access }

    func requestAccess() async -> SpeechAccessRequestOutcome {
        permissionCount += 1
        let number = permissionCount
        return await withCheckedContinuation { continuation in
            permissions[number] = continuation
            record("permission\(number)")
        }
    }

    func startTranscription(onTranscript: @escaping @MainActor (String) -> Void,
                            onAudioLevel: @escaping @MainActor (Double) -> Void,
                            onFailure: @escaping @MainActor (VoiceInteractionError) -> Void) async throws {
        startCount += 1
        let number = startCount
        callbacks[number] = Callbacks(transcript: onTranscript, level: onAudioLevel, failure: onFailure)
        try await withCheckedThrowingContinuation { continuation in
            starts[number] = continuation
            record("start\(number)")
        }
        record("startReturn\(number)")
    }

    func stopTranscription() async -> String {
        stopCount += 1
        let number = stopCount
        let result = await withCheckedContinuation { continuation in
            stops[number] = continuation
            record("stop\(number)")
        }
        record("stopReturn\(number)")
        return result
    }

    func cancelTranscription() { cancelCount += 1; record("cancel\(cancelCount)") }
    func completeStart(_ number: Int, error: VoiceInteractionError? = nil) {
        let continuation = starts.removeValue(forKey: number)!
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func completeStop(_ number: Int, transcript: String) { stops.removeValue(forKey: number)!.resume(returning: transcript) }
    func completePermission(_ number: Int, outcome: SpeechAccessRequestOutcome) {
        if outcome == .granted { accessState = .granted }
        permissions.removeValue(forKey: number)!.resume(returning: outcome)
    }
    func emitTranscript(_ text: String, capture: Int) { callbacks[capture]!.transcript(text) }
    func emitLevel(_ level: Double, capture: Int) { callbacks[capture]!.level(level) }
    func emitFailure(capture: Int) { callbacks[capture]!.failure(.recognitionFailed) }
    func waitFor(_ event: String) async {
        if events.contains(event) { return }
        let expectation = XCTestExpectation(description: "Ordered speech event \(event)")
        waiters[event, default: []].append(expectation)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed, "Missing ordered event \(event)")
    }
    private func record(_ event: String) {
        events.append(event)
        let pending = waiters.removeValue(forKey: event) ?? []
        for expectation in pending { expectation.fulfill() }
    }
}
