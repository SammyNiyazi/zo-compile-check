import Foundation
import Observation

struct WellbeingCheckInSnapshot: Codable, Equatable {
    static let currentVersion = 4
    let version: Int
    let recovery: [RecoveryCheckIn]
    let nutrition: [NutritionDayReview]
    let guidanceContext: NutritionGuidanceContext?

    init(recovery: [RecoveryCheckIn] = [], nutrition: [NutritionDayReview] = [], version: Int = Self.currentVersion,
         guidanceContext: NutritionGuidanceContext? = nil) {
        self.version = version
        self.recovery = recovery
        self.nutrition = nutrition
        self.guidanceContext = guidanceContext
    }

    var isValid: Bool {
        (1 ... Self.currentVersion).contains(version) && recovery.count <= 3_650 && nutrition.count <= 3_650
            && (version != 1 || nutrition.allSatisfy { $0.reportedCalorieGoal == nil })
            && (version >= 3 || (guidanceContext == nil && nutrition.allSatisfy { $0.amounts == nil }))
            && (version >= 4 || nutrition.allSatisfy { $0.energyTargetContext == nil })
            && (guidanceContext?.isValid ?? true)
            && recovery.allSatisfy(\.isStructurallyValid) && nutrition.allSatisfy(\.isStructurallyValid)
            && Set(recovery.map(\.id)).count == recovery.count && Set(nutrition.map(\.id)).count == nutrition.count
            && Set(recovery.map { "\($0.timeZoneID)|\($0.day.timeIntervalSinceReferenceDate)" }).count == recovery.count
            && Set(nutrition.map { "\($0.timeZoneID)|\($0.day.timeIntervalSinceReferenceDate)" }).count == nutrition.count
    }
}

enum WellbeingCheckInError: Error, Equatable {
    case unavailable, invalid, changed, saveNotConfirmed
}

/// Codable alone ignores unknown keys. Preserve unsupported stored facts by
/// rejecting them before a following correction/save can drop their fields.
private enum WellbeingSnapshotSyntax {
    static func validate(_ data: Data) throws {
        var syntax = ImportJSONSyntax(data: data); try syntax.validate()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recovery = root["recovery"] as? [[String: Any]],
              let nutrition = root["nutrition"] as? [[String: Any]],
              recovery.count <= 3_650, nutrition.count <= 3_650 else { throw WellbeingCheckInError.unavailable }
        try allowed(root, ["version", "recovery", "nutrition", "guidanceContext"])
        for report in recovery {
            try allowed(report, ["id", "day", "timeZoneID", "reportedAt", "energy", "soreness", "sleepHours",
                "hasNewOrWorseningPain", "feelsUnwell", "feelsUnusuallyHungry", "feelsThirsty"])
        }
        for review in nutrition {
            try allowed(review, ["id", "day", "timeZoneID", "reviewedAt", "coverage", "mealFingerprint",
                "reviewedFoodGroups", "reportedCalorieGoal", "amounts", "energyTargetContext"])
            try nested(review, key: "amounts", fields: ["coverage", "basis", "fruitAndVegetablesGrams",
                "foodFibreGrams", "freeSugarGrams", "saltGrams"])
            try nested(review, key: "energyTargetContext", fields: ["schemaVersion", "source", "intent"])
        }
        try nested(root, key: "guidanceContext", fields: ["reportedAt", "isAdult", "needsTailoredNutrition",
            "hasFoodRestrictions", "hasPrescribedFluidRestriction"])
    }

    private static func allowed(_ object: [String: Any], _ fields: Set<String>) throws {
        guard Set(object.keys).isSubset(of: fields) else { throw WellbeingCheckInError.unavailable }
    }

    private static func nested(_ parent: [String: Any], key: String, fields: Set<String>) throws {
        guard let value = parent[key], !(value is NSNull) else { return }
        guard let object = value as? [String: Any] else { throw WellbeingCheckInError.unavailable }
        try allowed(object, fields)
    }
}

protocol WellbeingCheckInPersisting {
    func load() throws -> WellbeingCheckInSnapshot
    func save(_ value: WellbeingCheckInSnapshot) throws
}

