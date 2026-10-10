import Foundation
import Speech

@MainActor
protocol SpeechTranscriptionService: AnyObject {
    var accessState: SpeechAccessState { get }

    func requestAccess() async -> SpeechAccessRequestOutcome

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws

    func stopTranscription() async -> String
    func cancelTranscription()
}

extension SpeechTranscriptionService {
    var accessState: SpeechAccessState { .granted }

    func requestAccess() async -> SpeechAccessRequestOutcome { .granted }
}

@MainActor
final class NativeSpeechTranscriptionService: SpeechTranscriptionService {
    private let captureService: VoiceCaptureService
    private let recognitionDriver: SpeechRecognitionDriver
    private let waitForFinalResult: @MainActor () async -> Void
    private let scheduleDelivery: (@escaping @MainActor () -> Void) -> Void
    private var currentRequest: SpeechRequestIsolation?
    private var authorizationRequest: UUID?

    init(
        captureService: VoiceCaptureService? = nil,
        locale: Locale = .current
    ) {
        self.captureService = captureService ?? NativeVoiceCaptureService()
        recognitionDriver = NativeSpeechRecognitionDriver(locale: locale)
        waitForFinalResult = { try? await Task.sleep(for: .milliseconds(180)) }
        scheduleDelivery = { delivery in Task { @MainActor in delivery() } }
    }

    // Internal deterministic seam: neither dependency activates the native provider
    // unless its production implementation is explicitly supplied.
    init(
        captureService: VoiceCaptureService,
        recognitionDriver: SpeechRecognitionDriver,
        waitForFinalResult: @escaping @MainActor () async -> Void,
        scheduleDelivery: @escaping (@escaping @MainActor () -> Void) -> Void = {
            delivery in Task { @MainActor in delivery() }
        }
    ) {
        self.captureService = captureService
        self.recognitionDriver = recognitionDriver
        self.waitForFinalResult = waitForFinalResult
        self.scheduleDelivery = scheduleDelivery
    }

    var accessState: SpeechAccessState {
        guard recognitionDriver.isAvailable else {
            return .unavailable
        }

        let speechStatus = recognitionDriver.permissionStatus
        let microphoneStatus = captureService.permissionStatus
        if speechStatus == .denied || microphoneStatus == .denied {
            return .denied
        }
        if speechStatus == .granted, microphoneStatus == .granted {
            return .granted
        }
        return .notDetermined
    }

    func requestAccess() async -> SpeechAccessRequestOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard recognitionDriver.isAvailable else { return .unavailable }
        let authorization = UUID()
        authorizationRequest = authorization
        defer {
            if authorizationRequest == authorization { authorizationRequest = nil }
        }

        let speechStatus = await recognitionDriver.requestPermission()
        guard authorizationRequest == authorization, !Task.isCancelled else { return .cancelled }
        guard speechStatus == .granted else { return .denied }

