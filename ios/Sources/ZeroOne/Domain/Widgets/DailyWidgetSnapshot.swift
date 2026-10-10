import Foundation

/// Shared, read-only display data. Never a source of truth for meals, water or HealthKit.
/// Deliberately excludes routes, locations, names, workout detail and raw health samples.
struct DailyWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Kind: String, CaseIterable, Sendable {
        case steps = "01.daily.steps"
        case calories = "01.daily.calories"
        case water = "01.daily.water"
        case together = "01.daily.together"
    }

    struct Metric: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case available, noData, needsConnection, needsRefresh, unavailable
        }

        let state: State
        let value: Double?
        let asOf: Date?
        let isStale: Bool

        static func reading(_ value: Double?, at date: Date, isStale: Bool = false) -> Self {
            guard let value, value.isFinite, value >= 0, value < Double(Int.max) else {
                return missing(.noData)
            }
            return Self(state: .available, value: value, asOf: date, isStale: isStale)
        }

        static func missing(_ state: State) -> Self {
            Self(state: state == .available ? .noData : state, value: nil, asOf: nil, isStale: false)
        }

        fileprivate func isValid(from start: Date, through end: Date) -> Bool {
            if state != .available { return value == nil && asOf == nil && !isStale }
            guard let value, value.isFinite, value >= 0, value < Double(Int.max), let asOf else { return false }
            return asOf.timeIntervalSinceReferenceDate.isFinite && asOf >= start && asOf <= end
        }
    }

    /// Totals only. No record identity, route, place, coordinates or map thumbnail.
    struct Walk: Codable, Equatable, Sendable {
        let finishedAt: Date
        let activeSeconds: Double
        let distanceMeters: Double?
        let distanceIncomplete: Bool
        var usesMiles = false

        func isValid(at date: Date) -> Bool {
            finishedAt.timeIntervalSinceReferenceDate.isFinite && finishedAt <= date
                && activeSeconds.isFinite && activeSeconds >= 0 && activeSeconds < Double(Int.max)
                && (distanceMeters.map { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) } ?? true)
        }
        func usingMiles(_ value: Bool) -> Self { var copy = self; copy.usesMiles = value; return copy }
        var distanceText: String { distanceText(using: .english) }
        var durationText: String { durationText(using: .english) }
        func distanceText(using localization: AppLocalization) -> String {
            guard let distanceMeters else { return localization.string("Distance unavailable") }
            let value = distanceMeters / (usesMiles ? 1_609.344 : 1_000)
            let number = SharedSurfaceLocalization(language: localization.language).number(value, fractionDigits: 0 ... 2)
            return localization.format("%1$@ %2$@", .text(number), .text(localization.string(usesMiles ? "mi" : "km")))
        }
        func durationText(using localization: AppLocalization) -> String {
            guard activeSeconds.isFinite, activeSeconds >= 0, activeSeconds < Double(Int.max) else { return "—" }
            let minutes = Int(activeSeconds) / 60
            if minutes == 0 { return localization.string("Under 1 min") }
            return minutes >= 60
                ? localization.format("%1$lld h %2$lld min", .integer(minutes / 60), .integer(minutes % 60))
                : localization.format("%1$lld min", .integer(minutes))
        }
    }

    let version: Int
    let generatedAt: Date
    let dayStart: Date
    let steps: Metric
    /// Food logged in 01, never netted against burned energy.
    let eatenKilocalories: Metric
    /// Apple Health active energy only, not total daily energy expenditure.
    let burnedKilocalories: Metric
    let waterMilliliters: Metric
    let waterGoalMilliliters: Int?
    let latestWalk: Walk?
    let stepGoal: Int?
    let foodGoalKilocalories: Int?
    // An absent or future accent falls back to yellow without invalidating recorded totals.
    var accentPreference: String? = nil
    var accent: AccentPreference { .storedValue(accentPreference) }
    var displayLanguageIdentifier: String? = nil
    var displayLanguage: AppLanguage { SharedSurfaceLocalization.language(displayLanguageIdentifier) }
    var localization: AppLocalization { AppLocalization(language: displayLanguage) }
    // Presentation only. Unknown raw values round-trip while resolving to Core.
    var designThemeIdentifier: String? = nil
    var displayTheme: ZOTheme { designThemeIdentifier.flatMap(ZOTheme.init(rawValue:)) ?? .core }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, dayStart, steps, eatenKilocalories, burnedKilocalories
        case waterMilliliters, waterGoalMilliliters, latestWalk, stepGoal, foodGoalKilocalories
        case accentPreference, displayLanguageIdentifier, designThemeIdentifier
    }

    func usingLanguage(_ language: AppLanguage) -> Self {
        var copy = self
        copy.displayLanguageIdentifier = language.rawValue
        return copy
    }

    func usingDesignTheme(_ theme: ZOTheme) -> Self {
        var copy = self
        copy.designThemeIdentifier = theme.rawValue
        return copy
    }

    init(generatedAt: Date, dayStart: Date, steps: Metric, eatenKilocalories: Metric,
         burnedKilocalories: Metric, waterMilliliters: Metric, waterGoalMilliliters: Int?, latestWalk: Walk? = nil,
         stepGoal: Int? = nil, foodGoalKilocalories: Int? = nil, accent: AccentPreference = .yellow) {
        version = Self.currentVersion
        self.generatedAt = generatedAt
        self.dayStart = dayStart
        self.steps = steps
        self.eatenKilocalories = eatenKilocalories
        self.burnedKilocalories = burnedKilocalories
        self.waterMilliliters = waterMilliliters
        self.waterGoalMilliliters = waterGoalMilliliters
        self.latestWalk = latestWalk
        self.stepGoal = stepGoal
        self.foodGoalKilocalories = foodGoalKilocalories
        self.accentPreference = accent.rawValue
    }

    var isValid: Bool {
        version == Self.currentVersion
            && generatedAt.timeIntervalSinceReferenceDate.isFinite
            && dayStart.timeIntervalSinceReferenceDate.isFinite
            && dayStart <= generatedAt
            && [steps, eatenKilocalories, burnedKilocalories, waterMilliliters]
                .allSatisfy { $0.isValid(from: dayStart, through: generatedAt) }
            && (waterGoalMilliliters.map { $0 > 0 } ?? true)
            && (latestWalk.map { $0.isValid(at: generatedAt) } ?? true)
            && (stepGoal.map { $0 > 0 } ?? true)
            && (foodGoalKilocalories.map { $0 > 0 } ?? true)
    }

    /// The extension must check this on each timeline read, including after travel.
    func isCurrent(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        isValid && generatedAt <= date && dayStart == calendar.startOfDay(for: date)
            && calendar.isDate(generatedAt, inSameDayAs: date)
    }
}

