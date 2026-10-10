import Foundation
import XCTest
@testable import ZeroOne

final class ProgressBodyWeightPresentationTests: XCTestCase {
    private func entry(_ seconds: TimeInterval, kilograms: Decimal = 72) -> BodyWeightEntry {
        BodyWeightEntry(id: UUID(), recordedAt: Date(timeIntervalSince1970: seconds), kilograms: kilograms)
    }

    func testUnavailableRetainedReadingsAreUnknownRatherThanConfirmedEmpty() {
        let result = BodyWeightObservationPresentation(entries: [entry(100)], isAvailable: false,
            now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertNil(result.observedEntries)
        XCTAssertNil(result.futureCount)
    }

    func testConfirmedEmptyDiffersFromOnlyFutureReadings() {
        let now = Date(timeIntervalSince1970: 200)
        let empty = BodyWeightObservationPresentation(entries: [], isAvailable: true, now: now)
        let future = BodyWeightObservationPresentation(entries: [entry(201)], isAvailable: true, now: now)
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(empty.futureCount, 0)
        XCTAssertEqual(future.state, .futureOnly)
        XCTAssertEqual(future.futureCount, 1)
        XCTAssertEqual(future.observedEntries, [])
    }

    func testFutureBoundaryPreservesExactRecordIdentityAndTimestamp() {
        let first = entry(199), boundary = entry(200), future = entry(201)
        let result = BodyWeightObservationPresentation(entries: [first, boundary, future], isAvailable: true,
            now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(result.state, .observed)
        XCTAssertEqual(result.observedEntries, [first, boundary])
        XCTAssertEqual(result.futureCount, 1)
        let later = BodyWeightObservationPresentation(entries: [first, boundary, future], isAvailable: true,
            now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(later.observedEntries, [first, boundary, future])
        XCTAssertEqual(later.futureCount, 0)
    }

    func testMidnightReprojectionExpiresCurrentSevenDayAverageWithoutChangingHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let reading = BodyWeightEntry(id: UUID(), recordedAt: date(2, 12), kilograms: 72)
        let before = BodyWeightTrend(entries: [reading], now: date(8, 23), calendar: calendar)
        let after = BodyWeightTrend(entries: [reading], now: date(9, 0), calendar: calendar)
        XCTAssertEqual(before.sevenDayAverageKilograms, 72)
        XCTAssertNil(after.sevenDayAverageKilograms)
        XCTAssertEqual(after.latest, reading)
    }

    func testEmptyInputDoesNotPresentValidationErrorButZeroDoes() {
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "  ", unit: .kilograms), .empty)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "0", unit: .kilograms), .invalid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "72kg", unit: .kilograms), .invalid)
    }

    func testDisplayValidationKeepsExistingRangeAndCommaDecimal() {
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "0,5", unit: .kilograms), .valid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "1000", unit: .kilograms), .valid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "1000.1", unit: .kilograms), .invalid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "0.49", unit: .kilograms), .invalid)
    }

    func testRangeQualificationUsesSelectedUnitInsteadOfAssumingKilograms() {
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "0.5", unit: .pounds), .invalid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "1.2", unit: .pounds), .valid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "2204", unit: .pounds), .valid)
        XCTAssertEqual(BodyWeightReadingInputPresentation(text: "2205", unit: .pounds), .invalid)
    }
}
