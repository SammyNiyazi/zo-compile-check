import Foundation

enum LoadUnit: String, Codable, Equatable, Sendable {
    case kilograms = "kg"
    case pounds = "lb"
}

struct Load: Codable, Equatable, Sendable {
    let value: Double
    let unit: LoadUnit

    init(_ value: Double, unit: LoadUnit = .kilograms) {
        self.value = value
        self.unit = unit
    }
}

struct RepRange: Codable, Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init(_ lowerBound: Int, _ upperBound: Int) {
        precondition(lowerBound > 0, "Rep ranges must start above zero.")
        precondition(upperBound >= lowerBound, "Rep range upper bound must be at least the lower bound.")

        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// Only explicitly authored units become a typed target. Historical set values
/// never pass through this parser and are never reinterpreted as durations.
struct WorkingSetPrescription: Codable, Equatable, Sendable {
    enum Unit: String, Codable, Sendable { case repetitions, seconds }
    let unit: Unit
    let lowerBound: Int
    let upperBound: Int
    let perSide: Bool

    init(unit: Unit, lowerBound: Int, upperBound: Int, perSide: Bool = false) {
        self.unit = unit
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.perSide = perSide
    }

    var isValid: Bool { lowerBound > 0 && upperBound >= lowerBound && upperBound <= 86_400 }

    private enum CodingKeys: String, CodingKey { case unit, lowerBound, upperBound, perSide }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unit = try values.decode(Unit.self, forKey: .unit)
        lowerBound = try values.decode(Int.self, forKey: .lowerBound)
        upperBound = try values.decode(Int.self, forKey: .upperBound)
        perSide = try values.decode(Bool.self, forKey: .perSide)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .upperBound, in: values,
                debugDescription: "A working target needs a positive ordered range.")
        }
    }

    static func authored(_ text: String, fallback: RepRange) -> Self {
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        let lower = max(1, numbers.first ?? fallback.lowerBound)
        let upper = max(lower, numbers.dropFirst().first ?? lower)
        let timed = text.localizedCaseInsensitiveContains("second") || text.localizedCaseInsensitiveContains("minute")
        let multiplier = text.localizedCaseInsensitiveContains("minute") ? 60 : 1
        return Self(unit: timed ? .seconds : .repetitions,
                    lowerBound: lower * multiplier, upperBound: upper * multiplier,
                    perSide: text.localizedCaseInsensitiveContains("per side"))
    }

    var displayText: String {
        let range = lowerBound == upperBound ? "\(lowerBound)" : "\(lowerBound)–\(upperBound)"
        return range + (unit == .seconds ? " sec" : " reps") + (perSide ? " per side" : "")
    }
}

struct PreviousSetPerformance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let load: Load
    let reps: Int

    init(id: UUID = UUID(), load: Load, reps: Int) {
        self.id = id
        self.load = load
        self.reps = reps
    }
}

