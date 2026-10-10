import Foundation

enum DailyWidgetSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum DailyWidgetCalories: String, CaseIterable, Identifiable, Codable {
    case both, eaten, burned
    var id: Self { self }
    var title: String {
        switch self { case .both: "Eaten and burned"; case .eaten: "Eaten only"; case .burned: "Burned only" }
    }
}

enum DailyWidgetMetric: String, CaseIterable, Identifiable, Codable {
    case steps, calories, water
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

extension DailyWidgetSnapshot.Kind: Identifiable {
    var id: Self { self }
    var title: String {
        switch self { case .steps: "Steps"; case .calories: "Calories"; case .water: "Water"; case .together: "Together" }
    }
    var symbol: String {
        switch self { case .steps: "shoeprints.fill"; case .calories: "flame"; case .water: "drop"; case .together: "square.grid.2x2" }
    }
    var sizes: [DailyWidgetSize] { self == .together ? [.medium, .large] : [.small, .medium] }
    func validSize(_ proposed: DailyWidgetSize) -> DailyWidgetSize { sizes.contains(proposed) ? proposed : sizes[0] }
}

struct DailyWidgetOptions: Equatable, Codable {
    var calories: DailyWidgetCalories = .both
    var waterAmount = 250
    var showsWalk = true
    private(set) var included: Set<DailyWidgetMetric> = Set(DailyWidgetMetric.allCases)

    var validatedWaterAmount: Int { [250, 500, 750].contains(waterAmount) ? waterAmount : 250 }
    var secondaryWaterAmount: Int { validatedWaterAmount == 500 ? 750 : 500 }
    var orderedMetrics: [DailyWidgetMetric] {
        let selection = included.isEmpty ? Set([DailyWidgetMetric.steps]) : included
        return DailyWidgetMetric.allCases.filter { selection.contains($0) }
    }

    mutating func set(_ metric: DailyWidgetMetric, included shouldInclude: Bool) {
        if shouldInclude { included.insert(metric) }
        else if included.count > 1 { included.remove(metric) }
    }
}

enum DailyWidgetFormatting {
    static func value(_ metric: DailyWidgetSnapshot.Metric?, liters: Bool = false) -> String {
        guard let metric, metric.state == .available, let value = metric.value,
              value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        return liters ? (value / 1_000).formatted(.number.precision(.fractionLength(0 ... 2)))
            : value.formatted(.number.precision(.fractionLength(0)))
    }

    static func stateText(_ metric: DailyWidgetSnapshot.Metric?) -> String? {
        guard let metric else { return "Open 01 to update" }
        switch metric.state {
        case .available: return metric.isStale ? "Refresh needed" : nil
        case .noData: return "No readable data"
        case .needsConnection: return "Connect in 01"
        case .needsRefresh: return "Open 01 to update"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Deep links open a destination only. They never begin tracking or save user data.
enum DailyWidgetRoute: String, CaseIterable {
    case steps, calories, water, today, walk
    var url: URL { URL(string: "the01://widget/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "the01", url.host?.lowercased() == "widget",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let path = url.path
        guard path.hasPrefix("/"), let value = Self(rawValue: String(path.dropFirst())) else { return nil }
        self = value
    }
}
