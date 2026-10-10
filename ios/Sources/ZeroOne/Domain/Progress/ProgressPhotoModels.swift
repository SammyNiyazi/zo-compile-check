import Foundation
import Observation

enum ProgressPhotoLabel: String, Codable, CaseIterable, Sendable {
    case progress
    case postWorkout

    var title: String {
        switch self {
        case .progress: "Progress"
        case .postWorkout: "Post-workout"
        }
    }
}

struct ProgressPhotoRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let label: ProgressPhotoLabel
    let imageRelativePath: String
    let thumbnailRelativePath: String
}

struct ProgressPhotoDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var label: ProgressPhotoLabel
    let imageData: Data
    let thumbnailData: Data
}

enum ProgressPhotoStoreError: Error, Equatable {
    case unavailable
    case invalidImage
    case invalidOwnedPath
}

protocol ProgressPhotoPersisting {
    var isAvailable: Bool { get }
    func loadRecords() throws -> [ProgressPhotoRecord]
    func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws
    func delete(_ record: ProgressPhotoRecord) throws
    func data(at relativePath: String, for record: ProgressPhotoRecord) -> Data?
}

@MainActor
@Observable
final class ProgressPhotoRepository {
    private(set) var entries: [ProgressPhotoRecord]
    private(set) var isAvailable: Bool
    private let store: any ProgressPhotoPersisting
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    init(store: any ProgressPhotoPersisting = LocalProgressPhotoStore()) {
        self.store = store
        let loadedRecords = store.isAvailable ? try? store.loadRecords() : nil
        isAvailable = store.isAvailable && loadedRecords != nil
        entries = loadedRecords?.sorted { $0.createdAt > $1.createdAt } ?? []
    }

    /// Registration only supplies synchronous invalidation, never export permission.
    /// Revoke both old and incoming retained permits before replacing/removing it.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Root readiness must match this exact installed capability, not a cached Bool.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    func makeDraft(
        from sourceData: Data,
        label: ProgressPhotoLabel,
        createdAt: Date = .now
    ) async throws -> ProgressPhotoDraft {
        let encoded = try await Task.detached(priority: .userInitiated) {
            try ProgressPhotoImageEncoder.encode(sourceData)
        }.value

        return ProgressPhotoDraft(
            id: UUID(),
            createdAt: createdAt,
            label: label,
            imageData: encoded.imageData,
            thumbnailData: encoded.thumbnailData
        )
    }

    @discardableResult
    func save(_ draft: ProgressPhotoDraft) throws -> ProgressPhotoRecord {
        shareRevocationRegistration?.revokeBeforeChange()
        guard isAvailable else { throw ProgressPhotoStoreError.unavailable }
        let paths = LocalProgressPhotoStore.relativePaths(for: draft.id)
        let record = ProgressPhotoRecord(
            id: draft.id,
            createdAt: draft.createdAt,
            label: draft.label,
            imageRelativePath: paths.image,
            thumbnailRelativePath: paths.thumbnail
        )
        try store.save(record, imageData: draft.imageData, thumbnailData: draft.thumbnailData)
        entries.removeAll { $0.id == record.id }
        entries.append(record)
        entries.sort { $0.createdAt > $1.createdAt }
        return record
    }

    func delete(_ record: ProgressPhotoRecord) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard isAvailable else { throw ProgressPhotoStoreError.unavailable }
        try store.delete(record)
        entries.removeAll { $0.id == record.id }
    }

    func imageData(for record: ProgressPhotoRecord) -> Data? {
        store.data(at: record.imageRelativePath, for: record)
    }

    func thumbnailData(for record: ProgressPhotoRecord) -> Data? {
        store.data(at: record.thumbnailRelativePath, for: record)
    }
}

enum BodyWeightUnit: String, CaseIterable, Identifiable {
    case kilograms = "kg"
    case pounds = "lb"

    var id: String { rawValue }

    func kilograms(from value: Decimal) -> Decimal {
        guard self == .pounds else { return value }
        let pounds = NSDecimalNumber(decimal: value).doubleValue
        return Decimal(Measurement(value: pounds, unit: UnitMass.pounds).converted(to: .kilograms).value)
    }

    func displayedValue(for kilograms: Decimal) -> Double {
        let value = NSDecimalNumber(decimal: kilograms).doubleValue
        guard self == .pounds else { return value }
        return Measurement(value: value, unit: UnitMass.kilograms).converted(to: .pounds).value
    }
}

