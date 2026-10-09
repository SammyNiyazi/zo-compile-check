import XCTest
@testable import ZeroOne

final class SmartNoteRulesTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-09-28T12:00:00Z") }
    private func candidate(_ kind: SmartNoteKind = .fits, at: Date? = nil, expires: Date? = nil, rest: Bool = false, fresh: Bool = true) -> SmartNoteCandidate {
        let id = UUID()
        return SmartNoteCandidate(id: id.uuidString, occurrenceID: id, revision: 1, kind: kind,
            title: "A real plan", body: "A chosen time", directTitle: nil, directBody: nil,
            reasons: ["Training time"], unknowns: [], deliveryDate: at ?? now.addingTimeInterval(3600),
            expiresAt: expires ?? now.addingTimeInterval(7200), isRestDay: rest, isCurrent: true, isFreshEvent: fresh)
    }
    private func decide(_ candidates: [SmartNoteCandidate], prefs: SmartNotePreferences? = nil,
                        records: [SmartNoteRecord] = [], authorized: Bool = true, active: Bool = false) -> [SmartNoteDecision] {
        var preferences = prefs ?? SmartNotePreferences()
        if prefs == nil { preferences.enabled = true }
        return SmartNoteRules.decisions(candidates: candidates, preferences: preferences, records: records,
            authorized: authorized, workoutActive: active, now: now, calendar: calendar)
    }

    func testDefaultsNeverOptIn() {
        XCTAssertNil(decide([candidate()], prefs: SmartNotePreferences()).first?.deliveryDate)
    }
    func testCurrentRecoveryHoldDoesNotReserveAProgressNotification() {
        let progress = candidate(.progress)
        let recovery = candidate(.recovery)
        var prefs = SmartNotePreferences()
        prefs.enabled = true
        let result = SmartNoteRules.decisions(candidates: [progress, recovery], preferences: prefs,
            records: [], authorized: true, workoutActive: false, now: now, calendar: calendar,
            progressionAllowed: false)
        XCTAssertEqual(result.filter { $0.deliveryDate != nil }.map(\.candidate.kind), [.recovery])
        XCTAssertNil(result.first { $0.candidate.kind == .progress }?.deliveryDate)
    }
    func testDeniedAndActiveWorkoutSuppress() {
        XCTAssertNil(decide([candidate()], authorized: false).first?.deliveryDate)
        XCTAssertNil(decide([candidate()], active: true).first?.deliveryDate)
    }
    func testRecoveryWinsDailyBudgetRegardlessOfInputOrder() {
        let result = decide([candidate(.fits), candidate(.recovery), candidate(.progress)])
        XCTAssertEqual(result.filter { $0.deliveryDate != nil }.map(\.candidate.kind), [.recovery])
    }
    func testQuietHoursAcrossMidnightDeferToMorning() {
        let note = candidate(at: date("2026-09-28T22:00:00Z"), expires: date("2026-09-29T09:00:00Z"))
        XCTAssertEqual(decide([note]).first?.deliveryDate, date("2026-09-29T07:30:00Z"))
    }
    func testExpiringDuringQuietHoursDropsInsteadOfLateDelivery() {
        let note = candidate(at: date("2026-09-28T22:00:00Z"), expires: date("2026-09-29T07:00:00Z"))
        XCTAssertNil(decide([note]).first?.deliveryDate)
    }
    func testRestDayAllowsOnlyPassiveNotes() {
        XCTAssertNil(decide([candidate(rest: true)]).first?.deliveryDate)
        XCTAssertNotNil(decide([candidate(.missed, rest: true)]).first?.deliveryDate)
    }
    func testNoCatchUpOrImportedEvent() {
        XCTAssertNil(decide([candidate(at: now.addingTimeInterval(-1))]).first?.deliveryDate)
        XCTAssertNil(decide([candidate(fresh: false)]).first?.deliveryDate)
    }
    func testExistingReservationDoesNotCountTwice() {
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.dailyLimit = 2
        let first = candidate(.recovery)
        let record = SmartNoteRecord(requestID: first.requestID, candidateID: first.id, kind: first.kind,
            date: first.deliveryDate, outcome: .scheduled, reason: "Accepted")
        XCTAssertEqual(decide([first, candidate(.fits)], prefs: preferences, records: [record]).filter { $0.deliveryDate != nil }.count, 2)
    }
    func testThreeDismissalsReduceWeeklyCap() {
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.consecutiveDismissals = 3
        let records = (1...2).map { index in
            SmartNoteRecord(requestID: "prior\(index)", candidateID: "prior\(index)", kind: .missed,
                date: now.addingTimeInterval(Double(index * 86400)), outcome: .scheduled, reason: "Reserved later this week")
        }
        XCTAssertNil(decide([candidate()], prefs: preferences, records: records).first?.deliveryDate)
    }
    func testSameQuietEndpointsMeanAllDayQuiet() {
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.quietEndMinute = preferences.quietStartMinute
        XCTAssertNil(decide([candidate()], prefs: preferences).first?.deliveryDate)
    }

    func testQuietHoursAcrossAutumnDSTUseLocalMorning() {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        let before = date("2026-11-01T01:00:00Z")
        let note = candidate(at: date("2026-11-01T02:00:00Z"), expires: date("2026-11-01T15:00:00Z"))
        let result = SmartNoteRules.decisions(candidates: [note], preferences: preferences, records: [],
            authorized: true, workoutActive: false, now: before, calendar: localCalendar)
        XCTAssertEqual(result.first?.deliveryDate, date("2026-11-01T12:30:00Z"))
    }

    func testFutureRequestWithdrawnDuringWorkoutCanBeReconsidered() throws {
        let note = candidate()
        let record = SmartNoteRecord(requestID: note.requestID, candidateID: note.id, kind: note.kind,
            date: note.deliveryDate, outcome: .scheduled, reason: "Accepted")
        XCTAssertNil(decide([note], records: [record], active: true).first?.deliveryDate)
        let withdrawn = SmartNoteRules.recordingWithdrawal(records: [record],
            removedPendingIDs: [note.requestID], at: now)
        XCTAssertEqual(withdrawn.first?.outcome, .held)
        XCTAssertEqual(withdrawn.first?.date, note.deliveryDate)
        XCTAssertTrue(SmartNoteRules.maySubmit(requestID: note.requestID, records: withdrawn, pendingIDs: []))
        XCTAssertEqual(decide([note], records: withdrawn).first?.deliveryDate, note.deliveryDate)
        XCTAssertEqual(SmartNoteRules.recordingWithdrawal(records: withdrawn,
            removedPendingIDs: [note.requestID], at: now), withdrawn)
    }

    func testWithdrawalDoesNotReleasePossiblyDeliveredOrUnobservedReservations() {
        let note = candidate()
        let outcomes: [SmartNoteRecord.Outcome] = [.scheduled, .delivered, .opened, .cleared, .stopped]
        for outcome in outcomes {
            let record = SmartNoteRecord(requestID: note.requestID, candidateID: note.id, kind: note.kind,
                date: now, outcome: outcome, reason: "Existing receipt")
            XCTAssertEqual(SmartNoteRules.recordingWithdrawal(records: [record],
                removedPendingIDs: [note.requestID], at: now), [record])
            XCTAssertFalse(SmartNoteRules.maySubmit(requestID: note.requestID, records: [record], pendingIDs: []))
        }
        let future = SmartNoteRecord(requestID: note.requestID, candidateID: note.id, kind: note.kind,
            date: note.deliveryDate, outcome: .scheduled, reason: "Accepted")
        XCTAssertEqual(SmartNoteRules.recordingWithdrawal(records: [future],
            removedPendingIDs: ["another-request"], at: now), [future])
        XCTAssertTrue(SmartNoteRules.maySubmit(requestID: note.requestID,
            records: [future], pendingIDs: [note.requestID]))
    }

    func testWithdrawnReservationFreesBudgetButNeverCreatesCatchUpDelivery() {
        let first = candidate(.recovery)
        let second = candidate(.fits)
        let record = SmartNoteRecord(requestID: first.requestID, candidateID: first.id, kind: first.kind,
            date: first.deliveryDate, outcome: .scheduled, reason: "Accepted")
        XCTAssertNil(decide([second], records: [record]).first?.deliveryDate)
        let withdrawn = SmartNoteRules.recordingWithdrawal(records: [record],
            removedPendingIDs: [first.requestID], at: now)
        XCTAssertNotNil(decide([second], records: withdrawn).first?.deliveryDate)
        let later = SmartNoteRules.decisions(candidates: [first], preferences: {
            var value = SmartNotePreferences(); value.enabled = true; return value
        }(), records: withdrawn, authorized: true, workoutActive: false,
            now: first.deliveryDate.addingTimeInterval(1), calendar: calendar)
        XCTAssertNil(later.first?.deliveryDate)
    }

    func testRequestedReminderIsNotBlockedByItsOwnOriginalReceipt() {
        var reminder = candidate()
        let original = SmartNoteRecord(requestID: reminder.requestID, candidateID: reminder.id,
            kind: reminder.kind, date: now.addingTimeInterval(-60), outcome: .delivered, reason: "Delivered")
        reminder.wasSnoozed = true
        reminder.snoozedUntil = now.addingTimeInterval(1800)
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.weeklyLimit = 1
        preferences.fewerKinds = [.fits]
        XCTAssertEqual(decide([reminder], prefs: preferences, records: [original]).first?.deliveryDate,
            reminder.snoozedUntil)
        XCTAssertEqual(reminder.requestID, original.requestID + ".snooze")
        XCTAssertFalse(SmartNoteRules.maySubmit(requestID: reminder.requestID, records: [
            .init(requestID: reminder.requestID, candidateID: reminder.id, kind: reminder.kind,
                date: now, outcome: .delivered, reason: "Already reminded")
        ], pendingIDs: []))
    }

    func testReminderExceptionDoesNotFreeCapacityForOtherNotes() {
        var reminder = candidate(.recovery)
        let original = SmartNoteRecord(requestID: reminder.requestID, candidateID: reminder.id,
            kind: reminder.kind, date: now.addingTimeInterval(-60), outcome: .delivered, reason: "Delivered")
        reminder.wasSnoozed = true
        reminder.snoozedUntil = now.addingTimeInterval(1800)
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.dailyLimit = 2
        let other = candidate(.fits)
        let result = decide([other, reminder], prefs: preferences, records: [original])
        XCTAssertEqual(result.first(where: { $0.candidate.id == reminder.id })?.deliveryDate, reminder.snoozedUntil)
        XCTAssertNil(result.first(where: { $0.candidate.id == other.id })?.deliveryDate)
        let otherReceipt = SmartNoteRecord(requestID: other.requestID, candidateID: other.id,
            kind: other.kind, date: now, outcome: .delivered, reason: "Another event")
        XCTAssertNil(decide([reminder], records: [original, otherReceipt]).first?.deliveryDate)
    }

    func testReminderStillRespectsPermissionWorkoutQuietHoursAndExpiry() {
        var reminder = candidate(at: date("2026-09-28T20:00:00Z"), expires: date("2026-09-29T07:00:00Z"))
        reminder.wasSnoozed = true
        reminder.snoozedUntil = date("2026-09-28T22:00:00Z")
        XCTAssertNil(decide([reminder]).first?.deliveryDate)
        reminder.snoozedUntil = now.addingTimeInterval(1800)
        XCTAssertNil(decide([reminder], authorized: false).first?.deliveryDate)
        XCTAssertNil(decide([reminder], active: true).first?.deliveryDate)
        reminder.snoozedUntil = now.addingTimeInterval(-1)
        XCTAssertNil(decide([reminder]).first?.deliveryDate)
    }

    func testReminderDoesNotExemptAnotherRevisionOfTheSameOccurrence() {
        var reminder = candidate()
        reminder.wasSnoozed = true
        reminder.snoozedUntil = now.addingTimeInterval(1800)
        let older = SmartNoteRecord(requestID: "01.note.\(reminder.occurrenceID.uuidString).fits.r0",
            candidateID: reminder.id, kind: reminder.kind, date: now, outcome: .delivered, reason: "Older revision")
        XCTAssertNil(decide([reminder], records: [older]).first?.deliveryDate)
    }
}
