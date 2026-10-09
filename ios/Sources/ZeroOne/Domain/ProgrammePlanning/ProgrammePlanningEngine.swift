import CryptoKit
import Foundation

struct ProgrammePlanningEngine: Sendable {
    // Only encoding can throw. Invalid policy, state or evidence returns a hold.
    // No clock, random identifier, storage, network or mutable programme is used.
    func proposal(for input: ProgrammePlanningInput) throws -> ProgrammePlanningProposal {
        let changes: [ProgrammePlanningChange]
        let reasons: [ProgrammePlanningReason]
        do {
            changes = try evaluate(input)
            reasons = changes.isEmpty ? [.noChange] : changes.map(\.reason)
        } catch let failure as PlanningFailure {
            return try makeProposal(input, changes: [], reasons: [failure.reason])
        }
        return try makeProposal(input, changes: changes, reasons: reasons)
    }

    private func evaluate(_ input: ProgrammePlanningInput) throws -> [ProgrammePlanningChange] {
        let state = input.state
        try require(valid(state), .invalidState)
        try require(!state.hasActiveSession, .activeSession)
        guard let policy = input.policy else { throw PlanningFailure(.missingPolicy) }
        try require(valid(policy), .invalidPolicy)
        try require(input.asOf.timeIntervalSinceReferenceDate.isFinite, .invalidState)
        try require(input.constraints.safety != .limitationReported, .limitationReported)
        try require(input.constraints.safety == .clear, .unknownConstraints)
        guard let equipment = input.constraints.availableEquipmentIDs,
              let allowedSessions = input.constraints.allowedSessionIDs else {
            throw PlanningFailure(.unknownConstraints)
        }
        for session in state.sessions {
            try require(allowedSessions.contains(session.id), .sessionNotAllowed)
            for occurrence in session.occurrences {
                try checkConstraints(occurrence.prescription, input.constraints, equipment)
            }
        }
        let relevant = input.evidence.filter { $0.programmeID == state.identity.programmeID }
        try require(unique(relevant.map(\.id)), .duplicateEvidence)
        try require(unique(relevant.flatMap { record in
            (record.occurrences ?? []).flatMap { $0.sets.map(\.id) }
        }), .duplicateEvidence)

        var changes: [ProgrammePlanningChange] = []
        for rule in policy.exerciseRules {
            guard let session = state.sessions.first(where: { $0.id == rule.sessionID }),
                  let occurrence = session.occurrences.first(where: { $0.id == rule.occurrenceID }) else {
                throw PlanningFailure(.invalidPolicy)
            }
            let evidence = try comparableEvidence(input, session: session, occurrence: occurrence, policy: policy)
            guard matches(rule.trigger, evidence, occurrence.prescription, policy.evidence) else { continue }
            let (after, dimension) = try adjusted(occurrence.prescription, rule: rule, policy: policy)
            try checkConstraints(after, input.constraints, equipment)
            guard after != occurrence.prescription else { continue }
            try require(!changes.contains {
                $0.sessionID == session.id && $0.occurrenceID == occurrence.id
            }, .conflictingRules)
            changes.append(ProgrammePlanningChange(
                ruleID: rule.id, dimension: dimension, sessionID: session.id, occurrenceID: occurrence.id,
                before: .prescription(occurrence.prescription), after: .prescription(after),
                evidence: evidence.references, reason: reason(for: rule.trigger)
            ))
        }

        for rule in policy.structureRules {
            var references: [ProgrammePlanningEvidenceReference] = []
            var satisfied = true
            for session in state.sessions {
                for occurrence in session.occurrences {
                    let evidence = try comparableEvidence(input, session: session, occurrence: occurrence, policy: policy)
                    references.append(contentsOf: evidence.references)
                    satisfied = satisfied && matches(rule.trigger, evidence, occurrence.prescription, policy.evidence)
                }
            }
            guard satisfied else { continue }
            let before: ProgrammePlanningValue
            let after: ProgrammePlanningValue
            let dimension: ProgrammePlanningDimension
            switch rule.adjustment {
            case let .sessionOrder(order):
                let current = state.sessions.map(\.id)
                try require(unique(order) && Set(order) == Set(current), .invalidPolicy)
                try require(zip(current, order).filter { $0.0 != $0.1 }.count
                            <= policy.structureBounds.maximumMovedSessions, .boundsExceeded)
                before = .sessionOrder(current)
                after = .sessionOrder(order)
                dimension = .sessionOrder
            case let .frequency(value):
                let bounds = policy.structureBounds
                guard let availableFrequency = input.constraints.maximumSessionsPerWeek,
                      availableFrequency > 0, let currentFrequency = state.sessionsPerWeek else { throw PlanningFailure(.unknownConstraints) }
                try require(value <= availableFrequency, .sessionNotAllowed)
                try require(value >= bounds.minimumSessionsPerWeek && value <= bounds.maximumSessionsPerWeek,
                            .boundsExceeded)
                try require(distance(value, currentFrequency) <= UInt(bounds.maximumFrequencyChange),
                            .boundsExceeded)
                // Missing repetitions never justify increasing training frequency.
                try require(rule.trigger != .belowTarget || value <= currentFrequency, .invalidPolicy)
                before = .frequency(currentFrequency)
                after = .frequency(value)
                dimension = .frequency
            }
            guard before != after else { continue }
            try require(!changes.contains { $0.dimension == dimension }, .conflictingRules)
            changes.append(ProgrammePlanningChange(
                ruleID: rule.id, dimension: dimension, sessionID: nil, occurrenceID: nil,
                before: before, after: after, evidence: references, reason: reason(for: rule.trigger)
            ))
        }
        try require(changes.count <= policy.maximumChanges, .tooManyChanges)
        return changes
    }

