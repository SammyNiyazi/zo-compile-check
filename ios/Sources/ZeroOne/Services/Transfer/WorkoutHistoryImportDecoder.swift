import Foundation
import CoreFoundation

/// Import reads only the workout projection. Other selected export categories
/// are reported as untouched and are never decoded into or written to live stores.
enum WorkoutHistoryImportDecoder {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    private static let maximumWorkouts = 10_000
    private static let maximumTotalSets = 250_000

    struct Source {
        let schemaVersion: Int
        let exportedAt: Date
        let entries: [WorkoutHistoryEntry]
        let untouchedCategories: [String]
    }

    private struct Projection: Decodable {
        let schemaVersion: Int
        let exportedAt: Date
        let workoutHistoryProvenance: String
        let completedWorkouts: [WorkoutHistoryEntry]
        let selection: LocalDataExportSelection?
    }

    static func decode(_ data: Data) throws -> Source {
        guard data.count <= maximumFileBytes else { throw WorkoutHistoryImportError.oversizedFile }
        do {
            var syntax = ImportJSONSyntax(data: data)
            try syntax.validate()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEntries = object["completedWorkouts"] as? [[String: Any]] else {
                throw WorkoutHistoryImportError.invalidFile
            }
            // Reject extra workout fields rather than silently dropping facts from
            // a newer producer while displaying an apparently lossless import.
            let package = try JSONDecoder().decode(Projection.self, from: data)
            guard (1...6).contains(package.schemaVersion) else { throw WorkoutHistoryImportError.unsupportedSchema }
            try validateRawEntries(rawEntries, allowsRestEvidence: package.schemaVersion >= 5,
                allowsProgrammeEvidence: package.schemaVersion >= 6)
            guard validDate(package.exportedAt) else { throw WorkoutHistoryImportError.invalidFile }
            guard package.workoutHistoryProvenance == "app-owned completed workout history" else {
                throw WorkoutHistoryImportError.workoutsNotSelected
            }
            guard package.selection?.workouts != false else { throw WorkoutHistoryImportError.workoutsNotSelected }
            if package.schemaVersion >= 2 && package.selection == nil { throw WorkoutHistoryImportError.invalidFile }
            try validate(package.completedWorkouts)
            var untouched: [String] = []
            if package.selection?.mealsAndWater == true || object["meals"] != nil || object["waterSnapshot"] != nil {
                untouched.append("Meals and water")
            }
            if package.selection?.bodyWeight == true || (object["bodyWeightReadings"] as? [Any])?.isEmpty == false {
                untouched.append("Body-weight readings")
            }
            if package.selection?.outdoorActivities == true || object["outdoorActivities"] != nil {
                untouched.append("Walks, runs and routes")
            }
            if package.selection?.goalsAndPreferences == true || object["goalsAndPreferences"] != nil {
                untouched.append("Goals and preferences")
            }
            return Source(schemaVersion: package.schemaVersion, exportedAt: package.exportedAt,
                entries: package.completedWorkouts.sorted(by: WorkoutHistoryEntry.newestFirst),
                untouchedCategories: untouched)
        } catch let error as WorkoutHistoryImportError { throw error }
        catch { throw WorkoutHistoryImportError.invalidFile }
    }

    static func validate(_ entries: [WorkoutHistoryEntry]) throws {
        guard entries.count <= maximumWorkouts, Set(entries.map(\.id)).count == entries.count else {
            throw WorkoutHistoryImportError.invalidHistory
        }
        var allSetIDs = Set<UUID>()
        var totalSets = 0
        for entry in entries {
            if let provenance = entry.programmeProvenance {
                guard entry.exercises != nil,
                      provenance.matches(programmeID: entry.programmeID, occurrenceIDs: (entry.exercises ?? []).map(\.id)) else {
                    throw WorkoutHistoryImportError.invalidHistory
                }
            }
            guard validDate(entry.completedAt), !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.title.utf8.count <= 4_096,
                  (0...maximumTotalSets).contains(entry.completedSetCount),
                  (1...maximumTotalSets).contains(entry.plannedSetCount),
                  entry.completedSetCount <= entry.plannedSetCount,
                  entry.targetDurationMinutes.map({ (1...10_080).contains($0) }) ?? true else {
                throw WorkoutHistoryImportError.invalidHistory
            }
            if let confirmed = entry.executionCompletionConfirmedAt {
                guard validDate(confirmed), confirmed >= entry.completedAt,
                      entry.executionCompleteness == .confirmedComplete else {
                    throw WorkoutHistoryImportError.invalidHistory
                }
            }
            // Bounds are checked before all additions, including summary-only
            // records, so downstream set-count aggregations cannot overflow.
            guard totalSets <= maximumTotalSets - entry.completedSetCount else {
                throw WorkoutHistoryImportError.invalidHistory
            }
            totalSets += entry.completedSetCount
            if let warmUp = entry.warmUp {
                guard (0...10_080).contains(warmUp.estimatedMinutes), warmUp.steps.count <= 1_000,
                      warmUp.steps.allSatisfy({ $0.utf8.count <= 4_096 }),
                      warmUp.resolvedAt.map({ validDate($0) && $0 <= entry.completedAt }) ?? true else {
                    throw WorkoutHistoryImportError.invalidHistory
                }
            }
            guard let exercises = entry.exercises else { continue }
            guard exercises.count <= 1_000, Set(exercises.map(\.id)).count == exercises.count else {
                throw WorkoutHistoryImportError.invalidHistory
            }
            var count = 0
            var planned = 0
            var hasAllPlannedCounts = true
            for exercise in exercises {
                guard !exercise.exerciseID.rawValue.isEmpty, exercise.exerciseID.rawValue.utf8.count <= 4_096,
                      exercise.completedSets.count <= maximumTotalSets,
                      exercise.targetPrescription?.isValid ?? true else { throw WorkoutHistoryImportError.invalidHistory }
                if let number = exercise.plannedSetCount {
                    guard (1...maximumTotalSets).contains(number), number >= exercise.completedSets.count,
                          planned <= maximumTotalSets - number else { throw WorkoutHistoryImportError.invalidHistory }
                    planned += number
                } else { hasAllPlannedCounts = false }
                guard count <= maximumTotalSets - exercise.completedSets.count else { throw WorkoutHistoryImportError.invalidHistory }
                count += exercise.completedSets.count
                for set in exercise.completedSets {
                    guard allSetIDs.insert(set.id).inserted, validDate(set.completedAt), set.completedAt <= entry.completedAt,
                          set.load.value.isFinite, (0...1_000_000).contains(set.load.value),
                          (0...86_400).contains(set.reps) else { throw WorkoutHistoryImportError.invalidHistory }
                    if let seconds = set.durationSeconds {
                        guard (1...86_400).contains(seconds), set.reps == 0, set.rir == nil else {
                            throw WorkoutHistoryImportError.invalidHistory
                        }
                    }
                    if let target = set.executionTarget {
                        guard target.matches(set, exerciseID: exercise.exerciseID, occurrenceID: exercise.id) else {
                            throw WorkoutHistoryImportError.invalidHistory
                        }
                    }
                    if let rest = set.restTimerObservation {
                        guard rest.isClosed, rest.isValid(for: set.id, completedAt: set.completedAt) else {
                            throw WorkoutHistoryImportError.invalidHistory
                        }
                    }
                    // Older raw RIR is copied as recorded, including out-of-range
                    // values. It is not normalized, clamped or converted to duration.
                }
            }
            guard count == entry.completedSetCount, planned <= entry.plannedSetCount,
                  !hasAllPlannedCounts || planned == entry.plannedSetCount else {
                throw WorkoutHistoryImportError.invalidHistory
            }
        }
    }