struct ExercisePlan: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let exerciseID: ExerciseID
    let name: String
    let targetLoad: Load
    let targetReps: RepRange
    let plannedSetCount: Int
    let restSeconds: TimeInterval
    let previousPerformance: [PreviousSetPerformance]
    let sourcePrescription: String?
    let coachingCue: String?
    let painGuardrail: String?
    let equipmentIdentifiers: [String]
    let alternativeExerciseIDs: [ExerciseID]
    let unresolvedAlternativeNames: [String]
    // Optional evolution: old plans and old logs keep their original meaning.
    let targetPrescription: WorkingSetPrescription?

    init(
        id: UUID = UUID(),
        exerciseID: ExerciseID? = nil,
        name: String,
        targetLoad: Load,
        targetReps: RepRange,
        plannedSetCount: Int,
        restSeconds: TimeInterval,
        previousPerformance: [PreviousSetPerformance],
        sourcePrescription: String? = nil,
        coachingCue: String? = nil,
        painGuardrail: String? = nil,
        equipmentIdentifiers: [String] = [],
        alternativeExerciseIDs: [ExerciseID] = [],
        unresolvedAlternativeNames: [String] = [],
        targetPrescription: WorkingSetPrescription? = nil
    ) {
        precondition(plannedSetCount > 0, "An exercise needs at least one planned set.")
        precondition(restSeconds >= 0, "Rest cannot be negative.")

        self.id = id
        self.exerciseID = exerciseID
            ?? ExerciseLibrary.exercise(named: name)?.id
            ?? ExerciseID(exerciseName: name)
        self.name = name
        self.targetLoad = targetLoad
        self.targetReps = targetReps
        self.plannedSetCount = plannedSetCount
        self.restSeconds = restSeconds
        self.previousPerformance = previousPerformance
        self.sourcePrescription = sourcePrescription
        self.coachingCue = coachingCue
        self.painGuardrail = painGuardrail
        self.equipmentIdentifiers = equipmentIdentifiers
        self.alternativeExerciseIDs = alternativeExerciseIDs
        self.unresolvedAlternativeNames = unresolvedAlternativeNames
        self.targetPrescription = targetPrescription
    }

    var prescription: WorkingSetPrescription {
        targetPrescription ?? WorkingSetPrescription(unit: .repetitions,
            lowerBound: targetReps.lowerBound, upperBound: targetReps.upperBound, perSide: false)
    }
    var isTimed: Bool { prescription.unit == .seconds }
    var prescriptionDisplayText: String { prescription.displayText }

    var allowsZeroLoad: Bool {
        if isTimed { return true }
        if let definition = ExerciseLibrary.exercise(id: exerciseID) {
            return definition.equipment.contains(.bodyweight)
        }
        return equipmentIdentifiers.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("bodyweight") == .orderedSame
        }
    }
}

struct CompletedSet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let load: Load
    let reps: Int
    let rir: Int?
    let completedAt: Date
    let durationSeconds: Int?
    // Nil in older sets is unknown; no side semantics are inferred from an ID.
    let isPerSide: Bool?
    // Nil in older logs or a plan without an explicitly authored target.
    let executionTarget: WorkingSetExecutionTarget?
    // Nil is unknown legacy timer coverage, never zero actual rest.
    var restTimerObservation: WorkoutRestTimerObservation?

    init(id: UUID = UUID(), load: Load, reps: Int, rir: Int? = nil, completedAt: Date,
         durationSeconds: Int? = nil, isPerSide: Bool? = nil,
         executionTarget: WorkingSetExecutionTarget? = nil,
         restTimerObservation: WorkoutRestTimerObservation? = nil) {
        self.id = id
        self.load = load
        self.reps = reps
        self.rir = rir
        self.completedAt = completedAt
        self.durationSeconds = durationSeconds
        self.isPerSide = isPerSide
        self.executionTarget = executionTarget
        self.restTimerObservation = restTimerObservation
    }

    var isTimed: Bool { durationSeconds != nil }
    private enum CodingKeys: String, CodingKey {
        case id, load, reps, rir, completedAt, durationSeconds, isPerSide, executionTarget, restTimerObservation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        load = try values.decode(Load.self, forKey: .load)
        reps = try values.decode(Int.self, forKey: .reps)
        rir = try values.decodeIfPresent(Int.self, forKey: .rir)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds)
        isPerSide = try values.decodeIfPresent(Bool.self, forKey: .isPerSide)
        executionTarget = try values.decodeIfPresent(WorkingSetExecutionTarget.self, forKey: .executionTarget)
        restTimerObservation = try values.decodeIfPresent(WorkoutRestTimerObservation.self, forKey: .restTimerObservation)
        if let restTimerObservation, !restTimerObservation.isValid(for: id, completedAt: completedAt) {
            throw DecodingError.dataCorruptedError(forKey: .restTimerObservation, in: values,
                debugDescription: "Rest timer evidence does not match this saved set or its transition contract.")
        }
        if let durationSeconds, !(1 ... 86_400).contains(durationSeconds) || reps != 0 || rir != nil {
            throw DecodingError.dataCorruptedError(forKey: .durationSeconds, in: values,
                debugDescription: "A timed set needs explicit positive seconds and cannot also claim repetitions or RIR.")
        }
        if let executionTarget,
           executionTarget.prescription.perSide != isPerSide
                || (executionTarget.prescription.unit == .seconds) != isTimed {
            throw DecodingError.dataCorruptedError(forKey: .executionTarget, in: values,
                debugDescription: "The recorded target and result have incompatible modes or side semantics.")
        }
    }

    var performanceText: String {
        (durationSeconds.map { "\($0) sec" } ?? "\(reps) reps") + (isPerSide == true ? " per side" : "")
    }
}

