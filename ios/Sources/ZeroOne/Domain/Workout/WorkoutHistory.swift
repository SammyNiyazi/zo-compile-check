import Foundation
import Observation

struct WorkoutHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let programmeID: WorkoutProgrammeID?
    let programmeProvenance: WorkoutProgrammeProvenance?
    let title: String
    let completedAt: Date
    let completedSetCount: Int
    let plannedSetCount: Int
    let targetDurationMinutes: Int?
    let wasAdapted: Bool
    // Nil in older records means the warm-up outcome was never recorded.
    let warmUp: WorkoutWarmUp?
    // Missing in legacy summaries means unknown, not an empty performed workout.
    let exercises: [WorkoutHistoryExercise]?
    // Nil in legacy records and automatic reconciliation without a user review.
    let executionCompletionConfirmedAt: Date?

    init(session: WorkoutSession) {
        id = session.id
        programmeID = session.programmeID
        programmeProvenance = session.programmeProvenance
        title = session.title
        precondition(session.isComplete, "Only completed sessions belong in History.")
        completedAt = session.completedAt!
        completedSetCount = session.completedSetCount
        plannedSetCount = session.totalPlannedSetCount
        targetDurationMinutes = session.targetDurationMinutes
        wasAdapted = session.isAdapted
        warmUp = session.warmUp
        exercises = session.exercises.map(WorkoutHistoryExercise.init)
        executionCompletionConfirmedAt = session.executionCompletionConfirmedAt
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func hasSameSummary(as other: Self) -> Bool {
        id == other.id && programmeID == other.programmeID && title == other.title
            && programmeProvenance == other.programmeProvenance
            && completedAt == other.completedAt && completedSetCount == other.completedSetCount
            && plannedSetCount == other.plannedSetCount && targetDurationMinutes == other.targetDurationMinutes
            && wasAdapted == other.wasAdapted
            && (executionCompletionConfirmedAt == nil
                || executionCompletionConfirmedAt == other.executionCompletionConfirmedAt)
    }

    /// Count and confirmation provenance only. This does not establish technique,
    /// effort, safety or comparability with another programme prescription.
    var executionCompleteness: WorkoutExecutionCompleteness {
        guard let exercises, !exercises.isEmpty else {
            return executionCompletionConfirmedAt == nil ? .unknown : .inconsistent
        }
        let sets = exercises.flatMap(\.completedSets)
        guard Set(exercises.map(\.id)).count == exercises.count,
              Set(sets.map(\.id)).count == sets.count,
              sets.count == completedSetCount,
              completedSetCount <= plannedSetCount,
              completedAt.timeIntervalSinceReferenceDate.isFinite else { return .inconsistent }
        if completedSetCount < plannedSetCount {
            return executionCompletionConfirmedAt == nil ? .partial : .inconsistent
        }
        guard exercises.allSatisfy({ $0.plannedSetCount != nil }) else {
            return executionCompletionConfirmedAt == nil ? .unknown : .inconsistent
        }
        // Bound before addition so a malformed decoded count cannot overflow.
        var totalPlanned = 0
        for exercise in exercises {
            guard let number = exercise.plannedSetCount, number > 0,
                  number <= plannedSetCount - totalPlanned,
                  number == exercise.completedSets.count else { return .inconsistent }
            totalPlanned += number
        }
        guard totalPlanned == plannedSetCount else { return .inconsistent }
        guard let confirmed = executionCompletionConfirmedAt else { return .unknown }
        guard confirmed.timeIntervalSinceReferenceDate.isFinite, confirmed >= completedAt else { return .inconsistent }
        return .confirmedComplete
    }
}

struct WorkoutHistoryExercise: Identifiable, Codable, Equatable {
    let id: UUID
    let exerciseID: ExerciseID
    // Array order preserves exercise occurrence and set order, including repeated exercises.
    let completedSets: [CompletedSet]
    // Nil in older records means this exercise's planned set count was never recorded.
    // Older records are never back-filled or given an inferred allocation.
    let plannedSetCount: Int?
    // Present only when the target was explicitly authored at execution time.
    let targetPrescription: WorkingSetPrescription?

