import Foundation

enum UserContextValue: Equatable, Sendable {
    case text(String)
    case number(Double, unit: String?)
    case time(DateComponents)
    case choice(String)
    case choices([String])
}

enum UserFactKind: String, CaseIterable, Equatable, Sendable {
    case primaryGoal
    case trainingExperience
    case workSchedule
    case availableEquipment
    case usualWorkoutDuration
    case preferredTrainingWindow
    case sleepRoutine
    case dietaryRoutine
    case hydrationTendency
    case constraint
    case preference
    case limitationNote
    case notificationPreference
    case communicationTone
}

struct UserContextFact: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: UserFactKind
    let value: UserContextValue
    let learnedAt: Date
    let source: String

    init(
        id: UUID = UUID(),
        kind: UserFactKind,
        value: UserContextValue,
        learnedAt: Date = .now,
        source: String
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.learnedAt = learnedAt
        self.source = source
    }
}

struct AssistantInference: Identifiable, Equatable, Sendable {
    let id: UUID
    let key: String
    let value: UserContextValue
    let confidence: Double
    let supportingFactIDs: [UUID]
    let inferredAt: Date

    init(
        id: UUID = UUID(),
        key: String,
        value: UserContextValue,
        confidence: Double,
        supportingFactIDs: [UUID],
        inferredAt: Date = .now
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.confidence = min(1, max(0, confidence))
        self.supportingFactIDs = supportingFactIDs
        self.inferredAt = inferredAt
    }
}

struct UserContextProfile: Equatable, Sendable {
    private(set) var facts: [UserContextFact] = []
    private(set) var inferences: [AssistantInference] = []

    mutating func record(facts newFacts: [UserContextFact]) {
        facts.append(contentsOf: newFacts)
    }

    mutating func replaceInferences(_ newInferences: [AssistantInference]) {
        inferences = newInferences
    }
}

enum OnboardingAnswerMode: String, CaseIterable, Equatable, Sendable {
    case voice
    case text
    case quickChoice
}

struct ConversationalOnboardingQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let prompt: String
    let acceptedModes: [OnboardingAnswerMode]
    let quickChoices: [String]
    let requiredFactKinds: [UserFactKind]
}

struct OnboardingExtraction: Equatable, Sendable {
    let facts: [UserContextFact]
    let unansweredRequiredFactKinds: [UserFactKind]
}

protocol ConversationalOnboardingExtracting: Sendable {
    func extractFacts(from answer: String, now: Date) -> OnboardingExtraction
}
