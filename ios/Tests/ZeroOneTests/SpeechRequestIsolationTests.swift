import AVFoundation
import Observation
import XCTest
@testable import ZeroOne

/// Source-only candidate. XCTest and native runtime execution remain UNRUN.
/// All suspended operations use continuations; no timing sleeps or queue-FIFO assumptions.
@MainActor
final class SpeechRequestIsolationTests: XCTestCase {
    func testQueuedOldResultErrorAndLevelCannotMutateReplacement() async throws {
        let rig = Rig()
        let old = Events()
        try await rig.start(old)
        let oldSession = rig.driver.sessions[0]
        oldSession.emit("old", failed: true)
        rig.capture.emitBuffer(at: 0)
        rig.service.cancelTranscription()
        let replacement = Events()
        try await rig.start(replacement)
        rig.driver.sessions[1].emit("new")
        rig.deliveries.flush()

        XCTAssertEqual(old.transcripts, [])
        XCTAssertEqual(old.levels, [])
        XCTAssertEqual(old.failures, [])
        XCTAssertEqual(replacement.transcripts, ["new"])
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[1].cancelCount, 0)
        XCTAssertTrue(rig.capture.isCapturing)
    }

    func testOldNativeBufferAndInterruptionAfterReplacementAreRejected() async throws {
        let rig = Rig()
        try await rig.start(Events())
        let oldSession = rig.driver.sessions[0]
        rig.service.cancelTranscription()
        let replacement = Events()
        try await rig.start(replacement)
        rig.capture.emitBuffer(at: 0)
        rig.capture.callbacks[0].interruption()
        rig.deliveries.flush()

        XCTAssertEqual(oldSession.buffers.appends, 0)
        XCTAssertEqual(oldSession.buffers.ends, 1)
        XCTAssertEqual(replacement.levels, [])
        XCTAssertEqual(replacement.failures, [])
        XCTAssertEqual(rig.capture.stopCount, 1)
        rig.capture.emitBuffer(at: 1)
        rig.deliveries.flush()
        XCTAssertEqual(rig.driver.sessions[1].buffers.appends, 1)
        XCTAssertEqual(replacement.levels.count, 1)
    }

    func testCurrentResultLevelAndFailureStillDeliverAndRetireOnce() async throws {
        let rig = Rig()
        let events = Events()
        try await rig.start(events)
        rig.capture.emitBuffer(at: 0)
        rig.driver.sessions[0].emit("current", failed: true)
        rig.deliveries.flush()
        XCTAssertEqual(events.transcripts, ["current"])
        XCTAssertEqual(events.levels.count, 1)
        XCTAssertEqual(events.failures, [.recognitionFailed])
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        rig.service.cancelTranscription()
        XCTAssertEqual(rig.capture.stopCount, 1)
    }

    func testTranscriptCallbackResetRejectsSameResultErrorBranch() async throws {
        let rig = Rig()
        let events = Events()
        try await rig.service.startTranscription(
            onTranscript: { value in
                events.transcripts.append(value)
                rig.service.cancelTranscription()
            },
            onAudioLevel: { events.levels.append($0) },
            onFailure: { events.failures.append($0) }
        )
        rig.driver.sessions[0].emit("accepted", failed: true)
        rig.deliveries.flush()
        XCTAssertEqual(events.transcripts, ["accepted"])
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(rig.capture.stopCount, 1)
        let replacement = Events()
        try await rig.start(replacement)
        rig.driver.sessions[0].emit(nil, failed: true)
        rig.deliveries.flush()
        XCTAssertEqual(rig.driver.sessions[1].cancelCount, 0)
        XCTAssertTrue(rig.capture.isCapturing)
    }

    func testFailureCallbackCancelDoesNotDoubleTeardown() async throws {
        let rig = Rig()
        var failures = 0
        try await rig.service.startTranscription(
            onTranscript: { _ in }, onAudioLevel: { _ in },
            onFailure: { _ in failures += 1; rig.service.cancelTranscription() }
        )
        rig.driver.sessions[0].emit(nil, failed: true)
        rig.deliveries.flush()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
    }

    func testSynchronousCaptureInterruptionCannotResurrectStart() async {
        let rig = Rig()
        let events = Events()
        rig.capture.onStart = { rig.capture.callbacks[0].interruption() }
        do {
            try await rig.start(events)
            XCTFail("Interrupted start must retire its ownership")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(events.failures, [.interrupted])
        XCTAssertFalse(rig.capture.isCapturing)
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        rig.capture.onStart = nil
        do { try await rig.start(Events()) } catch { XCTFail("Replacement failed: \(error)") }
        rig.capture.callbacks[0].interruption()
        XCTAssertTrue(rig.capture.isCapturing)
        XCTAssertEqual(rig.capture.stopCount, 1)
    }

    func testSessionConstructionCancellationClosesUnattachedResource() async {
        let rig = Rig()
        rig.driver.onMake = { rig.service.cancelTranscription() }
        do { try await rig.start(Events()); XCTFail("Cancelled construction must not capture") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(rig.capture.callbacks.count, 0)
        XCTAssertEqual(rig.driver.sessions[0].buffers.ends, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
    }

    func testTaskCancelledDuringSessionConstructionRetiresEmptyOwner() async {
        let rig = Rig()
        var task: Task<Bool, Never>!
        rig.driver.onMake = { task.cancel() }
        task = Task {
            do { try await rig.start(Events()); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(rig.capture.callbacks.count, 0)
        XCTAssertEqual(rig.driver.sessions[0].buffers.ends, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        let result = await rig.service.stopTranscription()
        XCTAssertEqual(result, "")
        XCTAssertEqual(rig.finalization.pendingCount, 0)
    }

    func testCaptureStartupThrowRetiresOldResourcesAndAllowsReplacement() async throws {
        let rig = Rig()
        let events = Events()
        rig.capture.startError = .audioInputUnavailable
        do { try await rig.start(events); XCTFail("Capture must fail") }
        catch let error as VoiceInteractionError { XCTAssertEqual(error, .audioInputUnavailable) }
        catch { XCTFail("Unexpected error: \(error)") }
        let oldSession = rig.driver.sessions[0]
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(oldSession.buffers.ends, 1)
        XCTAssertEqual(oldSession.cancelCount, 1)
        rig.capture.startError = nil
        try await rig.start(Events())
        oldSession.emit("obsolete", failed: true)
        rig.capture.emitBuffer(at: 0)
        rig.capture.callbacks[0].interruption()
        rig.deliveries.flush()
        XCTAssertEqual(events.transcripts, [])
        XCTAssertEqual(events.failures, [])
        XCTAssertTrue(rig.capture.isCapturing)
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[1].cancelCount, 0)
    }

    func testPendingOldStopCannotReadOrCancelReplacement() async throws {
        let rig = Rig()
        try await rig.start(Events())
        rig.driver.sessions[0].emit("old")
        rig.deliveries.flush()
        let stop = Task { await rig.service.stopTranscription() }
        await rig.finalization.waitUntilSuspended()
        rig.service.cancelTranscription()
        let replacement = Events()
        try await rig.start(replacement)
        rig.driver.sessions[1].emit("new")
        rig.deliveries.flush()
        rig.finalization.resume(())
        let oldReturn = await stop.value
        XCTAssertEqual(oldReturn, "")
        XCTAssertEqual(replacement.transcripts, ["new"])
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[1].cancelCount, 0)
        XCTAssertTrue(rig.capture.isCapturing)
    }

    func testStoppingAcceptsFinalTranscriptButRejectsLevelsErrorsAndInterruption() async throws {
        let rig = Rig()
        let events = Events()
        try await rig.start(events)
        let stop = Task { await rig.service.stopTranscription() }
        await rig.finalization.waitUntilSuspended()
        rig.driver.sessions[0].emit("final", failed: true)
        rig.capture.emitBuffer(at: 0)
        rig.capture.callbacks[0].interruption()
        rig.deliveries.flush()
        rig.finalization.resume(())
        let finalReturn = await stop.value
        XCTAssertEqual(finalReturn, "final")
        XCTAssertEqual(events.transcripts, ["final"])
        XCTAssertEqual(events.levels, [])
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(rig.driver.sessions[0].buffers.appends, 0)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        XCTAssertEqual(rig.capture.stopCount, 1)
    }

    func testCancelledScheduledStartDoesNotCancelCurrentOwner() async throws {
        let rig = Rig()
        try await rig.start(Events())
        let task = Task { () -> Bool in
            do { try await rig.start(Events()); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel() // Same actor: child has not entered the service yet.
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(rig.driver.sessions.count, 1)
        XCTAssertEqual(rig.capture.stopCount, 0)
        XCTAssertTrue(rig.capture.isCapturing)
    }

    func testCancelledPendingStopRetiresOnlyItsOwnResources() async throws {
        let rig = Rig()
        try await rig.start(Events())
        let task = Task { await rig.service.stopTranscription() }
        await rig.finalization.waitUntilSuspended()
        task.cancel()
        rig.finalization.resume(())
        let result = await task.value
        XCTAssertEqual(result, "")
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        rig.service.cancelTranscription()
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
    }

    func testCancelledScheduledStopDoesNotStopCurrentOwner() async throws {
        let rig = Rig()
        try await rig.start(Events())
        let task = Task { await rig.service.stopTranscription() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, "")
        XCTAssertEqual(rig.capture.stopCount, 0)
        XCTAssertTrue(rig.capture.isCapturing)
    }

    func testResetDuringSpeechAuthorizationDoesNotRequestMicrophone() async {
        let rig = Rig()
        rig.driver.deferredPermission = true
        let task = Task { await rig.service.requestAccess() }
        await rig.driver.permission.waitUntilSuspended()
        rig.service.cancelTranscription()
        rig.driver.permission.resume(.granted)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(rig.capture.permissionRequests, 0)
        XCTAssertEqual(rig.capture.callbacks.count, 0)
    }

    func testNewAuthorizationSupersedesOldAwait() async {
        let rig = Rig()
        rig.driver.deferredPermission = true
        let old = Task { await rig.service.requestAccess() }
        await rig.driver.permission.waitUntilSuspended()
        rig.driver.deferredPermission = false
        let current = await rig.service.requestAccess()
        rig.driver.permission.resume(.granted)
        let oldOutcome = await old.value
        XCTAssertEqual(current, .granted)
        XCTAssertEqual(oldOutcome, .cancelled)
        XCTAssertEqual(rig.capture.permissionRequests, 1)
    }

    func testResetDuringMicrophoneAuthorizationPreservesOSOutcomeButReturnsCancelled() async {
        let rig = Rig()
        rig.capture.deferredPermission = true
        let task = Task { await rig.service.requestAccess() }
        await rig.capture.permission.waitUntilSuspended()
        rig.service.cancelTranscription()
        rig.capture.permissionStatus = .granted // Represents the actual user's OS choice.
        rig.capture.permission.resume(.granted)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(rig.capture.permissionStatus, .granted)
        XCTAssertEqual(rig.capture.callbacks.count, 0)
    }

    func testCancelledAuthorizationEntryDoesNotSupersedePendingCurrentAuthorization() async {
        let rig = Rig()
        rig.driver.deferredPermission = true
        let current = Task { await rig.service.requestAccess() }
        await rig.driver.permission.waitUntilSuspended()
        let obsolete = Task { await rig.service.requestAccess() }
        obsolete.cancel()
        let obsoleteOutcome = await obsolete.value
        rig.driver.permission.resume(.granted)
        let currentOutcome = await current.value
        XCTAssertEqual(obsoleteOutcome, .cancelled)
        XCTAssertEqual(currentOutcome, .granted)
        XCTAssertEqual(rig.driver.permissionRequests, 1)
        XCTAssertEqual(rig.capture.permissionRequests, 1)
    }

    func testCaptureStopReentrantCancellationDoesNotStopTwice() async throws {
        let rig = Rig()
        try await rig.start(Events())
        rig.capture.onStop = { rig.service.cancelTranscription() }
        let result = await rig.service.stopTranscription()
        XCTAssertEqual(result, "")
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[0].cancelCount, 1)
        XCTAssertEqual(rig.finalization.pendingCount, 0)
    }

    func testEndAudioSynchronousFinalDeliveryCanCancelWithoutDeadlockOrOldContinuation() async throws {
        let rig = Rig(immediateDelivery: true)
        var transcripts: [String] = []
        try await rig.service.startTranscription(
            onTranscript: { value in transcripts.append(value); rig.service.cancelTranscription() },
            onAudioLevel: { _ in }, onFailure: { _ in XCTFail("Stopping failure must be suppressed") }
        )
        let oldSession = rig.driver.sessions[0]
        oldSession.buffers.onEnd = { oldSession.emit("last partial", failed: true) }
        let result = await rig.service.stopTranscription()
        XCTAssertEqual(result, "")
        XCTAssertEqual(transcripts, ["last partial"])
        XCTAssertEqual(oldSession.buffers.ends, 1)
        XCTAssertEqual(oldSession.cancelCount, 1)
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.finalization.pendingCount, 0)
        oldSession.buffers.onEnd = nil
        try await rig.start(Events())
        rig.capture.emitBuffer(at: 0)
        oldSession.emit("obsolete", failed: true)
        XCTAssertTrue(rig.capture.isCapturing)
        XCTAssertEqual(rig.capture.stopCount, 1)
        XCTAssertEqual(rig.driver.sessions[1].cancelCount, 0)
    }

    func testCancelledCoordinatorAuthorizationEntryPreservesConsentPhase() async {
        let service = OrderedTranscriptionService()
        service.accessState = .notDetermined
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        let task = Task { await coordinator.requestAccess() }
        task.cancel()
        await task.value
        XCTAssertEqual(coordinator.phase, .needsConsent)
        XCTAssertEqual(service.authorizationRequests, 0)
    }

    func testCancelledCoordinatorAuthorizationAwaitSettlesRetryablePhaseWithoutReset() async {
        let rig = Rig()
        rig.driver.permissionStatus = .notDetermined
        rig.driver.deferredPermission = true
        let coordinator = VoiceAssistantCoordinator(transcriptionService: rig.service)
        let task = Task { await coordinator.requestAccess() }
        await rig.driver.permission.waitUntilSuspended()
        XCTAssertEqual(coordinator.phase, .requestingAccess)
        task.cancel()
        rig.driver.permissionStatus = .granted
        rig.driver.permission.resume(.granted)
        await task.value
        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertEqual(rig.capture.permissionRequests, 0)
        rig.driver.deferredPermission = false
        await coordinator.requestAccess()
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(rig.capture.permissionRequests, 1)
    }

    func testOldCoordinatorAuthorizationCannotChangeCompletedNewConsent() async {
        let rig = Rig()
        rig.driver.permissionStatus = .notDetermined
        rig.driver.deferredPermission = true
        let coordinator = VoiceAssistantCoordinator(transcriptionService: rig.service)
        let old = Task { await coordinator.requestAccess() }
        await rig.driver.permission.waitUntilSuspended()
        coordinator.reset()
        rig.driver.deferredPermission = false
        rig.driver.permissionStatus = .granted
        await coordinator.requestAccess()
        XCTAssertEqual(coordinator.phase, .ready)
        rig.driver.permission.resume(.granted)
        await old.value
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(rig.capture.permissionRequests, 1)
        XCTAssertEqual(rig.capture.callbacks.count, 0)
    }

    func testCoordinatorPendingOldStartIsRetiredBeforeNewStart() async {
        let service = OrderedTranscriptionService()
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.startGate.waitUntilSuspended()
        coordinator.reset()
        coordinator.pressBegan()
        XCTAssertEqual(service.starts, 1)
        service.startGate.resume(())
        await service.waitForStarts(2)
        XCTAssertEqual(service.starts, 2)
        XCTAssertEqual(coordinator.phase, .preparing)
        service.callbacks[0].transcript("obsolete")
        service.callbacks[0].level(0.9)
        service.callbacks[0].failure(.recognitionFailed)
        XCTAssertEqual(coordinator.transcript, "")
        XCTAssertEqual(coordinator.audioLevel, 0)
        XCTAssertEqual(coordinator.phase, .preparing)
        coordinator.reset()
        service.startGate.resume(())
        await service.waitForCancellations(4)
        XCTAssertEqual(coordinator.phase, .ready)
    }

    func testCoordinatorQueuedOldStopNeverEntersServiceAfterReset() async {
        let service = OrderedTranscriptionService()
        service.pauseStarts = false
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitForStarts(1)
        await waitForPhase(.listening, of: coordinator)
        XCTAssertEqual(coordinator.phase, .listening)
        coordinator.pressEnded()
        coordinator.reset()
        coordinator.pressBegan()
        await service.waitForStarts(2)
        await waitForPhase(.listening, of: coordinator)
        XCTAssertEqual(service.stops, 0)
        XCTAssertEqual(coordinator.phase, .listening)
        coordinator.reset()
    }

    func testCoordinatorPendingStopQueuesReplacementUntilCompletion() async {
        let service = OrderedTranscriptionService()
        service.pauseStarts = false
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await service.waitForStarts(1)
        await waitForPhase(.listening, of: coordinator)
        coordinator.pressEnded()
        await service.stopGate.waitUntilSuspended()
        coordinator.reset()
        coordinator.pressBegan()
        XCTAssertEqual(service.starts, 1)
        XCTAssertEqual(coordinator.phase, .preparing)
        service.stopGate.resume("obsolete stop")
        await service.waitForStarts(2)
        await waitForPhase(.listening, of: coordinator)
        XCTAssertEqual(coordinator.transcript, "")
        XCTAssertEqual(coordinator.phase, .listening)
        coordinator.reset()
    }

    private func waitForPhase(_ phase: VoiceAssistantPhase, of coordinator: VoiceAssistantCoordinator) async {
        await withCheckedContinuation { continuation in
            PhaseObservation(coordinator: coordinator, expected: phase, continuation: continuation).observe()
        }
    }
}

@MainActor
private final class PhaseObservation {
    let coordinator: VoiceAssistantCoordinator
    let expected: VoiceAssistantPhase
    private var continuation: CheckedContinuation<Void, Never>?
    init(coordinator: VoiceAssistantCoordinator, expected: VoiceAssistantPhase,
         continuation: CheckedContinuation<Void, Never>) {
        self.coordinator = coordinator
        self.expected = expected
        self.continuation = continuation
    }
    func observe() {
        guard continuation != nil else { return }
        if coordinator.phase == expected {
            continuation?.resume()
            continuation = nil
            return
        }
        withObservationTracking { _ = coordinator.phase } onChange: { [self] in
            // Observation fires before mutation. Re-read on the actor after the
            // setter completes, rearming if a different phase was delivered.
            Task { @MainActor in observe() }
        }
    }
}

private final class ManualSpeechDeliveries {
    private var pending: [@MainActor () -> Void] = []
    func enqueue(_ delivery: @escaping @MainActor () -> Void) { pending.append(delivery) }
    @MainActor func flush() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

@MainActor
private final class ManualSuspension<Value> {
    private var pending: [CheckedContinuation<Value, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    var pendingCount: Int { pending.count }
    func suspend() async -> Value {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            let waiting = observers
            observers.removeAll()
            waiting.forEach { $0.resume() }
        }
    }
    func waitUntilSuspended() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume(_ value: Value) { pending.removeFirst().resume(returning: value) }
}

private final class BufferCounts {
    var appends = 0
    var ends = 0
    var onEnd: (() -> Void)?
}

@MainActor
private final class ManualRecognitionSession: SpeechRecognitionSession {
    let buffers: BufferCounts
    let inputGate: SpeechBufferDeliveryGate
    private var result: ((String?, Bool) -> Void)?
    private(set) var cancelCount = 0
    init() {
        let counts = BufferCounts()
        buffers = counts
        inputGate = SpeechBufferDeliveryGate(append: { _ in counts.appends += 1 }, endAudio: {
            counts.ends += 1
            counts.onEnd?()
        })
    }
    func startRecognition(onResult: @escaping (String?, Bool) -> Void) { result = onResult }
    func emit(_ transcript: String?, failed: Bool = false) { result?(transcript, failed) }
    func cancel() { cancelCount += 1 } // Retain old callback deliberately.
}

@MainActor
private final class ManualRecognitionDriver: SpeechRecognitionDriver {
    var isAvailable = true
    var permissionStatus: VoicePermissionStatus = .granted
    var deferredPermission = false
    let permission = ManualSuspension<VoicePermissionStatus>()
    private(set) var permissionRequests = 0
    private(set) var sessions: [ManualRecognitionSession] = []
    var onMake: (() -> Void)?
    func requestPermission() async -> VoicePermissionStatus {
        permissionRequests += 1
        return deferredPermission ? await permission.suspend() : permissionStatus
    }
    func makeSession() -> SpeechRecognitionSession {
        let session = ManualRecognitionSession()
        sessions.append(session)
        onMake?()
        return session
    }
}

@MainActor
private final class ManualCapture: VoiceCaptureService {
    struct Callbacks {
        let buffer: (AVAudioPCMBuffer, AVAudioTime) -> Void
        let interruption: @MainActor () -> Void
    }
    var permissionStatus: VoicePermissionStatus = .granted
    var deferredPermission = false
    let permission = ManualSuspension<VoicePermissionStatus>()
    private(set) var permissionRequests = 0
    private(set) var callbacks: [Callbacks] = []
    private(set) var stopCount = 0
    private(set) var isCapturing = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var startError: VoiceInteractionError?
    func requestPermission() async -> VoicePermissionStatus {
        permissionRequests += 1
        return deferredPermission ? await permission.suspend() : permissionStatus
    }
    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
                      onInterruption: @escaping @MainActor () -> Void) throws {
        callbacks.append(Callbacks(buffer: onBuffer, interruption: onInterruption))
        isCapturing = true
        onStart?()
        if let startError { throw startError }
    }
    func stopCapture() {
        stopCount += 1
        isCapturing = false
        onStop?()
    }
    func emitBuffer(at index: Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 { buffer.floatChannelData!.pointee[frame] = 0.5 }
        callbacks[index].buffer(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
    }
}

@MainActor
private final class Events {
    var transcripts: [String] = []
    var levels: [Double] = []
    var failures: [VoiceInteractionError] = []
}

@MainActor
private final class Rig {
    let driver: ManualRecognitionDriver
    let capture: ManualCapture
    let finalization: ManualSuspension<Void>
    let deliveries: ManualSpeechDeliveries
    let service: NativeSpeechTranscriptionService
    init(immediateDelivery: Bool = false) {
        let capture = ManualCapture()
        let driver = ManualRecognitionDriver()
        let finalization = ManualSuspension<Void>()
        let deliveries = ManualSpeechDeliveries()
        self.capture = capture
        self.driver = driver
        self.finalization = finalization
        self.deliveries = deliveries
        service = NativeSpeechTranscriptionService(
            captureService: capture, recognitionDriver: driver,
            waitForFinalResult: { await finalization.suspend() },
            scheduleDelivery: { delivery in
                if immediateDelivery { MainActor.assumeIsolated { delivery() } }
                else { deliveries.enqueue(delivery) }
            }
        )
    }
    func start(_ events: Events) async throws {
        try await service.startTranscription(onTranscript: { events.transcripts.append($0) },
                                             onAudioLevel: { events.levels.append($0) },
                                             onFailure: { events.failures.append($0) })
    }
}

@MainActor
private final class OrderedTranscriptionService: SpeechTranscriptionService {
    struct Callbacks {
        let transcript: @MainActor (String) -> Void
        let level: @MainActor (Double) -> Void
        let failure: @MainActor (VoiceInteractionError) -> Void
    }
    var accessState: SpeechAccessState = .granted
    var pauseStarts = true
    let startGate = ManualSuspension<Void>()
    let stopGate = ManualSuspension<String>()
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancellations = 0
    private(set) var authorizationRequests = 0
    private(set) var callbacks: [Callbacks] = []
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    func requestAccess() async -> SpeechAccessRequestOutcome {
        authorizationRequests += 1
        return .granted
    }
    func startTranscription(onTranscript: @escaping @MainActor (String) -> Void,
                            onAudioLevel: @escaping @MainActor (Double) -> Void,
                            onFailure: @escaping @MainActor (VoiceInteractionError) -> Void) async throws {
        starts += 1
        callbacks.append(Callbacks(transcript: onTranscript, level: onAudioLevel, failure: onFailure))
        let ready = startObservers.filter { $0.0 <= starts }
        startObservers.removeAll { $0.0 <= starts }
        ready.forEach { $0.1.resume() }
        if pauseStarts { await startGate.suspend() }
    }
    func stopTranscription() async -> String {
        stops += 1
        return await stopGate.suspend()
    }
    func cancelTranscription() {
        cancellations += 1
        let ready = cancellationObservers.filter { $0.0 <= cancellations }
        cancellationObservers.removeAll { $0.0 <= cancellations }
        ready.forEach { $0.1.resume() }
    }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { startObservers.append((count, $0)) }
    }
    func waitForCancellations(_ count: Int) async {
        if cancellations >= count { return }
        await withCheckedContinuation { cancellationObservers.append((count, $0)) }
    }
}
