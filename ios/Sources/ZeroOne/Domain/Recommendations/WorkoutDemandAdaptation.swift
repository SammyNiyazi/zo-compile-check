import Foundation

enum WorkoutDemandChange: String, CaseIterable, Sendable {
    case fewerSets, longerRest

    var titleKey: String {
        switch self {
        case .fewerSets: "Fewer working sets"
        case .longerRest: "More rest between sets"
        }
    }
}

enum WorkoutDemandAdaptationError: Error, Equatable {
    case contextUnavailable, noCurrentConcern, symptomsNeedReview, workoutStarted
    case alreadyAdapted, invalidPrescription, noBoundedChange, staleProposal

    var messageKey: String {
        switch self {
        case .contextUnavailable: "Current recovery and food records could not be verified. Review your check-in before changing the workout."
        case .noCurrentConcern: "No current supported recovery concern qualifies this option. Your workout has been kept."
        case .symptomsNeedReview: "Review the reported pain or illness before choosing a training adjustment."
        case .workoutStarted: "Working sets have started. This option cannot rewrite performed work."
        case .alreadyAdapted: "Undo the current adjustment before reviewing another option."
        case .invalidPrescription: "The workout prescription could not be verified. Your workout has been kept."
        case .noBoundedChange: "This prescription has no supported change for that option. Resting today remains a choice."
        case .staleProposal: "The workout or recovery context changed. Review a fresh option before applying it."
        }
    }
}

/// An unaccepted option is transient. Only the explicitly accepted prescription
/// uses the existing recoverable workout/Undo snapshot, without changing a
/// saved programme, custom template, training schedule or performed history.
struct WorkoutDemandAdaptationProposal: Equatable, Sendable {
    let policyVersion: String
    let change: WorkoutDemandChange
    let offeredAt: Date
    let timeZoneID: String
    let concerns: [WellbeingRecommendation]
    var energyTargetSource: String? = nil
    let originalSession: WorkoutSession
    let adaptedSession: WorkoutSession
    let originalEstimate: WorkoutTimeEstimate
    let adaptedEstimate: WorkoutTimeEstimate
}

struct WorkoutDemandAdapter: Sendable {
    static let policyVersion = "recovery-workout-option-v1"