    init(exercise: WorkoutExercise) {
        id = exercise.id
        exerciseID = exercise.plan.exerciseID
        completedSets = exercise.completedSets
        plannedSetCount = exercise.plan.plannedSetCount
        targetPrescription = exercise.plan.targetPrescription
    }

    /// Same saved occurrence and sets. A record without a planned count is
    /// compatible with any planned count; it only never learned it.
    func hasSameRecordedSets(as other: Self) -> Bool {
        id == other.id && exerciseID == other.exerciseID && completedSets == other.completedSets
            && (plannedSetCount == nil || plannedSetCount == other.plannedSetCount)
            && (targetPrescription == nil || targetPrescription == other.targetPrescription)
    }
}

enum WorkoutHistoryRecordResult: Equatable {
    case inserted
    case alreadyRecorded
}

enum WorkoutPersistenceError: Error {
    case unavailable
    case incompleteSession
    case conflictingSession
    case invalidSnapshot
    case verificationFailed
}

enum WorkoutHistoryAvailability: Equatable {
    case available
    case unavailable
}

struct WorkoutHistoryDisplayItem: Identifiable, Equatable {
    let sourceEntry: WorkoutHistoryEntry
    let id: UUID
    let programmeID: WorkoutProgrammeID?
    let title: String
    let completedAt: Date
    let completedSetCount: Int
    let plannedSetCount: Int
    let targetDurationMinutes: Int?
    let endedEarly: Bool
    let wasAdapted: Bool
    let warmUp: WorkoutWarmUp?
    let exercises: [WorkoutHistoryExercise]?

    init(entry: WorkoutHistoryEntry) {
        sourceEntry = entry
        id = entry.id
        programmeID = entry.programmeID
        title = entry.title
        completedAt = entry.completedAt
        completedSetCount = entry.completedSetCount
        plannedSetCount = entry.plannedSetCount
        targetDurationMinutes = entry.targetDurationMinutes
        endedEarly = entry.completedSetCount < entry.plannedSetCount
        wasAdapted = entry.wasAdapted
        warmUp = entry.warmUp
        exercises = entry.exercises
    }
}

struct WorkoutExerciseHistoryItem: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let sessionTitle: String
    let completedAt: Date
    let endedEarly: Bool
    let completedSets: [CompletedSet]
}

/// All saved occurrences for one exact exercise ID, newest session first.
/// Legacy summaries and sessions without sets cannot establish set-level history.
struct WorkoutExerciseHistory: Equatable {
    let exerciseID: ExerciseID
    let items: [WorkoutExerciseHistoryItem]

    init(exerciseID: ExerciseID, entries: [WorkoutHistoryDisplayItem]) {
        self.exerciseID = exerciseID
        items = entries.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.flatMap { entry in
            (entry.exercises ?? []).compactMap { exercise in
                guard exercise.exerciseID == exerciseID, !exercise.completedSets.isEmpty else { return nil }
                return WorkoutExerciseHistoryItem(
                    // Programme plans can reuse an exercise occurrence ID across sessions.
                    // A logged set ID identifies this saved occurrence without conflation.
                    id: exercise.completedSets[0].id,
                    sessionID: entry.id,
                    sessionTitle: entry.title,
                    completedAt: entry.completedAt,
                    endedEarly: entry.endedEarly,
                    completedSets: exercise.completedSets
                )
            }
        }
    }
}

enum WorkoutHistorySurfaceState: Equatable {
    case empty
    case entries([WorkoutHistoryDisplayItem])
    case unavailable
}

struct SavedLiftProgressPoint: Identifiable, Equatable {
    let id: UUID
    let completedAt: Date
    let load: Load
    let reps: Int
}

/// A truthful, same-unit view of saved performance for one exercise in the current plan.
/// Each point is the heaviest completed set in a session, not an estimated strength score.
struct SavedLiftProgress: Equatable {
    let exerciseID: ExerciseID
    let exerciseName: String
    let unit: LoadUnit
    let points: [SavedLiftProgressPoint]

