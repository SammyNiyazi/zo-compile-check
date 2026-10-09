import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class SavedShareExportAuthorityTests: XCTestCase {
    private struct Record: Identifiable, Equatable {
        let id: Int
        let value: Int
    }
    private enum Failure: Error { case unavailable }

    func testUnchangedAcknowledgedHistoryCanExport() async {
        let saved = [Record(id: 1, value: 40), Record(id: 2, value: 35)]
        let allowed = await SavedShareExportAuthority.verify(
            expected: saved, readCurrentRecords: { saved }, isReady: { true })
        XCTAssertTrue(allowed)
    }

    func testChangedComparisonRecordRejectsEvenWhenSelectedRecordIsUnchanged() async {
        let saved = [Record(id: 1, value: 40), Record(id: 2, value: 35)]
        let allowed = await SavedShareExportAuthority.verify(
            expected: saved,
            readCurrentRecords: { [saved[0], Record(id: 2, value: 50)] }, isReady: { true })
        XCTAssertFalse(allowed)
    }

    func testDeletedOrNewRecordInvalidatesCapturedSource() async {
        let saved = [Record(id: 1, value: 40)]
        for current in [[], [saved[0], Record(id: 2, value: 35)]] {
            let allowed = await SavedShareExportAuthority.verify(
                expected: saved, readCurrentRecords: { current }, isReady: { true })
            XCTAssertFalse(allowed)
        }
    }

    func testNewActivityDuringSuspendedReadRejectsExport() async {
        let saved = [Record(id: 1, value: 40)]
        var ready = true
        let allowed = await SavedShareExportAuthority.verify(expected: saved,
            readCurrentRecords: { await Task.yield(); ready = false; return saved },
            isReady: { ready })
        XCTAssertFalse(allowed)
    }

    func testUnavailableRecordStoreDoesNotUseAcknowledgedCache() async {
        let allowed = await SavedShareExportAuthority.verify(
            expected: [Record(id: 1, value: 40)],
            readCurrentRecords: { throw Failure.unavailable }, isReady: { true })
        XCTAssertFalse(allowed)
    }

    func testUnavailableRecoveryStoreRejectsBeforeReadingRecords() async {
        var reads = 0
        let allowed = await SavedShareExportAuthority.verify(
            expected: [Record(id: 1, value: 40)],
            readCurrentRecords: { reads += 1; return [] },
            isReady: { throw Failure.unavailable })
        XCTAssertFalse(allowed)
        XCTAssertEqual(reads, 0)
    }

    func testDuplicateIdentitiesCannotEstablishAcknowledgedSource() async {
        let duplicate = [Record(id: 1, value: 40), Record(id: 1, value: 35)]
        let allowed = await SavedShareExportAuthority.verify(
            expected: duplicate, readCurrentRecords: { duplicate }, isReady: { true })
        XCTAssertFalse(allowed)
    }

    func testCancellationDuringReadRejectsImageHandoff() async {
        let saved = [Record(id: 1, value: 40)]
        let task = Task { @MainActor in
            await SavedShareExportAuthority.verify(expected: saved,
                readCurrentRecords: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return saved
                }, isReady: { true })
        }
        let allowed = await task.value
        XCTAssertFalse(allowed)
    }
}
