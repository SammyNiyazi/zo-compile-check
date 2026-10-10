import XCTest
@testable import ZeroOne

final class WorkoutHistoryDefaultsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)

    func testLatestComparableLoadIsRepeatedWithoutAnIncreaseAndExplicitChoiceIsPreserved() {
        let emptyTarget = plan(load: 0)
        let entry = history(plan: emptyTarget, load: 16, at: now.addingTimeInterval(-86_400))
        let resolved = WorkoutHistoryDefaults().apply(to: emptyTarget, history: [entry], asOf: now)
        XCTAssertEqual(resolved.targetLoad, Load(16))
        XCTAssertEqual(resolved.previousPerformance.map(\.reps), [10])
        let explicit = plan(id: emptyTarget.id, load: 12)
        XCTAssertEqual(WorkoutHistoryDefaults().apply(to: explicit, history: [entry], asOf: now).targetLoad, Load(12))
    }

    func testStaleFutureUnknownSidesAndAmbiguousRepeatedOccurrencesDoNotInventDefaults() {
        let plan = plan(load: 0)
        for entry in [history(plan: plan, load: 16, at: now.addingTimeInterval(-43 * 86_400)),
                      history(plan: plan, load: 16, at: now.addingTimeInterval(1)),
                      history(plan: plan, load: 16, at: now.addingTimeInterval(-86_400), sides: nil)] {
            XCTAssertEqual(WorkoutHistoryDefaults().apply(to: plan, history: [entry], asOf: now), plan)
        }
        let olderPlan = self.plan(load: 0)
        let otherPlan = self.plan(load: 0)
        let date = now.addingTimeInterval(-86_400)
        let ambiguous = WorkoutHistoryEntry(session: WorkoutSession(title: "Repeated exercise", exercises: [
            completed(olderPlan, load: 14, at: date), completed(otherPlan, load: 18, at: date)
        ], completedAt: date))
        XCTAssertEqual(WorkoutHistoryDefaults().apply(to: plan, history: [ambiguous], asOf: now), plan)
    }

    func testStableOccurrenceIdentityRestoresTheCorrectRepeatedExercise() {
        let first = plan(load: 0)
        let second = plan(load: 0)
        let date = now.addingTimeInterval(-86_400)
        let entry = WorkoutHistoryEntry(session: WorkoutSession(title: "Repeated exercise", exercises: [
            completed(first, load: 14, at: date), completed(second, load: 18, at: date)
        ], completedAt: date))
        XCTAssertEqual(WorkoutHistoryDefaults().apply(to: first, history: [entry], asOf: now).targetLoad.value, 14)
        XCTAssertEqual(WorkoutHistoryDefaults().apply(to: second, history: [entry], asOf: now).targetLoad.value, 18)
    }

    @MainActor
    func testCustomSessionPreservesItemIdentityAndWarmUpChoice() throws {
        let workout = CustomWorkout(name: "Short warm-up", items: [CustomWorkoutItem(videoID: "dumbbell-curl")], warmUpLength: .short)
        let session = try XCTUnwrap(workout.makeSession(asOf: now))
        XCTAssertEqual(session.exercises[0].id, workout.items[0].id)
        XCTAssertEqual(session.warmUp?.length, .short)
        XCTAssertEqual(session.warmUp?.estimatedMinutes, 3)
        XCTAssertEqual(session.targetDurationMinutes, WorkoutTimeEstimator().estimate(for: session)?.maximumMinutes)
        var noWarmUp = workout
        noWarmUp.warmUpLength = WorkoutWarmUpLength.none
        XCTAssertFalse(try XCTUnwrap(noWarmUp.makeSession(asOf: now)).requiresWarmUp)
        XCTAssertTrue(try XCTUnwrap(noWarmUp.makeSession(asOf: now, warmUpLengthOverride: .full)).requiresWarmUp)
    }

    private func plan(id: UUID = UUID(), load: Double) -> ExercisePlan {
        ExercisePlan(id: id, exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(load),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 120, previousPerformance: [])
    }

    private func completed(_ plan: ExercisePlan, load: Double, at date: Date, sides: Bool? = false) -> WorkoutExercise {
        WorkoutExercise(plan: plan, completedSets: [CompletedSet(load: Load(load), reps: 10, completedAt: date, isPerSide: sides)])
    }

    private func history(plan: ExercisePlan, load: Double, at date: Date, sides: Bool? = false) -> WorkoutHistoryEntry {
        WorkoutHistoryEntry(session: WorkoutSession(title: "Recorded", exercises: [completed(plan, load: load, at: date, sides: sides)], completedAt: date))
    }
}
