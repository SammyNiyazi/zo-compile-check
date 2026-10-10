import Foundation

/// Proof 41's scheduling facts, from the appointment's own instant and time
/// zone and the session it opens. Nothing here writes, reschedules or
/// counts a planned time as a workout.
enum WorkoutSchedulePresentation {
    /// Proof `.zo-when .cal`: the weekday on ink, the day of the month below.
    struct DateTile: Equatable {
        let weekday: String
        let day: Int
    }

    enum RelativeDay: Equatable {
        case today, tomorrow, other
    }

    static func dateTile(for instant: Date, zone: TimeZone, locale: Locale) -> DateTile {
        let calendar = calendar(zone: zone, locale: locale)
        let weekday = calendar.component(.weekday, from: instant)
        return DateTile(weekday: calendar.shortStandaloneWeekdaySymbols[weekday - 1],
                        day: calendar.component(.day, from: instant))
    }

    static func relativeDay(of instant: Date, now: Date, zone: TimeZone) -> RelativeDay {
        let calendar = calendar(zone: zone)
        if calendar.isDate(instant, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(instant, inSameDayAs: tomorrow) { return .tomorrow }
        return .other
    }

    /// The editor's day chips: today and the following days, in the
    /// appointment's zone, as the start of each day.
    static func dayChoices(now: Date, zone: TimeZone, count: Int = 7) -> [Date] {
        let calendar = calendar(zone: zone)
        let today = calendar.startOfDay(for: now)
        return (0 ..< max(0, count)).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// The same wall-clock time on another day in `zone`, resolved through
    /// `AppointmentWallTime` so a repeated hour takes its first instant and
    /// a skipped one returns nil rather than a guessed time.
    static func moving(_ instant: Date, toDay day: Date, zone: TimeZone) -> Date? {
        let calendar = calendar(zone: zone)
        let time = calendar.dateComponents([.hour, .minute], from: instant)
        let date = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = date.year, let month = date.month, let dayOfMonth = date.day,
              let hour = time.hour, let minute = time.minute else { return nil }
        return AppointmentWallTime.instants(year: year, month: month, day: dayOfMonth,
                                            hour: hour, minute: minute, timeZone: zone).first
    }

    /// Proof 41's start screen: the session's own counts and the first four
    /// exercise pictures. Minutes come only from the session's authored
    /// target; without one, none are claimed.
    struct StartSummary: Equatable {
        static let stackLimit = 4

        let exerciseCount: Int
        let setCount: Int
        let minutes: Int?
        let stackExerciseIDs: [ExerciseID]
        let overflowCount: Int

        init(session: WorkoutSession) {
            exerciseCount = session.exercises.count
            setCount = session.totalPlannedSetCount
            minutes = session.targetDurationMinutes.flatMap { $0 > 0 ? $0 : nil }
            stackExerciseIDs = session.exercises.prefix(Self.stackLimit).map(\.plan.exerciseID)
            overflowCount = max(0, session.exercises.count - Self.stackLimit)
        }
    }

    private static func calendar(zone: TimeZone, locale: Locale? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if let locale { calendar.locale = locale }
        return calendar
    }
}
