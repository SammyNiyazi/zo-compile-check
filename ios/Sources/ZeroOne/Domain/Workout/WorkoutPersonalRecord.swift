import Foundation

/// The evidence behind Freak's "New PR" slam (study 30 tokens, themes.freak.celebration).
/// A finished workout earns it only when a saved working set beats an earlier set of the
/// same exercise and no earlier set matches or beats it (the share card's PR rule).
/// Unknown history never earns it: unreadable History, or any earlier workout saved
/// without exercise detail, could hide a better set.
enum WorkoutPersonalRecord {
    static func isEarned(exercises: [WorkoutExercise], sessionID: UUID, completedAt: Date?,
                         history: [WorkoutHistoryEntry], historyAvailable: Bool) -> Bool {
        guard historyAvailable, let completedAt, completedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        let earlier = history.filter { $0.id != sessionID && $0.completedAt < completedAt }
        guard earlier.allSatisfy({ $0.exercises != nil }) else { return false }
        return exercises.contains { exercise in
            guard !exercise.completedSets.isEmpty else { return false }
            let previous = earlier.flatMap { entry in
                (entry.exercises ?? []).filter { $0.exerciseID == exercise.plan.exerciseID }.flatMap(\.completedSets)
            }
            return SocialShareAnalysis.isPersonalRecord(current: exercise.completedSets, previous: previous)
        }
    }
}
