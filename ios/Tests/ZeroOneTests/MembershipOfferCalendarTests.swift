import XCTest
@testable import ZeroOne

final class MembershipOfferCalendarTests: XCTestCase {
    func testTwoWeekOfferUsesCalendarDaysAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12)))

        let paymentDate = try XCTUnwrap(MembershipOfferCalendar.freeUntil(start: start, days: 14, calendar: calendar))
        let lastFreeDay = try XCTUnwrap(MembershipOfferCalendar.lastFreeDay(paymentStarts: paymentDate, calendar: calendar))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: paymentDate),
                       DateComponents(year: 2026, month: 11, day: 1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: lastFreeDay),
                       DateComponents(year: 2026, month: 10, day: 31))
        XCTAssertNil(MembershipOfferCalendar.freeUntil(start: start, days: 7, calendar: calendar))
    }
}
