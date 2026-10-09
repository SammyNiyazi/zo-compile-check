import Foundation

enum SmartNoteKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case recovery, shorter, fits, missed, progress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fits: "Fits your day"
        case .shorter: "A shorter session"
        case .recovery: "A lighter option"
        case .missed: "Plans move"
        case .progress: "Progress that changes the next set"
        }
    }
    var detail: String {
        switch self {
        case .fits: "A planned workout inside a training time you chose."
        case .shorter: "A shorter version, when your saved plan has one."
        case .recovery: "An option based on what you logged. Never a recovery diagnosis."
        case .missed: "One neutral follow-up the next morning. No guilt."
        case .progress: "New, recorded progress with a real next-load choice."
        }
    }
    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var isPassive: Bool { self == .missed || self == .progress }
}

struct SmartNotePreferences: Codable, Equatable, Sendable {
    var enabled = false
    var enabledKinds = Set(SmartNoteKind.allCases)
    var fewerKinds: Set<SmartNoteKind> = []
    var dailyLimit = 1
    var weeklyLimit = 4
    var quietHoursEnabled = true
    var quietStartMinute = 21 * 60 + 30
    var quietEndMinute = 7 * 60 + 30
    var protectRestDays = true
    var directVoice = false
    var showDetails = false
    var consecutiveDismissals = 0
    /// Minutes after midnight for the training-day reminder; nil means none.
    /// Optional so notes saved before 9 Oct still decode.
    var trainingReminderMinute: Int? = nil
}

/// Created only from an acknowledged, current plan/history snapshot by the host.
/// Fixed dates preserve the intended instant when the user travels. No guessed health data.
struct SmartNoteCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let occurrenceID: UUID
    let revision: Int
    let kind: SmartNoteKind
    let title: String
    let body: String
    let directTitle: String?
    let directBody: String?
    let reasons: [String]
    let unknowns: [String]
    let deliveryDate: Date
    let expiresAt: Date
    let isRestDay: Bool
    let isCurrent: Bool
    let isFreshEvent: Bool
    var snoozedUntil: Date? = nil
    var wasSnoozed = false
    var programmeID: String? = nil
    var sessionID: String? = nil
    // Local evidence only. Never copied into the notification userInfo payload.
    var progressEvidence: SmartNoteProgressEvidence? = nil

    var originalRequestID: String { "01.note.\(occurrenceID.uuidString).\(kind.rawValue).r\(revision)" }
    var requestID: String { originalRequestID + (wasSnoozed ? ".snooze" : "") }
}

struct SmartNoteRecord: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case scheduled, held, delivered, opened, cleared, stopped, failed
    }
    var id: String { requestID }
    let requestID: String
    let candidateID: String
    let kind: SmartNoteKind
    var date: Date
    var outcome: Outcome
    var reason: String
}

struct SmartNoteDecision: Equatable, Sendable {
    let candidate: SmartNoteCandidate
    let deliveryDate: Date?
    let reason: String
}

struct SmartNoteRules {
    /// Only requests observed pending and explicitly removed by this app can
    /// release a future reservation. An already-due/missing request may have
    /// delivered outside the app and must retain its no-repeat receipt.
    static func recordingWithdrawal(
        records: [SmartNoteRecord], removedPendingIDs: Set<String>, at date: Date
    ) -> [SmartNoteRecord] {
        records.map { record in
            guard removedPendingIDs.contains(record.requestID), record.outcome == .scheduled,
                  record.date > date else { return record }
            var held = record
            held.outcome = .held
            held.reason = "Removed before its scheduled time. Reconsidered only while still useful."
            return held
        }
    }

    static func maySubmit(
        requestID: String, records: [SmartNoteRecord], pendingIDs: Set<String>
    ) -> Bool {
        guard let prior = records.first(where: { $0.requestID == requestID }) else { return true }
        let accepted: Set<SmartNoteRecord.Outcome> = [.scheduled, .delivered, .opened, .cleared, .stopped]
        return pendingIDs.contains(requestID) || !accepted.contains(prior.outcome)
    }

