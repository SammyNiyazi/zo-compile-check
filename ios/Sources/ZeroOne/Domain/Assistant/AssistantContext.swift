import Foundation

struct AssistantProfileContext: Equatable, Sendable {
    let trainingGoal: String?
    let trainingExperience: String?
    let weeklyAvailability: String?
    let equipmentAccess: String?
    let trainingConstraint: String?
}

enum AssistantWorkoutState: Equatable, Sendable {
    case none
    case inProgress(title: String, canAdaptToThirtyMinutes: Bool)
}

enum AssistantTodayState: Equatable, Sendable {
    case ready(workoutTitle: String)
    case completed(workoutTitle: String)
    case noWorkoutReady
}

struct AssistantHydrationContext: Equatable, Sendable {
    let consumedMilliliters: Int
    let goalMilliliters: Int
    let isAvailable: Bool
}

struct AssistantNutritionContext: Equatable, Sendable {
    let entryCountToday: Int
    let isAvailable: Bool
}

struct AssistantHealthContextAvailability: Equatable, Sendable {
    let isConnected: Bool
    let hasLocalContext: Bool
}

struct AssistantContext: Equatable, Sendable {
    let profile: AssistantProfileContext
    let workout: AssistantWorkoutState
    let today: AssistantTodayState
    let hydration: AssistantHydrationContext
    let nutrition: AssistantNutritionContext
    let health: AssistantHealthContextAvailability
    var wellbeing: WellbeingAssessment? = nil
}

enum ContextualAssistantIntent: Equatable, Sendable {
    case whatShouldIDoNow
    case adaptToThirtyMinutes
    case addWater
    case openNutrition
    case chooseWorkout
    case continueWorkout
    case unknown
}

struct ContextualAssistantIntentParser: Sendable {
    func parse(_ request: String) -> ContextualAssistantIntent {
        let normalized = request
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return .unknown }
        if normalized.contains("what should i do") || normalized == "what now" {
            return .whatShouldIDoNow
        }
        if normalized.contains("30 minutes") || normalized.contains("thirty minutes") {
            return .adaptToThirtyMinutes
        }
        if normalized.contains("add 250 ml water")
            || normalized.contains("add 250 milliliters water")
            || normalized.contains("add 250 millilitres water") {
            return .addWater
        }
        if normalized.contains("open nutrition") {
            return .openNutrition
        }
        if normalized.contains("choose a workout") || normalized.contains("choose workout") {
            return .chooseWorkout
        }
        if normalized.contains("continue workout") || normalized.contains("resume workout") {
            return .continueWorkout
        }
        return .unknown
    }
}

struct ContextualAssistantResponse: Equatable, Sendable {
    let eyebrow: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: AssistantActionID
}

struct ContextualAssistantPolicy: Sendable {
    private let parser = ContextualAssistantIntentParser()

    func currentStateResponse(for context: AssistantContext, at now: Date = .now,
                              calendar: Calendar = .current) -> ContextualAssistantResponse {
        currentPriorityResponse(for: context, at: now, calendar: calendar)
    }

    func response(to request: String, context: AssistantContext) -> ContextualAssistantResponse {
        response(for: parser.parse(request), context: context)
    }

    func response(
        for intent: ContextualAssistantIntent,
        context: AssistantContext
    ) -> ContextualAssistantResponse {
        switch intent {
        case .whatShouldIDoNow:
            return currentPriorityResponse(for: context)
        case .adaptToThirtyMinutes:
            return thirtyMinuteResponse(for: context)
        case .addWater:
            guard context.hydration.isAvailable else {
                return unsupported(
                    detail: "Local hydration is unavailable right now.",
                    context: context
                )
            }
            return ContextualAssistantResponse(
                eyebrow: "READY TO CONFIRM",
                title: "Add 250 ml",
                detail: "Your current local total is \(context.hydration.consumedMilliliters) ml.",
                actionTitle: "Add water",
                action: .addWater
            )
        case .openNutrition:
            let detail = context.nutrition.isAvailable
                ? "You have \(context.nutrition.entryCountToday) local entries today."
                : "Nutrition storage is unavailable, but you can review the surface."
            return ContextualAssistantResponse(
                eyebrow: "NUTRITION",
                title: "Review today",
                detail: detail,
                actionTitle: "Open nutrition",
                action: .openNutrition
            )
        case .chooseWorkout:
            return workoutLibraryResponse(
                detail: "Choose from the three local Beta programmes."
            )
        case .continueWorkout:
            guard case let .inProgress(title, _) = context.workout else {
                return workoutLibraryResponse(
                    detail: "There is no interrupted workout to continue."
                )
            }
            return continueResponse(title: title)
        case .unknown:
            return unsupported(
                detail: "I can guide your next action, shorten an eligible workout, add 250 ml water, open nutrition, choose a workout, or continue one.",
                context: context
            )
        }
    }

