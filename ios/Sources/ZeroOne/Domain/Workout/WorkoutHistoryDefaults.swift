import Foundation

/// Restore comparable acknowledged work without treating it as permission to
/// increase a load. Explicit custom targets remain the person's current choice.
struct WorkoutHistoryDefaults: Sendable {
    func apply(to plan: ExercisePlan, history: [WorkoutHistoryEntry], asOf: Date) -> ExercisePlan {
        guard asOf.timeIntervalSinceReferenceDate.isFinite else { return plan }
        for entry in history.sorted(by: WorkoutHistoryEntry.newestFirst) {
            guard entry.completedAt <= asOf,
                  entry.completedAt.timeIntervalSinceReferenceDate.isFinite else { continue }
            // A newer summary creates uncertainty; do not reach past it to
            // resurrect an older target as if that were the latest performance.
            guard let exercises = entry.exercises else { return plan }
            let occurrences = exercises.filter { $0.exerciseID == plan.exerciseID && !$0.completedSets.isEmpty }
            guard !occurrences.isEmpty else { continue }
            let exact = occurrences.first { $0.id == plan.id }
            guard let occurrence = exact ?? (occurrences.count == 1 ? occurrences.first : nil),
                  let last = occurrence.completedSets.last,
                  asOf.timeIntervalSince(entry.completedAt) <= 42 * 86_400,
                  Set(occurrence.completedSets.map(\.id)).count == occurrence.completedSets.count,
                  occurrence.completedSets.allSatisfy({
                      $0.completedAt <= entry.completedAt && $0.completedAt.timeIntervalSinceReferenceDate.isFinite
                          && $0.load.value.isFinite && (0 ... 2_000).contains($0.load.value)
                          && $0.load.unit == plan.targetLoad.unit
                          && (0 ... 5).contains($0.rir ?? 0)
                          && ($0.isPerSide ?? occurrence.targetPrescription?.perSide) == plan.prescription.perSide
                          && $0.isTimed == plan.isTimed
                          && (plan.isTimed ? (1 ... 86_400).contains($0.durationSeconds ?? 0) : (1 ... 50).contains($0.reps))
                  }) else { return plan }
            let load = plan.targetLoad.value == 0 && !plan.allowsZeroLoad ? last.load : plan.targetLoad
            return ExercisePlan(
                id: plan.id, exerciseID: plan.exerciseID, name: plan.name,
                targetLoad: load, targetReps: plan.targetReps,
                plannedSetCount: plan.plannedSetCount, restSeconds: plan.restSeconds,
                previousPerformance: plan.isTimed ? [] : occurrence.completedSets.map {
                    PreviousSetPerformance(id: $0.id, load: $0.load, reps: $0.reps)
                }, sourcePrescription: plan.sourcePrescription, coachingCue: plan.coachingCue,
                painGuardrail: plan.painGuardrail, equipmentIdentifiers: plan.equipmentIdentifiers,
                alternativeExerciseIDs: plan.alternativeExerciseIDs,
                unresolvedAlternativeNames: plan.unresolvedAlternativeNames,
                targetPrescription: plan.targetPrescription
            )
        }
        return plan
    }
}
