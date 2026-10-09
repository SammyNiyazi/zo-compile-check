import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutHistoryImportTests: XCTestCase {
    func testPreviewDoesNotWriteAndConfirmationPreservesAllExactRecordedValues() throws {
        let original = entry(title: "Existing")
        let imported = entry(title: "Imported", rir: -3, unit: .pounds, perSide: true)
        let store = ImportHistoryStore(entries: [original])
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([imported]))
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(review.appendedCount, 1)
        XCTAssertEqual(review.legacyEffortCount, 1)
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(result.confirmedEntries, [original, imported].sorted(by: WorkoutHistoryEntry.newestFirst))
        XCTAssertEqual(store.entries.first(where: { $0.id == imported.id }), imported)
        XCTAssertEqual(store.saves, 1)
    }

    func testExactDuplicatesSkipWithoutWriteIncludingMissingLegacyDetails() throws {
        let original = try summary(entry())
        let store = ImportHistoryStore(entries: [original])
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([original]))
        XCTAssertEqual(review.summaryOnlyCount, 1)
        XCTAssertEqual(review.appendedCount, 0)
        XCTAssertEqual(review.skippedCount, 1)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.saves, 0)
        XCTAssertNil(store.entries[0].exercises)
    }

    func testSummaryVersusDetailedIdentifierConflictDoesNotEnrichOrAppendOtherRecords() throws {
        let detailed = entry()
        let original = try summary(detailed)
        let store = ImportHistoryStore(entries: [original])
        XCTAssertThrowsError(try coordinator(store).prepare(data: package([entry(), detailed]))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .conflictingIdentifier)
        }
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(store.saves, 0)
    }

    func testChangedStoreAfterReviewRejectsAllWrites() throws {
        let store = ImportHistoryStore()
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([entry()]))
        let newExisting = entry()
        store.entries = [newExisting]
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyChanged)
        }
        XCTAssertEqual(store.entries, [newExisting])
        XCTAssertEqual(store.saves, 0)
        XCTAssertNil(coordinator.review)
    }

    func testChangedContentsWithSameIDInvalidateReview() throws {
        let original = entry()
        let store = ImportHistoryStore(entries: [original])
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([entry()]))
        store.entries = [try changing(original, key: "title", value: "Changed")]
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(store.saves, 0)
    }

    func testActiveOrRecoveryWorkoutBecomingBlockedAfterReviewPreventsSave() throws {
        let store = ImportHistoryStore()
        var allowed = true
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: { allowed })
        let review = try coordinator.prepare(data: package([entry()]))
        allowed = false
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .workoutInProgress)
        }
        XCTAssertEqual(store.saves, 0)
    }

    func testUnavailableRecoveryGateThrowsBeforeAnyHistoryWrite() throws {
        let store = ImportHistoryStore()
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: { throw CocoaError(.fileReadCorruptFile) })
        XCTAssertThrowsError(try coordinator.prepare(data: package([entry()])))
        XCTAssertEqual(store.saves, 0)
    }

    func testRejectedWriteRetainsReviewAndRetryWritesIdenticalExpectedCollection() throws {
        let original = entry()
        let imported = entry()
        let store = ImportHistoryStore(entries: [original])
        store.mode = .reject
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([imported]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertTrue(coordinator.needsReconciliation)
        XCTAssertEqual(store.entries, [original])
        store.mode = .normal
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(result.confirmedEntries.count, 2)
        XCTAssertEqual(store.saves, 2)
        XCTAssertFalse(coordinator.needsReconciliation)
    }

    func testWriteThatLandsThenThrowsIsConfirmedOnRetryWithoutAnotherWrite() throws {
        let store = ImportHistoryStore()
        store.mode = .landThenThrow
        let coordinator = coordinator(store)
        let imported = entry()
        let review = try coordinator.prepare(data: package([imported]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(store.entries, [imported])
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(result.confirmedEntries, [imported])
        XCTAssertEqual(store.saves, 1)
    }

    func testWriteWithFailedReadbackIsReconciledExactlyOnRetry() throws {
        let store = ImportHistoryStore()
        store.mode = .failReadback
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([entry()]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        store.unreadable = false
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.saves, 1)
    }

    func testDroppedWriteCannotPublishSuccessAndRetryUsesFreshStore() throws {
        let store = ImportHistoryStore()
        store.mode = .discard
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([entry()]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertTrue(store.entries.isEmpty)
        store.mode = .normal
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.saves, 2)
    }

    func testUnrelatedMutationAfterAmbiguousWriteDoesNotPassPartialReadback() throws {
        let store = ImportHistoryStore()
        store.mode = .landThenThrow
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([entry()]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        store.entries.append(entry())
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyChanged)
        }
        XCTAssertEqual(store.saves, 1)
        coordinator.discardReview()
        XCTAssertFalse(coordinator.needsReconciliation)
        XCTAssertEqual(store.entries.count, 2)
    }

    func testFreshReviewAfterProcessRestartSkipsPreviouslyLandedImport() throws {
        let imported = entry()
        let store = ImportHistoryStore()
        store.mode = .landThenThrow
        let first = coordinator(store)
        let review = try first.prepare(data: package([imported]))
        XCTAssertThrowsError(try first.confirm(reviewID: review.id))
        let next = coordinator(store)
        let repeated = try next.prepare(data: package([imported]))
        _ = try next.confirm(reviewID: repeated.id)
        XCTAssertEqual(repeated.skippedCount, 1)
        XCTAssertEqual(store.saves, 1)
    }

    func testLegacyAndTimedPerSideHistoryCoexistWithoutReinterpretation() throws {
        let legacy = try summary(entry())
        let timed = entry(timed: true, perSide: true)
        let store = ImportHistoryStore(entries: [legacy])
        let coordinator = coordinator(store)
        let review = try coordinator.prepare(data: package([timed]))
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.entries.first(where: { $0.id == timed.id }), timed)
        let set = try XCTUnwrap(timed.exercises?.first?.completedSets.first)
        XCTAssertEqual(set.durationSeconds, 45)
        XCTAssertEqual(set.reps, 0)
        XCTAssertNil(set.rir)
        XCTAssertEqual(set.isPerSide, true)
        XCTAssertNil(store.entries.first(where: { $0.id == legacy.id })?.exercises)
    }

    func testSchemasOneTwoAndThreeAcceptExactWorkoutProjection() throws {
        let imported = entry()
        for version in 1...3 {
            let source = try WorkoutHistoryImportDecoder.decode(package([imported], schema: version))
            XCTAssertEqual(source.entries, [imported])
            XCTAssertEqual(source.schemaVersion, version)
        }
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(package([imported], schema: LocalDataExportPackage.currentSchemaVersion + 1))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .unsupportedSchema)
        }
    }

    func testCurrentActualExportPackageIsAcceptedWithoutReadingOtherStores() throws {
        let imported = entry()
        let package = LocalDataExportPackage(exportedAt: Date(timeIntervalSinceReferenceDate: 2_000.5),
            completedWorkouts: [imported], bodyWeightReadings: [],
            selection: .init(mealsAndWater: false, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false),
            meals: nil, waterSnapshot: nil, outdoorActivities: nil, goalsAndPreferences: nil)
        let source = try WorkoutHistoryImportDecoder.decode(JSONEncoder().encode(package))
        XCTAssertEqual(source.entries, [imported])
        XCTAssertTrue(source.untouchedCategories.isEmpty)
    }

    func testProductionAtomicFileStoreAppendsAndPreservesLegacyFallbackRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try summary(entry())
        let imported = entry(timed: true, perSide: true)
        let legacy = ImportHistoryStore(entries: [original])
        let store = FileWorkoutHistoryStore(directory: directory, legacyStore: legacy)
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: { true })
        let review = try coordinator.prepare(data: package([imported]))
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(try store.load().sorted(by: WorkoutHistoryEntry.newestFirst), result.confirmedEntries)
        XCTAssertEqual(legacy.entries, [original])
        XCTAssertEqual(legacy.saves, 0)
        let restarted = WorkoutHistoryImportCoordinator(store: store, canImport: { true })
        let repeated = try restarted.prepare(data: package([original, imported]))
        XCTAssertEqual(repeated.appendedCount, 0)
        XCTAssertEqual(repeated.skippedCount, 2)
    }

    func testOtherSelectedCategoriesAreReportedWithoutRestoreOrFullPackageDecode() throws {
        var object = try packageObject([entry()])
        object["selection"] = ["workouts": true, "mealsAndWater": true, "bodyWeight": true,
            "outdoorActivities": true, "goalsAndPreferences": true]
        object["meals"] = ["unrecognized": "left untouched"]
        object["bodyWeightReadings"] = ["unrecognized": "left untouched"]
        object["outdoorActivities"] = ["unrecognized": "left untouched"]
        object["goalsAndPreferences"] = ["unrecognized": "left untouched"]
        let source = try WorkoutHistoryImportDecoder.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(source.untouchedCategories.count, 4)
        XCTAssertEqual(source.entries.count, 1)
    }

    func testDuplicateWorkoutIDsAndGlobalSetIDsRejectBeforeReview() throws {
        let imported = entry()
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(package([imported, imported])))
        let second = try changing(imported, key: "id", value: UUID().uuidString)
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(package([imported, second])))
    }

    func testMalformedCountsDatesAndLoadsRejectRatherThanOverflowOrInventFacts() throws {
        let imported = entry()
        for (key, value) in [("completedSetCount", Int.max as Any), ("plannedSetCount", Int.max as Any),
            ("completedAt", 1e100 as Any), ("completedSetCount", 2 as Any)] {
            XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(package([changing(imported, key: key, value: value)])))
        }
        var object = try entryObject(imported)
        var exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[0]["completedSets"] as? [[String: Any]])
        sets[0]["load"] = ["value": -4, "unit": "kg"]
        exercises[0]["completedSets"] = sets
        object["exercises"] = exercises
        XCTAssertThrowsError(try decodeEntryObject(object))
    }

    func testUnknownHistoryFieldsDuplicateJSONKeysAndDeepNestingReject() throws {
        let imported = entry()
        var object = try entryObject(imported)
        object["futureHealthFact"] = true
        XCTAssertThrowsError(try decodeEntryObject(object))
        let duplicate = Data(#"{"schemaVersion":3,"schemaVersion":1}"#.utf8)
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(duplicate))
        let escapedDuplicate = Data(#"{"schemaVersion":3,"schema\u0056ersion":1}"#.utf8)
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(escapedDuplicate))
        let deep = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(Data(deep.utf8)))
    }

    func testMalformedWarmUpCannotBeSilentlyNormalizedByHistoryDecoder() throws {
        var object = try entryObject(entry())
        object["warmUp"] = ["estimatedMinutes": 2, "steps": ["Prepare"],
            "timedStepSeconds": [-1], "length": "full", "status": "completed", "checkedStepIndices": [5]]
        XCTAssertThrowsError(try decodeEntryObject(object))
    }

    func testUnavailableOrDuplicateExistingHistoryBlocksWithoutWrite() throws {
        let imported = entry()
        let store = ImportHistoryStore(entries: [imported, imported])
        XCTAssertThrowsError(try coordinator(store).prepare(data: package([entry()]))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyUnavailable)
        }
        store.entries = []
        store.unreadable = true
        XCTAssertThrowsError(try coordinator(store).prepare(data: package([entry()])))
        XCTAssertEqual(store.saves, 0)
    }

    func testOversizedFileEmptyCorruptAndUnselectedHistoryFailClosed() throws {
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(Data(repeating: 32,
            count: WorkoutHistoryImportDecoder.maximumFileBytes + 1))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .oversizedFile)
        }
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(Data()))
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(Data("not JSON".utf8)))
        var object = try packageObject([entry()])
        object["selection"] = ["workouts": false, "mealsAndWater": false, "bodyWeight": false]
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .workoutsNotSelected)
        }
    }

    func testConfirmationRequiresTheSpecificReviewedIdentifier() throws {
        let store = ImportHistoryStore()
        let coordinator = coordinator(store)
        _ = try coordinator.prepare(data: package([entry()]))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: UUID()))
        XCTAssertEqual(store.saves, 0)
    }

    private func coordinator(_ store: ImportHistoryStore) -> WorkoutHistoryImportCoordinator {
        WorkoutHistoryImportCoordinator(store: store, canImport: { true })
    }

    private func entry(title: String = "Completed workout", rir: Int? = nil,
                       unit: LoadUnit = .kilograms, timed: Bool = false, perSide: Bool? = nil) -> WorkoutHistoryEntry {
        let set = CompletedSet(load: Load(42.125, unit: unit), reps: timed ? 0 : 8, rir: timed ? nil : rir,
            completedAt: Date(timeIntervalSinceReferenceDate: 1_000.25),
            durationSeconds: timed ? 45 : nil, isPerSide: perSide)
        let prescription = WorkingSetPrescription(unit: timed ? .seconds : .repetitions,
            lowerBound: timed ? 45 : 8, upperBound: timed ? 45 : 8, perSide: perSide == true)
        let plan = ExercisePlan(name: "Bench press", targetLoad: set.load, targetReps: RepRange(8, 8),
            plannedSetCount: 1, restSeconds: 90, previousPerformance: [], targetPrescription: prescription)
        return WorkoutHistoryEntry(session: WorkoutSession(title: title,
            exercises: [WorkoutExercise(plan: plan, completedSets: [set])],
            completedAt: Date(timeIntervalSinceReferenceDate: 1_100.75)))
    }

    private func entryObject(_ entry: WorkoutHistoryEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }

    private func changing(_ entry: WorkoutHistoryEntry, key: String, value: Any) throws -> WorkoutHistoryEntry {
        var object = try entryObject(entry)
        object[key] = value
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func summary(_ entry: WorkoutHistoryEntry) throws -> WorkoutHistoryEntry {
        var object = try entryObject(entry)
        object.removeValue(forKey: "exercises")
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func packageObject(_ entries: [WorkoutHistoryEntry], schema: Int = 3) throws -> [String: Any] {
        var object: [String: Any] = ["schemaVersion": schema, "exportedAt": 2_000.5,
            "workoutHistoryProvenance": "app-owned completed workout history",
            "completedWorkouts": try entries.map(entryObject)]
        if schema >= 2 { object["selection"] = ["workouts": true, "mealsAndWater": false, "bodyWeight": false] }
        return object
    }

    private func package(_ entries: [WorkoutHistoryEntry], schema: Int = 3) throws -> Data {
        try JSONSerialization.data(withJSONObject: packageObject(entries, schema: schema), options: [.sortedKeys])
    }

    private func decodeEntryObject(_ object: [String: Any]) throws -> WorkoutHistoryImportDecoder.Source {
        var package = try packageObject([])
        package["completedWorkouts"] = [object]
        return try WorkoutHistoryImportDecoder.decode(JSONSerialization.data(withJSONObject: package))
    }
}

private final class ImportHistoryStore: WorkoutHistoryPersisting {
    enum Mode { case normal, reject, discard, landThenThrow, failReadback }
    var entries: [WorkoutHistoryEntry]
    var mode = Mode.normal
    var saves = 0
    var unreadable = false
    init(entries: [WorkoutHistoryEntry] = []) { self.entries = entries }
    func load() throws -> [WorkoutHistoryEntry] {
        if unreadable { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }
    func save(_ entries: [WorkoutHistoryEntry]) throws {
        saves += 1
        switch mode {
        case .reject: throw CocoaError(.fileWriteNoPermission)
        case .discard: return
        case .normal: self.entries = entries
        case .landThenThrow:
            self.entries = entries
            throw CocoaError(.fileWriteUnknown)
        case .failReadback:
            self.entries = entries
            unreadable = true
        }
    }
}