    private func currentPriorityResponse(for context: AssistantContext, at now: Date = .now,
                                         calendar: Calendar = .current) -> ContextualAssistantResponse {
        let workoutStatus: PromptWorkoutStatus
        if case .inProgress = context.workout { workoutStatus = .active }
        else {
            switch context.today {
            case .ready: workoutStatus = .ready
            case .completed: workoutStatus = .complete
            case .noWorkoutReady: workoutStatus = .none
            }
        }
        let focus = RecommendationArbiter().focus(
            at: now, calendar: calendar, workout: workoutStatus, wellbeing: context.wellbeing
        )
        if case .sourceUnavailable = focus {
            return ContextualAssistantResponse(eyebrow: "RECOVERY AND FUELLING",
                title: "Check your records",
                detail: "Some recovery, food or activity records could not be verified. Review them before using training advice.",
                actionTitle: "Review check-in", action: .reviewWellbeing)
        }
        if case let .wellbeing(recommendation) = focus {
            return ContextualAssistantResponse(
                eyebrow: "RECOVERY AND FUELLING",
                title: recommendation.message.titleKey,
                detail: recommendation.message.detailKey,
                actionTitle: "Review check-in", action: .reviewWellbeing
            )
        }
        if case let .inProgress(title, _) = context.workout {
            return continueResponse(title: title)
        }

        switch context.today {
        case let .ready(workoutTitle):
            return ContextualAssistantResponse(
                eyebrow: "NEXT ACTION",
                title: "Train today",
                detail: "\(workoutTitle) is ready from your local programme.",
                actionTitle: "View workout",
                action: .trainToday
            )
        case let .completed(workoutTitle):
            return ContextualAssistantResponse(
                eyebrow: "TODAY COMPLETE",
                title: "Training is done",
                detail: "\(workoutTitle) is recorded locally for today.",
                actionTitle: "Review nutrition",
                action: .openNutrition
            )
        case .noWorkoutReady:
            return workoutLibraryResponse(
                detail: "No workout is ready from local Today state."
            )
        }
    }

    private func thirtyMinuteResponse(for context: AssistantContext) -> ContextualAssistantResponse {
        switch context.workout {
        case let .inProgress(title, true):
            return ContextualAssistantResponse(
                eyebrow: "LOCAL ADAPTATION",
                title: "Make \(title) 30 minutes",
                detail: "01 will create the existing deterministic proposal for your review.",
                actionTitle: "Prepare proposal",
                action: .shortenWorkout
            )
        case .inProgress:
            return ContextualAssistantResponse(
                eyebrow: "WORKOUT IN PROGRESS",
                title: "Keep the current structure",
                detail: "This session cannot be shortened safely at its current point.",
                actionTitle: "Continue workout",
                action: .continueWorkout
            )
        case .none:
            return workoutLibraryResponse(
                detail: "Choose a workout first, then 01 can check whether it can be shortened."
            )
        }
    }

    private func continueResponse(title: String) -> ContextualAssistantResponse {
        ContextualAssistantResponse(
            eyebrow: "IN PROGRESS",
            title: "Continue \(title)",
            detail: "Your active workout state is stored locally.",
            actionTitle: "Continue workout",
            action: .continueWorkout
        )
    }

    private func workoutLibraryResponse(detail: String) -> ContextualAssistantResponse {
        ContextualAssistantResponse(
            eyebrow: "WORKOUT LIBRARY",
            title: "Choose your next session",
            detail: detail,
            actionTitle: "Browse workouts",
            action: .openWorkoutLibrary
        )
    }

    private func unsupported(
        detail: String,
        context: AssistantContext
    ) -> ContextualAssistantResponse {
        let fallback = currentPriorityResponse(for: context)
        return ContextualAssistantResponse(
            eyebrow: "LOCAL ASSISTANT",
            title: "That is not supported yet",
            detail: detail,
            actionTitle: fallback.actionTitle,
            action: fallback.action
        )
    }
}
