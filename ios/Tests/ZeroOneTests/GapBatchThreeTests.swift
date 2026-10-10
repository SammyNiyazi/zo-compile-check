import XCTest
@testable import ZeroOne

/// Proof 19 sleep week, proof 41 missed plans.
final class GapBatchThreeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testSleepIsGroupedIntoNightsAndOverlapsCountOnce() {
        let samples = [
            SleepSegment(stage: .core, start: date(9, 23, 40), end: date(10, 1, 0)),
            SleepSegment(stage: .deep, start: date(10, 1, 0), end: date(10, 2, 0)),
            SleepSegment(stage: .awake, start: date(10, 2, 0), end: date(10, 2, 10)),
            SleepSegment(stage: .rem, start: date(10, 2, 10), end: date(10, 6, 52)),
            // A second source repeating part of the night must not add time.
            SleepSegment(stage: .asleep, start: date(10, 1, 30), end: date(10, 1, 50)),
            SleepSegment(stage: .core, start: date(8, 23, 0), end: date(9, 6, 0))
        ]
        let week = SleepWeek.make(samples: samples, today: date(10, 9), calendar: calendar)
        XCTAssertEqual(week.nights.count, 7)
        let last = try! XCTUnwrap(week.lastNight)
        XCTAssertEqual(last.asleepSeconds, (7 * 60 + 12 - 10) * 60, "23:40 to 06:52 less 10 minutes awake")
        XCTAssertEqual(last.fellAsleep, date(9, 23, 40))
        XCTAssertEqual(last.wokeUp, date(10, 6, 52))
        XCTAssertEqual(week.nights.filter(\.hasData).count, 2)
        XCTAssertEqual(week.nightsOver(goalMinutes: 421).met, 1, "422 minutes meets it, 420 does not")
        XCTAssertEqual(week.nightsOver(goalMinutes: 421).recorded, 2)
        let range = try! XCTUnwrap(week.bedtimeRange(calendar: calendar))
        XCTAssertEqual(range.earliest, date(8, 23, 0))
        XCTAssertEqual(range.latest, date(9, 23, 40))
    }

    func testBedtimesAfterMidnightSortAfterLateEvenings() {
        let samples = [
            SleepSegment(stage: .core, start: date(9, 0, 20), end: date(9, 7, 0)),
            SleepSegment(stage: .core, start: date(9, 23, 10), end: date(10, 7, 0))
        ]
        let range = try! XCTUnwrap(SleepWeek.make(samples: samples, today: date(10, 9), calendar: calendar).bedtimeRange(calendar: calendar))
        XCTAssertEqual(range.earliest, date(9, 23, 10))
        XCTAssertEqual(range.latest, date(9, 0, 20))
    }

    func testLiveActivityCoachUsesLastTimeAndTheRealGain() throws {
        var session = WorkoutSession(title: "Legs", customWorkoutID: UUID(), exercises: [
            WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Goblet squat", targetLoad: Load(16),
                targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
                previousPerformance: [PreviousSetPerformance(load: Load(16), reps: 10), PreviousSetPerformance(load: Load(16), reps: 10)]))
        ])
        let english = AppLocalization.english
        let before = WorkoutActivityCoach.lines(session: session, phase: .active, localization: english)
        XCTAssertTrue(before.coach?.hasPrefix("Last time 16 kg × 10 reps. Target today:") == true, before.coach ?? "nil")
        XCTAssertEqual(before.lastShort, "Last 16 × 10")
        XCTAssertNil(before.gain)

        _ = try session.completeCurrentSet(load: Load(16), reps: 11, at: Date(timeIntervalSince1970: 100))
        let resting = WorkoutActivityCoach.lines(session: session, phase: .rest, localization: english)
        XCTAssertEqual(resting.gain, "+1 rep")
        session.skipRest()
        _ = try session.completeCurrentSet(load: Load(18.5), reps: 10, at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(WorkoutActivityCoach.lines(session: session, phase: .rest, localization: english).gain, "+2.5 kg")
    }

    func testAMissedPlanWaitsThreeDaysThenLeavesToday() {
        var missed = WorkoutAppointment(reference: .custom(UUID()), title: "Full Body A", startsAt: date(9, 18, 30))
        XCTAssertEqual(MissedPlan.latest([missed], now: date(10, 9))?.id, missed.id)
        XCTAssertNil(MissedPlan.latest([missed], now: date(9, 18, 40)), "Still inside its own reservation")
        XCTAssertNil(MissedPlan.latest([missed], now: date(12, 19)), "Gone after three days")
        missed.startedSessionID = UUID()
        XCTAssertNil(MissedPlan.latest([missed], now: date(10, 9)), "A started plan is not missed")
        XCTAssertEqual(MissedPlan.tomorrow(at: date(9, 18, 30), now: date(10, 9), calendar: calendar), date(11, 18, 30))
    }
}
