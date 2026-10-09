import XCTest
@testable import ZeroOne

final class ProfileSettingsYouPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var asOf: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))! }

    func testUnknownCardAndMonthRemainAbsent() {
        let value = ProfileSettingsYouSnapshot(asOf: asOf, displayName: "  Mira  ")
        XCTAssertEqual(value.displayName, "Mira")
        XCTAssertNil(value.card)
        XCTAssertNil(value.month)
        XCTAssertNil(value.bodyWeight)
    }

    func testKnownZeroCardStatsDifferFromUnknown() throws {
        let card = try XCTUnwrap(ProfileSettingsYouVerifiedCard(number: "0127", holderName: "Mira", workouts: 0))
        XCTAssertEqual(card.workouts, 0)
        XCTAssertNil(card.consecutiveWeeks)
        XCTAssertNil(card.personalBests)
        XCTAssertNil(card.recognition)
        XCTAssertFalse(card.hasFounderSticker)
    }

    func testCardNumbersDoNotAcceptIdentityOrEmailOrOutOfRange() {
        for number in ["", "0", "-1", "12a", "1.0", "16777216", "123456789", UUID().uuidString, "person@example.invalid"] {
            XCTAssertNil(ProfileSettingsYouVerifiedCard(number: number, holderName: "Mira"))
        }
        XCTAssertNotNil(ProfileSettingsYouVerifiedCard(number: "16777215", holderName: "Mira"))
    }

    func testRecognitionRequiresExplicitAuthorizedShape() {
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "2", holderName: "Mira", recognition: .founder))
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "1002", holderName: "Mira", recognition: .foundingMember))
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "1", holderName: "Mira", hasFounderSticker: true))
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "2", holderName: "Mira", recognition: .partner(tier: 5)))
        XCTAssertNotNil(ProfileSettingsYouVerifiedCard(number: "0001", holderName: "Mira", recognition: .founder, hasFounderSticker: true))
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "0001", holderName: "Sammy")?.recognition)
    }

    func testMalformedOptionalFactsFailClosed() throws {
        let card = try XCTUnwrap(ProfileSettingsYouVerifiedCard(number: "2", holderName: "Mira", crew: "bad\ncrew", workouts: -1))
        XCTAssertNil(card.crew)
        XCTAssertNil(card.workouts)
        XCTAssertNil(ProfileSettingsYouPresentation.cleanText("bad\u{202E}name"))
        XCTAssertNil(ProfileSettingsYouPresentation.cleanText(String(repeating: "x", count: 121)))
        XCTAssertNil(ProfileSettingsYouVerifiedCard(number: "2", holderName: "\u{0000}"))
    }

    func testFutureJoinDateAndInvalidClockCannotRenderCard() throws {
        let card = try XCTUnwrap(ProfileSettingsYouVerifiedCard(number: "2", holderName: "Mira", since: asOf.addingTimeInterval(1)))
        XCTAssertNil(ProfileSettingsYouSnapshot(asOf: asOf, card: card).card)
        let current = try XCTUnwrap(ProfileSettingsYouVerifiedCard(number: "2", holderName: "Mira", since: asOf))
        XCTAssertNotNil(ProfileSettingsYouSnapshot(asOf: asOf, card: current).card)
        let malformed = ProfileSettingsYouSnapshot(asOf: Date(timeIntervalSinceReferenceDate: .nan), card: current,
            bodyWeight: ProfileSettingsYouWeight(value: 70, unit: .kilograms))
        XCTAssertNil(malformed.card)
        XCTAssertNil(malformed.bodyWeight)
    }

    func testMonthRejectsPartialIntervalsAndDifferentObservationTime() throws {
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: asOf))
        XCTAssertNil(ProfileSettingsYouMonth(start: asOf, end: interval.end, asOf: asOf, calendar: calendar, scope: .recordedHistory, workouts: 1))
        let month = try XCTUnwrap(ProfileSettingsYouMonth(start: interval.start, end: interval.end, asOf: asOf, calendar: calendar, scope: .recordedHistory, workouts: 1))
        XCTAssertNil(ProfileSettingsYouSnapshot(asOf: asOf.addingTimeInterval(1), month: month).month)
        XCTAssertNotNil(ProfileSettingsYouSnapshot(asOf: asOf, month: month).month)
        var monday = calendar
        monday.firstWeekday = 2
        monday.minimumDaysInFirstWeek = 4
        let may = try XCTUnwrap(monday.date(from: DateComponents(year: 2026, month: 5, day: 8)))
        let bounds = try XCTUnwrap(monday.dateInterval(of: .month, for: may))
        let first = try XCTUnwrap(ProfileSettingsYouMonth(start: bounds.start, end: bounds.end, asOf: bounds.start,
            calendar: monday, scope: .recordedHistory, workouts: 0))
        let last = try XCTUnwrap(ProfileSettingsYouMonth(start: bounds.start, end: bounds.end, asOf: bounds.end.addingTimeInterval(-1),
            calendar: monday, scope: .recordedHistory, workouts: 0))
        XCTAssertEqual(first.calendarWeek?.current, 1)
        XCTAssertEqual(last.calendarWeek?.current, last.calendarWeek?.total)
        XCTAssertEqual(first.calendarWeek?.total, last.calendarWeek?.total)
    }

    func testLocalMonthCannotEstablishSocialOrGlobalBestFacts() throws {
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: asOf))
        let month = try XCTUnwrap(ProfileSettingsYouMonth(start: interval.start, end: interval.end, asOf: asOf, calendar: calendar, scope: .recordedHistory, workouts: 0, respectsReceived: 9, newBests: 4))
        XCTAssertEqual(month.workouts, 0)
        XCTAssertNil(month.respectsReceived)
        XCTAssertNil(month.newBests)
        XCTAssertNil(month.goal)
    }

    func testUnreadableHistoryDiffersFromAcknowledgedEmptyHistory() throws {
        XCTAssertNil(ProfileSettingsYouPresentation.recordedMonth(history: nil, asOf: asOf, calendar: calendar))
        let empty = try XCTUnwrap(ProfileSettingsYouPresentation.recordedMonth(history: [], asOf: asOf, calendar: calendar))
        XCTAssertEqual(empty.workouts, 0)
        XCTAssertEqual(empty.scope, .recordedHistory)
        XCTAssertNil(empty.respectsReceived)
        XCTAssertNil(empty.newBests)
    }

    func testRecordedHistoryUsesPeriodAndRejectsDuplicateFutureOrInvalidSummary() throws {
        let current = try entry(at: asOf.addingTimeInterval(-60))
        let old = try entry(at: calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!)
        XCTAssertEqual(ProfileSettingsYouPresentation.recordedMonth(history: [current, old], asOf: asOf, calendar: calendar)?.workouts, 1)
        XCTAssertNil(ProfileSettingsYouPresentation.recordedMonth(history: [current, current], asOf: asOf, calendar: calendar))
        XCTAssertNil(ProfileSettingsYouPresentation.recordedMonth(history: [try entry(at: asOf.addingTimeInterval(1))], asOf: asOf, calendar: calendar))
        XCTAssertNil(ProfileSettingsYouPresentation.recordedMonth(history: [try entry(at: asOf, completed: 3, planned: 2)], asOf: asOf, calendar: calendar))
    }

    func testNoFactsMonthIsOmittedRatherThanFilledWithZeros() throws {
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: asOf))
        let month = try XCTUnwrap(ProfileSettingsYouMonth(start: interval.start, end: interval.end, asOf: asOf, calendar: calendar, scope: .verifiedMemberActivity))
        XCTAssertNil(ProfileSettingsYouSnapshot(asOf: asOf, month: month).month)
    }

    func testGoalRailRequiresRealTargetAndSettlesFullWithoutCurrent() throws {
        XCTAssertNil(ProfileSettingsYouMonth.Goal(completed: 0, target: 0))
        XCTAssertNil(ProfileSettingsYouMonth.Goal(completed: -1, target: 15))
        let partial = try XCTUnwrap(ProfileSettingsYouMonth.Goal(completed: 5, target: 15))
        XCTAssertEqual(ProfileSettingsYouPresentation.rail(goal: partial).filter { $0 == .done }.count, 5)
        XCTAssertEqual(ProfileSettingsYouPresentation.rail(goal: partial).filter { $0 == .current }.count, 1)
        let full = try XCTUnwrap(ProfileSettingsYouMonth.Goal(completed: Int.max, target: 1))
        XCTAssertEqual(ProfileSettingsYouPresentation.rail(goal: full), Array(repeating: .done, count: 15))
    }

    func testWeightRejectsUnknownOrNonfiniteOrNonpositiveValues() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertNil(ProfileSettingsYouWeight(value: value, unit: .kilograms))
        }
        XCTAssertEqual(ProfileSettingsYouWeight(value: 76.5, unit: .kilograms)?.value, 76.5)
    }

    func testTiltIsBoundedAndReduceMotionAlwaysSettles() {
        XCTAssertEqual(ProfileSettingsYouPresentation.boundedTilt(.nan), 0)
        XCTAssertEqual(ProfileSettingsYouPresentation.boundedTilt(.infinity), 0)
        XCTAssertEqual(ProfileSettingsYouPresentation.boundedTilt(-100), -6)
        XCTAssertEqual(ProfileSettingsYouPresentation.boundedTilt(100), 6)
        XCTAssertEqual(ProfileSettingsYouPresentation.sheenPosition(tilt: 6, reduceMotion: true), 0.62)
        XCTAssertEqual(ProfileSettingsYouPresentation.sheenPosition(tilt: 6, reduceMotion: false), 0.90, accuracy: 0.0001)
    }

    private func entry(at date: Date, completed: Int = 1, planned: Int = 1) throws -> WorkoutHistoryEntry {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "title": "Recorded session",
            "completedAt": date.timeIntervalSinceReferenceDate, "completedSetCount": completed,
            "plannedSetCount": planned, "wasAdapted": false])
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: data)
    }
}