    init?(session: WorkoutSession, historyState: WorkoutHistorySurfaceState) {
        guard case let .entries(entries) = historyState else { return nil }

        for exercise in session.exercises {
            let plan = exercise.plan
            let unit = plan.targetLoad.unit
            let matching = entries.compactMap { entry -> SavedLiftProgressPoint? in
                let sets = entry.exercises?
                    .filter { $0.exerciseID == plan.exerciseID }
                    .flatMap(\.completedSets) ?? []
                let heaviest = sets
                    .filter { !$0.isTimed && $0.load.unit == unit && $0.load.value.isFinite && $0.load.value > 0 && $0.reps > 0 }
                    .max { lhs, rhs in
                        if lhs.load.value != rhs.load.value { return lhs.load.value < rhs.load.value }
                        if lhs.reps != rhs.reps { return lhs.reps < rhs.reps }
                        return lhs.completedAt < rhs.completedAt
                    }
                guard let heaviest else { return nil }
                return SavedLiftProgressPoint(
                    id: entry.id,
                    completedAt: entry.completedAt,
                    load: heaviest.load,
                    reps: heaviest.reps
                )
            }
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

            guard !matching.isEmpty else { continue }
            exerciseID = plan.exerciseID
            exerciseName = plan.name
            self.unit = unit
            points = Array(matching.suffix(6))
            return
        }
        return nil
    }
}

struct WorkoutActivityMonth: Identifiable, Equatable {
    let start: Date
    let workoutCount: Int

    var id: Date { start }
}

struct WorkoutActivityDay: Identifiable, Equatable {
    let date: Date
    let workoutCount: Int
    let partialWorkoutCount: Int
    let isToday: Bool
    let isFuture: Bool

    var id: Date { date }
}

/// Calendar-based counts from completed local sessions with saved working sets,
/// including sessions ended early.
/// There is no streak reset or inferred activity when history is unavailable.
struct WorkoutActivitySummary: Equatable {
    let thisWeekCount: Int
    let thisMonthCount: Int
    let thisMonthSetCount: Int
    let months: [WorkoutActivityMonth]
    let monthDays: [WorkoutActivityDay]
    let leadingWeekdayCount: Int

    init(entries: [WorkoutHistoryDisplayItem], now: Date, calendar: Calendar) {
        let acknowledged = entries.filter { $0.completedSetCount > 0 }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let currentMonth = calendar.dateInterval(of: .month, for: now)
        thisWeekCount = acknowledged.filter { week?.contains($0.completedAt) == true }.count
        thisMonthCount = acknowledged.filter { currentMonth?.contains($0.completedAt) == true }.count
        thisMonthSetCount = acknowledged
            .filter { currentMonth?.contains($0.completedAt) == true }
            .reduce(0) { $0 + $1.completedSetCount }

        guard let currentMonth else {
            months = []
            monthDays = []
            leadingWeekdayCount = 0
            return
        }

        leadingWeekdayCount = (
            calendar.component(.weekday, from: currentMonth.start) - calendar.firstWeekday + 7
        ) % 7
        let today = calendar.startOfDay(for: now)
        monthDays = (calendar.range(of: .day, in: .month, for: currentMonth.start) ?? 1..<1)
            .compactMap { dayNumber in
                guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: currentMonth.start),
                      let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
                let saved = acknowledged.filter { interval.contains($0.completedAt) }
                return WorkoutActivityDay(
                    date: date,
                    workoutCount: saved.count,
                    partialWorkoutCount: saved.filter(\.endedEarly).count,
                    isToday: calendar.isDate(date, inSameDayAs: now),
                    isFuture: date > today
                )
            }
        months = (0..<6).reversed().compactMap { monthsAgo in
            guard let start = calendar.date(byAdding: .month, value: -monthsAgo, to: currentMonth.start),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return WorkoutActivityMonth(
                start: interval.start,
                workoutCount: acknowledged.filter { interval.contains($0.completedAt) }.count
            )
        }
    }
}

