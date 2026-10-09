import XCTest
@testable import ZeroOne

final class ProgrammePlanningTests: XCTestCase {
    private let engine = ProgrammePlanningEngine()
    // These numbers are injected test fixtures, not production training policy.
    private let now = Date(timeIntervalSince1970: 10_000)

    func testReplayRoundTripAndEvidenceOrderProduceSameProposal() throws {
        let input = fixture()
        let originalBytes = try JSONEncoder().encode(input)
        let restored = try JSONDecoder().decode(ProgrammePlanningInput.self, from: originalBytes)
        let first = try engine.proposal(for: input)
        XCTAssertEqual(first, try ProgrammePlanningEngine().proposal(for: restored))
        XCTAssertEqual(first, try engine.proposal(for: copy(input, evidence: Array(input.evidence.reversed()))))
        XCTAssertEqual(first, try engine.proposal(for: copy(input, asOf: now.addingTimeInterval(1))))
        XCTAssertEqual(first, try JSONDecoder().decode(
            ProgrammePlanningProposal.self, from: JSONEncoder().encode(first)
        ))
        XCTAssertEqual(input, try JSONDecoder().decode(ProgrammePlanningInput.self, from: originalBytes))
        XCTAssertTrue(first.id.hasPrefix("programme-proposal-v2-"))
        XCTAssertEqual(first.changes[0].evidence.count, 2)
        XCTAssertFalse(first.changes[0].reason.explanation.isEmpty)
    }

    func testLoadRepsSetsAndRestUseOnlyInjectedAdjustments() throws {
        let cases: [(ProgrammePlanningExerciseAdjustment, ProgrammePlanningDimension)] = [
            (.load(delta: 2.5), .load), (.reps(delta: 1), .reps),
            (.sets(delta: 1), .sets), (.rest(deltaSeconds: 15), .rest)
        ]
        for (adjustment, dimension) in cases {
            let input = fixture(policy: policy(adjustment: adjustment))
            let proposal = try engine.proposal(for: input)
            XCTAssertEqual(proposal.outcome, .change)
            let change = try XCTUnwrap(proposal.changes.first)
            XCTAssertEqual(change.dimension, dimension)
            XCTAssertEqual(change.before, .prescription(prescription()))
            guard case let .prescription(after) = change.after else { return XCTFail("Missing prescription") }
            XCTAssertEqual(after.load.value, dimension == .load ? 12.5 : 10)
            XCTAssertEqual(after.reps, dimension == .reps ? .init(lower: 9, upper: 11) : .init(lower: 8, upper: 10))
            XCTAssertEqual(after.sets, dimension == .sets ? 3 : 2)
            XCTAssertEqual(after.restSeconds, dimension == .rest ? 105 : 90)
        }
    }

    func testBelowTargetCanReduceWorkButCannotIncreaseIt() throws {
        let reduction = fixture(policy: policy(adjustment: .sets(delta: -1), trigger: .belowTarget), reps: 7)
        let proposal = try engine.proposal(for: reduction)
        XCTAssertEqual(proposal.outcome, .change)
        XCTAssertEqual(proposal.changes.first?.reason, .repeatedBelowTarget)
        assertHold(fixture(policy: policy(adjustment: .load(delta: 2.5), trigger: .belowTarget), reps: 7), .invalidPolicy)
    }

    func testNilEffortStillRequiresPositiveRepAndTechniqueEvidence() throws {
        XCTAssertEqual(try engine.proposal(for: fixture(effort: nil)).outcome, .change)
        assertHold(fixture(reps: 9, effort: nil), .noChange)
        assertHold(fixture(effort: nil, technique: nil), .unconfirmedTechnique)
        assertHold(fixture(effort: 0), .noChange)
        assertHold(fixture(technique: false), .unconfirmedTechnique)
    }

    func testCuratedSubstitutionUsesReplacementPrescriptionAndEvidence() throws {
        let replacement = prescription(exercise: "machine-press", load: 5, equipment: ["machine"])
        let alternative = ProgrammePlanningAlternative(
            id: "approved-swap", sourceExerciseID: "press", replacement: replacement, bounds: bounds()
        )
        let proposal = try engine.proposal(for: fixture(policy: policy(
            adjustment: .substitute(alternativeID: "approved-swap"), alternatives: [alternative]
        )))
        XCTAssertEqual(proposal.changes.first?.dimension, .exercise)
        XCTAssertEqual(proposal.changes.first?.after, .prescription(replacement))
        assertHold(fixture(policy: policy(adjustment: .substitute(alternativeID: "unknown"))), .uncuratedAlternative)
    }

