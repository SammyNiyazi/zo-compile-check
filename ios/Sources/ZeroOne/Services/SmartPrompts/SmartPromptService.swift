import Foundation

protocol SmartPromptProviding: Sendable {
    func prompts(for context: SmartPromptContext) -> [SmartPrompt]
}

struct LocalSmartPromptService: SmartPromptProviding {
    func prompts(for context: SmartPromptContext) -> [SmartPrompt] {
        let focus = RecommendationArbiter().focus(at: context.date, workout: context.workoutStatus,
            wellbeing: context.wellbeing, availability: context.availability,
            estimatedUpperMinutes: context.estimatedUpperMinutes, progressReviewDue: context.isProgressReviewDue)
        switch focus {
        case let .wellbeing(recommendation):
            return [SmartPrompt(id: "wellbeing-" + recommendation.kind.rawValue,
                trigger: recommendation.kind == .hydration ? .hydrationLow : .recoveryCheckIn,
                priority: recommendation.demand >= .checkIn ? .strong : .useful,
                tone: .calm, message: recommendation.message.detailKey,
                systemImage: recommendation.kind == .hydration ? "drop.fill" : "heart.text.clipboard",
                action: .reviewWellbeing)]
        case .continueWorkout:
            return [] // The active workout owns its execution surface.
        case let .startWorkout(fits):
            return [SmartPrompt(id: fits ? "workout-window" : "next-workout",
                trigger: fits ? .workoutWindow : .nextWorkout, priority: .useful, tone: .direct,
                message: fits ? "The session estimate fits the time you reported. Your session is ready."
                    : "Your next session is ready. Start when you are set.",
                systemImage: "figure.strengthtraining.traditional", action: .openWorkout)]
        case .reviewProgress:
            return [SmartPrompt(id: "progress-review", trigger: .nextWorkout, priority: .passive,
                tone: .calm, message: "Review your recorded work when it suits you.",
                systemImage: "chart.xyaxis.line", action: .openProgress)]
        case .none, .sourceUnavailable: return []
        }
    }
}