enum WorkoutMuscleRegion: String, CaseIterable, Identifiable {
    case chest, shoulders, biceps, triceps, forearms, back, traps, core
    case lowerBack, glutes, quadriceps, hamstrings, calves, adductors, hipFlexors, serratus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowerBack: "Lower back"
        case .quadriceps: "Quads"
        case .adductors: "Inner thighs"
        case .hipFlexors: "Hip flexors"
        default: rawValue.capitalized
        }
    }

    /// Explicitly maps the shipped exercise seed. Unknown names are never assigned a guessed area.
    static func fromSeedMuscle(_ name: String) -> Self? {
        switch name {
        case "pectoralis major", "upper chest": .chest
        case "anterior deltoid", "lateral deltoid", "posterior deltoid", "shoulders", "rotator cuff": .shoulders
        case "biceps", "brachialis": .biceps
        case "triceps": .triceps
        case "forearms": .forearms
        case "latissimus dorsi", "mid back", "upper back": .back
        case "upper trapezius": .traps
        case "abdominals": .core
        case "spinal erectors": .lowerBack
        case "gluteus maximus": .glutes
        case "quadriceps": .quadriceps
        case "hamstrings": .hamstrings
        case "gastrocnemius", "soleus", "calves": .calves
        case "adductors": .adductors
        case "hip flexors": .hipFlexors
        case "serratus anterior": .serratus
        default: nil
        }
    }

    /// The licensed library uses broader category labels than the authored seed.
    /// Keep unmapped categories unknown rather than guessing a body region.
    static func fromLicensedMuscle(_ name: String) -> Self? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chest": .chest
        case "shoulders": .shoulders
        case "biceps": .biceps
        case "triceps": .triceps
        case "forearms": .forearms
        case "back": .back
        case "trapezius": .traps
        case "core": .core
        case "lower back": .lowerBack
        case "glutes": .glutes
        case "quadriceps": .quadriceps
        case "hamstrings": .hamstrings
        case "calves": .calves
        case "adductors": .adductors
        default: nil
        }
    }
}

struct WorkoutMuscleRegionLoad: Identifiable, Equatable {
    let region: WorkoutMuscleRegion
    let directSets: Int
    let helperSets: Int
    let sessionIDs: [UUID]

    var id: WorkoutMuscleRegion { region }
    var score: Double { Double(directSets) + Double(helperSets) * 0.5 }
    var tier: Int { score == 0 ? 0 : (score < 5 ? 1 : (score < 10 ? 2 : 3)) }
}

struct WorkoutMuscleExerciseContribution: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let exerciseID: ExerciseID
    let region: WorkoutMuscleRegion
    let exerciseName: String
    let isDirect: Bool
    let completedSets: [CompletedSet]
}

/// Monday-to-Sunday muscle work from saved, exercise-level History only.
/// Multiple source names mapping to the same visible area count once per set.
struct WorkoutMuscleWeek: Equatable {
    let start: Date
    let end: Date
    let regions: [WorkoutMuscleRegionLoad]
    let contributions: [WorkoutMuscleExerciseContribution]
    let sessionsWithoutExerciseDetails: Int
    let setsWithoutMuscleMapping: Int

    var hasMappedSets: Bool { regions.contains { $0.score > 0 } }

    init(entries: [WorkoutHistoryDisplayItem], now: Date, calendar: Calendar) {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        weekCalendar.minimumDaysInFirstWeek = 4
        start = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? weekCalendar.startOfDay(for: now)
        end = weekCalendar.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 24 * 60 * 60)

        var direct: [WorkoutMuscleRegion: Int] = [:]
        var helper: [WorkoutMuscleRegion: Int] = [:]
        var sessionIDs: [WorkoutMuscleRegion: Set<UUID>] = [:]
        var savedContributions: [WorkoutMuscleExerciseContribution] = []
        var unknownSessions = 0
        var unknownSets = 0

