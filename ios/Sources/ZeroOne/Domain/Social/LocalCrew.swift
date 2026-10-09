import Foundation
import Observation

/// The Club before its service (Sammy, 9 Oct): your crew lives on this iPhone.
/// A name and a weekly workout goal, counted from your own saved History.
/// No members, numbers or messages are invented; friends join when Social is live.
struct LocalCrew: Codable, Equatable, Sendable {
    static let nameLimit = 40
    static let goalRange = 1 ... 14

    let name: String
    let weeklyGoal: Int
    let createdAt: Date

    init?(name: String, weeklyGoal: Int, createdAt: Date) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.nameLimit,
              Self.goalRange.contains(weeklyGoal),
              createdAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        self.name = trimmed
        self.weeklyGoal = weeklyGoal
        self.createdAt = createdAt
    }

    /// Saved workouts completed in the calendar week containing `asOf`.
    static func workoutsThisWeek(completedAt dates: [Date], asOf: Date, calendar: Calendar) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: asOf) else { return 0 }
        return dates.filter { week.contains($0) && $0 <= asOf }.count
    }
}

@MainActor
@Observable
final class LocalCrewStore {
    static let storageKey = "01.localCrew.v1"

    private(set) var crew: LocalCrew?
    /// False when a saved crew exists but can't be read; it is kept, never overwritten.
    private(set) var isAvailable = true
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            crew = nil
            isAvailable = true
            return
        }
        if let decoded = try? JSONDecoder().decode(LocalCrew.self, from: data),
           LocalCrew(name: decoded.name, weeklyGoal: decoded.weeklyGoal, createdAt: decoded.createdAt) != nil {
            crew = decoded
            isAvailable = true
        } else {
            crew = nil
            isAvailable = false
        }
    }

    @discardableResult
    func save(_ crew: LocalCrew) -> Bool {
        guard isAvailable, let data = try? JSONEncoder().encode(crew) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else { return false }
        self.crew = crew
        return true
    }

    @discardableResult
    func leave() -> Bool {
        guard isAvailable else { return false }
        defaults.removeObject(forKey: Self.storageKey)
        crew = nil
        return defaults.data(forKey: Self.storageKey) == nil
    }
}
