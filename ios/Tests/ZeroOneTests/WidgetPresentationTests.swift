import XCTest
@testable import ZeroOne

final class WidgetPresentationTests: XCTestCase {
    func testMissingAndDisconnectedMetricsNeverBecomeZeroProgress() {
        XCTAssertNil(WidgetMetricProgress(metric: nil, target: 8_000))
        for state in [DailyWidgetSnapshot.Metric.State.noData, .needsConnection, .needsRefresh, .unavailable] {
            XCTAssertNil(WidgetMetricProgress(metric: .missing(state), target: 8_000))
        }
    }

    func testInvalidTargetAndMalformedReadingCannotDrawGoalWin() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = DailyWidgetSnapshot.Metric.reading(1_000, at: date)
        for target in [0, -1] { XCTAssertNil(WidgetMetricProgress(metric: valid, target: target)) }
        XCTAssertNil(WidgetMetricProgress(metric: valid, target: nil))
        for value in [Double.nan, Double.infinity, -1, Double(Int.max)] {
            let invalid = DailyWidgetSnapshot.Metric(state: .available, value: value, asOf: date, isStale: false)
            XCTAssertNil(WidgetMetricProgress(metric: invalid, target: 1_000))
        }
    }

    func testActualZeroIsAvailableAndRetainsFullRemainingGoal() {
        let result = WidgetMetricProgress(metric: .reading(0, at: .distantPast), target: 8_000)
        XCTAssertEqual(result?.fraction, 0)
        XCTAssertEqual(result?.remaining, 8_000)
        XCTAssertEqual(result?.reached, false)
    }

    func testOverGoalCapsRingWithoutChangingRecordedValue() {
        let metric = DailyWidgetSnapshot.Metric.reading(2_750, at: .distantPast)
        let result = WidgetMetricProgress(metric: metric, target: 2_000)
        XCTAssertEqual(result?.fraction, 1)
        XCTAssertEqual(result?.remaining, 0)
        XCTAssertEqual(result?.reached, true)
        XCTAssertEqual(metric.value, 2_750)
    }

    func testStaleReadingMayShowItsRingButCannotClaimGoalWin() {
        let result = WidgetMetricProgress(metric: .reading(2_000, at: .distantPast, isStale: true), target: 2_000)
        XCTAssertEqual(result?.fraction, 1)
        XCTAssertEqual(result?.reached, false)
    }
}