        for entry in entries where entry.completedAt >= start && entry.completedAt < end {
            guard let exercises = entry.exercises else {
                unknownSessions += 1
                continue
            }
            for exercise in exercises where !exercise.completedSets.isEmpty {
                let setCount = exercise.completedSets.count
                let primaryNames: [String]
                let secondaryNames: [String]
                let exerciseName: String
                if let definition = ExerciseLibrary.exercise(id: exercise.exerciseID) {
                    primaryNames = definition.primaryMuscleNames
                    secondaryNames = definition.secondaryMuscleNames
                    exerciseName = definition.name
                } else if let clip = MoveKitExerciseCatalog.match(for: exercise.exerciseID)?.exercise {
                    primaryNames = clip.muscleFocus.components(separatedBy: ",")
                    secondaryNames = []
                    exerciseName = clip.name
                } else {
                    unknownSets += setCount
                    continue
                }
                func region(_ name: String) -> WorkoutMuscleRegion? {
                    WorkoutMuscleRegion.fromSeedMuscle(name)
                        ?? WorkoutMuscleRegion.fromLicensedMuscle(name)
                }
                let primary = Set(primaryNames.compactMap(region))
                let secondary = Set(secondaryNames.compactMap(region))
                    .subtracting(primary)
                if primary.isEmpty && secondary.isEmpty
                    || (primaryNames + secondaryNames).contains(where: { region($0) == nil }) {
                    unknownSets += setCount
                }
                for region in primary {
                    direct[region, default: 0] += setCount
                    sessionIDs[region, default: []].insert(entry.id)
                    savedContributions.append(WorkoutMuscleExerciseContribution(
                        id: exercise.id, sessionID: entry.id, exerciseID: exercise.exerciseID, region: region,
                        exerciseName: exerciseName, isDirect: true,
                        completedSets: exercise.completedSets
                    ))
                }
                for region in secondary {
                    helper[region, default: 0] += setCount
                    sessionIDs[region, default: []].insert(entry.id)
                    savedContributions.append(WorkoutMuscleExerciseContribution(
                        id: exercise.id, sessionID: entry.id, exerciseID: exercise.exerciseID, region: region,
                        exerciseName: exerciseName, isDirect: false,
                        completedSets: exercise.completedSets
                    ))
                }
            }
        }

        regions = WorkoutMuscleRegion.allCases.map { region in
            WorkoutMuscleRegionLoad(
                region: region,
                directSets: direct[region, default: 0],
                helperSets: helper[region, default: 0],
                sessionIDs: sessionIDs[region, default: []].sorted { $0.uuidString < $1.uuidString }
            )
        }
        contributions = savedContributions
        sessionsWithoutExerciseDetails = unknownSessions
        setsWithoutMuscleMapping = unknownSets
    }
}

protocol WorkoutHistoryPersisting {
    func load() throws -> [WorkoutHistoryEntry]
    func save(_ entries: [WorkoutHistoryEntry]) throws
    var isAvailable: Bool { get }
}

extension WorkoutHistoryPersisting {
    var isAvailable: Bool { true }
}

/// New envelopes deliberately fail an older array-only decoder. Legacy arrays
/// remain read-only inputs; missing timer evidence is never backfilled.
enum WorkoutHistoryStorageCodec {
    static let currentVersion = 2
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let entries: [WorkoutHistoryEntry]
    }
    static func decode(_ data: Data) throws -> [WorkoutHistoryEntry] {
        guard data.count <= 64 * 1_024 * 1_024 else { throw WorkoutPersistenceError.invalidSnapshot }
        var syntax = ImportJSONSyntax(data: data)
        try syntax.validate()
        let object = try JSONSerialization.jsonObject(with: data)
        let entries: [WorkoutHistoryEntry]
        if let rows = object as? [[String: Any]] {
            try WorkoutHistoryImportDecoder.validateRawEntries(rows, allowsRestEvidence: false)
            entries = try JSONDecoder().decode([WorkoutHistoryEntry].self, from: data)
        } else if let envelope = object as? [String: Any],
                  Set(envelope.keys) == ["format", "version", "entries"],
                  let rows = envelope["entries"] as? [[String: Any]] {
            let saved = try JSONDecoder().decode(Envelope.self, from: data)
            guard saved.format == "zeroone-workout-history", (1...currentVersion).contains(saved.version) else {
                throw WorkoutPersistenceError.invalidSnapshot
            }
            try WorkoutHistoryImportDecoder.validateRawEntries(rows, allowsRestEvidence: true,
                allowsProgrammeEvidence: saved.version >= 2)
            entries = saved.entries
        } else { throw WorkoutPersistenceError.invalidSnapshot }
        try WorkoutHistoryImportDecoder.validate(entries)
        return entries
    }
    static func encode(_ entries: [WorkoutHistoryEntry]) throws -> Data {
        try WorkoutHistoryImportDecoder.validate(entries)
        let data = try JSONEncoder().encode(Envelope(format: "zeroone-workout-history",
            version: currentVersion, entries: entries))
        guard data.count <= 64 * 1_024 * 1_024 else { throw WorkoutPersistenceError.invalidSnapshot }
        return data
    }
}

