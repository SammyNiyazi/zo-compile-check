import Foundation

// These boundary values are independent of persistence and UI. Integration must
// supply stable template occurrence IDs, not infer identity from exercise names.
struct ProgrammePlanningIdentity: Codable, Equatable, Sendable {
    let programmeID: String
    let revisionID: String
    let stateID: String
}

struct ProgrammePlanningRepRange: Codable, Equatable, Sendable {
    let lower: Int
    let upper: Int
}

struct ProgrammePlanningPrescription: Codable, Equatable, Sendable {
    let exerciseID: String
    let load: Load
    let reps: ProgrammePlanningRepRange
    let sets: Int
    let restSeconds: TimeInterval
    let requiredEquipmentIDs: [String]
    var targetUnit: WorkingSetPrescription.Unit? = .repetitions
    var perSide: Bool? = false
}

struct ProgrammePlanningOccurrence: Codable, Equatable, Sendable {
    let id: String
    let prescription: ProgrammePlanningPrescription
}

struct ProgrammePlanningSession: Codable, Equatable, Sendable {
    let id: String
    let occurrences: [ProgrammePlanningOccurrence]
}

struct ProgrammePlanningState: Codable, Equatable, Sendable {
    let identity: ProgrammePlanningIdentity
    // Order is meaningful. Reordering never creates or removes a session.
    let sessions: [ProgrammePlanningSession]
    // No valid dated calendar means unknown, not an invented frequency.
    let sessionsPerWeek: Int?
    let hasActiveSession: Bool
}

enum ProgrammePlanningCompletion: String, Codable, Sendable {
    case complete, partial, legacySummary
}

enum ProgrammePlanningSafety: String, Codable, Sendable {
    case clear, limitationReported, unknown
}

struct ProgrammePlanningRecordedSet: Codable, Equatable, Sendable {
    let id: String
    let load: Load
    let reps: Int
    let effortRemaining: Int?
    let techniqueConfirmed: Bool?
    let safety: ProgrammePlanningSafety
    var durationSeconds: Int? = nil
    var isPerSide: Bool? = nil
}

struct ProgrammePlanningRecordedOccurrence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let prescription: ProgrammePlanningPrescription
    let sets: [ProgrammePlanningRecordedSet]
}

struct ProgrammePlanningEvidence: Codable, Equatable, Sendable {
    let id: String
    let programmeID: String
    // Unknown legacy provenance is retained as a barrier in recent evidence.
    let revisionID: String?
    let sessionID: String?
    let completedAt: Date
    let completion: ProgrammePlanningCompletion
    // nil means details were never recorded, not zero performed work.
    let occurrences: [ProgrammePlanningRecordedOccurrence]?
}

struct ProgrammePlanningConstraints: Codable, Equatable, Sendable {
    let safety: ProgrammePlanningSafety
    // nil is unknown; [] explicitly means no equipment is available.
    let availableEquipmentIDs: [String]?
    let blockedExerciseIDs: [String]
    let allowedSessionIDs: [String]?
    let maximumSessionsPerWeek: Int?
}

struct ProgrammePlanningEvidencePolicy: Codable, Equatable, Sendable {
    let minimumSessions: Int
    let maximumAgeSeconds: TimeInterval
    // This threshold is used only when effort was voluntarily recorded.
    // nil effort is never synthesized, and reps/technique still provide evidence.
    let minimumReportedEffortForProgression: Int?
}

struct ProgrammePlanningExerciseBounds: Codable, Equatable, Sendable {
    let loadUnit: LoadUnit
    let minimumLoad: Double
    let maximumLoad: Double
    let maximumLoadChange: Double
    let minimumReps: Int
    let maximumReps: Int
    let maximumRepChange: Int
    let minimumSets: Int
    let maximumSets: Int
    let maximumSetChange: Int
    let minimumRestSeconds: Int
    let maximumRestSeconds: Int
    let maximumRestChange: Int
}

enum ProgrammePlanningTrigger: String, Codable, Sendable {
    case targetMet, belowTarget, consistentCompletion
}

enum ProgrammePlanningExerciseAdjustment: Codable, Equatable, Sendable {
    case load(delta: Double)
    case reps(delta: Int)
    case sets(delta: Int)
    case rest(deltaSeconds: Int)
    case substitute(alternativeID: String)
}

struct ProgrammePlanningExerciseRule: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let occurrenceID: String
    let trigger: ProgrammePlanningTrigger
    let adjustment: ProgrammePlanningExerciseAdjustment
    let bounds: ProgrammePlanningExerciseBounds
}

struct ProgrammePlanningAlternative: Codable, Equatable, Sendable {
    let id: String
    let sourceExerciseID: String
    // A curated alternative supplies its own complete prescription. Load is
    // never carried automatically between different exercises.
    let replacement: ProgrammePlanningPrescription
    let bounds: ProgrammePlanningExerciseBounds
}

enum ProgrammePlanningStructureAdjustment: Codable, Equatable, Sendable {
    case sessionOrder([String])
    case frequency(sessionsPerWeek: Int)
}

