import Foundation
import XCTest
@testable import ZeroOne

final class AssistantVoiceArchitectureTests: XCTestCase {
    private let parser = LocalAssistantIntentParser()
    private let validator = LocalAssistantActionValidator()
    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    func testParsesOneLitreAsHydrationAddition() throws {
        let result = parser.parse("I drank a litre of water today", now: now)
        let intent = try intent(from: result)

        XCTAssertEqual(intent.action, .addHydration(milliliters: 1_000, date: now))
        XCTAssertGreaterThanOrEqual(intent.confidence, 0.75)
    }

    func testParsesAnotherThreeHundredMillilitres() throws {
        let result = parser.parse("Add another 300 millilitres", now: now)

        XCTAssertEqual(
            try intent(from: result).action,
            .addHydration(milliliters: 300, date: now)
        )
    }

    func testAsksForClarificationWhenHydrationUnitIsMissing() {
        let result = parser.parse("I drank two", now: now)

        XCTAssertEqual(result, .clarification(question: "Glasses or litres?"))
    }

    func testParsesAvailableWorkoutTime() throws {
        let result = parser.parse("I only have 35 minutes to train", now: now)

        XCTAssertEqual(
            try intent(from: result).action,
            .updateAvailableTime(minutes: 35)
        )
    }

    func testParsesStructuredWorkoutSetWithoutExecutingIt() throws {
        let result = parser.parse("82.5 kilograms for 8 reps with 1 RIR", now: now)

        XCTAssertEqual(
            try intent(from: result).action,
            .logWorkoutSet(load: Load(82.5, unit: .kilograms), reps: 8, rir: 1)
        )
    }

    func testValidatorRejectsImplausibleHydrationAmount() {
        let result = validator.validate(.addHydration(milliliters: 8_000, date: now))

        XCTAssertEqual(result, .invalid(.error("That water amount looks wrong.")))
    }

    @MainActor
    func testHydrationIntentExecutesEndToEnd() throws {
        let store = VoiceHydrationStore(.init(date: now, currentMilliliters: 750, goalMilliliters: 2_500))
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750, goalMilliliters: 2_500),
            store: store, currentDate: { self.now }
        )
        let context = DailyAssistantContextStore()
        let executor = LocalAssistantActionExecutor(
            hydrationViewModel: hydration,
            dailyContext: context
        )
        let parsed = try intent(from: parser.parse("I drank a litre", now: now))

        XCTAssertEqual(validator.validate(parsed.action), .valid)
        XCTAssertEqual(executor.execute(parsed.action), .success("+1.0 L"))
        XCTAssertEqual(hydration.state.currentMilliliters, 1_750)
        XCTAssertEqual(store.value?.currentMilliliters, 1_750)
    }

    @MainActor
    func testHydrationVoiceDoesNotConfirmFailedWritesOrMemoryOnlyChanges() {
        let store = VoiceHydrationStore(.init(date: now, currentMilliliters: 750, goalMilliliters: 2_500))
        store.acceptsWrites = false
        let hydration = HydrationViewModel(store: store, currentDate: { self.now })
        let executor = LocalAssistantActionExecutor(hydrationViewModel: hydration, dailyContext: DailyAssistantContextStore())
        XCTAssertEqual(executor.execute(.addHydration(milliliters: 250, date: now)).kind, .error)
        XCTAssertEqual(executor.execute(.setHydration(milliliters: 500, date: now)).kind, .error)
        XCTAssertEqual(store.value?.currentMilliliters, 750)
        let memoryOnly = LocalAssistantActionExecutor(hydrationViewModel: HydrationViewModel(), dailyContext: DailyAssistantContextStore())
        XCTAssertEqual(memoryOnly.execute(.addHydration(milliliters: 250, date: now)).kind, .error)
    }

    @MainActor
    func testAvailableTimeUpdatesDailyContext() {
        let hydration = HydrationViewModel(state: HydrationState())
        let context = DailyAssistantContextStore()
        let executor = LocalAssistantActionExecutor(
            hydrationViewModel: hydration,
            dailyContext: context
        )

        let confirmation = executor.execute(.updateAvailableTime(minutes: 35))

        XCTAssertEqual(confirmation, .success("35 min available"))
        XCTAssertEqual(context.availableWorkoutMinutes, 35)
    }

    @MainActor
    func testVoiceControlStartsOnPressAndStopsOnRelease() async {
        let service = StubSpeechTranscriptionService(transcript: "Add 250 ml")
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(coordinator.phase, .listening)

        coordinator.pressEnded()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(service.stopCount, 1)
        XCTAssertEqual(coordinator.phase, .transcriptConfirmation)
    }

    @MainActor
    func testVoiceControlPublishesAudioLevelButWaitsForConfirmation() async {
        let service = StubSpeechTranscriptionService(
            transcript: "Add 250 ml water",
            audioLevel: 0.72
        )
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)

        coordinator.pressBegan()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(coordinator.phase, .listening)
        XCTAssertEqual(coordinator.audioLevel, 0.72, accuracy: 0.001)

        coordinator.pressEnded()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(coordinator.phase, .transcriptConfirmation)
        XCTAssertEqual(coordinator.confirmTranscript(), "Add 250 ml water")
    }

    private func intent(
        from result: AssistantParseResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ParsedAssistantIntent {
        guard case let .intent(intent) = result else {
            XCTFail("Expected a parsed intent, got \(result)", file: file, line: line)
            throw TestFailure.expectedIntent
        }
        return intent
    }

    private enum TestFailure: Error {
        case expectedIntent
    }

}

@MainActor
private final class StubSpeechTranscriptionService: SpeechTranscriptionService {
    let transcript: String
    let audioLevel: Double
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(transcript: String, audioLevel: Double = 0.4) {
        self.transcript = transcript
        self.audioLevel = audioLevel
    }

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure _: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        startCount += 1
        onAudioLevel(audioLevel)
        onTranscript(transcript)
    }

    func stopTranscription() async -> String {
        stopCount += 1
        return transcript
    }

    func cancelTranscription() {}
}

private final class VoiceHydrationStore: HydrationPersisting {
    var value: HydrationStoredState?
    var acceptsWrites = true
    init(_ value: HydrationStoredState) { self.value = value }
    func load() -> HydrationStoredState? { value }
    func save(_ value: HydrationStoredState) { if acceptsWrites { self.value = value } }
}