    /// Conservative delivery ledger: accepted requests count toward caps even if iOS
    /// later suppresses them. Scheduling is never reported as proof of delivery.
    static func decisions(
        candidates: [SmartNoteCandidate], preferences: SmartNotePreferences,
        records: [SmartNoteRecord], authorized: Bool, workoutActive: Bool,
        now: Date, calendar: Calendar = .current, progressionAllowed: Bool = true
    ) -> [SmartNoteDecision] {
        var reserved = records.filter { [.scheduled, .delivered, .opened, .cleared, .stopped].contains($0.outcome) }
        let weekLimit = preferences.consecutiveDismissals >= 3 ? min(2, preferences.weeklyLimit) : preferences.weeklyLimit
        return candidates.sorted {
            if calendar.isDate($0.deliveryDate, inSameDayAs: $1.deliveryDate), $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            return $0.deliveryDate == $1.deliveryDate ? $0.id < $1.id : $0.deliveryDate < $1.deliveryDate
        }.map { note in
            func hold(_ reason: String) -> SmartNoteDecision { .init(candidate: note, deliveryDate: nil, reason: reason) }
            guard !workoutActive else { return hold("Held while a workout is active.") }
            guard progressionAllowed || note.kind != .progress else {
                return hold("Held while a current recovery or fuelling concern needs review.")
            }
            guard preferences.enabled, preferences.enabledKinds.contains(note.kind) else { return hold("These notes are off. Your choices are kept.") }
            guard authorized else { return hold("Not scheduled. Notifications are not authorized on this iPhone.") }
            guard note.isCurrent, note.expiresAt > now else { return hold("The plan changed or this note is no longer useful.") }
            guard note.isFreshEvent else { return hold("No catch-up notes for older or imported events.") }
            guard !(preferences.protectRestDays && note.isRestDay && !note.kind.isPassive) else { return hold("Your rest day stays quiet.") }
            if reserved.contains(where: { $0.candidateID == note.id && $0.requestID != note.requestID }) && !note.wasSnoozed {
                return hold("Already considered for delivery. No repeat for this event.")
            }
            var date = note.snoozedUntil ?? note.deliveryDate
            guard date > now else { return hold("The original time passed. No catch-up notification.") }
            if preferences.quietHoursEnabled, isQuiet(date, preferences: preferences, calendar: calendar) {
                // Calendar matching handles midnight and DST. Equal endpoints mean all-day quiet.
                guard preferences.quietStartMinute != preferences.quietEndMinute,
                      let end = calendar.nextDate(after: date, matching: DateComponents(
                        hour: preferences.quietEndMinute / 60, minute: preferences.quietEndMinute % 60
                      ), matchingPolicy: .nextTime, repeatedTimePolicy: .first) else {
                    return hold("Quiet hours cover the whole day.")
                }
                date = end
            }
            guard date < note.expiresAt else { return hold("The note would expire during quiet hours.") }
            guard date.timeIntervalSince(now) <= 48 * 3600 else { return hold("Outside the next two days. Rechecked when 01 opens.") }
            // One explicit reminder may follow its own original note even at the
            // default one-note limit. Do not exempt other events or revisions.
            // Both receipts still count when considering any unrelated note.
            let others = reserved.filter {
                $0.requestID != note.requestID &&
                    !(note.wasSnoozed && $0.requestID == note.originalRequestID)
            }
            let dayCount = others.filter { calendar.isDate($0.date, inSameDayAs: date) }.count
            let week = calendar.dateInterval(of: .weekOfYear, for: date)
            let weekRecords = others.filter { week?.contains($0.date) == true }
            guard dayCount < min(2, max(1, preferences.dailyLimit)), weekRecords.count < max(1, weekLimit) else {
                return hold("Your daily or weekly note limit is reached.")
            }
            guard !preferences.fewerKinds.contains(note.kind) || !weekRecords.contains(where: { $0.kind == note.kind }) else {
                return hold("Fewer like this: at most one this week.")
            }
            reserved.removeAll { $0.requestID == note.requestID }
            reserved.append(.init(requestID: note.requestID, candidateID: note.id, kind: note.kind, date: date, outcome: .scheduled, reason: "Reserved"))
            return .init(candidate: note, deliveryDate: date, reason: date == (note.snoozedUntil ?? note.deliveryDate) ? "Inside your chosen limits." : "Moved until after quiet hours.")
        }
    }

    static func isQuiet(_ date: Date, preferences: SmartNotePreferences, calendar: Calendar) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let start = preferences.quietStartMinute, end = preferences.quietEndMinute
        return start == end || (start < end ? minute >= start && minute < end : minute >= start || minute < end)
    }
}
