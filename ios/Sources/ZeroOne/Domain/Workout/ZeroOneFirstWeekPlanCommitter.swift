import Foundation

/// Saves a reviewed proposal into the same repositories observed by the app.
/// It never starts/replaces an active session or rewrites workout history.
@MainActor
enum ZeroOneFirstWeekPlanCommitter {
    enum CommitError: LocalizedError, Equatable {
        case draftUnavailable, workoutsUnavailable, activationUnconfirmed, reviewRequired

        var errorDescription: String? {
            switch self {
            case .draftUnavailable:
                "Couldn't save your plan draft on this iPhone. Your answers are still here. Reload saved data, then review and try again."
            case .workoutsUnavailable:
                "Couldn't confirm the saved workouts. No new plan was activated. Reload saved data, then try again."
            case .activationUnconfirmed:
                "The workouts were saved, but 01 couldn't confirm plan activation. Reload saved data before trying again."
            case .reviewRequired:
                "Your answers or exercise selection changed. Review a new draft before saving."
            }
        }
    }

    @discardableResult
    static func save(
        _ plan: ZeroOneFirstWeekPlan,
        profile: ZeroOneUserProfileRepository,
        workouts: CustomWorkoutRepository,
        completesOnboarding: Bool,
        skippedSetup: Bool,
        savedAt: Date = .now
    ) throws -> ZeroOneSavedFirstWeekPlan {
        guard ZeroOneFirstWeekPlanner.isCurrent(plan, for: profile.profile,
            availableVideoIDs: MoveKitExercise.availableVideoIDs) else { throw CommitError.reviewRequired }
        let ids = profile.profile.firstWeekDraftWorkoutIDs ?? plan.sessions.map { _ in UUID() }
        guard profile.updateVerified({ $0.firstWeekDraftWorkoutIDs = ids }) else {
            throw CommitError.draftUnavailable
        }
        let unit = profile.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()
        guard let proposed = plan.makeCustomWorkouts(ids: ids,
            weightUnit: unit == .pounds ? .pounds : .kilograms),
              workouts.saveTogether(proposed) else {
            throw CommitError.workoutsUnavailable
        }
        let saved = ZeroOneSavedFirstWeekPlan(plan: plan, workoutIDs: ids, savedAt: savedAt)
        guard profile.updateVerified({ value in
            value.savedFirstWeekPlan = saved
            value.firstWeekDraftWorkoutIDs = nil
            value.onboardingWasSkipped = skippedSetup
            if completesOnboarding { value.onboardingComplete = true }
        }) else {
            throw CommitError.activationUnconfirmed
        }
        return saved
    }
}
