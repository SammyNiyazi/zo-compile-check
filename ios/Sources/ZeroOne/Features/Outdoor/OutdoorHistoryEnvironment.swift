import SwiftUI

/// The root's one outdoor repository, so History (proof 40) can show walks and runs
/// beside workouts without a second writer for the same files.
private struct OutdoorHistoryRepositoryKey: EnvironmentKey {
    static let defaultValue: OutdoorActivityRepository? = nil
}

extension EnvironmentValues {
    var zeroOneOutdoorRepository: OutdoorActivityRepository? {
        get { self[OutdoorHistoryRepositoryKey.self] }
        set { self[OutdoorHistoryRepositoryKey.self] = newValue }
    }
}

/// Proof 40 "Walks and runs": this month's distance, walks and runs.
struct OutdoorMonthSummary: Equatable {
    let month: Date
    let meters: Double
    let walks: Int
    let runs: Int

    static func make(_ records: [OutdoorActivityRecord], now: Date, calendar: Calendar) -> OutdoorMonthSummary? {
        let month = records.filter { calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month) }
        guard !month.isEmpty else { return nil }
        return OutdoorMonthSummary(month: now, meters: month.reduce(0) { $0 + max(0, $1.recordedDistanceMeters ?? 0) },
            walks: month.filter { $0.kind == .walk }.count, runs: month.filter { $0.kind != .walk }.count)
    }
}

enum HistoryKind: Hashable { case workouts, outdoor }
