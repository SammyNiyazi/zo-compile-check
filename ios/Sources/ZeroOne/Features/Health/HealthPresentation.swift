import Foundation

/// Observed Health facts only. No permission result or missing sample becomes a zero.
struct StepsDayPresentation {
    let reading: StepsDayReading?
    let hours: [StepsHour]
    let goal: Int?
    let dayInterval: DateInterval?
    let isStale: Bool

    init(reading: StepsDayReading?, now: Date, calendar: Calendar, dailyGoal: Int?, isStale: Bool) {
        goal = dailyGoal.flatMap { $0 > 0 ? $0 : nil }
        let dayStart = calendar.startOfDay(for: now)
        guard let reading, reading.dayStart == dayStart, reading.readAt <= now,
              calendar.isDate(reading.readAt, inSameDayAs: now),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), dayEnd > dayStart else {
            self.reading = nil
            hours = []
            dayInterval = nil
            self.isStale = false
            return
        }
        self.reading = reading
        self.isStale = isStale
        dayInterval = DateInterval(start: dayStart, end: dayEnd)
        hours = reading.hours.filter {
            $0.startedAt >= dayStart && $0.startedAt < dayEnd && $0.startedAt <= now && $0.count != nil
        }
    }

    var goalReached: Bool {
        guard let count = reading?.totalSteps, let goal else { return false }
        // A retained reading after a failed refresh does not earn a new goal moment.
        return !isStale && count >= goal
    }
    var progress: Double? {
        guard let count = reading?.totalSteps, let goal else { return nil }
        return min(1, max(0, Double(count) / Double(goal)))
    }
}

struct HealthSleepPresentation {
    let duration: TimeInterval?
    let isCurrent: Bool
    var periodKey: String { isCurrent ? "Last night" : "Last available sleep" }

    init(context: HealthContext?, status: HealthConnectionStatus, isStale: Bool, now: Date, calendar: Calendar) {
        duration = context?.lastNightSleepDurationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        isCurrent = context.map {
            status == .connected && !isStale && $0.refreshedAt <= now
                && $0.dayStart == calendar.startOfDay(for: now)
                && calendar.isDate($0.refreshedAt, inSameDayAs: now)
        } ?? false
    }
}
