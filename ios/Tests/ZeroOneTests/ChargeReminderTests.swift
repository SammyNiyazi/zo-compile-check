import XCTest
@testable import ZeroOne

/// Sammy 10 Oct: a reminder 2 days before every paid renewal, only while the plan renews.
final class ChargeReminderTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }()
    private let localization = AppLocalization(language: .english, bundle: .main)

    private func date(_ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testPaidRenewalGetsAReminderTwoDaysBeforeAtSix() throws {
        let next = MembershipNextCharge(date: date(24), price: "$4.99", period: "a month", isTrial: false, renews: true)
        let plan = try XCTUnwrap(ChargeReminderScheduler.plan(next: next, enabled: true, now: date(11),
                                                              calendar: calendar, localization: localization))
        XCTAssertEqual(plan.identifier, ChargeReminderScheduler.reminderID)
        XCTAssertEqual(plan.fireAt, date(22, TrialNotificationScheduler.hour))
        XCTAssertTrue(plan.body.contains("$4.99"))
    }

    func testNoReminderWhenSwitchedOffCancelledTrialOrTooLate() {
        let paid = MembershipNextCharge(date: date(24), price: "$4.99", period: "a month", isTrial: false, renews: true)
        XCTAssertNil(ChargeReminderScheduler.plan(next: paid, enabled: false, now: date(11), calendar: calendar, localization: localization))
        XCTAssertNil(ChargeReminderScheduler.plan(next: paid, enabled: true, now: date(23), calendar: calendar, localization: localization))
        let cancelled = MembershipNextCharge(date: date(24), price: nil, period: nil, isTrial: false, renews: false)
        XCTAssertNil(ChargeReminderScheduler.plan(next: cancelled, enabled: true, now: date(11), calendar: calendar, localization: localization))
        // The trial keeps its own, richer "2 days left" note.
        let trial = MembershipNextCharge(date: date(24), price: "$4.99", period: "a month", isTrial: true, renews: true)
        XCTAssertNil(ChargeReminderScheduler.plan(next: trial, enabled: true, now: date(11), calendar: calendar, localization: localization))
        XCTAssertNil(ChargeReminderScheduler.plan(next: nil, enabled: true, now: date(11), calendar: calendar, localization: localization))
    }

    func testReleaseUsesTheAppStoreProducts() {
        XCTAssertEqual(MembershipConfiguration.appStore.productIDs,
                       ["app.the01.membership.monthly", "app.the01.membership.yearly"])
        XCTAssertFalse(MembershipConfiguration.appStore.isBeta)
        XCTAssertTrue(MembershipConfiguration.appStore.hasLegalLinks)
    }
}
