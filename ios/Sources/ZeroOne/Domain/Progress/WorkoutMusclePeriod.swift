import Foundation

enum WorkoutMusclePeriod: String, CaseIterable, Identifiable {
    case day, week

    var id: Self { self }
    var title: String { self == .day ? "Day" : "Week" }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval? {
        var local = calendar
        local.firstWeekday = 2
        local.minimumDaysInFirstWeek = 4
        return local.dateInterval(of: self == .day ? .day : .weekOfYear, for: date)
    }

    /// A half-open local-calendar interval. Changing the view never edits History.
    func entries(from saved: [WorkoutHistoryDisplayItem], containing date: Date,
                 calendar: Calendar) -> [WorkoutHistoryDisplayItem] {
        guard let interval = interval(containing: date, calendar: calendar) else { return [] }
        return saved.filter { $0.completedAt >= interval.start && $0.completedAt < interval.end }
    }
}