    func proposal(for session: WorkoutSession, change: WorkoutDemandChange,
                  assessment: WellbeingAssessment?, at now: Date,
                  calendar: Calendar = .current) throws -> WorkoutDemandAdaptationProposal {
        guard let assessment, assessment.isCurrent(at: now, calendar: calendar),
              assessment.hasCurrentRecoveryReport, assessment.unavailableSources.isEmpty,
              assessment.energyTargetReview?.hasBoundSource ?? true,
              assessment.recommendations.allSatisfy({ $0.policyVersion == WellbeingRecommendationEngine.policyVersion }) else {
            throw WorkoutDemandAdaptationError.contextUnavailable
        }
        guard !assessment.recommendations.contains(where: { $0.demand == .pauseForSymptoms || $0.kind == .symptoms }) else {
            throw WorkoutDemandAdaptationError.symptomsNeedReview
        }
        let concerns = assessment.recommendations.filter {
            $0.demand == .easeTraining && ($0.kind == .recovery || $0.kind == .fuelling)
        }
        guard !concerns.isEmpty else { throw WorkoutDemandAdaptationError.noCurrentConcern }
        guard !session.isComplete, session.completedSetCount == 0, session.currentExerciseIndex == 0,
              session.restEndsAt == nil, session.activeRestDuration == nil else {
            throw WorkoutDemandAdaptationError.workoutStarted
        }
        guard !session.isAdapted else { throw WorkoutDemandAdaptationError.alreadyAdapted }
        let estimator = WorkoutTimeEstimator()
        guard let originalEstimate = estimator.estimate(for: session),
              Set(session.exercises.map(\.id)).count == session.exercises.count,
              session.exercises.allSatisfy({ $0.plan.targetLoad.value.isFinite && $0.plan.targetLoad.value >= 0 }) else {
            throw WorkoutDemandAdaptationError.invalidPrescription
        }
        let exercises = session.exercises.enumerated().map { index, exercise in
            let before = exercise.plan
            let sets: Int
            let rest: TimeInterval
            switch change {
            case .fewerSets:
                // One fewer set per occurrence, never zero work. This explicit
                // review bound is not a validated percentage deload protocol.
                sets = max(1, before.plannedSetCount - 1)
                rest = before.restSeconds
            case .longerRest:
                sets = before.plannedSetCount
                let hasRestInterval = sets > 1 || index < session.exercises.count - 1
                // Keep authored zero-rest/circuit and already long targets.
                rest = hasRestInterval && before.restSeconds > 0 && before.restSeconds < 600
                    ? min(600, before.restSeconds + 30) : before.restSeconds
            }
            // Keep accepted workload/rest changes when the person later undoes a swap.
            // Never shorten an older original rest target while doing so.
            let original = exercise.originalPlan.map { copy($0, sets: min($0.plannedSetCount, sets),
                rest: change == .longerRest ? max($0.restSeconds, rest) : $0.restSeconds) }
            return WorkoutExercise(plan: copy(before, sets: sets, rest: rest), originalPlan: original, substitutionInput: exercise.substitutionInput)
        }
        guard exercises.map(\.plan) != session.exercises.map(\.plan) else {
            throw WorkoutDemandAdaptationError.noBoundedChange
        }
        let adapted = WorkoutSession(id: session.id, title: session.title, programmeID: session.programmeID,
            programmeProvenance: session.programmeProvenance?.retaining(exercises.map(\.id)),
            customWorkoutID: session.customWorkoutID, targetDurationMinutes: session.targetDurationMinutes,
            isAdapted: true, warmUp: session.warmUp, exercises: exercises)
        guard let adaptedEstimate = estimator.estimate(for: adapted) else {
            throw WorkoutDemandAdaptationError.invalidPrescription
        }
        return .init(policyVersion: Self.policyVersion, change: change, offeredAt: now,
            timeZoneID: calendar.timeZone.identifier, concerns: concerns,
            energyTargetSource: assessment.energyTargetReview?.sourceFingerprint,
            originalSession: session, adaptedSession: adapted,
            originalEstimate: originalEstimate, adaptedEstimate: adaptedEstimate)
    }

    func revalidated(_ presented: WorkoutDemandAdaptationProposal, current session: WorkoutSession,
                     assessment: WellbeingAssessment?, at now: Date,
                     calendar: Calendar = .current) throws -> WorkoutDemandAdaptationProposal {
        guard presented.policyVersion == Self.policyVersion, presented.originalSession == session,
              presented.offeredAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, presented.offeredAt <= now,
              now.timeIntervalSince(presented.offeredAt) <= 600,
              presented.timeZoneID == calendar.timeZone.identifier,
              calendar.isDate(presented.offeredAt, inSameDayAs: now) else {
            throw WorkoutDemandAdaptationError.staleProposal
        }
        let fresh = try proposal(for: session, change: presented.change, assessment: assessment, at: now, calendar: calendar)
        guard fresh.adaptedSession == presented.adaptedSession, fresh.concerns == presented.concerns,
              fresh.energyTargetSource == presented.energyTargetSource,
              fresh.originalEstimate == presented.originalEstimate, fresh.adaptedEstimate == presented.adaptedEstimate else {
            throw WorkoutDemandAdaptationError.staleProposal
        }
        return fresh
    }

    private func copy(_ plan: ExercisePlan, sets: Int, rest: TimeInterval) -> ExercisePlan {
        .init(id: plan.id, exerciseID: plan.exerciseID, name: plan.name, targetLoad: plan.targetLoad,
            targetReps: plan.targetReps, plannedSetCount: sets, restSeconds: rest,
            previousPerformance: plan.previousPerformance, sourcePrescription: plan.sourcePrescription,
            coachingCue: plan.coachingCue, painGuardrail: plan.painGuardrail,
            equipmentIdentifiers: plan.equipmentIdentifiers, alternativeExerciseIDs: plan.alternativeExerciseIDs,
            unresolvedAlternativeNames: plan.unresolvedAlternativeNames, targetPrescription: plan.targetPrescription)
    }
}
