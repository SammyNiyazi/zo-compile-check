import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorPresentationTests: XCTestCase {
    func testDurationUsesProofMinutesAndRetainsHours() {
        XCTAssertEqual(OutdoorPresentation.duration(1_458), "24:18")
        XCTAssertEqual(OutdoorPresentation.duration(3_661), "1:01:01")
        XCTAssertEqual(OutdoorPresentation.duration(0), "0:00")
    }

    func testDurationRejectsNonfiniteAndUnrepresentableValues() {
        for seconds in [-1, .nan, .infinity, Double(Int.max)] {
            XCTAssertEqual(OutdoorPresentation.duration(seconds), "—")
        }
    }

    func testDurationDoesNotTruncateHoursTo32Bits() {
        let hours = 2_147_483_648
        XCTAssertEqual(OutdoorPresentation.duration(Double(hours) * 3_600), "2147483648:00:00")
    }

    func testDistanceRetainsMissingAndInvalidRatherThanZero() {
        let invalid: [Double?] = [nil, -.infinity, .nan, -1]
        for meters in invalid {
            XCTAssertEqual(OutdoorPresentation.distance(meters, locale: Locale(identifier: "en_US")), "—")
        }
        XCTAssertEqual(OutdoorPresentation.distance(0, locale: Locale(identifier: "en_US")), "0.00")
    }

    func testDistanceUsesSelectedLocale() {
        XCTAssertEqual(OutdoorPresentation.distance(1_250, locale: Locale(identifier: "en_US")), "1.25")
        XCTAssertEqual(OutdoorPresentation.distance(1_250, locale: Locale(identifier: "bg_BG")), "1,25")
    }

    func testPaceRequiresMeasuredContinuousDistanceAndActiveTime() {
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 1_458, meters: 2_410, hasGPSGap: false), "10:04")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 1_458, meters: 2_410, hasGPSGap: true), "—")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 0, meters: 100, hasGPSGap: false), "—")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: .infinity, meters: 100, hasGPSGap: false), "—")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 60, meters: nil, hasGPSGap: false), "—")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 60, meters: 99, hasGPSGap: false), "—")
    }

    func testUnknownAndNegativeStepsStayUnknownButMeasuredZeroRemainsZero() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(OutdoorPresentation.steps(nil, locale: locale), "—")
        XCTAssertEqual(OutdoorPresentation.steps(-1, locale: locale), "—")
        XCTAssertEqual(OutdoorPresentation.steps(0, locale: locale), "0")
    }

    func testTickRequiresMatchingUncelebratedLiveFinishIdentity() {
        let id = UUID()
        XCTAssertTrue(OutdoorPresentation.celebrates(finishedID: id, requestedID: id, alreadyCelebrated: []))
        XCTAssertFalse(OutdoorPresentation.celebrates(finishedID: nil, requestedID: id, alreadyCelebrated: []))
        XCTAssertFalse(OutdoorPresentation.celebrates(finishedID: id, requestedID: nil, alreadyCelebrated: []))
        XCTAssertFalse(OutdoorPresentation.celebrates(finishedID: UUID(), requestedID: id, alreadyCelebrated: []))
        XCTAssertFalse(OutdoorPresentation.celebrates(finishedID: id, requestedID: id, alreadyCelebrated: [id]))
    }

    func testSavedRangeDetectsCalendarDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 86_340)
        XCTAssertFalse(OutdoorPresentation.crossesCalendarDay(start: start, end: start.addingTimeInterval(30), calendar: calendar))
        XCTAssertTrue(OutdoorPresentation.crossesCalendarDay(start: start, end: start.addingTimeInterval(120), calendar: calendar))
    }

    func testThumbnailPreservesSegmentIdentityAndDoesNotRewriteMeasuredFacts() {
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 50, maximumGapSeconds: 15,
                                                   maximumPlausibleSpeedMetersPerSecond: 1_000, maximumFutureSeconds: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        func fix(_ longitude: Double, _ seconds: Double) -> OutdoorRouteFix {
            OutdoorRouteFix(latitude: 42, longitude: longitude, timestamp: start.addingTimeInterval(seconds), horizontalAccuracyMeters: 3)
        }
        route.ingest(fix(23, 0), receivedAt: start, policy: policy)
        route.ingest(fix(23.0001, 2), receivedAt: start.addingTimeInterval(2), policy: policy)
        route.noteLocationGap()
        route.ingest(fix(23.001, 20), receivedAt: start.addingTimeInterval(20), policy: policy)
        route.ingest(fix(23.0011, 22), receivedAt: start.addingTimeInterval(22), policy: policy)
        let before = route
        let result = OutdoorPresentation.thumbnail(route)
        XCTAssertEqual(result.map(\.id), route.segments.map(\.id))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.points.count == 2 })
        XCTAssertTrue(result.flatMap(\.points).allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertEqual(route, before)
    }

    func testEmptyRouteThumbnailDoesNotInventGeometry() {
        XCTAssertTrue(OutdoorPresentation.thumbnail(OutdoorRouteAccumulator()).isEmpty)
    }

    func testPaceRejectsInvalidDistanceAndExtremeSlowPace() {
        for meters in [Double.nan, .infinity, -100, 0] {
            XCTAssertEqual(OutdoorPresentation.pace(seconds: 600, meters: meters, hasGPSGap: false), "—")
        }
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 360, meters: 100, hasGPSGap: false), "—")
        XCTAssertEqual(OutdoorPresentation.pace(seconds: 60, meters: 100, hasGPSGap: false), "10:00")
    }

    func testCalendarDayBoundaryUsesProvidedTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7_200)!
        let start = Date(timeIntervalSince1970: 79_140)
        let end = start.addingTimeInterval(120)
        XCTAssertTrue(OutdoorPresentation.crossesCalendarDay(start: start, end: end, calendar: calendar))
        XCTAssertEqual(OutdoorPresentation.date(end, style: .dateTime.day(), locale: Locale(identifier: "en_US"), calendar: calendar), "2")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(OutdoorPresentation.crossesCalendarDay(start: start, end: end, calendar: calendar))
        XCTAssertEqual(OutdoorPresentation.date(end, style: .dateTime.day(), locale: Locale(identifier: "en_US"), calendar: calendar), "1")
    }

    func testSingleRecordedFixStaysARealCenteredPoint() {
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 50, maximumGapSeconds: 15,
                                                   maximumPlausibleSpeedMetersPerSecond: 10, maximumFutureSeconds: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        route.ingest(OutdoorRouteFix(latitude: 42, longitude: 23, timestamp: now, horizontalAccuracyMeters: 3), receivedAt: now, policy: policy)
        let original = route
        let result = OutdoorPresentation.thumbnail(route)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.points, [OutdoorPresentation.Point(x: 0.5, y: 0.5)])
        XCTAssertEqual(route, original)
    }

    func testThumbnailKeepsTheDatelineCrossingLocalAndSeparateFromPause() {
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 50, maximumGapSeconds: 15,
                                                   maximumPlausibleSpeedMetersPerSecond: 10, maximumFutureSeconds: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        func fix(_ longitude: Double, _ second: Double) -> OutdoorRouteFix {
            OutdoorRouteFix(latitude: 0, longitude: longitude, timestamp: start.addingTimeInterval(second), horizontalAccuracyMeters: 3)
        }
        route.ingest(fix(179.99999, 0), receivedAt: start, policy: policy)
        route.ingest(fix(-179.99999, 2), receivedAt: start.addingTimeInterval(2), policy: policy)
        route.breakForUserPause()
        route.ingest(fix(-179.99998, 20), receivedAt: start.addingTimeInterval(20), policy: policy)
        let original = route
        let result = OutdoorPresentation.thumbnail(route)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.id), route.segments.map(\.id))
        XCTAssertEqual(result.map { $0.points.count }, [2, 1])
        XCTAssertTrue(result.flatMap(\.points).allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertEqual(route, original)
    }

    // These checks use the actual merged app tables on the native target. They
    // intentionally fail if the manager omits the complete returned fragments.
    func testBulgarianConditionalCoverageAndStorageErrorsResolveAtDisplay() {
        let localization = AppLocalization(language: .bulgarian)
        XCTAssertEqual(localization.string("Steps were unavailable for this activity."), "Крачките не бяха достъпни за това занимание.")
        XCTAssertEqual(localization.string("The route was not removed. Your existing history has been kept."), "Маршрутът не е премахнат. Съществуващата ти история е запазена.")
        XCTAssertEqual(localization.string("Route map deleted. Time and measured distance were kept."), "Картата на маршрута е изтрита. Времето и измереното разстояние са запазени.")
    }

    func testAccessibleRouteCountAndTimeUseTypedSelectedLanguageFormats() {
        let english = AppLocalization(language: .english)
        let bulgarian = AppLocalization(language: .bulgarian)
        XCTAssertEqual(english.format("outdoor.design.route.sections", .integer(2)), "Map of recorded route, 2 separate sections")
        XCTAssertEqual(bulgarian.format("outdoor.design.route.sections", .integer(2)), "Карта на записания маршрут, 2 отделни участъка")
        XCTAssertEqual(bulgarian.format("outdoor.design.active.time.accessibility", .text("24:18")), "Активно време 24:18")
    }
}
