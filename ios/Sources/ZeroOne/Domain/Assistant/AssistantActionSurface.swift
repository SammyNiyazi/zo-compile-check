import Foundation

enum AssistantActionID: String, CaseIterable, Identifiable, Equatable, Sendable {
    case shortenWorkout
    case addWater
    case openNutrition
    case openWorkoutLibrary
    case trainToday
    case continueWorkout
    case reviewWellbeing

    var id: String { rawValue }
}

enum AssistantWorkoutContext: Equatable, Sendable {
    case inactive
    case activeEligible
    case activeIneligible(String)
}

struct AssistantActionContext: Equatable, Sendable {
    let workout: AssistantWorkoutContext
    let hydrationIsAvailable: Bool
}

struct AssistantActionOption: Identifiable, Equatable, Sendable {
    let id: AssistantActionID
    let title: String
    let detail: String
    let systemImage: String
}

enum AssistantActionRoute: Equatable, Sendable {
    case workoutLibrary
    case recommendedWorkout
    case nutrition
    case currentWorkout
}

enum AssistantFeedbackKind: Equatable, Sendable {
    case success
    case information
    case unavailable
}

struct AssistantActionFeedback: Equatable, Sendable {
    let message: String
    let kind: AssistantFeedbackKind
    let accessibilityAnnouncement: String?

    init(
        message: String,
        kind: AssistantFeedbackKind,
        accessibilityAnnouncement: String? = nil
    ) {
        self.message = message
        self.kind = kind
        self.accessibilityAnnouncement = accessibilityAnnouncement
    }
}

enum AssistantActionResolution: Equatable, Sendable {
    case proposeThirtyMinuteWorkout(AssistantActionFeedback)
    case addWater(milliliters: Int, feedback: AssistantActionFeedback)
    case route(AssistantActionRoute, feedback: AssistantActionFeedback)
    case unsupported(feedback: AssistantActionFeedback, usefulRoute: AssistantActionRoute?)

    var feedback: AssistantActionFeedback {
        switch self {
        case let .proposeThirtyMinuteWorkout(feedback),
             let .addWater(_, feedback),
             let .route(_, feedback),
             let .unsupported(feedback, _):
            feedback
        }
    }
}

struct AssistantActionPolicy {
    func options(for context: AssistantActionContext) -> [AssistantActionOption] {
        var actions = [
            AssistantActionOption(
                id: .shortenWorkout,
                title: "I only have 30 minutes",
                detail: workoutDetail(for: context.workout),
                systemImage: "clock"
            ),
            AssistantActionOption(
                id: .addWater,
                title: "Add 250 ml water",
                detail: context.hydrationIsAvailable
                    ? "Update today's shared hydration total"
                    : "Local hydration is unavailable",
                systemImage: "drop"
            ),
            AssistantActionOption(
                id: .openNutrition,
                title: "Open nutrition",
                detail: "Review today's local entries",
                systemImage: "fork.knife"
            )
        ]

        if case .inactive = context.workout {
            actions.append(
                AssistantActionOption(
                    id: .openWorkoutLibrary,
                    title: "Choose a workout",
                    detail: "Open the local Workout Library",
                    systemImage: "dumbbell"
                )
            )
        }
        return actions
    }

    func resolution(
        for action: AssistantActionID,
        context: AssistantActionContext
    ) -> AssistantActionResolution {
        switch action {
        case .reviewWellbeing:
            // The root presents the local review sheet. This pure fallback
            // avoids claiming a save or a workout change if used elsewhere.
            return .unsupported(feedback: AssistantActionFeedback(
                message: "Open the recovery and fuelling check-in on Today.", kind: .information), usefulRoute: nil)
        case .shortenWorkout:
            switch context.workout {
            case .activeEligible:
                return .proposeThirtyMinuteWorkout(
                    AssistantActionFeedback(
                        message: "30-minute proposal ready to review.",
                        kind: .information
                    )
                )
            case .inactive:
                return .route(
                    .workoutLibrary,
                    feedback: AssistantActionFeedback(
                        message: "Choose a workout first, then 01 can shorten it.",
                        kind: .information
                    )
                )
            case let .activeIneligible(reason):
                return .unsupported(
                    feedback: AssistantActionFeedback(
                        message: reason,
                        kind: .unavailable
                    ),
                    usefulRoute: .currentWorkout
                )
            }
        case .addWater:
            guard context.hydrationIsAvailable else {
                return .unsupported(
                    feedback: AssistantActionFeedback(
                        message: "Hydration cannot be updated locally right now.",
                        kind: .unavailable
                    ),
                    usefulRoute: .nutrition
                )
            }
            return .addWater(
                milliliters: 250,
                feedback: AssistantActionFeedback(
                    message: "+250 ml added to hydration.",
                    kind: .success,
                    accessibilityAnnouncement: "250 milliliters added to hydration."
                )
            )
        case .openNutrition:
            return .route(
                .nutrition,
                feedback: AssistantActionFeedback(
                    message: "Nutrition is open.",
                    kind: .information
                )
            )
        case .openWorkoutLibrary:
            return .route(
                .workoutLibrary,
                feedback: AssistantActionFeedback(
                    message: "Workout Library is open.",
                    kind: .information
                )
            )
        case .trainToday:
            return .route(
                .recommendedWorkout,
                feedback: AssistantActionFeedback(
                    message: "Today's workout is ready.",
                    kind: .information
                )
            )
        case .continueWorkout:
            switch context.workout {
            case .inactive:
                return .route(
                    .workoutLibrary,
                    feedback: AssistantActionFeedback(
                        message: "There is no active workout to continue.",
                        kind: .information
                    )
                )
            case .activeEligible, .activeIneligible:
                return .route(
                    .currentWorkout,
                    feedback: AssistantActionFeedback(
                        message: "Workout resumed.",
                        kind: .information
                    )
                )
            }
        }
    }

    private func workoutDetail(for context: AssistantWorkoutContext) -> String {
        switch context {
        case .activeEligible:
            "Review a deterministic shorter plan"
        case .inactive:
            "Choose a workout before adapting it"
        case .activeIneligible:
            "This session cannot be shortened now"
        }
    }
}
