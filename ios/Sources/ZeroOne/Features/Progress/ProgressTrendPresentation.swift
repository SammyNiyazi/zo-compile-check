import Foundation

/// Display windows and observed facts only. This never sets a target or changes a workout.
enum ProgressChartWindow: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self { case .week: .weekOfYear; case .month: .month; case .year: .year }
    }
    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.dateInterval(of: component, for: now)?.start ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return DateInterval(start: start, end: end)
    }
}

struct ProgressWeightDay: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let reading: Decimal?
    let average: Decimal?
    let sampleCount: Int
    /// A new series after every missing day prevents Charts connecting across a gap.
    let series: Date
}

struct ProgressWeightChart {
    let days: [ProgressWeightDay]
    let interval: DateInterval
    let recentAverage: Decimal?
    let recentSampleCount: Int

    init(entries: [BodyWeightEntry], interval: DateInterval, now: Date, calendar: Calendar) {
        self.interval = interval
        let valid = entries.filter {
            let value = NSDecimalNumber(decimal: $0.kilograms).doubleValue
            return $0.recordedAt <= now && value.isFinite && value > 0
        }.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var daily: [Date: Decimal] = [:]
        for entry in valid {
            let day = calendar.startOfDay(for: entry.recordedAt)
            if daily[day] == nil { daily[day] = entry.kilograms }
        }
        func samples(ending day: Date) -> [Decimal] {
            guard let start = calendar.date(byAdding: .day, value: -6, to: day) else { return [] }
            return daily.filter { $0.key >= start && $0.key <= day }.map(\.value)
        }
        let recent = samples(ending: calendar.startOfDay(for: now))
        recentSampleCount = recent.count
        recentAverage = Self.average(recent)
        var points: [ProgressWeightDay] = []
        var day = calendar.startOfDay(for: interval.start)
        var series = day
        var previousWasMissing = true
        while day < interval.end {
            let reading = daily[day]
            if previousWasMissing && reading != nil { series = day }
            let observed = reading == nil ? [] : samples(ending: day)
            let average = Self.average(observed)
            points.append(ProgressWeightDay(day: day, reading: reading, average: average,
                                           sampleCount: observed.count, series: series))
            previousWasMissing = reading == nil
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        days = points
    }

    private static func average(_ samples: [Decimal]) -> Decimal? {
        guard !samples.isEmpty else { return nil }
        // Divide before adding, so finite individual values do not overflow their sum.
        let divisor = Decimal(samples.count)
        let value = samples.reduce(Decimal(0)) { $0 + $1 / divisor }
        guard !value.isNaN, NSDecimalNumber(decimal: value).doubleValue.isFinite else { return nil }
        return value
    }

    func domain(unit: BodyWeightUnit) -> ClosedRange<Double>? {
        let values = days.flatMap { [$0.reading, $0.average].compactMap { $0 }.map { unit.displayedValue(for: $0) } }
            .filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return nil }
        let span = max(unit == .kilograms ? 4.0 : 9.0, high - low + 1)
        let lower = max(0, (low + high) / 2 - span / 2)
        let upper = lower + span
        guard span.isFinite, lower.isFinite, upper.isFinite, upper >= lower else { return nil }
        return lower ... upper
    }
}

struct ProgressWorkoutWeek: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let end: Date
    /// nil means the history could not be read; zero means no saved session in this interval.
    let count: Int?
}

enum ProgressWorkoutChart {
    static func weeks(completedDates: [Date]?, interval: DateInterval, now: Date,
                      calendar: Calendar) -> [ProgressWorkoutWeek] {
        var result: [ProgressWorkoutWeek] = []
        var start = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
        while start < interval.end {
            guard let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start), end > start else { break }
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            let count = completedDates.map { dates in
                dates.filter { $0 >= lower && $0 < upper && $0 <= now }.count
            }
            result.append(ProgressWorkoutWeek(start: start, end: end, count: count))
            start = end
        }
        return result
    }
}
