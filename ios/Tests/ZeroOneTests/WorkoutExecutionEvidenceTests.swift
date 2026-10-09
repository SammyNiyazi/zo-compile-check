import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutExecutionEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 10_000)

    func testNewSetsCaptureExplicitTargetWithoutInventingEffortOrActualRest() throws {
        var session = makeSession(sets: 2)
        _ = try session.completeCurrentSet(load: Load(40), reps: 9, at: start)
        let set = try XCTUnwrap(session.exercises[0].completedSets.first)
        let target = try XCTUnwrap(set.executionTarget)
        XCTAssertEqual(target.prescription, session.exercises[0].plan.targetPrescription)
        XCTAssertEqual(target.plannedSetCount, 2)
        XCTAssertEqual(target.restSeconds, 120) // Target only; the next rest can be skipped.
        XCTAssertEqual(target.targetLoad, Load(40))
        XCTAssertEqual(set.isPerSide, false)
        XCTAssertNil(set.rir)
        session.skipRest()
        _ = try session.completeCurrentSet(load: Load(42), reps: 7, rir: 1, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.exercises[0].completedSets[1].executionTarget, target)
        XCTAssertEqual(session.exercises[0].completedSets[1].load, Load(42))
        XCTAssertEqual(session.exercises[0].completedSets[0].id, set.id)
        XCTAssertEqual(session.exercises[0].completedSets[0].load, set.load)
        XCTAssertEqual(session.exercises[0].completedSets[0].executionTarget, set.executionTarget)
        XCTAssertTrue(session.exercises[0].completedSets[0].restTimerObservation?.isClosed == true)
    }

    func testLegacyPlanDoesNotBecomeKnownBilateralOrAcquireAnExecutionTarget() throws {
        var session = makeSession(explicit: false)
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: start)
        let set = try XCTUnwrap(session.exercises[0].completedSets.first)
        XCTAssertNil(set.isPerSide)
        XCTAssertNil(set.executionTarget)
        XCTAssertNil(set.rir)
        XCTAssertNil(session.executionCompletionConfirmedAt)
    }

    func testTimedPerSideResultRetainsActualSecondsAndAuthoredTargetSeparately() throws {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Timed fixture",
            targetLoad: Load(0), targetReps: RepRange(8, 10), plannedSetCount: 1,
            restSeconds: 120, previousPerformance: [], targetPrescription:
                WorkingSetPrescription(unit: .seconds, lowerBound: 30, upperBound: 45, perSide: true))
        var session = WorkoutSession(title: "Timed", programmeID: .zeroOneStart, exercises: [WorkoutExercise(plan: plan)])
        _ = try session.completeCurrentSet(load: Load(0), reps: 0, durationSeconds: 23, at: start)
        let set = try XCTUnwrap(session.exercises[0].completedSets.first)
        XCTAssertEqual(set.durationSeconds, 23)
        XCTAssertEqual(set.executionTarget?.prescription.lowerBound, 30)
        XCTAssertEqual(set.isPerSide, true)
        XCTAssertNil(set.rir)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(session)), session)
    }

    func testLaterPlanChangeCannotRewriteTargetsCapturedWithPerformedSets() throws {
        var session = makeSession(sets: 2)
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: start)
        session.skipRest(at: start.addingTimeInterval(0.5))
        let first = session.exercises[0].completedSets[0]
        let old = session.exercises[0].plan
        let changed = ExercisePlan(id: old.id, exerciseID: old.exerciseID, name: old.name,
            targetLoad: Load(42), targetReps: RepRange(6, 8), plannedSetCount: 2,
            restSeconds: 180, previousPerformance: [], targetPrescription:
                WorkingSetPrescription(unit: .repetitions, lowerBound: 6, upperBound: 8))
        var revised = WorkoutSession(id: session.id, title: session.title, programmeID: .zeroOneStart,
            exercises: [WorkoutExercise(plan: changed, completedSets: [first])])
        _ = try revised.completeCurrentSet(load: Load(42), reps: 8, at: start.addingTimeInterval(1))
        let entry = WorkoutHistoryEntry(session: revised)
        XCTAssertEqual(entry.exercises?[0].completedSets[0], first)
        XCTAssertEqual(first.executionTarget?.restSeconds, 120)
        XCTAssertEqual(entry.exercises?[0].completedSets[1].executionTarget?.restSeconds, 180)
        XCTAssertNotEqual(entry.exercises?[0].completedSets[0].executionTarget,
                          entry.exercises?[0].completedSets[1].executionTarget)
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(package(entry)).entries, [entry])
    }

    func testActualLoadUnitAndTargetUnitRemainIndependentThroughRecoveryAndTransfer() throws {
        var session = makeSession()
        _ = try session.completeCurrentSet(load: Load(85, unit: .pounds), reps: 8, at: start)
        let set = session.exercises[0].completedSets[0]
        XCTAssertEqual(set.load, Load(85, unit: .pounds))
        XCTAssertEqual(set.executionTarget?.targetLoad, Load(40, unit: .kilograms))
        let restored = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
        let snapshot = ActiveWorkoutSnapshot(session: restored, enteredLoadValue: 85, enteredReps: 8,
            enteredRIR: nil, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        XCTAssertTrue(snapshot.isCompatible)
        let entry = WorkoutHistoryEntry(session: restored)
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(package(entry)).entries, [entry])
    }

    func testExecutionMetadataUsesNewRecoveryVersionAndFutureSnapshotsStayUnsupported() throws {
        let session = try completedSession()
        let snapshot = ActiveWorkoutSnapshot(session: session, enteredLoadValue: 40, enteredReps: 10,
            enteredRIR: 2, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        XCTAssertEqual(snapshot.version, ActiveWorkoutSnapshot.currentVersion)
        XCTAssertTrue(snapshot.isCompatible)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        future["version"] = ActiveWorkoutSnapshot.currentVersion + 1
        let decoded = try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONSerialization.data(withJSONObject: future))
        XCTAssertFalse(decoded.isCompatible)
        XCTAssertEqual(decoded.session.exercises[0].completedSets, session.exercises[0].completedSets)
    }

    func testFullConfirmationIsExplicitIdempotentAndClearedWhenFinalSetIsUndone() throws {
        var session = try completedSession()
        XCTAssertEqual(WorkoutHistoryEntry(session: session).executionCompleteness, .unknown)
        XCTAssertFalse(session.confirmCompletedExecution(at: start.addingTimeInterval(-1)))
        let confirmation = start.addingTimeInterval(20)
        XCTAssertTrue(session.confirmCompletedExecution(at: confirmation))
        XCTAssertTrue(session.confirmCompletedExecution(at: confirmation.addingTimeInterval(10)))
        XCTAssertEqual(session.executionCompletionConfirmedAt, confirmation)
        XCTAssertEqual(WorkoutHistoryEntry(session: session).executionCompleteness, .confirmedComplete)
        XCTAssertNotNil(session.undoLastSet(reopeningFinalSet: true))
        XCTAssertNil(session.executionCompletionConfirmedAt)
        XCTAssertFalse(session.isComplete)
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: confirmation.addingTimeInterval(11))
        XCTAssertNil(session.executionCompletionConfirmedAt)
    }

    func testEarlyFinishCannotAcquireWholeExecutionConfirmation() throws {
        var session = makeSession(sets: 2)
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: start)
        XCTAssertTrue(session.finishEarly(at: start.addingTimeInterval(2)))
        XCTAssertFalse(session.confirmCompletedExecution(at: start.addingTimeInterval(3)))
        let entry = WorkoutHistoryEntry(session: session)
        XCTAssertEqual(entry.executionCompleteness, .partial)
        XCTAssertNil(entry.executionCompletionConfirmedAt)
        var forged = try object(entry)
        forged["executionCompletionConfirmedAt"] = start.addingTimeInterval(3).timeIntervalSinceReferenceDate
        XCTAssertThrowsError(try decode(forged))
    }

    func testActualFinalReviewAndFailedHistoryWriteSurviveRelaunchWithoutAnotherSet() throws {
        let store = ExecutionEvidenceHistoryStore()
        store.rejectSave = true
        let history = WorkoutHistoryRepository(store: store)
        var saved: ActiveWorkoutSnapshot?
        let viewModel = WorkoutViewModel(session: makeSession(), requiresFinalSetReview: true,
            onSnapshotChanged: { value, _ in saved = value }, onSessionCompleted: history.record)
        viewModel.completeCurrentSet(at: start)
        XCTAssertNil(viewModel.session.executionCompletionConfirmedAt)
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
        viewModel.confirmFinalSetAndFinish(at: start.addingTimeInterval(1))
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        let recovery = try XCTUnwrap(saved)
        XCTAssertEqual(recovery.session.executionCompletionConfirmedAt, start.addingTimeInterval(1))
        let decoded = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(recovery))
        XCTAssertTrue(decoded.isCompatible)
        XCTAssertEqual(decoded, recovery)
        store.rejectSave = false
        let relaunchedHistory = WorkoutHistoryRepository(store: store)
        let restored = WorkoutViewModel(session: decoded.session, restoredSnapshot: decoded,
            requiresFinalSetReview: true, onSnapshotChanged: { value, _ in saved = value },
            onSessionCompleted: relaunchedHistory.record)
        XCTAssertTrue(restored.isCompletionSaved)
        XCTAssertNil(saved)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].completedSetCount, 1)
        XCTAssertEqual(store.entries[0].executionCompletionConfirmedAt, start.addingTimeInterval(1))
        guard case let .recorded(performance) = relaunchedHistory.previousPerformance(for: ExerciseIDs.barbellBenchPress) else {
            return XCTFail("Acknowledged history was not projected.")
        }
        XCTAssertEqual(performance.executionCompleteness, .confirmedComplete)
        XCTAssertEqual(performance.executionCompletionConfirmedAt, start.addingTimeInterval(1))
    }

    func testFailedFinalSnapshotAndInvalidReviewTimeCannotDismissTheReview() throws {
        var rejectSnapshot = false
        let viewModel = WorkoutViewModel(session: makeSession(), requiresFinalSetReview: true,
            onSnapshotChanged: { _, _ in if rejectSnapshot { throw WorkoutPersistenceError.unavailable } })
        rejectSnapshot = true
        viewModel.completeCurrentSet(at: start)
        viewModel.confirmFinalSetAndFinish(at: start.addingTimeInterval(1))
        XCTAssertNil(viewModel.session.executionCompletionConfirmedAt)
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
        rejectSnapshot = false
        viewModel.retryPersistence(at: start.addingTimeInterval(2))
        viewModel.confirmFinalSetAndFinish(at: start.addingTimeInterval(-1))
        XCTAssertNil(viewModel.session.executionCompletionConfirmedAt)
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
    }

    func testActualJSONExportImportAndCSVKeepExecutionEvidenceExactly() throws {
        var session = try completedSession()
        XCTAssertTrue(session.confirmCompletedExecution(at: start.addingTimeInterval(20)))
        let entry = WorkoutHistoryEntry(session: session)
        let original = ExecutionEvidenceHistoryStore(entries: [entry])
        let selection = LocalDataExportSelection(workouts: true, mealsAndWater: false, bodyWeight: false,
            outdoorActivities: false, goalsAndPreferences: false)
        let data = try LocalDataExport(historyStore: original).createJSON(selection: selection,
            exportedAt: start.addingTimeInterval(30))
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(data).entries, [entry])
        let destination = ExecutionEvidenceHistoryStore()
        let coordinator = WorkoutHistoryImportCoordinator(store: destination, canImport: { true })
        let review = try coordinator.prepare(data: data)
        _ = try coordinator.confirm(reviewID: review.id)
        let exportedAgain = try LocalDataExport(historyStore: destination).createJSON(selection: selection,
            exportedAt: start.addingTimeInterval(40))
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(exportedAgain).entries, [entry])
        let files = try LocalDataExportFiles.make(from: data)
        let setsCSV = try XCTUnwrap(files["sets.csv"].flatMap { String(data: $0, encoding: .utf8) })
        let workoutsCSV = try XCTUnwrap(files["workouts.csv"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(setsCSV.contains("executionTarget.occurrenceID"))
        XCTAssertTrue(setsCSV.contains("executionTarget.prescription.upperBound"))
        XCTAssertTrue(setsCSV.contains(session.exercises[0].id.uuidString))
        XCTAssertTrue(workoutsCSV.contains("executionCompletionConfirmedAt"))
        XCTAssertEqual(destination.entries, [entry])
    }

    func testStrictImportRejectsUnknownNestedFieldsAndWrongOccurrenceIdentity() throws {
        let entry = WorkoutHistoryEntry(session: try completedSession())
        var root = try object(entry)
        var exercises = try XCTUnwrap(root["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[0]["completedSets"] as? [[String: Any]])
        var target = try XCTUnwrap(sets[0]["executionTarget"] as? [String: Any])
        target["unknownSafetyScore"] = 100
        sets[0]["executionTarget"] = target
        exercises[0]["completedSets"] = sets
        root["exercises"] = exercises
        XCTAssertThrowsError(try decode(root))
        target.removeValue(forKey: "unknownSafetyScore")
        target["occurrenceID"] = UUID().uuidString
        sets[0]["executionTarget"] = target
        exercises[0]["completedSets"] = sets
        root["exercises"] = exercises
        XCTAssertThrowsError(try decode(root))
        target["occurrenceID"] = entry.exercises![0].id.uuidString
        target["restSeconds"] = -1
        sets[0]["executionTarget"] = target
        exercises[0]["completedSets"] = sets
        root["exercises"] = exercises
        XCTAssertThrowsError(try decode(root))
    }

    func testLegacyPayloadRemainsUnknownAndRawEffortSurvivesLosslessTransfer() throws {
        var root = try object(WorkoutHistoryEntry(session: try completedSession()))
        root.removeValue(forKey: "executionCompletionConfirmedAt")
        var exercises = try XCTUnwrap(root["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[0]["completedSets"] as? [[String: Any]])
        for index in sets.indices {
            sets[index].removeValue(forKey: "executionTarget")
            sets[index].removeValue(forKey: "isPerSide")
            sets[index].removeValue(forKey: "restTimerObservation")
            sets[index]["rir"] = -3
        }
        exercises[0]["completedSets"] = sets
        root["exercises"] = exercises
        let legacy = try XCTUnwrap(decode(root).entries.first)
        XCTAssertEqual(legacy.executionCompleteness, .unknown)
        XCTAssertNil(legacy.executionCompletionConfirmedAt)
        XCTAssertNil(legacy.exercises?[0].completedSets[0].executionTarget)
        XCTAssertNil(legacy.exercises?[0].completedSets[0].isPerSide)
        XCTAssertEqual(legacy.exercises?[0].completedSets[0].rir, -3)
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(package(legacy)).entries, [legacy])
    }

    func testDuplicateConfirmationIsExactAndLegacyHistoryIsNeverEnrichedOnRetry() throws {
        var session = try completedSession()
        let original = WorkoutHistoryEntry(session: session)
        let store = ExecutionEvidenceHistoryStore(entries: [original])
        XCTAssertTrue(session.confirmCompletedExecution(at: start.addingTimeInterval(20)))
        let history = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try history.record(session), .alreadyRecorded)
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(store.saves, 0)
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: { true })
        let duplicate = try coordinator.prepare(data: package(original))
        XCTAssertEqual(duplicate.skippedCount, 1)
        coordinator.discardReview()
        XCTAssertThrowsError(try coordinator.prepare(data: package(WorkoutHistoryEntry(session: session)))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .conflictingIdentifier)
        }
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(store.saves, 0)
    }

    private func makeSession(sets: Int = 1, explicit: Bool = true) -> WorkoutSession {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench press",
            targetLoad: Load(40), targetReps: RepRange(8, 10), plannedSetCount: sets,
            restSeconds: 120, previousPerformance: [], targetPrescription: explicit
                ? WorkingSetPrescription(unit: .repetitions, lowerBound: 8, upperBound: 10) : nil)
        return WorkoutSession(title: "Evidence", programmeID: .zeroOneStart, exercises: [WorkoutExercise(plan: plan)])
    }

    private func completedSession() throws -> WorkoutSession {
        var session = makeSession()
        _ = try session.completeCurrentSet(load: Load(40), reps: 10, rir: 2, at: start)
        return session
    }

    private func object(_ entry: WorkoutHistoryEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }

    private func package(_ entry: WorkoutHistoryEntry) throws -> Data { try packageObject(object(entry)) }

    private func packageObject(_ entry: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": LocalDataExportPackage.currentSchemaVersion,
            "exportedAt": start.addingTimeInterval(30).timeIntervalSinceReferenceDate,
            "workoutHistoryProvenance": "app-owned completed workout history",
            "selection": ["workouts": true, "mealsAndWater": false, "bodyWeight": false],
            "completedWorkouts": [entry]], options: [.sortedKeys])
    }

    private func decode(_ entry: [String: Any]) throws -> WorkoutHistoryImportDecoder.Source {
        try WorkoutHistoryImportDecoder.decode(packageObject(entry))
    }
}

private final class ExecutionEvidenceHistoryStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry]
    var rejectSave = false
    private(set) var saves = 0
    init(entries: [WorkoutHistoryEntry] = []) { self.entries = entries }
    func load() throws -> [WorkoutHistoryEntry] { entries }
    func save(_ entries: [WorkoutHistoryEntry]) throws {
        if rejectSave { throw WorkoutPersistenceError.unavailable }
        saves += 1
        self.entries = entries
    }
}
