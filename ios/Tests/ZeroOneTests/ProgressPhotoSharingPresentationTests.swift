import Foundation
import XCTest
@testable import ZeroOne

final class ProgressPhotoSharingPresentationTests: XCTestCase {
    private func photo(_ id: Int, time: TimeInterval = 100, label: ProgressPhotoLabel = .progress,
                       image: String = "image", thumbnail: String = "thumbnail") -> ProgressPhotoRecord {
        ProgressPhotoRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            createdAt: Date(timeIntervalSince1970: time), label: label,
            imageRelativePath: image, thumbnailRelativePath: thumbnail)
    }

    func testUncapturedSelectionDoesNotAuthorizeDefaultPair() {
        let records = [photo(1), photo(2)]
        XCTAssertNotNil(ProgressPhotoPair.resolve(records: records, firstID: nil, secondID: nil))
        XCTAssertNil(ProgressPhotoPair.selected(records: records, firstID: nil, secondID: nil))
    }

    func testExactSelectionPreservesUserSlotOrderAndEqualTimestamps() throws {
        let first = photo(1), second = photo(2)
        let selected = try XCTUnwrap(ProgressPhotoPair.selected(records: [first, second],
            firstID: second.id, secondID: first.id))
        XCTAssertEqual(selected.first, second)
        XCTAssertEqual(selected.second, first)
        XCTAssertEqual(selected.labelKey(firstSlot: true), "First photo")
        XCTAssertEqual(selected.labelKey(firstSlot: false), "Second photo")
        XCTAssertEqual(selected.validatedForSharing(records: [first, second],
            isAvailable: true, isReadable: { _ in true }), selected)
    }

    func testDeletedSelectionCanCompareVisuallyButCannotAuthorizeFallbackSharing() throws {
        let first = photo(1), deleted = photo(2), survivor = photo(3)
        let original = ProgressPhotoPair(first: first, second: deleted)
        let records = [first, survivor]
        let visual = try XCTUnwrap(ProgressPhotoPair.resolve(records: records,
            firstID: first.id, secondID: deleted.id))
        XCTAssertEqual(visual.second, survivor)
        XCTAssertNil(ProgressPhotoPair.selected(records: records, firstID: first.id, secondID: deleted.id))
        XCTAssertNil(original.validatedForSharing(records: records, isAvailable: true, isReadable: { _ in true }))
    }

    func testExplicitReselectionCanAuthorizeSurvivingPair() throws {
        let first = photo(1), survivor = photo(3)
        let selected = try XCTUnwrap(ProgressPhotoPair.selected(records: [first, survivor],
            firstID: first.id, secondID: survivor.id))
        XCTAssertNotNil(selected.validatedForSharing(records: [first, survivor],
            isAvailable: true, isReadable: { _ in true }))
    }

    func testSameRecordInBothSlotsIsRejected() {
        let record = photo(1)
        XCTAssertNil(ProgressPhotoPair.selected(records: [record], firstID: record.id, secondID: record.id))
        XCTAssertNil(ProgressPhotoPair(first: record, second: record).validatedForSharing(
            records: [record], isAvailable: true, isReadable: { _ in true }))
    }

    func testAmbiguousDuplicateSelectedIdentifierIsRejected() {
        let first = photo(1), second = photo(2)
        XCTAssertNil(ProgressPhotoPair.selected(records: [first, first, second],
            firstID: first.id, secondID: second.id))
        XCTAssertNil(ProgressPhotoPair.selected(records: [first, second, second],
            firstID: first.id, secondID: second.id))
    }

    func testUnavailableRepositoryRejectsBeforeReadingPrivateImages() {
        let first = photo(1), second = photo(2)
        var readCount = 0
        let result = ProgressPhotoPair(first: first, second: second).validatedForSharing(
            records: [first, second], isAvailable: false) { _ in readCount += 1; return true }
        XCTAssertNil(result)
        XCTAssertEqual(readCount, 0)
    }

    func testEitherUnreadableFullImageBlocksSharing() {
        let first = photo(1), second = photo(2)
        let pair = ProgressPhotoPair(first: first, second: second)
        for unreadable in [first.id, second.id] {
            XCTAssertNil(pair.validatedForSharing(records: [first, second],
                isAvailable: true, isReadable: { $0.id != unreadable }))
        }
    }

    func testChangedPresentedVersionBlocksBeforeImageRead() {
        let first = photo(1), second = photo(2)
        let pair = ProgressPhotoPair(first: first, second: second)
        let revisions = [photo(1, time: 101), photo(1, label: .postWorkout),
                         photo(1, image: "replaced"), photo(1, thumbnail: "replaced")]
        for revised in revisions {
            var readCount = 0
            XCTAssertNil(pair.validatedForSharing(records: [revised, second], isAvailable: true) {
                _ in readCount += 1; return true
            })
            XCTAssertEqual(readCount, 0)
        }
    }

    func testUnrelatedRecordChangesDoNotChangeTheChosenPair() {
        let first = photo(1), second = photo(2)
        let pair = ProgressPhotoPair(first: first, second: second)
        XCTAssertEqual(pair.validatedForSharing(records: [photo(3), second, first],
            isAvailable: true, isReadable: { _ in true }), pair)
    }

    func testChangedSecondVersionIsRejectedToo() {
        let first = photo(1), second = photo(2)
        XCTAssertNil(ProgressPhotoPair(first: first, second: second).validatedForSharing(
            records: [first, photo(2, label: .postWorkout)], isAvailable: true, isReadable: { _ in true }))
    }
}
