import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutLiveActivityTests: XCTestCase {
    func testAccentChangeUpdatesTheSameActivityWithoutChangingWorkoutFacts() throws {
        let yellow = WorkoutActivityProjector.project(snapshot(for: MockWorkoutFactory.upperBodyA()))
        let pink = yellow.usingAccent(.pink)
        XCTAssertEqual(pink.sessionID, yellow.sessionID)
        XCTAssertEqual(pink.workoutTitle, yellow.workoutTitle)
        var facts = pink.state
        facts.accentPreference = yellow.state.accentPreference
        XCTAssertEqual(facts, yellow.state)
        XCTAssertEqual(pink.state.accent, .pink)
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: pink,
            existingSessionID: yellow.sessionID, existingState: yellow.state), .update)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(pink.state)), pink.state)
    }

    func testLegacyAndFutureActivityAccentsFallBackWithoutLosingFacts() throws {
        let state = WorkoutActivityProjector.project(snapshot(for: MockWorkoutFactory.upperBodyA()), accent: .pink).state
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let rawValues: [String?] = [nil, "future-accent"]
        for raw in rawValues {
            json["accentPreference"] = raw
            let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.accent, .yellow)
            var expected = state
            expected.accentPreference = raw
            XCTAssertEqual(decoded, expected)
        }
    }

    func testWarmUpPhasePrecedesFirstSetAndClearsAfterDecision() throws {
        var session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps)?.makeSession())
        let pending = WorkoutActivityProjector.project(snapshot(for: session))
        XCTAssertEqual(pending.state.phase, .warmUp)
        XCTAssertEqual(pending.state.phaseTitle, "Warm up first")
        XCTAssertEqual(pending.state.completedSets, 0)
        XCTAssertNil(pending.staleDate)

        session.resolveWarmUp(as: .completed, at: Date(timeIntervalSince1970: 1_000))
        let ready = WorkoutActivityProjector.project(snapshot(for: session))
        XCTAssertEqual(ready.state.phase, .active)
        XCTAssertEqual(ready.state.currentSet, 1)
        XCTAssertEqual(ready.state.completedSets, 0)
    }

    func testProjectionUsesRecordedSetAndRestEndDate() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)
        _ = try session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: exercise.plan.targetReps.upperBound,
            at: loggedAt
        )

        let projection = WorkoutActivityProjector.project(
            snapshot(for: session), at: loggedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(projection.sessionID, session.id)
        XCTAssertEqual(projection.workoutTitle, session.title)
        XCTAssertEqual(projection.state.exerciseName, exercise.plan.name)
        XCTAssertEqual(projection.state.currentSet, 2)
        XCTAssertEqual(projection.state.plannedSetsForExercise, exercise.plan.plannedSetCount)
        XCTAssertEqual(projection.state.completedSets, 1)
        XCTAssertEqual(projection.state.totalSets, session.totalPlannedSetCount)
        XCTAssertEqual(projection.state.phase, .rest)
        XCTAssertEqual(projection.state.restEndsAt, session.restEndsAt)
        XCTAssertEqual(projection.staleDate, session.restEndsAt)
        XCTAssertNil(projection.state.pausedRestSeconds)

        let restEnd = try XCTUnwrap(session.restEndsAt)
        let afterRest = WorkoutActivityProjector.project(
            snapshot(for: session), at: restEnd.addingTimeInterval(1)
        )
        XCTAssertEqual(afterRest.state.phase, .awaitingNextSet)
        XCTAssertNil(afterRest.staleDate)
    }

    func testUndoLastSetReturnsLiveActivityToActiveSet() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)
        _ = try session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: exercise.plan.targetReps.lowerBound,
            at: loggedAt
        )
        let resting = WorkoutActivityProjector.project(snapshot(for: session), at: loggedAt)
        XCTAssertEqual(resting.state.phase, .rest)
        XCTAssertEqual(resting.state.completedSets, 1)

        XCTAssertNotNil(session.undoLastSet())
        let reopened = WorkoutActivityProjector.project(snapshot(for: session), at: loggedAt)
        XCTAssertEqual(reopened.state.phase, .active)
        XCTAssertEqual(reopened.state.exerciseName, exercise.plan.name)
        XCTAssertEqual(reopened.state.currentSet, 1)
        XCTAssertEqual(reopened.state.completedSets, 0)
        XCTAssertNil(reopened.state.restEndsAt)
        XCTAssertNil(reopened.staleDate)
    }

    func testProjectionCoversPausedAcknowledgementAndSaving() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)
        _ = try session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: exercise.plan.targetReps.upperBound,
            at: loggedAt
        )
        let paused = WorkoutActivityProjector.project(
            snapshot(for: session, isPaused: true, pausedRestSeconds: 40), at: loggedAt
        )
        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.pausedRestSeconds, 40)
        XCTAssertNil(paused.state.restEndsAt)
        XCTAssertNil(paused.staleDate)

        session.skipRest()
        let awaiting = WorkoutActivityProjector.project(
            snapshot(for: session, awaitingNextSet: true), at: loggedAt
        )
        XCTAssertEqual(awaiting.state.phase, .awaitingNextSet)
        XCTAssertNil(awaiting.state.restEndsAt)
        XCTAssertNil(awaiting.staleDate)

        let saving = WorkoutActivityProjector.project(
            snapshot(for: session), phase: .saving, at: loggedAt
        )
        XCTAssertEqual(saving.state.phase, .saving)
        XCTAssertNil(saving.state.restEndsAt)
        XCTAssertNil(saving.staleDate)
    }

    func testLifecycleDecisionsAreIdempotent() {
        let projection = WorkoutActivityProjector.project(
            snapshot(for: MockWorkoutFactory.upperBodyA())
        )
        XCTAssertEqual(
            WorkoutActivityDecision.decide(
                desired: projection, existingSessionID: nil, existingState: nil
            ), .request
        )
        XCTAssertEqual(
            WorkoutActivityDecision.decide(
                desired: projection, existingSessionID: projection.sessionID,
                existingState: projection.state
            ), .unchanged
        )
        XCTAssertEqual(
            WorkoutActivityDecision.decide(
                desired: projection, existingSessionID: UUID(), existingState: projection.state
            ), .request
        )
        var changed = projection.state
        changed = WorkoutActivityAttributes.ContentState(
            exerciseName: changed.exerciseName,
            currentSet: changed.currentSet,
            plannedSetsForExercise: changed.plannedSetsForExercise,
            completedSets: changed.completedSets,
            totalSets: changed.totalSets,
            phase: .paused,
            restEndsAt: nil,
            pausedRestSeconds: nil
        )
        XCTAssertEqual(
            WorkoutActivityDecision.decide(
                desired: projection, existingSessionID: projection.sessionID,
                existingState: changed
            ), .update
        )
        XCTAssertEqual(
            WorkoutActivityDecision.decide(
                desired: nil, existingSessionID: projection.sessionID,
                existingState: projection.state
            ), .endAll
        )
    }

    private func snapshot(
        for session: WorkoutSession,
        awaitingNextSet: Bool = false,
        isPaused: Bool = false,
        pausedRestSeconds: Int? = nil
    ) -> ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(
            session: session,
            enteredLoadValue: 10,
            enteredReps: 10,
            enteredRIR: nil,
            awaitingNextSetAcknowledgement: awaitingNextSet,
            isPaused: isPaused,
            pausedRemainingRestSeconds: pausedRestSeconds,
            pendingAdaptation: nil,
            sessionBeforeAdaptation: nil,
            lastSetGuidance: nil
        )
    }
}
