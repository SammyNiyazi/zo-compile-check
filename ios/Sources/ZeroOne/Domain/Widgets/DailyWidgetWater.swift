import Foundation

struct DailyWidgetWaterState: Equatable {
    let transaction: HydrationTransactionState
    let dayStart: Date
    let undo: HydrationAddition?

    init?(transaction: HydrationTransactionState?, at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        guard let transaction, transaction.isValid, transaction.state.date <= date else { return nil }
        self.transaction = transaction
        dayStart = calendar.startOfDay(for: date)
        if transaction.isCurrent(at: date, calendar: calendar), let addition = transaction.lastAddition,
           date.timeIntervalSince(addition.date) < 900 {
            undo = addition
        } else { undo = nil }
    }

    func displaySnapshot(base: DailyWidgetSnapshot?, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> DailyWidgetSnapshot {
        let accent = base?.accent ?? .yellow
        let base = base.flatMap { $0.isCurrent(on: date, calendar: calendar) ? $0 : nil }
        let current = transaction.isCurrent(at: date, calendar: calendar)
        return DailyWidgetSnapshot(generatedAt: date, dayStart: calendar.startOfDay(for: date),
            steps: base?.steps ?? .missing(.needsRefresh), eatenKilocalories: base?.eatenKilocalories ?? .missing(.needsRefresh),
            burnedKilocalories: base?.burnedKilocalories ?? .missing(.needsRefresh),
            waterMilliliters: .reading(current ? Double(transaction.state.currentMilliliters) : 0,
                                       at: current ? transaction.state.date : date),
            waterGoalMilliliters: transaction.state.goalMilliliters, latestWalk: base?.latestWalk,
            stepGoal: base?.stepGoal, foodGoalKilocalories: base?.foodGoalKilocalories, accent: accent)
    }

    static func unavailableSnapshot(base: DailyWidgetSnapshot?, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> DailyWidgetSnapshot {
        let current = base.flatMap { $0.isCurrent(on: date, calendar: calendar) ? $0 : nil }
        return DailyWidgetSnapshot(generatedAt: date, dayStart: calendar.startOfDay(for: date),
            steps: current?.steps ?? .missing(.needsRefresh), eatenKilocalories: current?.eatenKilocalories ?? .missing(.needsRefresh),
            burnedKilocalories: current?.burnedKilocalories ?? .missing(.needsRefresh),
            waterMilliliters: .missing(.unavailable), waterGoalMilliliters: nil, latestWalk: current?.latestWalk,
            stepGoal: current?.stepGoal, foodGoalKilocalories: current?.foodGoalKilocalories, accent: base?.accent ?? .yellow)
    }
}

/// Short-lived interaction feedback, never a source of water totals or success.
struct WidgetWaterFeedback: Codable {
    let date: Date
    let message: String

    static func read(bundle: Bundle = .main, at date: Date = .now) -> String? {
        guard let url = url(bundle: bundle), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.date <= date, date.timeIntervalSince(value.date) < 90, !value.message.isEmpty else { return nil }
        return value.message
    }

    static func write(_ message: String, bundle: Bundle = .main) {
        guard let url = url(bundle: bundle) else { return }
        // Best effort only. A feedback-write failure cannot turn a failed add into success.
        try? JSONEncoder().encode(Self(date: .now, message: message))
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func url(bundle: Bundle) -> URL? {
        guard let id = bundle.object(forInfoDictionaryKey: "01AppGroupIdentifier") as? String, !id.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return container.appendingPathComponent("last-water-widget-action.json")
    }
}
