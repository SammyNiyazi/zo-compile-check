import XCTest
@testable import ZeroOne

final class ContextualAssistantTests: XCTestCase {
    private let policy = ContextualAssistantPolicy()

    func testCurrentStatePrioritizesInterruptedWorkout() {
        let context = makeContext(
            workout: .inProgress(title: "ZeroOne Build", canAdaptToThirtyMinutes: true),
            today: .completed(workoutTitle: "Earlier session")
        )

        let response = policy.currentStateResponse(for: context)

        XCTAssertEqual(response.action, .continueWorkout)
        XCTAssertEqual(response.title, "Continue ZeroOne Build")
    }

    func testCurrentStateOffersReadyWorkout() {
        let response = policy.currentStateResponse(
            for: makeContext(today: .ready(workoutTitle: "ZeroOne Start"))
        )

        XCTAssertEqual(response.action, .trainToday)
        XCTAssertEqual(response.title, "Train today")
    }

    func testCurrentStateRecognizesCompletedToday() {
        let response = policy.currentStateResponse(
            for: makeContext(today: .completed(workoutTitle: "Upper A"))
        )

        XCTAssertEqual(response.eyebrow, "TODAY COMPLETE")
        XCTAssertEqual(response.action, .openNutrition)
    }

    func testCurrentStateBrowsesWhenNoWorkoutIsReady() {
        let response = policy.currentStateResponse(
            for: makeContext(today: .noWorkoutReady)
        )

        XCTAssertEqual(response.action, .openWorkoutLibrary)
    }

    func testEverySupportedIntentUsesDeterministicLocalAction() {
        let context = makeContext(
            workout: .inProgress(title: "ZeroOne Build", canAdaptToThirtyMinutes: true)
        )
        let cases: [(String, AssistantActionID)] = [
            ("What should I do now?", .continueWorkout),
            ("I only have 30 minutes", .shortenWorkout),
            ("Add 250 milliliters water", .addWater),
            ("Open nutrition", .openNutrition),
            ("Choose a workout", .openWorkoutLibrary),
            ("Continue workout", .continueWorkout)
        ]

        for (request, expectedAction) in cases {
            XCTAssertEqual(policy.response(to: request, context: context).action, expectedAction, request)
        }
    }

    func testThirtyMinuteIntentUsesStateConditionedFallback() {
        let noWorkout = policy.response(
            to: "I only have thirty minutes",
            context: makeContext(workout: .none)
        )
        let ineligible = policy.response(
            to: "I only have 30 minutes",
            context: makeContext(
                workout: .inProgress(title: "Upper A", canAdaptToThirtyMinutes: false)
            )
        )

        XCTAssertEqual(noWorkout.action, .openWorkoutLibrary)
        XCTAssertEqual(ineligible.action, .continueWorkout)
    }

    func testUnknownRequestIsTruthfulAndOffersCurrentUsefulAction() {
        let response = policy.response(
            to: "Build my meals and predict tomorrow",
            context: makeContext(today: .ready(workoutTitle: "ZeroOne Start"))
        )

        XCTAssertEqual(response.title, "That is not supported yet")
        XCTAssertTrue(response.detail.contains("I can guide"))
        XCTAssertEqual(response.action, .trainToday)
    }

    func testPolicyDoesNotMutateHydrationBeforeAction() {
        let context = makeContext(hydrationMilliliters: 750)

        let response = policy.response(to: "Add 250 ml water", context: context)

        XCTAssertEqual(response.action, .addWater)
        XCTAssertEqual(context.hydration.consumedMilliliters, 750)
    }

    @MainActor
    func testConfirmedSpeechTranscriptUsesSamePipelineAsTypedRequest() async {
        let service = ContextualSpeechService(transcript: "Open nutrition")
        let coordinator = VoiceAssistantCoordinator(transcriptionService: service)
        coordinator.pressBegan()
        await settle()
        coordinator.pressEnded()
        await settle()

        let confirmedTranscript = coordinator.confirmTranscript()
        let context = makeContext()
        let typed = policy.response(to: "Open nutrition", context: context)
        let spoken = confirmedTranscript.map { policy.response(to: $0, context: context) }

        XCTAssertEqual(spoken, typed)
        XCTAssertEqual(spoken?.action, .openNutrition)
    }

    private func makeContext(
        workout: AssistantWorkoutState = .none,
        today: AssistantTodayState = .ready(workoutTitle: "ZeroOne Start"),
        hydrationMilliliters: Int = 750
    ) -> AssistantContext {
        AssistantContext(
            profile: AssistantProfileContext(
                trainingGoal: "Build strength",
                trainingExperience: "Some experience",
                weeklyAvailability: "3 days",
                equipmentAccess: "Full gym",
                trainingConstraint: "Variable schedule"
            ),
            workout: workout,
            today: today,
            hydration: AssistantHydrationContext(
                consumedMilliliters: hydrationMilliliters,
                goalMilliliters: 2_500,
                isAvailable: true
            ),
            nutrition: AssistantNutritionContext(entryCountToday: 2, isAvailable: true),
            health: AssistantHealthContextAvailability(isConnected: true, hasLocalContext: true)
        )
    }

    @MainActor
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class ContextualSpeechService: SpeechTranscriptionService {
    let accessState: SpeechAccessState = .granted
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func startTranscription(
        onTranscript: @escaping @MainActor (String) -> Void,
        onAudioLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (VoiceInteractionError) -> Void
    ) async throws {
        onTranscript(transcript)
    }

    func stopTranscription() async -> String {
        transcript
    }

    func cancelTranscription() {}
}
