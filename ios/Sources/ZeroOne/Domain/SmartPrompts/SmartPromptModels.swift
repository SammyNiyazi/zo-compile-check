import Foundation

enum SmartPromptTrigger: String, Equatable, Sendable {
    case workoutWindow
    case hydrationLow
    case recoveryCheckIn
    case nextWorkout
    case inactivity
}

enum SmartPromptPriority: Int, Comparable, Equatable, Sendable {
    case passive = 1
    case useful = 2
    case strong = 3
    case nonNegotiable = 4

    static func < (lhs: SmartPromptPriority, rhs: SmartPromptPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SmartPromptTone: String, Equatable, Sendable {
    case calm
    case direct
    case firm
}

enum SmartPromptAction: Equatable, Sendable {
    case openWorkout
    case addWater(milliliters: Int)
    case openProgress
    case reviewWellbeing
    case none
}

enum PromptWorkoutStatus: Equatable, Sendable {
    case none
    case ready
    case active
    case complete
}

enum PromptReadiness: Equatable, Sendable {
    case unknown
    case normal
    case low
}

struct SmartPromptContext: Equatable, Sendable {
    let date: Date
    let workoutStatus: PromptWorkoutStatus
    // Legacy compatibility inputs only. These scalars cannot qualify a health
    // assessment, inactivity claim or real time window; the service ignores them.
    let hydrationProgress: Double?
    let readiness: PromptReadiness
    let minutesSinceActivity: Int?
    let hasScheduleGap: Bool
    let wellbeing: WellbeingAssessment?
    let availability: ReportedWorkoutAvailability?
    let estimatedUpperMinutes: Int?
    let isProgressReviewDue: Bool

    init(
        date: Date,
        workoutStatus: PromptWorkoutStatus,
        hydrationProgress: Double? = nil,
        readiness: PromptReadiness = .unknown,
        minutesSinceActivity: Int? = nil,
        hasScheduleGap: Bool = false,
        wellbeing: WellbeingAssessment? = nil,
        availability: ReportedWorkoutAvailability? = nil,
        estimatedUpperMinutes: Int? = nil,
        isProgressReviewDue: Bool = false
    ) {
        self.date = date
        self.workoutStatus = workoutStatus
        self.hydrationProgress = hydrationProgress
        self.readiness = readiness
        self.minutesSinceActivity = minutesSinceActivity
        self.hasScheduleGap = hasScheduleGap
        self.wellbeing = wellbeing
        self.availability = availability
        self.estimatedUpperMinutes = estimatedUpperMinutes
        self.isProgressReviewDue = isProgressReviewDue
    }
}

struct SmartPrompt: Identifiable, Equatable, Sendable {
    let id: String
    let trigger: SmartPromptTrigger
    let priority: SmartPromptPriority
    let tone: SmartPromptTone
    let message: String
    let systemImage: String
    let action: SmartPromptAction
}
