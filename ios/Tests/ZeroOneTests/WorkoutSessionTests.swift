import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutSessionTests: XCTestCase {
    func testLoadedExerciseRequiresChosenWeightWhileBodyweightAllowsZero() throws {
        let loadedPlan = ExercisePlan(
            exerciseID: ExerciseIDs.gobletSquat, name: "Goblet Squat", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: []
        )
        var loaded = WorkoutSession(title: "Lower body", exercises: [WorkoutExercise(plan: loadedPlan)])
        XCTAssertThrowsError(try loaded.completeCurrentSet(load: Load(0), reps: 8, at: .now)) {
            XCTAssertEqual($0 as? WorkoutCompletionError, .invalidLoad)
        }
        XCTAssertEqual(loaded.completedSetCount, 0)
        _ = try loaded.completeCurrentSet(load: Load(10), reps: 8, at: .now)
        XCTAssertEqual(loaded.completedSetCount, 1)

        let bodyweightPlan = ExercisePlan(
            exerciseID: ExerciseIDs.pushUp, name: "Push-Up", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: []
        )
        var bodyweight = WorkoutSession(title: "Push", exercises: [WorkoutExercise(plan: bodyweightPlan)])
        _ = try bodyweight.completeCurrentSet(load: Load(0), reps: 8, at: .now)
        XCTAssertEqual(bodyweight.completedSetCount, 1)

        let customPlan = ExercisePlan(
            exerciseID: ExerciseID(rawValue: "MOV-custom-bodyweight"), name: "Custom bodyweight",
            targetLoad: Load(0), targetReps: RepRange(8, 12), plannedSetCount: 1,
            restSeconds: 0, previousPerformance: [], equipmentIdentifiers: ["Bodyweight"]
        )
        var custom = WorkoutSession(title: "Custom", exercises: [WorkoutExercise(plan: customPlan)])
        _ = try custom.completeCurrentSet(load: Load(0), reps: 8, at: .now)
        XCTAssertEqual(custom.completedSetCount, 1)
    }

    func testLoadStepperUsesTheSameIncrementAsProgression() {
        let legs = ExercisePlan(
            exerciseID: ExerciseIDs.gobletSquat, name: "Goblet Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: []
        )
        let arms = ExercisePlan(
            exerciseID: ExerciseIDs.dumbbellCurl, name: "Dumbbell Curl", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: []
        )
        let engine = WorkoutProgressionEngine()
        XCTAssertEqual(engine.loadIncrement(for: legs), 5)
        XCTAssertEqual(engine.loadIncrement(for: arms), 2.5)
    }

    func testSavedLiftProgressUsesRealSameUnitSetsInSessionOrder() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.dumbbellCurl,
            name: "Dumbbell curl",
            targetLoad: Load(16),
            targetReps: RepRange(8, 12),
            plannedSetCount: 2,
            restSeconds: 0,
            previousPerformance: []
        )
        let current = WorkoutSession(title: "Biceps", exercises: [WorkoutExercise(plan: plan)])
        var first = WorkoutSession(title: "Biceps", exercises: [WorkoutExercise(plan: plan)])
        var second = WorkoutSession(title: "Biceps", exercises: [WorkoutExercise(plan: plan)])
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)

        _ = try first.completeCurrentSet(load: Load(12), reps: 10, at: firstDate)
        _ = try first.completeCurrentSet(load: Load(14), reps: 8, at: firstDate.addingTimeInterval(1))
        _ = try second.completeCurrentSet(load: Load(16), reps: 9, at: secondDate)
        _ = try second.completeCurrentSet(load: Load(16), reps: 11, at: secondDate.addingTimeInterval(1))

        let state = WorkoutHistorySurfaceState.entries([
            WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: second)),
            WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: first))
        ])
        let progress = try XCTUnwrap(SavedLiftProgress(session: current, historyState: state))

        XCTAssertEqual(progress.exerciseID, ExerciseIDs.dumbbellCurl)
        XCTAssertEqual(progress.unit, .kilograms)
        XCTAssertEqual(progress.points.map(\.load.value), [14, 16])
        XCTAssertEqual(progress.points.map(\.reps), [8, 11])
        XCTAssertEqual(progress.points.map(\.id), [first.id, second.id])
    }

    func testSavedLiftProgressDoesNotInventHistoryOrMixUnits() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.dumbbellCurl,
            name: "Dumbbell curl",
            targetLoad: Load(16),
            targetReps: RepRange(8, 12),
            plannedSetCount: 1,
            restSeconds: 0,
            previousPerformance: []
        )
        let current = WorkoutSession(title: "Biceps", exercises: [WorkoutExercise(plan: plan)])
        XCTAssertNil(SavedLiftProgress(session: current, historyState: .empty))
        XCTAssertNil(SavedLiftProgress(session: current, historyState: .unavailable))

        var pounds = WorkoutSession(title: "Biceps", exercises: [WorkoutExercise(plan: plan)])
        _ = try pounds.completeCurrentSet(
            load: Load(35, unit: .pounds), reps: 10, at: Date(timeIntervalSince1970: 1_000)
        )
        let state = WorkoutHistorySurfaceState.entries([
            WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: pounds))
        ])
        XCTAssertNil(SavedLiftProgress(session: current, historyState: state))
    }

    func testSubstitutionUsesChosenLoadAndRecordsTheExerciseActuallyPerformed() throws {
        let original = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let alternative = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellCurl))
        let previous = PreviousSetPerformance(load: Load(18), reps: 10)
        let plan = ExercisePlan(
            exerciseID: original.id, name: original.name, targetLoad: Load(18),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: [previous],
            alternativeExerciseIDs: original.resolvedAlternativeIDs
        )
        var session = WorkoutSession(
            title: "Arms", programmeID: .biceps, exercises: [WorkoutExercise(plan: plan)]
        )

        try session.substituteCurrentExercise(with: alternative.id, load: Load(12))
        let swapped = try XCTUnwrap(session.currentExercise)
        XCTAssertEqual(swapped.id, plan.id)
        XCTAssertEqual(swapped.plan.exerciseID, alternative.id)
        XCTAssertEqual(swapped.plan.targetLoad, Load(12))
        XCTAssertTrue(swapped.plan.previousPerformance.isEmpty)
        XCTAssertEqual(swapped.originalPlan, plan)
        XCTAssertEqual(swapped.plan.coachingCue, alternative.shortCoachingCue)

        let restored = try JSONDecoder().decode(
            WorkoutSession.self, from: JSONEncoder().encode(session)
        )
        XCTAssertEqual(restored.currentExercise?.originalPlan, plan)
        _ = try session.completeCurrentSet(
            load: Load(12), reps: 10, at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertFalse(session.undoCurrentSubstitution())
        let history = WorkoutHistoryEntry(session: session)
        XCTAssertEqual(history.exercises?.first?.exerciseID, alternative.id)
        XCTAssertEqual(history.exercises?.first?.completedSets.first?.load, Load(12))
    }

    func testSubstitutionRejectsUnlistedOrUnchosenLoadAndUndoesBeforeSet() throws {
        let original = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let alternative = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellCurl))
        let unrelated = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.barbellBenchPress))
        let plan = ExercisePlan(
            exerciseID: original.id, name: original.name, targetLoad: Load(14),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 0,
            previousPerformance: [], alternativeExerciseIDs: original.resolvedAlternativeIDs
        )
        var session = WorkoutSession(title: "Arms", exercises: [WorkoutExercise(plan: plan)])
        XCTAssertThrowsError(try session.substituteCurrentExercise(with: unrelated.id, load: Load(10))) {
            XCTAssertEqual($0 as? WorkoutSubstitutionError, .unavailableAlternative)
        }
        XCTAssertThrowsError(try session.substituteCurrentExercise(with: alternative.id, load: Load(0))) {
            XCTAssertEqual($0 as? WorkoutSubstitutionError, .invalidLoad)
        }
        XCTAssertEqual(session.currentExercise?.plan, plan)

        try session.substituteCurrentExercise(with: alternative.id, load: Load(10))
        XCTAssertTrue(session.undoCurrentSubstitution())
        XCTAssertEqual(session.currentExercise?.plan, plan)
        XCTAssertNil(session.currentExercise?.originalPlan)

        _ = try session.completeCurrentSet(
            load: Load(14), reps: 9, at: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertThrowsError(try session.substituteCurrentExercise(with: alternative.id, load: Load(10))) {
            XCTAssertEqual($0 as? WorkoutSubstitutionError, .exerciseAlreadyStarted)
        }
    }

    func testAdaptedSubstitutionUndoKeepsShortenedSetAndRestTargets() throws {
        let original = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let alternative = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellCurl))
        let plan = ExercisePlan(
            exerciseID: original.id, name: original.name, targetLoad: Load(14),
            targetReps: RepRange(8, 12), plannedSetCount: 4, restSeconds: 120,
            previousPerformance: [], alternativeExerciseIDs: original.resolvedAlternativeIDs
        )
        var session = WorkoutSession(title: "Arms", exercises: [WorkoutExercise(plan: plan)])
        try session.substituteCurrentExercise(with: alternative.id, load: Load(10))
        let adapted = try DeterministicWorkoutAdapter().proposal(for: session, targetMinutes: 5).adaptedSession
        XCTAssertEqual(adapted.currentExercise?.plan.plannedSetCount, 2)
        XCTAssertEqual(adapted.currentExercise?.originalPlan?.plannedSetCount, 2)
        var undone = adapted
        XCTAssertTrue(undone.undoCurrentSubstitution())
        XCTAssertEqual(undone.currentExercise?.plan.exerciseID, original.id)
        XCTAssertEqual(undone.currentExercise?.plan.plannedSetCount, 2)
        XCTAssertEqual(undone.currentExercise?.plan.restSeconds, 120)
        XCTAssertTrue(try XCTUnwrap(WorkoutTimeEstimator().estimate(for: undone)).fitsWithin(minutes: 5))
    }

    func testWarmUpMustBeResolvedBeforeWorkingSetsAndDoesNotCountAsOne() throws {
        let exercise = WorkoutExercise(plan: ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
            plannedSetCount: 1, restSeconds: 0, previousPerformance: []
        ))
        var session = WorkoutSession(
            title: "Biceps", warmUp: WorkoutWarmUp(estimatedMinutes: 5, steps: ["Move easily."]),
            exercises: [exercise]
        )
        let date = Date(timeIntervalSince1970: 1_000)

        XCTAssertThrowsError(try session.completeCurrentSet(load: Load(10), reps: 10, at: date)) {
            XCTAssertEqual($0 as? WorkoutCompletionError, .warmUpPending)
        }
        XCTAssertEqual(session.completedSetCount, 0)
        session.resolveWarmUp(as: .skipped, at: date)
        XCTAssertEqual(session.warmUp?.status, .skipped)
        XCTAssertEqual(session.warmUp?.resolvedAt, date)
        XCTAssertEqual(session.completedSetCount, 0)
        _ = try session.completeCurrentSet(load: Load(10), reps: 10, at: date)
        XCTAssertEqual(session.completedSetCount, 1)
    }

    func testWarmUpStepChecksRoundTripAndOlderSnapshotsDefaultToUnchecked() throws {
        var warmUp = WorkoutWarmUp(estimatedMinutes: 5, steps: ["Move.", "Practice."])
        warmUp.toggleStep(at: -1)
        warmUp.toggleStep(at: 2)
        XCTAssertTrue(warmUp.checkedStepIndices.isEmpty)
        warmUp.toggleStep(at: 1)
        XCTAssertEqual(warmUp.checkedStepIndices, Set([1]))

        let encoded = try JSONEncoder().encode(warmUp)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutWarmUp.self, from: encoded), warmUp)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldObject.removeValue(forKey: "checkedStepIndices")
        oldObject.removeValue(forKey: "length")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let legacy = try JSONDecoder().decode(WorkoutWarmUp.self, from: oldData)
        XCTAssertTrue(legacy.checkedStepIndices.isEmpty)
        XCTAssertEqual(legacy.length, .full)

        oldObject["checkedStepIndices"] = [-1, 0, 9]
        let invalidData = try JSONSerialization.data(withJSONObject: oldObject)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutWarmUp.self, from: invalidData).checkedStepIndices, Set([0]))

        warmUp.resolve(as: .completed, at: Date(timeIntervalSince1970: 100))
        warmUp.toggleStep(at: 0)
        XCTAssertEqual(warmUp.checkedStepIndices, Set([1]))
    }

    func testWarmUpTimerMetadataRoundTripsAndOldSnapshotsRemainUntimed() throws {
        let warmUp = WorkoutWarmUp(
            estimatedMinutes: 4,
            steps: ["Circles.", "Light curls.", "Ramp sets."],
            timedStepSeconds: [30, nil, 45]
        )
        XCTAssertEqual(warmUp.timerSeconds(forStepAt: 0), 30)
        XCTAssertNil(warmUp.timerSeconds(forStepAt: 1))
        XCTAssertEqual(warmUp.timerSeconds(forStepAt: 2), 45)
        XCTAssertNil(warmUp.timerSeconds(forStepAt: 3))

        let encoded = try JSONEncoder().encode(warmUp)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutWarmUp.self, from: encoded), warmUp)
        let shortened = warmUp.configured(for: .short, at: .now)
        XCTAssertEqual(shortened.steps, ["Light curls.", "Ramp sets."])
        XCTAssertNil(shortened.timerSeconds(forStepAt: 0))
        XCTAssertEqual(shortened.timerSeconds(forStepAt: 1), 45)

        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldObject.removeValue(forKey: "timedStepSeconds")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let restored = try JSONDecoder().decode(WorkoutWarmUp.self, from: oldData)
        XCTAssertTrue(restored.steps.indices.allSatisfy { restored.timerSeconds(forStepAt: $0) == nil })
    }

    func testWarmUpTimerUsesAbsoluteEndDateAcrossBackgroundGap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = WarmUpStepTimer(stepIndex: 0, durationSeconds: 30, endsAt: start.addingTimeInterval(30))
        XCTAssertEqual(timer.remainingSeconds(at: start), 30)
        XCTAssertEqual(timer.remainingSeconds(at: start.addingTimeInterval(10)), 20)
        XCTAssertEqual(timer.remainingSeconds(at: start.addingTimeInterval(40)), 0)
    }

    func testPartialWarmUpRoundTripsWithoutInventingCompletedSteps() throws {
        var warmUp = WorkoutWarmUp(estimatedMinutes: 4, steps: ["Move lightly.", "Practice the lift."])
        XCTAssertEqual(warmUp.statusWhenStartingWorkingSets, .skipped)
        warmUp.toggleStep(at: 0)
        XCTAssertEqual(warmUp.statusWhenStartingWorkingSets, .partial)
        var completeWarmUp = warmUp
        completeWarmUp.toggleStep(at: 1)
        XCTAssertEqual(completeWarmUp.statusWhenStartingWorkingSets, .completed)
        warmUp.resolve(as: .partial, at: Date(timeIntervalSince1970: 100))

        let restored = try JSONDecoder().decode(WorkoutWarmUp.self, from: JSONEncoder().encode(warmUp))
        XCTAssertEqual(restored.status, .partial)
        XCTAssertEqual(restored.checkedStepIndices, Set([0]))
        XCTAssertEqual(restored.resolvedAt, Date(timeIntervalSince1970: 100))

        let plan = ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
            plannedSetCount: 1, restSeconds: 0, previousPerformance: []
        )
        var session = WorkoutSession(
            title: "Biceps", programmeID: .biceps, warmUp: warmUp,
            exercises: [WorkoutExercise(plan: plan)]
        )
        XCTAssertFalse(session.requiresWarmUp)
        _ = try session.completeCurrentSet(load: Load(10), reps: 8, at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(session.completedSetCount, 1)
    }

    func testPreflightWarmUpChoicesSurviveRestorationWithoutLoggingWorkingSets() throws {
        let exercise = WorkoutExercise(plan: ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
            plannedSetCount: 1, restSeconds: 0, previousPerformance: []
        ))
        let warmUp = WorkoutWarmUp(
            estimatedMinutes: 6,
            steps: ["Move easily.", "Practice light curls.", "Start when controlled."]
        )
        let start = Date(timeIntervalSince1970: 1_000)
        var shortSession = WorkoutSession(
            title: "Biceps", programmeID: .biceps, warmUp: warmUp, exercises: [exercise]
        )
        shortSession.selectWarmUpLength(.short, at: start)
        XCTAssertEqual(try XCTUnwrap(shortSession.warmUp).length, .short)
        XCTAssertEqual(shortSession.warmUp?.estimatedMinutes, 4)
        XCTAssertEqual(shortSession.warmUp?.steps, ["Practice light curls.", "Start when controlled."])
        XCTAssertTrue(shortSession.requiresWarmUp)
        XCTAssertEqual(shortSession.completedSetCount, 0)
        let restoredShort = try JSONDecoder().decode(
            WorkoutSession.self, from: JSONEncoder().encode(shortSession)
        )
        XCTAssertEqual(try XCTUnwrap(restoredShort.warmUp).length, .short)
        XCTAssertEqual(restoredShort.warmUp?.steps, shortSession.warmUp?.steps)
        shortSession.selectWarmUpLength(.none, at: start)
        XCTAssertEqual(try XCTUnwrap(shortSession.warmUp).length, .short)

        var begunSession = WorkoutSession(
            title: "Biceps", programmeID: .biceps, warmUp: warmUp, exercises: [exercise]
        )
        begunSession.toggleWarmUpStep(at: 0)
        begunSession.selectWarmUpLength(.none, at: start)
        XCTAssertEqual(try XCTUnwrap(begunSession.warmUp).length, .full)
        XCTAssertEqual(begunSession.warmUp?.checkedStepIndices, Set([0]))

        var noWarmUpSession = WorkoutSession(
            title: "Biceps", programmeID: .biceps, warmUp: warmUp, exercises: [exercise]
        )
        noWarmUpSession.selectWarmUpLength(.none, at: start)
        XCTAssertEqual(try XCTUnwrap(noWarmUpSession.warmUp).length, .none)
        XCTAssertEqual(noWarmUpSession.warmUp?.status, .skipped)
        XCTAssertEqual(noWarmUpSession.warmUp?.resolvedAt, start)
        XCTAssertFalse(noWarmUpSession.requiresWarmUp)
        XCTAssertEqual(noWarmUpSession.completedSetCount, 0)
        let restoredNone = try JSONDecoder().decode(
            WorkoutSession.self, from: JSONEncoder().encode(noWarmUpSession)
        )
        XCTAssertEqual(try XCTUnwrap(restoredNone.warmUp).length, .none)
        XCTAssertEqual(restoredNone.warmUp?.status, .skipped)
        let snapshot = ActiveWorkoutSnapshot(
            session: noWarmUpSession,
            enteredLoadValue: 10,
            enteredReps: 8,
            enteredRIR: nil,
            isPaused: false,
            pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil,
            sessionBeforeAdaptation: nil,
            lastSetGuidance: nil
        )
        let restoredSnapshot = try JSONDecoder().decode(
            ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot)
        )
        XCTAssertTrue(restoredSnapshot.isCompatible)
        XCTAssertEqual(try XCTUnwrap(restoredSnapshot.session.warmUp).length, .none)
        _ = try noWarmUpSession.completeCurrentSet(load: Load(10), reps: 10, at: start)
        XCTAssertEqual(noWarmUpSession.completedSetCount, 1)
    }

    func testOlderSessionWithoutWarmUpDecodesAsUnknown() throws {
        let original = MockWorkoutFactory.upperBodyA()
        let encoded = try JSONEncoder().encode(original)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "warmUp")
        if var exercises = legacyObject["exercises"] as? [[String: Any]] {
            for index in exercises.indices { exercises[index].removeValue(forKey: "originalPlan") }
            legacyObject["exercises"] = exercises
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: legacyData)
        XCTAssertNil(restored.warmUp)
        XCTAssertFalse(restored.requiresWarmUp)
        XCTAssertTrue(restored.exercises.allSatisfy { $0.originalPlan == nil })
    }

    func testCompletingSetRecordsSetAdvancesAndStartsRest() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let completionDate = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)

        let result = try session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: 8,
            rir: 2,
            at: completionDate
        )

        XCTAssertEqual(result, .advancedToNextSet)
        XCTAssertEqual(session.currentSetNumber, 2)
        XCTAssertEqual(session.completedSetCount, 1)
        XCTAssertEqual(session.exercises[0].completedSets[0].rir, 2)
        XCTAssertEqual(session.remainingRestSeconds(at: completionDate), 150)
        XCTAssertEqual(session.activeRestDuration, 150)
        XCTAssertTrue(session.isResting(at: completionDate.addingTimeInterval(149)))
    }

    func testRestCountdownNeverBecomesNegative() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let completionDate = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)

        _ = try session.completeCurrentSet(load: exercise.plan.targetLoad, reps: 8, at: completionDate)

        XCTAssertEqual(session.remainingRestSeconds(at: completionDate.addingTimeInterval(151)), 0)
        XCTAssertFalse(session.isResting(at: completionDate.addingTimeInterval(151)))
    }

    func testShorteningRestChangesDeadlineWithoutStartingNextSet() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)
        _ = try session.completeCurrentSet(load: exercise.plan.targetLoad, reps: 8, at: loggedAt)

        session.shortenRest(by: 15, at: loggedAt.addingTimeInterval(60))
        XCTAssertEqual(session.remainingRestSeconds(at: loggedAt.addingTimeInterval(60)), 75)
        XCTAssertEqual(session.activeRestDuration, 135)
        XCTAssertEqual(session.currentSetNumber, 2)

        session.shortenRest(by: 30, at: loggedAt.addingTimeInterval(130))
        XCTAssertEqual(session.remainingRestSeconds(at: loggedAt.addingTimeInterval(130)), 0)
        XCTAssertNotNil(session.restEndsAt, "The ready-to-start step stays pending until acknowledged")
        XCTAssertEqual(session.completedSetCount, 1)

        session.skipRest()
        XCTAssertNil(session.restEndsAt)
        XCTAssertEqual(session.currentSetNumber, 2)
    }

    func testSkippingRestClearsCountdownWithoutAdvancingAgain() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let completionDate = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)

        _ = try session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: 8,
            rir: 2,
            at: completionDate
        )

        session.skipRest()

        XCTAssertEqual(session.currentSetNumber, 2)
        XCTAssertEqual(session.completedSetCount, 1)
        XCTAssertEqual(session.remainingRestSeconds(at: completionDate), 0)
        XCTAssertNil(session.activeRestDuration)
    }

    func testUndoLastSetReturnsFromNextExerciseAndClearsRest() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let first = try XCTUnwrap(session.currentExercise)
        let start = Date(timeIntervalSince1970: 1_000)
        for setIndex in 0..<first.plan.plannedSetCount {
            _ = try session.completeCurrentSet(
                load: first.plan.targetLoad, reps: 8,
                at: start.addingTimeInterval(Double(setIndex) * first.plan.restSeconds)
            )
        }
        XCTAssertEqual(session.currentExerciseIndex, 1)
        XCTAssertEqual(session.completedSetCount, first.plan.plannedSetCount)

        let beforeUndo = session
        let latestID = try XCTUnwrap(beforeUndo.exercises[0].completedSets.last?.id)
        XCTAssertEqual(try XCTUnwrap(beforeUndo.latestCompletedSetID), latestID)
        XCTAssertNil(session.undoLastSet(expectedSetID: UUID()))
        XCTAssertEqual(session, beforeUndo)
        let undone = try XCTUnwrap(session.undoLastSet(expectedSetID: latestID))
        XCTAssertEqual(undone.reps, 8)
        XCTAssertEqual(session.currentExerciseIndex, 0)
        XCTAssertEqual(session.currentSetNumber, first.plan.plannedSetCount)
        XCTAssertEqual(session.completedSetCount, first.plan.plannedSetCount - 1)
        XCTAssertNil(session.restEndsAt)
        XCTAssertNil(session.activeRestDuration)
    }

    func testCannotCompleteSecondSetDuringRest() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let completionDate = Date(timeIntervalSince1970: 1_000)
        let exercise = try XCTUnwrap(session.currentExercise)

        _ = try session.completeCurrentSet(load: exercise.plan.targetLoad, reps: 8, at: completionDate)

        XCTAssertThrowsError(
            try session.completeCurrentSet(
                load: exercise.plan.targetLoad,
                reps: 8,
                at: completionDate.addingTimeInterval(10)
            )
        ) { error in
            XCTAssertEqual(error as? WorkoutCompletionError, .restInProgress)
        }
    }

    func testLastSetOfExerciseAdvancesToNextExerciseAndStartsRest() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let firstCompletionDate = Date(timeIntervalSince1970: 1_000)
        let firstExercise = try XCTUnwrap(session.currentExercise)

        _ = try session.completeCurrentSet(load: firstExercise.plan.targetLoad, reps: 8, at: firstCompletionDate)
        _ = try session.completeCurrentSet(
            load: firstExercise.plan.targetLoad,
            reps: 8,
            at: firstCompletionDate.addingTimeInterval(150)
        )
        let result = try session.completeCurrentSet(
            load: firstExercise.plan.targetLoad,
            reps: 8,
            at: firstCompletionDate.addingTimeInterval(300)
        )

        XCTAssertEqual(result, .advancedToNextExercise)
        XCTAssertEqual(session.currentExercise?.plan.name, "Chest-Supported Row")
        XCTAssertEqual(session.currentSetNumber, 1)
        XCTAssertEqual(session.remainingRestSeconds(at: firstCompletionDate.addingTimeInterval(300)), 150)
    }

    func testFinalSetCompletesWorkoutWithoutStartingRest() throws {
        let exercise = WorkoutExercise(
            plan: ExercisePlan(
                name: "Cable Row",
                targetLoad: Load(50),
                targetReps: RepRange(10, 10),
                plannedSetCount: 1,
                restSeconds: 90,
                previousPerformance: []
            )
        )
        var session = WorkoutSession(title: "Single Exercise", exercises: [exercise])
        let completionDate = Date(timeIntervalSince1970: 1_000)

        let result = try session.completeCurrentSet(load: Load(50), reps: 10, at: completionDate)

        XCTAssertEqual(result, .workoutCompleted)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.remainingRestSeconds(at: completionDate), 0)
        XCTAssertNil(session.currentExercise)
    }

    func testRejectsInvalidRIR() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let exercise = try XCTUnwrap(session.currentExercise)

        XCTAssertThrowsError(
            try session.completeCurrentSet(
                load: exercise.plan.targetLoad,
                reps: 8,
                rir: 6,
                at: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(error as? WorkoutCompletionError, .invalidRIR)
        }
    }

    func testZeroRIRProducesConservativeLimitGuidance() throws {
        let plan = try XCTUnwrap(MockWorkoutFactory.upperBodyA().currentExercise?.plan)
        let guidance = DeterministicSetEffortGuidance().guidance(
            rir: 0,
            reps: 8,
            plan: plan,
            targetRIR: RIRRange(2, 3)
        )

        XCTAssertEqual(guidance.kind, .limitReached)
        XCTAssertEqual(guidance.title, "LIMIT REACHED")
        XCTAssertEqual(guidance.instruction, "Do not add load. Reduce the next set if technique changed.")
    }

    func testTargetRIRProducesMaintainGuidance() throws {
        let plan = try XCTUnwrap(MockWorkoutFactory.upperBodyA().currentExercise?.plan)
        let guidance = DeterministicSetEffortGuidance().guidance(
            rir: 2,
            reps: 8,
            plan: plan,
            targetRIR: RIRRange(2, 3)
        )

        XCTAssertEqual(guidance.kind, .onTarget)
        XCTAssertEqual(guidance.instruction, "Repeat the planned load and rep range.")
    }

    func testHighRIRBelowRepCeilingPrioritizesRepsBeforeLoad() throws {
        let plan = try XCTUnwrap(MockWorkoutFactory.upperBodyA().currentExercise?.plan)
        let guidance = DeterministicSetEffortGuidance().guidance(
            rir: 5,
            reps: 6,
            plan: plan,
            targetRIR: RIRRange(2, 3)
        )

        XCTAssertEqual(guidance.kind, .capacityAvailable)
        XCTAssertEqual(guidance.instruction, "Keep the load. Work toward 8 clean reps.")
    }

    // MARK: Study 09 training companion rules

    func testDockTapGuardIgnoresASecondTapOnlyBrieflyAfterRoleChange() {
        var dock = WorkoutDockTapGuard()
        let changedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(dock.allowsTap(at: changedAt))

        dock.roleChanged(at: changedAt)
        XCTAssertFalse(dock.allowsTap(at: changedAt.addingTimeInterval(0.2)))
        XCTAssertTrue(dock.allowsTap(at: changedAt.addingTimeInterval(WorkoutDockTapGuard.interval)))
    }

    func testDockTapGuardUsesHandoffInputTimeWithoutShorteningSafetyFloor() {
        var dock = WorkoutDockTapGuard()
        let changedAt = Date(timeIntervalSince1970: 1_000)
        dock.roleChanged(at: changedAt, inputDelay: 0.6)
        XCTAssertFalse(dock.allowsTap(at: changedAt.addingTimeInterval(0.5)))
        XCTAssertTrue(dock.allowsTap(at: changedAt.addingTimeInterval(0.6)))

        dock.roleChanged(at: changedAt, inputDelay: 0.1)
        XCTAssertFalse(dock.allowsTap(at: changedAt.addingTimeInterval(0.2)))
        XCTAssertTrue(dock.allowsTap(at: changedAt.addingTimeInterval(0.36)))
    }

    func testDockTransitionClassifiesRoleChangesAndNeverReplaysOnFirstRender() {
        XCTAssertEqual(WorkoutDockTransition(from: nil, to: .logSet(exerciseIndex: 0, setNumber: 2)), .steady)
        XCTAssertEqual(WorkoutDockTransition(
            from: .rest(exerciseIndex: 0, nextSetNumber: 2), to: .rest(exerciseIndex: 0, nextSetNumber: 2)
        ), .steady)
        XCTAssertEqual(WorkoutDockTransition(
            from: .logSet(exerciseIndex: 0, setNumber: 1), to: .rest(exerciseIndex: 0, nextSetNumber: 2)
        ), .save)
        XCTAssertEqual(WorkoutDockTransition(
            from: .logSet(exerciseIndex: 2, setNumber: 3), to: .finalReview
        ), .save)
        XCTAssertEqual(WorkoutDockTransition(
            from: .rest(exerciseIndex: 0, nextSetNumber: 2), to: .logSet(exerciseIndex: 0, setNumber: 2)
        ), .restOver)
        XCTAssertEqual(WorkoutDockTransition(
            from: .rest(exerciseIndex: 1, nextSetNumber: 1), to: .logSet(exerciseIndex: 1, setNumber: 1)
        ), .handoff)
        XCTAssertEqual(WorkoutDockTransition(
            from: .rest(exerciseIndex: 1, nextSetNumber: 1), to: .logSet(exerciseIndex: 0, setNumber: 2)
        ), .undo)
        XCTAssertEqual(WorkoutDockTransition(
            from: .logSet(exerciseIndex: 0, setNumber: 3), to: .logSet(exerciseIndex: 0, setNumber: 2)
        ), .undo)
        XCTAssertEqual(WorkoutDockTransition(from: .finalReview, to: .logSet(exerciseIndex: 2, setNumber: 3)), .undo)
        XCTAssertEqual(WorkoutDockTransition(from: .paused, to: .logSet(exerciseIndex: 0, setNumber: 2)), .resume)
        XCTAssertEqual(WorkoutDockTransition(from: .warmUp, to: .logSet(exerciseIndex: 0, setNumber: 1)), .resume)
        XCTAssertEqual(WorkoutDockTransition(from: .finalReview, to: .finished), .finish)
        XCTAssertEqual(WorkoutDockTransition(
            from: .logSet(exerciseIndex: 0, setNumber: 1), to: .retry
        ), .other)
    }

    func testDockInputDelayIs360AndLongerOnlyForAGenuineHandoff() {
        let floor = WorkoutDockTapGuard.interval
        XCTAssertEqual(floor, 0.36)
        XCTAssertEqual(WorkoutDockTransition.save.inputDelay(motionEnabled: true), floor)
        XCTAssertEqual(WorkoutDockTransition.restOver.inputDelay(motionEnabled: true), floor)
        XCTAssertEqual(WorkoutDockTransition.undo.inputDelay(motionEnabled: true), floor)
        XCTAssertEqual(WorkoutDockTransition.resume.inputDelay(motionEnabled: true), floor)
        XCTAssertEqual(WorkoutDockTransition.finish.inputDelay(motionEnabled: true), floor)
        XCTAssertEqual(WorkoutDockTransition.handoff.inputDelay(motionEnabled: true), 0.6)
        // Reduce Motion shortens the motion, never the finger guard.
        XCTAssertEqual(WorkoutDockTransition.handoff.inputDelay(motionEnabled: false), floor)
        XCTAssertEqual(WorkoutDockTransition.handoff.totalDuration(motionEnabled: false), 0.24)
        XCTAssertEqual(WorkoutDockTransition.save.totalDuration(motionEnabled: true), 0.6)
        XCTAssertEqual(WorkoutDockTransition.handoff.totalDuration(motionEnabled: true), 0.72)
        XCTAssertEqual(WorkoutDockTransition.finish.totalDuration(motionEnabled: true), 0.96)

        var dock = WorkoutDockTapGuard()
        let changedAt = Date(timeIntervalSince1970: 1_000)
        dock.roleChanged(at: changedAt, inputDelay: WorkoutDockTransition.handoff.inputDelay(motionEnabled: true))
        XCTAssertFalse(dock.allowsTap(at: changedAt.addingTimeInterval(0.59)))
        XCTAssertTrue(dock.allowsTap(at: changedAt.addingTimeInterval(0.6)))
    }

    func testHistorySavedAnnouncementStatesStatusAndActualCounts() {
        XCTAssertEqual(
            WorkoutSetAnnouncement.historySaved(savedSetCount: 9, plannedSetCount: 20),
            "Workout saved to History. Partial, 9 of 20 sets."
        )
        XCTAssertEqual(
            WorkoutSetAnnouncement.historySaved(savedSetCount: 20, plannedSetCount: 20),
            "Workout saved to History. Complete, all 20 sets."
        )
    }

    func testSessionRailKeepsPlanOrderAndStableSegmentIdentity() {
        let first = ExercisePlan(
            name: "Row", targetLoad: Load(20), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 90, previousPerformance: []
        )
        let second = ExercisePlan(
            name: "Press", targetLoad: Load(14), targetReps: RepRange(8, 10),
            plannedSetCount: 3, restSeconds: 90, previousPerformance: []
        )
        let session = WorkoutSession(
            title: "Rail", exercises: [WorkoutExercise(plan: first), WorkoutExercise(plan: second)]
        )
        let rail = WorkoutSetRail(session: session, confirmedSetCount: 0, showsCurrent: true)
        XCTAssertEqual(rail.segments.count, 5)
        XCTAssertEqual(rail.segments.map(\.setNumber), [1, 2, 1, 2, 3])
        XCTAssertEqual(rail.segments.map(\.exerciseID), [first.id, first.id, second.id, second.id, second.id])
        XCTAssertEqual(rail.segments.map(\.mark), [.current, .open, .open, .open, .open])
        XCTAssertEqual(rail.savedCount, 0)
        XCTAssertEqual(
            WorkoutSetRail(session: session, confirmedSetCount: 0, showsCurrent: false).segments.map(\.id),
            rail.segments.map(\.id)
        )
        // A confirmed count can never mark sets that do not exist.
        XCTAssertEqual(WorkoutSetRail(session: session, confirmedSetCount: 7, showsCurrent: false).savedCount, 0)
    }

    func testPrimaryDockRestFractionUsesDeadlineAndClampsToItsTrack() {
        let deadline = Date(timeIntervalSince1970: 1_090)
        let rest = WorkoutPrimaryAction.rest(deadline: deadline, duration: 90)
        XCTAssertEqual(rest.remainingFraction(at: Date(timeIntervalSince1970: 900)), 1)
        XCTAssertEqual(rest.remainingFraction(at: Date(timeIntervalSince1970: 1_045)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(rest.remainingFraction(at: deadline), 0)
        XCTAssertEqual(rest.remainingFraction(at: deadline.addingTimeInterval(1)), 0)
        XCTAssertTrue(rest.isResting)
        XCTAssertEqual(WorkoutPrimaryAction.logSet(number: 2).remainingFraction(at: deadline), 1)
        XCTAssertEqual(WorkoutPrimaryAction.startSet(number: 1, exerciseName: "Curl").title, "Start Curl")
        XCTAssertEqual(WorkoutPrimaryAction.startSet(number: 2, exerciseName: "Curl").title, "Start set 2")
    }

    func testSetAnnouncementsSpeakOnlyWhatHappened() {
        let set = CompletedSet(load: Load(16), reps: 8, completedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(
            WorkoutSetAnnouncement.saved(setNumber: 2, set: set, restSeconds: 90),
            "Set 2 saved. 16 kilograms, 8 reps. Rest 1 minute 30 seconds."
        )
        XCTAssertEqual(
            WorkoutSetAnnouncement.saved(setNumber: 2, set: set, restSeconds: 0),
            "Set 2 saved. 16 kilograms, 8 reps."
        )
        let single = CompletedSet(
            load: Load(35, unit: .pounds), reps: 1, completedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            WorkoutSetAnnouncement.saved(setNumber: 1, set: single, restSeconds: 120),
            "Set 1 saved. 35 pounds, 1 rep. Rest 2 minutes."
        )
        XCTAssertEqual(
            WorkoutSetAnnouncement.notSaved(setNumber: 2),
            "Set 2 was not saved. Your numbers are kept. Try again."
        )
        XCTAssertEqual(WorkoutSetAnnouncement.removed(setNumber: 2), "Set 2 removed.")
    }

    func testSetResponseCopyStatesFactsAndKeepsLowerResultsNeutral() throws {
        let previous = recordedPerformance([(Load(40), 10), (Load(40), 10)])
        let range = RepRange(8, 12)
        func response(_ load: Double, _ reps: Int) throws -> WorkoutSetResponse {
            try XCTUnwrap(WorkoutSetResponse.evaluate(
                savedSet: CompletedSet(load: Load(load), reps: reps, completedAt: Date(timeIntervalSince1970: 3_000)),
                setNumber: 1, targetReps: range, previousPerformance: previous
            ))
        }

        let up = try response(45, 10)
        XCTAssertEqual(WorkoutSetResponseCopy.gainChip(for: up), "+5 kg")
        XCTAssertEqual(
            WorkoutSetResponseCopy.note(for: up, targetReps: range, offersNextLoadChoice: false),
            "Up from 40 kg × 10 last time."
        )

        let moreReps = try response(40, 11)
        XCTAssertEqual(WorkoutSetResponseCopy.gainChip(for: moreReps), "+1 rep")
        XCTAssertEqual(
            WorkoutSetResponseCopy.note(for: moreReps, targetReps: range, offersNextLoadChoice: false),
            "1 more rep than last time at 40 kg."
        )

        let below = try response(45, 6)
        XCTAssertNil(WorkoutSetResponseCopy.gainChip(for: below))
        XCTAssertEqual(
            WorkoutSetResponseCopy.note(for: below, targetReps: range, offersNextLoadChoice: true),
            "6 reps at 45 kg, under your 8–12 range. It's saved and it counts. For the next set:"
        )

        let fewer = try response(40, 8)
        XCTAssertEqual(
            WorkoutSetResponseCopy.note(for: fewer, targetReps: range, offersNextLoadChoice: false),
            "8 reps, 2 fewer than last time at 40 kg. Saved and counted; day-to-day variation is normal."
        )

        let lighter = try response(35, 10)
        let heavierInRange = try response(45, 9)
        XCTAssertEqual(lighter.kind, .lighter)
        XCTAssertEqual(heavierInRange.kind, .heavierIn)
        for lower in [below, fewer, lighter, heavierInRange] {
            let note = WorkoutSetResponseCopy.note(for: lower, targetReps: range, offersNextLoadChoice: false)
            XCTAssertFalse(note.localizedCaseInsensitiveContains("fail"), note)
            XCTAssertFalse(note.localizedCaseInsensitiveContains("missed"), note)
        }
    }

    func testOfferReasonCitesTheRecordedSetsTheRuleChecked() {
        let opportunity = WorkoutProgressionOpportunity(previousLoad: Load(40), suggestedLoad: Load(45))
        let range = RepRange(8, 12)
        XCTAssertEqual(WorkoutProgressionOfferCopy.stepText(for: opportunity), "+5 kg")
        XCTAssertEqual(
            WorkoutProgressionOfferCopy.reason(
                for: opportunity,
                previousPerformance: recordedPerformance([(Load(40), 12), (Load(40), 12), (Load(40), 13)]),
                targetReps: range
            ),
            "Last time you reached 12 reps on all 3 sets at 40 kg, the top of your 8–12 range."
        )

        // Evidence the rule would not accept is never described as if it were.
        XCTAssertNil(WorkoutProgressionOfferCopy.reason(
            for: opportunity, previousPerformance: .unavailable, targetReps: range
        ))
        XCTAssertNil(WorkoutProgressionOfferCopy.reason(
            for: opportunity,
            previousPerformance: recordedPerformance([(Load(40), 12), (Load(40), 11)]),
            targetReps: range
        ))
        XCTAssertNil(WorkoutProgressionOfferCopy.reason(
            for: opportunity,
            previousPerformance: recordedPerformance([(Load(37.5), 12), (Load(40), 12)]),
            targetReps: range
        ))
        XCTAssertNil(WorkoutProgressionOfferCopy.reason(
            for: opportunity,
            previousPerformance: recordedPerformance([(Load(40), 12)], hasNewerUnknownDetails: true),
            targetReps: range
        ))
    }

    func testExerciseComparisonPairsMatchingSetsAndRefusesGuesses() throws {
        let previous = recordedPerformance([(Load(40), 10), (Load(40), 10), (Load(40), 10)])
        func compare(_ sets: [(Load, Int)]) -> WorkoutExerciseComparison? {
            WorkoutExerciseComparison.evaluate(
                savedSets: sets.map { CompletedSet(load: $0.0, reps: $0.1, completedAt: Date(timeIntervalSince1970: 3_000)) },
                previousPerformance: previous
            )
        }

        let heavier = try XCTUnwrap(compare([(Load(45), 9), (Load(45), 8)]))
        XCTAssertEqual(heavier.kind, .load)
        XCTAssertEqual(heavier.chip, "+5 kg")
        XCTAssertEqual(heavier.repsNow, 17)
        XCTAssertEqual(heavier.repsBefore, 20)
        XCTAssertEqual(compare([(Load(40), 10), (Load(40), 11)])?.chip, "+1 rep")
        XCTAssertEqual(compare([(Load(40), 10)])?.chip, "Matched")
        XCTAssertEqual(compare([(Load(40), 8)])?.chip, "2 reps under")
        XCTAssertEqual(compare([(Load(35), 12)])?.kind, .lighter)
        // A matching total must not erase a stronger first set and weaker second set.
        XCTAssertEqual(compare([(Load(40), 12), (Load(40), 8)])?.kind, .mixed)
        // The same peak load does not make these repetitions a same-load gain.
        XCTAssertEqual(compare([(Load(40), 10), (Load(35), 12)])?.kind, .mixed)
        XCTAssertEqual(heavier.comparedSetCount, 2)

        XCTAssertNil(compare([]))
        XCTAssertNil(compare([(Load(90, unit: .pounds), 10)]))
        XCTAssertNil(WorkoutExerciseComparison.evaluate(
            savedSets: [CompletedSet(load: Load(40), reps: 10, completedAt: .now)],
            previousPerformance: .unavailable
        ))
        XCTAssertNil(WorkoutExerciseComparison.evaluate(
            savedSets: [CompletedSet(load: Load(40), reps: 10, completedAt: .now)],
            previousPerformance: recordedPerformance([(Load(40), 10)], hasNewerUnknownDetails: true)
        ))
    }

    func testSessionHighlightLeadsWithProgressAndNeverInventsOne() throws {
        let previous = recordedPerformance([(Load(40), 10), (Load(40), 10)])
        func exercise(_ name: String, _ sets: [(Load, Int)]) -> WorkoutExercise {
            WorkoutExercise(
                plan: ExercisePlan(
                    name: name, targetLoad: Load(40), targetReps: RepRange(8, 12),
                    plannedSetCount: 2, restSeconds: 0, previousPerformance: []
                ),
                completedSets: sets.map {
                    CompletedSet(load: $0.0, reps: $0.1, completedAt: Date(timeIntervalSince1970: 3_000))
                }
            )
        }
        func item(_ exercise: WorkoutExercise) -> (exercise: WorkoutExercise, comparison: WorkoutExerciseComparison?) {
            (exercise, WorkoutExerciseComparison.evaluate(
                savedSets: exercise.completedSets, previousPerformance: previous
            ))
        }
        let matched = exercise("Curl", [(Load(40), 10), (Load(40), 10)])
        let heavier = exercise("Row", [(Load(45), 9), (Load(45), 8)])
        let under = exercise("Press", [(Load(40), 8)])

        let progress = try XCTUnwrap(WorkoutSessionHighlight.make([item(matched), item(heavier)]))
        XCTAssertEqual(progress.title, "+5 kg on Row")
        XCTAssertEqual(
            progress.body,
            "Your heaviest compared set reached 45 kg, up from 40 kg. 2 sets compared."
        )
        XCTAssertEqual(WorkoutSessionHighlight.make([item(matched)])?.title, "Matched last time")
        XCTAssertEqual(
            WorkoutSessionHighlight.make([item(matched), item(under)]),
            WorkoutSessionHighlight(
                title: "Saved as logged",
                body: "Press came in 2 reps under last time across 1 compared set. One session isn't a trend, and nothing resets."
            )
        )
        let uneven = exercise("Row", [(Load(45), 8), (Load(35), 12), (Load(50), 6)])
        let unevenHighlight = try XCTUnwrap(WorkoutSessionHighlight.make([item(uneven)]))
        // Only the first two sets have matching prior evidence; neither the extra
        // 50 kg set nor all three sets can be described as 45 kg comparisons.
        XCTAssertEqual(unevenHighlight.body,
            "Your heaviest compared set reached 45 kg, up from 40 kg. 2 sets compared.")
        let redistributed = exercise("Curl", [(Load(40), 12), (Load(40), 8)])
        XCTAssertEqual(WorkoutSessionHighlight.make([item(redistributed)])?.title, "Saved as logged")
        XCTAssertNil(WorkoutSessionHighlight.make([(exercise: matched, comparison: nil)]))
    }

    func testEndConfirmationStatesExactlyWhatIsSavedAndUnlogged() throws {
        let plans = ["Curl", "Row"].map {
            ExercisePlan(
                name: $0, targetLoad: Load(20), targetReps: RepRange(8, 12),
                plannedSetCount: 2, restSeconds: 0, previousPerformance: []
            )
        }
        var session = WorkoutSession(title: "Arms", exercises: plans.map { WorkoutExercise(plan: $0) })
        let empty = WorkoutEndConfirmationCopy(session: session)
        XCTAssertEqual(empty.title, "End this session?")
        XCTAssertEqual(empty.message, "Nothing is logged yet, so ending now leaves no record for today.")
        XCTAssertEqual(empty.confirmTitle, "End without saving")

        _ = try session.completeCurrentSet(load: Load(20), reps: 10, at: Date(timeIntervalSince1970: 1_000))
        let partial = WorkoutEndConfirmationCopy(session: session)
        XCTAssertEqual(partial.title, "End workout?")
        XCTAssertEqual(
            partial.message,
            "1 set saved across 1 exercise. 3 planned sets stay unlogged. Everything saved stays saved."
        )
        XCTAssertEqual(partial.confirmTitle, "End and see summary")
        XCTAssertEqual(partial.cancelTitle, "Keep training")
    }

    private func recordedPerformance(
        _ sets: [(Load, Int)],
        hasNewerUnknownDetails: Bool = false
    ) -> PreviousExercisePerformanceState {
        let exercise = WorkoutExercise(
            plan: ExercisePlan(
                exerciseID: ExerciseIDs.dumbbellCurl, name: "Dumbbell curl",
                targetLoad: sets.first?.0 ?? Load(0), targetReps: RepRange(8, 12),
                plannedSetCount: max(1, sets.count), restSeconds: 0, previousPerformance: []
            ),
            completedSets: sets.enumerated().map {
                CompletedSet(
                    load: $0.element.0, reps: $0.element.1,
                    completedAt: Date(timeIntervalSince1970: 1_000 + Double($0.offset))
                )
            }
        )
        return .recorded(RecordedExercisePerformance(
            sessionID: UUID(),
            sessionTitle: "Arms",
            completedAt: Date(timeIntervalSince1970: 2_000),
            occurrences: [WorkoutHistoryExercise(exercise: exercise)],
            hasNewerUnknownDetails: hasNewerUnknownDetails
        ))
    }
}

extension WorkoutSessionTests {
    private func timedSession(setCount: Int = 2) -> WorkoutSession {
        let plan = ExercisePlan(
            exerciseID: "EX-PLANK", name: "Front Plank", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: setCount, restSeconds: 0,
            previousPerformance: [], sourcePrescription: "2 sets · 20-45 seconds",
            targetPrescription: WorkingSetPrescription(unit: .seconds, lowerBound: 20, upperBound: 45, perSide: false)
        )
        return WorkoutSession(title: "Timed core", programmeID: .zeroOneStart,
                              exercises: [WorkoutExercise(plan: plan)])
    }

    func testAuthoredSeedHoldsAndMinutesHaveTypedUnitsWithoutReclassifyingRepTargets() throws {
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let plank = try XCTUnwrap(start.sessions.flatMap(\.exercisePlans).first { $0.exerciseID.rawValue == "EX-PLANK" })
        XCTAssertTrue(plank.isTimed)
        XCTAssertEqual(plank.prescription.lowerBound, 20)
        XCTAssertEqual(plank.prescription.upperBound, 45)
        XCTAssertEqual(plank.prescriptionDisplayText, "20–45 sec")
        let unilateral = try XCTUnwrap(start.sessions.flatMap(\.exercisePlans).first { $0.exerciseID.rawValue == "EX-SPLIT-SQUAT" })
        XCTAssertFalse(unilateral.isTimed)
        XCTAssertTrue(unilateral.prescription.perSide)
        XCTAssertEqual(unilateral.prescriptionDisplayText, "8–12 reps per side")
        let consistency = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneConsistency))
        let walk = try XCTUnwrap(consistency.exercisePlans.first { $0.exerciseID.rawValue == "EX-INCLINE-WALK" })
        XCTAssertEqual(walk.prescription.unit, .seconds)
        XCTAssertEqual(walk.prescription.lowerBound, 600)
        XCTAssertEqual(walk.prescription.upperBound, 1_200)
        XCTAssertTrue(walk.allowsZeroLoad)
    }

    func testTimedCompletionRequiresAnActualDurationAndNeverRecordsTargetReps() throws {
        var session = timedSession()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(try session.completeCurrentSet(load: Load(0), reps: 20, at: now)) {
            XCTAssertEqual($0 as? WorkoutCompletionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.completeCurrentSet(load: Load(0), reps: 0, durationSeconds: 0, at: now))
        XCTAssertThrowsError(try session.completeCurrentSet(load: Load(0), reps: 1, durationSeconds: 25, at: now))
        XCTAssertThrowsError(try session.completeCurrentSet(load: Load(0), reps: 0, rir: 2, durationSeconds: 25, at: now))
        XCTAssertEqual(session.completedSetCount, 0)
        _ = try session.completeCurrentSet(load: Load(0, unit: .pounds), reps: 0, durationSeconds: 17, at: now)
        let saved = try XCTUnwrap(session.exercises.first?.completedSets.first)
        XCTAssertEqual(saved.durationSeconds, 17) // Actual work can be below target.
        XCTAssertEqual(saved.reps, 0)
        XCTAssertEqual(saved.load, Load(0, unit: .pounds))
        XCTAssertNil(saved.rir)
        XCTAssertEqual(saved.performanceText, "17 sec")
    }

    func testLegacyPlanAndSetDecodeKeepRepFactsWithUnknownDurationAndSide() throws {
        let legacy = CompletedSet(load: Load(31.75, unit: .pounds), reps: 35, rir: 0,
                                  completedAt: Date(timeIntervalSince1970: 900))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "durationSeconds")
        object.removeValue(forKey: "isPerSide")
        let decoded = try JSONDecoder().decode(CompletedSet.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, legacy)
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertNil(decoded.isPerSide)
        XCTAssertEqual(decoded.rir, 0)
        let currentPlan = timedSession().exercises[0].plan
        var planObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(currentPlan)) as? [String: Any])
        planObject.removeValue(forKey: "targetPrescription")
        let oldPlan = try JSONDecoder().decode(ExercisePlan.self, from: JSONSerialization.data(withJSONObject: planObject))
        XCTAssertFalse(oldPlan.isTimed) // Old source text is not migration evidence.
        XCTAssertEqual(oldPlan.targetReps, currentPlan.targetReps)
        XCTAssertEqual(oldPlan.id, currentPlan.id)
    }

    func testExplicitMalformedTimedDataFailsWithoutInventingSeconds() throws {
        for duration in [0, -1, 86_401] {
            let invalid = CompletedSet(load: Load(0), reps: 0, completedAt: .now, durationSeconds: duration)
            XCTAssertThrowsError(try JSONDecoder().decode(CompletedSet.self, from: JSONEncoder().encode(invalid)))
        }
        let mixed = CompletedSet(load: Load(0), reps: 30, completedAt: .now, durationSeconds: 30)
        XCTAssertThrowsError(try JSONDecoder().decode(CompletedSet.self, from: JSONEncoder().encode(mixed)))
    }

    @MainActor
    func testTimedDraftRecoveryStartsBlankAndRequiresASeparateResultForEachSet() throws {
        var latest: ActiveWorkoutSnapshot?
        let session = timedSession()
        let model = WorkoutViewModel(session: session, onSnapshotChanged: { saved, _ in latest = saved })
        XCTAssertEqual(model.durationDraft, "")
        model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(model.session.completedSetCount, 0)
        for invalid in ["-1", "0", "2.5", "1:30", "86401", "abc"] {
            model.durationDraft = invalid
            model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
            XCTAssertEqual(model.session.completedSetCount, 0)
        }
        model.durationDraft = "23"
        let snapshot = try XCTUnwrap(latest)
        XCTAssertTrue(snapshot.isCompatible)
        let recovered = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot))
        let relaunched = WorkoutViewModel(session: session, restoredSnapshot: recovered,
                                         onSnapshotChanged: { saved, _ in latest = saved })
        XCTAssertEqual(relaunched.durationDraft, "23")
        relaunched.completeCurrentSet(at: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(relaunched.session.exercises[0].completedSets.first?.durationSeconds, 23)
        XCTAssertEqual(relaunched.durationDraft, "")
        XCTAssertTrue(try XCTUnwrap(latest).isCompatible)
        relaunched.acknowledgeNextSet()
        relaunched.completeCurrentSet(at: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(relaunched.session.completedSetCount, 1)
        relaunched.undoLastSet()
        XCTAssertEqual(relaunched.session.completedSetCount, 0)
        XCTAssertEqual(relaunched.durationDraft, "23")
    }

    @MainActor
    func testTimedFinalReviewUndoRestoresTheSameActualDuration() throws {
        let model = WorkoutViewModel(session: timedSession(setCount: 1), requiresFinalSetReview: true)
        model.durationDraft = "18"
        model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(model.awaitingFinalSetConfirmation)
        XCTAssertFalse(model.isCompletionSaved)
        let originalID = try XCTUnwrap(model.session.exercises[0].completedSets.first?.id)
        model.undoFinalSet()
        XCTAssertFalse(model.session.isComplete)
        XCTAssertEqual(model.durationDraft, "18")
        XCTAssertEqual(model.session.completedSetCount, 0)
        model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_001))
        XCTAssertNotEqual(model.session.exercises[0].completedSets.first?.id, originalID)
        model.confirmFinalSetAndFinish()
        XCTAssertTrue(model.isCompletionSaved)
        XCTAssertEqual(model.session.exercises[0].completedSets.first?.durationSeconds, 18)
    }

    func testTimedEarlyFinishRoundTripsFileSnapshotAndLosslessHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TimedHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var session = timedSession()
        _ = try session.completeCurrentSet(load: Load(2.25, unit: .pounds), reps: 0,
                                           durationSeconds: 29, at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(session.finishEarly(at: Date(timeIntervalSince1970: 1_001)))
        let snapshot = ActiveWorkoutSnapshot(session: session, enteredLoadValue: 2.25, enteredReps: 1,
            enteredRIR: nil, durationDraft: "", isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        let activeStore = FileActiveWorkoutStore(directory: directory, legacyStore: UserDefaultsActiveWorkoutStore(defaults: defaults))
        try activeStore.save(snapshot)
        XCTAssertEqual(try activeStore.load(), snapshot)
        let historyStore = FileWorkoutHistoryStore(directory: directory, legacyStore: UserDefaultsWorkoutHistoryStore(defaults: defaults))
        let entry = WorkoutHistoryEntry(session: session)
        let oldSet = CompletedSet(load: Load(40, unit: .pounds), reps: 35, rir: 0,
                                  completedAt: Date(timeIntervalSince1970: 800))
        let oldPlan = ExercisePlan(exerciseID: "EX-PLANK", name: "Front Plank", targetLoad: Load(0),
            targetReps: RepRange(20, 45), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: [], sourcePrescription: "20-45 seconds")
        let oldSession = WorkoutSession(title: "Older log", programmeID: .zeroOneStart,
            exercises: [WorkoutExercise(plan: oldPlan, completedSets: [oldSet])],
            completedAt: Date(timeIntervalSince1970: 800))
        let oldEntry = WorkoutHistoryEntry(session: oldSession)
        try historyStore.save([entry, oldEntry])
        let restored = try XCTUnwrap(historyStore.load().first)
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.exercises?.first?.targetPrescription, session.exercises[0].plan.targetPrescription)
        XCTAssertEqual(restored.exercises?.first?.completedSets.first?.durationSeconds, 29)
        XCTAssertEqual(restored.exercises?.first?.completedSets.first?.load.unit, .pounds)
        XCTAssertEqual(restored.completedSetCount, 1)
        XCTAssertEqual(restored.plannedSetCount, 2)
        try activeStore.clear(expectedSessionID: session.id)
        XCTAssertNil(try activeStore.load())
        XCTAssertEqual(try historyStore.load(), [entry, oldEntry])
        let oldRestored = try XCTUnwrap(historyStore.load().last?.exercises?.first?.completedSets.first)
        XCTAssertNil(oldRestored.durationSeconds)
        XCTAssertNil(oldRestored.isPerSide)
        XCTAssertEqual(oldRestored, oldSet)
    }

    @MainActor
    func testTimedSetsDoNotEarnRepOrLoadProgressionClaims() throws {
        var session = timedSession(setCount: 1)
        _ = try session.completeCurrentSet(load: Load(5), reps: 0, durationSeconds: 45, at: .now)
        let entry = WorkoutHistoryEntry(session: session)
        let exercise = session.exercises[0]
        let performance = RecordedExercisePerformance(sessionID: session.id, sessionTitle: session.title,
            completedAt: session.completedAt!, occurrences: [WorkoutHistoryExercise(exercise: exercise)],
            hasNewerUnknownDetails: false)
        XCTAssertEqual(WorkoutProgressionEngine().plan(exercise.plan, using: [entry]), exercise.plan)
        XCTAssertNil(WorkoutProgressionEngine().opportunity(for: exercise.plan, previousPerformance: .recorded(performance)))
        XCTAssertNil(WorkoutSetResponse.evaluate(savedSet: exercise.completedSets[0], setNumber: 1,
            targetReps: exercise.plan.targetReps, previousPerformance: .recorded(performance)))
        XCTAssertNil(WorkoutExerciseComparison.evaluate(savedSets: exercise.completedSets, previousPerformance: .recorded(performance)))
        XCTAssertTrue(WorkoutSetAnnouncement.saved(setNumber: 1, set: exercise.completedSets[0], restSeconds: 0).contains("45 seconds"))
    }
}
extension WorkoutSessionTests {
    @MainActor
    func testTimedFailedSaveKeepsActualSetForRetryWithoutLoggingAnotherHold() throws {
        var rejectSetSave = true
        var disk: ActiveWorkoutSnapshot?
        let session = timedSession()
        let model = WorkoutViewModel(session: session, onSnapshotChanged: { snapshot, _ in
            if rejectSetSave && (snapshot?.session.completedSetCount ?? 0) > 0 {
                throw WorkoutPersistenceError.unavailable
            }
            disk = snapshot
        })
        model.durationDraft = "24"
        model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.session.completedSetCount, 1)
        let held = try XCTUnwrap(model.session.exercises[0].completedSets.first)
        XCTAssertEqual(held.durationSeconds, 24)
        XCTAssertEqual(disk?.session.completedSetCount, 0)
        rejectSetSave = false
        model.retryPersistence(at: Date(timeIntervalSince1970: 1_200))
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(disk?.session.exercises[0].completedSets.first, held)
        XCTAssertTrue(try XCTUnwrap(disk).isCompatible)
        XCTAssertEqual(model.durationDraft, "")
        model.acknowledgeNextSet()
        model.completeCurrentSet(at: Date(timeIntervalSince1970: 1_201))
        XCTAssertEqual(model.session.completedSetCount, 1)
    }
}
extension WorkoutSessionTests {
    func testAuthoredPerSideRepResultKeepsItsCountWithoutDoublingOrInferringLegacySides() throws {
        let plan = ExercisePlan(exerciseID: "EX-DEAD-BUG", name: "Dead Bug", targetLoad: Load(0),
            targetReps: RepRange(6, 10), plannedSetCount: 1, restSeconds: 0,
            previousPerformance: [],
            targetPrescription: WorkingSetPrescription(unit: .repetitions, lowerBound: 6, upperBound: 10, perSide: true))
        var session = WorkoutSession(title: "Per side", programmeID: .zeroOneStart,
                                     exercises: [WorkoutExercise(plan: plan)])
        _ = try session.completeCurrentSet(load: Load(0), reps: 7, at: .now)
        let set = try XCTUnwrap(session.exercises[0].completedSets.first)
        XCTAssertEqual(set.reps, 7)
        XCTAssertEqual(set.isPerSide, true)
        XCTAssertNil(set.durationSeconds)
        XCTAssertEqual(set.performanceText, "7 reps per side")
        let entry = WorkoutHistoryEntry(session: session)
        let decoded = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        let legacySet = CompletedSet(load: Load(0), reps: 7, completedAt: .now)
        let performance = RecordedExercisePerformance(sessionID: UUID(), sessionTitle: "Legacy", completedAt: .now,
            occurrences: [WorkoutHistoryExercise(exercise: WorkoutExercise(plan: plan, completedSets: [legacySet]))],
            hasNewerUnknownDetails: false)
        XCTAssertNil(WorkoutSetResponse.evaluate(savedSet: set, setNumber: 1, targetReps: plan.targetReps,
                                                 previousPerformance: .recorded(performance)))
    }
}