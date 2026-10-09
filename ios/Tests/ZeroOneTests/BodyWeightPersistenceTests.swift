import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class BodyWeightPersistenceTests: XCTestCase {
    func testDiscardedCreateAndCorrectionAreNotPublishedAsSuccess() throws {
        let original = reading(70)
        let store = WeightPersistenceStore(values: [original])
        let repository = BodyWeightRepository(store: store)
        store.discardWrites = true
        XCTAssertThrowsError(try repository.save(reading(71))) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .verificationFailed)
        }
        let correction = BodyWeightEntry(id: original.id, recordedAt: original.recordedAt, kilograms: 72)
        XCTAssertThrowsError(try repository.replace(original, with: correction))
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.values, [original])
    }

    func testDiscardedDeleteKeepsReadingVisible() {
        let original = reading(70)
        let store = WeightPersistenceStore(values: [original])
        let repository = BodyWeightRepository(store: store)
        store.discardWrites = true
        XCTAssertThrowsError(try repository.delete(original))
        XCTAssertEqual(repository.entries, [original])
    }

    func testMalformedSavedCollectionIsPreservedAndNeverRewritten() {
        let original = reading(70)
        let duplicate = WeightPersistenceStore(values: [original, original])
        let duplicateRepository = BodyWeightRepository(store: duplicate)
        XCTAssertFalse(duplicateRepository.isAvailable)
        XCTAssertThrowsError(try duplicateRepository.save(reading(72)))
        XCTAssertEqual(duplicate.writes, 0)
        XCTAssertEqual(duplicate.values, [original, original])

        let invalid = WeightPersistenceStore(values: [reading(-1)])
        XCTAssertFalse(BodyWeightRepository(store: invalid).isAvailable)
        XCTAssertEqual(invalid.writes, 0)
        let badDate = WeightPersistenceStore(values: [BodyWeightEntry(id: UUID(),
            recordedAt: Date(timeIntervalSinceReferenceDate: .infinity), kilograms: 70)])
        XCTAssertFalse(BodyWeightRepository(store: badDate).isAvailable)
    }

    func testReadFailureKeepsMemoryAndCanRecoverWithoutSavingDraft() throws {
        let original = reading(70)
        let store = WeightPersistenceStore(values: [original])
        let repository = BodyWeightRepository(store: store)
        store.failReads = true
        XCTAssertThrowsError(try repository.save(reading(71)))
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.writes, 0)
        store.failReads = false
        repository.reload()
        XCTAssertTrue(repository.isAvailable)
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.writes, 0)
    }

    func testAcknowledgmentErrorAfterWriteIsNotSilentlyConvertedToSuccess() throws {
        let store = WeightPersistenceStore()
        let repository = BodyWeightRepository(store: store)
        let entry = reading(71)
        store.failAfterWrite = true
        XCTAssertThrowsError(try repository.save(entry))
        XCTAssertTrue(repository.entries.isEmpty)
        XCTAssertEqual(store.values, [entry])
        // The same ID retries the store's save/metadata work, not a second entry.
        store.failAfterWrite = false
        try repository.save(entry)
        XCTAssertEqual(repository.entries, [entry])
        XCTAssertEqual(store.values.count, 1)
    }

    func testReadbackVerifiesUnrelatedReadingsToo() {
        let original = reading(70)
        let store = WeightPersistenceStore(values: [original])
        let repository = BodyWeightRepository(store: store)
        store.dropIDOnWrite = original.id
        let added = reading(71)
        XCTAssertThrowsError(try repository.save(added)) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .verificationFailed)
        }
        // Publish only actual readable state, never the proposed whole list.
        XCTAssertEqual(repository.entries, [added])
    }

    func testUnreadableReadbackRequiresReloadBeforeRetry() throws {
        let original = reading(70)
        let store = WeightPersistenceStore(values: [original])
        let repository = BodyWeightRepository(store: store)
        let added = reading(71)
        store.failReadsAfterWrite = true
        XCTAssertThrowsError(try repository.save(added))
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.values.count, 2)
        XCTAssertThrowsError(try repository.save(added))
        XCTAssertEqual(store.writes, 1)

        store.failReads = false
        store.failReadsAfterWrite = false
        repository.reload()
        XCTAssertTrue(repository.isAvailable)
        try repository.save(added)
        XCTAssertEqual(Set(repository.entries.map(\.id)), Set([original.id, added.id]))
        XCTAssertEqual(repository.entries.count, 2)
    }

    private func reading(_ kilograms: Decimal) -> BodyWeightEntry {
        BodyWeightEntry(id: UUID(), recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            kilograms: kilograms)
    }
}

private final class WeightPersistenceStore: BodyWeightPersisting {
    var values: [BodyWeightEntry]
    var writes = 0
    var discardWrites = false
    var failReads = false
    var failAfterWrite = false
    var failReadsAfterWrite = false
    var dropIDOnWrite: UUID?
    init(values: [BodyWeightEntry] = []) { self.values = values }
    func load() throws -> [BodyWeightEntry] {
        if failReads { throw BodyWeightStoreError.unavailable }
        return values
    }
    func save(_ proposed: [BodyWeightEntry]) throws {
        writes += 1
        if !discardWrites { values = proposed.filter { $0.id != dropIDOnWrite } }
        if failReadsAfterWrite { failReads = true }
        if failAfterWrite { throw BodyWeightStoreError.unavailable }
    }
}
