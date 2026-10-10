import CryptoKit
import Foundation

/// A fresh, deterministic projection of acknowledged history. It does not
/// authorize edits or invent a programme policy, equipment, technique or safety.
struct ProgrammePlanningObservation: Equatable {
    let sourceFingerprint: String
    let input: ProgrammePlanningInput
    let proposal: ProgrammePlanningProposal

    static func capture(programme: WorkoutProgramme, history: [WorkoutHistoryEntry], sessionsPerWeek: Int?,
                        hasActiveSession: Bool, constraints: ProgrammePlanningConstraints,
                        policy: ProgrammePlanningPolicy? = nil, at now: Date) throws -> Self {
        guard now.timeIntervalSinceReferenceDate.isFinite, history.count <= 10_000,
              sessionsPerWeek.map({ (1...7).contains($0) }) ?? true else { throw ProgrammeVolumeError.unavailable }
        try WorkoutHistoryImportDecoder.validate(history)
        let revision = try ProgrammeVolumeSource.fingerprint(programme)
        let relevant = history.filter { $0.programmeID == programme.id }.sorted(by: WorkoutHistoryEntry.newestFirst)
        for entry in relevant {
            var previous: Date?
            for set in (entry.exercises ?? []).flatMap(\.completedSets) {
                guard previous.map({ set.completedAt >= $0 }) ?? true else { throw ProgrammeVolumeError.unavailable }
                previous = set.completedAt
            }
        }
        let sessions = programme.sessions.map { session in
            ProgrammePlanningSession(id: session.id, occurrences: session.exercisePlans.enumerated().map { index, plan in
                .init(id: "slot-\(index)", prescription: prescription(exerciseID: plan.exerciseID,
                    target: plan.targetPrescription, fallback: plan.targetReps, load: plan.targetLoad, sets: plan.plannedSetCount,
                    rest: plan.restSeconds, equipment: plan.equipmentIdentifiers))
            })
        }
        struct Source: Encodable {
            let version: Int
            let authored: String
            let effective: String
            let sessions: [ProgrammePlanningSession]
            let sessionsPerWeek: Int?
            let active: Bool
            let history: [WorkoutHistoryEntry]
            let constraints: ProgrammePlanningConstraints
            let policy: ProgrammePlanningPolicy?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Source(version: 1, authored: programme.authoredSourceFingerprint ?? revision,
            effective: revision, sessions: sessions, sessionsPerWeek: sessionsPerWeek, active: hasActiveSession,
            history: relevant, constraints: constraints, policy: policy))
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let state = ProgrammePlanningState(identity: .init(programmeID: programme.id.rawValue,
            revisionID: revision, stateID: fingerprint), sessions: sessions,
            sessionsPerWeek: sessionsPerWeek, hasActiveSession: hasActiveSession)
        let input = ProgrammePlanningInput(state: state, evidence: relevant.map { evidence($0, programmeID: programme.id) }, constraints: constraints,
            policy: policy, asOf: now)
        return .init(sourceFingerprint: fingerprint, input: input, proposal: try ProgrammePlanningEngine().proposal(for: input))
    }

    private static func prescription(exerciseID: ExerciseID, target: WorkingSetPrescription?, fallback: RepRange, load: Load,
                                     sets: Int, rest: TimeInterval, equipment: [String]) -> ProgrammePlanningPrescription {
        .init(exerciseID: exerciseID.rawValue, load: load, reps: .init(lower: target?.lowerBound ?? fallback.lowerBound,
            upper: target?.upperBound ?? fallback.upperBound),
            sets: sets, restSeconds: rest, requiredEquipmentIDs: equipment,
            targetUnit: target?.unit, perSide: target?.perSide)
    }

    private static func evidence(_ entry: WorkoutHistoryEntry, programmeID: WorkoutProgrammeID) -> ProgrammePlanningEvidence {
        guard let provenance = entry.programmeProvenance, let exercises = entry.exercises,
              provenance.matches(programmeID: entry.programmeID, occurrenceIDs: exercises.map(\.id)) else {
            return .init(id: entry.id.uuidString, programmeID: programmeID.rawValue,
                revisionID: nil, sessionID: nil, completedAt: entry.completedAt, completion: .legacySummary, occurrences: nil)
        }
        var occurrences: [ProgrammePlanningRecordedOccurrence] = []
        for (exercise, binding) in zip(exercises, provenance.occurrences) {
            guard let started = binding.startedTarget, started.exerciseID == exercise.exerciseID,
                  let first = exercise.completedSets.first, let target = first.executionTarget,
                  target.exerciseID == exercise.exerciseID, target.occurrenceID == exercise.id,
                  exercise.targetPrescription == target.prescription, exercise.plannedSetCount == target.plannedSetCount,
                  exercise.completedSets.allSatisfy({ $0.executionTarget == target
                      && target.matches($0, exerciseID: exercise.exerciseID, occurrenceID: exercise.id) }) else {
                // Unknown or a substituted source never borrows the current
                // catalogue's equipment or an older successful occurrence.
                return .init(id: entry.id.uuidString, programmeID: provenance.programmeID.rawValue,
                    revisionID: provenance.effectiveRevision, sessionID: provenance.sessionID,
                    completedAt: entry.completedAt, completion: .legacySummary, occurrences: nil)
            }
            occurrences.append(.init(occurrenceID: binding.templateID,
                prescription: prescription(exerciseID: exercise.exerciseID, target: target.prescription,
                    fallback: RepRange(target.prescription.lowerBound, target.prescription.upperBound), load: target.targetLoad,
                    sets: target.plannedSetCount, rest: target.restSeconds, equipment: binding.requiredEquipmentIDs),
                sets: exercise.completedSets.map {
                    .init(id: $0.id.uuidString, load: $0.load, reps: $0.reps, effortRemaining: $0.rir,
                        techniqueConfirmed: nil, safety: .unknown, durationSeconds: $0.durationSeconds, isPerSide: $0.isPerSide)
                }))
        }
        return .init(id: entry.id.uuidString, programmeID: provenance.programmeID.rawValue,
            revisionID: provenance.effectiveRevision, sessionID: provenance.sessionID, completedAt: entry.completedAt,
            completion: entry.executionCompleteness == .confirmedComplete ? .complete : .partial, occurrences: occurrences)
    }
}
