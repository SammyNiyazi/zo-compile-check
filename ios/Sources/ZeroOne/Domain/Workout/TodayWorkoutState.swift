import Foundation

/// Elapsed time in the actual local calendar day, including 23/25-hour DST days.
struct LocalDayProgress: Equatable, Sendable {
    static let preferenceKey = "zeroone.showsDayProgress"
    let elapsedFraction: Double
    var percentage: Int { Int((elapsedFraction * 100).rounded(.down)) }

    init?(at date: Date, calendar: Calendar = .current) {
        guard let day = calendar.dateInterval(of: .day, for: date), day.duration > 0 else { return nil }
        elapsedFraction = min(1, max(0, date.timeIntervalSince(day.start) / day.duration))
    }
}

enum TodayWorkoutState: Equatable {
    case ready
    case completed(WorkoutHistoryDisplayItem)
    case unavailable
}

struct TodayWorkoutStateDeriver {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    @MainActor
    func state(
        for session: WorkoutSession,
        history: WorkoutHistoryRepository,
        activeSession: Bool = false,
        now: Date = .now
    ) -> TodayWorkoutState {
        // An unfinished workout always remains resumable, even when another
        // session was saved earlier on the same day.
        if activeSession && !session.isComplete { return .ready }
        guard history.availability == .available else {
            return .unavailable
        }

        if session.isComplete,
           let saved = history.entries.first(where: { $0.id == session.id }) {
            return .completed(WorkoutHistoryDisplayItem(entry: saved))
        }

        guard let latestTodayEntry = history.entries.first(where: {
            calendar.isDate($0.completedAt, inSameDayAs: now)
        }) else {
            return .ready
        }

        return .completed(WorkoutHistoryDisplayItem(entry: latestTodayEntry))
    }
}