struct WorkoutExercise: Identifiable, Codable, Equatable, Sendable {
    let plan: ExercisePlan
    var completedSets: [CompletedSet]
    // Retained so a today's swap can be undone before its first working set.
    // Optional for compatibility with snapshots created before substitutions.
    let originalPlan: ExercisePlan?
    let substitutionInput: WorkoutSubstitutionInput?

    var id: UUID { plan.id }

    init(plan: ExercisePlan, completedSets: [CompletedSet] = [], originalPlan: ExercisePlan? = nil,
         substitutionInput: WorkoutSubstitutionInput? = nil) {
        self.plan = plan
        self.completedSets = completedSets
        self.originalPlan = originalPlan
        self.substitutionInput = substitutionInput
    }
}

enum WorkoutSubstitutionError: Error, Equatable, Sendable {
    case workoutCompleted
    case warmUpPending
    case exerciseAlreadyStarted
    case unavailableAlternative
    case invalidLoad
}

enum WorkoutCompletionError: Error, Equatable, Sendable {
    case workoutCompleted
    case warmUpPending
    case restInProgress
    case noCurrentExercise
    case invalidLoad
    case invalidReps
    case invalidRIR
    case invalidDuration
}

enum SetCompletionResult: Equatable, Sendable {
    case advancedToNextSet
    case advancedToNextExercise
    case workoutCompleted
}

enum SetEffortGuidanceKind: Codable, Equatable, Sendable {
    case limitReached
    case nearLimit
    case onTarget
    case capacityAvailable
}

struct SetEffortGuidance: Codable, Equatable, Sendable {
    let kind: SetEffortGuidanceKind
    let title: String
    let instruction: String
}

struct DeterministicSetEffortGuidance: Sendable {
    func guidance(
        rir: Int,
        reps: Int,
        plan: ExercisePlan,
        targetRIR: RIRRange
    ) -> SetEffortGuidance {
        precondition((0 ... 5).contains(rir), "RIR must be between zero and five.")

        if rir == 0 {
            return SetEffortGuidance(
                kind: .limitReached,
                title: "LIMIT REACHED",
                instruction: "Do not add load. Reduce the next set if technique changed."
            )
        }

        if rir < targetRIR.lowerBound {
            return SetEffortGuidance(
                kind: .nearLimit,
                title: "NEAR LIMIT",
                instruction: "Hold the load. Keep the next set controlled."
            )
        }

        if rir <= targetRIR.upperBound {
            return SetEffortGuidance(
                kind: .onTarget,
                title: "EFFORT ON TARGET",
                instruction: "Repeat the planned load and rep range."
            )
        }

        if reps < plan.targetReps.upperBound {
            return SetEffortGuidance(
                kind: .capacityAvailable,
                title: "CAPACITY LEFT",
                instruction: "Keep the load. Work toward \(plan.targetReps.upperBound) clean reps."
            )
        }

        return SetEffortGuidance(
            kind: .capacityAvailable,
            title: "CAPACITY LEFT",
            instruction: "Repeat cleanly. Consider the smallest load increase next session."
        )
    }
}
