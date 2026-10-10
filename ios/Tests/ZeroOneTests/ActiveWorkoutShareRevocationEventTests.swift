import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class ActiveWorkoutShareRevocationEventTests: XCTestCase {
    func testMissingRegistrationDoesNotBlockOfflineWorkoutCallbacks() {
        var cleared = false
        let model = WorkoutViewModel(session: session(), persistInitialSnapshot: false,
            onSnapshotChanged: { snapshot, _ in cleared = snapshot == nil })
        XCTAssertFalse(model.isShareRevocationRegistered(nil))
        XCTAssertTrue(model.clearSnapshotForExit())
        XCTAssertTrue(cleared)
        XCTAssertFalse(UserDefaultsActiveWorkoutStore().isShareRevocationRegistered(nil))
        XCTAssertFalse(FileActiveWorkoutStore().isShareRevocationRegistered(nil))
    }

    func testConstructionRevokesBeforeInitialSnapshotCallback() {
        let registry = ZeroOneSharePermitRegistry()
        let old = mint(registry)
        var writes = 0
        let initial = session()
        let model = WorkoutViewModel(session: initial, onSnapshotChanged: { snapshot, id in
            XCTAssertTrue(old.invalidated)
            XCTAssertEqual(snapshot?.session, initial)
            XCTAssertEqual(id, initial.id)
            writes += 1
        }, shareRevocationRegistration: registry.revocationRegistration)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(model.isShareRevocationRegistered(registry.revocationRegistration))
        XCTAssertFalse(model.isShareRevocationRegistered(nil))
    }

    func testSameIdentityRecoveryWithoutInitialWriteStillRevokes() {
        let registry = ZeroOneSharePermitRegistry()
        let old = mint(registry)
        let recovered = snapshot(session())
        var writes = 0
        let model = WorkoutViewModel(session: recovered.session, restoredSnapshot: recovered,
            observationDate: date, persistInitialSnapshot: false,
            onSnapshotChanged: { _, _ in writes += 1 },
            shareRevocationRegistration: registry.revocationRegistration)
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(model.session.id, recovered.session.id)
        XCTAssertEqual(model.enteredLoadValue, recovered.enteredLoadValue)
        XCTAssertEqual(model.enteredReps, recovered.enteredReps)
    }

    func testInstallReplaceRemoveAndReinstallCannotReviveOldPermit() {
        let first = ZeroOneSharePermitRegistry(), second = ZeroOneSharePermitRegistry()
        let model = WorkoutViewModel(session: session(), persistInitialSnapshot: false)
        let firstOld = mint(first)
        model.installShareRevocationRegistration(first.revocationRegistration)
        XCTAssertTrue(firstOld.invalidated)
        let beforeReplacement = mint(first), incoming = mint(second)
        model.installShareRevocationRegistration(second.revocationRegistration)
        XCTAssertTrue(beforeReplacement.invalidated)
        XCTAssertTrue(incoming.invalidated)
        XCTAssertFalse(model.isShareRevocationRegistered(first.revocationRegistration))
        XCTAssertTrue(model.isShareRevocationRegistered(second.revocationRegistration))
        let beforeRemoval = mint(second)
        model.installShareRevocationRegistration(nil)
        XCTAssertTrue(beforeRemoval.invalidated)
        XCTAssertFalse(model.isShareRevocationRegistered(second.revocationRegistration))
        model.installShareRevocationRegistration(first.revocationRegistration)
        XCTAssertTrue(firstOld.invalidated)
        XCTAssertTrue(beforeReplacement.invalidated)
        let sameInstance = mint(first)
        model.installShareRevocationRegistration(first.revocationRegistration)
        XCTAssertTrue(sameInstance.invalidated)
    }

    func testNestedSessionMutationRevokesBeforeWriteAndPauseResumePreserveState() {
        let registry = ZeroOneSharePermitRegistry()
        var pending: ActiveWorkoutEventPermit?
        var writes = 0
        let model = WorkoutViewModel(session: session(sets: 2), persistInitialSnapshot: false,
            onSnapshotChanged: { _, _ in
                XCTAssertTrue(pending?.invalidated == true)
                writes += 1
            }, shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        model.completeCurrentSet(at: date)
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertEqual(model.session.completedSetCount, 1)
        pending = mint(registry)
        model.togglePause(at: date.addingTimeInterval(1))
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(pending?.invalidated == true)
        pending = mint(registry)
        model.togglePause(at: date.addingTimeInterval(2))
        XCTAssertFalse(model.isPaused)
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertEqual(model.session.completedSetCount, 1)
        XCTAssertEqual(writes, 3)
    }

    func testNextSetAcknowledgementRevokesBeforeItsSeparateSnapshotCallback() {
        let registry = ZeroOneSharePermitRegistry()
        var pending: ActiveWorkoutEventPermit?
        var writes = 0
        let model = WorkoutViewModel(session: session(sets: 2), persistInitialSnapshot: false,
            onSnapshotChanged: { _, _ in
                XCTAssertTrue(pending?.invalidated == true)
                writes += 1
            }, shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        model.completeCurrentSet(at: date)
        XCTAssertTrue(model.awaitingNextSetAcknowledgement)
        pending = mint(registry)
        model.acknowledgeNextSet(at: date.addingTimeInterval(1))
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertFalse(model.awaitingNextSetAcknowledgement)
        XCTAssertEqual(model.session.completedSetCount, 1)
        XCTAssertEqual(writes, 2)
    }

    func testFinalReviewWriteDoesNotCommitHistoryAndExplicitFinishStillRevokes() {
        let registry = ZeroOneSharePermitRegistry()
        var pending: ActiveWorkoutEventPermit?
        var events: [String] = []
        let model = WorkoutViewModel(session: session(), persistInitialSnapshot: false,
            requiresFinalSetReview: true,
            onSnapshotChanged: { value, _ in
                XCTAssertTrue(pending?.invalidated == true)
                events.append(value == nil ? "clear" : "snapshot")
                pending = self.mint(registry)
            }, onSessionCompleted: { _ in
                XCTAssertTrue(pending?.invalidated == true)
                events.append("history")
                pending = self.mint(registry)
                return .inserted
            }, shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        model.completeCurrentSet(at: date)
        XCTAssertEqual(events, ["snapshot"])
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertTrue(model.awaitingFinalSetConfirmation)
        XCTAssertFalse(model.isCompletionSaved)
        pending = mint(registry)
        model.confirmFinalSetAndFinish(at: date.addingTimeInterval(1))
        XCTAssertEqual(events, ["snapshot", "snapshot", "history", "clear"])
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertTrue(model.isCompletionSaved)
        XCTAssertEqual(model.completionFeedbackCount, 1)
    }

    func testFailureReadinessPublicationRevokesEvenPermitCreatedInsideFailingCallback() {
        let registry = ZeroOneSharePermitRegistry()
        var old: ActiveWorkoutEventPermit?
        var duringFailure: ActiveWorkoutEventPermit?
        let model = WorkoutViewModel(session: session(), persistInitialSnapshot: false,
            onSnapshotChanged: { _, _ in
                XCTAssertTrue(old?.invalidated == true)
                // Adversarial fixture isolates the subsequent readiness setter;
                // production may never activate merely because a write started.
                duringFailure = self.mint(registry)
                throw ActiveWorkoutEventFailure.write
            }, shareRevocationRegistration: registry.revocationRegistration)
        old = mint(registry)
        model.enteredReps = 9
        XCTAssertTrue(old?.invalidated == true)
        XCTAssertTrue(duringFailure?.invalidated == true)
        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.enteredReps, 9)
    }

    func testCompletedRecoveryKeepsExactPayloadAndWriteAheadHistoryClearOrder() throws {
        let registry = ZeroOneSharePermitRegistry()
        var complete = session()
        _ = try complete.completeCurrentSet(load: Load(10), reps: 8, at: date)
        let recovered = snapshot(complete)
        var pending = mint(registry)
        var events: [String] = []
        let model = WorkoutViewModel(session: complete, restoredSnapshot: recovered,
            onSnapshotChanged: { value, id in
                XCTAssertTrue(pending.invalidated)
                XCTAssertEqual(id, complete.id)
                if let value {
                    XCTAssertEqual(value, recovered)
                    events.append("write-ahead")
                } else { events.append("clear") }
                pending = self.mint(registry)
            }, onSessionCompleted: { value in
                XCTAssertTrue(pending.invalidated)
                XCTAssertEqual(value, complete)
                events.append("history")
                pending = self.mint(registry)
                return .alreadyRecorded
            }, shareRevocationRegistration: registry.revocationRegistration)
        XCTAssertEqual(events, ["write-ahead", "history", "clear"])
        XCTAssertTrue(pending.invalidated)
        XCTAssertTrue(model.isCompletionSaved)
        XCTAssertEqual(model.completionFeedbackCount, 0)
        XCTAssertEqual(model.lastCompletionRecordResult, .alreadyRecorded)
    }

    func testFailedWriteAheadDoesNotCallHistoryOrClearAndRetryUsesNewPermit() throws {
        let registry = ZeroOneSharePermitRegistry()
        var complete = session()
        _ = try complete.completeCurrentSet(load: Load(10), reps: 8, at: date)
        var fail = true, historyCalls = 0, clears = 0
        var pending: ActiveWorkoutEventPermit?
        let model = WorkoutViewModel(session: complete, persistInitialSnapshot: false,
            onSnapshotChanged: { value, _ in
                XCTAssertTrue(pending?.invalidated == true)
                if value == nil { clears += 1 }
                if fail { throw ActiveWorkoutEventFailure.write }
            }, onSessionCompleted: { _ in historyCalls += 1; return .inserted },
            shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        let first = pending
        model.retryPersistence(at: date)
        XCTAssertTrue(first?.invalidated == true)
        XCTAssertFalse(model.isCompletionSaved)
        XCTAssertEqual(historyCalls, 0)
        XCTAssertEqual(clears, 0)
        fail = false
        pending = mint(registry)
        model.retryPersistence(at: date)
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertTrue(first?.invalidated == true)
        XCTAssertTrue(model.isCompletionSaved)
        XCTAssertEqual(historyCalls, 1)
        XCTAssertEqual(clears, 1)
    }

    func testFailedHistoryLeavesWriteAheadRecoverableAndDoesNotClear() throws {
        let registry = ZeroOneSharePermitRegistry()
        var complete = session()
        _ = try complete.completeCurrentSet(load: Load(10), reps: 8, at: date)
        var events: [String] = [], pending: ActiveWorkoutEventPermit?
        let model = WorkoutViewModel(session: complete, persistInitialSnapshot: false,
            onSnapshotChanged: { value, _ in
                XCTAssertTrue(pending?.invalidated == true)
                events.append(value == nil ? "clear" : "write-ahead")
                pending = self.mint(registry)
            }, onSessionCompleted: { _ in
                XCTAssertTrue(pending?.invalidated == true)
                events.append("history-failed")
                throw ActiveWorkoutEventFailure.write
            }, shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        model.retryPersistence(at: date)
        XCTAssertEqual(events, ["write-ahead", "history-failed"])
        XCTAssertFalse(model.isCompletionSaved)
        XCTAssertNotNil(model.persistenceErrorMessage)
    }

    func testFailedExitRevokesBeforeClearAndKeepsRetryGate() {
        let registry = ZeroOneSharePermitRegistry()
        var pending: ActiveWorkoutEventPermit?
        let model = WorkoutViewModel(session: session(), persistInitialSnapshot: false,
            onSnapshotChanged: { value, _ in
                XCTAssertNil(value)
                XCTAssertTrue(pending?.invalidated == true)
                throw ActiveWorkoutEventFailure.write
            }, shareRevocationRegistration: registry.revocationRegistration)
        pending = mint(registry)
        XCTAssertFalse(model.clearSnapshotForExit())
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.session.completedSetCount, 0)
    }

    func testDefaultsStoreSameBytesSaveAndConflictingClearRevokeWithoutErasure() throws {
        let name = "ActiveWorkoutShareEvents-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = ZeroOneSharePermitRegistry()
        let constructed = mint(registry)
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "active",
            shareRevocationRegistration: registry.revocationRegistration)
        XCTAssertTrue(constructed.invalidated)
        XCTAssertTrue(store.isShareRevocationRegistered(registry.revocationRegistration))
        let value = snapshot(session())
        try store.save(value)
        let sameBytes = mint(registry)
        try store.save(value)
        XCTAssertTrue(sameBytes.invalidated)
        XCTAssertEqual(try store.load(), value)
        // Encoded key order can differ between saves; the promise is that a failed clear erases nothing.
        let beforeConflict = defaults.data(forKey: "active")
        let conflict = mint(registry)
        XCTAssertThrowsError(try store.clear(expectedSessionID: UUID()))
        XCTAssertTrue(conflict.invalidated)
        XCTAssertEqual(defaults.data(forKey: "active"), beforeConflict)
        let clearing = mint(registry)
        try store.clear(expectedSessionID: value.session.id)
        XCTAssertTrue(clearing.invalidated)
        XCTAssertNil(try store.load())
    }

    func testDefaultsInvalidSnapshotAndMalformedRecoveryFailClosedWithoutChangingBytes() throws {
        let name = "ActiveWorkoutShareEvents-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = ZeroOneSharePermitRegistry()
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "active",
            shareRevocationRegistration: registry.revocationRegistration)
        let invalid = mint(registry)
        XCTAssertThrowsError(try store.save(snapshot(session(), version: 999)))
        XCTAssertTrue(invalid.invalidated)
        XCTAssertNil(defaults.data(forKey: "active"))
        let malformed = Data("malformed".utf8)
        defaults.set(malformed, forKey: "active")
        let held = mint(registry)
        XCTAssertThrowsError(try store.clear(expectedSessionID: UUID()))
        XCTAssertTrue(held.invalidated)
        XCTAssertEqual(defaults.data(forKey: "active"), malformed)
    }

    func testFileSaveAndClearRevokeBeforeLegacyReadIncludingEmptyTombstone() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ZeroOneSharePermitRegistry()
        var pending: ActiveWorkoutEventPermit?
        var reads = 0
        let legacy = ActiveWorkoutEventLegacyStore {
            XCTAssertTrue(pending?.invalidated == true)
            reads += 1
            return nil
        }
        let constructed = mint(registry)
        let store = FileActiveWorkoutStore(directory: directory, legacyStore: legacy,
            shareRevocationRegistration: registry.revocationRegistration)
        XCTAssertTrue(constructed.invalidated)
        XCTAssertTrue(store.isShareRevocationRegistered(registry.revocationRegistration))
        pending = mint(registry)
        try store.clear(expectedSessionID: UUID())
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try store.load())
        XCTAssertEqual(reads, 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("active-workout.json"))
        pending = mint(registry)
        let value = snapshot(session())
        try store.save(value)
        XCTAssertTrue(pending?.invalidated == true)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(try store.load(), value)
    }

    func testFileConflictFailedWriteAndCopiedStoreRetainExactRegistration() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ZeroOneSharePermitRegistry()
        let legacy = ActiveWorkoutEventLegacyStore { nil }
        let store = FileActiveWorkoutStore(directory: directory, legacyStore: legacy,
            shareRevocationRegistration: registry.revocationRegistration)
        let copy = store
        XCTAssertTrue(copy.isShareRevocationRegistered(registry.revocationRegistration))
        XCTAssertFalse(copy.isShareRevocationRegistered(ZeroOneShareRevocationRegistration {}))
        let value = snapshot(session())
        try store.save(value)
        let url = directory.appendingPathComponent("active-workout.json")
        let bytes = try Data(contentsOf: url)
        let conflict = mint(registry)
        XCTAssertThrowsError(try copy.save(snapshot(session())))
        XCTAssertTrue(conflict.invalidated)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let clearConflict = mint(registry)
        XCTAssertThrowsError(try copy.clear(expectedSessionID: UUID()))
        XCTAssertTrue(clearConflict.invalidated)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let blocked = directory.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        let failing = FileActiveWorkoutStore(directory: blocked, legacyStore: legacy,
            shareRevocationRegistration: registry.revocationRegistration)
        let failed = mint(registry)
        XCTAssertThrowsError(try failing.save(value))
        XCTAssertTrue(failed.invalidated)
        XCTAssertEqual(try Data(contentsOf: blocked), Data([1]))
    }

    func testSuccessfulReadDoesNotRevokeOrReactivateOldPermit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ZeroOneSharePermitRegistry()
        let store = FileActiveWorkoutStore(directory: directory,
            legacyStore: ActiveWorkoutEventLegacyStore { nil },
            shareRevocationRegistration: registry.revocationRegistration)
        let value = snapshot(session())
        let old = mint(registry)
        try store.save(value)
        XCTAssertTrue(old.invalidated)
        let fresh = mint(registry)
        XCTAssertEqual(try store.load(), value)
        XCTAssertFalse(fresh.invalidated)
        XCTAssertTrue(old.invalidated)
    }

    private let date = Date(timeIntervalSince1970: 1_000)

    private func session(sets: Int = 1) -> WorkoutSession {
        WorkoutSession(title: "Fixture", customWorkoutID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, exercises: [WorkoutExercise(plan: ExercisePlan(
            exerciseID: ExerciseIDs.gobletSquat, name: "Goblet Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: sets, restSeconds: 0, previousPerformance: []))])
    }

    private func snapshot(_ session: WorkoutSession, version: Int = ActiveWorkoutSnapshot.currentVersion) -> ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(version: version, session: session, enteredLoadValue: 10,
            enteredReps: 8, enteredRIR: nil, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ActiveWorkoutShareEvents-\(UUID().uuidString)")
    }

    private func mint(_ registry: ZeroOneSharePermitRegistry) -> ActiveWorkoutEventPermit {
        // Fixture activation proves invalidation only, never complete root readiness.
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let permit = ActiveWorkoutEventPermit()
        XCTAssertNotNil(registry.register(permit, for: generation))
        return permit
    }
}

private enum ActiveWorkoutEventFailure: Error { case write }

private final class ActiveWorkoutEventPermit: ZeroOneShareRevocablePermit, @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func invalidate() { lock.lock(); revoked = true; lock.unlock() }
    var invalidated: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
}

private final class ActiveWorkoutEventLegacyStore: ActiveWorkoutPersisting {
    private let read: () throws -> ActiveWorkoutSnapshot?
    init(read: @escaping () throws -> ActiveWorkoutSnapshot?) { self.read = read }
    func load() throws -> ActiveWorkoutSnapshot? { try read() }
    func save(_ snapshot: ActiveWorkoutSnapshot) throws { throw ActiveWorkoutEventFailure.write }
    func clear(expectedSessionID: UUID) throws { throw ActiveWorkoutEventFailure.write }
}
