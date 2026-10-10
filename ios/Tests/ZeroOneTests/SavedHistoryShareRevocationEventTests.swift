import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class SavedHistoryShareRevocationEventTests: XCTestCase {
    func testRecordRevokesBeforeAvailabilityReadAndFirstWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let repository = repository(store, probe)
        let session = session(); let old = probe.issue(); probe.clear()
        XCTAssertEqual(try repository.record(session), .inserted)
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked", "load:revoked", "save:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(store.entries, [WorkoutHistoryEntry(session: session)])
        XCTAssertEqual(repository.entries, store.entries)
        XCTAssertEqual(repository.availability, .available)
    }

    func testIncompleteRecordRevokesBeforeFirstGuardWithoutStoreAccess() {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let repository = repository(store, probe)
        let plan = ExercisePlan(name: "Bench press", targetLoad: Load(42.125), targetReps: RepRange(8, 8),
                                plannedSetCount: 1, restSeconds: 90, previousPerformance: [])
        let incomplete = WorkoutSession(title: "Incomplete", exercises: [WorkoutExercise(plan: plan)])
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.record(incomplete)) {
            guard case WorkoutPersistenceError.incompleteSession = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(probe.events, ["revoke"])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testUnavailableRecordRevokesBeforeAvailabilityGuardWithoutReadOrWrite() {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let repository = repository(store, probe); store.available = false
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.record(session())) {
            guard case WorkoutPersistenceError.unavailable = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked"])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testRecordReadFailureRevokesWithoutWriteOrCacheReplacement() {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let original = WorkoutHistoryEntry(session: session()); store.entries = [original]
        let repository = repository(store, probe); store.failLoad = true
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.record(session())) { XCTAssertEqual($0 as? Failure, .read) }
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked", "load:revoked"])
        XCTAssertEqual(repository.entries, [original]); XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(old.allows)
    }

    func testRecordSaveFailureRevokesAndPreservesAcknowledgedCache() {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let original = WorkoutHistoryEntry(session: session()); store.entries = [original]
        let repository = repository(store, probe); store.mode = .reject
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.record(session())) { XCTAssertEqual($0 as? Failure, .write) }
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked", "load:revoked", "save:revoked"])
        XCTAssertEqual(repository.entries, [original]); XCTAssertEqual(store.entries, [original])
        XCTAssertFalse(old.allows)
    }

    func testAlreadyRecordedAttemptRevokesEvenThoughItDoesNotWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let saved = session()
        store.entries = [WorkoutHistoryEntry(session: saved)]
        let repository = repository(store, probe); let old = probe.issue(); probe.clear()
        XCTAssertEqual(try repository.record(saved), .alreadyRecorded)
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked", "load:revoked"])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
        let next = probe.issue()
        XCTAssertFalse(old.allows); XCTAssertTrue(next.allows)
    }

    func testConflictingSameIDAttemptRevokesWithoutReplacingRecordedFacts() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let saved = session()
        let original = try changed(WorkoutHistoryEntry(session: saved), title: "Different saved title")
        store.entries = [original]; let repository = repository(store, probe)
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.record(saved)) {
            guard case WorkoutPersistenceError.conflictingSession = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(probe.events, ["revoke", "availability:revoked", "load:revoked"])
        XCTAssertEqual(store.entries, [original]); XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testUnchangedConfirmedReadsAndIdentityQueriesDoNotRevoke() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        store.entries = [WorkoutHistoryEntry(session: session())]
        let repository = WorkoutHistoryRepository(store: store); let registration = registration(probe)
        repository.installShareRevocationRegistration(registration)
        let old = probe.issue(); probe.clear()
        XCTAssertTrue(repository.isShareRevocationRegistered(registration))
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
        XCTAssertEqual(try repository.confirmedEntries(), store.entries)
        XCTAssertEqual(try repository.confirmedEntries(), store.entries)
        XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID", "availability:VALID", "load:VALID"])
        XCTAssertTrue(old.allows); XCTAssertEqual(store.saves, 0)
    }

    func testConfirmedReadRevokesForSameIDChangedRecordBeforePublishingNewFacts() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let original = WorkoutHistoryEntry(session: session()); store.entries = [original]
        let repository = repository(store, probe)
        let updated = try changed(original, title: "Changed title, same UUID"); store.entries = [updated]
        let old = probe.issue(); probe.clear()
        XCTAssertEqual(try repository.confirmedEntries(), [updated])
        XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID", "revoke"])
        XCTAssertEqual(repository.entries, [updated]); XCTAssertEqual(updated.id, original.id)
        XCTAssertFalse(old.allows); XCTAssertEqual(store.saves, 0)
    }

    func testConfirmedReadRevokesForChangedCollectionAndNormalizesOrderOnly() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let first = WorkoutHistoryEntry(session: session()); let second = WorkoutHistoryEntry(session: session())
        store.entries = [first]; let repository = repository(store, probe)
        store.entries = [first, second]; let old = probe.issue(); probe.clear()
        let expected = store.entries.sorted(by: WorkoutHistoryEntry.newestFirst)
        XCTAssertEqual(try repository.confirmedEntries(), expected); XCTAssertFalse(old.allows)
        XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID", "revoke"])
        store.entries.reverse(); let fresh = probe.issue(); probe.clear()
        XCTAssertEqual(try repository.confirmedEntries(), expected)
        XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID"]); XCTAssertTrue(fresh.allows)
    }

    func testConfirmedReadFailuresRevokeOnEachAttemptAndRetainCachedFacts() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let original = WorkoutHistoryEntry(session: session()); store.entries = [original]
        let repository = repository(store, probe); store.failLoad = true
        for _ in 0..<2 {
            let old = probe.issue(); probe.clear()
            XCTAssertThrowsError(try repository.confirmedEntries()) { XCTAssertEqual($0 as? Failure, .read) }
            XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID", "revoke"])
            XCTAssertEqual(repository.availability, .unavailable); XCTAssertEqual(repository.entries, [original])
            XCTAssertFalse(old.allows)
        }
        store.failLoad = false; let old = probe.issue(); probe.clear()
        XCTAssertEqual(try repository.confirmedEntries(), [original])
        XCTAssertEqual(probe.events, ["availability:VALID", "load:VALID", "revoke"])
        XCTAssertEqual(repository.availability, .available); XCTAssertFalse(old.allows)
    }

    func testConfirmedUnavailableGuardRevokesWithoutLoading() {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let repository = repository(store, probe); store.available = false
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try repository.confirmedEntries())
        XCTAssertEqual(probe.events, ["availability:VALID", "revoke"])
        XCTAssertEqual(repository.availability, .unavailable); XCTAssertFalse(old.allows)
    }

    func testAllOwnersRevokeOldAndIncomingRegistrationOnReplacementReinstallAndRemoval() {
        let repository = WorkoutHistoryRepository(store: Store(HistoryEventProbe()))
        let coordinator = WorkoutHistoryImportCoordinator(store: Store(HistoryEventProbe()), canImport: { true })
        let authority = SavedWorkoutHistoryShareAuthority()
        let owners: [(@MainActor (ZeroOneShareRevocationRegistration?) -> Void,
                      @MainActor (ZeroOneShareRevocationRegistration?) -> Bool)] = [
            (repository.installShareRevocationRegistration, repository.isShareRevocationRegistered),
            (coordinator.installShareRevocationRegistration, coordinator.isShareRevocationRegistered),
            (authority.installShareRevocationRegistration, authority.isShareRevocationRegistered)
        ]
        for (install, matches) in owners {
            let oldProbe = HistoryEventProbe(); let incomingProbe = HistoryEventProbe()
            let oldRegistration = registration(oldProbe); let incoming = registration(incomingProbe)
            XCTAssertFalse(matches(nil)); XCTAssertFalse(matches(oldRegistration))
            let preexisting = oldProbe.issue(); install(oldRegistration)
            XCTAssertFalse(preexisting.allows); XCTAssertTrue(matches(oldRegistration))
            let old = oldProbe.issue(); let incomingOld = incomingProbe.issue()
            oldProbe.clear(); incomingProbe.clear(); install(incoming)
            XCTAssertEqual(oldProbe.events, ["revoke"]); XCTAssertEqual(incomingProbe.events, ["revoke"])
            XCTAssertFalse(old.allows); XCTAssertFalse(incomingOld.allows)
            XCTAssertFalse(matches(oldRegistration)); XCTAssertTrue(matches(incoming)); XCTAssertFalse(matches(nil))
            let reinstalled = incomingProbe.issue(); incomingProbe.clear(); install(incoming)
            XCTAssertEqual(incomingProbe.events, ["revoke"]); XCTAssertFalse(reinstalled.allows)
            let removed = incomingProbe.issue(); incomingProbe.clear(); install(nil)
            XCTAssertEqual(incomingProbe.events, ["revoke"]); XCTAssertFalse(removed.allows)
            XCTAssertFalse(matches(incoming)); XCTAssertFalse(matches(nil))
            let fresh = incomingProbe.issue(); XCTAssertTrue(fresh.allows); XCTAssertFalse(removed.allows)
        }
    }

    func testUnregisteredOwnersKeepExistingStorageBehaviorWithoutBecomingRegistered() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let repository = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try repository.record(session()), .inserted)
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: { true })
        let review = try coordinator.prepare(data: package([WorkoutHistoryEntry(session: session())]))
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertFalse(coordinator.isShareRevocationRegistered(nil)); XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(probe.events.contains("revoke"))
    }

    func testImportPrepareRevokesBeforeGateAndReadWithoutWriting() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let imported = WorkoutHistoryEntry(session: session()); let old = probe.issue(); probe.clear()
        let review = try coordinator.prepare(data: package([imported]))
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(review.records, [imported]); XCTAssertEqual(review.appendedCount, 1)
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testRejectedImportPrepareGateRevokesBeforeGateWithoutStoreAccess() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let coordinator = coordinator(store, probe, allowsImport: false)
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.prepare(data: package([]))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .workoutInProgress)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked"])
        XCTAssertNil(coordinator.review); XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testMalformedImportPrepareRevokesEvenThoughDecoderRejectsBeforeRead() {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.prepare(data: Data("not JSON".utf8))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .invalidFile)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked"])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testUnavailableImportPrepareRevokesBeforeReadAndPreservesStore() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); store.failLoad = true
        let coordinator = coordinator(store, probe); let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.prepare(data: package([]))) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyUnavailable)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testImportConfirmRevokesBeforeGateReadWriteAndReadback() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let imported = WorkoutHistoryEntry(session: session())
        let review = try coordinator.prepare(data: package([imported])); let old = probe.issue(); probe.clear()
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked",
                                     "save:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(result.confirmedEntries, [imported]); XCTAssertFalse(coordinator.needsReconciliation)
        XCTAssertNil(coordinator.review); XCTAssertEqual(store.saves, 1); XCTAssertFalse(old.allows)
    }

    func testExpiredConfirmationRevokesBeforeReviewGuardWithoutGateOrStore() {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: UUID())) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .reviewExpired)
        }
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testChangedHistoryConfirmationRevokesAndRejectsWithoutWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let review = try coordinator.prepare(data: package([WorkoutHistoryEntry(session: session())]))
        let intervening = WorkoutHistoryEntry(session: session()); store.entries = [intervening]
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyChanged)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(store.entries, [intervening]); XCTAssertEqual(store.saves, 0)
        XCTAssertNil(coordinator.review); XCTAssertFalse(old.allows)
    }

    func testRejectedConfirmationGateRevokesBeforeGateAndRetainsReviewWithoutWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); var gateOpen = true
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: {
            probe.observe("gate"); return gateOpen
        })
        coordinator.installShareRevocationRegistration(registration(probe))
        let review = try coordinator.prepare(data: package([WorkoutHistoryEntry(session: session())]))
        gateOpen = false; let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .workoutInProgress)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked"])
        XCTAssertEqual(coordinator.review?.id, review.id); XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(coordinator.needsReconciliation); XCTAssertFalse(old.allows)
    }

    func testConfirmationReadFailureRevokesAndRetainsReviewWithoutWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let review = try coordinator.prepare(data: package([WorkoutHistoryEntry(session: session())]))
        store.failLoad = true; let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .historyUnavailable)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(coordinator.review?.id, review.id); XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(coordinator.needsReconciliation); XCTAssertFalse(old.allows)
    }

    func testRejectedImportWriteKeepsOldPermitRevokedThroughSuccessfulRetry() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let imported = WorkoutHistoryEntry(session: session())
        let review = try coordinator.prepare(data: package([imported])); store.mode = .reject
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .writeUnconfirmed)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked", "save:revoked"])
        XCTAssertEqual(store.entries, []); XCTAssertTrue(coordinator.needsReconciliation); XCTAssertFalse(old.allows)
        store.mode = .normal; let retry = probe.issue(); probe.clear()
        XCTAssertEqual(try coordinator.confirm(reviewID: review.id).confirmedEntries, [imported])
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked",
                                     "save:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(store.saves, 2); XCTAssertFalse(retry.allows); XCTAssertFalse(old.allows)
    }

    func testImportFailedWriteReconciliationAndBlockedPrepareAlwaysRevoke() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let imported = WorkoutHistoryEntry(session: session())
        let review = try coordinator.prepare(data: package([imported])); store.mode = .landThenThrow
        let old = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .writeUnconfirmed)
        }
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked", "save:revoked"])
        XCTAssertTrue(coordinator.needsReconciliation); XCTAssertEqual(coordinator.review?.id, review.id)
        XCTAssertEqual(store.entries, [imported]); XCTAssertFalse(old.allows)
        let blocked = probe.issue(); probe.clear()
        XCTAssertThrowsError(try coordinator.prepare(data: Data())) {
            XCTAssertEqual($0 as? WorkoutHistoryImportError, .writeUnconfirmed)
        }
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(blocked.allows)
        let retry = probe.issue(); probe.clear()
        let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(result.confirmedEntries, [imported]); XCTAssertEqual(store.saves, 1)
        XCTAssertFalse(coordinator.needsReconciliation); XCTAssertFalse(retry.allows); XCTAssertFalse(old.allows)
    }

    func testDiscardRevokesPendingAndEmptyReviewWithoutTouchingSavedRecords() throws {
        let probe = HistoryEventProbe(); let store = Store(probe); let coordinator = coordinator(store, probe)
        let imported = WorkoutHistoryEntry(session: session())
        let review = try coordinator.prepare(data: package([imported])); store.mode = .landThenThrow
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        for _ in 0..<2 {
            let old = probe.issue(); probe.clear(); coordinator.discardReview()
            XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
            XCTAssertNil(coordinator.review); XCTAssertFalse(coordinator.needsReconciliation)
            XCTAssertEqual(store.entries, [imported]); XCTAssertEqual(store.saves, 1)
        }
    }

    func testDuplicateOnlyImportConfirmRevokesButDoesNotWrite() throws {
        let probe = HistoryEventProbe(); let store = Store(probe)
        let imported = WorkoutHistoryEntry(session: session()); store.entries = [imported]
        let coordinator = coordinator(store, probe); let review = try coordinator.prepare(data: package([imported]))
        let old = probe.issue(); probe.clear(); let result = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(probe.events, ["revoke", "gate:revoked", "availability:revoked", "load:revoked"])
        XCTAssertEqual(result.skippedCount, 1); XCTAssertEqual(result.appendedCount, 0)
        XCTAssertEqual(store.saves, 0); XCTAssertFalse(old.allows)
    }

    func testAuthorityInstallAndRevokePermanentlyRetireOldPermitsAndSnapshotGeneration() async throws {
        let probe = HistoryEventProbe(); let authority = SavedWorkoutHistoryShareAuthority()
        authority.installShareRevocationRegistration(registration(probe))
        let entry = WorkoutHistoryEntry(session: session()); let beforeInstall = probe.issue(); probe.clear()
        install(authority)
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(beforeInstall.allows)
        let resolved = await authority.resolve(entry); let oldSnapshot = try XCTUnwrap(resolved)
        let old = probe.issue(); probe.clear(); authority.revoke()
        XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
        let unavailable = await authority.resolve(entry); let oldAllowed = await authority.canExport(oldSnapshot)
        XCTAssertNil(unavailable); XCTAssertFalse(oldAllowed)
        install(authority); let fresh = probe.issue()
        let reopened = await authority.resolve(entry); let current = try XCTUnwrap(reopened)
        XCTAssertEqual(current.entry, oldSnapshot.entry)
        XCTAssertNotEqual(current.authorityGeneration, oldSnapshot.authorityGeneration)
        let staleAllowed = await authority.canExport(oldSnapshot); let freshAllowed = await authority.canExport(current)
        XCTAssertFalse(staleAllowed); XCTAssertTrue(freshAllowed); XCTAssertTrue(fresh.allows); XCTAssertFalse(old.allows)
    }

    func testAuthorityReinstallDuringSuspendedResolveRevokesAndRejectsOldResult() async {
        let probe = HistoryEventProbe(); let authority = SavedWorkoutHistoryShareAuthority()
        authority.installShareRevocationRegistration(registration(probe))
        authority.install(resolve: { entry, generation in
            await Task.yield()
            self.install(authority)
            return .init(entry: entry, acknowledgedHistory: [entry], authorityGeneration: generation)
        }, canExport: { _ in true })
        let old = probe.issue(); probe.clear()
        let result = await authority.resolve(WorkoutHistoryEntry(session: session()))
        XCTAssertNil(result); XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
    }

    func testAuthorityRevokeDuringSuspendedExportRevokesAndRejectsOldApproval() async throws {
        let probe = HistoryEventProbe(); let authority = SavedWorkoutHistoryShareAuthority()
        authority.installShareRevocationRegistration(registration(probe))
        install(authority, exporter: { _ in
            await Task.yield(); authority.revoke(); return true
        })
        let resolved = await authority.resolve(WorkoutHistoryEntry(session: session()))
        let snapshot = try XCTUnwrap(resolved); let old = probe.issue(); probe.clear()
        let allowed = await authority.canExport(snapshot)
        XCTAssertFalse(allowed); XCTAssertEqual(probe.events, ["revoke"]); XCTAssertFalse(old.allows)
    }

    private func registration(_ probe: HistoryEventProbe) -> ZeroOneShareRevocationRegistration {
        ZeroOneShareRevocationRegistration { probe.revoke() }
    }

    private func repository(_ store: Store, _ probe: HistoryEventProbe) -> WorkoutHistoryRepository {
        let repository = WorkoutHistoryRepository(store: store)
        repository.installShareRevocationRegistration(registration(probe)); return repository
    }

    private func coordinator(_ store: Store, _ probe: HistoryEventProbe,
                             allowsImport: Bool = true) -> WorkoutHistoryImportCoordinator {
        let coordinator = WorkoutHistoryImportCoordinator(store: store, canImport: {
            probe.observe("gate"); return allowsImport
        })
        coordinator.installShareRevocationRegistration(registration(probe)); return coordinator
    }

    private func install(_ authority: SavedWorkoutHistoryShareAuthority,
                         exporter: @escaping @MainActor (SavedWorkoutHistoryShareSnapshot) async -> Bool = { _ in true }) {
        authority.install(resolve: { entry, generation in
            .init(entry: entry, acknowledgedHistory: [entry], authorityGeneration: generation)
        }, canExport: exporter)
    }

    private func session() -> WorkoutSession {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_100.75)
        let set = CompletedSet(load: Load(42.125), reps: 8, rir: 2,
                               completedAt: Date(timeIntervalSinceReferenceDate: 1_000.25))
        let plan = ExercisePlan(name: "Bench press", targetLoad: set.load, targetReps: RepRange(8, 8),
                                plannedSetCount: 1, restSeconds: 90, previousPerformance: [])
        return WorkoutSession(title: "Synthetic saved workout",
                              exercises: [WorkoutExercise(plan: plan, completedSets: [set])], completedAt: completedAt)
    }

    private func changed(_ entry: WorkoutHistoryEntry, title: String) throws -> WorkoutHistoryEntry {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["title"] = title
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func package(_ entries: [WorkoutHistoryEntry]) throws -> Data {
        let records = try entries.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? [String: Any])
        }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 3, "exportedAt": 2_000.5,
            "workoutHistoryProvenance": "app-owned completed workout history",
            "selection": ["workouts": true, "mealsAndWater": false, "bodyWeight": false],
            "completedWorkouts": records
        ], options: [.sortedKeys])
    }

    private enum Failure: Error, Equatable { case read, write }
    private final class Store: WorkoutHistoryPersisting {
        enum Mode { case normal, reject, landThenThrow }
        let probe: HistoryEventProbe
        var entries: [WorkoutHistoryEntry] = []
        var available = true
        var failLoad = false
        var mode = Mode.normal
        var saves = 0
        var isAvailable: Bool { probe.observe("availability"); return available }
        init(_ probe: HistoryEventProbe) { self.probe = probe }
        func load() throws -> [WorkoutHistoryEntry] {
            probe.observe("load")
            if failLoad { throw Failure.read }
            return entries
        }
        func save(_ entries: [WorkoutHistoryEntry]) throws {
            probe.observe("save"); saves += 1
            if mode == .reject { throw Failure.write }
            self.entries = entries
            if mode == .landThenThrow { throw Failure.write }
        }
    }
}

// This is the only state captured by the Sendable invalidator. No actor-owned
// store, repository, authority, test case or UI state is read or re-entered.
private final class HistoryEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HistoryEventPermit?
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func issue() -> HistoryEventPermit {
        lock.lock(); defer { lock.unlock() }
        let fresh = HistoryEventPermit(); current = fresh; return fresh
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        current?.revoke(); recorded.append("revoke")
    }
    func observe(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event + (current?.allows == true ? ":VALID" : ":revoked"))
    }
    func clear() { lock.lock(); defer { lock.unlock() }; recorded.removeAll() }
}

private final class HistoryEventPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var allows: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func revoke() { lock.lock(); defer { lock.unlock() }; valid = false }
}