    func testEquipmentAndLimitationVetoWinOverSuccessfulEvidence() {
        let base = fixture()
        assertHold(copy(base, constraints: constraints(equipment: [])), .equipmentUnavailable)
        assertHold(copy(base, constraints: constraints(blocked: ["press"])), .limitationReported)
        assertHold(copy(base, constraints: constraints(safety: .unknown)), .unknownConstraints)
        assertHold(copy(base, constraints: constraints(safety: .limitationReported)), .limitationReported)
        assertHold(fixture(safety: .limitationReported), .limitationReported)
        let alternative = ProgrammePlanningAlternative(
            id: "swap", sourceExerciseID: "press",
            replacement: prescription(exercise: "machine-press", equipment: ["machine"]), bounds: bounds()
        )
        let swap = fixture(policy: policy(adjustment: .substitute(alternativeID: "swap"), alternatives: [alternative]))
        assertHold(copy(swap, constraints: constraints(equipment: ["dumbbell"])), .equipmentUnavailable)
        assertHold(copy(swap, constraints: constraints(blocked: ["machine-press"])), .limitationReported)
    }

    func testFrequencyAndOrderRequireWholeProgrammeEvidence() throws {
        let state = currentState(sessionIDs: ["A", "B"])
        let rules = [
            ProgrammePlanningStructureRule(id: "order", trigger: .consistentCompletion, adjustment: .sessionOrder(["B", "A"])),
            ProgrammePlanningStructureRule(id: "frequency", trigger: .targetMet, adjustment: .frequency(sessionsPerWeek: 2))
        ]
        let input = fixture(state: state, policy: policy(exerciseRules: [], structureRules: rules))
        let proposal = try engine.proposal(for: input)
        XCTAssertEqual(proposal.changes.map(\.dimension), [.sessionOrder, .frequency])
        XCTAssertEqual(proposal.changes[0].before, .sessionOrder(["A", "B"]))
        XCTAssertEqual(proposal.changes[0].after, .sessionOrder(["B", "A"]))
        XCTAssertEqual(proposal.changes[1].before, .frequency(3))
        XCTAssertEqual(proposal.changes[1].after, .frequency(2))
        XCTAssertEqual(Set(proposal.changes[1].evidence.map(\.sessionID)), Set(["A", "B"]))
        assertHold(copy(input, evidence: input.evidence.filter { $0.sessionID == "A" }), .insufficientEvidence)
    }

    func testStructureBoundsAndSessionConstraintsCannotBeBypassed() {
        let state = currentState(sessionIDs: ["A", "B"])
        let invalidOrder = ProgrammePlanningStructureRule(id: "order", trigger: .targetMet, adjustment: .sessionOrder(["A", "C"]))
        let frequency = ProgrammePlanningStructureRule(id: "frequency", trigger: .targetMet, adjustment: .frequency(sessionsPerWeek: 8))
        assertHold(fixture(state: state, policy: policy(exerciseRules: [], structureRules: [invalidOrder])), .invalidPolicy)
        assertHold(fixture(state: state, policy: policy(exerciseRules: [], structureRules: [frequency])), .sessionNotAllowed)
        let boundedFrequency = ProgrammePlanningStructureRule(id: "frequency", trigger: .targetMet, adjustment: .frequency(sessionsPerWeek: 5))
        assertHold(fixture(state: state, policy: policy(exerciseRules: [], structureRules: [boundedFrequency])), .boundsExceeded)
        assertHold(copy(fixture(state: state), constraints: constraints(allowed: ["A"])), .sessionNotAllowed)
    }

    func testRepeatedExercisesUseOccurrenceIdentity() throws {
        let state = currentState(occurrenceIDs: ["first", "second"])
        let first = fixture(state: state, policy: policy(exerciseRules: [rule(occurrence: "first")]), repsByOccurrence: ["second": 7])
        let second = fixture(state: state, policy: policy(exerciseRules: [rule(occurrence: "second")]), repsByOccurrence: ["second": 7])
        let proposal = try engine.proposal(for: first)
        XCTAssertEqual(proposal.outcome, .change)
        XCTAssertEqual(proposal.changes[0].evidence.map(\.occurrenceID), ["first", "first"])
        assertHold(second, .noChange)
    }