struct UserDefaultsWorkoutHistoryStore: WorkoutHistoryPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.workoutHistory") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [WorkoutHistoryEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try WorkoutHistoryStorageCodec.decode(data)
    }

    // Legacy adapter. Production completion uses the atomic file store below.
    func save(_ entries: [WorkoutHistoryEntry]) throws {
        _ = try load()
        let data = try WorkoutHistoryStorageCodec.encode(entries)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
    }

    var isAvailable: Bool {
        guard let data = defaults.data(forKey: key) else { return true }
        return (try? WorkoutHistoryStorageCodec.decode(data)) != nil
    }
}

struct RecordedExercisePerformance: Equatable {
    let sessionID: UUID
    let sessionTitle: String
    let completedAt: Date
    let occurrences: [WorkoutHistoryExercise]
    let hasNewerUnknownDetails: Bool
    let executionCompleteness: WorkoutExecutionCompleteness
    let executionCompletionConfirmedAt: Date?
    // Exact acknowledged source is required for progression fingerprints.
    let sourceEntry: WorkoutHistoryEntry?

    init(sessionID: UUID, sessionTitle: String, completedAt: Date,
         occurrences: [WorkoutHistoryExercise], hasNewerUnknownDetails: Bool,
         executionCompleteness: WorkoutExecutionCompleteness = .unknown,
         executionCompletionConfirmedAt: Date? = nil, sourceEntry: WorkoutHistoryEntry? = nil) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.completedAt = completedAt
        self.occurrences = occurrences
        self.hasNewerUnknownDetails = hasNewerUnknownDetails
        self.executionCompleteness = executionCompleteness
        self.executionCompletionConfirmedAt = executionCompletionConfirmedAt
        self.sourceEntry = sourceEntry
    }

    var latestSavedSet: CompletedSet? {
        occurrences.flatMap(\.completedSets).max { left, right in
            if left.completedAt != right.completedAt { return left.completedAt < right.completedAt }
            return left.id.uuidString < right.id.uuidString
        }
    }
}

enum PreviousExercisePerformanceState: Equatable {
    case unavailable
    case noRecordedSets(hasUnknownDetails: Bool)
    case recorded(RecordedExercisePerformance)
}

enum WorkoutPersistenceFiles {
    static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            guard failure.isMissingFile else {
                throw error
            }
            return nil
        }
    }

    static func file(_ name: String, directory: URL?) throws -> URL {
        let root: URL
        if let directory {
            root = directory
        } else {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Slick/Workouts", isDirectory: true)
        }
        return root.appendingPathComponent(name)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw WorkoutPersistenceError.verificationFailed }
    }
}

struct FileWorkoutHistoryStore: WorkoutHistoryPersisting {
    let directory: URL?
    let legacyStore: any WorkoutHistoryPersisting

    init(directory: URL? = nil, legacyStore: any WorkoutHistoryPersisting = UserDefaultsWorkoutHistoryStore()) {
        self.directory = directory
        self.legacyStore = legacyStore
    }

    func load() throws -> [WorkoutHistoryEntry] {
        let url = try WorkoutPersistenceFiles.file("history.json", directory: directory)
        guard let data = try WorkoutPersistenceFiles.readIfPresent(url) else {
            guard legacyStore.isAvailable else { throw WorkoutPersistenceError.unavailable }
            return try legacyStore.load()
        }
        return try WorkoutHistoryStorageCodec.decode(data)
    }

    func save(_ entries: [WorkoutHistoryEntry]) throws {
        // Never replace unreadable history or erase the original legacy payload.
        _ = try load()
        let data = try WorkoutHistoryStorageCodec.encode(entries)
        try WorkoutPersistenceFiles.write(data, to: WorkoutPersistenceFiles.file("history.json", directory: directory))
    }
}

@MainActor
@Observable
final class WorkoutHistoryRepository {
    private(set) var entries: [WorkoutHistoryEntry]
    private(set) var availability: WorkoutHistoryAvailability
    private let store: any WorkoutHistoryPersisting
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    init(store: any WorkoutHistoryPersisting = FileWorkoutHistoryStore()) {
        self.store = store
        do {
            guard store.isAvailable else { throw WorkoutPersistenceError.unavailable }
            entries = try store.load().sorted(by: WorkoutHistoryEntry.newestFirst)
            availability = .available
        } catch {
            entries = []
            availability = .unavailable
        }
    }

