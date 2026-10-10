import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class PushToTalkAssistantTests: XCTestCase {
    func testPermissionRequestRequiresExplicitSetupAction() async {
        let service = FakePushToTalkSpeechService(accessState: .notDetermined)
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()

        XCTAssertEqual(coordinator.phase, .needsConsent)
        XCTAssertEqual(service.accessRequestCount, 0)
        XCTAssertEqual(service.startCount, 0)

        await coordinator.requestAccess()

        XCTAssertEqual(service.accessRequestCount, 1)
        XCTAssertEqual(coordinator.phase, .ready)
    }

    func testTranscriptDoesNotProduceActionBeforeConfirmation() async {
        let service = FakePushToTalkSpeechService(
            accessState: .granted,
            transcript: "Add 250 ml water"
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()
        await settle()
        coordinator.pressEnded()
        await settle()

        XCTAssertEqual(coordinator.phase, .transcriptConfirmation)
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(service.stopCount, 1)

        XCTAssertEqual(coordinator.confirmTranscript(), "Add 250 ml water")
    }

    func testUnsupportedTranscriptTakesNoAction() async {
        let service = FakePushToTalkSpeechService(
            accessState: .granted,
            transcript: "Tell me what I should eat tomorrow"
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()
        await settle()
        coordinator.pressEnded()
        await settle()

        XCTAssertEqual(
            coordinator.confirmTranscript(),
            "Tell me what I should eat tomorrow"
        )
        XCTAssertEqual(
            coordinator.phase,
            .feedback(.success("Transcript confirmed."))
        )
    }

    func testEmptyTranscriptShowsFeedbackAndTakesNoAction() async {
        let service = FakePushToTalkSpeechService(accessState: .granted, transcript: "  ")
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()
        await settle()
        coordinator.pressEnded()
        await settle()

        XCTAssertEqual(coordinator.phase, .feedback(.error("Didn’t catch that.")))
    }

    func testDeniedPermissionNeverStartsCapture() async {
        let service = FakePushToTalkSpeechService(
            accessState: .notDetermined,
            accessOutcome: .denied
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        await coordinator.requestAccess()
        coordinator.pressBegan()

        XCTAssertEqual(coordinator.phase, .denied)
        XCTAssertEqual(service.startCount, 0)
    }

    func testUnavailableSpeechNeverRequestsOrStartsCapture() async {
        let service = FakePushToTalkSpeechService(
            accessState: .unavailable,
            accessOutcome: .unavailable
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        await coordinator.requestAccess()
        coordinator.pressBegan()

        XCTAssertEqual(coordinator.phase, .unavailable)
        XCTAssertEqual(service.accessRequestCount, 0)
        XCTAssertEqual(service.startCount, 0)
    }

    func testCancelledSetupDoesNotStartCaptureOrRetryAutomatically() async {
        let service = FakePushToTalkSpeechService(
            accessState: .notDetermined,
            accessOutcome: .cancelled
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        await coordinator.requestAccess()
        coordinator.pressBegan()

        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertEqual(service.accessRequestCount, 1)
        XCTAssertEqual(service.startCount, 0)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class FakePushToTalkSpeechService: SpeechTranscriptionService {
    private(set) var accessState: SpeechAccessState
    let accessOutcome: SpeechAccessRequestOutcome
    let transcript: String
    private(set) var accessRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    init(
        accessState: SpeechAccessState,
        accessOutcome: SpeechAccessRequestOutcome = .granted,
        transcript: String = "Add 250 ml water"
    ) {
        self.accessState = accessState
        self.accessOutcome = accessOutcome
        self.transcript = transcript
    }

    func requestAccess() async -> SpeechAccessRequestOutcome {
        accessRequestCount += 1
        if accessOutcome == .granted {
            accessState = .granted
        }
        return accessOutcome
    }

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        startCount += 1
        onAudioLevel(0.68)
        onTranscript(transcript)
    }

    func stopTranscription() async -> String {
        stopCount += 1
        return transcript
    }

    func cancelTranscription() {
        cancelCount += 1
    }
}
