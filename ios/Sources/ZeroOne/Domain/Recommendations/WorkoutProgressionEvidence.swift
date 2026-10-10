import CryptoKit
import Foundation

/// A review of one saved occurrence, never a rewrite of its performed sets.
/// Optional answers remain unknown. Equipment answers concern the available
/// next-session increment, not a machine inferred from exercise metadata.
struct WorkoutProgressionReview: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceSessionID: UUID
    let occurrenceID: UUID
    let exerciseID: ExerciseID
    let sourceFingerprint: String
    let planFingerprint: String
    let reviewedAt: Date
    let controlledMovement: Bool?
    let painFree: Bool?
    let availableIncrement: Load?
    let higherValueMeansMoreResistance: Bool?

    var isValid: Bool {
        !exerciseID.rawValue.isEmpty && exerciseID.rawValue.utf8.count <= 4_096
            && reviewedAt.timeIntervalSinceReferenceDate.isFinite
            && WorkoutProgressionEvidence.isFingerprint(sourceFingerprint)
            && WorkoutProgressionEvidence.isFingerprint(planFingerprint)
            && (availableIncrement.map { $0.value.isFinite && $0.value > 0 && $0.value <= 20 } ?? true)
    }
}

/// Stable provenance travels with a proposal and an accepted choice. A clock
/// is rechecked separately, so repeated evaluation does not change its identity.
struct WorkoutProgressionProposalContext: Codable, Equatable, Sendable {
    let policyVersion: String
    let sourceSessionID: UUID
    let occurrenceID: UUID
    let sourceFingerprint: String
    let planFingerprint: String
    let reviewID: UUID
}

struct QualifiedWorkoutProgression {
    let occurrence: WorkoutHistoryExercise
    let opportunity: WorkoutProgressionOpportunity
}

/// Exact-source qualification and versioned product bounds. This is not an
/// individually validated prescription, clinical clearance or a rest measure.
enum WorkoutProgressionEvidence {
    static let policyVersion = "load-progression-v3"
    static let maximumAge: TimeInterval = 42 * 86_400

    static func qualify(plan: ExercisePlan, performance: RecordedExercisePerformance,
                        reviews: [WorkoutProgressionReview], at now: Date) -> QualifiedWorkoutProgression? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              !performance.hasNewerUnknownDetails,
              let entry = performance.sourceEntry,
              entry.id == performance.sessionID, entry.completedAt == performance.completedAt,
              entry.title == performance.sessionTitle,
              entry.executionCompleteness == .confirmedComplete,
              performance.executionCompleteness == .confirmedComplete,
              entry.executionCompletionConfirmedAt == performance.executionCompletionConfirmedAt,
              let confirmed = entry.executionCompletionConfirmedAt, confirmed <= now,
              entry.completedAt <= now, now.timeIntervalSince(entry.completedAt) <= maximumAge,
              let saved = entry.exercises, saved.count <= 500,
              (1 ... 5_000).contains(entry.completedSetCount),
              performance.occurrences == saved.filter({ $0.exerciseID == plan.exerciseID }),
              let planFingerprint = planFingerprint(plan),
              let sourceFingerprint = fingerprint(entry),
              let occurrence = matchingOccurrence(plan: plan, occurrences: performance.occurrences),
              let first = occurrence.completedSets.first, let target = first.executionTarget,
              let explicit = plan.targetPrescription, explicit.unit == .repetitions,
              explicit.upperBound <= 50,
              occurrence.targetPrescription == explicit,
              occurrence.plannedSetCount == plan.plannedSetCount,
              occurrence.completedSets.count == plan.plannedSetCount,
              target.prescription == explicit, target.plannedSetCount == plan.plannedSetCount,
              target.restSeconds == plan.restSeconds,
              target.targetLoad.unit == plan.targetLoad.unit,
              first.load.unit == plan.targetLoad.unit, first.load.value > 0,
              first.load.value.isFinite, first.load.value <= 2_000 else { return nil }

