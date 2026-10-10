import XCTest
@testable import ZeroOne

/// Pure facts behind proof 41's scheduling surfaces. Pickers, Calendar
/// access, alerts and VoiceOver need native acceptance; these rules do not.
final class WorkoutSchedulePresentationTests: XCTestCase {
    private let sofia = TimeZone(identifier: "Europe/Sofia")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func instant(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func wallTime(_ date: Date, in zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    }

    func testTheDateTileReadsTheInstantInTheGivenZone() {
        // 23:30 in Sofia on Thursday 1 October is already Friday 2 in Tokyo.
        let late = instant(10, 1, 23, 30, in: sofia)
        let english = Locale(identifier: "en_GB")
        XCTAssertEqual(WorkoutSchedulePresentation.dateTile(for: late, zone: sofia, locale: english),
                       .init(weekday: "Thu", day: 1))
        XCTAssertEqual(WorkoutSchedulePresentation.dateTile(for: late, zone: tokyo, locale: english),
                       .init(weekday: "Fri", day: 2))
    }

    func testTodayAndTomorrowAreCalendarDaysInTheZone() {
        let now = instant(10, 1, 9, in: sofia)
        XCTAssertEqual(WorkoutSchedulePresentation.relativeDay(of: instant(10, 1, 23, 59, in: sofia), now: now, zone: sofia), .today)
        XCTAssertEqual(WorkoutSchedulePresentation.relativeDay(of: instant(10, 2, 0, 0, in: sofia), now: now, zone: sofia), .tomorrow)
        XCTAssertEqual(WorkoutSchedulePresentation.relativeDay(of: instant(10, 3, 18, in: sofia), now: now, zone: sofia), .other)
    }

    func testDayChoicesStartTodayInTheZone() {
        let days = WorkoutSchedulePresentation.dayChoices(now: instant(10, 1, 9, in: sofia), zone: sofia)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, instant(10, 1, 0, in: sofia))
        XCTAssertEqual(days.last, instant(10, 7, 0, in: sofia))
        XCTAssertEqual(WorkoutSchedulePresentation.dayChoices(now: .now, zone: sofia, count: 0), [])
    }

    func testMovingKeepsTheWallClockTime() throws {
        let moved = try XCTUnwrap(WorkoutSchedulePresentation.moving(
            instant(10, 1, 18, 30, in: sofia), toDay: instant(10, 3, 0, in: sofia), zone: sofia))
        XCTAssertEqual(wallTime(moved, in: sofia), DateComponents(month: 10, day: 3, hour: 18, minute: 30))
    }

    func testMovingIntoASkippedHourInventsNoTime() {
        // Sofia skips 03:00 to 04:00 on Sunday 29 March 2026.
        XCTAssertNil(WorkoutSchedulePresentation.moving(
            instant(3, 28, 3, 30, in: sofia), toDay: instant(3, 29, 0, in: sofia), zone: sofia))
    }

    func testMovingIntoARepeatedHourTakesItsFirstInstant() throws {
        // Sofia repeats 03:00 to 04:00 on Sunday 25 October 2026.
        let moved = try XCTUnwrap(WorkoutSchedulePresentation.moving(
            instant(10, 24, 3, 30, in: sofia), toDay: instant(10, 25, 0, in: sofia), zone: sofia))
        let both = AppointmentWallTime.instants(year: 2026, month: 10, day: 25, hour: 3, minute: 30, timeZone: sofia)
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(moved, both.first)
    }

    private func session(exercises count: Int, minutes: Int?) -> WorkoutSession {
        let exercises = (0 ..< count).map { index in
            WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseID(rawValue: "EX-\(index)"), name: "Exercise \(index)",
                                               targetLoad: Load(10), targetReps: RepRange(8, 12),
                                               plannedSetCount: 3, restSeconds: 90, previousPerformance: []))
        }
        return WorkoutSession(title: "Full Body A", targetDurationMinutes: minutes, exercises: exercises)
    }

    func testTheStartSummaryCountsTheSessionAndStacksFour() {
        let summary = WorkoutSchedulePresentation.StartSummary(session: session(exercises: 6, minutes: 30))
        XCTAssertEqual(summary.exerciseCount, 6)
        XCTAssertEqual(summary.setCount, 18)
        XCTAssertEqual(summary.minutes, 30)
        XCTAssertEqual(summary.stackExerciseIDs.count, 4)
        XCTAssertEqual(summary.overflowCount, 2)
    }

    func testNoAuthoredTargetClaimsNoMinutes() {
        XCTAssertNil(WorkoutSchedulePresentation.StartSummary(session: session(exercises: 2, minutes: nil)).minutes)
        XCTAssertNil(WorkoutSchedulePresentation.StartSummary(session: session(exercises: 2, minutes: 0)).minutes)
        XCTAssertEqual(WorkoutSchedulePresentation.StartSummary(session: session(exercises: 2, minutes: nil)).overflowCount, 0)
    }
}
