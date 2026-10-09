import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class ProgressPhotoShareRevocationEventTests: XCTestCase {
    func testSaveRevokesBeforeExactStoreWriteAndPreservesDraftFacts() throws {
        let bank = PermitBank(); let store = Store(bank: bank)
        let repository = ProgressPhotoRepository(store: store)
        let registration = registration(bank)
        repository.installShareRevocationRegistration(registration)
        let old = bank.issue(); bank.clearEvents()
        let draft = draft()
        let saved = try repository.save(draft)
        XCTAssertEqual(bank.events, ["revoke", "save:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(saved.id, draft.id)
        XCTAssertEqual(saved.createdAt, draft.createdAt)
        XCTAssertEqual(saved.label, draft.label)
        XCTAssertEqual(store.savedImage, draft.imageData)
        XCTAssertEqual(store.savedThumbnail, draft.thumbnailData)
        XCTAssertEqual(saved.imageRelativePath, LocalProgressPhotoStore.relativePaths(for: draft.id).image)
        XCTAssertEqual(repository.entries, [saved])
    }

    func testFailedSaveStillRevokesBeforeStoreAndPreservesCachedEntries() throws {
        let bank = PermitBank(); let store = Store(bank: bank)
        let original = record(); store.records = [original]; store.failSave = true
        let repository = ProgressPhotoRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        XCTAssertThrowsError(try repository.save(draft())) { XCTAssertEqual($0 as? Failure, .write) }
        XCTAssertEqual(bank.events, ["revoke", "save:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.entries, [original])
    }

    func testDeleteRevokesBeforeStoreAndRemovesOnlyRequestedRecord() throws {
        let bank = PermitBank(); let store = Store(bank: bank)
        let first = record(); let second = record(); store.records = [first, second]
        let repository = ProgressPhotoRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        try repository.delete(first)
        XCTAssertEqual(bank.events, ["revoke", "delete:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(store.deleted, first)
        XCTAssertEqual(repository.entries, [second])
    }

    func testFailedDeleteStillRevokesAndPreservesCachedEntries() throws {
        let bank = PermitBank(); let store = Store(bank: bank)
        let original = record(); store.records = [original]; store.failDelete = true
        let repository = ProgressPhotoRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        XCTAssertThrowsError(try repository.delete(original)) { XCTAssertEqual($0 as? Failure, .write) }
        XCTAssertEqual(bank.events, ["revoke", "delete:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.entries, [original])
    }

    func testUnavailableSaveAndDeleteAttemptsRevokeBeforeExistingGuard() {
        let bank = PermitBank(); let store = Store(bank: bank); store.isAvailable = false
        let repository = ProgressPhotoRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let saveLease = bank.issue(); bank.clearEvents()
        XCTAssertThrowsError(try repository.save(draft())) { XCTAssertEqual($0 as? ProgressPhotoStoreError, .unavailable) }
        XCTAssertEqual(bank.events, ["revoke"])
        XCTAssertFalse(saveLease.allows)
        let deleteLease = bank.issue(); bank.clearEvents()
        XCTAssertThrowsError(try repository.delete(record())) { XCTAssertEqual($0 as? ProgressPhotoStoreError, .unavailable) }
        XCTAssertEqual(bank.events, ["revoke"])
        XCTAssertFalse(deleteLease.allows)
    }

    func testReplacementRevokesOldAndIncomingPermitsBeforeIdentityChanges() {
        let oldBank = PermitBank(); let incomingBank = PermitBank()
        let repository = ProgressPhotoRepository(store: Store(bank: oldBank))
        let oldRegistration = registration(oldBank); let incoming = registration(incomingBank)
        repository.installShareRevocationRegistration(oldRegistration)
        let old = oldBank.issue(); let incomingLease = incomingBank.issue()
        repository.installShareRevocationRegistration(incoming)
        XCTAssertFalse(old.allows); XCTAssertFalse(incomingLease.allows)
        XCTAssertFalse(repository.isShareRevocationRegistered(oldRegistration))
        XCTAssertTrue(repository.isShareRevocationRegistered(incoming))
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
    }

    func testRemovalRevokesAndFutureUnregisteredMutationKeepsExistingBehavior() throws {
        let bank = PermitBank(); let store = Store(bank: bank)
        let repository = ProgressPhotoRepository(store: store); let installed = registration(bank)
        repository.installShareRevocationRegistration(installed)
        let old = bank.issue()
        repository.installShareRevocationRegistration(nil)
        XCTAssertFalse(old.allows)
        XCTAssertFalse(repository.isShareRevocationRegistered(installed))
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
        bank.clearEvents()
        let saved = try repository.save(draft())
        XCTAssertEqual(bank.events, ["save:revoked"])
        XCTAssertEqual(repository.entries, [saved])
    }

    func testReinstallingSameRegistrationCannotReopenOldPermit() {
        let bank = PermitBank(); let repository = ProgressPhotoRepository(store: Store(bank: bank))
        let installed = registration(bank)
        repository.installShareRevocationRegistration(installed)
        let old = bank.issue(); bank.clearEvents()
        repository.installShareRevocationRegistration(installed)
        XCTAssertEqual(bank.events, ["revoke"])
        XCTAssertFalse(old.allows)
        let fresh = bank.issue()
        XCTAssertTrue(fresh.allows); XCTAssertFalse(old.allows)
        XCTAssertTrue(repository.isShareRevocationRegistered(installed))
    }

    func testReadOnlyImageAccessAndRegistrationMatchDoNotRevoke() {
        let bank = PermitBank(); let store = Store(bank: bank); let saved = record(); store.records = [saved]
        let repository = ProgressPhotoRepository(store: store); let installed = registration(bank)
        repository.installShareRevocationRegistration(installed)
        let old = bank.issue(); bank.clearEvents()
        XCTAssertTrue(repository.isShareRevocationRegistered(installed))
        XCTAssertEqual(repository.imageData(for: saved), Data([1, 2]))
        XCTAssertEqual(repository.thumbnailData(for: saved), Data([3]))
        XCTAssertEqual(bank.events, [])
        XCTAssertTrue(old.allows)
    }

    func testConfiguredLocalStoreRetainsExactMasterAndManifestLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actualStore = LocalProgressPhotoStore(rootURL: root)
        let bank = PermitBank(); let repository = ProgressPhotoRepository(store: actualStore)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); let source = draft()
        let saved = try repository.save(source)
        XCTAssertFalse(old.allows)
        XCTAssertEqual(try actualStore.loadRecords(), [saved])
        XCTAssertEqual(actualStore.data(at: saved.imageRelativePath, for: saved), source.imageData)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.imageRelativePath)), source.imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("records.json").path))
        let deleteLease = bank.issue()
        try repository.delete(saved)
        XCTAssertFalse(deleteLease.allows)
        XCTAssertEqual(try actualStore.loadRecords(), [])
    }

    private func registration(_ bank: PermitBank) -> ZeroOneShareRevocationRegistration {
        ZeroOneShareRevocationRegistration { bank.revoke() }
    }
    private func draft() -> ProgressPhotoDraft {
        .init(id: UUID(), createdAt: Date(timeIntervalSince1970: 123), label: .postWorkout,
              imageData: Data([1, 2]), thumbnailData: Data([3]))
    }
    private func record() -> ProgressPhotoRecord {
        let id = UUID(); let paths = LocalProgressPhotoStore.relativePaths(for: id)
        return .init(id: id, createdAt: Date(timeIntervalSince1970: 100), label: .progress,
                     imageRelativePath: paths.image, thumbnailRelativePath: paths.thumbnail)
    }

    private enum Failure: Error, Equatable { case write }
    private final class Store: ProgressPhotoPersisting {
        let bank: PermitBank
        var isAvailable = true
        var records: [ProgressPhotoRecord] = []
        var failSave = false
        var failDelete = false
        var savedImage: Data?
        var savedThumbnail: Data?
        var deleted: ProgressPhotoRecord?
        init(bank: PermitBank) { self.bank = bank }
        func loadRecords() throws -> [ProgressPhotoRecord] { records }
        func data(at path: String, for record: ProgressPhotoRecord) -> Data? {
            path == record.imageRelativePath ? Data([1, 2]) : Data([3])
        }
        func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws {
            bank.observeWrite("save")
            if failSave { throw Failure.write }
            savedImage = imageData; savedThumbnail = thumbnailData
            records.removeAll { $0.id == record.id }; records.append(record)
        }
        func delete(_ record: ProgressPhotoRecord) throws {
            bank.observeWrite("delete")
            if failDelete { throw Failure.write }
            deleted = record; records.removeAll { $0.id == record.id }
        }
    }
}

// Synthetic thread-safe retained permits. Each issued permit is permanent;
// issuing a replacement cannot reactivate an earlier revoked instance.
private final class EventPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var allows: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func revoke() { lock.lock(); defer { lock.unlock() }; valid = false }
}

private final class PermitBank: @unchecked Sendable {
    private let lock = NSLock()
    private var permit: EventPermit?
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func issue() -> EventPermit {
        lock.lock(); defer { lock.unlock() }
        let fresh = EventPermit(); permit = fresh; return fresh
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        permit?.revoke(); recorded.append("revoke")
    }
    func observeWrite(_ kind: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(kind + (permit?.allows == true ? ":VALID" : ":revoked"))
    }
    func clearEvents() { lock.lock(); defer { lock.unlock() }; recorded.removeAll() }
}