    private static func validDate(_ value: Date) -> Bool {
        let seconds = value.timeIntervalSinceReferenceDate
        return seconds.isFinite && (-62_000_000_000...100_000_000_000).contains(seconds)
    }

    private static func allowed(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys).isSubset(of: keys) else { throw WorkoutHistoryImportError.invalidHistory }
    }

    static func validateRawEntries(_ entries: [[String: Any]], allowsRestEvidence: Bool,
                                   allowsProgrammeEvidence: Bool = false) throws {
        for entry in entries { try validateRawEntry(entry, allowsRestEvidence: allowsRestEvidence,
            allowsProgrammeEvidence: allowsProgrammeEvidence) }
    }

    private static func validateRawEntry(_ entry: [String: Any], allowsRestEvidence: Bool, allowsProgrammeEvidence: Bool) throws {
        var entryKeys: Set<String> = ["id", "programmeID", "title", "completedAt", "completedSetCount", "plannedSetCount",
            "targetDurationMinutes", "wasAdapted", "warmUp", "exercises", "executionCompletionConfirmedAt"]
        if allowsProgrammeEvidence { entryKeys.insert("programmeProvenance") }
        try allowed(entry, entryKeys)
        if let warmUp = entry["warmUp"] as? [String: Any] {
            try allowed(warmUp, ["estimatedMinutes", "steps", "timedStepSeconds", "length", "status", "resolvedAt", "checkedStepIndices"])
            let steps = warmUp["steps"] as? [String] ?? []
            if let timers = warmUp["timedStepSeconds"] as? [Any] {
                guard timers.count == steps.count, timers.allSatisfy({ value in
                    if value is NSNull { return true }
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                    let seconds = number.doubleValue
                    return seconds.isFinite && (1.0...86_400.0).contains(seconds) && seconds.rounded(.towardZero) == seconds
                }) else { throw WorkoutHistoryImportError.invalidHistory }
            }
            if let indices = warmUp["checkedStepIndices"] as? [Int] {
                guard Set(indices).count == indices.count, indices.allSatisfy(steps.indices.contains) else {
                    throw WorkoutHistoryImportError.invalidHistory
                }
            }
        }
        for exercise in entry["exercises"] as? [[String: Any]] ?? [] {
            try allowed(exercise, ["id", "exerciseID", "completedSets", "plannedSetCount", "targetPrescription"])
            if let identifier = exercise["exerciseID"] as? [String: Any] { try allowed(identifier, ["rawValue"]) }
            if let prescription = exercise["targetPrescription"] as? [String: Any] {
                try allowed(prescription, ["unit", "lowerBound", "upperBound", "perSide"])
            }
            for set in exercise["completedSets"] as? [[String: Any]] ?? [] {
                var keys: Set<String> = ["id", "load", "reps", "rir", "completedAt", "durationSeconds", "isPerSide", "executionTarget"]
                if allowsRestEvidence { keys.insert("restTimerObservation") }
                try allowed(set, keys)
                if let load = set["load"] as? [String: Any] { try allowed(load, ["value", "unit"]) }
                if let target = set["executionTarget"] as? [String: Any] {
                    try allowed(target, ["occurrenceID", "exerciseID", "prescription", "plannedSetCount", "restSeconds", "targetLoad"])
                    if let identifier = target["exerciseID"] as? [String: Any] { try allowed(identifier, ["rawValue"]) }
                    if let prescription = target["prescription"] as? [String: Any] {
                        try allowed(prescription, ["unit", "lowerBound", "upperBound", "perSide"])
                    }
                    if let load = target["targetLoad"] as? [String: Any] { try allowed(load, ["value", "unit"]) }
                }
            }
        }
    }
}