    /// This capability revokes retained permits synchronously; it never grants export.
    /// Replacement/removal revokes old and incoming permits before changing ownership.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Root must verify the exact nonnil installed capability before granting export.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    var surfaceState: WorkoutHistorySurfaceState {
        switch availability {
        case .unavailable:
            .unavailable
        case .available where entries.isEmpty:
            .empty
        case .available:
            .entries(entries.map(WorkoutHistoryDisplayItem.init))
        }
    }

    @discardableResult
    func record(_ session: WorkoutSession) throws -> WorkoutHistoryRecordResult {
        shareRevocationRegistration?.revokeBeforeChange()
        guard session.isComplete else { throw WorkoutPersistenceError.incompleteSession }
        guard store.isAvailable else { throw WorkoutPersistenceError.unavailable }
        // Re-read on retry: a previous write may have succeeded before an interruption.
        let persisted = try store.load()
        let entry = WorkoutHistoryEntry(session: session)
        if let existing = persisted.first(where: { $0.id == entry.id }) {
            // A legacy summary is not permission to invent or overwrite historical details.
            guard existing.hasSameSummary(as: entry),
                  existing.exercises.map({ saved in
                      let current = entry.exercises ?? []
                      return saved.count == current.count
                          && zip(saved, current).allSatisfy { $0.hasSameRecordedSets(as: $1) }
                  }) ?? true,
                  existing.warmUp == nil || existing.warmUp == entry.warmUp else {
                throw WorkoutPersistenceError.conflictingSession
            }
            entries = persisted.sorted(by: WorkoutHistoryEntry.newestFirst)
            availability = .available
            return .alreadyRecorded
        }
        let updated = ([entry] + persisted).sorted(by: WorkoutHistoryEntry.newestFirst)
        try store.save(updated)
        entries = updated
        availability = .available
        return .inserted
    }

    /// Notification actions must validate fresh persistence, not a launch-time cache.
    func confirmedEntries() throws -> [WorkoutHistoryEntry] {
        do {
            guard store.isAvailable else { throw WorkoutPersistenceError.unavailable }
            let current = try store.load().sorted(by: WorkoutHistoryEntry.newestFirst)
            // Unchanged authorization reads preserve the current permit. Changed or
            // recovered authority revokes before publishing any cache/readiness state.
            if current != entries || availability != .available {
                shareRevocationRegistration?.revokeBeforeChange()
            }
            entries = current
            availability = .available
            return current
        } catch {
            shareRevocationRegistration?.revokeBeforeChange()
            availability = .unavailable
            throw error
        }
    }

    /// Latest acknowledged session containing recorded sets for this exact exercise identity.
    /// Repeated occurrences stay separate; legacy summaries cannot establish exercise presence.
    func previousPerformance(
        for exerciseID: ExerciseID, excluding sessionID: UUID? = nil
    ) -> PreviousExercisePerformanceState {
        guard availability == .available else { return .unavailable }
        var hasUnknownDetails = false
        // Known, not unknown: a newer skipped occurrence still stops older sets counting as latest.
        var hasNewerSkippedOccurrence = false
        for entry in entries {
            if entry.id == sessionID { continue }
            guard let exercises = entry.exercises else {
                hasUnknownDetails = true
                continue
            }
            let occurrences = exercises.filter { $0.exerciseID == exerciseID }
            guard occurrences.contains(where: { !$0.completedSets.isEmpty }) else {
                if !occurrences.isEmpty { hasNewerSkippedOccurrence = true }
                continue
            }
            return .recorded(RecordedExercisePerformance(
                sessionID: entry.id, sessionTitle: entry.title, completedAt: entry.completedAt,
                occurrences: occurrences, hasNewerUnknownDetails: hasUnknownDetails || hasNewerSkippedOccurrence,
                executionCompleteness: entry.executionCompleteness,
                executionCompletionConfirmedAt: entry.executionCompletionConfirmedAt, sourceEntry: entry
            ))
        }
        return .noRecordedSets(hasUnknownDetails: hasUnknownDetails)
    }
}