extension DailyWidgetSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        dayStart = try values.decode(Date.self, forKey: .dayStart)
        steps = try values.decode(Metric.self, forKey: .steps)
        eatenKilocalories = try values.decode(Metric.self, forKey: .eatenKilocalories)
        burnedKilocalories = try values.decode(Metric.self, forKey: .burnedKilocalories)
        waterMilliliters = try values.decode(Metric.self, forKey: .waterMilliliters)
        waterGoalMilliliters = try values.decodeIfPresent(Int.self, forKey: .waterGoalMilliliters)
        latestWalk = try values.decodeIfPresent(Walk.self, forKey: .latestWalk)
        stepGoal = try values.decodeIfPresent(Int.self, forKey: .stepGoal)
        foodGoalKilocalories = try values.decodeIfPresent(Int.self, forKey: .foodGoalKilocalories)
        accentPreference = try values.decodeIfPresent(String.self, forKey: .accentPreference)
        displayLanguageIdentifier = try? values.decode(String.self, forKey: .displayLanguageIdentifier)
        designThemeIdentifier = try? values.decode(String.self, forKey: .designThemeIdentifier)
    }
}

enum DailyWidgetSnapshotError: Error {
    case sharedContainerUnavailable
    case invalidSnapshot
    case verificationFailed
}

protocol DailyWidgetSnapshotPersisting {
    var isAvailable: Bool { get }
    func load() throws -> DailyWidgetSnapshot?
    func save(_ snapshot: DailyWidgetSnapshot) throws
}

/// Resolves an entitled App Group, never a fabricated shared filesystem path.
/// Until the Apple capability and matching profiles are configured, this fails closed.
struct FileDailyWidgetSnapshotStore: DailyWidgetSnapshotPersisting {
    private let directory: URL?
    private let fileManager: FileManager

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        let identifier = bundle.object(forInfoDictionaryKey: "01AppGroupIdentifier") as? String
        let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        directory = normalized.flatMap { id in
            id.isEmpty ? nil : fileManager.containerURL(forSecurityApplicationGroupIdentifier: id)
        }?.appendingPathComponent("DailyWidgetDisplay", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Explicit directory injection for isolated tests. Production uses the entitled initializer.
    init(directory: URL?, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    var isAvailable: Bool { directory != nil }

    func load() throws -> DailyWidgetSnapshot? {
        guard let directory else { throw DailyWidgetSnapshotError.sharedContainerUnavailable }
        let url = directory.appendingPathComponent("daily.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: Data(contentsOf: url))
        guard decoded.isValid else { throw DailyWidgetSnapshotError.invalidSnapshot }
        return decoded
    }

    func save(_ snapshot: DailyWidgetSnapshot) throws {
        guard let directory else { throw DailyWidgetSnapshotError.sharedContainerUnavailable }
        guard snapshot.isValid else { throw DailyWidgetSnapshotError.invalidSnapshot }
        let data = try JSONEncoder().encode(snapshot)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("daily.json")
        // Display cache remains readable after first unlock, while primary stores keep their own protection.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try load() == snapshot else { throw DailyWidgetSnapshotError.verificationFailed }
    }
}
