import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class OutdoorShareRevocationEventTests: XCTestCase {
    func testAllFourOwnersRevokeInitialReplacementReinstallAndRemovalRegistrations() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: { true })
        let model = OutdoorActivityViewModel(repository: repository)
        let owners: [(@MainActor (ZeroOneShareRevocationRegistration?) async -> Void,
                      @MainActor (ZeroOneShareRevocationRegistration?) async -> Bool)] = [
            ({ await repository.installShareRevocationRegistration($0) }, { await repository.isShareRevocationRegistered($0) }),
            ({ await recorder.installShareRevocationRegistration($0) }, { await recorder.isShareRevocationRegistered($0) }),
            ({ coordinator.installShareRevocationRegistration($0) }, { coordinator.isShareRevocationRegistered($0) }),
            ({ await model.installShareRevocationRegistration($0) }, { await model.isShareRevocationRegistered($0) })
        ]
        for (install, matches) in owners {
            let oldProbe = OutdoorEventProbe(); let incomingProbe = OutdoorEventProbe()
            let oldRegistration = registration(oldProbe); let incoming = registration(incomingProbe)
            let absent = await matches(nil); XCTAssertFalse(absent)
            let initial = oldProbe.issue(); await install(oldRegistration); XCTAssertFalse(initial.allows)
            let installed = await matches(oldRegistration); XCTAssertTrue(installed)
            let old = oldProbe.issue(); let nextOld = incomingProbe.issue()
            await install(incoming); XCTAssertFalse(old.allows); XCTAssertFalse(nextOld.allows)
            let staleMatch = await matches(oldRegistration); let nextMatch = await matches(incoming)
            XCTAssertFalse(staleMatch); XCTAssertTrue(nextMatch)
            let same = incomingProbe.issue(); await install(incoming); XCTAssertFalse(same.allows)
            let removed = incomingProbe.issue(); await install(nil); XCTAssertFalse(removed.allows)
            let absentAgain = await matches(nil); let removedMatch = await matches(incoming)
            XCTAssertFalse(absentAgain); XCTAssertFalse(removedMatch)
            XCTAssertTrue(incomingProbe.issue().allows); XCTAssertFalse(removed.allows)
        }
    }

    func testCheckpointSaveAndExactRetryBothRevokeWithoutChangingJournalFacts() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let original = checkpoint(); let old = probe.issue(); probe.clear()
        try await repository.saveCheckpoint(original)
        XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
        let firstBytes = try bytes(directory, "active-outdoor.json")
        let retry = probe.issue(); probe.clear(); try await repository.saveCheckpoint(original)
        XCTAssertFalse(retry.allows); XCTAssertEqual(probe.events.first, "revoke")
        XCTAssertEqual(try bytes(directory, "active-outdoor.json"), firstBytes)
        let persisted = try await repository.loadCheckpoint(); XCTAssertEqual(persisted, original)
    }

    func testInvalidCheckpointRevokesBeforeGuardWithoutCreatingFiles() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        var invalid = checkpoint(); invalid.confirmedActiveSeconds = -1
        let old = probe.issue(); probe.clear()
        do { try await repository.saveCheckpoint(invalid); XCTFail("Invalid checkpoint") }
        catch { XCTAssertEqual(error as? OutdoorActivityPersistenceError, .invalidCheckpoint) }
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-outdoor.json").path))
    }

    func testConflictingCheckpointRevokesAndPreservesExactOwnerBytes() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        try await repository.saveCheckpoint(checkpoint()); let original = try bytes(directory, "active-outdoor.json")
        let old = probe.issue(); probe.clear()
        do { try await repository.saveCheckpoint(checkpoint()); XCTFail("Different owner") }
        catch { XCTAssertEqual(error as? OutdoorActivityPersistenceError, .conflictingActivity) }
        XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
        XCTAssertEqual(try bytes(directory, "active-outdoor.json"), original)
    }

    func testFinishRevokesFrozenCheckpointHistoryAndTombstoneThenExactRetryRevokesAgain() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let active = checkpoint(); try await repository.saveCheckpoint(active)
        let final = finished(active); let old = probe.issue(); probe.clear()
        guard case let .saved(record) = try await repository.finish(final) else { return XCTFail("Must save") }
        XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
        let cleared = try await repository.loadCheckpoint(); XCTAssertNil(cleared)
        XCTAssertEqual(try bytes(directory, "active-outdoor.json"), Data("null".utf8))
        let records = try await repository.loadRecords(); XCTAssertEqual(records, [record])
        let historyBytes = try bytes(directory, "outdoor-history.json")
        let retry = probe.issue(); probe.clear()
        guard case let .alreadySaved(same) = try await repository.finish(final) else { return XCTFail("Exact retry") }
        XCTAssertEqual(same, record); XCTAssertFalse(retry.allows)
        XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(try bytes(directory, "outdoor-history.json"), historyBytes)
    }

    func testRejectedFinishRevokesBeforeReadyGuardAndPreservesCheckpoint() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let active = checkpoint(); try await repository.saveCheckpoint(active)
        let original = try bytes(directory, "active-outdoor.json"); let old = probe.issue(); probe.clear()
        do { _ = try await repository.finish(active); XCTFail("Not ready") }
        catch { XCTAssertEqual(error as? OutdoorActivityPersistenceError, .notReadyToSave) }
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
        XCTAssertEqual(try bytes(directory, "active-outdoor.json"), original)
    }

    func testRoutePrivacyDeletionAndNoOpRepeatRevokeWhilePreservingTotalsAndIdentity() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let original = record(); try seed([original], directory)
        let old = probe.issue(); probe.clear()
        let deleted = try await repository.deleteRoute(for: original.id, at: date.addingTimeInterval(40))
        XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
        XCTAssertNil(deleted.route); XCTAssertNotNil(deleted.routeDeletedAt)
        XCTAssertEqual(deleted.id, original.id); XCTAssertEqual(deleted.confirmedActiveSeconds, original.confirmedActiveSeconds)
        XCTAssertEqual(deleted.recordedDistanceMeters, original.recordedDistanceMeters)
        let priorBytes = try bytes(directory, "outdoor-history.json"); let again = probe.issue(); probe.clear()
        let repeated = try await repository.deleteRoute(for: original.id, at: date.addingTimeInterval(50))
        XCTAssertEqual(repeated, deleted); XCTAssertFalse(again.allows)
        XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(try bytes(directory, "outdoor-history.json"), priorBytes)
    }

    func testInvalidOrMissingPrivacyDeletionRevokesWithoutReplacingSavedBytes() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let original = record(); try seed([original], directory); let priorBytes = try bytes(directory, "outdoor-history.json")
        for invalidDate in [true, false] {
            let old = probe.issue(); probe.clear()
            do {
                _ = try await repository.deleteRoute(for: invalidDate ? original.id : UUID(),
                    at: invalidDate ? Date(timeIntervalSinceReferenceDate: .infinity) : date)
                XCTFail("Invalid privacy deletion")
            } catch {
                XCTAssertEqual(error as? OutdoorActivityPersistenceError, invalidDate ? .invalidHistory : .recordNotFound)
            }
            XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
            XCTAssertEqual(try bytes(directory, "outdoor-history.json"), priorBytes)
        }
    }

    func testSessionDeleteAndMissingNoOpRevokeWithoutRevivingOldPermit() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let first = record(); let second = record(); try seed([first, second], directory)
        let old = probe.issue(); probe.clear(); let removed = try await repository.deleteSession(first.id)
        XCTAssertTrue(removed); XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
        let records = try await repository.loadRecords(); XCTAssertEqual(records, [second])
        let fresh = probe.issue(); probe.clear(); let absent = try await repository.deleteSession(first.id)
        XCTAssertFalse(absent); XCTAssertFalse(fresh.allows); XCTAssertFalse(old.allows)
        XCTAssertEqual(probe.events.first, "revoke")
    }

    func testReadOnlyRepositoryReadsObservationAndReconciliationQueryDoNotRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        let original = record(); try seed([original], directory)
        let review = try await repository.prepareHistoryExport(at: date)
        let old = probe.issue(); probe.clear()
        let records = try await repository.loadRecords(); let checkpoint = try await repository.loadCheckpoint()
        let observation = try await repository.loadRecommendationObservation()
        let needsReconciliation = await repository.historyTransferNeedsReconciliation(reviewID: review.id)
        let unconfirmed = await repository.hasUnconfirmedHistoryTransfer
        XCTAssertEqual(records, [original]); XCTAssertNil(checkpoint); XCTAssertFalse(needsReconciliation)
        XCTAssertFalse(unconfirmed)
        XCTAssertTrue(repository.confirmsRecommendationSource(observation.source))
        XCTAssertEqual(probe.events, []); XCTAssertTrue(old.allows)
    }

    func testImportFaultBeforeFirstWriteSeesRevokedTokenAndReadOnlyBaselineReconciliationRevokes() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe()
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            probe.observe("fault-\(phase)")
            if phase == .beforeWrite { throw Failure.write }
        })
        await repository.installShareRevocationRegistration(registration(probe))
        let review = try await repository.prepareHistoryImport(.init(records: [record()], exportedAt: date))
        let old = probe.issue(); probe.clear()
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Write rejected") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        XCTAssertFalse(old.allows); XCTAssertTrue(probe.events.contains("fault-beforeWrite:revoked"))
        XCTAssertFalse(probe.events.contains(where: { $0.hasSuffix(":VALID") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outdoor-history.json").path))
        let retry = probe.issue(); probe.clear(); let result = try await repository.reconcileHistoryImport(reviewID: review.id)
        XCTAssertNil(result); XCTAssertFalse(retry.allows); XCTAssertEqual(probe.events.first, "revoke")
    }

    func testImportLandedFailureSeesRevokedTokenAndReconcilesWithoutSecondWrite() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe()
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            probe.observe("fault-\(phase)")
            if phase == .afterWrite { throw Failure.write }
        })
        await repository.installShareRevocationRegistration(registration(probe))
        let incoming = record(); let review = try await repository.prepareHistoryImport(.init(records: [incoming], exportedAt: date))
        let old = probe.issue(); probe.clear()
        do { _ = try await repository.confirmHistoryImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Unconfirmed") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        XCTAssertFalse(old.allows); XCTAssertTrue(probe.events.contains("fault-beforeWrite:revoked"))
        XCTAssertTrue(probe.events.contains("fault-afterWrite:revoked"))
        let unconfirmed = await repository.hasUnconfirmedHistoryTransfer; XCTAssertTrue(unconfirmed)
        let originalBytes = try bytes(directory, "outdoor-history.json")
        let retry = probe.issue(); probe.clear(); let result = try await repository.reconcileHistoryImport(reviewID: review.id)
        XCTAssertEqual(result?.confirmedRecords, [incoming]); XCTAssertFalse(retry.allows)
        XCTAssertFalse(probe.events.contains(where: { $0.hasPrefix("fault-") }))
        XCTAssertEqual(try bytes(directory, "outdoor-history.json"), originalBytes); XCTAssertFalse(old.allows)
        let reconciled = await repository.hasUnconfirmedHistoryTransfer; XCTAssertFalse(reconciled)
    }

    func testTransferPrepareConfirmAcknowledgementRejectAndDiscardAllRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = await repository(directory, probe)
        try seed([record()], directory)
        let prepare = probe.issue(); let review = try await repository.prepareHistoryExport(at: date)
        XCTAssertFalse(prepare.allows)
        let rejected = probe.issue(); probe.clear()
        do { _ = try await repository.confirmHistoryExport(reviewID: review.id, acknowledgesRouteData: false); XCTFail("Missing acknowledgment") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .routeAcknowledgementRequired) }
        XCTAssertFalse(rejected.allows); XCTAssertEqual(probe.events.first, "revoke")
        let approved = probe.issue(); let data = try await repository.confirmHistoryExport(reviewID: review.id, acknowledgesRouteData: true)
        XCTAssertFalse(approved.allows); XCTAssertEqual(try OutdoorHistoryTransferDecoder.decode(data).records, review.records)
        let discarded = probe.issue(); try await repository.discardHistoryTransferReview(reviewID: review.id)
        XCTAssertFalse(discarded.allows)
        let emptyDiscard = probe.issue(); try await repository.discardHistoryTransferReview(reviewID: nil)
        XCTAssertFalse(emptyDiscard.allows)
    }

    func testRecorderRestoreAndRepeatedRestoreRevokeEvenWhenStateStaysIdle() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        await recorder.installShareRevocationRegistration(registration(probe))
        for _ in 0..<2 {
            let old = probe.issue(); probe.clear(); let state = try await recorder.restore()
            XCTAssertEqual(state, .idle); XCTAssertFalse(old.allows)
            XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
            let ready = await recorder.canShareSavedRecords; XCTAssertTrue(ready)
        }
    }

    func testRecorderReadOnlyStateReadinessAndRegistrationIdentityDoNotRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let registration = registration(probe); await recorder.installShareRevocationRegistration(registration)
        let old = probe.issue(); probe.clear()
        let state = await recorder.state(); let ready = await recorder.canShareSavedRecords
        let matches = await recorder.isShareRevocationRegistered(registration)
        XCTAssertEqual(state, .idle); XCTAssertTrue(ready); XCTAssertTrue(matches)
        XCTAssertEqual(probe.events, []); XCTAssertTrue(old.allows)
    }

    func testRecorderRejectedPauseFinishAndRetryRevokeEntryAndExitWhileIdle() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        await recorder.installShareRevocationRegistration(registration(probe))
        let operations: [() async throws -> Void] = [
            { _ = try await recorder.pause(at: self.date) },
            { _ = try await recorder.finish(at: self.date) },
            { _ = try await recorder.retryStorage(at: self.date) }
        ]
        for operation in operations {
            let old = probe.issue(); probe.clear()
            do { try await operation(); XCTFail("No active session") } catch { XCTAssertNotNil(error as? OutdoorRecorderError) }
            XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
            let ready = await recorder.canShareSavedRecords; XCTAssertTrue(ready)
        }
    }

    func testRecorderStartRejectionPauseResumeAndFinishAlwaysLeavePriorPermitsRevoked() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        await recorder.installShareRevocationRegistration(registration(probe))
        let monotonic = ContinuousClock.now; let start = probe.issue()
        let initial = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: date, monotonic: monotonic)
        XCTAssertFalse(start.allows); let recordingReady = await recorder.canShareSavedRecords; XCTAssertFalse(recordingReady)
        let rejected = probe.issue(); probe.clear()
        do { _ = try await recorder.start(kind: .run, at: date, monotonic: monotonic); XCTFail("Already active") }
        catch { XCTAssertEqual(error as? OutdoorRecorderError, .alreadyActive) }
        XCTAssertFalse(rejected.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        let pausing = probe.issue()
        _ = try await recorder.pause(at: date.addingTimeInterval(10), monotonic: monotonic.advanced(by: .seconds(10)))
        XCTAssertFalse(pausing.allows); let pausedReady = await recorder.canShareSavedRecords; XCTAssertFalse(pausedReady)
        let resuming = probe.issue()
        _ = try await recorder.resume(at: date.addingTimeInterval(20), monotonic: monotonic.advanced(by: .seconds(20)))
        XCTAssertFalse(resuming.allows)
        let finishing = probe.issue()
        guard case let .saved(saved) = try await recorder.finish(at: date.addingTimeInterval(30), monotonic: monotonic.advanced(by: .seconds(30))) else {
            return XCTFail("Finish must save")
        }
        XCTAssertEqual(saved.id, initial.id); XCTAssertEqual(saved.confirmedActiveSeconds, 20)
        XCTAssertFalse(finishing.allows); XCTAssertFalse(start.allows)
        let ready = await recorder.canShareSavedRecords; XCTAssertTrue(ready)
    }

    func testRecorderClockRegressionRevokesAndKeepsRecordedCheckpoint() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        await recorder.installShareRevocationRegistration(registration(probe))
        let monotonic = ContinuousClock.now
        let initial = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: date, monotonic: monotonic)
        let old = probe.issue(); probe.clear()
        do { _ = try await recorder.heartbeat(at: date, monotonic: monotonic.advanced(by: .seconds(-1))); XCTFail("Clock regression") }
        catch { XCTAssertEqual(error as? OutdoorRecorderError, .clockRegression) }
        XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        let state = await recorder.state(); XCTAssertEqual(state, .recording(initial))
    }

    func testRecorderFailedWriteAndStorageRetryRevokeWithoutAutoResuming() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        await recorder.installShareRevocationRegistration(registration(probe))
        let monotonic = ContinuousClock.now
        _ = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: date, monotonic: monotonic)
        let activeURL = directory.appendingPathComponent("active-outdoor.json")
        let originalBytes = try Data(contentsOf: activeURL); try Data("corrupt synthetic journal".utf8).write(to: activeURL)
        let old = probe.issue(); probe.clear()
        do { _ = try await recorder.heartbeat(at: date.addingTimeInterval(10), monotonic: monotonic.advanced(by: .seconds(10))); XCTFail("Unreadable journal") }
        catch { XCTAssertNotNil(error) }
        XCTAssertFalse(old.allows); let blocked = await recorder.canShareSavedRecords; XCTAssertFalse(blocked)
        try originalBytes.write(to: activeURL)
        let retry = probe.issue(); probe.clear(); let recovered = try await recorder.retryStorage(at: date.addingTimeInterval(11))
        guard case .paused = recovered else { return XCTFail("Retry must pause") }
        XCTAssertFalse(retry.allows); XCTAssertFalse(old.allows)
        XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        let ready = await recorder.canShareSavedRecords; XCTAssertFalse(ready)
    }

    func testRecorderRestoredInterruptionResumeAndRejectedResumeRevokeWithoutInventingGapTime() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory); let active = checkpoint()
        try await repository.saveCheckpoint(active)
        let probe = OutdoorEventProbe(); let recorder = OutdoorActivityRecorder(repository: repository)
        await recorder.installShareRevocationRegistration(registration(probe))
        let loading = probe.issue(); let restored = try await recorder.restore()
        XCTAssertEqual(restored, .interrupted(active)); XCTAssertFalse(loading.allows)
        let resumedPermit = probe.issue(); let monotonic = ContinuousClock.now
        let resumed = try await recorder.resume(at: date.addingTimeInterval(100), monotonic: monotonic)
        XCTAssertFalse(resumedPermit.allows); XCTAssertEqual(resumed.confirmedActiveSeconds, active.confirmedActiveSeconds)
        let rejected = probe.issue(); probe.clear()
        do { _ = try await recorder.resume(at: date.addingTimeInterval(101), monotonic: monotonic); XCTFail("Already recording") }
        catch { XCTAssertEqual(error as? OutdoorRecorderError, .notResumable) }
        XCTAssertFalse(rejected.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        let ready = await recorder.canShareSavedRecords; XCTAssertFalse(ready)
    }

    func testViewModelDefaultClosedAndAsyncInstallationCoversActualHiddenRecorder() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let model = OutdoorActivityViewModel(repository: OutdoorActivityRepository(directory: directory))
        XCTAssertFalse(model.canShareSavedRecords)
        let absent = await model.isShareRevocationRegistered(nil); XCTAssertFalse(absent)
        let registration = registration(probe); await model.installShareRevocationRegistration(registration)
        let matches = await model.isShareRevocationRegistered(registration); XCTAssertTrue(matches)
        let old = probe.issue(); probe.clear(); await model.load()
        XCTAssertFalse(old.allows); XCTAssertTrue(model.isLoaded); XCTAssertEqual(model.surface, .setup)
        XCTAssertTrue(model.canShareSavedRecords)
        let ready = await model.confirmsRecorderShareReadiness(); XCTAssertTrue(ready)
        XCTAssertEqual(probe.events.first, "revoke")
    }

    func testViewModelReadOnlyExportsLatestWalkAndRecorderQueriesDoNotRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = OutdoorActivityRepository(directory: directory)
        let model = OutdoorActivityViewModel(repository: repository); let registration = registration(probe)
        await model.installShareRevocationRegistration(registration); await model.load()
        let original = record(); try seed([original], directory); let old = probe.issue(); probe.clear()
        let records = try await model.savedRecordsForExport(); await model.refreshLatestWalk()
        let ready = await model.confirmsRecorderShareReadiness(); let matches = await model.isShareRevocationRegistered(registration)
        XCTAssertEqual(records, [original]); XCTAssertTrue(ready); XCTAssertTrue(matches)
        XCTAssertTrue(model.canShareSavedRecords); XCTAssertEqual(probe.events, []); XCTAssertTrue(old.allows)
    }

    func testViewModelRejectedActionsBeforeLoadRevokeWithoutStartingSensorsOrJournal() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let model = OutdoorActivityViewModel(repository: OutdoorActivityRepository(directory: directory))
        await model.installShareRevocationRegistration(registration(probe))
        let operations: [() async -> Void] = [
            { await model.startTimeOnly() }, { await model.startWithRoute() },
            { await model.pause() }, { await model.finish() }, { await model.retryStorage() }
        ]
        for operation in operations {
            let old = probe.issue(); probe.clear(); await operation()
            XCTAssertFalse(old.allows); XCTAssertEqual(probe.events.first, "revoke")
            XCTAssertFalse(model.isLoaded); XCTAssertFalse(model.canShareSavedRecords); XCTAssertNil(model.checkpoint)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-outdoor.json").path))
    }

    func testViewModelFrozenRecoveryRetryAndSummaryCloseRevokeAndUseHiddenRecorder() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let final = finished(checkpoint()); try JSONEncoder().encode(final).write(to: directory.appendingPathComponent("active-outdoor.json"))
        let probe = OutdoorEventProbe(); let repository = OutdoorActivityRepository(directory: directory)
        let model = OutdoorActivityViewModel(repository: repository)
        await model.installShareRevocationRegistration(registration(probe)); let loading = probe.issue(); await model.load()
        XCTAssertFalse(loading.allows); XCTAssertEqual(model.surface, .storageBlocked)
        XCTAssertFalse(model.canShareSavedRecords); let blockedReady = await model.confirmsRecorderShareReadiness(); XCTAssertFalse(blockedReady)
        let retry = probe.issue(); probe.clear(); await model.retryStorage()
        XCTAssertFalse(retry.allows); XCTAssertEqual(model.surface, .summary); XCTAssertNil(model.checkpoint)
        XCTAssertEqual(model.finishedRecord?.id, final.id); XCTAssertTrue(model.canShareSavedRecords)
        let ready = await model.confirmsRecorderShareReadiness(); XCTAssertTrue(ready)
        let closing = probe.issue(); probe.clear(); model.closeSummary()
        XCTAssertFalse(closing.allows); XCTAssertEqual(model.surface, .setup); XCTAssertNil(model.finishedRecord)
        XCTAssertEqual(probe.events.first, "revoke")
    }

    func testViewModelUnreadableLoadAndFailedRetryRemainClosedAndRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        try Data("synthetic corrupt checkpoint".utf8).write(to: directory.appendingPathComponent("active-outdoor.json"))
        let probe = OutdoorEventProbe(); let model = OutdoorActivityViewModel(repository: OutdoorActivityRepository(directory: directory))
        await model.installShareRevocationRegistration(registration(probe))
        let loading = probe.issue(); await model.load(); XCTAssertFalse(loading.allows)
        XCTAssertTrue(model.isLoaded); XCTAssertEqual(model.surface, .storageBlocked); XCTAssertFalse(model.canShareSavedRecords)
        let retry = probe.issue(); probe.clear(); await model.retryStorage()
        XCTAssertFalse(retry.allows); XCTAssertEqual(model.surface, .storageBlocked)
        // A failed restore can leave the recorder idle. The VM's blocked gate
        // must still deny sharing; the recorder check is an additional condition.
        let ready = await model.confirmsRecorderShareReadiness(); XCTAssertTrue(ready)
        XCTAssertEqual(probe.events.first, "revoke")
    }

    func testCoordinatorPrepareGateSeesRevokedPermitAndBusyExitRevokesPermitMintedAtGate() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let repository = OutdoorActivityRepository(directory: directory)
        var coordinator: OutdoorHistoryTransferCoordinator!
        coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: {
            probe.observe("gate"); XCTAssertTrue(coordinator.isBusy); _ = probe.issue(); return true
        })
        coordinator.installShareRevocationRegistration(registration(probe)); let old = probe.issue(); probe.clear()
        let review = try await coordinator.prepareExport()
        XCTAssertFalse(old.allows); XCTAssertTrue(probe.events.contains("gate:revoked"))
        XCTAssertFalse(probe.currentAllows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(coordinator.review?.id, review.id)
    }

    func testCoordinatorRejectedGateStillRevokesBusyExitAndPreservesHistory() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let original = record(); try seed([original], directory); let before = try bytes(directory, "outdoor-history.json")
        let probe = OutdoorEventProbe()
        let coordinator = OutdoorHistoryTransferCoordinator(repository: OutdoorActivityRepository(directory: directory), canTransfer: {
            probe.observe("gate"); _ = probe.issue(); return false
        })
        coordinator.installShareRevocationRegistration(registration(probe)); let old = probe.issue(); probe.clear()
        do { _ = try await coordinator.prepareExport(); XCTFail("Gate blocked") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .appGateBlocked) }
        XCTAssertFalse(old.allows); XCTAssertTrue(probe.events.contains("gate:revoked")); XCTAssertFalse(probe.currentAllows)
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(probe.events.last, "revoke")
        XCTAssertEqual(try bytes(directory, "outdoor-history.json"), before)
    }

    func testCoordinatorMalformedImportAndExpiredConfirmRevokeEntryAndBusyExit() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe(); let coordinator = coordinator(directory, probe)
        let operations: [() async throws -> Void] = [
            { _ = try await coordinator.prepareImport(data: Data("not JSON".utf8)) },
            { _ = try await coordinator.confirmImport(reviewID: UUID(), acknowledgesRouteData: true) },
            { _ = try await coordinator.confirmExport(reviewID: UUID(), acknowledgesRouteData: true) }
        ]
        for operation in operations {
            let old = probe.issue(); probe.clear()
            do { try await operation(); XCTFail("Rejected input") } catch { XCTAssertNotNil(error as? OutdoorHistoryTransferError) }
            XCTAssertFalse(old.allows); XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        }
    }

    func testCoordinatorImportUnconfirmedMirrorBlockedPrepareReconcileAndDiscardRevoke() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let probe = OutdoorEventProbe()
        let repository = OutdoorActivityRepository(directory: directory, transferFault: { phase in
            if phase == .afterWrite { throw Failure.write }
        })
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: { probe.observe("gate"); return true })
        coordinator.installShareRevocationRegistration(registration(probe))
        let incoming = record(); let data = try OutdoorHistoryTransferDecoder.encode(.init(records: [incoming], exportedAt: date))
        let review = try await coordinator.prepareImport(data: data); let old = probe.issue(); probe.clear()
        do { _ = try await coordinator.confirmImport(reviewID: review.id, acknowledgesRouteData: true); XCTFail("Ambiguous write") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        XCTAssertFalse(old.allows); XCTAssertTrue(coordinator.needsReconciliation); XCTAssertFalse(coordinator.isBusy)
        let blocked = probe.issue(); probe.clear()
        do { _ = try await coordinator.prepareExport(); XCTFail("Reconciliation needed") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .writeUnconfirmed) }
        XCTAssertFalse(blocked.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        let retry = probe.issue(); probe.clear(); let result = try await coordinator.reconcile(reviewID: review.id)
        XCTAssertEqual(result?.confirmedRecords, [incoming]); XCTAssertFalse(retry.allows)
        XCTAssertFalse(coordinator.needsReconciliation); XCTAssertFalse(coordinator.isBusy); XCTAssertNil(coordinator.review)
        let discarded = probe.issue(); probe.clear(); try await coordinator.discardReview()
        XCTAssertFalse(discarded.allows); XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
    }

    func testCoordinatorAcknowledgementRejectAndNoOpDiscardRevokeWithoutMutatingHistory() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let original = record(); try seed([original], directory); let originalBytes = try bytes(directory, "outdoor-history.json")
        let probe = OutdoorEventProbe(); let coordinator = coordinator(directory, probe)
        let review = try await coordinator.prepareExport(); let old = probe.issue(); probe.clear()
        do { _ = try await coordinator.confirmExport(reviewID: review.id, acknowledgesRouteData: false); XCTFail("Acknowledgement required") }
        catch { XCTAssertEqual(error as? OutdoorHistoryTransferError, .routeAcknowledgementRequired) }
        XCTAssertFalse(old.allows); XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        for _ in 0..<2 {
            let discarded = probe.issue(); probe.clear(); try await coordinator.discardReview()
            XCTAssertFalse(discarded.allows); XCTAssertFalse(coordinator.isBusy); XCTAssertNil(coordinator.review)
            XCTAssertEqual(probe.events.first, "revoke"); XCTAssertEqual(probe.events.last, "revoke")
        }
        XCTAssertEqual(try bytes(directory, "outdoor-history.json"), originalBytes)
    }

    func testNilRegistrationPreservesOfflineRecorderAndTransferBehavior() async throws {
        let directory = try directory(); defer { cleanup(directory) }
        let repository = OutdoorActivityRepository(directory: directory); let recorder = OutdoorActivityRecorder(repository: repository)
        let monotonic = ContinuousClock.now
        _ = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: date, monotonic: monotonic)
        _ = try await recorder.finish(at: date.addingTimeInterval(10), monotonic: monotonic.advanced(by: .seconds(10)))
        let coordinator = OutdoorHistoryTransferCoordinator(repository: repository, canTransfer: { true })
        let review = try await coordinator.prepareExport()
        let data = try await coordinator.confirmExport(reviewID: review.id, acknowledgesRouteData: true)
        XCTAssertEqual(try OutdoorHistoryTransferDecoder.decode(data).records.count, 1)
        let repositoryRegistered = await repository.isShareRevocationRegistered(nil)
        let recorderRegistered = await recorder.isShareRevocationRegistered(nil)
        XCTAssertFalse(repositoryRegistered); XCTAssertFalse(recorderRegistered)
        XCTAssertFalse(coordinator.isShareRevocationRegistered(nil)); XCTAssertFalse(coordinator.isBusy)
    }

    private var date: Date { Date(timeIntervalSinceReferenceDate: 2_000_000) }
    private enum Failure: Error { case write }
    private func registration(_ probe: OutdoorEventProbe) -> ZeroOneShareRevocationRegistration {
        ZeroOneShareRevocationRegistration { probe.revoke() }
    }
    private func repository(_ directory: URL, _ probe: OutdoorEventProbe) async -> OutdoorActivityRepository {
        let repository = OutdoorActivityRepository(directory: directory)
        await repository.installShareRevocationRegistration(registration(probe)); return repository
    }
    private func coordinator(_ directory: URL, _ probe: OutdoorEventProbe) -> OutdoorHistoryTransferCoordinator {
        let coordinator = OutdoorHistoryTransferCoordinator(repository: OutdoorActivityRepository(directory: directory), canTransfer: {
            probe.observe("gate"); return true
        })
        coordinator.installShareRevocationRegistration(registration(probe)); return coordinator
    }
    private func checkpoint() -> OutdoorActivityCheckpoint {
        .init(kind: .walk, trackingMode: .timerOnly, startedAt: date, checkpointedAt: date.addingTimeInterval(10),
              confirmedActiveSeconds: 10, phase: .recording)
    }
    private func finished(_ active: OutdoorActivityCheckpoint) -> OutdoorActivityCheckpoint {
        var final = active; final.revision += 1; final.phase = .readyToSave
        final.finishedAt = date.addingTimeInterval(20); final.checkpointedAt = final.finishedAt!
        return final
    }
    private func record() -> OutdoorActivityRecord {
        let final = finished(checkpoint()); return .init(checkpoint: final, finishedAt: final.finishedAt!)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OutdoorRevocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    private func cleanup(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }
    private func bytes(_ directory: URL, _ filename: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(filename)) }
    private func seed(_ records: [OutdoorActivityRecord], _ directory: URL) throws {
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("outdoor-history.json"))
    }
}

private final class OutdoorEventPermit: @unchecked Sendable {
    private let lock = NSLock(); private var valid = true
    var allows: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func revoke() { lock.lock(); defer { lock.unlock() }; valid = false }
}

// The invalidator captures only this thread-safe probe. It never queries or
// re-enters actor/UI-owned state, starts a task or blocks on another executor.
private final class OutdoorEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current: OutdoorEventPermit?
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var currentAllows: Bool { lock.lock(); defer { lock.unlock() }; return current?.allows == true }
    func issue() -> OutdoorEventPermit {
        lock.lock(); defer { lock.unlock() }; let fresh = OutdoorEventPermit(); current = fresh; return fresh
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }; current?.revoke(); recorded.append("revoke")
    }
    func observe(_ label: String) {
        lock.lock(); defer { lock.unlock() }; recorded.append(label + (current?.allows == true ? ":VALID" : ":revoked"))
    }
    func clear() { lock.lock(); defer { lock.unlock() }; recorded.removeAll() }
}