    private struct EvidenceBundle {
        let setsBySession: [[ProgrammePlanningRecordedSet]]
        let references: [ProgrammePlanningEvidenceReference]
    }

    private func comparableEvidence(
        _ input: ProgrammePlanningInput,
        session: ProgrammePlanningSession,
        occurrence: ProgrammePlanningOccurrence,
        policy: ProgrammePlanningPolicy
    ) throws -> EvidenceBundle {
        let records = input.evidence.filter {
            $0.programmeID == input.state.identity.programmeID && ($0.sessionID == session.id || $0.sessionID == nil)
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id < $1.id
        }
        try require(records.count >= policy.evidence.minimumSessions, .insufficientEvidence)
        var batches: [[ProgrammePlanningRecordedSet]] = []
        var references: [ProgrammePlanningEvidenceReference] = []
        // Do not skip a recent partial/unknown record to find older success.
        for record in records.prefix(policy.evidence.minimumSessions) {
            try require(record.sessionID != nil && record.revisionID != nil, .legacyEvidence)
            let age = input.asOf.timeIntervalSince(record.completedAt)
            try require(age.isFinite && age >= 0 && age <= policy.evidence.maximumAgeSeconds
                        && record.revisionID == input.state.identity.revisionID, .staleEvidence)
            try require(record.completion != .legacySummary, .legacyEvidence)
            try require(record.completion == .complete, .partialEvidence)
            guard let occurrences = record.occurrences else { throw PlanningFailure(.legacyEvidence) }
            try require(unique(occurrences.map(\.occurrenceID)), .duplicateEvidence)
            try require(unique(occurrences.flatMap { $0.sets.map(\.id) }), .duplicateEvidence)
            // A record labelled complete must contain the complete prescribed
            // session. Never hide missing work in another occurrence.
            for expected in session.occurrences {
                guard let actual = occurrences.first(where: { $0.occurrenceID == expected.id }) else {
                    throw PlanningFailure(.missingEvidence)
                }
                try validate(actual, against: expected.prescription)
            }
            try require(occurrences.count == session.occurrences.count, .incomparablePrescription)
            guard let recorded = occurrences.first(where: { $0.occurrenceID == occurrence.id }) else {
                throw PlanningFailure(.missingEvidence)
            }
            batches.append(recorded.sets)
            references.append(ProgrammePlanningEvidenceReference(
                recordID: record.id, sessionID: session.id, occurrenceID: occurrence.id,
                setIDs: recorded.sets.map(\.id)
            ))
        }
        return EvidenceBundle(setsBySession: batches, references: references)
    }