enum BodyWeightDirection: String, CaseIterable, Identifiable {
    case none
    case maintain
    case gain
    case lose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No direction"
        case .maintain: "Maintain"
        case .gain: "Gain"
        case .lose: "Lose"
        }
    }

    func context(for fourWeekChangeKilograms: Decimal) -> String {
        let change = NSDecimalNumber(decimal: fourWeekChangeKilograms).doubleValue
        let steady = abs(change) < 0.3
        switch self {
        case .none:
            return steady ? "About steady over four weeks." : "A direction is optional. This is a comparison, not a judgment."
        case .maintain where steady:
            return "About steady. That matches the direction you chose."
        case .gain where change >= 0.3:
            return "That is the direction you chose. The average matters more than one reading."
        case .lose where change <= -0.3:
            return "That is the direction you chose. The average matters more than one reading."
        default:
            return "Weight can move slowly. The average gives more context than one reading."
        }
    }
}

struct BodyWeightEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let recordedAt: Date
    let kilograms: Decimal
}

struct BodyWeightAveragePoint: Identifiable {
    let id: Date
    let kilograms: Decimal
}

enum BodyWeightStoreError: Error, Equatable {
    case unavailable
    case invalidValue
    case conflictingEntry
    case missingEntry
    case verificationFailed
}

protocol BodyWeightPersisting {
    func load() throws -> [BodyWeightEntry]
    func save(_ entries: [BodyWeightEntry]) throws
}

@MainActor
@Observable
final class BodyWeightRepository {
    private(set) var entries: [BodyWeightEntry]
    private(set) var isAvailable: Bool
    private let store: any BodyWeightPersisting

    init(store: any BodyWeightPersisting = LocalBodyWeightStore()) {
        self.store = store
        do {
            entries = try Self.readValidated(from: store)
            isAvailable = true
        } catch {
            entries = []
            isAvailable = false
        }
    }