struct UserDefaultsWellbeingCheckInStore: WellbeingCheckInPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "01.wellbeingCheckIns.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> WellbeingCheckInSnapshot {
        guard let data = defaults.data(forKey: key) else {
            guard defaults.object(forKey: key) == nil else { throw WellbeingCheckInError.unavailable }
            return WellbeingCheckInSnapshot()
        }
        try WellbeingSnapshotSyntax.validate(data)
        let value = try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: data)
        guard value.isValid else { throw WellbeingCheckInError.unavailable }
        return value
    }

    func save(_ value: WellbeingCheckInSnapshot) throws {
        guard value.isValid else { throw WellbeingCheckInError.invalid }
        _ = try load() // Preserve corrupt or future-version data rather than overwrite it.
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        guard try load() == value else { throw WellbeingCheckInError.saveNotConfirmed }
    }
}

@MainActor @Observable
final class WellbeingCheckInRepository {
    private(set) var snapshot = WellbeingCheckInSnapshot()
    private(set) var isAvailable = false
    @ObservationIgnored private let store: any WellbeingCheckInPersisting

    init(store: any WellbeingCheckInPersisting = UserDefaultsWellbeingCheckInStore()) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            let loaded = try store.load()
            guard loaded.isValid else { throw WellbeingCheckInError.unavailable }
            snapshot = loaded
            isAvailable = true
        } catch { isAvailable = false }
    }

    /// The form's baseline must still be current. Neither a stale form nor a
    /// failed write may optimistically publish data as acknowledged evidence.
    func save(recovery: RecoveryCheckIn?, nutrition: NutritionDayReview?,
              replacing baseline: WellbeingCheckInSnapshot, at now: Date, calendar: Calendar,
              guidanceContext: NutritionGuidanceContext? = nil) throws {
        guard isAvailable, now.timeIntervalSinceReferenceDate.isFinite else { throw WellbeingCheckInError.unavailable }
        if let recovery {
            guard recovery.isCurrent(at: now, calendar: calendar),
                  recovery.day == calendar.startOfDay(for: now) else { throw WellbeingCheckInError.invalid }
        }
        if let nutrition {
            guard nutrition.isStructurallyValid, nutrition.reviewedAt <= now,
                  nutrition.timeZoneID == calendar.timeZone.identifier,
                  calendar.startOfDay(for: nutrition.day) == nutrition.day,
                  let interval = calendar.dateInterval(of: .day, for: nutrition.day),
                  nutrition.reviewedAt >= interval.end, interval.end <= now else { throw WellbeingCheckInError.invalid }
        }
        if let guidanceContext {
            guard guidanceContext.isCurrent(at: now) else { throw WellbeingCheckInError.invalid }
        }
        let fresh: WellbeingCheckInSnapshot
        do { fresh = try store.load() } catch {
            isAvailable = false
            throw WellbeingCheckInError.unavailable
        }
        guard fresh.isValid else { isAvailable = false; throw WellbeingCheckInError.unavailable }
        guard fresh == baseline else { snapshot = fresh; throw WellbeingCheckInError.changed }
        var recoveryRecords = fresh.recovery
        var nutritionRecords = fresh.nutrition
        if let recovery {
            recoveryRecords.removeAll { $0.day == recovery.day && $0.timeZoneID == recovery.timeZoneID }
            recoveryRecords.append(recovery)
        }
        if let nutrition {
            nutritionRecords.removeAll { $0.day == nutrition.day && $0.timeZoneID == nutrition.timeZoneID }
            nutritionRecords.append(nutrition)
        }
        try commit(WellbeingCheckInSnapshot(recovery: recoveryRecords, nutrition: nutritionRecords,
            guidanceContext: guidanceContext ?? fresh.guidanceContext))
    }

    /// Explicit user action, confined to this store; meal and workout originals
    /// are unaffected. It also uses the baseline and readback contract.
    func deleteAll(replacing baseline: WellbeingCheckInSnapshot) throws {
        guard isAvailable else { throw WellbeingCheckInError.unavailable }
        let fresh = try store.load()
        guard fresh == baseline else { snapshot = fresh; throw WellbeingCheckInError.changed }
        try commit(WellbeingCheckInSnapshot())
    }

    private func commit(_ candidate: WellbeingCheckInSnapshot) throws {
        guard candidate.isValid else { throw WellbeingCheckInError.invalid }
        do {
            try store.save(candidate)
            let confirmed = try store.load()
            guard confirmed.isValid, confirmed == candidate else { throw WellbeingCheckInError.saveNotConfirmed }
            snapshot = confirmed
        } catch {
            // A readable rejected write stays retryable. An unreadable store
            // becomes unavailable; the last acknowledged snapshot stays intact.
            reload()
            throw error
        }
    }
}
