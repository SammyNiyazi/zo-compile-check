import SwiftUI
import XCTest
@testable import ZeroOne

final class ThemeNumberShimmerTests: XCTestCase {
    func testSweepRunsOnceBetween480And1200Milliseconds() throws {
        XCTAssertNil(ThemeNumberShimmer.rowPosition(elapsed: 0, count: 3))
        XCTAssertNil(ThemeNumberShimmer.rowPosition(elapsed: 0.479, count: 3))
        XCTAssertNil(ThemeNumberShimmer.rowPosition(elapsed: 1.2, count: 3))
        XCTAssertNil(ThemeNumberShimmer.rowPosition(elapsed: .nan, count: 3))
        XCTAssertNil(ThemeNumberShimmer.rowPosition(elapsed: 0.8, count: 0))
        let first = try XCTUnwrap(ThemeNumberShimmer.rowPosition(elapsed: 0.48, count: 3))
        XCTAssertEqual(first, -0.05, accuracy: 0.0001)
        let late = try XCTUnwrap(ThemeNumberShimmer.rowPosition(elapsed: 1.199, count: 3))
        XCTAssertGreaterThan(late, 1)
    }

    func testBandMovesLeftToRightAcrossTheRow() throws {
        var previous = -Double.infinity
        for step in stride(from: 0.48, to: 1.2, by: 0.06) {
            let row = try XCTUnwrap(ThemeNumberShimmer.rowPosition(elapsed: step, count: 3))
            XCTAssertGreaterThanOrEqual(row, previous)
            previous = row
        }
        // Halfway across the row is the middle of the second number.
        XCTAssertEqual(ThemeNumberShimmer.localPosition(row: 0.5, index: 1, count: 3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ThemeNumberShimmer.localPosition(row: 0.5, index: 0, count: 3), 1.5, accuracy: 0.0001)
    }

    func testStopsOnlyWhenTheBandIsOnTheNumberAndStayOrdered() throws {
        XCTAssertNil(ThemeNumberShimmer.stops(center: -0.2, ink: .black, band: [.white]))
        XCTAssertNil(ThemeNumberShimmer.stops(center: 1.2, ink: .black, band: [.white]))
        XCTAssertNil(ThemeNumberShimmer.stops(center: 0.5, ink: .black, band: []))
        let stops = try XCTUnwrap(ThemeNumberShimmer.stops(center: 0.05, ink: .black, band: [.white, .pink, .purple]))
        XCTAssertEqual(stops.count, 7)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        for pair in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.location, pair.1.location)
        }
    }
}
