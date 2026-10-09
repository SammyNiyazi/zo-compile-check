import XCTest
@testable import ZeroOne

@MainActor
final class DietTrackerFeatureModelTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Sofia")!
    private let date = Date(timeIntervalSince1970: 1_791_449_400)

    func testConfirmedTickAndUndoUseOneActualScheduledLog() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        var draft = DietTrackerDraft()
        draft.name = "My entered tracker"
        draft.times = [.init(hour: 8, minute: 0), .init(hour: 12, minute: 30)]
        _ = try repository.add(draft, at: date)
        let model = DietTrackerFeatureModel(repository: repository, now: { self.date }, timeZone: { self.zone })
        let first = try XCTUnwrap(model.checklist?.first)
        XCTAssertTrue(model.toggle(first))
        XCTAssertEqual(repository.snapshot.completions.count, 1)
        XCTAssertEqual(model.checklist?.filter(\.isCompleted).count, 1)
        let checked = try XCTUnwrap(model.checklist?.first)
        XCTAssertTrue(model.toggle(checked))
        XCTAssertTrue(repository.snapshot.completions.isEmpty)
        XCTAssertEqual(repository.activeTrackers.first?.times.map(\.id), draft.times.map(\.id))
    }

    func testDayChangeRejectsOldVisibleCheckboxBeforeWriting() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        var draft = DietTrackerDraft(); draft.name = "User choice"
        _ = try repository.add(draft, at: date)
        var clock = date
        let model = DietTrackerFeatureModel(repository: repository, now: { clock }, timeZone: { self.zone })
        let old = try XCTUnwrap(model.checklist?.first)
        clock = old.day.end
        let writes = store.writes
        XCTAssertFalse(model.toggle(old))
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(repository.snapshot.completions.isEmpty)
        XCTAssertNotEqual(model.day, old.day)
    }

    func testFailureBeforeWriteAllowsRetryOnlyAfterUnchangedReadback() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        let model = DietTrackerFeatureModel(repository: repository, now: { self.date }, timeZone: { self.zone })
        var draft = DietTrackerDraft(); draft.name = "Keep this draft"
        store.failure = .beforeWrite
        XCTAssertFalse(model.save(draft))
        XCTAssertFalse(model.requiresSavedDataReview)
        XCTAssertTrue(repository.activeTrackers.isEmpty)
        store.failure = .none
        XCTAssertTrue(model.save(draft))
        XCTAssertEqual(repository.activeTrackers.map(\.name), [draft.name])
    }

    func testWriteThenFailureCannotBlindlyDuplicateNewTracker() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        let model = DietTrackerFeatureModel(repository: repository, now: { self.date }, timeZone: { self.zone })
        var draft = DietTrackerDraft(); draft.name = "Actually saved but not acknowledged"
        store.failure = .afterWrite
        XCTAssertFalse(model.save(draft))
        XCTAssertTrue(model.requiresSavedDataReview)
        XCTAssertEqual(repository.activeTrackers.count, 1)
        let writes = store.writes
        store.failure = .none
        model.refresh()
        XCTAssertFalse(model.save(draft))
        XCTAssertEqual(store.writes, writes)
        XCTAssertEqual(repository.activeTrackers.count, 1)
    }

    func testStaleEditorCannotReplaceNewerUserDetails() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        var draft = DietTrackerDraft(); draft.name = "Original"
        let original = try repository.add(draft, at: date)
        let oldEditor = DietTrackerDraft(tracker: original)
        var newEditor = oldEditor; newEditor.name = "Newer user details"
        _ = try repository.update(newEditor, at: date.addingTimeInterval(1))
        let model = DietTrackerFeatureModel(repository: repository, now: { self.date.addingTimeInterval(2) }, timeZone: { self.zone })
        XCTAssertFalse(model.save(oldEditor))
        XCTAssertTrue(model.requiresSavedDataReview)
        XCTAssertEqual(repository.activeTrackers.first?.name, "Newer user details")
    }

    func testFailedCheckboxSaveNeverDisplaysOptimisticCompletion() throws {
        let store = Store()
        let repository = DietTrackerRepository(store: store)
        var draft = DietTrackerDraft(); draft.name = "No invented tick"
        _ = try repository.add(draft, at: date)
        let model = DietTrackerFeatureModel(repository: repository, now: { self.date }, timeZone: { self.zone })
        let row = try XCTUnwrap(model.checklist?.first)
        store.failure = .beforeWrite
        XCTAssertFalse(model.toggle(row))
        XCTAssertEqual(model.checklist?.first?.isCompleted, false)
        XCTAssertNotNil(model.errorMessage)
    }

    private final class Store: DietTrackerPersisting {
        enum Failure { case none, beforeWrite, afterWrite }
        var snapshot = DietTrackerSnapshot.empty
        var failure = Failure.none
        var writes = 0
        func load() throws -> DietTrackerSnapshot { snapshot }
        func save(_ candidate: DietTrackerSnapshot, replacing baseline: DietTrackerSnapshot) throws {
            guard snapshot == baseline else { throw DietTrackerError.storeChanged }
            if failure == .beforeWrite { throw DietTrackerError.saveFailed }
            writes += 1
            snapshot = candidate
            if failure == .afterWrite { throw DietTrackerError.saveFailed }
        }
    }
}
