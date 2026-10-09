import Foundation
import StoreKit
import XCTest
@testable import ZeroOne

final class MembershipPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return value
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 1,
                      hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func recap(start: Date? = nil) -> MembershipTrialRecap {
        let first = start ?? date()
        return MembershipTrialRecap(interval: DateInterval(start: first,
            end: calendar.date(byAdding: .day, value: 14, to: first)!))
    }

    private func day(_ offset: Int, from start: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: start)!
    }

    private func lift(_ recap: MembershipTrialRecap, id: String = "squat",
                      first: Double = 12, current: Double = 18,
                      firstDay: Int = 0, currentDay: Int = 13,
                      qualified: Bool = true) -> MembershipTrialRecap.Strength {
        .init(id: id, exerciseName: "Squat", firstLoadKilograms: first,
              currentLoadKilograms: current,
              firstObservedAt: day(firstDay, from: recap.interval.start),
              currentObservedAt: day(currentDay, from: recap.interval.start),
              comparisonQualified: qualified)
    }

    func testOnlyApprovedSingleFreeOfferHasTwoWeekPresentation() {
        XCTAssertEqual(MembershipTrialPresentation.approvedDays(unit: .day, value: 14,
            periodCount: 1, isFreeTrial: true, eligibility: .eligible), 14)
        XCTAssertEqual(MembershipTrialPresentation.approvedDays(unit: .week, value: 2,
            periodCount: 1, isFreeTrial: true, eligibility: .eligible), 14)
        for eligibility in [MembershipEligibility.checking, .ineligible, .unavailable] {
            XCTAssertNil(MembershipTrialPresentation.approvedDays(unit: .week, value: 2,
                periodCount: 1, isFreeTrial: true, eligibility: eligibility))
        }
        XCTAssertNil(MembershipTrialPresentation.approvedDays(unit: .week, value: 2,
            periodCount: 1, isFreeTrial: false, eligibility: .eligible))
        XCTAssertNil(MembershipTrialPresentation.approvedDays(unit: .week, value: 2,
            periodCount: 2, isFreeTrial: true, eligibility: .eligible))
    }

    func testOtherDurationsAndAbsentProductNeverPromiseTheApprovedTrial() {
        for unit in [Product.SubscriptionPeriod.Unit.day, .week, .month, .year] {
            XCTAssertNil(MembershipTrialPresentation.approvedDays(unit: unit, value: 1,
                periodCount: 1, isFreeTrial: true, eligibility: .eligible))
        }
        XCTAssertNil(MembershipTrialPresentation.approvedDays(unit: .day, value: -14,
            periodCount: 1, isFreeTrial: true, eligibility: .eligible))
        XCTAssertNil(MembershipTrialPresentation.approvedDays(product: nil, eligibility: .eligible))
    }

    func testDaysLeftRequiresVerifiedUnexpiredTrial() {
        let now = date(), end = day(2, from: now)
        for access in [MembershipAccess.checking, .none, .member(until: end),
                       .gracePeriod(until: end), .billingRetry, .expired, .revoked, .unknown] {
            XCTAssertNil(MembershipTrialPresentation.daysLeft(access: access, now: now, calendar: calendar))
        }
        XCTAssertNil(MembershipTrialPresentation.daysLeft(access: .trial(until: now), now: now, calendar: calendar))
        XCTAssertNil(MembershipTrialPresentation.daysLeft(access: .trial(until: now.addingTimeInterval(-1)), now: now, calendar: calendar))
        XCTAssertEqual(MembershipTrialPresentation.daysLeft(access: .trial(until: now.addingTimeInterval(1)), now: now, calendar: calendar), 1)
    }

    func testDaysLeftUsesCalendarDaysAcrossSpringAndAutumnDST() {
        for now in [date(2026, 3, 28), date(2026, 10, 24)] {
            let end = day(2, from: now)
            XCTAssertNotEqual(end.timeIntervalSince(now), 2 * 86_400)
            XCTAssertEqual(MembershipTrialPresentation.daysLeft(access: .trial(until: end), now: now, calendar: calendar), 2)
        }
    }

    func testPlannedDaysRejectOutsideWindowAndDeduplicateLocalDay() {
        let start = date(), end = day(14, from: start)
        let planned = [start, start.addingTimeInterval(60), day(2, from: start),
                       start.addingTimeInterval(-1), end]
        XCTAssertEqual(MembershipTrialPresentation.plannedDays(planned, start: start, days: 14, calendar: calendar),
                       [calendar.startOfDay(for: start), calendar.startOfDay(for: day(2, from: start))])
        XCTAssertTrue(MembershipTrialPresentation.plannedDays(planned, start: start, days: 0, calendar: calendar).isEmpty)
    }

    func testRecapUsesFourteenLocalDaysRatherThanSecondsAcrossDST() {
        let value = recap(start: date(2026, 3, 25))
        XCTAssertTrue(value.isFourteenDays(calendar: calendar))
        XCTAssertNotEqual(value.interval.duration, 14 * 86_400)
        let fixedSeconds = MembershipTrialRecap(interval: DateInterval(start: value.interval.start, duration: 14 * 86_400))
        XCTAssertFalse(fixedSeconds.isFourteenDays(calendar: calendar))
    }

    func testAllUnknownRecapAndInvalidValuesDoNotBecomeFacts() {
        var value = recap()
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
        value.workouts = -1; value.completedSets = -2; value.bests = -3
        value.averageDailySteps = -1; value.longestWalkKilometres = .infinity
        value.attendance = [.init(date: value.interval.start, planned: nil, completed: nil)]
        value.weightTrend = [.init(date: value.interval.start, sevenDayAverageKilograms: nil)]
        value.strength = [lift(value, qualified: false)]
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
    }

    func testObservedZeroCountsAndZeroWalkRemainFacts() {
        var value = recap()
        value.workouts = 0
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        XCTAssertEqual(MembershipTrialRecap.count(value.workouts), 0)
        value.workouts = nil; value.averageDailySteps = 0
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        value.averageDailySteps = nil; value.longestWalkKilometres = 0
        XCTAssertEqual(value.validLongestWalk, 0)
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        XCTAssertNil(MembershipTrialRecap.count(nil))
        XCTAssertNil(MembershipTrialRecap.count(-1))
    }

    func testInvalidIntervalWithObservedZeroIsUnavailable() {
        var value = MembershipTrialRecap(interval: DateInterval(start: date(), duration: 13 * 86_400))
        value.workouts = 0
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
    }

    func testEachOptionalSectionCanSupplyFactsWithoutSummaryCounts() {
        var value = recap()
        value.strength = [lift(value)]
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        value.strength = []; value.attendance = [.init(date: value.interval.start, planned: false, completed: false)]
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        value.attendance = nil; value.weightTrend = [.init(date: value.interval.start, sevenDayAverageKilograms: 76)]
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
        value.weightTrend = nil; value.lessons = [.init(id: "lesson", title: "Read", readAt: value.interval.start)]
        XCTAssertTrue(value.hasDisplayableFacts(calendar: calendar))
    }

    func testEqualAndDecliningQualifiedLoadsRemainFactual() {
        var value = recap()
        value.strength = [lift(value, id: "equal", first: 20, current: 20),
                          lift(value, id: "decline", first: 20, current: 18)]
        XCTAssertEqual(value.qualifiedStrength.count, 2)
    }

    func testStrengthRejectsBadLoadsReversedTimeAndWindowEnd() {
        var value = recap()
        value.strength = [lift(value, id: "unqualified", qualified: false),
            lift(value, id: "negative", first: -1), lift(value, id: "nan", current: .nan),
            lift(value, id: "infinity", first: .infinity), lift(value, id: "reverse", firstDay: 5, currentDay: 2),
            lift(value, id: "same", firstDay: 2, currentDay: 2), lift(value, id: "before", firstDay: -1),
            lift(value, id: "atEnd", currentDay: 14)]
        XCTAssertTrue(value.qualifiedStrength.isEmpty)
        XCTAssertTrue(value.contains(value.interval.start))
        XCTAssertFalse(value.contains(value.interval.end))
    }

    func testDuplicateStrengthIdentityCannotProduceTwoClaims() {
        var value = recap()
        value.strength = [lift(value), lift(value, current: 24)]
        XCTAssertTrue(value.qualifiedStrength.isEmpty)
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
    }

    func testAttendanceKeepsUnknownAndObservedFalseDistinct() {
        var value = recap()
        value.attendance = [.init(date: day(1, from: value.interval.start), planned: true, completed: nil),
                            .init(date: value.interval.start, planned: false, completed: false),
                            .init(date: value.interval.end, planned: true, completed: true)]
        let days = value.attendanceDays(calendar: calendar)
        XCTAssertEqual(days?.count, 2)
        XCTAssertEqual(days?.first?.completed, false)
        XCTAssertNil(days?.last?.completed)
    }

    func testDuplicateLocalAttendanceDayInvalidatesSection() {
        var value = recap()
        value.attendance = [.init(date: value.interval.start, planned: true, completed: true),
                            .init(date: value.interval.start.addingTimeInterval(60), planned: true, completed: false)]
        XCTAssertNil(value.attendanceDays(calendar: calendar))
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
    }

    func testWeightLineBreaksAtUnknownAndMissingLocalDay() {
        var value = recap()
        value.weightTrend = [
            .init(date: day(0, from: value.interval.start), sevenDayAverageKilograms: 76),
            .init(date: day(1, from: value.interval.start), sevenDayAverageKilograms: nil),
            .init(date: day(2, from: value.interval.start), sevenDayAverageKilograms: 75.8),
            .init(date: day(4, from: value.interval.start), sevenDayAverageKilograms: 75.5),
            .init(date: value.interval.end, sevenDayAverageKilograms: 70)]
        let plot = value.weightPlot(calendar: calendar)
        XCTAssertEqual(plot.map(\.kilograms), [76, 75.8, 75.5])
        XCTAssertEqual(plot.map(\.segment), [0, 1, 2])
    }

    func testWeightLineRemainsConnectedAcrossLocalDSTDay() {
        var value = recap(start: date(2026, 3, 28))
        value.weightTrend = [0, 1, 2].map { .init(date: day($0, from: value.interval.start), sevenDayAverageKilograms: 76) }
        XCTAssertEqual(value.weightPlot(calendar: calendar).map(\.segment), [0, 0, 0])
    }

    func testInvalidWeightsDoNotBridgeLineOrBecomeZero() {
        var value = recap()
        value.weightTrend = [0.0, -1, .nan, .infinity].enumerated().map {
            .init(date: day($0.offset, from: value.interval.start), sevenDayAverageKilograms: $0.element)
        }
        XCTAssertTrue(value.weightPlot(calendar: calendar).isEmpty)
        XCTAssertFalse(value.hasDisplayableFacts(calendar: calendar))
    }

    func testDuplicateLocalWeightDayInvalidatesEntirePlot() {
        var value = recap()
        value.weightTrend = [.init(date: value.interval.start, sevenDayAverageKilograms: 76),
                            .init(date: value.interval.start.addingTimeInterval(1), sevenDayAverageKilograms: 75)]
        XCTAssertTrue(value.weightPlot(calendar: calendar).isEmpty)
    }

    func testLessonsRejectOutsideWindowAndDuplicateIdentity() {
        var value = recap()
        value.lessons = [.init(id: "valid", title: "Read", readAt: value.interval.start),
                         .init(id: "atEnd", title: "Later", readAt: value.interval.end)]
        XCTAssertEqual(value.readLessons.map(\.id), ["valid"])
        value.lessons.append(.init(id: "valid", title: "Repeated", readAt: day(1, from: value.interval.start)))
        XCTAssertTrue(value.readLessons.isEmpty)
    }

    func testLongestWalkRejectsNegativeAndNonfiniteValues() {
        var value = recap()
        for kilometres in [-1.0, .nan, .infinity, -.infinity] {
            value.longestWalkKilometres = kilometres
            XCTAssertNil(value.validLongestWalk)
        }
    }

    func testRenewalMustMatchExactValidRecapEnd() {
        let value = recap()
        let renewal = MembershipRecapRenewal(trialEnds: value.interval.end, continuation: .renews,
                                            verifiedPrice: "$4.99", verifiedPeriod: "per month")
        XCTAssertTrue(renewal.matches(value, calendar: calendar))
        XCTAssertFalse(renewal.matches(nil, calendar: calendar))
        XCTAssertFalse(renewal.matches(recap(start: value.interval.start.addingTimeInterval(1)), calendar: calendar))
        XCTAssertFalse(renewal.matches(MembershipTrialRecap(interval:
            DateInterval(start: day(1, from: value.interval.start), end: value.interval.end)), calendar: calendar))
    }

    func testRenewalPriceRequiresBothNonblankVerifiedFields() {
        let end = recap().interval.end
        let pairs: [(String?, String?)] = [(nil, "per month"), ("$4.99", nil), (" ", "per month"), ("$4.99", "\n")]
        for pair in pairs {
            XCTAssertFalse(MembershipRecapRenewal(trialEnds: end, continuation: .renews,
                verifiedPrice: pair.0, verifiedPeriod: pair.1).hasVerifiedPriceAndPeriod)
        }
        XCTAssertTrue(MembershipRecapRenewal(trialEnds: end, continuation: .renews,
            verifiedPrice: "$4.99", verifiedPeriod: "per month").hasVerifiedPriceAndPeriod)
    }

    /// Manager must merge paired fragments before running this resource acceptance test.
    func testBulgarianRecapCopyAndTypedArgumentsAreActuallyBundled() {
        let bg = AppLocalization(language: .bulgarian)
        XCTAssertEqual(bg.string("Your trial recap is unavailable."), "Обобщението на пробния ви период не е достъпно.")
        XCTAssertEqual(bg.string("Completion unknown"), "Завършването е неизвестно")
        XCTAssertEqual(bg.format("Renewal is off. Your trial ends %1$@.", .text("17 октомври")),
                       "Подновяването е изключено. Пробният ви период приключва на 17 октомври.")
        XCTAssertEqual(bg.format("%1$@ → %2$@ kg", .text("12,5"), .text("18")), "12,5 → 18 кг")
    }
}