    func testMixedUnitsHoldAndPoundsRemainPounds() throws {
        assertHold(fixture(recordedUnit: .pounds), .incomparableUnits)
        let state = currentState(unit: .pounds)
        let proposal = try engine.proposal(for: fixture(state: state, policy: policy(unit: .pounds)))
        guard case let .prescription(after) = proposal.changes.first?.after else { return XCTFail("Missing change") }
        XCTAssertEqual(after.load, Load(12.5, unit: .pounds))
    }

    func testMissingPartialLegacyAndStaleEvidenceHold() {
        assertHold(fixture(recordCount: 1), .insufficientEvidence)
        assertHold(fixture(completion: .partial), .partialEvidence)
        assertHold(fixture(completion: .legacySummary), .legacyEvidence)
        assertHold(fixture(includeDetails: false), .legacyEvidence)
        assertHold(fixture(revision: "older-revision"), .staleEvidence)
        assertHold(copy(fixture(), asOf: now.addingTimeInterval(5_000)), .staleEvidence)
        assertHold(copy(fixture(), asOf: now.addingTimeInterval(-1_000)), .staleEvidence)
    }

    func testInvalidRecordedValuesAndUnknownSafetyHold() {
        assertHold(fixture(reps: 0), .invalidEvidence)
        assertHold(fixture(effort: 6), .invalidEvidence)
        assertHold(fixture(safety: .unknown), .unknownConstraints)
        assertHold(fixture(recordedLoad: 12.5), .incomparablePrescription)
    }

    func testRecentPartialEvidenceIsNotSkippedForOlderSuccess() {
        let base = fixture()
        let recentPartial = fixture(completion: .partial).evidence[0]
        assertHold(copy(base, evidence: [recentPartial, base.evidence[1]]), .partialEvidence)
    }

    func testMissingPolicyAndActiveSessionHold() {
        let base = fixture()
        assertHold(ProgrammePlanningInput(state: base.state, evidence: base.evidence,
                                         constraints: base.constraints, policy: nil, asOf: now), .missingPolicy)
        assertHold(fixture(state: currentState(active: true)), .activeSession)
        assertHold(copy(base, constraints: ProgrammePlanningConstraints(
            safety: .clear, availableEquipmentIDs: nil, blockedExerciseIDs: [], allowedSessionIDs: ["A"], maximumSessionsPerWeek: 5
        )), .unknownConstraints)
    }

    func testExcessiveAndNonFiniteChangesHoldWithoutClamping() {
        assertHold(fixture(policy: policy(adjustment: .load(delta: 100))), .boundsExceeded)
        assertHold(fixture(policy: policy(adjustment: .reps(delta: Int.max))), .boundsExceeded)
        assertHold(fixture(policy: policy(adjustment: .sets(delta: -5))), .boundsExceeded)
        assertHold(fixture(policy: policy(adjustment: .rest(deltaSeconds: 1_000))), .boundsExceeded)
        assertHold(fixture(policy: policy(adjustment: .load(delta: .nan))), .invalidPolicy)
    }

    func testDuplicateEvidenceAndConflictingChangesHold() {
        let base = fixture()
        assertHold(copy(base, evidence: [base.evidence[0], base.evidence[0]]), .duplicateEvidence)
        let overlapping = [rule(id: "one"), rule(id: "two", adjustment: .sets(delta: 1))]
        assertHold(fixture(policy: policy(exerciseRules: overlapping)), .conflictingRules)
        let state = currentState(occurrenceIDs: ["first", "second"])
        let rules = [rule(id: "one", occurrence: "first"), rule(id: "two", occurrence: "second")]
        assertHold(fixture(state: state, policy: policy(exerciseRules: rules, maximumChanges: 1)), .tooManyChanges)
    }

