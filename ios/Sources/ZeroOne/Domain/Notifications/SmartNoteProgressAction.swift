import Foundation

struct SmartNoteProgressEvidence: Codable, Equatable, Sendable {
    let plan: ExercisePlan
    let opportunity: WorkoutProgressionOpportunity
}

enum SmartNoteProgressActionResult: Equatable {
    case saved(Load, undo: WorkoutLoadChoiceUndo?)
    case stale
    case unavailable
    case workoutActive
    case policyHold

    var savedLoad: Load? {
        if case let .saved(load, _) = self { return load }
        return nil
    }
}

/// Resolves a notification against current local evidence, never its displayed copy.
/// The choice repository is also used by Progress and the next-workout planner.
struct SmartNoteProgressAction {
    static func upgrade(
        for note: SmartNoteCandidate, history: [WorkoutHistoryEntry],
        programmeID: WorkoutProgrammeID?, now: Date,
        progressionReviews: [WorkoutProgressionReview] = []
    ) -> (upgrade: WorkoutCompletionUpgrade, sessionID: UUID)? {
        guard note.kind == .progress, note.isCurrent, note.expiresAt > now,
              let programmeID, note.programmeID == programmeID.rawValue,
              let evidence = note.progressEvidence,
              let rawID = note.sessionID, let sourceID = UUID(uuidString: rawID),
              history.filter({ $0.id == sourceID }).count == 1,
              let source = history.first(where: { $0.id == sourceID }),
              source.programmeID == programmeID, source.completedAt <= now,
              let exercises = source.exercises else { return nil }
        let occurrences = exercises.filter { $0.exerciseID == evidence.plan.exerciseID }
        guard let occurrence = occurrences.first(where: { $0.id == evidence.opportunity.context?.occurrenceID }),
              occurrence.completedSets.last?.id == note.occurrenceID,
              occurrence.plannedSetCount == evidence.plan.plannedSetCount,
              !history.contains(where: { entry in
                  guard entry.id != sourceID, entry.completedAt >= source.completedAt else { return false }
                  guard let details = entry.exercises else { return true }
                  return details.contains { $0.exerciseID == evidence.plan.exerciseID }
              }) else { return nil }
        let performance = RecordedExercisePerformance(
            sessionID: source.id, sessionTitle: source.title, completedAt: source.completedAt,
            occurrences: occurrences, hasNewerUnknownDetails: false,
            executionCompleteness: source.executionCompleteness,
            executionCompletionConfirmedAt: source.executionCompletionConfirmedAt, sourceEntry: source
        )
        guard let opportunity = WorkoutProgressionEngine(reviews: progressionReviews, asOf: now).earnedOpportunity(
            for: evidence.plan, performance: performance
        ), opportunity == evidence.opportunity else { return nil }
        return (.init(exerciseID: evidence.plan.exerciseID, exerciseName: evidence.plan.name,
            opportunity: opportunity, completedSets: occurrence.completedSets,
            targetRepUpperBound: evidence.plan.targetReps.upperBound, plan: evidence.plan), sourceID)
    }

    @MainActor static func apply(
        _ selection: WorkoutLoadChoiceSelection, to note: SmartNoteCandidate,
        history: WorkoutHistoryRepository, choices: WorkoutLoadChoiceRepository,
        programmeID: WorkoutProgrammeID?, now: Date, workoutActive: Bool = false,
        progressionAllowed: Bool = true,
        progressionReviews: [WorkoutProgressionReview] = []
    ) -> SmartNoteProgressActionResult {
        guard !workoutActive else { return .workoutActive }
        guard progressionAllowed || selection == .repeatPrevious else { return .policyHold }
        guard let entries = try? history.confirmedEntries(), choices.reload() else { return .unavailable }
        guard let resolved = upgrade(for: note, history: entries, programmeID: programmeID, now: now,
            progressionReviews: progressionReviews) else { return .stale }
        guard choices.validates(selection, for: resolved.upgrade, sourceSessionID: resolved.sessionID) else { return .stale }
        let previous = choices.choices.first { $0.exerciseID == resolved.upgrade.exerciseID }
        var needsSave = true
        if let existing = choices.choices.first(where: { $0.exerciseID == resolved.upgrade.exerciseID }) {
            // A newer/different choice must never be overwritten by an old notification.
            if existing.sourceSessionID == resolved.sessionID {
                guard existing.matches(resolved.upgrade, sourceSessionID: resolved.sessionID),
                      existing.selection == selection else { return .stale }
                needsSave = false
            } else {
                guard let older = entries.first(where: { $0.id == existing.sourceSessionID }),
                      let source = entries.first(where: { $0.id == resolved.sessionID }),
                      older.completedAt < source.completedAt else { return .stale }
            }
        }
        if needsSave && !choices.choose(selection, for: resolved.upgrade, sourceSessionID: resolved.sessionID) {
            return .unavailable
        }
        let undo = needsSave ? choices.choices.first(where: { $0.exerciseID == resolved.upgrade.exerciseID }).map {
            WorkoutLoadChoiceUndo(expected: $0, previous: previous, createdAt: now)
        } : nil
        return .saved(selection == .tryNext
            ? resolved.upgrade.opportunity.suggestedLoad : resolved.upgrade.opportunity.previousLoad, undo: undo)
    }

    @MainActor static func undo(
        _ receipt: WorkoutLoadChoiceUndo, history: WorkoutHistoryRepository,
        choices: WorkoutLoadChoiceRepository, workoutActive: Bool
    ) -> Bool {
        guard !workoutActive, let entries = try? history.confirmedEntries(),
              let source = entries.first(where: { $0.id == receipt.expected.sourceSessionID }),
              !entries.contains(where: { entry in
                  guard entry.id != source.id, entry.completedAt >= source.completedAt else { return false }
                  guard let details = entry.exercises else { return true }
                  return details.contains { $0.exerciseID == receipt.expected.exerciseID && !$0.completedSets.isEmpty }
              }) else { return false }
        return choices.undo(receipt)
    }
}
