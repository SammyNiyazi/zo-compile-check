import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutRestTimerEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testFractionalPauseAndPausedExtensionKeepPreciseTransitionsThroughResume() throws {
        let store = RestEvidenceActiveStore()
        let model = model(store: store)
        model.completeCurrentSet(at: start)
        model.togglePause(at: start.addingTimeInterval(10.25))
        model.addRestSeconds(15, at: start.addingTimeInterval(20))
        model.togglePause(at: start.addingTimeInterval(40))
        XCTAssertEqual(try XCTUnwrap(model.session.restEndsAt).timeIntervalSince(start), 134.75, accuracy: 0.000_001)
        model.skipRest(at: start.addingTimeInterval(50))
        let rest = try observation(model.session)
        XCTAssertEqual(rest.events.map(\.kind), [.started, .paused, .extendedWhilePaused, .resumed, .skipped])
        XCTAssertEqual(rest.events[1].remainingSeconds, 79.75)
        XCTAssertEqual(rest.events[2].remainingSeconds, 94.75)
        XCTAssertTrue(rest.isClosed)
        XCTAssertEqual(try observation(XCTUnwrap(store.saved).session), rest)
        XCTAssertEqual(model.session.exercises[0].completedSets[0].executionTarget?.restSeconds, 90)
    }

    func testLateAutomaticExpiryKeepsDeadlineSeparateFromObservationAndManualSkip() throws {
        let automatic = model()
        automatic.completeCurrentSet(at: start)
        XCTAssertTrue(automatic.advanceElapsedRest(at: start.addingTimeInterval(120)))
        let ended = try XCTUnwrap(observation(automatic.session).events.last)
        XCTAssertEqual(ended.kind, .expired)
        XCTAssertEqual(ended.deadline, start.addingTimeInterval(90))
        XCTAssertEqual(ended.observedAt, start.addingTimeInterval(120))
        XCTAssertTrue(try observation(automatic.session).hasUnobservedGap)
        let manual = model()
        manual.completeCurrentSet(at: start)
        manual.skipRest(at: start.addingTimeInterval(20))
        XCTAssertEqual(try observation(manual.session).events.last?.kind, .skipped)
    }

    func testPausedExpiredAndSkippedTimerCanRestartWithExplicitGapEvidence() throws {
        for skipFirst in [false, true] {
            let model = model()
            model.completeCurrentSet(at: start)
            model.togglePause(at: start.addingTimeInterval(skipFirst ? 10 : 100))
            if skipFirst { model.skipRest(at: start.addingTimeInterval(20)) }
            model.addRestSeconds(15, at: start.addingTimeInterval(110))
            model.togglePause(at: start.addingTimeInterval(120))
            XCTAssertEqual(model.session.restEndsAt, start.addingTimeInterval(135))
            XCTAssertTrue(model.advanceElapsedRest(at: start.addingTimeInterval(135)))
            let rest = try observation(model.session)
            XCTAssertTrue(rest.events.contains(where: { $0.kind == .restartedWhilePaused }))
            XCTAssertTrue(rest.hasUnobservedGap)
            XCTAssertTrue(rest.isValid(for: model.session.exercises[0].completedSets[0].id, completedAt: start))
        }
    }

    func testUnacknowledgedSetSaveRecordsEachFullTimerRestartWithoutChangingSetTime() throws {
        let store = RestEvidenceActiveStore()
        let model = model(store: store)
        store.reject = true
        model.completeCurrentSet(at: start)
        model.retryPersistence(at: start.addingTimeInterval(100))
        store.reject = false
        model.retryPersistence(at: start.addingTimeInterval(120))
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.session.restEndsAt, start.addingTimeInterval(210))
        let rest = try observation(XCTUnwrap(store.saved).session)
        XCTAssertEqual(rest.events.map(\.kind), [.started, .restartedAfterSaveFailure, .restartedAfterSaveFailure])
        XCTAssertTrue(rest.hasUnobservedGap)
        XCTAssertEqual(model.session.exercises[0].completedSets[0].completedAt, start)
    }

    func testFailedExpiryWriteRetryKeepsCapturedEndpointWithoutRestartingTimer() throws {
        let store = RestEvidenceActiveStore()
        let model = model(store: store)
        model.completeCurrentSet(at: start)
        store.reject = true
        XCTAssertFalse(model.advanceElapsedRest(at: start.addingTimeInterval(91)))
        let captured = try observation(model.session)
        store.reject = false
        model.retryPersistence(at: start.addingTimeInterval(200))
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertNil(model.session.restEndsAt)
        XCTAssertEqual(try observation(XCTUnwrap(store.saved).session), captured)
        XCTAssertEqual(captured.events.last?.observedAt, start.addingTimeInterval(91))
    }

    func testPausedRelaunchRetainsExactRemainingAndMarksUnobservedRecovery() throws {
        let store = RestEvidenceActiveStore()
        let initial = model(store: store)
        initial.completeCurrentSet(at: start)
        initial.togglePause(at: start.addingTimeInterval(10.25))
        let snapshot = try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONEncoder().encode(XCTUnwrap(store.saved)))
        let recovered = WorkoutViewModel(session: snapshot.session, restoredSnapshot: snapshot,
            observationDate: start.addingTimeInterval(25), onSnapshotChanged: store.handle)
        recovered.togglePause(at: start.addingTimeInterval(60))
        XCTAssertEqual(try XCTUnwrap(recovered.session.restEndsAt).timeIntervalSince(start), 139.75, accuracy: 0.000_001)
        XCTAssertEqual(try observation(recovered.session).events.map(\.kind), [.started, .paused, .recovered, .resumed])
        XCTAssertTrue(try observation(recovered.session).hasUnobservedGap)
    }

    func testHandoffAcknowledgementAndEarlyFinishKeepDifferentClosureReasons() throws {
        let store = RestEvidenceActiveStore()
        let initial = model(store: store, session: session(sets: 1, secondExercise: true))
        initial.completeCurrentSet(at: start)
        var snapshot = try XCTUnwrap(store.saved)
        snapshot.resolveElapsedRest(at: start.addingTimeInterval(100))
        let recovered = WorkoutViewModel(session: snapshot.session, restoredSnapshot: snapshot,
            observationDate: start.addingTimeInterval(100), onSnapshotChanged: store.handle)
        recovered.acknowledgeNextSet(at: start.addingTimeInterval(110))
        XCTAssertEqual(try observation(recovered.session).events.last?.kind, .handoffAcknowledged)
        let early = model()
        early.completeCurrentSet(at: start)
        early.togglePause(at: start.addingTimeInterval(10))
        XCTAssertTrue(early.finishEarly(at: start.addingTimeInterval(20)))
        XCTAssertEqual(try observation(early.session).events.last?.kind, .workoutEnded)
    }

    func testUndoDropsOnlyTheRemovedSetsObservation() throws {
        let model = model(session: session(sets: 3))
        model.completeCurrentSet(at: start)
        model.skipRest(at: start.addingTimeInterval(20))
        let retained = model.session.exercises[0].completedSets[0]
        model.completeCurrentSet(at: start.addingTimeInterval(30))
        XCTAssertEqual(model.session.completedSetCount, 2)
        model.undoLastSet()
        XCTAssertEqual(model.session.exercises[0].completedSets, [retained])
        XCTAssertNil(model.session.restEndsAt)
    }

    func testZeroTimerAndFinalSetSayNotScheduledWithoutClaimingZeroPhysicalRest() throws {
        let model = model(session: session(sets: 2, rest: 0))
        model.completeCurrentSet(at: start)
        XCTAssertEqual(try observation(model.session).events.map(\.kind), [.notScheduled])
        model.acknowledgeNextSet(at: start.addingTimeInterval(10))
        model.completeCurrentSet(at: start.addingTimeInterval(20))
        XCTAssertEqual(model.session.exercises[0].completedSets.last?.restTimerObservation?.events.last?.kind, .notScheduled)
        XCTAssertNil(model.session.exercises[0].completedSets.last?.restTimerObservation?.events.last?.remainingSeconds)
    }

    func testActualHistoryMigrationReadsLegacyBytesWithoutEnrichmentAndWritesEnvelope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = try completedEntry()
        let legacy = try legacyData(entry)
        let url = root.appendingPathComponent("history.json")
        try legacy.write(to: url)
        let store = FileWorkoutHistoryStore(directory: root, legacyStore: RestEvidenceHistoryStore())
        let unknown = try store.load()
        XCTAssertNil(unknown[0].exercises?[0].completedSets[0].restTimerObservation)
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        let added = try completedEntry()
        try store.save(unknown + [added])
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try JSONDecoder().decode([WorkoutHistoryEntry].self, from: saved))
        XCTAssertEqual(try store.load(), unknown + [added])
        XCTAssertEqual(try store.load().first, unknown.first)
    }

    func testLegacyFormatsAndFutureUnknownTimerFactsCannotSilentlyStripEvidence() throws {
        let entry = try completedEntry()
        XCTAssertThrowsError(try WorkoutHistoryStorageCodec.decode(JSONEncoder().encode([entry])))
        var payload = try exportObject(entry)
        payload["schemaVersion"] = 4
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(JSONSerialization.data(withJSONObject: payload)))
        var snapshot = try snapshotObject()
        snapshot["version"] = 5
        XCTAssertFalse(try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONSerialization.data(withJSONObject: snapshot)).isCompatible)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkoutHistoryStorageCodec.encode([entry])) as? [String: Any])
        future["version"] = WorkoutHistoryStorageCodec.currentVersion + 1
        XCTAssertThrowsError(try WorkoutHistoryStorageCodec.decode(JSONSerialization.data(withJSONObject: future)))
        var rest = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observationEntry(entry))) as? [String: Any])
        rest["unverifiedRestScore"] = 100
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutRestTimerObservation.self,
            from: JSONSerialization.data(withJSONObject: rest)))
    }

    func testActualExportImportAndCSVPreserveJournalAndRejectKnownUnknownIdentityConflict() throws {
        let entry = try completedEntry()
        let source = RestEvidenceHistoryStore(entries: [entry])
        let json = try export(source)
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(json).entries, [entry])
        let destination = RestEvidenceHistoryStore()
        let coordinator = WorkoutHistoryImportCoordinator(store: destination, canImport: { true })
        let review = try coordinator.prepare(data: json)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(destination.entries, [entry])
        let csv = try XCTUnwrap(LocalDataExportFiles.make(from: json)["sets.csv"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(csv.contains("restTimerObservation.events"))
        XCTAssertTrue(csv.contains("skipped"))
        let unknown = try WorkoutHistoryStorageCodec.decode(legacyData(entry))
        let conflict = WorkoutHistoryImportCoordinator(store: RestEvidenceHistoryStore(entries: unknown), canImport: { true })
        XCTAssertThrowsError(try conflict.prepare(data: json)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .conflictingIdentifier)
        }
    }

    func testContradictoryDeadlineAndSetBindingAreRejectedWhileClockRollbackIsExplicit() throws {
        let entry = try completedEntry()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observationEntry(entry))) as? [String: Any])
        var events = try XCTUnwrap(raw["events"] as? [[String: Any]])
        events[0]["deadline"] = start.addingTimeInterval(-1).timeIntervalSinceReferenceDate
        raw["events"] = events
        let contradictory = try JSONDecoder().decode(WorkoutRestTimerObservation.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertFalse(contradictory.isValid(for: entry.exercises![0].completedSets[0].id, completedAt: start))
        let model = model()
        model.completeCurrentSet(at: start)
        model.togglePause(at: start.addingTimeInterval(-1))
        let rest = try observation(model.session)
        XCTAssertTrue(rest.events.contains(where: { $0.kind == .clockDiscontinuity }))
        XCTAssertTrue(rest.hasUnobservedGap)
        XCTAssertTrue(rest.isValid(for: model.session.exercises[0].completedSets[0].id, completedAt: start))
        XCTAssertFalse(rest.isValid(for: UUID(), completedAt: start))
    }

    func testBoundedJournalKeepsPausedStateAndPrecisionAfterMiddleTransitionsAreOmitted() throws {
        let model = model()
        model.completeCurrentSet(at: start)
        model.togglePause(at: start.addingTimeInterval(10.25))
        for index in 0..<600 { model.addRestSeconds(1, at: start.addingTimeInterval(20 + Double(index))) }
        model.togglePause(at: start.addingTimeInterval(700))
        XCTAssertEqual(try XCTUnwrap(model.session.restEndsAt).timeIntervalSince(start), 1_379.75, accuracy: 0.000_001)
        let rest = try observation(model.session)
        XCTAssertEqual(rest.events.count, WorkoutRestTimerObservation.maximumEvents)
        XCTAssertTrue(rest.hasOmittedTransitions)
        XCTAssertTrue(rest.hasUnobservedGap)
        XCTAssertEqual(rest.events.first?.kind, .started)
        XCTAssertEqual(rest.events.last?.kind, .resumed)
        XCTAssertTrue(rest.isValid(for: model.session.exercises[0].completedSets[0].id, completedAt: start))
    }

    private func session(sets: Int = 2, rest: TimeInterval = 90, secondExercise: Bool = false) -> WorkoutSession {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench press",
            targetLoad: Load(40), targetReps: RepRange(8, 10), plannedSetCount: sets,
            restSeconds: rest, previousPerformance: [], targetPrescription:
                WorkingSetPrescription(unit: .repetitions, lowerBound: 8, upperBound: 10))
        var exercises = [WorkoutExercise(plan: plan)]
        if secondExercise {
            exercises.append(WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.pushUp, name: "Push-up",
                targetLoad: Load(0), targetReps: RepRange(8, 10), plannedSetCount: 1, restSeconds: 0, previousPerformance: [])))
        }
        return WorkoutSession(title: "Timer evidence", programmeID: .zeroOneStart, exercises: exercises)
    }
    private func model(store: RestEvidenceActiveStore = RestEvidenceActiveStore(), session: WorkoutSession? = nil) -> WorkoutViewModel {
        WorkoutViewModel(session: session ?? self.session(), onSnapshotChanged: store.handle)
    }
    private func observation(_ session: WorkoutSession) throws -> WorkoutRestTimerObservation {
        try XCTUnwrap(session.exercises[0].completedSets.first?.restTimerObservation)
    }
    private func completedEntry() throws -> WorkoutHistoryEntry {
        let model = model()
        model.completeCurrentSet(at: start)
        model.skipRest(at: start.addingTimeInterval(30))
        model.completeCurrentSet(at: start.addingTimeInterval(50))
        return WorkoutHistoryEntry(session: model.session)
    }
    private func observationEntry(_ entry: WorkoutHistoryEntry) throws -> WorkoutRestTimerObservation {
        try XCTUnwrap(entry.exercises?[0].completedSets[0].restTimerObservation)
    }
    private func legacyData(_ entry: WorkoutHistoryEntry) throws -> Data {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var exercises = try XCTUnwrap(raw["exercises"] as? [[String: Any]])
        for index in exercises.indices {
            var sets = try XCTUnwrap(exercises[index]["completedSets"] as? [[String: Any]])
            for set in sets.indices { sets[set].removeValue(forKey: "restTimerObservation") }
            exercises[index]["completedSets"] = sets
        }
        raw["exercises"] = exercises
        return try JSONSerialization.data(withJSONObject: [raw], options: [.sortedKeys])
    }
    private func export(_ store: RestEvidenceHistoryStore) throws -> Data {
        try LocalDataExport(historyStore: store).createJSON(selection: .init(workouts: true, mealsAndWater: false,
            bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false), exportedAt: start.addingTimeInterval(100))
    }
    private func exportObject(_ entry: WorkoutHistoryEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: export(RestEvidenceHistoryStore(entries: [entry]))) as? [String: Any])
    }
    private func snapshotObject() throws -> [String: Any] {
        let store = RestEvidenceActiveStore()
        let model = model(store: store)
        model.completeCurrentSet(at: start)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(store.saved))) as? [String: Any])
    }
}

private final class RestEvidenceActiveStore {
    var saved: ActiveWorkoutSnapshot?
    var reject = false
    func handle(_ value: ActiveWorkoutSnapshot?, _ id: UUID) throws {
        if reject { throw WorkoutPersistenceError.unavailable }
        if let value, !value.isCompatible { throw WorkoutPersistenceError.invalidSnapshot }
        if let saved, saved.session.id != id { throw WorkoutPersistenceError.conflictingSession }
        saved = value
    }
}

private final class RestEvidenceHistoryStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry]
    init(entries: [WorkoutHistoryEntry] = []) { self.entries = entries }
    func load() throws -> [WorkoutHistoryEntry] { entries }
    func save(_ entries: [WorkoutHistoryEntry]) throws { self.entries = entries }
}
