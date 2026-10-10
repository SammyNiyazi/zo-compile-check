import Foundation

struct HydrationStoredState: Codable, Equatable, Sendable {
    let date: Date
    let currentMilliliters: Int
    let goalMilliliters: Int
    let dayStart: Date?

    init(date: Date, currentMilliliters: Int, goalMilliliters: Int, dayStart: Date? = nil) {
        self.date = date
        self.currentMilliliters = currentMilliliters
        self.goalMilliliters = goalMilliliters
        self.dayStart = dayStart
    }
}

protocol HydrationPersisting {
    var isAvailable: Bool { get }
    func load() -> HydrationStoredState?
    func save(_ state: HydrationStoredState)
}

extension HydrationPersisting {
    var isAvailable: Bool { true }
}

struct UserDefaultsHydrationStore: HydrationPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.hydrationDailyState") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HydrationStoredState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HydrationStoredState.self, from: data)
    }

    func save(_ state: HydrationStoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    var isAvailable: Bool {
        guard let data = defaults.data(forKey: key) else { return true }
        return (try? JSONDecoder().decode(HydrationStoredState.self, from: data)) != nil
    }
}