        let microphoneStatus = await captureService.requestPermission()
        guard authorizationRequest == authorization, !Task.isCancelled else { return .cancelled }
        return microphoneStatus == .granted ? .granted : .denied
    }

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        // A cancelled scheduled start must not cancel a replacement at entry.
        try Task.checkCancellation()
        cancelTranscription()

        guard accessState == .granted else {
            throw VoiceInteractionError.speechRecognitionDenied
        }
        guard recognitionDriver.isAvailable else {
            throw VoiceInteractionError.speechRecognizerUnavailable
        }

        let isolation = SpeechRequestIsolation()
        currentRequest = isolation
        let session = recognitionDriver.makeSession()
        guard owns(isolation), !Task.isCancelled else {
            session.inputGate.close()
            session.cancel()
            retire(isolation)
            throw CancellationError()
        }
        isolation.session = session
        let scheduleDelivery = self.scheduleDelivery
        session.startRecognition { [weak self, weak isolation] transcript, failed in
            scheduleDelivery {
                guard let self, let isolation, self.owns(isolation) else { return }
                if let transcript {
                    isolation.transcript = transcript
                    onTranscript(transcript)
                }
                // A user callback may cancel or replace the request synchronously.
                guard self.owns(isolation) else { return }
                if failed, !isolation.isStopping {
                    onFailure(.recognitionFailed)
                    self.retire(isolation)
                }
            }
        }
        guard owns(isolation), !Task.isCancelled else {
            retire(isolation)
            throw CancellationError()
        }

        do {
            isolation.captureStarted = true
            let inputGate = session.inputGate
            try captureService.startCapture(
                onBuffer: { [weak self, weak isolation, inputGate] buffer, _ in
                    guard inputGate.append(buffer) else { return }
                    let level = Self.normalizedAudioPower(in: buffer)
                    scheduleDelivery {
                        guard let self, let isolation, self.owns(isolation),
                              !isolation.isStopping else { return }
                        onAudioLevel(level)
                    }
                },
                onInterruption: { [weak self, weak isolation] in
                    guard let self, let isolation, self.owns(isolation),
                          !isolation.isStopping else { return }
                    onFailure(.interrupted)
                    self.retire(isolation)
                }
            )
            guard owns(isolation), !Task.isCancelled else {
                retire(isolation)
                throw CancellationError()
            }
        } catch is CancellationError {
            retire(isolation)
            throw CancellationError()
        } catch let error as VoiceInteractionError {
            retire(isolation)
            throw error
        } catch {
            retire(isolation)
            throw VoiceInteractionError.audioInputUnavailable
        }
    }

    nonisolated private static func normalizedAudioPower(in buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for index in 0 ..< frameCount {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }

        let rootMeanSquare = sqrt(sumOfSquares / Float(frameCount))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return min(1, max(0, Double((decibels + 55) / 47)))
    }

    func stopTranscription() async -> String {
        guard !Task.isCancelled, let isolation = currentRequest else { return "" }
        isolation.isStopping = true
        isolation.session?.inputGate.close()
        guard owns(isolation) else { return "" }
        guard !Task.isCancelled else { retire(isolation); return "" }
        if isolation.captureStarted {
            isolation.captureStarted = false
            captureService.stopCapture()
        }
        guard owns(isolation) else { return "" }
        guard !Task.isCancelled else { retire(isolation); return "" }
        await waitForFinalResult()
        guard owns(isolation) else { return "" }
        guard !Task.isCancelled else { retire(isolation); return "" }
        let transcript = isolation.transcript
        retire(isolation)
        return transcript
    }

    func cancelTranscription() {
        authorizationRequest = nil
        if let isolation = currentRequest { retire(isolation) }
    }

    private func owns(_ isolation: SpeechRequestIsolation) -> Bool {
        currentRequest === isolation
    }

    private func retire(_ isolation: SpeechRequestIsolation) {
        // Retire identity first. After an outward callback, this may already be
        // obsolete; only the current capture owner may stop the shared capture.
        guard owns(isolation) else { return }
        currentRequest = nil
        isolation.isStopping = true
        isolation.session?.inputGate.close()
        if isolation.captureStarted {
            isolation.captureStarted = false
            captureService.stopCapture()
        }
        isolation.session?.cancel()
        isolation.session = nil
    }
}

@MainActor
private final class NativeSpeechRecognitionDriver: SpeechRecognitionDriver {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale) { recognizer = SFSpeechRecognizer(locale: locale) }

    var isAvailable: Bool {
        recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true
    }

    var permissionStatus: VoicePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func requestPermission() async -> VoicePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized ? .granted : .denied)
                }
            }
        @unknown default:
            return .denied
        }
    }

    func makeSession() -> SpeechRecognitionSession {
        NativeSpeechRecognitionSession(recognizer: recognizer)
    }
}

