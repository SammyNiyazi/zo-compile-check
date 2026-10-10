import Foundation

enum ZeroOneNotificationCategory: String, CaseIterable, Equatable, Sendable {
    case workout
    case hydration
    case recovery
    case inactivity
    case progress
}

enum ZeroOneNotificationEvent: String, Equatable, Sendable {
    case workoutWindowOpened
    case hydrationBehindGoal
    case recoveryNeedsAttention
    case inactivityThresholdReached
    case progressReviewReady
}

enum ZeroOneNotificationPriority: Int, Comparable, Equatable, Sendable {
    case low = 1
    case normal = 2
    case high = 3

    static func < (lhs: ZeroOneNotificationPriority, rhs: ZeroOneNotificationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ZeroOneNotificationAction: Equatable, Sendable {
    case openWorkout
    case openHydration
    case openRecovery
    case openProgress
    case reviewWellbeing
    case none
}

struct ZeroOneNotificationContext: Equatable, Sendable {
    let date: Date
    let workoutStatus: PromptWorkoutStatus
    // Retained for source compatibility. Selection requires typed, dated
    // evidence below rather than treating these scalars as measurements.
    let hydrationProgress: Double?
    let readiness: PromptReadiness
    let minutesSinceActivity: Int?
    let hasScheduleGap: Bool
    let isProgressReviewDue: Bool
    let wellbeing: WellbeingAssessment?
    let availability: ReportedWorkoutAvailability?
    let estimatedUpperMinutes: Int?

    init(
        date: Date,
        workoutStatus: PromptWorkoutStatus,
        hydrationProgress: Double? = nil,
        readiness: PromptReadiness = .unknown,
        minutesSinceActivity: Int? = nil,
        hasScheduleGap: Bool = false,
        isProgressReviewDue: Bool = false,
        wellbeing: WellbeingAssessment? = nil,
        availability: ReportedWorkoutAvailability? = nil,
        estimatedUpperMinutes: Int? = nil
    ) {
        self.date = date
        self.workoutStatus = workoutStatus
        self.hydrationProgress = hydrationProgress
        self.readiness = readiness
        self.minutesSinceActivity = minutesSinceActivity
        self.hasScheduleGap = hasScheduleGap
        self.isProgressReviewDue = isProgressReviewDue
        self.wellbeing = wellbeing
        self.availability = availability
        self.estimatedUpperMinutes = estimatedUpperMinutes
    }
}

struct ZeroOneNotification: Identifiable, Equatable, Sendable {
    let id: String
    let category: ZeroOneNotificationCategory
    let event: ZeroOneNotificationEvent
    let priority: ZeroOneNotificationPriority
    let title: String
    let body: String
    let action: ZeroOneNotificationAction
}

struct ZeroOneNotificationScheduleRequest: Equatable, Sendable {
    let notification: ZeroOneNotification
    let deliveryDate: Date
}

enum ZeroOneNotificationSchedulingOutcome: Equatable, Sendable {
    case scheduled
    case deferred(reason: String)
}
