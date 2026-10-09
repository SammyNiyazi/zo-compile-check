import XCTest
@testable import ZeroOne

final class TrainingDayRemindersTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // Friday 9 October 2026 is Foundation weekday 6; Saturday is 7.
    func testRemindsOnTrainingDaysTodayAndTomorrowAtTheChosenTime() throws {
        let notes = TrainingDayReminders.candidates(
            trainingWeekdays: [6, 7], programmeID: "full-body", sessionTitle: "Upper body A",
            estimatedMinutes: 40, reminderMinute: 18 * 60, lastCompletedAt: nil,
            now: date(2026, 10, 9, 9), calendar: calendar)
        XCTAssertEqual(notes.count, 2)
        let first = try XCTUnwrap(notes.first)
        XCTAssertEqual(first.id, "training-day.2026-10-09")
        XCTAssertEqual(first.title, "Training day")
        XCTAssertEqual(first.body, "Upper body A is ready when you are. About 40 min.")
        XCTAssertEqual(first.deliveryDate, date(2026, 10, 9, 18))
        XCTAssertEqual(first.expiresAt, date(2026, 10, 10, 0))
        XCTAssertEqual(first.kind, .fits)
        XCTAssertFalse(first.kind.isPassive)
        XCTAssertNotEqual(notes[0].occurrenceID, notes[1].occurrenceID)
    }

    func testQuietWhenTrainedTodayTimePassedOffOrRestDay() {
        func build(now: Date, minute: Int? = 18 * 60, weekdays: [Int]? = [6], trained: Date? = nil) -> [SmartNoteCandidate] {
            TrainingDayReminders.candidates(trainingWeekdays: weekdays, programmeID: nil, sessionTitle: "Upper body A",
                estimatedMinutes: nil, reminderMinute: minute, lastCompletedAt: trained, now: now, calendar: calendar)
        }
        XCTAssertTrue(build(now: date(2026, 10, 9, 9), trained: date(2026, 10, 9, 7)).isEmpty)
        XCTAssertTrue(build(now: date(2026, 10, 9, 19)).isEmpty)
        XCTAssertTrue(build(now: date(2026, 10, 9, 9), minute: nil).isEmpty)
        XCTAssertTrue(build(now: date(2026, 10, 9, 9), weekdays: [2]).isEmpty)
        XCTAssertTrue(build(now: date(2026, 10, 9, 9), weekdays: nil).isEmpty)
        XCTAssertEqual(build(now: date(2026, 10, 9, 9)).first?.body, "Upper body A is ready when you are.")
    }

    func testRebuildKeepsTheSameDayIdentityAndOtherNotes() throws {
        let day = date(2026, 10, 9, 0)
        XCTAssertEqual(TrainingDayReminders.occurrenceID(for: day, calendar: calendar),
                       TrainingDayReminders.occurrenceID(for: date(2026, 10, 9, 23), calendar: calendar))
        let fresh = TrainingDayReminders.candidates(trainingWeekdays: [6], programmeID: nil, sessionTitle: "A",
            estimatedMinutes: nil, reminderMinute: 18 * 60, lastCompletedAt: nil, now: date(2026, 10, 9, 9), calendar: calendar)
        let other = SmartNoteCandidate(id: "progress.x", occurrenceID: UUID(), revision: 1, kind: .progress,
            title: "t", body: "b", directTitle: nil, directBody: nil, reasons: [], unknowns: [],
            deliveryDate: date(2026, 10, 10, 8), expiresAt: date(2026, 10, 11, 0),
            isRestDay: false, isCurrent: true, isFreshEvent: true)
        let merged = TrainingDayReminders.merged([other] + fresh, with: fresh)
        XCTAssertEqual(merged.map(\.id), ["progress.x", "training-day.2026-10-09"])
    }

    func testOldSavedPreferencesStillDecode() throws {
        let old = try JSONEncoder().encode(SmartNotePreferences())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "trainingReminderMinute")
        let decoded = try JSONDecoder().decode(SmartNotePreferences.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.trainingReminderMinute)
    }
}