    func testIncompleteDetailsAndReusedSetIDsCannotMasqueradeAsCompleteEvidence() throws {
        let input = fixture()
        let original = input.evidence[0]
        let occurrence = try XCTUnwrap(original.occurrences?.first)
        let incomplete = ProgrammePlanningRecordedOccurrence(
            occurrenceID: occurrence.occurrenceID, prescription: occurrence.prescription,
            sets: Array(occurrence.sets.prefix(1))
        )
        func record(_ occurrences: [ProgrammePlanningRecordedOccurrence], id: String? = nil) -> ProgrammePlanningEvidence {
            .init(id: id ?? original.id, programmeID: original.programmeID, revisionID: original.revisionID,
                  sessionID: original.sessionID, completedAt: original.completedAt,
                  completion: .complete, occurrences: occurrences)
        }
        assertHold(copy(input, evidence: [record([incomplete]), input.evidence[1]]), .partialEvidence)
        assertHold(copy(input, evidence: [record([]), input.evidence[1]]), .missingEvidence)
        assertHold(copy(input, evidence: [original, record([occurrence], id: "reused-sets")]), .duplicateEvidence)
        let held = try engine.proposal(for: copy(input, evidence: [record([]), input.evidence[1]]))
        XCTAssertEqual(held.evaluatedEvidenceIDs, input.evidence.map(\.id).sorted())
    }

    func testInvalidPolicyAndUnknownFrequencyAvailabilityHold() {
        let base = policy()
        let invalid = ProgrammePlanningPolicy(
            id: base.id, evidence: .init(minimumSessions: 0, maximumAgeSeconds: 1_000,
                                        minimumReportedEffortForProgression: nil),
            exerciseRules: base.exerciseRules, alternatives: [], structureRules: [],
            structureBounds: base.structureBounds, maximumChanges: base.maximumChanges
        )
        assertHold(fixture(policy: invalid), .invalidPolicy)
        let frequency = ProgrammePlanningStructureRule(id: "frequency", trigger: .targetMet,
                                                      adjustment: .frequency(sessionsPerWeek: 4))
        let input = fixture(policy: policy(exerciseRules: [], structureRules: [frequency]))
        assertHold(copy(input, constraints: .init(safety: .clear, availableEquipmentIDs: ["dumbbell"],
                   blockedExerciseIDs: [], allowedSessionIDs: ["A"], maximumSessionsPerWeek: nil)), .unknownConstraints)
    }

    func testDifferentStateOrPolicyHasDifferentProposalIdentity() throws {
        let base = try engine.proposal(for: fixture())
        XCTAssertNotEqual(base.id, try engine.proposal(for: fixture(state: currentState(stateID: "state-2"))).id)
        XCTAssertNotEqual(base.id, try engine.proposal(for: fixture(policy: policy(adjustment: .load(delta: 1)))).id)
    }

    func testNoOpPolicyReturnsAnExplainedHold() {
        assertHold(fixture(policy: policy(adjustment: .load(delta: 0))), .noChange)
        assertHold(fixture(policy: policy(exerciseRules: [])), .noChange)
    }

