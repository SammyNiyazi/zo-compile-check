import Foundation

/// Counts from acknowledged saved sessions, not total weekly activity coverage.
/// Summary-only history can establish a recorded set count, but never effort.
struct StrengthWorkloadWindow: Equatable, Sendable {
    var sessionCount = 0
    var recordedSetCount = 0
    var detailedSetCount = 0
    var repetitionSetCount = 0
    var effortReportedSetCount = 0
    var lowReserveSetCount = 0
    var summaryOnlySessionCount = 0
    var restTimers = WorkoutRestTimerWorkload()
}

/// Unpaused recorder time is not moving time or cardiovascular intensity.
/// Distances with gaps remain partial; nil distances never become zero travel.
struct OutdoorModalityWorkload: Equatable, Sendable {
    var sessionCount = 0
    var unpausedSeconds: TimeInterval = 0
    var completeDistanceSessionCount = 0
    var partialDistanceSessionCount = 0
    var unknownDistanceSessionCount = 0
    var clockDiscrepancySessionCount = 0
}

struct OutdoorWorkloadWindow: Equatable, Sendable {
    var runs = OutdoorModalityWorkload()
    var walks = OutdoorModalityWorkload()
}

/// A narrow comparison of the last three known exposures at the same actual
/// loads, prescribed work/rest, exercise order and reported effort. Actual rest,
/// equipment setup, technique and environment remain unmeasured.
struct ComparableStrengthTrend: Identifiable, Equatable, Sendable {
    var id: ExerciseID { exerciseID }
    let exerciseID: ExerciseID
    let sourceSessionIDs: [UUID] // Oldest to newest.
    let recordedRepetitions: [Int]
    let hasRepeatedDecline: Bool
    /// Ordered incoming countdown facts. Unknown intervals remain explicit;
    /// matching signatures do not prove matching physical rest or technique.
    let incomingTimerContexts: [WorkoutIncomingTimerContext]

    var hasUnknownIncomingTimerContext: Bool { incomingTimerContexts.contains(.unknown) }
}

struct TrainingWorkloadAssessment: Equatable, Sendable {
    let evaluatedAt: Date
    let currentWindowStart: Date
    let previousWindowStart: Date
    // Nil means source unavailable or too large to validate. Empty known
    // windows mean no qualifying saved records, not no actual activity.
    let currentStrength: StrengthWorkloadWindow?
    let previousStrength: StrengthWorkloadWindow?
    let currentOutdoor: OutdoorWorkloadWindow?
    let previousOutdoor: OutdoorWorkloadWindow?
    let excludedStrengthRecordCount: Int
    let excludedOutdoorRecordCount: Int
    let comparableStrengthTrends: [ComparableStrengthTrend]
    let recordedTrainingDays: Set<Date>

    var hasRepeatedComparableDecline: Bool {
        comparableStrengthTrends.contains { $0.hasRepeatedDecline }
    }
}

enum TrainingWorkloadEvidence {
    static let policyVersion = "recorded-workload-v2"

