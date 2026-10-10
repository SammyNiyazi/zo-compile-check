import XCTest
@testable import ZeroOne

/// Proof 26 voice that acts on a clear request, proof 23 tracker reminders.
final class GapBatchFourTests: XCTestCase {
    func testClearVoiceRequestsActAndUnclearOnesDoNot() {
        XCTAssertEqual(VoiceQuickIntent.match("I drank 500 ml of water"), .addWater(milliliters: 500))
        XCTAssertEqual(VoiceQuickIntent.match("Start my workout"), .startWorkout)
        XCTAssertEqual(VoiceQuickIntent.match("Log food"), .open(.logFood))
        XCTAssertEqual(VoiceQuickIntent.match("Open my steps"), .open(.steps))
        XCTAssertEqual(VoiceQuickIntent.match("show history"), .open(.history))
        XCTAssertEqual(VoiceQuickIntent.match("go for a run"), .open(.walk))
        XCTAssertNil(VoiceQuickIntent.match("Turn off the notifications"), "Not sure: the options sheet decides")
        XCTAssertNil(VoiceQuickIntent.match("water"), "Water without an amount asks instead")
        XCTAssertNil(VoiceQuickIntent.match("   "))
    }

    func testTrackerRemindersCoverTwoDaysAndDropTheNudgeOnceLogged() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 7, minute: 0))!
        let morning = DietTrackerTime(hour: 8, minute: 0)
        var draft = DietTrackerDraft()
        draft.name = "Vitamin D"
        draft.kind = .supplement
        draft.dose = "1 capsule"
        draft.times = [morning]
        draft.remindMe = true
        draft.remindAgainIfNotLogged = true
        let tracker = try draft.validated(id: UUID(), at: now)
        var snapshot = DietTrackerSnapshot(version: 1, trackers: [tracker], completions: [])

        let plan = DietTrackerReminderPlan.make(snapshot, now: now, calendar: calendar)
        XCTAssertEqual(plan.count, 4, "Today and tomorrow, each with the 08:00 reminder and the 08:30 nudge")
        XCTAssertEqual(plan.first?.title, "Vitamin D")
        XCTAssertEqual(plan.first?.body, "1 capsule. Tap to tick it off.")

        let today = try DietTrackerDay(containing: now, timeZone: calendar.timeZone)
        snapshot.completions = [DietTrackerCompletion(id: UUID(), trackerID: tracker.id, trackerRevision: tracker.revision,
            name: tracker.name, kind: tracker.kind, dose: tracker.dose, scheduledTime: tracker.times[0], day: today,
            loggedAt: now)]
        XCTAssertEqual(DietTrackerReminderPlan.make(snapshot, now: now, calendar: calendar).count, 2, "Logged today: only tomorrow remains")

        var off = draft
        off.remindMe = false
        let quiet = DietTrackerSnapshot(version: 1, trackers: [try off.validated(id: UUID(), at: now)], completions: [])
        XCTAssertTrue(DietTrackerReminderPlan.make(quiet, now: now, calendar: calendar).isEmpty)
    }
}