    private func validate(_ recorded: ProgrammePlanningRecordedOccurrence,
                          against target: ProgrammePlanningPrescription) throws {
        try require(recorded.prescription.load.unit == target.load.unit, .incomparableUnits)
        try require(recorded.prescription == target, .incomparablePrescription)
        try require(recorded.sets.count == target.sets, .partialEvidence)
        for set in recorded.sets {
            try require(set.load.unit == target.load.unit, .incomparableUnits)
            try require(set.load.value.isFinite && set.load.value >= 0
                        && (target.targetUnit == .seconds ? (set.durationSeconds ?? 0) > 0 : set.reps > 0)
                        && (set.effortRemaining.map { (0 ... 5).contains($0) } ?? true), .invalidEvidence)
            try require(set.load == target.load, .incomparablePrescription)
            try require(set.isPerSide == target.perSide
                        && (target.targetUnit == .seconds ? (set.durationSeconds ?? 0) > 0 : set.durationSeconds == nil), .invalidEvidence)
            try require(set.safety != .limitationReported, .limitationReported)
            try require(set.safety == .clear, .unknownConstraints)
            try require(set.techniqueConfirmed == true, .unconfirmedTechnique)
        }
    }

    private func matches(
        _ trigger: ProgrammePlanningTrigger, _ evidence: EvidenceBundle,
        _ target: ProgrammePlanningPrescription, _ policy: ProgrammePlanningEvidencePolicy
    ) -> Bool {
        evidence.setsBySession.allSatisfy { sets in
            switch trigger {
            case .belowTarget:
                sets.contains { (target.targetUnit == .seconds ? ($0.durationSeconds ?? 0) : $0.reps) < target.reps.lower }
            case .targetMet, .consistentCompletion:
                sets.allSatisfy { set in
                    let requiredReps = trigger == .targetMet ? target.reps.upper : target.reps.lower
                    let effortSupportsChange = set.effortRemaining.map { reported in
                        policy.minimumReportedEffortForProgression.map { reported >= $0 } ?? true
                    } ?? true
                    let count = target.targetUnit == .seconds ? (set.durationSeconds ?? 0) : set.reps
                    return count >= requiredReps && effortSupportsChange
                }
            }
        }
    }

