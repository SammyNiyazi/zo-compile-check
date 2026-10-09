import XCTest
@testable import ZeroOne

final class WorkoutTimeEstimatorTests: XCTestCase {
    func testTimedPerSideRangeIncludesWarmUpRestAndTransition() throws {
        let first = plan(sets: 2, rest: 120, timed: true, perSide: true)
        let second = plan(sets: 1, rest: 180, timed: true)
        let warmUp = WorkoutWarmUp(estimatedMinutes: 5, steps: ["Prepare"])
        let estimate = try XCTUnwrap(WorkoutTimeEstimator().estimate(plans: [first, second], warmUp: warmUp))
        // 300 warm-up + 150/300 working + 240 rest + 30/60 transition.
        XCTAssertEqual(estimate.minimumSeconds, 720)
        XCTAssertEqual(estimate.maximumSeconds, 900)
        XCTAssertFalse(estimate.fitsWithin(minutes: 14))
        XCTAssertTrue(estimate.fitsWithin(minutes: 15))
    }

    func testFinalSetDoesNotAddAnUnusedRestPeriod() throws {
        let estimate = try XCTUnwrap(WorkoutTimeEstimator().estimate(plans: [plan(sets: 1, rest: 600, timed: true)], warmUp: nil))
        XCTAssertEqual(estimate.minimumSeconds, 30)
        XCTAssertEqual(estimate.maximumSeconds, 60)
    }

    func testShorteningNeverSacrificesAuthoredRestOrOriginalSwapPlan() throws {
        let original = plan(sets: 4, rest: 240)
        let session = WorkoutSession(title: "Strength", warmUp: nil,
            exercises: [WorkoutExercise(plan: original, originalPlan: plan(sets: 3, rest: 300))])
        let proposal = try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 5)
        XCTAssertEqual(proposal.adaptedSession.exercises[0].plan.restSeconds, 240)
        // Undoing the swap keeps the accepted set reduction (WorkoutAdaptation), never a changed rest or identity.
        let adaptedOriginal = try XCTUnwrap(proposal.adaptedSession.exercises[0].originalPlan)
        XCTAssertEqual(adaptedOriginal.id, session.exercises[0].originalPlan?.id)
        XCTAssertEqual(adaptedOriginal.restSeconds, 300)
        XCTAssertEqual(adaptedOriginal.plannedSetCount, min(3, proposal.adaptedSession.exercises[0].plan.plannedSetCount))
        XCTAssertTrue(WorkoutTimeEstimator().estimate(for: proposal.adaptedSession)?.fitsWithin(minutes: 5) == true)
        XCTAssertEqual(proposal.originalSession, session)
    }

    func testSmallerWindowProducesLessWorkWithoutChangingRest() throws {
        let session = WorkoutSession(title: "Strength", exercises: (0 ..< 5).map { _ in WorkoutExercise(plan: plan(sets: 3, rest: 180)) })
        let shorter = try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 10)
        let longer = try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 30)
        XCTAssertLessThan(shorter.adaptedSession.totalPlannedSetCount, longer.adaptedSession.totalPlannedSetCount)
        XCTAssertTrue(shorter.adaptedSession.exercises.allSatisfy { $0.plan.restSeconds == 180 })
    }

    func testImpossibleWindowAndMalformedPrescriptionAreRejected() {
        let session = WorkoutSession(title: "Long timed work", warmUp: WorkoutWarmUp(estimatedMinutes: 5, steps: ["Prepare"]),
            exercises: [WorkoutExercise(plan: plan(sets: 1, rest: 180, timed: true))])
        XCTAssertThrowsError(try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 5)) {
            XCTAssertEqual($0 as? WorkoutAdaptationError, .cannotFitTimeWindow)
        }
        XCTAssertThrowsError(try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 0))
        let malformed = WorkoutSession(title: "Invalid rest", exercises: [WorkoutExercise(plan: plan(sets: 2, rest: .infinity))])
        XCTAssertNil(WorkoutTimeEstimator().estimate(for: malformed))
        XCTAssertThrowsError(try DeterministicWorkoutAdapter().proposal(for: malformed))
    }

    private func plan(sets: Int, rest: Double, timed: Bool = false, perSide: Bool = false) -> ExercisePlan {
        ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Movement", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: sets, restSeconds: rest, previousPerformance: [],
            targetPrescription: WorkingSetPrescription(unit: timed ? .seconds : .repetitions,
                lowerBound: timed ? 30 : 8, upperBound: timed ? 60 : 12, perSide: perSide))
    }
}
