import Foundation

enum SmartNoteWorkoutSaveOrigin: Sendable {
    case liveWorkout
    case importedHistory
}

/// Call only after History.record returns its receipt for a live completion.
/// Pass the complete, freshly reloaded History and load-choice snapshots; nil
/// means a source is unavailable. Reading History on launch is not an event.
/// The host merges this output with other candidates before replaceCandidates,
/// then reconciles again whenever a choice or programme changes.
struct SmartNoteCandidates {
    static func progressAfterAcknowledgedSave(
        session: WorkoutSession,
        recordResult: WorkoutHistoryRecordResult,
        origin: SmartNoteWorkoutSaveOrigin,
        currentProgrammeID: WorkoutProgrammeID?,
        savedHistory: [WorkoutHistoryEntry]?,
        loadChoices: [WorkoutLoadChoice]?,
        records: [SmartNoteRecord],
        now: Date,
        calendar: Calendar,
        progressionReviews: [WorkoutProgressionReview] = []
    ) -> SmartNoteCandidate? {
        guard case .inserted = recordResult,
              case .liveWorkout = origin,
              let currentProgrammeID,
              session.programmeID == .some(currentProgrammeID),
              session.customWorkoutID == nil,
              let completedAt = session.completedAt,
              completedAt <= now,
              now.timeIntervalSince(completedAt) <= 10 * 60,
              let savedHistory, let loadChoices,
              savedHistory.filter({ $0.id == session.id }).count == 1,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: completedAt)),
              let deliveryDate = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: nextDay),
              let expiresAt = calendar.date(byAdding: .day, value: 1, to: nextDay),
              deliveryDate < expiresAt,
              deliveryDate > now else { return nil }

        let upgrades = WorkoutCompletionUpgrade.readyAfter(
            session: session, savedHistory: savedHistory, progressionReviews: progressionReviews, asOf: now
        )
        for upgrade in upgrades {
            guard let finalSet = upgrade.completedSets.last,
                  !loadChoices.contains(where: {
                      $0.matches(upgrade, sourceSessionID: session.id)
                  }),
                  !hasPriorMilestone(upgrade, before: completedAt, sessionID: session.id, in: savedHistory),
                  !savedHistory.contains(where: { entry in
                      guard entry.id != session.id, entry.completedAt >= completedAt else { return false }
                      // Newer summaries without details cannot establish that this is still current.
                      guard let exercises = entry.exercises else { return true }
                      return exercises.contains { $0.exerciseID == upgrade.exerciseID }
                  }) else { continue }

            let loadKey = String(upgrade.opportunity.previousLoad.value.bitPattern, radix: 16)
            let eventID = "progress.\(upgrade.exerciseID.rawValue).\(upgrade.opportunity.previousLoad.unit.rawValue).\(loadKey).\(upgrade.completedSets.count)x\(upgrade.targetRepUpperBound)"
            guard !records.contains(where: {
                $0.candidateID == eventID
                    && [.delivered, .opened, .cleared, .stopped].contains($0.outcome)
            }) else { continue }

            let completedLoad = loadText(upgrade.opportunity.previousLoad)
            let nextLoad = loadText(upgrade.opportunity.suggestedLoad)
            let setCount = upgrade.completedSets.count
            let repGoal = upgrade.targetRepUpperBound
            var candidate = SmartNoteCandidate(
                id: eventID,
                occurrenceID: finalSet.id,
                revision: 1,
                kind: .progress,
                title: "\(upgrade.exerciseName): ready for \(nextLoad)",
                body: "You saved \(setCount) sets at \(completedLoad), each with at least \(repGoal) reps. 01's progression rule suggests \(nextLoad) next time. Your choice.",
                directTitle: "\(upgrade.exerciseName): \(nextLoad) next",
                directBody: "\(setCount) saved sets at \(completedLoad), each with at least \(repGoal) reps. Choose the next load in 01.",
                reasons: [
                    "Workout History: all \(setCount) recorded sets reached \(repGoal) reps at \(completedLoad).",
                    "Training plan: the existing progression rule suggests \(nextLoad); no next-load choice is saved."
                ],
                unknowns: ["How recovered you are. This is a training suggestion, not a health assessment."],
                deliveryDate: deliveryDate,
                expiresAt: expiresAt,
                isRestDay: false,
                isCurrent: true,
                isFreshEvent: true,
                programmeID: currentProgrammeID.rawValue,
                sessionID: session.id.uuidString
            )
            if let plan = session.exercises.first(where: { $0.plan.exerciseID == upgrade.exerciseID })?.plan {
                candidate.progressEvidence = .init(plan: plan, opportunity: upgrade.opportunity)
            }
            return candidate
        }
        return nil
    }

    private static func loadText(_ load: Load) -> String {
        let value = load.value.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(value) \(load.unit.rawValue)"
    }

    private static func hasPriorMilestone(
        _ upgrade: WorkoutCompletionUpgrade,
        before completedAt: Date,
        sessionID: UUID,
        in history: [WorkoutHistoryEntry]
    ) -> Bool {
        let minimumEffortReserve = max(
            2, ExerciseLibrary.exercise(id: upgrade.exerciseID)?.defaultRIRRange.lowerBound ?? 2
        )
        for entry in history where entry.id != sessionID && entry.completedAt < completedAt {
            // An older summary without sets cannot prove that this milestone is new.
            guard let exercises = entry.exercises else { return true }
            if exercises.contains(where: { occurrence in
                occurrence.exerciseID == upgrade.exerciseID
                    && occurrence.completedSets.count >= upgrade.completedSets.count
                    && occurrence.completedSets.allSatisfy { set in
                        set.load.unit == upgrade.opportunity.previousLoad.unit
                            && set.load.value >= upgrade.opportunity.previousLoad.value
                            && set.reps >= upgrade.targetRepUpperBound
                            && (set.rir.map { $0 >= minimumEffortReserve } ?? true)
                    }
            }) { return true }
        }
        return false
    }
}
