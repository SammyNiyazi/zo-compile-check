import XCTest
@testable import ZeroOne

@MainActor
final class RecommendationExecutionGuardTests: XCTestCase {
    func testAllLoadChoiceSurfacesRevalidateLivePolicyAtTheWriteBoundary() throws {
        let name = "01.load-choice-policy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWorkoutLoadChoiceStore(defaults: defaults)
        let repository = WorkoutLoadChoiceRepository(store: store)
        var allowed = true
        repository.setProgressionPolicy { allowed }
        // Isolate the policy boundary with a host test adapter. Full persisted
        // evidence/current-plan validation is covered by WorkoutProgressionEvidenceTests.
        repository.setProgressionValidator { _, _ in true }
        let upgrade = WorkoutCompletionUpgrade(exerciseID: ExerciseIDs.gobletSquat, exerciseName: "Squat",
            opportunity: .init(previousLoad: Load(15), suggestedLoad: Load(20)),
            completedSets: [], targetRepUpperBound: 12)
        let sourceID = UUID()
        XCTAssertTrue(repository.choose(.repeatPrevious, for: upgrade, sourceSessionID: sourceID))
        let before = try store.load()
        allowed = false // Evidence changed after the original card was shown.
        XCTAssertFalse(repository.choose(.tryNext, for: upgrade, sourceSessionID: sourceID))
        XCTAssertEqual(repository.choices, before)
        XCTAssertEqual(try store.load(), before)
        allowed = true
        XCTAssertTrue(repository.choose(.tryNext, for: upgrade, sourceSessionID: sourceID))
        XCTAssertEqual(repository.choices.first?.selection, .tryNext)
    }

    func testNotificationCannotSaveAnIncreaseDuringANewRecoveryHold() throws {
        let name = "01.recommendation-guard." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = WorkoutHistoryRepository(store: UserDefaultsWorkoutHistoryStore(defaults: defaults))
        let choices = WorkoutLoadChoiceRepository(store: UserDefaultsWorkoutLoadChoiceStore(defaults: defaults))
        let now = Date.now
        let note = SmartNoteCandidate(id: "progress", occurrenceID: UUID(), revision: 1, kind: .progress,
            title: "Review", body: "Saved work", directTitle: nil, directBody: nil,
            reasons: [], unknowns: [], deliveryDate: now, expiresAt: now.addingTimeInterval(60),
            isRestDay: false, isCurrent: true, isFreshEvent: true)
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: now, progressionAllowed: false), .policyHold)
        XCTAssertTrue(choices.choices.isEmpty)
        XCTAssertTrue(WorkoutLoadChoiceRepository(store: UserDefaultsWorkoutLoadChoiceStore(defaults: defaults)).choices.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(SmartNoteProgressAction.apply(.repeatPrevious, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: now, progressionAllowed: false), .stale,
            "Repeating a load still requires current saved evidence")
    }

    func testAvailableTimeExpiresAndFutureReportCannotBecomeCurrent() {
        let store = DailyAssistantContextStore()
        let now = Date(timeIntervalSince1970: 1_791_024_000)
        store.setAvailableWorkoutMinutes(35, at: now)
        XCTAssertEqual(store.currentAvailableWorkoutMinutes(at: now), 35)
        XCTAssertNil(store.currentAvailableWorkoutMinutes(at: now.addingTimeInterval(7 * 3_600)))
        XCTAssertNil(store.currentAvailableWorkoutMinutes(at: now.addingTimeInterval(-1)))
    }

    func testAcceptingStaleTimeProposalCannotDiscardPerformedWork() throws {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 120, previousPerformance: [])
        let model = WorkoutViewModel(session: WorkoutSession(title: "Training", exercises: [WorkoutExercise(plan: plan)]))
        model.proposeThirtyMinuteAdaptation()
        XCTAssertNotNil(model.pendingAdaptation)
        model.completeCurrentSet(at: .now)
        let performed = model.session
        XCTAssertEqual(performed.completedSetCount, 1)
        model.applyPendingAdaptation()
        XCTAssertEqual(model.session, performed)
        XCTAssertEqual(model.adaptationError, .staleProposal)
    }

    func testRecoveryHoldBlocksAStaleProgressionOfferWithoutChangingADraft() {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(15),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 120, previousPerformance: [])
        let model = WorkoutViewModel(session: WorkoutSession(title: "Training", exercises: [WorkoutExercise(plan: plan)]))
        model.progressionRecommendationsAllowed = false
        let opportunity = WorkoutProgressionOpportunity(previousLoad: Load(15), suggestedLoad: Load(20))
        model.selectProgressionOffer(.tryNext, opportunity: opportunity)
        XCTAssertEqual(model.enteredLoadValue, 15)
        XCTAssertTrue(model.progressionOfferSelections.isEmpty)
    }

    func testAssistantPrioritisesSupportedRecoveryConcernOverResumingWork() {
        let recommendation = WellbeingRecommendation(kind: .recovery, demand: .easeTraining,
            evidence: [.reportedFatigue, .consecutiveTrainingDays], policyVersion: WellbeingRecommendationEngine.policyVersion, sourceReferences: ["REC-2013"])
        let context = AssistantContext(profile: AssistantProfileContext(trainingGoal: nil, trainingExperience: nil,
            weeklyAvailability: nil, equipmentAccess: nil, trainingConstraint: nil),
            workout: .inProgress(title: "Training", canAdaptToThirtyMinutes: true), today: .ready(workoutTitle: "Training"),
            hydration: AssistantHydrationContext(consumedMilliliters: 0, goalMilliliters: 2_500, isAvailable: true),
            nutrition: AssistantNutritionContext(entryCountToday: 0, isAvailable: true),
            health: AssistantHealthContextAvailability(isConnected: false, hasLocalContext: false),
            wellbeing: WellbeingAssessment(recommendations: [recommendation], recordedTrainingDays: 3,
                reviewedNutritionDays: 0, hasCurrentRecoveryReport: true, hasConflictingSleep: false,
                evaluatedAt: .now, timeZoneID: Calendar.current.timeZone.identifier))
        XCTAssertEqual(ContextualAssistantPolicy().currentStateResponse(for: context).action, .reviewWellbeing)
    }
}
