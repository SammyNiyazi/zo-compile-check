import Foundation
import Observation

/// User choices, never estimated from exercise or presented as medical advice.
struct DailyGoals: Codable, Equatable, Sendable {
    let steps: Int?
    let foodKilocalories: Int?
    static let empty = Self(steps: nil, foodKilocalories: nil)
    var isValid: Bool { (steps.map { $0 > 0 } ?? true) && (foodKilocalories.map { $0 > 0 } ?? true) }
}

struct DailyGoalsDraft: Equatable {
    var steps: String
    var foodKilocalories: String

    init(value: DailyGoals) {
        steps = value.steps.map(String.init) ?? ""
        foodKilocalories = value.foodKilocalories.map(String.init) ?? ""
    }

    func validated() throws -> DailyGoals {
        try DailyGoals(steps: Self.number(steps), foodKilocalories: Self.number(foodKilocalories))
    }

    private static func number(_ text: String) throws -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var value = 0
        for character in text {
            guard character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                  let digit = character.wholeNumberValue, (0 ... 9).contains(digit) else { throw DailyGoalsError.invalidNumber }
            let product = value.multipliedReportingOverflow(by: 10)
            let sum = product.partialValue.addingReportingOverflow(digit)
            guard !product.overflow, !sum.overflow else { throw DailyGoalsError.invalidNumber }
            value = sum.partialValue
        }
        guard value > 0 else { throw DailyGoalsError.invalidNumber }
        return value
    }
}

enum DailyGoalsError: Error, LocalizedError {
    case invalidNumber, unavailable, changed, verificationFailed
    var errorDescription: String? {
        switch self {
        case .invalidNumber: "Use a positive whole number without separators, or leave the field blank."
        case .unavailable: "Your goals could not be loaded. Existing data has been kept."
        case .changed: "Your goals changed elsewhere. Reload them before saving."
        case .verificationFailed: "Goals were not confirmed saved. Try again."
        }
    }
}

protocol DailyGoalsPersisting {
    func load() throws -> DailyGoals
    func save(_ value: DailyGoals) throws
}

struct UserDefaultsDailyGoalsStore: DailyGoalsPersisting {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "01.dailyGoals.v1") { self.defaults = defaults; self.key = key }
    func load() throws -> DailyGoals {
        guard let data = defaults.data(forKey: key) else {
            guard defaults.object(forKey: key) == nil else { throw DailyGoalsError.unavailable }
            return .empty
        }
        let value = try JSONDecoder().decode(DailyGoals.self, from: data)
        guard value.isValid else { throw DailyGoalsError.unavailable }
        return value
    }
    func save(_ value: DailyGoals) throws {
        guard value.isValid else { throw DailyGoalsError.invalidNumber }
        _ = try load() // Never replace corrupt prior data with an empty default.
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        guard try load() == value else { throw DailyGoalsError.verificationFailed }
    }
}

@MainActor @Observable
final class DailyGoalsRepository {
    private(set) var value: DailyGoals = .empty
    private(set) var isAvailable = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let store: any DailyGoalsPersisting

    init(store: any DailyGoalsPersisting = UserDefaultsDailyGoalsStore()) {
        self.store = store
        reload()
    }
    func reload() {
        do {
            let loaded = try store.load()
            guard loaded.isValid else { throw DailyGoalsError.unavailable }
            value = loaded
            isAvailable = true
            errorMessage = nil
        }
        catch { isAvailable = false; errorMessage = DailyGoalsError.unavailable.localizedDescription }
    }
    func valueForExport() throws -> DailyGoals {
        let saved = try store.load()
        guard saved.isValid else { throw DailyGoalsError.unavailable }
        return saved
    }
    @discardableResult
    func save(_ proposed: DailyGoals, replacing expected: DailyGoals) -> Bool {
        do {
            guard isAvailable else { throw DailyGoalsError.unavailable }
            guard proposed.isValid else { throw DailyGoalsError.invalidNumber }
            guard try store.load() == expected, value == expected else { throw DailyGoalsError.changed }
            try store.save(proposed)
            guard try store.load() == proposed else { throw DailyGoalsError.verificationFailed }
            value = proposed
            errorMessage = nil
            return true
        } catch {
            // A failed write/readback is not evidence that the last in-memory
            // targets are still current. Reconcile without retrying the write.
            // The editor owns its draft and keeps it until an explicit reload.
            let message = error.localizedDescription
            if let confirmed = try? store.load(), confirmed.isValid {
                value = confirmed
                isAvailable = true
            } else {
                isAvailable = false
            }
            errorMessage = message
            return false
        }
    }
}