struct ProgrammePlanningStructureRule: Codable, Equatable, Sendable {
    let id: String
    let trigger: ProgrammePlanningTrigger
    let adjustment: ProgrammePlanningStructureAdjustment
}

struct ProgrammePlanningStructureBounds: Codable, Equatable, Sendable {
    let minimumSessionsPerWeek: Int
    let maximumSessionsPerWeek: Int
    let maximumFrequencyChange: Int
    let maximumMovedSessions: Int
}

struct ProgrammePlanningPolicy: Codable, Equatable, Sendable {
    // Version this identifier whenever policy values or curation change.
    let id: String
    let evidence: ProgrammePlanningEvidencePolicy
    let exerciseRules: [ProgrammePlanningExerciseRule]
    let alternatives: [ProgrammePlanningAlternative]
    let structureRules: [ProgrammePlanningStructureRule]
    let structureBounds: ProgrammePlanningStructureBounds
    let maximumChanges: Int
}

struct ProgrammePlanningInput: Codable, Equatable, Sendable {
    let state: ProgrammePlanningState
    let evidence: [ProgrammePlanningEvidence]
    let constraints: ProgrammePlanningConstraints
    let policy: ProgrammePlanningPolicy?
    // Injected clock makes freshness decisions replayable.
    let asOf: Date
}

enum ProgrammePlanningDimension: String, Codable, Sendable {
    case load, reps, sets, rest, exercise, sessionOrder, frequency
}

enum ProgrammePlanningValue: Codable, Equatable, Sendable {
    case prescription(ProgrammePlanningPrescription)
    case sessionOrder([String])
    case frequency(Int)
}

struct ProgrammePlanningEvidenceReference: Codable, Equatable, Sendable {
    let recordID: String
    let sessionID: String
    let occurrenceID: String
    let setIDs: [String]
}

enum ProgrammePlanningReason: String, Codable, Sendable {
    case missingPolicy, invalidPolicy, invalidState, activeSession
    case unknownConstraints, limitationReported, equipmentUnavailable, sessionNotAllowed
    case insufficientEvidence, missingEvidence, duplicateEvidence, legacyEvidence, partialEvidence
    case staleEvidence, incomparableUnits, incomparablePrescription, invalidEvidence, unconfirmedTechnique
    case boundsExceeded, uncuratedAlternative, conflictingRules, tooManyChanges, noChange
    case repeatedTargetMet, repeatedBelowTarget, consistentCompletion

    var explanation: String {
        switch self {
        case .missingPolicy: "Keep the plan until progression rules are available."
        case .invalidPolicy: "Keep the plan because its progression rules need review."
        case .invalidState: "Keep the plan because its current details need checking."
        case .activeSession: "Finish the active workout before changing the programme."
        case .unknownConstraints: "Confirm your equipment and limitations before changing the plan."
        case .limitationReported: "Keep the plan unchanged while the reported limitation is reviewed."
        case .equipmentUnavailable: "The proposed exercise needs equipment you have not confirmed."
        case .sessionNotAllowed: "The proposed schedule does not fit your confirmed availability."
        case .insufficientEvidence: "Record more comparable sessions before changing the plan."
        case .missingEvidence: "The required exercise record is missing."
        case .duplicateEvidence: "Repeated record identifiers need checking before changing the plan."
        case .legacyEvidence: "Older summary records do not contain enough detail for this change."
        case .partialEvidence: "An unfinished session is not enough evidence for this change."
        case .staleEvidence: "The recent records do not match the current plan or evidence window."
        case .incomparableUnits: "These weights use different units and cannot be compared directly."
        case .incomparablePrescription: "The recorded exercise or target differs from the current plan."
        case .invalidEvidence: "Some recorded values need checking before changing the plan."
        case .unconfirmedTechnique: "Confirm controlled technique before progressing the plan."
        case .boundsExceeded: "This change exceeds the limits set for your programme."
        case .uncuratedAlternative: "This replacement has not been approved for the current exercise."
        case .conflictingRules: "Overlapping programme changes need review."
        case .tooManyChanges: "The proposal changes too much at once. Keep the current plan."
        case .noChange: "Your recent records do not call for a change. Keep the current plan."
        case .repeatedTargetMet: "You met the target with confirmed technique across the required sessions."
        case .repeatedBelowTarget: "The target was missed across the required comparable sessions."
        case .consistentCompletion: "You consistently completed the planned work with confirmed technique."
        }
    }
}

struct ProgrammePlanningChange: Codable, Equatable, Sendable {
    let ruleID: String
    let dimension: ProgrammePlanningDimension
    let sessionID: String?
    let occurrenceID: String?
    let before: ProgrammePlanningValue
    let after: ProgrammePlanningValue
    let evidence: [ProgrammePlanningEvidenceReference]
    let reason: ProgrammePlanningReason
}

struct ProgrammePlanningProposal: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case hold, change }

    let id: String
    let basedOn: ProgrammePlanningIdentity
    let policyID: String?
    let outcome: Outcome
    let evaluatedEvidenceIDs: [String]
    let changes: [ProgrammePlanningChange]
    let reasons: [ProgrammePlanningReason]
}
