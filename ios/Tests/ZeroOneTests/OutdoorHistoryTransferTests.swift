import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class OutdoorHistoryTransferTests: XCTestCase {
    func testFullLocalExportImportRoundTripPreservesRawRoutesStepsGapsOptionalFlagsAndDates() async throws {
        let sourceDirectory = try temporaryDirectory()
        let targetDirectory = try temporaryDirectory()
        defer { cleanup(sourceDirectory, targetDirectory) }
        let full = record()
        let unknown = record(timerOnly: true)
        try seed([full, unknown], at: sourceDirectory)
        let source = OutdoorActivityRepository(directory: sourceDirectory)
        let exportReview = try await source.prepareHistoryExport()
        let bytesBefore = try historyData(sourceDirectory)
        let data = try await source.confirmHistoryExport(reviewID: exportReview.id, acknowledgesRouteData: true)
        XCTAssertEqual(try historyData(sourceDirectory), bytesBefore)
        let package = try OutdoorHistoryTransferDecoder.decode(data)
        XCTAssertEqual(package.records, [full, unknown])
        let target = OutdoorActivityRepository(directory: targetDirectory)
        let review = try await target.prepareHistoryImport(package)
        XCTAssertEqual(review.coordinateCount, 4)
        XCTAssertEqual(review.records[0].steps, full.steps)
        XCTAssertEqual(review.records[0].route, full.route)
        XCTAssertEqual(review.records[0].route?.segments[0].endsAtUserPause, true)
        XCTAssertNil(review.records[0].route?.segments[1].endsAtUserPause)
        XCTAssertNil(review.records[1].recordedDistanceMeters)
        XCTAssertNil(review.records[1].recordedSteps)
        let result = try await target.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true)
        XCTAssertEqual(result.confirmedRecords, [full, unknown])
        let reloaded = try await OutdoorActivityRepository(directory: targetDirectory).loadRecords()
        XCTAssertEqual(reloaded, [full, unknown])
        XCTAssertEqual(reloaded[0].route?.segments.map(\.id), full.route?.segments.map(\.id))
        XCTAssertEqual(reloaded[0].steps.intervals.map(\.id), full.steps.intervals.map(\.id))
    }

    func testBothExportAndImportRequireRouteAcknowledgementEvenForUnknownEmptyRoutes() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let export = try await repository.prepareHistoryExport()
        do { _ = try await repository.confirmHistoryExport(reviewID: export.id, acknowledgesRouteData: false); XCTFail("Requires route acknowledgement") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .routeAcknowledgementRequired) }
        let review = try await repository.prepareHistoryImport(.init(records: [record(timerOnly: true)]))
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: false); XCTFail("Requires route acknowledgement") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .routeAcknowledgementRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outdoor-history.json").path))
    }

    func testReviewAndDiscardNeverWriteOrCreateHistory() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let review = try await repository.prepareHistoryImport(.init(records: [record()]))
        try await repository.discardHistoryTransferReview(reviewID: review.id)
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Discarded review cannot confirm") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .reviewExpired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outdoor-history.json").path))
    }

    func testExactDuplicatesInFileAndSavedCollectionSkipWithoutWriteOrNotification() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let original = record()
        try seed([original], at: directory)
        let bytes = try historyData(directory)
        let counter = TransferNotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .outdoorHistoryDidChange, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let repository = OutdoorActivityRepository(directory: directory)
        let review = try await repository.prepareHistoryImport(.init(records: [original, original]))
        XCTAssertEqual(review.appendedCount, 0)
        XCTAssertEqual(review.skippedCount, 2)
        XCTAssertEqual(review.rows.map(\.record), [original, original])
        XCTAssertEqual(Set(review.rows.map(\.id)).count, 2, "Duplicate source rows need separate stable review controls")
        _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true)
        XCTAssertEqual(try historyData(directory), bytes)
        XCTAssertEqual(counter.value, 0)
    }

    func testSameIDConflictRejectsEntireFileWithoutAppendingAnyRows() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let original = record()
        var deleted = original
        deleted.route = nil; deleted.routeDeletedAt = original.finishedAt.addingTimeInterval(1)
        try seed([original], at: directory)
        let bytes = try historyData(directory)
        let repository = OutdoorActivityRepository(directory: directory)
        do { _ = try await repository.prepareHistoryImport(.init(records: [record(), deleted])); XCTFail("Conflicting ID must block every row") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .conflictingIdentifier) }
        XCTAssertEqual(try historyData(directory), bytes)
    }

    func testSourceIDConflictsAndRouteResurrectionAreRejectedWhileDeletedRecordRoundTrips() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let original = record()
        var deleted = original
        deleted.route = nil; deleted.routeDeletedAt = original.finishedAt.addingTimeInterval(1.1234567)
        try seed([deleted], at: directory)
        let repository = OutdoorActivityRepository(directory: directory)
        let export = try await repository.prepareHistoryExport()
        let data = try await repository.confirmHistoryExport(reviewID: export.id, acknowledgesRouteData: true)
        XCTAssertEqual(try OutdoorHistoryTransferDecoder.decode(data).records, [deleted])
        do { _ = try await repository.prepareHistoryImport(.init(records: [original])); XCTFail("Cannot resurrect deleted route") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .conflictingIdentifier) }
        do { _ = try await repository.prepareHistoryImport(.init(records: [record(), original, deleted])); XCTFail("Conflict blocks category") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .conflictingIdentifier) }
        let records = try await repository.loadRecords()
        XCTAssertEqual(records, [deleted])
    }

    func testFreshActorCheckpointBlocksPreparationConfirmationExportAndReconciliation() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let fault = TransferFaultState(.afterWrite)
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { try fault.call($0) })
        let review = try await repository.prepareHistoryImport(.init(records: [record(timerOnly: true)]))
        try seedCheckpoint(at: directory)
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("New active state must block") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .outdoorInProgress) }
        do { _ = try await repository.prepareHistoryExport(); XCTFail("Export must also block active state") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .outdoorInProgress) }
        let activeURL = directory.appendingPathComponent("active-outdoor.json")
        let checkpointBytes = try Data(contentsOf: activeURL)
        do { _ = try await repository.prepareHistoryImport(.init(records: [record()])); XCTFail("Preparation must block") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .outdoorInProgress) }
        XCTAssertEqual(try Data(contentsOf: activeURL), checkpointBytes)
        try Data("null".utf8).write(to: activeURL)
        let retry = try await repository.prepareHistoryImport(.init(records: [record(timerOnly: true)]))
        do { _ = try await repository.confirmHistoryImport(reviewID: retry.id, acknowledgesRouteData: true); XCTFail("Fault must prevent success") } catch {}
        try seedCheckpoint(at: directory)
        do { _ = try await repository.reconcileHistoryImport(reviewID: retry.id); XCTFail("Recovery must respect checkpoint") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .outdoorInProgress) }
        XCTAssertEqual(fault.writeCount, 1)
    }

    func testConcurrentRecorderStartWinsOrRunsAfterSerializedConfirmationWithoutCheckpointClear() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let imported = record(timerOnly: true)
        let review = try await repository.prepareHistoryImport(.init(records: [imported]))
        let recorder = OutdoorActivityRecorder(repository: repository)
        async let start = recorder.start(kind: .walk, trackingMode: .timerOnly, at: Date(timeIntervalSinceReferenceDate: 2_000_000))
        var didImport = false
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); didImport = true }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .outdoorInProgress) }
        let checkpoint = try await start
        let storedCheckpoint = try await repository.loadCheckpoint()
        let records = try await repository.loadRecords()
        XCTAssertEqual(storedCheckpoint, checkpoint)
        XCTAssertEqual(records, didImport ? [imported] : [])
    }

    func testFreshStrengthGateBlocksCoordinatorConfirmWithoutAnyFileWrite() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        var allowed = true
        let repository = OutdoorActivityRepository(directory: directory)
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: { allowed })
        let review = try await coordinator.prepareImport(data: package([record()]))
        allowed = false
        do { _ = try await coordinator.confirmImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Fresh app gate must block") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .appGateBlocked) }
        let records = try await repository.loadRecords()
        XCTAssertEqual(records, [])
        do { _ = try await coordinator.prepareExport(); XCTFail("Export app gate must block") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .appGateBlocked) }
    }

    func testCoordinatorChecksGateAgainAfterOffActorDecodingBeforePreparingActorReview() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        var gateCalls = 0
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: {
            gateCalls += 1
            return gateCalls == 1
        })
        do { _ = try await coordinator.prepareImport(data: package([record()])); XCTFail("Changed gate must block after decoding") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .appGateBlocked) }
        XCTAssertEqual(gateCalls, 2)
        XCTAssertNil(coordinator.review)
        let records = try await repository.loadRecords()
        XCTAssertEqual(records, [])
    }

    func testCoordinatorReflectsAmbiguousActorStateAndCannotReplayConfirmation() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let fault = TransferFaultState(.afterWrite)
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { try fault.call($0) })
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: { true })
        let incoming = record()
        let review = try await coordinator.prepareImport(data: package([incoming]))
        do { _ = try await coordinator.confirmImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Ambiguous actor state") } catch {}
        XCTAssertTrue(coordinator.needsReconciliation)
        XCTAssertNotNil(coordinator.review)
        do { _ = try await coordinator.confirmImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("No replay") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        let result = try await coordinator.reconcile(reviewID: review.id)
        XCTAssertEqual(result?.confirmedRecords, [incoming])
        XCTAssertEqual(fault.writeCount, 1)
        XCTAssertFalse(coordinator.needsReconciliation)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.review)
    }

    func testTransferFaultSeamDoesNotChangeOrdinaryRecorderFinishOrDeleteOperations() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let fault = TransferFaultState(.beforeWrite)
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { try fault.call($0) })
        let recorder = OutdoorActivityRecorder(repository: repository)
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let monotonic = ContinuousClock.now
        _ = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: start, monotonic: monotonic)
        let outcome = try await recorder.finish(at: start.addingTimeInterval(15), monotonic: monotonic.advanced(by: .seconds(15)))
        guard case let .saved(saved) = outcome else { return XCTFail("Ordinary finish must save") }
        let deletedRoute = try await repository.deleteRoute(for: saved.id, at: start.addingTimeInterval(20))
        XCTAssertNil(deletedRoute.route)
        XCTAssertEqual(deletedRoute.routeDeletedAt, start.addingTimeInterval(20))
        let removed = try await repository.deleteSession(saved.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(fault.writeCount, 0)
    }

    func testChangedWholeCollectionInvalidatesImportAndExportEvenIfIncomingIDsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let original = record(timerOnly: true)
        try seed([original], at: directory)
        let repository = OutdoorActivityRepository(directory: directory)
        let review = try await repository.prepareHistoryImport(.init(records: [record()]))
        let third = record(timerOnly: true)
        try seed([original, third], at: directory)
        let freshBytes = try historyData(directory)
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Changed baseline blocks write") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .storeChanged) }
        XCTAssertEqual(try historyData(directory), freshBytes)
        let export = try await repository.prepareHistoryExport()
        try seed([original], at: directory)
        do { _ = try await repository.confirmHistoryExport(reviewID: export.id, acknowledgesRouteData: true); XCTFail("Stale export blocks disclosure") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .storeChanged) }
    }

    func testWriteLandedThenAcknowledgementThrowsRequiresOnceOnlyReadOnlyReconciliation() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let fault = TransferFaultState(.afterWrite)
        let counter = TransferNotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .outdoorHistoryDidChange, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { try fault.call($0) })
        let incoming = record()
        let review = try await repository.prepareHistoryImport(.init(records: [incoming]))
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Ambiguous write is not success") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(fault.writeCount, 1)
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("No replay") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        do { _ = try await repository.prepareHistoryImport(.init(records: [incoming])); XCTFail("Reconciliation required") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        let result = try await repository.reconcileHistoryImport(reviewID: review.id)
        XCTAssertEqual(result?.confirmedRecords, [incoming])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(fault.writeCount, 1)
        do { _ = try await repository.reconcileHistoryImport(reviewID: review.id); XCTFail("Cannot notify twice") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .reviewExpired) }
        XCTAssertEqual(counter.value, 1)
    }

    func testFailedReadbackRetainsUnconfirmedReviewUntilReadableRecoveryWithoutAnotherWrite() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let historyURL = directory.appendingPathComponent("outdoor-history.json")
        let counter = TransferNotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .outdoorHistoryDidChange, object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            if phase == .beforeReadback { try Data("corrupt readback".utf8).write(to: historyURL) }
        })
        let incoming = record()
        let review = try await repository.prepareHistoryImport(.init(records: [incoming]))
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Readback fails") } catch {}
        do { _ = try await repository.reconcileHistoryImport(reviewID: review.id); XCTFail("Corrupt state cannot confirm") } catch {}
        do { try await repository.discardHistoryTransferReview(reviewID: review.id); XCTFail("Must read saved state before discard") } catch {}
        XCTAssertEqual(counter.value, 0)
        try seed([incoming], at: directory)
        let result = try await repository.reconcileHistoryImport(reviewID: review.id)
        XCTAssertEqual(result?.confirmedRecords, [incoming])
        XCTAssertEqual(counter.value, 1)
    }

    func testRejectedWriteRecoveryReadsBaselineAndRequiresFreshReview() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            if phase == .beforeWrite { throw CocoaError(.fileWriteUnknown) }
        })
        let review = try await repository.prepareHistoryImport(.init(records: [record()]))
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Write rejected") } catch {}
        let result = try await repository.reconcileHistoryImport(reviewID: review.id)
        XCTAssertNil(result)
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("New review needed") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .reviewExpired) }
    }

    func testThirdCollectionAfterUnconfirmedWriteDoesNotConfirmOrOverwrite() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            if phase == .afterWrite { throw CocoaError(.fileWriteUnknown) }
        })
        let incoming = record()
        let review = try await repository.prepareHistoryImport(.init(records: [incoming]))
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Ambiguous") } catch {}
        let third = record(timerOnly: true)
        try seed([incoming, third], at: directory)
        let freshBytes = try historyData(directory)
        do { _ = try await repository.reconcileHistoryImport(reviewID: review.id); XCTFail("Third state must not confirm") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .storeChanged) }
        XCTAssertEqual(try historyData(directory), freshBytes)
        try await repository.discardHistoryTransferReview(reviewID: review.id)
        let fresh = try await repository.prepareHistoryImport(.init(records: [incoming]))
        XCTAssertEqual(fresh.appendedCount, 0)
    }

    func testCorruptHistoryCheckpointAndInvalidRecordFailClosedWithoutChangingBytes() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: directory.appendingPathComponent("outdoor-history.json"))
        do { _ = try await repository.prepareHistoryImport(.init(records: [record()])); XCTFail("Corrupt history blocks") } catch {}
        XCTAssertEqual(try historyData(directory), corrupt)
        try seed([], at: directory)
        try corrupt.write(to: directory.appendingPathComponent("active-outdoor.json"))
        do { _ = try await repository.prepareHistoryExport(); XCTFail("Corrupt checkpoint blocks") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("active-outdoor.json")), corrupt)
        try Data("null".utf8).write(to: directory.appendingPathComponent("active-outdoor.json"))
        let invalid = try changingRecord(package([record()]), key: "confirmedActiveSeconds", value: -1)
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(invalid))
    }

    func testGeneralSchema3ProjectionCannotInventFullRecordState() throws {
        let data = try JSONEncoder().encode(LocalDataExportPackage(exportedAt: .now, completedWorkouts: [], bodyWeightReadings: [],
            selection: .init(workouts: false, mealsAndWater: false, bodyWeight: false, outdoorActivities: true, routes: true, goalsAndPreferences: false),
            meals: nil, waterSnapshot: nil, outdoorActivities: [OutdoorActivityExport(record(), includeRoute: true)], goalsAndPreferences: nil))
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(data)) {
            XCTAssertEqual($0 as? OutdoorHistoryTransferError, .invalidFile)
        }
    }

    func testHostileSyntaxSchemaUnknownNestedKeysAndSizeFailBeforeAnyStoreWrite() throws {
        let valid = try package([record()])
        let json = String(decoding: valid, as: UTF8.self)
        let bad = [
            Data("{\"format\":\"01.outdoor-history\",\"fo\\u0072mat\":\"01.outdoor-history\"}".utf8),
            Data((String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)).utf8),
            try changingRoot(valid, key: "schemaVersion", value: 99),
            try changingRoot(valid, key: "newFact", value: true),
            try changingRecord(valid, key: "newRowFact", value: true),
            Data(json.replacingOccurrences(of: "\"latitude\":", with: "\"fixID\":\"invented\",\"latitude\":").utf8),
            Data(json.replacingOccurrences(of: "\"latestCumulativeSteps\":", with: "\"extraStep\":true,\"latestCumulativeSteps\":").utf8),
            Data(repeating: 32, count: OutdoorHistoryTransferDecoder.maximumFileBytes + 1)
        ]
        for data in bad { XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(data)) }
    }

    func testInvalidIDScalarCoordinateDistanceDeletionAndStepStateRejectWithoutNormalization() throws {
        let valid = try package([record()])
        for (key, value) in [("id", "invalid" as Any), ("version", 2), ("confirmedActiveSeconds", true),
                             ("startedAt", 1e100), ("recordedDistanceMeters", -1), ("recordedSteps", Int.max),
                             ("routeDeletedAt", 1)] {
            XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(changingRecord(valid, key: key, value: value)))
        }
        let json = String(decoding: valid, as: UTF8.self)
        let latitudeKey = "\"latitude\":37.3333"
        XCTAssertTrue(json.contains(latitudeKey))
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(Data(json.replacingOccurrences(of: latitudeKey, with: "\"latitude\":91").utf8)))
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(Data(json.replacingOccurrences(of: "\"isFinal\":false", with: "\"isFinal\":true").utf8)))
    }

    func testPointAndRecordCountBoundsRejectPathologicalTypedCollections() throws {
        let original = record()
        let oversized = OutdoorHistoryTransferPackage(records: Array(repeating: original, count: OutdoorHistoryTransferDecoder.maximumRecords + 1))
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.validate(oversized))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package([original])) as? [String: Any])
        var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        var route = try XCTUnwrap(rows[0]["route"] as? [String: Any])
        var segments = try XCTUnwrap(route["segments"] as? [[String: Any]])
        let fix = try XCTUnwrap((segments[0]["points"] as? [[String: Any]])?.first)
        segments[0]["points"] = Array(repeating: fix, count: OutdoorHistoryTransferDecoder.maximumPointsPerRecord + 1)
        route["segments"] = segments; rows[0]["route"] = route; object["records"] = rows
        XCTAssertThrowsError(try OutdoorHistoryTransferDecoder.decode(JSONSerialization.data(withJSONObject: object)))
    }

    private func record(timerOnly: Bool = false) -> OutdoorActivityRecord {
        let startedAt = Date(timeIntervalSinceReferenceDate: 812345678.1234567)
        var route = OutdoorRouteAccumulator()
        var steps = OutdoorStepAccumulator()
        if !timerOnly {
            let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 35,
                maximumGapSeconds: 30, maximumPlausibleSpeedMetersPerSecond: 15, maximumFutureSeconds: 5)
            func fix(_ offset: Double, _ seconds: Double) -> OutdoorRouteFix {
                OutdoorRouteFix(latitude: 37.3333, longitude: -122.1111 + offset,
                    timestamp: startedAt.addingTimeInterval(seconds), horizontalAccuracyMeters: 4.123456789)
            }
            _ = route.ingest(fix(0, 0), receivedAt: startedAt, policy: policy)
            _ = route.ingest(fix(0.00001, 10), receivedAt: startedAt.addingTimeInterval(10), policy: policy)
            route.breakForUserPause()
            _ = route.ingest(fix(0.0003, 40), receivedAt: startedAt.addingTimeInterval(40), policy: policy)
            route.noteLocationGap()
            _ = route.ingest(fix(0.0004, 60), receivedAt: startedAt.addingTimeInterval(60), policy: policy)
            route.noteLocationGap() // retain the private pending-break fact too
            let intervalID = UUID()
            _ = steps.begin(at: startedAt, id: intervalID)
            steps.close(at: startedAt.addingTimeInterval(20))
            _ = steps.ingest(OutdoorStepSnapshot(intervalID: intervalID, sampleStartedAt: startedAt,
                sampleEndedAt: startedAt.addingTimeInterval(20), cumulativeSteps: 17, isFinal: true))
            _ = steps.begin(at: startedAt.addingTimeInterval(35))
            steps.close(at: startedAt.addingTimeInterval(30)) // retained clock discontinuity
        }
        let finishedAt = startedAt.addingTimeInterval(100.1234567)
        let checkpoint = OutdoorActivityCheckpoint(kind: .walk, trackingMode: timerOnly ? .timerOnly : .route,
            startedAt: startedAt, checkpointedAt: finishedAt, confirmedActiveSeconds: 31.123456789,
            phase: .readyToSave, finishedAt: finishedAt, route: route, steps: steps)
        return OutdoorActivityRecord(checkpoint: checkpoint, finishedAt: finishedAt)
    }
    private func package(_ records: [OutdoorActivityRecord]) throws -> Data {
        try OutdoorHistoryTransferDecoder.encode(.init(records: records))
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OutdoorTransfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func cleanup(_ directories: URL...) { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    private func seed(_ records: [OutdoorActivityRecord], at directory: URL) throws {
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("outdoor-history.json"))
    }
    private func historyData(_ directory: URL) throws -> Data { try Data(contentsOf: directory.appendingPathComponent("outdoor-history.json")) }
    private func seedCheckpoint(at directory: URL) throws {
        let date = Date(timeIntervalSinceReferenceDate: 812345000)
        let checkpoint = OutdoorActivityCheckpoint(kind: .run, trackingMode: .timerOnly,
            startedAt: date, checkpointedAt: date, confirmedActiveSeconds: 0, phase: .recording)
        try JSONEncoder().encode(checkpoint).write(to: directory.appendingPathComponent("active-outdoor.json"))
    }
    private func changingRoot(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func changingRecord(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        rows[0][key] = value; object["records"] = rows
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private final class TransferNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class TransferFaultState: @unchecked Sendable {
    private let lock = NSLock()
    private let failurePhase: OutdoorHistoryTransferIOPhase
    private var writes = 0
    init(_ failurePhase: OutdoorHistoryTransferIOPhase) { self.failurePhase = failurePhase }
    func call(_ phase: OutdoorHistoryTransferIOPhase) throws {
        lock.lock(); defer { lock.unlock() }
        if phase == .afterWrite { writes += 1 }
        if phase == failurePhase { throw CocoaError(.fileWriteUnknown) }
    }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
}