@MainActor
private final class NativeSpeechRecognitionSession: SpeechRecognitionSession {
    let inputGate: SpeechBufferDeliveryGate
    private let recognizer: SFSpeechRecognizer?
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer?) {
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        inputGate = SpeechBufferDeliveryGate(append: { request.append($0) }, endAudio: { request.endAudio() })
    }

    func startRecognition(onResult: @escaping (String?, Bool) -> Void) {
        task = recognizer?.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, error != nil)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
enum SpeechTranscriptionServiceFactory {
    static func makeDefault() -> SpeechTranscriptionService {
#if DEBUG
        if ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_MODE"] == "1" {
            let access = reviewAccessConfiguration(
                ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_ACCESS"]
            )
            return ReviewSpeechTranscriptionService(
                transcript: ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_TRANSCRIPT"]
                    ?? "Add 250 ml water.",
                delayMilliseconds: Int(
                    ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_DELAY_MS"] ?? "650"
                ) ?? 650,
                accessState: access.state,
                requestOutcome: access.outcome
            )
        }
#endif
        return NativeSpeechTranscriptionService()
    }

    #if DEBUG
    private static func reviewAccessConfiguration(
        _ value: String?
    ) -> (state: SpeechAccessState, outcome: SpeechAccessRequestOutcome) {
        switch value?.lowercased() {
        case "granted": (.granted, .granted)
        case "denied": (.denied, .denied)
        case "unavailable": (.unavailable, .unavailable)
        case "cancelled": (.notDetermined, .cancelled)
        default: (.notDetermined, .granted)
        }
    }
    #endif
}

#if DEBUG
@MainActor
private final class ReviewSpeechTranscriptionService: SpeechTranscriptionService {
    private let scriptedTranscript: String
    private let delayMilliseconds: Int
    private var currentRequest: SpeechRequestIsolation?
    private var reviewAccessState: SpeechAccessState
    private let requestOutcome: SpeechAccessRequestOutcome

    init(
        transcript: String,
        delayMilliseconds: Int,
        accessState: SpeechAccessState,
        requestOutcome: SpeechAccessRequestOutcome
    ) {
        scriptedTranscript = transcript
        self.delayMilliseconds = delayMilliseconds
        reviewAccessState = accessState
        self.requestOutcome = requestOutcome
    }

    var accessState: SpeechAccessState { reviewAccessState }

    func requestAccess() async -> SpeechAccessRequestOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if requestOutcome == .granted {
            reviewAccessState = .granted
        }
        return requestOutcome
    }

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure _: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        try Task.checkCancellation()
        cancelTranscription()
        let isolation = SpeechRequestIsolation()
        currentRequest = isolation
        onAudioLevel(0.24)
        guard currentRequest === isolation else { return }
        guard !Task.isCancelled else {
            cancelTranscription()
            throw CancellationError()
        }
        isolation.reviewTask = Task { @MainActor [weak self, weak isolation, scriptedTranscript, delayMilliseconds] in
            let firstStage = max(1, delayMilliseconds / 2)
            try? await Task.sleep(for: .milliseconds(firstStage))
            guard let self, let isolation, self.currentRequest === isolation, !Task.isCancelled else { return }
            onAudioLevel(0.72)
            guard self.currentRequest === isolation, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(max(1, delayMilliseconds - firstStage)))
            guard self.currentRequest === isolation, !Task.isCancelled else { return }
            isolation.transcript = scriptedTranscript
            onTranscript(scriptedTranscript)
        }
    }

    func stopTranscription() async -> String {
        guard !Task.isCancelled, let isolation = currentRequest else { return "" }
        currentRequest = nil
        isolation.reviewTask?.cancel()
        isolation.reviewTask = nil
        return isolation.transcript
    }

    func cancelTranscription() {
        guard let isolation = currentRequest else { return }
        currentRequest = nil
        isolation.reviewTask?.cancel()
        isolation.reviewTask = nil
    }
}
#endif
