import XCTest
@testable import ZeroOne

final class StepsGoalObservationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(_ steps: Int, second: Double = 100, goal: Int = 8_000,
                             calendar: Calendar? = nil, date: Date? = nil) -> StepsGoalObservation {
        let cal = calendar ?? self.calendar
        let start = cal.startOfDay(for: date ?? day)
        return StepsGoalObservation(calendar: cal, now: start.addingTimeInterval(10_000), goal: goal,
            readingDayStart: start, readAt: start.addingTimeInterval(second), steps: steps, isAvailable: true)!
    }

    private func seed(_ gate: inout StepsGoalObservationGate, _ value: StepsGoalObservation) {
        let ticket = gate.begin(nil, allowCelebration: false)
        XCTAssertNil(gate.complete(ticket, with: value))
    }

    private func observed(_ gate: inout StepsGoalObservationGate, before: StepsGoalObservation?,
                          allowCelebration: Bool = true, after: StepsGoalObservation?) -> StepsGoalObservationGate.Attainment? {
        let ticket = gate.begin(before, allowCelebration: allowCelebration)
        return gate.complete(ticket, with: after)
    }

    func testInitialBelowToAttainedLoadIsBaselineOnly() {
        var gate = StepsGoalObservationGate()
        let ticket = gate.begin(observation(7_999), allowCelebration: true)
        XCTAssertNil(gate.complete(ticket, with: observation(8_000, second: 101)))
    }

    func testSuccessfulFreshSameDayBelowToGoalEarnsObservedAttainment() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_999)
        seed(&gate, before)
        let ticket = gate.begin(before, allowCelebration: true)
        let result = gate.complete(ticket, with: observation(8_000, second: 101))
        XCTAssertEqual(result?.fromProgress, Double(7_999) / 8_000)
        XCTAssertEqual(result?.observedReadAt, observation(8_000, second: 101).readAt)
    }

    func testHigherButStillBelowDoesNotCelebrate() {
        var gate = StepsGoalObservationGate()
        let before = observation(6_000)
        seed(&gate, before)
        let ticket = gate.begin(before, allowCelebration: true)
        XCTAssertNil(gate.complete(ticket, with: observation(7_999, second: 101)))
    }

    func testInitiallyAttainedCorrectionAndRecrossCannotReplay() {
        var gate = StepsGoalObservationGate()
        let settled = observation(8_100)
        seed(&gate, settled)
        let below = observation(7_900, second: 101)
        XCTAssertNil(observed(&gate, before: settled, after: below))
        XCTAssertNil(observed(&gate, before: below, after: observation(8_100, second: 102)))
    }

    func testReadFailureThenRecoveredAttainmentDoesNotEarnEvent() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        XCTAssertNil(observed(&gate, before: before, after: nil))
        XCTAssertNil(observed(&gate, before: nil, after: observation(8_001, second: 102)))
    }

    func testRecoveredBelowSeedsThenSubsequentFreshAttainmentCanEarnEvent() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        XCTAssertNil(observed(&gate, before: before, after: nil))
        let recovered = observation(7_999, second: 102)
        XCTAssertNil(observed(&gate, before: nil, after: recovered))
        XCTAssertNotNil(observed(&gate, before: recovered, after: observation(8_000, second: 103)))
    }

    func testGoalChangeDoesNotConvertBelowIntoAchievement() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        XCTAssertNil(observed(&gate, before: before, after: observation(7_900, second: 101, goal: 7_000)))
    }

    func testNewDayCannotCrossFromOldDay() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        XCTAssertNil(observed(&gate, before: before, after: observation(8_000, second: 101, date: tomorrow)))
    }

    func testCalendarChangeCannotReuseOldBaseline() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        var changed = calendar
        changed.timeZone = TimeZone(secondsFromGMT: 3_600)!
        XCTAssertNil(observed(&gate, before: before, after: observation(8_000, second: 101, calendar: changed)))
    }

    func testSameTimestampNumberChangeIsNotFreshEvidence() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        XCTAssertNil(observed(&gate, before: before, after: observation(8_000)))
    }

    func testSkippedUnchangedQueryKeepsActualBaselineButDoesNotCelebrate() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        XCTAssertNil(observed(&gate, before: before, after: before))
        XCTAssertNotNil(observed(&gate, before: before, after: observation(8_000, second: 101)))
    }

    func testClockRegressionBreaksContinuity() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        let regressed = observation(7_950, second: 99)
        XCTAssertNil(observed(&gate, before: before, after: regressed))
        XCTAssertNil(observed(&gate, before: regressed, after: observation(8_000, second: 100)))
    }

    func testDisappearOrGoalInvalidationRejectsPendingCompletion() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        let pending = gate.begin(before, allowCelebration: true)
        gate.invalidate()
        XCTAssertNil(gate.complete(pending, with: observation(8_000, second: 101)))
    }

    func testRepeatedCompletionAndSubsequentAtGoalDoNotReplay() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900), after = observation(8_000, second: 101)
        seed(&gate, before)
        let ticket = gate.begin(before, allowCelebration: true)
        XCTAssertNotNil(gate.complete(ticket, with: after))
        XCTAssertNil(gate.complete(ticket, with: after))
        XCTAssertNil(observed(&gate, before: after, after: observation(8_200, second: 102)))
    }

    func testOverlappingOlderTicketCannotFinishNewerObservation() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900), after = observation(8_000, second: 101)
        seed(&gate, before)
        let older = gate.begin(before, allowCelebration: true)
        let newer = gate.begin(before, allowCelebration: true)
        XCTAssertNil(gate.complete(older, with: after))
        XCTAssertNotNil(gate.complete(newer, with: after))
    }

    func testSceneReactivationIsBaselineOnly() {
        var gate = StepsGoalObservationGate()
        let before = observation(7_900)
        seed(&gate, before)
        gate.invalidate()
        XCTAssertNil(observed(&gate, before: before, allowCelebration: false, after: observation(8_000, second: 101)))
    }

    func testMissingGoalCountAvailabilityFutureAndOldReadingAreRejected() {
        let now = calendar.startOfDay(for: day).addingTimeInterval(100)
        func make(goal: Int? = 8_000, steps: Int? = 0, readAt: Date? = nil, available: Bool = true) -> StepsGoalObservation? {
            StepsGoalObservation(calendar: calendar, now: now, goal: goal,
                readingDayStart: calendar.startOfDay(for: now), readAt: readAt ?? now, steps: steps, isAvailable: available)
        }
        XCTAssertNil(make(goal: nil)); XCTAssertNil(make(goal: 0)); XCTAssertNil(make(steps: nil))
        XCTAssertNil(make(steps: -1)); XCTAssertNil(make(available: false))
        XCTAssertNil(make(readAt: now.addingTimeInterval(1)))
        XCTAssertNil(make(readAt: now.addingTimeInterval(-86_400)))
    }

    func testDSTDayUsesCalendarIntervalRatherThanFixed86400() {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let fall = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        XCTAssertEqual(observation(1, calendar: cal, date: spring).context.day.duration, 23 * 3_600)
        XCTAssertEqual(observation(1, calendar: cal, date: fall).context.day.duration, 25 * 3_600)
    }

    func testReduceMotionTimingHasNoDiscOrTravelAndKeepsSettledReading() {
        let f = StepsGoalMomentTiming.frame(elapsed: 0.06, fromProgress: 0.2, reduceMotion: true)
        XCTAssertEqual(f.progress, 1); XCTAssertEqual(f.discScale, 0); XCTAssertEqual(f.discOpacity, 0)
        XCTAssertEqual(f.checkScale, 1); XCTAssertEqual(f.checkOpacity, 0.5, accuracy: 1e-12)
        XCTAssertFalse(f.onAccent)
    }

    func testBezierSolvesTimeCoordinateAndPreservesEndpoints() {
        XCTAssertEqual(StepsGoalMomentTiming.curve(0.5, 0, 0, 1, 1), 0.5, accuracy: 1e-10)
        XCTAssertEqual(StepsGoalMomentTiming.land(0), 0); XCTAssertEqual(StepsGoalMomentTiming.land(1), 1)
        let f = StepsGoalMomentTiming.frame(elapsed: StepsGoalMomentTiming.end, fromProgress: 0.2, reduceMotion: false)
        XCTAssertEqual(f.progress, 1); XCTAssertEqual(f.discOpacity, 0); XCTAssertEqual(f.checkScale, 1, accuracy: 1e-10)
    }
}