    private func adjusted(
        _ before: ProgrammePlanningPrescription, rule: ProgrammePlanningExerciseRule,
        policy: ProgrammePlanningPolicy
    ) throws -> (ProgrammePlanningPrescription, ProgrammePlanningDimension) {
        var load = before.load
        var reps = before.reps
        var sets = before.sets
        var rest = before.restSeconds
        let dimension: ProgrammePlanningDimension
        switch rule.adjustment {
        case let .load(delta):
            try require(delta.isFinite && (rule.trigger != .belowTarget || delta <= 0), .invalidPolicy)
            load = Load(before.load.value + delta, unit: before.load.unit)
            dimension = .load
        case let .reps(delta):
            try require(rule.trigger != .belowTarget || delta <= 0, .invalidPolicy)
            reps = ProgrammePlanningRepRange(lower: try add(before.reps.lower, delta), upper: try add(before.reps.upper, delta))
            dimension = .reps
        case let .sets(delta):
            try require(rule.trigger != .belowTarget || delta <= 0, .invalidPolicy)
            sets = try add(before.sets, delta)
            dimension = .sets
        case let .rest(delta):
            try require(rule.trigger != .belowTarget || delta >= 0, .invalidPolicy)
            rest = before.restSeconds + Double(delta)
            dimension = .rest
        case let .substitute(id):
            guard let alternative = policy.alternatives.first(where: { $0.id == id }),
                  alternative.sourceExerciseID == before.exerciseID,
                  alternative.replacement.exerciseID != before.exerciseID else {
                throw PlanningFailure(.uncuratedAlternative)
            }
            try require(within(alternative.replacement, alternative.bounds), .boundsExceeded)
            return (alternative.replacement, .exercise)
        }
        let after = ProgrammePlanningPrescription(
            exerciseID: before.exerciseID, load: load, reps: reps, sets: sets, restSeconds: rest,
            requiredEquipmentIDs: before.requiredEquipmentIDs, targetUnit: before.targetUnit, perSide: before.perSide
        )
        let bounds = rule.bounds
        try require(within(after, bounds), .boundsExceeded)
        try require(abs(after.load.value - before.load.value) <= bounds.maximumLoadChange
                    && distance(after.reps.lower, before.reps.lower) <= UInt(bounds.maximumRepChange)
                    && distance(after.reps.upper, before.reps.upper) <= UInt(bounds.maximumRepChange)
                    && distance(after.sets, before.sets) <= UInt(bounds.maximumSetChange)
                    && abs(after.restSeconds - before.restSeconds) <= Double(bounds.maximumRestChange), .boundsExceeded)
        return (after, dimension)
    }

    private func checkConstraints(
        _ prescription: ProgrammePlanningPrescription, _ constraints: ProgrammePlanningConstraints,
        _ equipment: [String]
    ) throws {
        try require(!constraints.blockedExerciseIDs.contains(prescription.exerciseID), .limitationReported)
        try require(Set(prescription.requiredEquipmentIDs).isSubset(of: Set(equipment)), .equipmentUnavailable)
    }

    private func valid(_ state: ProgrammePlanningState) -> Bool {
        let identity = state.identity
        return [identity.programmeID, identity.revisionID, identity.stateID].allSatisfy { !$0.isEmpty }
            && (state.sessionsPerWeek.map { $0 > 0 } ?? true) && !state.sessions.isEmpty && unique(state.sessions.map(\.id))
            && state.sessions.allSatisfy { session in
                !session.occurrences.isEmpty && unique(session.occurrences.map(\.id))
                    && session.occurrences.allSatisfy { valid($0.prescription) }
            }
    }

    private func valid(_ prescription: ProgrammePlanningPrescription) -> Bool {
        !prescription.exerciseID.isEmpty && prescription.load.value.isFinite && prescription.load.value >= 0
            && prescription.reps.lower > 0 && prescription.reps.upper >= prescription.reps.lower
            && prescription.targetUnit != nil && prescription.perSide != nil
            && prescription.sets > 0 && prescription.restSeconds.isFinite && prescription.restSeconds >= 0 && unique(prescription.requiredEquipmentIDs)
    }

    private func valid(_ bounds: ProgrammePlanningExerciseBounds) -> Bool {
        [bounds.minimumLoad, bounds.maximumLoad, bounds.maximumLoadChange].allSatisfy { $0.isFinite && $0 >= 0 }
            && bounds.maximumLoad >= bounds.minimumLoad
            && bounds.minimumReps > 0 && bounds.maximumReps >= bounds.minimumReps && bounds.maximumRepChange >= 0
            && bounds.minimumSets > 0 && bounds.maximumSets >= bounds.minimumSets && bounds.maximumSetChange >= 0
            && bounds.minimumRestSeconds >= 0 && bounds.maximumRestSeconds >= bounds.minimumRestSeconds
            && bounds.maximumRestChange >= 0
    }

