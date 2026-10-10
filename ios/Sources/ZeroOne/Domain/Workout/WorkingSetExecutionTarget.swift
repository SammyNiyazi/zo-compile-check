import Foundation

/// Facts shown by the authored plan when this particular set was logged.
/// This is a target snapshot, not proof of actual rest, technique or safety.
struct WorkingSetExecutionTarget: Codable, Equatable, Sendable {
    let occurrenceID: UUID
    let exerciseID: ExerciseID
    let prescription: WorkingSetPrescription
    let plannedSetCount: Int
    let restSeconds: TimeInterval
    let targetLoad: Load

    init?(plan: ExercisePlan) {
        guard let explicit = plan.targetPrescription else { return nil }
        occurrenceID = plan.id
        exerciseID = plan.exerciseID
        prescription = explicit
        plannedSetCount = plan.plannedSetCount
        restSeconds = plan.restSeconds
        targetLoad = plan.targetLoad
        guard isValid else { return nil }
    }

    var isValid: Bool {
        !exerciseID.rawValue.isEmpty && exerciseID.rawValue.utf8.count <= 4_096
            && prescription.isValid && (1 ... 250_000).contains(plannedSetCount)
            && restSeconds.isFinite && (0 ... 86_400).contains(restSeconds)
            && targetLoad.value.isFinite && (0 ... 1_000_000).contains(targetLoad.value)
    }

    func matches(_ set: CompletedSet, exerciseID: ExerciseID, occurrenceID: UUID) -> Bool {
        isValid && self.exerciseID == exerciseID && self.occurrenceID == occurrenceID
            // Actual load and authored target remain independent facts. A unit
            // mismatch prevents progression comparison, not lossless recording.
            && prescription.perSide == set.isPerSide
            && (prescription.unit == .seconds) == set.isTimed
    }

    private enum CodingKeys: String, CodingKey {
        case occurrenceID, exerciseID, prescription, plannedSetCount, restSeconds, targetLoad
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        occurrenceID = try values.decode(UUID.self, forKey: .occurrenceID)
        exerciseID = try values.decode(ExerciseID.self, forKey: .exerciseID)
        prescription = try values.decode(WorkingSetPrescription.self, forKey: .prescription)
        plannedSetCount = try values.decode(Int.self, forKey: .plannedSetCount)
        restSeconds = try values.decode(TimeInterval.self, forKey: .restSeconds)
        targetLoad = try values.decode(Load.self, forKey: .targetLoad)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .prescription, in: values,
                debugDescription: "Invalid recorded execution target.")
        }
    }
}

enum WorkoutExecutionCompleteness: Equatable, Sendable {
    case unknown
    case partial
    case confirmedComplete
    case inconsistent
}