        let allSets = saved.flatMap(\.completedSets)
        guard Set(saved.map(\.id)).count == saved.count,
              Set(allSets.map(\.id)).count == allSets.count,
              allSets.allSatisfy({
                  $0.completedAt.timeIntervalSinceReferenceDate.isFinite && $0.completedAt <= entry.completedAt
                      && $0.load.value.isFinite && (0 ... 2_000).contains($0.load.value)
                      && ($0.isTimed ? (1 ... 86_400).contains($0.durationSeconds ?? 0) : (1 ... 50).contains($0.reps))
                      && WorkoutRestTimerEvidence.validStoredObservation(for: $0, finishedAt: entry.completedAt)
              }) else { return nil }
        let minimumReserve = max(2, ExerciseLibrary.exercise(id: plan.exerciseID)?.defaultRIRRange.lowerBound ?? 2)
        guard minimumReserve <= 5 else { return nil }
        var previousDate: Date?
        for set in occurrence.completedSets {
            guard set.executionTarget == target,
                  target.matches(set, exerciseID: plan.exerciseID, occurrenceID: occurrence.id),
                  !set.isTimed, set.isPerSide == explicit.perSide, set.load == first.load,
                  set.reps >= explicit.upperBound, let reserve = set.rir,
                  (minimumReserve ... 5).contains(reserve),
                  previousDate.map({ set.completedAt >= $0 }) ?? true else { return nil }
            previousDate = set.completedAt
        }

        guard reviews.count <= 10_000, Set(reviews.map(\.id)).count == reviews.count else { return nil }
        let matches = reviews.filter { $0.sourceSessionID == entry.id && $0.occurrenceID == occurrence.id }
        guard matches.count == 1, let review = matches.first, review.isValid,
              review.exerciseID == plan.exerciseID, review.sourceFingerprint == sourceFingerprint,
              review.planFingerprint == planFingerprint, review.reviewedAt >= confirmed, review.reviewedAt <= now,
              review.controlledMovement == true, review.painFree == true,
              review.higherValueMeansMoreResistance == true, let increment = review.availableIncrement,
              increment.unit == first.load.unit else { return nil }
        // These bounds are product controls, not a claim that every 10% increase
        // is appropriate. A real available increment must satisfy both bounds.
        let absoluteMaximum = increment.unit == .kilograms ? 10.0 : 20.0
        guard increment.value <= absoluteMaximum, increment.value / first.load.value <= 0.10 else { return nil }
        let suggested = Load(first.load.value + increment.value, unit: first.load.unit)
        guard suggested.value.isFinite, suggested.value <= 2_000,
              plan.targetLoad.value == 0 || plan.targetLoad == first.load || plan.targetLoad == suggested else { return nil }
        let context = WorkoutProgressionProposalContext(policyVersion: policyVersion, sourceSessionID: entry.id,
            occurrenceID: occurrence.id, sourceFingerprint: sourceFingerprint, planFingerprint: planFingerprint,
            reviewID: review.id)
        return QualifiedWorkoutProgression(occurrence: occurrence,
            opportunity: WorkoutProgressionOpportunity(previousLoad: first.load, suggestedLoad: suggested, context: context))
    }

    static func matchingOccurrence(plan: ExercisePlan, occurrences: [WorkoutHistoryExercise]) -> WorkoutHistoryExercise? {
        guard !occurrences.isEmpty, Set(occurrences.map(\.id)).count == occurrences.count else { return nil }
        return occurrences.first { $0.id == plan.id } ?? (occurrences.count == 1 ? occurrences.first : nil)
    }

    static func fingerprint(_ entry: WorkoutHistoryEntry) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(entry) else { return nil }
        return digest(bytes)
    }

    static func planFingerprint(_ plan: ExercisePlan) -> String? {
        guard let prescription = plan.targetPrescription, prescription.isValid,
              (1 ... 100).contains(plan.plannedSetCount), plan.restSeconds.isFinite,
              (0 ... 86_400).contains(plan.restSeconds), plan.targetLoad.value.isFinite,
              (0 ... 2_000).contains(plan.targetLoad.value), plan.equipmentIdentifiers.count <= 64,
              Set(plan.equipmentIdentifiers).count == plan.equipmentIdentifiers.count else { return nil }
        // Source occurrence identity is retained separately. Programme factories
        // may regenerate their plan UUID; only one unambiguous occurrence can
        // use that fallback. Load and previous-performance values are outcomes.
        struct Specification: Encodable {
            let exerciseID: ExerciseID
            let prescription: WorkingSetPrescription
            let plannedSets: Int
            let rest: TimeInterval
            let unit: LoadUnit
            let equipment: [String]
            let sourcePrescription: String?
            let coachingCue: String?
            let painGuardrail: String?
        }
        let specification = Specification(exerciseID: plan.exerciseID, prescription: prescription,
            plannedSets: plan.plannedSetCount, rest: plan.restSeconds, unit: plan.targetLoad.unit,
            equipment: plan.equipmentIdentifiers.sorted(), sourcePrescription: plan.sourcePrescription,
            coachingCue: plan.coachingCue, painGuardrail: plan.painGuardrail)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(specification) else { return nil }
        return digest(bytes)
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
