import Foundation
import XCTest
@testable import ZeroOne

final class DailyWidgetPresentationTests: XCTestCase {
    func testTogetherSelectionKeepsOneMetricAndStableOrder() {
        var options = DailyWidgetOptions()
        options.set(.water, included: false)
        options.set(.calories, included: false)
        options.set(.steps, included: false)
        XCTAssertEqual(options.orderedMetrics, [.steps])
        options.set(.water, included: true)
        options.set(.calories, included: true)
        XCTAssertEqual(options.orderedMetrics, [.steps, .calories, .water])
    }

    func testOptionsRoundTripAndInvalidWaterAmountFallback() throws {
        var options = DailyWidgetOptions()
        options.calories = .burned
        options.showsWalk = false
        options.waterAmount = 500
        options.set(.calories, included: false)
        let restored = try JSONDecoder().decode(DailyWidgetOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(restored, options)
        XCTAssertEqual(restored.secondaryWaterAmount, 750)
        options.waterAmount = -250
        XCTAssertEqual(options.validatedWaterAmount, 250)
        XCTAssertEqual(options.secondaryWaterAmount, 500)
    }

    func testWidgetKindsNeverChooseUnsupportedSizes() {
        for kind in DailyWidgetSnapshot.Kind.allCases {
            for size in DailyWidgetSize.allCases {
                XCTAssertTrue(kind.sizes.contains(kind.validSize(size)))
                if kind.sizes.contains(size) { XCTAssertEqual(kind.validSize(size), size) }
            }
        }
        XCTAssertEqual(DailyWidgetSnapshot.Kind.together.validSize(.small), .medium)
        XCTAssertEqual(DailyWidgetSnapshot.Kind.water.validSize(.large), .small)
    }

    func testRoutesRoundTripOnlyAsKnownDestinations() {
        for route in DailyWidgetRoute.allCases {
            XCTAssertEqual(DailyWidgetRoute(url: route.url), route)
        }
    }

    func testRoutesRejectExtraAuthorityParametersAndUnknownCommands() throws {
        let invalid = [
            "https://widget/water", "the01://other/water", "the01://widget/",
            "the01://widget/water/add", "the01://widget/record",
            "the01://widget/water?amount=750", "the01://widget/walk?start=true",
            "the01://widget/water#confirm", "the01://user@widget/water",
            "the01://widget:123/water"
        ]
        for value in invalid {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(DailyWidgetRoute(url: url), value)
        }
    }

    func testMissingInvalidAndUnobservedValuesNeverDisplayZero() {
        XCTAssertEqual(DailyWidgetFormatting.value(nil), "—")
        for state in [DailyWidgetSnapshot.Metric.State.noData, .needsConnection, .needsRefresh, .unavailable] {
            XCTAssertEqual(DailyWidgetFormatting.value(.missing(state)), "—")
            XCTAssertNotNil(DailyWidgetFormatting.stateText(.missing(state)))
        }
        for value in [-1.0, Double.infinity, Double.nan] {
            let invalid = DailyWidgetSnapshot.Metric(state: .available, value: value, asOf: Date(), isStale: false)
            XCTAssertEqual(DailyWidgetFormatting.value(invalid), "—")
        }
        let zero = DailyWidgetSnapshot.Metric.reading(0, at: Date())
        XCTAssertEqual(DailyWidgetFormatting.value(zero), 0.formatted(.number.precision(.fractionLength(0))))
        XCTAssertNil(DailyWidgetFormatting.stateText(zero))
        XCTAssertEqual(DailyWidgetFormatting.stateText(.reading(250, at: Date(), isStale: true)), "Refresh needed")
    }

    func testWaterFormattingConvertsMillilitersWithoutChangingSourceValue() {
        let metric = DailyWidgetSnapshot.Metric.reading(1_250, at: Date())
        XCTAssertEqual(DailyWidgetFormatting.value(metric, liters: true), 1.25.formatted(.number.precision(.fractionLength(0 ... 2))))
        XCTAssertEqual(metric.value, 1_250)
    }
}