    private func valid(_ policy: ProgrammePlanningPolicy) -> Bool {
        let bounds = policy.structureBounds
        return !policy.id.isEmpty && policy.maximumChanges > 0 && policy.evidence.minimumSessions > 0
            && policy.evidence.maximumAgeSeconds.isFinite && policy.evidence.maximumAgeSeconds >= 0
            && (policy.evidence.minimumReportedEffortForProgression.map { (0 ... 5).contains($0) } ?? true)
            && unique(policy.exerciseRules.map(\.id) + policy.structureRules.map(\.id))
            && unique(policy.alternatives.map(\.id))
            && policy.exerciseRules.allSatisfy { valid($0.bounds) }
            && policy.alternatives.allSatisfy { !$0.sourceExerciseID.isEmpty && valid($0.replacement) && valid($0.bounds) }
            && bounds.minimumSessionsPerWeek > 0 && bounds.maximumSessionsPerWeek >= bounds.minimumSessionsPerWeek
            && bounds.maximumFrequencyChange >= 0 && bounds.maximumMovedSessions >= 0
    }

    private func within(_ value: ProgrammePlanningPrescription, _ bounds: ProgrammePlanningExerciseBounds) -> Bool {
        valid(value) && value.load.unit == bounds.loadUnit
            && value.load.value >= bounds.minimumLoad && value.load.value <= bounds.maximumLoad
            && value.reps.lower >= bounds.minimumReps && value.reps.upper <= bounds.maximumReps
            && value.sets >= bounds.minimumSets && value.sets <= bounds.maximumSets
            && value.restSeconds >= Double(bounds.minimumRestSeconds) && value.restSeconds <= Double(bounds.maximumRestSeconds)
    }

    private func reason(for trigger: ProgrammePlanningTrigger) -> ProgrammePlanningReason {
        switch trigger {
        case .targetMet: .repeatedTargetMet
        case .belowTarget: .repeatedBelowTarget
        case .consistentCompletion: .consistentCompletion
        }
    }

    private func unique(_ ids: [String]) -> Bool {
        ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count
    }

    private func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        try require(!result.overflow, .boundsExceeded)
        return result.partialValue
    }

    private func distance(_ lhs: Int, _ rhs: Int) -> UInt {
        let result = lhs.subtractingReportingOverflow(rhs)
        return result.overflow ? UInt.max : result.partialValue.magnitude
    }

    private func require(_ condition: Bool, _ reason: ProgrammePlanningReason) throws {
        if !condition { throw PlanningFailure(reason) }
    }

    private struct PlanningFailure: Error {
        let reason: ProgrammePlanningReason
        init(_ reason: ProgrammePlanningReason) { self.reason = reason }
    }

    private struct Fingerprint: Encodable {
        let engineVersion: Int
        let state: ProgrammePlanningState
        let constraints: ProgrammePlanningConstraints
        let policy: ProgrammePlanningPolicy?
        let evidence: [ProgrammePlanningEvidence]
        let changes: [ProgrammePlanningChange]
        let reasons: [ProgrammePlanningReason]
    }

    private func makeProposal(
        _ input: ProgrammePlanningInput, changes: [ProgrammePlanningChange], reasons: [ProgrammePlanningReason]
    ) throws -> ProgrammePlanningProposal {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        // The evaluation clock is excluded: retrying unchanged evidence/state
        // yields the same ID until a freshness decision actually changes.
        let fingerprint = Fingerprint(
            engineVersion: 2, state: input.state, constraints: input.constraints, policy: input.policy,
            evidence: input.evidence.sorted { $0.id < $1.id }, changes: changes, reasons: reasons
        )
        let digest = SHA256.hash(data: try encoder.encode(fingerprint))
        let id = "programme-proposal-v2-" + digest.map { String(format: "%02x", $0) }.joined()
        return ProgrammePlanningProposal(
            id: id, basedOn: input.state.identity, policyID: input.policy?.id,
            outcome: changes.isEmpty ? .hold : .change,
            evaluatedEvidenceIDs: input.evidence.filter {
                $0.programmeID == input.state.identity.programmeID
            }.map(\.id).sorted(),
            changes: changes, reasons: reasons
        )
    }
}
