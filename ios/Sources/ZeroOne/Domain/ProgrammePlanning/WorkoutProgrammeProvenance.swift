import Foundation

/// Authored template identity is separate from each live execution UUID. This
/// provenance is captured at start; later adaptation never rewrites its source.
struct WorkoutProgrammeProvenance: Codable, Equatable, Sendable {
    static let currentVersion = 1
    struct Occurrence: Codable, Equatable, Sendable {
        let executionID: UUID
        let templateID: String
        // Nil remains an unrecorded explicit target, not an inferred prescription.
        let startedTarget: WorkingSetExecutionTarget?
        let requiredEquipmentIDs: [String]
        private enum CodingKeys: String, CodingKey { case executionID, templateID, startedTarget, requiredEquipmentIDs }
        init(executionID: UUID, templateID: String, startedTarget: WorkingSetExecutionTarget?, requiredEquipmentIDs: [String]) {
            self.executionID = executionID; self.templateID = templateID
            self.startedTarget = startedTarget; self.requiredEquipmentIDs = requiredEquipmentIDs
        }
        init(from decoder: Decoder) throws {
            try ProgrammeProvenanceKey.rejectUnknown(decoder, allowed: ["executionID", "templateID", "startedTarget", "requiredEquipmentIDs"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            executionID = try values.decode(UUID.self, forKey: .executionID)
            templateID = try values.decode(String.self, forKey: .templateID)
            startedTarget = try values.decodeIfPresent(WorkingSetExecutionTarget.self, forKey: .startedTarget)
            if startedTarget != nil {
                let targetDecoder = try values.superDecoder(forKey: .startedTarget)
                try ProgrammeProvenanceKey.rejectUnknown(targetDecoder,
                    allowed: ["occurrenceID", "exerciseID", "prescription", "plannedSetCount", "restSeconds", "targetLoad"])
                let targetValues = try targetDecoder.container(keyedBy: ProgrammeProvenanceKey.self)
                let prescriptionDecoder = try targetValues.superDecoder(forKey: ProgrammeProvenanceKey(stringValue: "prescription")!)
                try ProgrammeProvenanceKey.rejectUnknown(prescriptionDecoder, allowed: ["unit", "lowerBound", "upperBound", "perSide"])
                let loadDecoder = try targetValues.superDecoder(forKey: ProgrammeProvenanceKey(stringValue: "targetLoad")!)
                try ProgrammeProvenanceKey.rejectUnknown(loadDecoder, allowed: ["value", "unit"])
                let exerciseDecoder = try targetValues.superDecoder(forKey: ProgrammeProvenanceKey(stringValue: "exerciseID")!)
                // ExerciseID is RawRepresentable, so it is stored as its plain string.
                _ = try exerciseDecoder.singleValueContainer().decode(String.self)
            }
            requiredEquipmentIDs = try values.decode([String].self, forKey: .requiredEquipmentIDs)
        }
    }
    let version: Int
    let programmeID: WorkoutProgrammeID
    let sessionID: String
    let authoredRevision: String
    let effectiveRevision: String
    let startedPrescription: String
    let occurrences: [Occurrence]

    init(programmeID: WorkoutProgrammeID, sessionID: String, authoredRevision: String,
         effectiveRevision: String, startedPrescription: String, occurrences: [Occurrence]) {
        version = Self.currentVersion
        self.programmeID = programmeID; self.sessionID = sessionID
        self.authoredRevision = authoredRevision; self.effectiveRevision = effectiveRevision
        self.startedPrescription = startedPrescription; self.occurrences = occurrences
    }

    var isValid: Bool {
        guard version == Self.currentVersion, !sessionID.isEmpty, sessionID.utf8.count <= 256,
              [authoredRevision, effectiveRevision, startedPrescription].allSatisfy(WorkoutProgressionEvidence.isFingerprint),
              (1...50).contains(occurrences.count), Set(occurrences.map(\.executionID)).count == occurrences.count else { return false }
        var previous = -1
        for occurrence in occurrences {
            guard occurrence.templateID.hasPrefix("slot-"), let slot = Int(occurrence.templateID.dropFirst(5)),
                  (0..<50).contains(slot), occurrence.templateID == "slot-\(slot)", slot > previous,
                  occurrence.requiredEquipmentIDs.count <= 64,
                  Set(occurrence.requiredEquipmentIDs).count == occurrence.requiredEquipmentIDs.count,
                  occurrence.requiredEquipmentIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }),
                  occurrence.startedTarget.map({ $0.isValid && $0.occurrenceID == occurrence.executionID }) ?? true else { return false }
            previous = slot
        }
        return true
    }

    func matches(programmeID: WorkoutProgrammeID?, occurrenceIDs: [UUID]) -> Bool {
        isValid && self.programmeID == programmeID && occurrences.map(\.executionID) == occurrenceIDs
    }

    func retaining(_ executionIDs: [UUID]) -> Self? {
        let retained = occurrences.filter { executionIDs.contains($0.executionID) }
        let value = Self(programmeID: programmeID, sessionID: sessionID, authoredRevision: authoredRevision,
            effectiveRevision: effectiveRevision, startedPrescription: startedPrescription, occurrences: retained)
        return value.matches(programmeID: programmeID, occurrenceIDs: executionIDs) ? value : nil
    }

    static func capture(programme: WorkoutProgramme, selected: WorkoutProgrammeSession,
                        startedPlans: [ExercisePlan]) throws -> Self {
        guard programme.sessions.contains(selected), startedPlans.map(\.id) == selected.exercisePlans.map(\.id) else {
            throw ProgrammeVolumeError.unavailable
        }
        let effective = try ProgrammeVolumeSource.fingerprint(programme)
        let value = Self(programmeID: programme.id, sessionID: selected.id,
            authoredRevision: programme.authoredSourceFingerprint ?? effective,
            effectiveRevision: effective,
            startedPrescription: try ProgrammeVolumeSource.sessionFingerprint(programmeID: programme.id,
                session: .init(id: selected.id, title: selected.title, exercisePlans: startedPlans)),
            occurrences: startedPlans.enumerated().map {
                .init(executionID: $0.element.id, templateID: "slot-\($0.offset)",
                    startedTarget: WorkingSetExecutionTarget(plan: $0.element), requiredEquipmentIDs: $0.element.equipmentIdentifiers)
            })
        guard value.isValid else { throw ProgrammeVolumeError.unavailable }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case version, programmeID, sessionID, authoredRevision, effectiveRevision, startedPrescription, occurrences
    }
    init(from decoder: Decoder) throws {
        try ProgrammeProvenanceKey.rejectUnknown(decoder,
            allowed: ["version", "programmeID", "sessionID", "authoredRevision", "effectiveRevision", "startedPrescription", "occurrences"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        programmeID = try values.decode(WorkoutProgrammeID.self, forKey: .programmeID)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        authoredRevision = try values.decode(String.self, forKey: .authoredRevision)
        effectiveRevision = try values.decode(String.self, forKey: .effectiveRevision)
        startedPrescription = try values.decode(String.self, forKey: .startedPrescription)
        occurrences = try values.decode([Occurrence].self, forKey: .occurrences)
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid programme provenance.")) }
    }
}

private struct ProgrammeProvenanceKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported programme provenance fields."))
        }
    }
}
