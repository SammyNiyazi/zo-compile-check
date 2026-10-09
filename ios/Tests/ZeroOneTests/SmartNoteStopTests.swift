import Foundation
import XCTest
@testable import ZeroOne

final class SmartNoteStopTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    func testExpiredNoteCanStopItsKindWithoutChangingPlanOrOtherPreferences() throws {
        let note = candidate()
        var original = SmartNoteSnapshot()
        original.preferences.enabled = true
        original.preferences.consecutiveDismissals = 2
        original.candidates = [note]
        let change = try XCTUnwrap(original.stopping(requestID: note.requestID, at: now))

        XCTAssertEqual(change.kind, .fits)
        var expected = original.preferences
        expected.enabledKinds.remove(.fits)
        XCTAssertEqual(change.snapshot.preferences, expected)
        XCTAssertEqual(change.snapshot.candidates, original.candidates)
        XCTAssertEqual(change.snapshot.records.first?.outcome, .stopped)
        XCTAssertTrue(original.preferences.enabledKinds.contains(.fits), "Preparing a change must not publish it")
        XCTAssertNil(change.snapshot.stopping(requestID: note.requestID, at: now))
    }

    func testOldRevisionReceiptCanStopKindAfterCandidateWasRemoved() throws {
        let note = candidate()
        let receipt = SmartNoteRecord(requestID: note.requestID, candidateID: note.id,
            kind: note.kind, date: now.addingTimeInterval(-3_600), outcome: .delivered, reason: "Delivered")
        var original = SmartNoteSnapshot()
        original.records = [receipt]
        let change = try XCTUnwrap(original.stopping(requestID: note.requestID, at: now))
        XCTAssertTrue(change.snapshot.candidates.isEmpty)
        XCTAssertEqual(change.snapshot.records[0].date, receipt.date)
        XCTAssertEqual(change.snapshot.records[0].requestID, receipt.requestID)
        XCTAssertEqual(change.snapshot.records[0].outcome, .stopped)
        XCTAssertFalse(change.snapshot.preferences.enabledKinds.contains(.fits))

        let restored = try JSONDecoder().decode(SmartNoteSnapshot.self,
            from: JSONEncoder().encode(change.snapshot))
        XCTAssertEqual(restored.preferences, change.snapshot.preferences)
        XCTAssertEqual(restored.records, change.snapshot.records)
        XCTAssertNil(restored.stopping(requestID: note.requestID, at: now))
    }

    func testUnknownOrConflictingLocalIdentityCannotDisableGuessedKind() {
        let note = candidate()
        var snapshot = SmartNoteSnapshot()
        XCTAssertNil(snapshot.stopping(requestID: note.requestID, at: now))
        snapshot.candidates = [note]
        snapshot.records = [.init(requestID: note.requestID, candidateID: note.id,
            kind: .recovery, date: now, outcome: .delivered, reason: "Conflicting data")]
        XCTAssertNil(snapshot.stopping(requestID: note.requestID, at: now))
        XCTAssertEqual(snapshot.preferences.enabledKinds, Set(SmartNoteKind.allCases))
        XCTAssertTrue(snapshot.handledActions.isEmpty)
    }

    func testStoppingDeliveredKindDoesNotFreeBudgetForAnotherNoteThatDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let fresh = SmartNoteCandidate(id: "new", occurrenceID: UUID(), revision: 1, kind: .progress,
            title: "New progress", body: "Recorded result", directTitle: nil, directBody: nil,
            reasons: [], unknowns: [], deliveryDate: midday.addingTimeInterval(3_600),
            expiresAt: midday.addingTimeInterval(7_200), isRestDay: false, isCurrent: true, isFreshEvent: true)
        var preferences = SmartNotePreferences()
        preferences.enabled = true
        preferences.enabledKinds.remove(.fits)
        let stopped = SmartNoteRecord(requestID: "old", candidateID: "old", kind: .fits,
            date: midday.addingTimeInterval(-3_600), outcome: .stopped, reason: "Turned off by you")
        let result = SmartNoteRules.decisions(candidates: [fresh], preferences: preferences,
            records: [stopped], authorized: true, workoutActive: false, now: midday, calendar: calendar)
        XCTAssertNil(result.first?.deliveryDate)
    }

    private func candidate() -> SmartNoteCandidate {
        SmartNoteCandidate(id: "old-plan", occurrenceID: UUID(), revision: 1, kind: .fits,
            title: "Old plan", body: "Old training time", directTitle: nil, directBody: nil,
            reasons: [], unknowns: [], deliveryDate: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(-60), isRestDay: false, isCurrent: false, isFreshEvent: true)
    }
}
