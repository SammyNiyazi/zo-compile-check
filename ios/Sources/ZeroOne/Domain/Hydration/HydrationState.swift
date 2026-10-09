import Foundation

struct HydrationDailyRecord: Identifiable, Equatable, Sendable {
    let date: Date
    let consumedMilliliters: Int

    var id: Date { date }

    init(date: Date, consumedMilliliters: Int) {
        precondition(consumedMilliliters >= 0, "Hydration intake cannot be negative.")
        self.date = date
        self.consumedMilliliters = consumedMilliliters
    }
}

struct HydrationState: Equatable, Sendable {
    private(set) var currentMilliliters: Int
    let goalMilliliters: Int
    let recentHistory: [HydrationDailyRecord]

    init(
        currentMilliliters: Int = 0,
        goalMilliliters: Int = 2_500,
        recentHistory: [HydrationDailyRecord] = []
    ) {
        precondition(currentMilliliters >= 0, "Hydration intake cannot be negative.")
        precondition(goalMilliliters > 0, "Hydration goal must be greater than zero.")
        self.currentMilliliters = currentMilliliters
        self.goalMilliliters = goalMilliliters
        self.recentHistory = recentHistory.sorted { $0.date < $1.date }
    }

    var progress: Double {
        min(1, Double(currentMilliliters) / Double(goalMilliliters))
    }

    var remainingMilliliters: Int {
        max(0, goalMilliliters - currentMilliliters)
    }

    mutating func add(_ milliliters: Int) {
        guard milliliters > 0, currentMilliliters <= Int.max - milliliters else { return }
        currentMilliliters += milliliters
    }

    mutating func set(_ milliliters: Int) {
        guard milliliters >= 0 else { return }
        currentMilliliters = milliliters
    }

    func recentIntake(endingOn date: Date = .now, calendar: Calendar = .current) -> [HydrationDailyRecord] {
        let earlierDays = recentHistory.filter { !calendar.isDate($0.date, inSameDayAs: date) }
        return Array(earlierDays.suffix(6)) + [
            HydrationDailyRecord(date: date, consumedMilliliters: currentMilliliters)
        ]
    }

    static func previewHistory(endingOn date: Date = .now, calendar: Calendar = .current) -> [HydrationDailyRecord] {
        let intakes = [2_250, 1_900, 2_600, 2_100, 2_350, 2_050]

        return intakes.enumerated().compactMap { index, intake in
            guard let day = calendar.date(byAdding: .day, value: index - intakes.count, to: date) else {
                return nil
            }
            return HydrationDailyRecord(date: day, consumedMilliliters: intake)
        }
    }
}
