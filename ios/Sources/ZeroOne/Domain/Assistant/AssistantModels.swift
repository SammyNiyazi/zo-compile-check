import Foundation

enum AssistantIntentKind: String, CaseIterable, Equatable, Sendable {
    case addHydration
    case setHydration
    case logWorkoutSet
    case updateAvailableTime
    case updateDailyContext
    case skipWorkout
    case startWorkout
    case nextExercise
    case adjustLoad
    case extendRest
    case skipExercise
    case completeWorkout
    case reportSleep
    case reportEnergy
    case reportSoreness
    case askAssistant
    case unknown
}

enum SubjectiveEnergy: String, Equatable, Sendable {
    case low
    case normal
    case high
}

enum ContextSeverity: String, Equatable, Sendable {
    case mild
    case moderate
    case severe
}

struct DailyContextUpdate: Equatable, Sendable {
    let key: String
    let value: String
}

enum AssistantAction: Equatable, Sendable {
    case addHydration(milliliters: Int, date: Date)
    case setHydration(milliliters: Int, date: Date)
    case logWorkoutSet(load: Load, reps: Int, rir: Int?)
    case updateAvailableTime(minutes: Int)
    case updateDailyContext(DailyContextUpdate)
    case skipWorkout(date: Date)
    case startWorkout
    case nextExercise
    case adjustLoad(amount: Double, unit: LoadUnit)
    case extendRest(seconds: Int)
    case skipExercise
    case completeWorkout
    case reportSleep(hours: Double, date: Date)
    case reportEnergy(SubjectiveEnergy, date: Date)
    case reportSoreness(area: String?, severity: ContextSeverity, date: Date)
    case askAssistant(question: String)

    var kind: AssistantIntentKind {
        switch self {
        case .addHydration: .addHydration
        case .setHydration: .setHydration
        case .logWorkoutSet: .logWorkoutSet
        case .updateAvailableTime: .updateAvailableTime
        case .updateDailyContext: .updateDailyContext
        case .skipWorkout: .skipWorkout
        case .startWorkout: .startWorkout
        case .nextExercise: .nextExercise
        case .adjustLoad: .adjustLoad
        case .extendRest: .extendRest
        case .skipExercise: .skipExercise
        case .completeWorkout: .completeWorkout
        case .reportSleep: .reportSleep
        case .reportEnergy: .reportEnergy
        case .reportSoreness: .reportSoreness
        case .askAssistant: .askAssistant
        }
    }
}

struct ParsedAssistantIntent: Equatable, Sendable {
    let action: AssistantAction
    let confidence: Double
    let sourceTranscript: String

    init(action: AssistantAction, confidence: Double, sourceTranscript: String) {
        self.action = action
        self.confidence = min(1, max(0, confidence))
        self.sourceTranscript = sourceTranscript
    }
}

enum AssistantParseResult: Equatable, Sendable {
    case intent(ParsedAssistantIntent)
    case clarification(question: String)
    case unknown
}

enum AssistantConfirmationKind: Equatable, Sendable {
    case success
    case clarification
    case error
}

struct AssistantConfirmation: Equatable, Sendable {
    let kind: AssistantConfirmationKind
    let message: String

    static func success(_ message: String) -> AssistantConfirmation {
        AssistantConfirmation(kind: .success, message: message)
    }

    static func clarification(_ message: String) -> AssistantConfirmation {
        AssistantConfirmation(kind: .clarification, message: message)
    }

    static func error(_ message: String) -> AssistantConfirmation {
        AssistantConfirmation(kind: .error, message: message)
    }
}

enum AssistantActionValidation: Equatable, Sendable {
    case valid
    case invalid(AssistantConfirmation)
}

protocol AssistantIntentParser: Sendable {
    func parse(_ transcript: String, now: Date) -> AssistantParseResult
}

protocol AssistantActionValidating: Sendable {
    func validate(_ action: AssistantAction) -> AssistantActionValidation
}

@MainActor
protocol AssistantActionExecuting: AnyObject {
    func execute(_ action: AssistantAction) -> AssistantConfirmation
}
