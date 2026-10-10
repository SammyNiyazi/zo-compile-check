import Foundation

/// Proof 56 / tokens.notifications "Training day": on a confirmed training day,
/// at the time the person chose, "Upper body A is ready when you are. About 40 min."
/// Local notifications only (Sammy, 9 Oct). Built from the saved schedule and the
/// programme's next session; the host merges these with its other candidates.
enum TrainingDayReminders {
    static let idPrefix = "training-day."

    /// Today and tomorrow only (SmartNoteRules never schedules past 48 h; the
    /// host rebuilds on every foreground). A day already trained stays quiet.
    static func candidates(
        trainingWeekdays: [Int]?,
        programmeID: String?,
        sessionTitle: String?,
        estimatedMinutes: Int?,
        reminderMinute: Int?,
        lastCompletedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> [SmartNoteCandidate] {
        guard let weekdays = trainingWeekdays, !weekdays.isEmpty,
              let reminderMinute, (0 ..< 24 * 60).contains(reminderMinute),
              let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0 ... 1).compactMap { offset -> SmartNoteCandidate? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  !(lastCompletedAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false),
                  let delivery = calendar.date(bySettingHour: reminderMinute / 60, minute: reminderMinute % 60,
                                               second: 0, of: day),
                  let expiresAt = calendar.date(byAdding: .day, value: 1, to: day),
                  delivery > now, delivery < expiresAt,
                  let occurrence = occurrenceID(for: day, calendar: calendar) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let body = estimatedMinutes.map { "\(title) is ready when you are. About \($0) min." }
                ?? "\(title) is ready when you are."
            return SmartNoteCandidate(
                id: idPrefix + String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                occurrenceID: occurrence, revision: 1, kind: .fits,
                title: "Training day", body: body,
                directTitle: nil, directBody: nil,
                reasons: ["This is one of your training days, and you chose this reminder time."],
                unknowns: ["Whether you're free. Calendar isn't connected to these notes."],
                deliveryDate: delivery, expiresAt: expiresAt,
                isRestDay: false, isCurrent: true, isFreshEvent: true,
                programmeID: programmeID, sessionID: nil
            )
        }
    }

    /// Stable per calendar day, so a rebuild never schedules the same day twice.
    static func occurrenceID(for day: Date, calendar: Calendar) -> UUID? {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let date = parts.day,
              (1 ... 9999).contains(year) else { return nil }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%04d%02d%02d0000", year, month, date))
    }

    /// Replaces only this generator's candidates; progress notes and one-off
    /// reminders the person added stay as they are.
    static func merged(_ existing: [SmartNoteCandidate], with fresh: [SmartNoteCandidate]) -> [SmartNoteCandidate] {
        existing.filter { !$0.id.hasPrefix(idPrefix) } + fresh
    }
}
