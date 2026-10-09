import Foundation
import Observation

struct WorkoutProgressionReviewRequest: Identifiable {
    let plan: ExercisePlan
    let source: WorkoutHistoryEntry
    let occurrence: WorkoutHistoryExercise
    var id: String { "\(source.id)|\(occurrence.id)" }
}

/// One host-owned authority for the active draft, durable choices and review UI.
/// Displayed cards are never authority to change a load. Both write boundaries
/// reread local stores, resolve the current prescription and qualify again.
@MainActor @Observable
final class WorkoutProgressionAuthority {
    let history: WorkoutHistoryRepository
    let reviews: WorkoutProgressionReviewRepository
    @ObservationIgnored private var currentPlans: (@MainActor (WorkoutHistoryEntry) -> [ExercisePlan]?)?
    @ObservationIgnored private var increaseAllowed: (@MainActor () -> Bool)?
    @ObservationIgnored private var refreshCurrentPlans: (@MainActor (WorkoutHistoryEntry) -> Bool)?

    init(history: WorkoutHistoryRepository, reviews: WorkoutProgressionReviewRepository) {
        self.history = history
        self.reviews = reviews
    }

    func install(currentPlans: @escaping @MainActor (WorkoutHistoryEntry) -> [ExercisePlan]?,
                 refreshCurrentPlans: @escaping @MainActor (WorkoutHistoryEntry) -> Bool,
                 increaseAllowed: @escaping @MainActor () -> Bool) {
        self.currentPlans = currentPlans
        self.refreshCurrentPlans = refreshCurrentPlans
        self.increaseAllowed = increaseAllowed
    }

    var engine: WorkoutProgressionEngine {
        WorkoutProgressionEngine(reviews: reviews.isAvailable ? reviews.snapshot.reviews : [])
    }

    func validate(_ upgrade: WorkoutCompletionUpgrade, sourceSessionID: UUID,
                  requireIncrease: Bool = true, at now: Date = .now) -> Bool {
        guard let plan = upgrade.plan,
              let context = upgrade.opportunity.context, context.sourceSessionID == sourceSessionID,
              validate(plan: plan, opportunity: upgrade.opportunity, requireIncrease: requireIncrease, at: now),
              let source = history.entries.first(where: { $0.id == sourceSessionID }),
              let occurrence = source.exercises?.first(where: { $0.id == context.occurrenceID }),
              upgrade.exerciseID == plan.exerciseID, upgrade.completedSets == occurrence.completedSets,
              upgrade.targetRepUpperBound == plan.targetReps.upperBound else { return false }
        return true
    }

    func validate(plan: ExercisePlan, opportunity: WorkoutProgressionOpportunity,
                  requireIncrease: Bool = true, at now: Date = .now) -> Bool {
        guard opportunity.context?.policyVersion == WorkoutProgressionEvidence.policyVersion,
              !requireIncrease || increaseAllowed?() == true, reviews.reload(),
              let entries = try? history.confirmedEntries(),
              let source = entries.first(where: { $0.id == opportunity.context?.sourceSessionID }),
              refreshCurrentPlans?(source) == true,
              isCurrent(plan, source: source),
              let performance = WorkoutProgressionEngine(asOf: now).latestPerformance(for: plan, history: entries),
              let qualified = WorkoutProgressionEvidence.qualify(plan: plan, performance: performance,
                  reviews: reviews.snapshot.reviews, at: now),
              qualified.opportunity == opportunity,
              currentTargetIsCompatible(plan, source: source, opportunity: opportunity) else { return false }
        // Re-evaluate after fresh history is published to the recovery policy.
        return !requireIncrease || increaseAllowed?() == true
    }

    func reviewRequest(for plan: ExercisePlan, sourceSessionID: UUID? = nil,
                       at now: Date = .now) -> WorkoutProgressionReviewRequest? {
        guard history.availability == .available, reviews.isAvailable,
              let performance = WorkoutProgressionEngine(asOf: now).latestPerformance(for: plan, history: history.entries),
              let source = performance.sourceEntry,
              sourceSessionID == nil || source.id == sourceSessionID,
              source.executionCompleteness == .confirmedComplete,
              let confirmed = source.executionCompletionConfirmedAt, confirmed <= now,
              source.completedAt <= now, now.timeIntervalSince(source.completedAt) <= WorkoutProgressionEvidence.maximumAge,
              isCurrent(plan, source: source),
              let occurrence = WorkoutProgressionEvidence.matchingOccurrence(plan: plan, occurrences: performance.occurrences),
              !occurrence.completedSets.isEmpty else { return nil }
        return .init(plan: plan, source: source, occurrence: occurrence)
    }

    func save(_ review: WorkoutProgressionReview, request: WorkoutProgressionReviewRequest,
              replacing baseline: WorkoutProgressionReviewSnapshot, at now: Date) throws {
        guard refreshCurrentPlans?(request.source) == true,
              isCurrent(request.plan, source: request.source), review.sourceSessionID == request.source.id,
              review.occurrenceID == request.occurrence.id else { throw WorkoutProgressionReviewError.sourceChanged }
        try reviews.save(review, for: request.plan, history: history, replacing: baseline, at: now)
    }

    private func isCurrent(_ plan: ExercisePlan, source: WorkoutHistoryEntry) -> Bool {
        guard let candidates = currentPlans?(source),
              let expected = WorkoutProgressionEvidence.planFingerprint(plan) else { return false }
        let matches = candidates.filter {
            $0.exerciseID == plan.exerciseID && WorkoutProgressionEvidence.planFingerprint($0) == expected
        }
        // Authored custom occurrence identity must still exist. Programme plan
        // UUIDs can be regenerated; identical duplicate prescriptions are fine
        // here because the source-occurrence check remains exact/unambiguous.
        return source.programmeID != nil ? !matches.isEmpty : matches.contains { $0.id == plan.id }
    }

    private func currentTargetIsCompatible(_ plan: ExercisePlan, source: WorkoutHistoryEntry,
                                          opportunity: WorkoutProgressionOpportunity) -> Bool {
        guard let candidates = currentPlans?(source),
              let fingerprint = WorkoutProgressionEvidence.planFingerprint(plan) else { return false }
        return candidates.contains { current in
            current.exerciseID == plan.exerciseID
                && (source.programmeID != nil || current.id == plan.id)
                && WorkoutProgressionEvidence.planFingerprint(current) == fingerprint
                && (current.targetLoad.value == 0 || current.targetLoad == opportunity.previousLoad
                    || current.targetLoad == opportunity.suggestedLoad)
        }
    }
}