    func reload() {
        do {
            entries = try Self.readValidated(from: store)
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    /// Read through the actual app-owned repository, preserving last readable
    /// state on an unavailable or malformed store. This does not invent provenance.
    func readForImport() throws -> [BodyWeightEntry] {
        do {
            let loaded = try Self.readValidated(from: store)
            try FoodBodyWeightImportDecoder.validateWeights(loaded)
            entries = loaded
            isAvailable = true
            return loaded
        } catch {
            isAvailable = false
            throw FoodBodyWeightImportError.storeUnavailable
        }
    }

    func importReviewed(_ candidate: [BodyWeightEntry], replacing baseline: [BodyWeightEntry]) throws {
        try FoodBodyWeightImportDecoder.validateWeights(candidate)
        guard try readForImport() == baseline else { throw FoodBodyWeightImportError.storeChanged }
        let byID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.id, $0) })
        guard baseline.allSatisfy({ byID[$0.id] == $0 }) else {
            throw FoodBodyWeightImportError.conflictingIdentifier
        }
        do {
            try persistAndConfirm(candidate)
        } catch {
            // An unacknowledged write may have landed. Block ordinary mutations
            // until a fresh read-only reload checks the actual collection.
            isAvailable = false
            throw error
        }
    }

    @discardableResult
    func save(_ entry: BodyWeightEntry) throws -> BodyWeightEntry {
        guard isAvailable else { throw BodyWeightStoreError.unavailable }
        try Self.validate(entry)
        let persisted = try readCurrent()
        if let existing = persisted.first(where: { $0.id == entry.id }) {
            guard existing == entry else {
                entries = persisted
                throw BodyWeightStoreError.conflictingEntry
            }
            try persistAndConfirm(persisted)
            return existing
        }
        let updated = ([entry] + persisted).sorted(by: Self.newestFirst)
        try persistAndConfirm(updated)
        return entry
    }

    @discardableResult
    func replace(_ original: BodyWeightEntry, with revised: BodyWeightEntry) throws -> BodyWeightEntry {
        guard isAvailable else { throw BodyWeightStoreError.unavailable }
        guard original.id == revised.id else { throw BodyWeightStoreError.conflictingEntry }
        try Self.validate(revised)
        let persisted = try readCurrent()
        guard let current = persisted.first(where: { $0.id == original.id }) else {
            entries = persisted
            throw BodyWeightStoreError.missingEntry
        }
        // A write may have succeeded before its acknowledgement failed. Retrying
        // the exact revision is safe, but a different edit must never be lost.
        if current == revised {
            try persistAndConfirm(persisted)
            return current
        }
        guard current == original else {
            entries = persisted.sorted(by: Self.newestFirst)
            throw BodyWeightStoreError.conflictingEntry
        }
        let updated = persisted.map { $0.id == original.id ? revised : $0 }
        try persistAndConfirm(updated)
        return revised
    }

    func delete(_ original: BodyWeightEntry) throws {
        guard isAvailable else { throw BodyWeightStoreError.unavailable }
        let persisted = try readCurrent()
        guard let current = persisted.first(where: { $0.id == original.id }) else {
            // The intended state was reached by an earlier uncertain attempt.
            try persistAndConfirm(persisted)
            return
        }
        guard current == original else {
            entries = persisted.sorted(by: Self.newestFirst)
            throw BodyWeightStoreError.conflictingEntry
        }
        let updated = persisted.filter { $0.id != original.id }
        try persistAndConfirm(updated)
    }

    private func readCurrent() throws -> [BodyWeightEntry] {
        do {
            return try Self.readValidated(from: store)
        } catch {
            isAvailable = false
            throw error
        }
    }

    private static func readValidated(from store: any BodyWeightPersisting) throws -> [BodyWeightEntry] {
        let values = try store.load()
        guard Set(values.map(\.id)).count == values.count else {
            throw BodyWeightStoreError.conflictingEntry
        }
        try values.forEach { try validate($0) }
        return values.sorted(by: newestFirst)
    }

    /// Do not consume store errors, including post-write file-protection errors.
    /// Only an acknowledged save plus an exact collection readback is success.
    private func persistAndConfirm(_ proposed: [BodyWeightEntry]) throws {
        try store.save(proposed)
        let confirmed = try readCurrent()
        entries = confirmed
        guard confirmed == proposed.sorted(by: Self.newestFirst) else {
            throw BodyWeightStoreError.verificationFailed
        }
    }

    private static func validate(_ entry: BodyWeightEntry) throws {
        let value = NSDecimalNumber(decimal: entry.kilograms).doubleValue
        guard value.isFinite, (0.5 ... 1_000).contains(value),
              entry.recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BodyWeightStoreError.invalidValue
        }
    }

    private static func newestFirst(_ lhs: BodyWeightEntry, _ rhs: BodyWeightEntry) -> Bool {
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// At most one reading per calendar day enters the mean and chart. A second
/// reading on the same day replaces that day's point but remains in local history.
struct BodyWeightTrend {
    let latest: BodyWeightEntry?
    let sevenDayAverageKilograms: Decimal?
    let latestDiffersFromPriorAverage: Bool
    let averageChangeAfterLatestKilograms: Decimal?
    let fourWeekChangeKilograms: Decimal?
    let lastThirtyDays: [BodyWeightEntry]
    let rollingAverages: [BodyWeightAveragePoint]

    /// Keep ordinary day-to-day variation from filling the entire chart.
    func chartDomain(for unit: BodyWeightUnit) -> ClosedRange<Double>? {
        let values = lastThirtyDays.map { unit.displayedValue(for: $0.kilograms) }
            + rollingAverages.map { unit.displayedValue(for: $0.kilograms) }
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        let minimumSpan = unit == .kilograms ? 4.0 : 9.0
        let span = max(minimumSpan, maximum - minimum + minimumSpan * 0.2)
        let center = (minimum + maximum) / 2
        let lower = max(0, center - span / 2)
        return lower ... (lower + span)
    }

    init(entries: [BodyWeightEntry], now: Date, calendar: Calendar) {
        let ordered = entries.filter { $0.recordedAt <= now }.sorted {
            $0.recordedAt > $1.recordedAt
        }
        latest = ordered.first
        var seenDays = Set<Date>()
        let daily = ordered.filter { seenDays.insert(calendar.startOfDay(for: $0.recordedAt)).inserted }
        let today = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let recent = daily.filter { $0.recordedAt >= sevenDayStart }
        sevenDayAverageKilograms = recent.isEmpty
            ? nil
            : recent.reduce(Decimal(0)) { $0 + $1.kilograms } / Decimal(recent.count)
        let prior = Array(daily.dropFirst()).filter { $0.recordedAt >= sevenDayStart }
        if let latest, latest.recordedAt >= sevenDayStart, !prior.isEmpty,
           let currentAverage = sevenDayAverageKilograms {
            let priorAverage = prior.reduce(Decimal(0)) { $0 + $1.kilograms } / Decimal(prior.count)
            let difference = NSDecimalNumber(decimal: latest.kilograms - priorAverage).doubleValue
            latestDiffersFromPriorAverage = abs(difference) >= 1
            averageChangeAfterLatestKilograms = currentAverage - priorAverage
        } else {
            latestDiffersFromPriorAverage = false
            averageChangeAfterLatestKilograms = nil
        }
        if let latest, latest.recordedAt >= sevenDayStart {
            let latestDay = calendar.startOfDay(for: latest.recordedAt)
            if let currentStart = calendar.date(byAdding: .day, value: -6, to: latestDay),
               let currentEnd = calendar.date(byAdding: .day, value: 1, to: latestDay),
               let baselineEndDay = calendar.date(byAdding: .day, value: -28, to: latestDay),
               let baselineStart = calendar.date(byAdding: .day, value: -6, to: baselineEndDay),
               let baselineEnd = calendar.date(byAdding: .day, value: 1, to: baselineEndDay) {
                let currentWindow = daily.filter {
                    $0.recordedAt >= currentStart && $0.recordedAt < currentEnd
                }
                let baselineWindow = daily.filter {
                    $0.recordedAt >= baselineStart && $0.recordedAt < baselineEnd
                }
                if currentWindow.count >= 2, baselineWindow.count >= 2 {
                    let currentTotal = currentWindow.reduce(Decimal(0)) { $0 + $1.kilograms }
                    let baselineTotal = baselineWindow.reduce(Decimal(0)) { $0 + $1.kilograms }
                    let currentAverage = currentTotal / Decimal(currentWindow.count)
                    let baselineAverage = baselineTotal / Decimal(baselineWindow.count)
                    fourWeekChangeKilograms = currentAverage - baselineAverage
                } else {
                    fourWeekChangeKilograms = nil
                }
            } else {
                fourWeekChangeKilograms = nil
            }
        } else {
            fourWeekChangeKilograms = nil
        }
        lastThirtyDays = Array(daily.filter { $0.recordedAt >= thirtyDayStart }.reversed())
        rollingAverages = lastThirtyDays.map { point in
            let pointDay = calendar.startOfDay(for: point.recordedAt)
            let windowStart = calendar.date(byAdding: .day, value: -6, to: pointDay) ?? pointDay
            let window = daily.filter { $0.recordedAt >= windowStart && $0.recordedAt <= point.recordedAt }
            return BodyWeightAveragePoint(
                id: point.recordedAt,
                kilograms: window.reduce(Decimal(0)) { $0 + $1.kilograms } / Decimal(window.count)
            )
        }
    }
}

struct ProgressWeekSnapshot {
    let start: Date
    let end: Date
    let sessions: [WorkoutHistoryDisplayItem]
    let savedSetCount: Int

    var workoutCount: Int { sessions.count }

    init(entries: [WorkoutHistoryDisplayItem], now: Date, calendar: Calendar) {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        weekCalendar.minimumDaysInFirstWeek = 4
        // Locals: closures can't capture self's properties before every property is set.
        let weekStart = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? weekCalendar.startOfDay(for: now)
        let weekEnd = weekCalendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 24 * 60 * 60)
        let weekSessions = entries.filter {
            $0.completedSetCount > 0 && $0.completedAt >= weekStart
                && $0.completedAt < weekEnd && $0.completedAt <= now
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        start = weekStart
        end = weekEnd
        sessions = weekSessions
        savedSetCount = weekSessions.reduce(0) { $0 + $1.completedSetCount }
    }
}

/// A visible next-load choice must be supported by the latest detailed saved
/// occurrence and the current plan. An unknown newer record blocks inference.
struct ProgressLoadReview: Identifiable {
    let upgrade: WorkoutCompletionUpgrade
    let sourceSessionID: UUID
    let completedAt: Date

    var id: ExerciseID { upgrade.exerciseID }

    static func available(
        for session: WorkoutSession,
        entries: [WorkoutHistoryDisplayItem],
        progressionReviews: [WorkoutProgressionReview] = [],
        asOf: Date = .now
    ) -> [Self] {
        let engine = WorkoutProgressionEngine(reviews: progressionReviews, asOf: asOf)
        let history = entries.map(\.sourceEntry)
        var seen = Set<ExerciseID>()
        return session.exercises.compactMap { exercise in
            let plan = exercise.plan
            guard seen.insert(plan.exerciseID).inserted,
                  let performance = engine.latestPerformance(for: plan, history: history),
                  let qualified = WorkoutProgressionEvidence.qualify(plan: plan, performance: performance,
                      reviews: progressionReviews, at: asOf) else { return nil }
            return Self(upgrade: .init(exerciseID: plan.exerciseID, exerciseName: plan.name,
                opportunity: qualified.opportunity, completedSets: qualified.occurrence.completedSets,
                targetRepUpperBound: plan.targetReps.upperBound, plan: plan),
                sourceSessionID: performance.sessionID, completedAt: performance.completedAt)
        }
    }
}
