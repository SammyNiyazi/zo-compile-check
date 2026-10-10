import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorStepAccumulatorTests: XCTestCase {
    func testCumulativeUpdatesReplaceEachOtherAndPausesNeverAddSteps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let firstID = UUID()
        let secondID = UUID()
        var steps = OutdoorStepAccumulator()
        XCTAssertEqual(steps.begin(at: start, id: firstID), firstID)

        XCTAssertTrue(steps.ingest(sample(firstID, start: start, end: start + 10, count: 12)))
        XCTAssertTrue(steps.ingest(sample(firstID, start: start, end: start + 20, count: 25)))
        XCTAssertEqual(steps.recordedSteps, 25)
        steps.close(at: start + 30)
        XCTAssertFalse(steps.ingest(sample(firstID, start: start, end: start + 25, count: 50)))
        XCTAssertEqual(steps.begin(at: start + 100, id: secondID), secondID)
        XCTAssertTrue(steps.ingest(sample(secondID, start: start + 100, end: start + 110, count: 8)))
        XCTAssertEqual(steps.recordedSteps, 33)
        XCTAssertTrue(steps.hasIncompleteCoverage)
        XCTAssertTrue(steps.isInternallyConsistent)
    }

    func testFinalQueryReconcilesClosedIntervalAndValidZeroIsNotUnknown() {
        let start = Date(timeIntervalSince1970: 2_000)
        let id = UUID()
        var steps = OutdoorStepAccumulator()
        _ = steps.begin(at: start, id: id)
        XCTAssertTrue(steps.ingest(sample(id, start: start, end: start + 10, count: 3)))
        steps.close(at: start + 20)
        XCTAssertTrue(steps.ingest(sample(id, start: start, end: start + 20, count: 0, final: true)))
        XCTAssertEqual(steps.recordedSteps, 0)
        XCTAssertFalse(steps.hasIncompleteCoverage)
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 20, count: 6, final: true)))
    }

    func testUnavailableAndInterruptedCoverageStayUnknownOrPartial() {
        let start = Date(timeIntervalSince1970: 3_000)
        let id = UUID()
        var steps = OutdoorStepAccumulator()
        _ = steps.begin(at: start, id: id)
        steps.close(at: start + 10)
        XCTAssertNil(steps.recordedSteps)
        XCTAssertTrue(steps.hasIncompleteCoverage)
        XCTAssertFalse(steps.ingest(sample(UUID(), start: start, end: start + 10, count: 100, final: true)))
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 11, count: 100, final: true)))
        XCTAssertNil(steps.begin(at: start - 100))
        XCTAssertTrue(steps.hasClockDiscontinuity)
        XCTAssertTrue(steps.isInternallyConsistent)
    }

    func testOverflowCannotBeClaimedAsARecordedTotal() {
        let start = Date(timeIntervalSince1970: 4_000)
        var steps = OutdoorStepAccumulator()
        let firstID = UUID()
        let secondID = UUID()
        _ = steps.begin(at: start, id: firstID)
        _ = steps.ingest(sample(firstID, start: start, end: start + 1, count: Int.max))
        steps.close(at: start + 2)
        _ = steps.begin(at: start + 3, id: secondID)
        XCTAssertFalse(steps.ingest(sample(secondID, start: start + 3, end: start + 4, count: 1)))
        XCTAssertEqual(steps.recordedSteps, Int.max)
        XCTAssertTrue(steps.isInternallyConsistent)
    }

    func testForegroundQueryAndDelayedLiveCallbacksCannotDoubleCountOrRegress() {
        let start = Date(timeIntervalSince1970: 5_000)
        let id = UUID()
        var steps = OutdoorStepAccumulator()
        _ = steps.begin(at: start, id: id)
        XCTAssertTrue(steps.ingest(sample(id, start: start, end: start + 20, count: 18)))
        // A foreground cached query is cumulative, exactly like a live callback.
        XCTAssertTrue(steps.ingest(sample(id, start: start, end: start + 30, count: 27)))
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 25, count: 22)))
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 30, count: 27)))
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 31, count: 26)))
        XCTAssertEqual(steps.recordedSteps, 27)
        steps.close(at: start + 40)
        let resumedID = UUID()
        _ = steps.begin(at: start + 100, id: resumedID)
        XCTAssertFalse(steps.ingest(sample(id, start: start, end: start + 35, count: 32)))
        XCTAssertTrue(steps.ingest(sample(id, start: start, end: start + 40, count: 35, final: true)))
        XCTAssertTrue(steps.ingest(sample(resumedID, start: start + 100, end: start + 110, count: 9)))
        XCTAssertEqual(steps.recordedSteps, 44)
        XCTAssertTrue(steps.isInternallyConsistent)
    }

    private func sample(
        _ id: UUID, start: Date, end: Date, count: Int, final: Bool = false
    ) -> OutdoorStepSnapshot {
        OutdoorStepSnapshot(
            intervalID: id,
            sampleStartedAt: start,
            sampleEndedAt: end,
            cumulativeSteps: count,
            isFinal: final
        )
    }
}
