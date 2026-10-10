import Foundation

protocol ZeroOneNotificationSelecting: Sendable {
    func bestNotification(for context: ZeroOneNotificationContext) -> ZeroOneNotification?
}

protocol ZeroOneNotificationScheduling: Sendable {
    func schedule(_ request: ZeroOneNotificationScheduleRequest) async -> ZeroOneNotificationSchedulingOutcome
    func cancel(identifier: String) async
}

/// Uses the same evidence ordering as in-app prompts. This framework adapter
/// is not the OS-backed SmartNoteCenter and does not imply delivery permission.
struct LocalZeroOneNotificationSelector: ZeroOneNotificationSelecting {
    func bestNotification(for context: ZeroOneNotificationContext) -> ZeroOneNotification? {
        let focus = RecommendationArbiter().focus(at: context.date, workout: context.workoutStatus,
            wellbeing: context.wellbeing, availability: context.availability,
            estimatedUpperMinutes: context.estimatedUpperMinutes, progressReviewDue: context.isProgressReviewDue)
        switch focus {
        case let .wellbeing(recommendation):
            guard recommendation.demand >= .checkIn else { return nil }
            return .init(id: "wellbeing-review", category: .recovery, event: .recoveryNeedsAttention,
                priority: .high, title: "Review your check-in",
                body: "Open 01 to review your latest check-in and training choices.", action: .reviewWellbeing)
        case .startWorkout(fitsReportedWindow: true):
            return .init(id: "workout-window", category: .workout, event: .workoutWindowOpened,
                priority: .normal, title: "Your training time", body: "Your session estimate fits the time you reported.",
                action: .openWorkout)
        case .reviewProgress:
            return .init(id: "progress-review", category: .progress, event: .progressReviewReady,
                priority: .low, title: "Your week, in view", body: "Review your recorded work when it suits you.",
                action: .openProgress)
        default: return nil
        }
    }
}

struct DeferredZeroOneNotificationScheduler: ZeroOneNotificationScheduling {
    func schedule(_ request: ZeroOneNotificationScheduleRequest) async -> ZeroOneNotificationSchedulingOutcome {
        .deferred(reason: "Notification delivery is not configured.")
    }

    func cancel(identifier: String) async {}
}
