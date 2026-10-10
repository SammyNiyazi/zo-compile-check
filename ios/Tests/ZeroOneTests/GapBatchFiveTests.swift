import XCTest
@testable import ZeroOne

/// Proof 53 the trial's last days, proof 56 the trial notifications.
final class GapBatchFiveTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testTheCardShowsOnDayThirteenAndFourteenAndTheRecapOnTheLastEvening() {
        // Started 3 Oct 10:23, Apple charges 17 Oct 10:23.
        let window = TrialWindow(end: date(17, 10, 23))
        XCTAssertEqual(window.dayNumber(now: date(15, 9), calendar: calendar), 13)
        XCTAssertEqual(window.daysLeft(now: date(15, 9), calendar: calendar), 2)
        XCTAssertFalse(window.showsTodayCard(now: date(14, 20), calendar: calendar))
        XCTAssertTrue(window.showsTodayCard(now: date(15, 9), calendar: calendar))
        XCTAssertTrue(window.showsTodayCard(now: date(16, 22), calendar: calendar))
        XCTAssertFalse(window.showsTodayCard(now: date(17, 11), calendar: calendar), "Charged: the card goes")

        XCTAssertFalse(window.recapIsDue(now: date(16, 12), calendar: calendar))
        XCTAssertTrue(window.recapIsDue(now: date(16, 17), calendar: calendar), "The evening before")
        XCTAssertTrue(window.recapIsDue(now: date(17, 8), calendar: calendar))
        XCTAssertTrue(window.recapIsDue(now: date(20, 8), calendar: calendar), "A week after it ended")
        XCTAssertFalse(window.recapIsDue(now: date(25, 8), calendar: calendar))
    }

    func testTheReminderUsesTheirNumbersAndTheExactDates() {
        let window = TrialWindow(end: date(17, 10, 23))
        let renewal = MembershipRecapRenewal(trialEnds: window.end, continuation: .renews,
                                             verifiedPrice: "$4.99", verifiedPeriod: "a month")
        let progress = TrialProgress(workouts: 9, sets: 112, bests: 3, topLift: nil, share: nil)
        let plans = TrialNotificationScheduler.plan(window: window, continuation: .renews, continued: false,
            renewal: renewal, progress: progress, now: date(10, 9), calendar: calendar, localization: .english)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.title, "2 days left in your trial")
        XCTAssertEqual(plans.first?.fireAt, date(15, 18))
        let day = Date.FormatStyle.dateTime.day().month(.wide).locale(AppLocalization.english.locale)
        XCTAssertEqual(plans.first?.body, "9 workouts and 3 new bests so far. On \(window.end.formatted(day)) it becomes $4.99 a month. "
            + "Cancel by \(date(16, 10, 23).formatted(day)) and nothing is charged.")
    }

    func testRenewalOffSwapsTheReminderForTheHeldCardAndContinuingClearsBoth() {
        let window = TrialWindow(end: date(17, 10, 23))
        let progress = TrialProgress(workouts: 1, sets: 12, bests: 0, topLift: nil, share: nil)
        let plans = TrialNotificationScheduler.plan(window: window, continuation: .cancelled, continued: false,
            renewal: nil, progress: progress, now: date(10, 9), calendar: calendar, localization: .english)
        XCTAssertEqual(plans.map(\.identifier), [TrialNotificationScheduler.waitingID])
        XCTAssertEqual(plans.first?.fireAt, date(20, 18))
        XCTAssertEqual(plans.first?.body, "Your card is held for you for 27 more days, with your 1 workout.")

        XCTAssertTrue(TrialNotificationScheduler.plan(window: window, continuation: .renews, continued: true,
            renewal: nil, progress: progress, now: date(10, 9), calendar: calendar, localization: .english).isEmpty)
    }

    @MainActor
    func testTheTrialIsRememberedAndTheRecapShowsOnce() {
        let defaults = UserDefaults(suiteName: "GapBatchFiveTests-\(UUID().uuidString)")!
        let store = TrialMomentStore(defaults: defaults)
        XCTAssertNil(store.window)
        store.record(MembershipRecapRenewal(trialEnds: date(17, 10), continuation: .cancelled,
                                            verifiedPrice: nil, verifiedPeriod: nil))
        store.markRecapShown()
        store.dismissCard()
        let reopened = TrialMomentStore(defaults: defaults)
        XCTAssertEqual(reopened.window?.end, date(17, 10))
        XCTAssertEqual(reopened.continuation, .cancelled)
        XCTAssertTrue(reopened.recapShown)
        XCTAssertTrue(reopened.cardDismissed)
        reopened.record(MembershipRecapRenewal(trialEnds: date(31, 10), continuation: .unknown,
                                               verifiedPrice: nil, verifiedPeriod: nil))
        XCTAssertFalse(reopened.recapShown, "A new trial gets its own recap")
        XCTAssertEqual(reopened.continuation, .unknown, "A new trial starts without the old answer")
        reopened.record(MembershipRecapRenewal(trialEnds: date(31, 10), continuation: .renews,
                                               verifiedPrice: nil, verifiedPeriod: nil))
        reopened.record(MembershipRecapRenewal(trialEnds: date(31, 10), continuation: .unknown,
                                               verifiedPrice: nil, verifiedPeriod: nil))
        XCTAssertEqual(reopened.continuation, .renews, "Unknown never overwrites what Apple said")
    }

    func testTheWalkActivityFollowsTheSavedCheckpoint() {
        let start = date(10, 7)
        var checkpoint = OutdoorActivityCheckpoint(kind: .run, trackingMode: .timerOnly, startedAt: start,
            checkpointedAt: start.addingTimeInterval(600), confirmedActiveSeconds: 600, phase: .recording)
        let live = WalkActivityProjection.make(surface: .recording, checkpoint: checkpoint, withoutGPS: true,
            accent: .yellow, language: .english, theme: .core)
        XCTAssertEqual(live?.state.phase, .noGPS)
        XCTAssertEqual(live?.state.elapsedAnchor, start, "The clock counts from the active start")
        XCTAssertNil(live?.state.frozenSeconds)
        XCTAssertNil(live?.state.distanceMetres, "Time only never invents distance")
        XCTAssertEqual(live?.kind, .run)

        checkpoint.phase = .paused
        let paused = WalkActivityProjection.make(surface: .paused, checkpoint: checkpoint, withoutGPS: true,
            accent: .yellow, language: .english, theme: .core)
        XCTAssertEqual(paused?.state.phase, .paused)
        XCTAssertEqual(paused?.state.frozenSeconds, 600)
        XCTAssertNil(WalkActivityProjection.make(surface: .setup, checkpoint: nil, withoutGPS: false,
            accent: .yellow, language: .english, theme: .core))
    }

    func testNoReadableHistoryIsUnknownNotZero() {
        let window = TrialWindow(end: date(17, 10))
        XCTAssertNil(TrialProgress.make(window: window, history: nil, calendar: calendar))
        XCTAssertEqual(TrialProgress.make(window: window, history: [], calendar: calendar)?.workouts, 0)
    }
}
