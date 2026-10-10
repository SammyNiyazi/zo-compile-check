import Foundation
import Observation

enum VoiceAssistantPhase: Equatable {
    case needsConsent
    case requestingAccess
    case ready
    case preparing
    case listening
    case finalizing
    case transcriptConfirmation
    case feedback(AssistantConfirmation)
    case denied
    case unavailable
    case cancelled

    var isListening: Bool {
        self == .listening
    }
}

@MainActor
@Observable
final class VoiceAssistantCoordinator {
    private(set) var phase: VoiceAssistantPhase
    private(set) var transcript = ""
    private(set) var audioLevel = 0.0

    private let transcriptionService: SpeechTranscriptionService
    private var isPressed = false
    private var operationTask: Task<Void, Never>?
    private var generation: UInt = 0
    // The service is shared and exposes no per-capture cleanup token. Serialize starts:
    // a stale start must finish and be cancelled before a newer one may touch it.
    private var startInFlight: UInt?
    private var stopInFlight: UInt?
    private var pendingStart: UInt?


    init(
        transcriptionService: SpeechTranscriptionService
    ) {
        self.transcriptionService = transcriptionService
        phase = Self.initialPhase(for: transcriptionService.accessState)
    }

    func requestAccess() async {
        guard !Task.isCancelled, phase == .needsConsent || phase == .cancelled else { return }
        phase = .requestingAccess

        generation &+= 1
        let requestGeneration = generation
        let outcome = await transcriptionService.requestAccess()
        guard requestGeneration == generation, phase == .requestingAccess else { return }
        guard !Task.isCancelled else { phase = .cancelled; return }
        switch outcome {
        case .granted:
            phase = .ready
        case .denied:
            phase = .denied
        case .cancelled:
            phase = .cancelled
        case .unavailable:
            phase = .unavailable
        }
    }

    func pressBegan() {
        guard phase == .ready, !isPressed else { return }
        isPressed = true
        transcript = ""
        audioLevel = 0
        phase = .preparing

        generation &+= 1
        pendingStart = generation
        startPendingCaptureIfPossible()
    }

    func pressEnded() {
        guard isPressed else { return }
        isPressed = false
        if phase == .listening {
            finishListening()
        } else if phase == .preparing {
            // Release before start completion invalidates this hold immediately.
            tryAgain()
        }
    }

    func toggleForAccessibility() {
        if isPressed || phase == .preparing || phase == .listening {
            pressEnded()
        } else if phase == .ready {
            pressBegan()
        }
    }

    func confirmTranscript() -> String? {
        guard phase == .transcriptConfirmation else { return nil }
        let confirmed = transcript
        phase = .feedback(.success("Transcript confirmed."))
        return confirmed
    }

    func tryAgain() {
        generation &+= 1
        pendingStart = nil
        operationTask?.cancel()
        transcriptionService.cancelTranscription()
        isPressed = false
        transcript = ""
        audioLevel = 0
        phase = Self.initialPhase(for: transcriptionService.accessState)
    }

    func cancelTranscript() {
        guard phase == .transcriptConfirmation || isActive else { return }
        tryAgain()
    }

    func reset() {
        tryAgain()
    }

    private var isActive: Bool {
        switch phase {
        case .preparing, .listening, .finalizing:
            true
        default:
            false
        }
    }

    private func startPendingCaptureIfPossible() {
        guard startInFlight == nil, stopInFlight == nil, let captureGeneration = pendingStart,
              captureGeneration == generation, isPressed, phase == .preparing else { return }
        pendingStart = nil
        startInFlight = captureGeneration
        operationTask = Task { [weak self] in
            await self?.beginListening(generation: captureGeneration)
        }
    }

    private func beginListening(generation captureGeneration: UInt) async {
        // A release/reset can happen before this scheduled task even reaches the
        // service. Retire that ownership without ever starting capture afterward.
        guard captureGeneration == generation, isPressed, phase == .preparing, !Task.isCancelled else {
            if startInFlight == captureGeneration { startInFlight = nil }
            startPendingCaptureIfPossible()
            return
        }
        var failure: AssistantConfirmation?
        do {
            try await transcriptionService.startTranscription(
                onTranscript: { [weak self] transcript in
                    guard let self, self.generation == captureGeneration, self.isActive else { return }
                    self.transcript = transcript
                },
                onAudioLevel: { [weak self] level in
                    guard let self, self.generation == captureGeneration,
                          self.phase == .preparing || self.phase == .listening else { return }
                    self.audioLevel = level
                },
                onFailure: { [weak self] error in
                    guard let self, self.generation == captureGeneration,
                          self.phase == .preparing || self.phase == .listening else { return }
                    self.present(error.confirmation)
                }
            )
        } catch let error as VoiceInteractionError {
            failure = error.confirmation
        } catch {
            failure = VoiceInteractionError.recognitionFailed.confirmation
        }

        // No new start can own the shared service until this cleanup is done.
        if captureGeneration != generation || !isPressed || Task.isCancelled {
            transcriptionService.cancelTranscription()
            if startInFlight == captureGeneration { startInFlight = nil }
            startPendingCaptureIfPossible()
            return
        }
        startInFlight = nil
        if let failure { present(failure) }
        else if phase == .preparing { phase = .listening }
    }

    private func finishListening() {
        operationTask?.cancel()
        phase = .finalizing
        let finishGeneration = generation
        stopInFlight = finishGeneration
        audioLevel = 0

        operationTask = Task { [weak self] in
            guard let self else { return }
            // A queued obsolete stop must never enter a shared service owned by
            // a later request. Release only this stop reservation.
            guard finishGeneration == generation, !Task.isCancelled, phase == .finalizing else {
                if stopInFlight == finishGeneration { stopInFlight = nil }
                startPendingCaptureIfPossible()
                return
            }
            let finalTranscript = await transcriptionService.stopTranscription()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // stopTranscription may await before reading shared service state.
            // A reset/new press queues behind that completion, just as with start.
            if stopInFlight == finishGeneration { stopInFlight = nil }
            guard finishGeneration == generation, !Task.isCancelled, phase == .finalizing else {
                startPendingCaptureIfPossible()
                return
            }
            transcript = finalTranscript

            guard !finalTranscript.isEmpty else {
                present(VoiceInteractionError.noSpeech.confirmation)
                return
            }
            phase = .transcriptConfirmation
        }
    }

    private func present(_ confirmation: AssistantConfirmation) {
        generation &+= 1
        pendingStart = nil
        operationTask?.cancel()
        isPressed = false
        audioLevel = 0
        transcriptionService.cancelTranscription()
        phase = .feedback(confirmation)
    }

    private static func initialPhase(for accessState: SpeechAccessState) -> VoiceAssistantPhase {
        switch accessState {
        case .notDetermined: .needsConsent
        case .granted: .ready
        case .denied: .denied
        case .unavailable: .unavailable
        }
    }
}