    static func assess(strength: [WorkoutHistoryEntry]?, outdoor: [OutdoorActivityRecord]?,
                       at now: Date, calendar: Calendar) -> TrainingWorkloadAssessment? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let currentStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
              let previousStart = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)),
              let trendStart = calendar.date(byAdding: .day, value: -27, to: calendar.startOfDay(for: now)) else { return nil }
        let strengthRecords = validatedStrength(strength, at: now)
        let outdoorRecords = validatedOutdoor(outdoor, at: now)
        let currentStrength = strengthRecords.entries.map { strengthWindow($0, from: currentStart, before: nil) }
        let previousStrength = strengthRecords.entries.map { strengthWindow($0, from: previousStart, before: currentStart) }
        let currentOutdoor = outdoorRecords.entries.map { outdoorWindow($0, from: currentStart, before: nil) }
        let previousOutdoor = outdoorRecords.entries.map { outdoorWindow($0, from: previousStart, before: currentStart) }
        var trainingDays: Set<Date> = []
        for entry in strengthRecords.entries ?? [] where entry.completedAt >= currentStart && entry.completedSetCount > 0 {
            trainingDays.insert(calendar.startOfDay(for: entry.completedAt))
        }
        for entry in outdoorRecords.entries ?? [] where entry.finishedAt >= currentStart && entry.kind == .run
            && entry.confirmedActiveSeconds >= 1_200 && !hasClockDiscrepancy(entry) {
            trainingDays.insert(calendar.startOfDay(for: entry.finishedAt))
        }
        // A rejected source may be a newer exposure. Do not reach past it for
        // a favourable or concerning trend. Exact duplicates collapse once.
        let trends = strengthRecords.excluded == 0
            ? comparableTrends(strengthRecords.entries ?? [], since: trendStart, recentStart: currentStart) : []
        return TrainingWorkloadAssessment(evaluatedAt: now, currentWindowStart: currentStart,
            previousWindowStart: previousStart, currentStrength: currentStrength, previousStrength: previousStrength,
            currentOutdoor: currentOutdoor, previousOutdoor: previousOutdoor,
            excludedStrengthRecordCount: strengthRecords.excluded, excludedOutdoorRecordCount: outdoorRecords.excluded,
            comparableStrengthTrends: trends, recordedTrainingDays: trainingDays)
    }

    private static func validatedStrength(_ input: [WorkoutHistoryEntry]?, at now: Date)
        -> (entries: [WorkoutHistoryEntry]?, excluded: Int) {
        guard let input, input.count <= 100_000 else { return (nil, 0) }
        var result: [WorkoutHistoryEntry] = []
        var excluded = 0
        for group in Dictionary(grouping: input, by: \.id).values {
            guard let entry = group.first, group.allSatisfy({ $0 == entry }),
                  validStrength(entry, at: now) else { excluded += 1; continue }
            result.append(entry)
        }
        // Set identities identify performed work globally. Programme exercise
        // occurrence IDs may legitimately recur, but a performed set cannot
        // become two sessions merely because a local/imported session ID differs.
        var owners: [UUID: UUID] = [:]
        var conflictingSessions: Set<UUID> = []
        for entry in result {
            for exercise in entry.exercises ?? [] {
                for set in exercise.completedSets {
                    if let existing = owners[set.id], existing != entry.id {
                        conflictingSessions.insert(existing)
                        conflictingSessions.insert(entry.id)
                    } else { owners[set.id] = entry.id }
                }
            }
        }
        excluded += conflictingSessions.count
        result.removeAll { conflictingSessions.contains($0.id) }
        return (result.sorted(by: WorkoutHistoryEntry.newestFirst), excluded)
    }

    private static func validStrength(_ entry: WorkoutHistoryEntry, at now: Date) -> Bool {
        guard entry.completedAt.timeIntervalSinceReferenceDate.isFinite, entry.completedAt <= now,
              (0 ... 5_000).contains(entry.completedSetCount),
              (1 ... 5_000).contains(entry.plannedSetCount), entry.completedSetCount <= entry.plannedSetCount,
              entry.executionCompletionConfirmedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 <= now }) ?? true else { return false }
        guard let exercises = entry.exercises else { return entry.executionCompletionConfirmedAt == nil }
        guard exercises.count <= 500, Set(exercises.map(\.id)).count == exercises.count else { return false }
        // Bound before flattening or adding attacker-controlled imported arrays.
        var total = 0
        for exercise in exercises {
            guard exercise.completedSets.count <= entry.completedSetCount - total,
                  !exercise.exerciseID.rawValue.isEmpty, exercise.exerciseID.rawValue.utf8.count <= 4_096 else { return false }
            total += exercise.completedSets.count
        }
        let sets = exercises.flatMap(\.completedSets)
        guard total == entry.completedSetCount, Set(sets.map(\.id)).count == sets.count,
              entry.executionCompleteness != .inconsistent else { return false }
        return exercises.allSatisfy { exercise in
            var previousDate: Date?
            return exercise.completedSets.allSatisfy { set in
                defer { previousDate = set.completedAt }
                return set.completedAt.timeIntervalSinceReferenceDate.isFinite && set.completedAt <= entry.completedAt
                    && (previousDate.map { set.completedAt >= $0 } ?? true)
                    && set.load.value.isFinite && (0 ... 2_000).contains(set.load.value)
                    && (set.isTimed
                        ? (1 ... 86_400).contains(set.durationSeconds ?? 0) && set.reps == 0 && set.rir == nil
                        : (1 ... 100).contains(set.reps) && (set.rir.map { (0 ... 5).contains($0) } ?? true))
                    && (set.executionTarget.map { $0.matches(set, exerciseID: exercise.exerciseID, occurrenceID: exercise.id) } ?? true)
                    && WorkoutRestTimerEvidence.validStoredObservation(for: set, finishedAt: entry.completedAt)
            }
        }
    }

    private static func validatedOutdoor(_ input: [OutdoorActivityRecord]?, at now: Date)
        -> (entries: [OutdoorActivityRecord]?, excluded: Int) {
        guard let input, input.count <= 100_000 else { return (nil, 0) }
        var result: [OutdoorActivityRecord] = []
        var excluded = 0
        for group in Dictionary(grouping: input, by: \.id).values {
            guard let entry = group.first, group.allSatisfy({ $0 == entry }), entry.isValid,
                  entry.startedAt <= now, entry.finishedAt <= now,
                  entry.confirmedActiveSeconds <= 7 * 86_400 else { excluded += 1; continue }
            result.append(entry)
        }
        return (result, excluded)
    }

    private static func strengthWindow(_ entries: [WorkoutHistoryEntry], from start: Date, before end: Date?) -> StrengthWorkloadWindow {
        var window = StrengthWorkloadWindow()
        for entry in entries where entry.completedAt >= start && (end.map { entry.completedAt < $0 } ?? true) {
            window.sessionCount += 1
            window.recordedSetCount += entry.completedSetCount
            guard let exercises = entry.exercises else {
                window.summaryOnlySessionCount += 1
                window.restTimers.unknownSetCount += entry.completedSetCount
                continue
            }
            let sets = exercises.flatMap(\.completedSets)
            window.detailedSetCount += sets.count
            for (index, set) in sets.enumerated() {
                let next = index + 1 < sets.count ? sets[index + 1].completedAt : entry.completedAt
                window.restTimers.include(set, before: next)
            }
            for set in sets where !set.isTimed {
                window.repetitionSetCount += 1
                if let reserve = set.rir {
                    window.effortReportedSetCount += 1
                    if reserve <= 1 { window.lowReserveSetCount += 1 }
                }
            }
        }
        return window
    }

    private static func hasClockDiscrepancy(_ entry: OutdoorActivityRecord) -> Bool {
        entry.startedAt > entry.finishedAt
            || entry.confirmedActiveSeconds > entry.finishedAt.timeIntervalSince(entry.startedAt) + 1
    }

    private static func outdoorWindow(_ entries: [OutdoorActivityRecord], from start: Date, before end: Date?) -> OutdoorWorkloadWindow {
        var window = OutdoorWorkloadWindow()
        for entry in entries where entry.finishedAt >= start && (end.map { entry.finishedAt < $0 } ?? true) {
            var modality = entry.kind == .run ? window.runs : window.walks
            modality.sessionCount += 1
            modality.unpausedSeconds += entry.confirmedActiveSeconds
            if entry.recordedDistanceMeters == nil { modality.unknownDistanceSessionCount += 1 }
            else if entry.hasMissingLocationCoverage { modality.partialDistanceSessionCount += 1 }
            else { modality.completeDistanceSessionCount += 1 }
            if hasClockDiscrepancy(entry) { modality.clockDiscrepancySessionCount += 1 }
            if entry.kind == .run { window.runs = modality } else { window.walks = modality }
        }
        return window
    }

    private struct Exposure {
        let entry: WorkoutHistoryEntry
        let occurrence: WorkoutHistoryExercise
        let target: WorkingSetExecutionTarget
        let loads: [Load]
        let reserves: [Int]
        let repetitions: Int
        let order: [ExerciseID]
        let incomingTimerContexts: [WorkoutIncomingTimerContext]

        func isComparable(to other: Self) -> Bool {
            entry.programmeID == other.entry.programmeID && entry.title == other.entry.title
                && order == other.order && loads == other.loads && reserves == other.reserves
                && target.prescription == other.target.prescription
                && target.plannedSetCount == other.target.plannedSetCount && target.restSeconds == other.target.restSeconds
                && target.targetLoad == other.target.targetLoad
                && incomingTimerContexts == other.incomingTimerContexts
        }
    }

    private static func exposure(_ entry: WorkoutHistoryEntry, for exerciseID: ExerciseID) -> Exposure? {
        guard entry.executionCompleteness == .confirmedComplete, let exercises = entry.exercises,
              let occurrence = exercises.first(where: { $0.exerciseID == exerciseID }),
              exercises.filter({ $0.exerciseID == exerciseID }).count == 1,
              let first = occurrence.completedSets.first, let target = first.executionTarget,
              target.prescription.unit == .repetitions, target.prescription.upperBound <= 50,
              occurrence.targetPrescription == target.prescription,
              occurrence.plannedSetCount == target.plannedSetCount,
              occurrence.completedSets.count == target.plannedSetCount else { return nil }
        let sets = occurrence.completedSets
        guard sets.allSatisfy({ !$0.isTimed && $0.executionTarget == target && $0.rir != nil
            && $0.load.value > 0 && $0.load.unit == first.load.unit && $0.reps <= 50 }) else { return nil }
        guard let timerContexts = WorkoutRestTimerEvidence.incomingContexts(in: entry, occurrenceID: occurrence.id),
              timerContexts.count == sets.count, WorkoutRestTimerEvidence.permitsComparison(timerContexts) else { return nil }
        return Exposure(entry: entry, occurrence: occurrence, target: target, loads: sets.map(\.load),
            reserves: sets.compactMap(\.rir), repetitions: sets.reduce(0) { $0 + $1.reps }, order: exercises.map(\.exerciseID),
            incomingTimerContexts: timerContexts)
    }

    private static func comparableTrends(_ entries: [WorkoutHistoryEntry], since start: Date, recentStart: Date) -> [ComparableStrengthTrend] {
        let recent = entries.filter { $0.completedAt >= start }
        let exerciseIDs = Set(recent.filter { $0.completedAt >= recentStart }.flatMap { ($0.exercises ?? []).map(\.exerciseID) })
        return exerciseIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { exerciseID in
            // Summary-only records are an unknown exposure barrier. Never
            // assume that an unlogged exercise or repeated occurrence was skipped.
            let candidates = recent.filter { $0.exercises == nil || $0.exercises?.isEmpty == true
                || $0.exercises?.contains(where: { $0.exerciseID == exerciseID }) == true }
            let selected = Array(candidates.prefix(3))
            guard selected.count == 3, selected[0].completedAt >= recentStart,
                  selected[0].completedAt > selected[1].completedAt, selected[1].completedAt > selected[2].completedAt else { return nil }
            let exposures = selected.compactMap { exposure($0, for: exerciseID) }
            guard exposures.count == 3, exposures[0].isComparable(to: exposures[1]), exposures[1].isComparable(to: exposures[2]) else { return nil }
            let oldestFirst = exposures.reversed()
            let repetitions = oldestFirst.map(\.repetitions)
            // Product review threshold only, not a validated fatigue test.
            let declines = zip(repetitions, repetitions.dropFirst()).allSatisfy {
                $0.0 - $0.1 >= 2 && Double($0.1) <= Double($0.0) * 0.90
            }
            return ComparableStrengthTrend(exerciseID: exerciseID, sourceSessionIDs: oldestFirst.map { $0.entry.id },
                recordedRepetitions: repetitions, hasRepeatedDecline: declines,
                incomingTimerContexts: exposures[0].incomingTimerContexts)
        }
    }
}
