import Foundation

enum WorkoutAdaptationError: Error, Equatable {
    case workoutAlreadyStarted
    case workoutCompleted
    case invalidTimeWindow
    case invalidPrescription
    case cannotFitTimeWindow
    case staleProposal
}

struct WorkoutAdaptationProposal: Codable, Equatable, Sendable {
    let targetMinutes: Int
    let originalSession: WorkoutSession
    let adaptedSession: WorkoutSession
    let changes: [String]
}

struct DeterministicWorkoutAdapter {
    func proposal(
        for session: WorkoutSession,
        targetMinutes: Int = 30
    ) throws -> WorkoutAdaptationProposal {
        guard !session.isComplete else { throw WorkoutAdaptationError.workoutCompleted }
        guard session.completedSetCount == 0 else { throw WorkoutAdaptationError.workoutAlreadyStarted }

        guard (5 ... 180).contains(targetMinutes) else { throw WorkoutAdaptationError.invalidTimeWindow }
        let estimator = WorkoutTimeEstimator()
        guard estimator.estimate(for: session) != nil else { throw WorkoutAdaptationError.invalidPrescription }
        var retainedExercises = session.exercises
        // Preserve authored order and rest. Trim later sets first, then later
        // movements. Order is not claimed to be a personalised priority score.
        while let estimate = estimator.estimate(plans: retainedExercises.map(\.plan), warmUp: session.warmUp),
              !estimate.fitsWithin(minutes: targetMinutes) {
            if let index = retainedExercises.lastIndex(where: { $0.plan.plannedSetCount > 1 }) {
                let exercise = retainedExercises[index]
                retainedExercises[index] = WorkoutExercise(
                    plan: adaptedPlan(exercise.plan, sets: exercise.plan.plannedSetCount - 1),
                    // Undoing a swap must retain this separately accepted set reduction.
                    originalPlan: exercise.originalPlan.map { adaptedPlan($0, sets: min($0.plannedSetCount, exercise.plan.plannedSetCount - 1)) },
                    substitutionInput: exercise.substitutionInput
                )
            } else if retainedExercises.count > 1 {
                retainedExercises.removeLast()
            } else {
                throw WorkoutAdaptationError.cannotFitTimeWindow
            }
        }
        guard let estimate = estimator.estimate(plans: retainedExercises.map(\.plan), warmUp: session.warmUp),
              estimate.fitsWithin(minutes: targetMinutes) else { throw WorkoutAdaptationError.cannotFitTimeWindow }
        let adaptedExercises = retainedExercises

        let originalSets = session.totalPlannedSetCount
        let adaptedSets = adaptedExercises.reduce(0) { $0 + $1.plan.plannedSetCount }
        var changes = [
            originalSets.formatted() + " to " + adaptedSets.formatted() + " working sets",
            "Prescribed rest retained",
            "Estimated within " + targetMinutes.formatted() + " minutes"
        ]

        if session.exercises.count > adaptedExercises.count {
            changes.append(
                (session.exercises.count - adaptedExercises.count).formatted()
                    + " later exercise removed"
            )
        }

        let adaptedSession = WorkoutSession(
            id: session.id,
            title: session.title + " · " + targetMinutes.formatted() + " min",
            programmeID: session.programmeID,
            programmeProvenance: session.programmeProvenance?.retaining(adaptedExercises.map(\.id)),
            customWorkoutID: session.customWorkoutID,
            targetDurationMinutes: targetMinutes,
            isAdapted: true,
            warmUp: session.warmUp,
            exercises: adaptedExercises
        )

        return WorkoutAdaptationProposal(
            targetMinutes: targetMinutes,
            originalSession: session,
            adaptedSession: adaptedSession,
            changes: changes
        )
    }

    private func adaptedPlan(_ plan: ExercisePlan, sets: Int) -> ExercisePlan {
        ExercisePlan(
            id: plan.id,
            exerciseID: plan.exerciseID,
            name: plan.name,
            targetLoad: plan.targetLoad,
            targetReps: plan.targetReps,
            plannedSetCount: sets,
            restSeconds: plan.restSeconds,
            previousPerformance: plan.previousPerformance,
            sourcePrescription: plan.sourcePrescription,
            coachingCue: plan.coachingCue,
            painGuardrail: plan.painGuardrail,
            equipmentIdentifiers: plan.equipmentIdentifiers,
            alternativeExerciseIDs: plan.alternativeExerciseIDs,
            unresolvedAlternativeNames: plan.unresolvedAlternativeNames,
            targetPrescription: plan.targetPrescription
        )
    }
}