    private func assertHold(_ input: ProgrammePlanningInput, _ reason: ProgrammePlanningReason,
                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            let proposal = try engine.proposal(for: input)
            XCTAssertEqual(proposal.outcome, .hold, file: file, line: line)
            XCTAssertTrue(proposal.changes.isEmpty, file: file, line: line)
            XCTAssertEqual(proposal.reasons, [reason], file: file, line: line)
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func prescription(exercise: String = "press", load: Double = 10,
                              unit: LoadUnit = .kilograms, equipment: [String] = ["dumbbell"]) -> ProgrammePlanningPrescription {
        .init(exerciseID: exercise, load: Load(load, unit: unit), reps: .init(lower: 8, upper: 10),
              sets: 2, restSeconds: 90, requiredEquipmentIDs: equipment)
    }

    private func bounds(unit: LoadUnit = .kilograms) -> ProgrammePlanningExerciseBounds {
        .init(loadUnit: unit, minimumLoad: 0, maximumLoad: 100, maximumLoadChange: 2.5,
              minimumReps: 1, maximumReps: 20, maximumRepChange: 2,
              minimumSets: 1, maximumSets: 4, maximumSetChange: 1,
              minimumRestSeconds: 30, maximumRestSeconds: 180, maximumRestChange: 30)
    }

    private func rule(id: String = "rule", occurrence: String = "first",
                      adjustment: ProgrammePlanningExerciseAdjustment = .load(delta: 2.5),
                      trigger: ProgrammePlanningTrigger = .targetMet,
                      unit: LoadUnit = .kilograms) -> ProgrammePlanningExerciseRule {
        .init(id: id, sessionID: "A", occurrenceID: occurrence, trigger: trigger, adjustment: adjustment, bounds: bounds(unit: unit))
    }

    private func policy(adjustment: ProgrammePlanningExerciseAdjustment = .load(delta: 2.5),
                        trigger: ProgrammePlanningTrigger = .targetMet, unit: LoadUnit = .kilograms,
                        exerciseRules: [ProgrammePlanningExerciseRule]? = nil,
                        alternatives: [ProgrammePlanningAlternative] = [],
                        structureRules: [ProgrammePlanningStructureRule] = [], maximumChanges: Int = 4) -> ProgrammePlanningPolicy {
        .init(id: "fixture-policy-1", evidence: .init(minimumSessions: 2, maximumAgeSeconds: 1_000,
              minimumReportedEffortForProgression: 2),
              exerciseRules: exerciseRules ?? [rule(adjustment: adjustment, trigger: trigger, unit: unit)],
              alternatives: alternatives, structureRules: structureRules,
              structureBounds: .init(minimumSessionsPerWeek: 1, maximumSessionsPerWeek: 5,
                                     maximumFrequencyChange: 1, maximumMovedSessions: 2), maximumChanges: maximumChanges)
    }

    private func currentState(sessionIDs: [String] = ["A"], occurrenceIDs: [String] = ["first"],
                              unit: LoadUnit = .kilograms, active: Bool = false, stateID: String = "state-1") -> ProgrammePlanningState {
        .init(identity: .init(programmeID: "programme", revisionID: "revision-1", stateID: stateID),
              sessions: sessionIDs.map { sessionID in
                  .init(id: sessionID, occurrences: occurrenceIDs.map { .init(id: $0, prescription: prescription(unit: unit)) })
              }, sessionsPerWeek: 3, hasActiveSession: active)
    }

    private func constraints(equipment: [String] = ["dumbbell", "machine"], blocked: [String] = [],
                             safety: ProgrammePlanningSafety = .clear, allowed: [String] = ["A", "B"]) -> ProgrammePlanningConstraints {
        .init(safety: safety, availableEquipmentIDs: equipment, blockedExerciseIDs: blocked,
              allowedSessionIDs: allowed, maximumSessionsPerWeek: 5)
    }

    private func fixture(state: ProgrammePlanningState? = nil, policy: ProgrammePlanningPolicy? = nil,
                         reps: Int = 10, effort: Int? = nil, technique: Bool? = true,
                         safety: ProgrammePlanningSafety = .clear, completion: ProgrammePlanningCompletion = .complete,
                         recordCount: Int = 2, includeDetails: Bool = true, revision: String = "revision-1",
                         recordedUnit: LoadUnit? = nil, recordedLoad: Double? = nil,
                         repsByOccurrence: [String: Int] = [:]) -> ProgrammePlanningInput {
        let state = state ?? currentState()
        let records = state.sessions.flatMap { session in
            (0 ..< recordCount).map { index in
                let recordID = "record-\(session.id)-\(index)"
                return ProgrammePlanningEvidence(
                    id: recordID, programmeID: "programme", revisionID: revision, sessionID: session.id,
                    completedAt: now.addingTimeInterval(-Double((index + 1) * 100)), completion: completion,
                    occurrences: includeDetails ? session.occurrences.map { occurrence in
                        .init(occurrenceID: occurrence.id, prescription: occurrence.prescription,
                              sets: (0 ..< occurrence.prescription.sets).map { set in
                                  .init(id: "\(recordID)-\(occurrence.id)-\(set)",
                                        load: Load(recordedLoad ?? occurrence.prescription.load.value, unit: recordedUnit ?? occurrence.prescription.load.unit),
                                        reps: repsByOccurrence[occurrence.id] ?? reps, effortRemaining: effort,
                                        techniqueConfirmed: technique, safety: safety, isPerSide: false)
                              })
                    } : nil
                )
            }
        }
        return .init(state: state, evidence: records, constraints: constraints(), policy: policy ?? self.policy(), asOf: now)
    }

    private func copy(_ input: ProgrammePlanningInput, evidence: [ProgrammePlanningEvidence]? = nil,
                      constraints: ProgrammePlanningConstraints? = nil, asOf: Date? = nil) -> ProgrammePlanningInput {
        .init(state: input.state, evidence: evidence ?? input.evidence,
              constraints: constraints ?? input.constraints, policy: input.policy, asOf: asOf ?? input.asOf)
    }
}
