import SwiftUI
import XCTest
@testable import ZeroOne

/// Tests the actual UI-owned lifetime seeded by the unchanged observation gate.
/// These do not execute SwiftUI tasks, OS haptics, geometry or renderer pixels.
@MainActor
final class StepsThemeWinLifetimeTests: XCTestCase {
    func testEarnedAttainmentRetainsIdentityContextReadAndOriginalBurstInstant() throws {
        let moment = try attainment()
        let instant = ContinuousClock.now
        let start = try XCTUnwrap(StepsGoalBurstStart(moment: moment,
            theme: .resolve(designTheme: .retro, colorScheme: .light),
            startedAt: instant, reduceMotion: false))
        XCTAssertEqual(start.id, moment.id)
        XCTAssertEqual(start.context, moment.context)
        XCTAssertEqual(start.moment.observedReadAt, moment.observedReadAt)
        XCTAssertEqual(start.startedAt, instant)
        XCTAssertEqual(start.theme.designTheme, .retro)
        XCTAssertEqual(start.theme.colorScheme, .light)
    }

    func testCoreKeepsSuppressedReducedMotionAndParentOwnedNormalRemoval() throws {
        let moment = try attainment(), instant = ContinuousClock.now
        let core = ZeroOneThemeTokens.resolve(designTheme: .core)
        XCTAssertNil(StepsGoalBurstStart(moment: moment, theme: core,
            startedAt: instant, reduceMotion: true))
        var normal = try XCTUnwrap(StepsGoalBurstStart(moment: moment, theme: core,
            startedAt: instant, reduceMotion: false))
        XCTAssertNil(normal.remainingTime(elapsed: 0.5, liveReduceMotion: false),
            "The new cleanup must not take ownership of Core's installed ring timeline.")
        XCTAssertFalse(normal.observeReduceMotion(true), "The actual parent removes Core travel immediately.")
    }

    func testInitiallyReducedNonCoreRetainsOnlyOriginalStaticLifetime() throws {
        for theme in [ZOTheme.retro, .freak, .princess] {
            let moment = try attainment(), instant = ContinuousClock.now
            let start = try XCTUnwrap(StepsGoalBurstStart(moment: moment,
                theme: .resolve(designTheme: theme), startedAt: instant, reduceMotion: true))
            XCTAssertTrue(start.usesReducedMotion(live: false))
            XCTAssertEqual(try XCTUnwrap(start.remainingTime(elapsed: 1, liveReduceMotion: false)), 0.92, accuracy: 0.000_001)
            XCTAssertEqual(start.remainingTime(elapsed: 1.92, liveReduceMotion: false), 0)
            XCTAssertEqual(start.startedAt, instant)
            XCTAssertEqual(start.id, moment.id)
        }
    }

    func testMidBurstReduceMotionShortensDeadlineWithoutRenewingClockOrEvent() throws {
        let moment = try attainment(), instant = ContinuousClock.now
        var start = try XCTUnwrap(StepsGoalBurstStart(moment: moment,
            theme: .resolve(designTheme: .retro), startedAt: instant, reduceMotion: false))
        XCTAssertEqual(try XCTUnwrap(start.remainingTime(elapsed: 1.1, liveReduceMotion: false)), 1.3, accuracy: 0.000_001)
        XCTAssertTrue(start.observeReduceMotion(true))
        XCTAssertEqual(try XCTUnwrap(start.remainingTime(elapsed: 1.1, liveReduceMotion: true)), 0.82, accuracy: 0.000_001)
        XCTAssertEqual(start.startedAt, instant)
        XCTAssertEqual(start.id, moment.id)
        XCTAssertEqual(start.context, moment.context)
    }

    func testLateReduceMotionExpiresInsteadOfRestartingStaticWrapper() throws {
        var start = try XCTUnwrap(StepsGoalBurstStart(moment: attainment(),
            theme: .resolve(designTheme: .princess), startedAt: ContinuousClock.now, reduceMotion: false))
        XCTAssertEqual(try XCTUnwrap(start.remainingTime(elapsed: 2.1, liveReduceMotion: false)), 0.3, accuracy: 0.000_001)
        XCTAssertTrue(start.observeReduceMotion(true))
        XCTAssertEqual(start.remainingTime(elapsed: 2.1, liveReduceMotion: true), 0,
            "An old earned event cannot buy a fresh 1.92 seconds after a setting toggle.")
    }

    func testRepeatedReduceMotionTogglesCannotResumeTravelOrExtendEvent() throws {
        let moment = try attainment(), instant = ContinuousClock.now
        var start = try XCTUnwrap(StepsGoalBurstStart(moment: moment,
            theme: .resolve(designTheme: .freak), startedAt: instant, reduceMotion: false))
        for value in [true, false, true, false] {
            XCTAssertTrue(start.observeReduceMotion(value))
            XCTAssertTrue(start.usesReducedMotion(live: value))
            XCTAssertEqual(try XCTUnwrap(start.remainingTime(elapsed: 1.8, liveReduceMotion: value)), 0.12, accuracy: 0.000_001)
            XCTAssertEqual(start.startedAt, instant)
            XCTAssertEqual(start.id, moment.id)
        }
    }

    func testInvalidElapsedCannotScheduleAnUnboundedCleanup() throws {
        let start = try XCTUnwrap(StepsGoalBurstStart(moment: attainment(),
            theme: .resolve(designTheme: .retro), startedAt: ContinuousClock.now, reduceMotion: false))
        for elapsed in [-1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(start.remainingTime(elapsed: elapsed, liveReduceMotion: false), 0)
        }
    }

    private func attainment() throws -> StepsGoalObservationGate.Attainment {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func observed(_ count: Int, _ second: Double) throws -> StepsGoalObservation {
            try XCTUnwrap(StepsGoalObservation(calendar: calendar,
                now: day.addingTimeInterval(1_000), goal: 8_000, readingDayStart: day,
                readAt: day.addingTimeInterval(second), steps: count, isAvailable: true))
        }
        let before = try observed(7_999, 100), after = try observed(8_000, 101)
        var gate = StepsGoalObservationGate()
        let baseline = gate.begin(nil, allowCelebration: false)
        XCTAssertNil(gate.complete(baseline, with: before))
        let actualQuery = gate.begin(before, allowCelebration: true)
        return try XCTUnwrap(gate.complete(actualQuery, with: after))
    }
}
