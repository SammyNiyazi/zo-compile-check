import XCTest
@testable import ZeroOne

@MainActor
final class ProgrammePlanningProvenanceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var base: WorkoutProgramme { WorkoutProgrammeLibrary.programme(id: .zeroOneStart)! }
    private var unknownConstraints: ProgrammePlanningConstraints {
        .init(safety: .unknown, availableEquipmentIDs: nil, blockedExerciseIDs: [], allowedSessionIDs: nil, maximumSessionsPerWeek: nil)
    }

    func testFactoryBindsStableSlotsAcrossRebuiltRepeatedExercises() throws {
        let first = programme([plan(), plan()]).makeSession(asOf: now)
        let second = programme([plan(), plan()]).makeSession(asOf: now)
        let a = try XCTUnwrap(first.programmeProvenance); let b = try XCTUnwrap(second.programmeProvenance)
        XCTAssertEqual(a.sessionID, "session-0")
        XCTAssertEqual(a.occurrences.map(\.templateID), ["slot-0", "slot-1"])
        XCTAssertNotEqual(a.occurrences.map(\.executionID), b.occurrences.map(\.executionID))
        XCTAssertEqual(a.authoredRevision, b.authoredRevision)
        XCTAssertEqual(a.effectiveRevision, b.effectiveRevision)
        XCTAssertEqual(a.startedPrescription, b.startedPrescription)
        XCTAssertEqual(a.occurrences[0].startedTarget?.restSeconds, 90.25)
        XCTAssertEqual(a.occurrences[0].requiredEquipmentIDs, ["dumbbell"])
    }

    func testStartPrescriptionBindsLoadWithoutChangingAuthoredOrEffectiveRevision() throws {
        let source = programme([plan()]); let selected = source.sessions[0]
        let first = try WorkoutProgrammeProvenance.capture(programme: source, selected: selected, startedPlans: selected.exercisePlans)
        var raw = try object(selected.exercisePlans[0]); raw["targetLoad"] = ["value": 12, "unit": "kg"]
        let changed = try WorkoutProgrammeProvenance.capture(programme: source, selected: selected,
            startedPlans: [decode(ExercisePlan.self, raw)])
        XCTAssertEqual(first.authoredRevision, changed.authoredRevision)
        XCTAssertEqual(first.effectiveRevision, changed.effectiveRevision)
        XCTAssertNotEqual(first.startedPrescription, changed.startedPrescription)
        XCTAssertEqual(changed.occurrences[0].startedTarget?.targetLoad, Load(12))
    }

    func testAcceptedVolumeRetainsAuthoredSourceAndActualEffectiveCounts() throws {
        let source = programme([plan(sets: 3)])
        let original = try ProgrammeVolumeSource.fingerprint(source)
        let effective = try ProgrammeVolumeSource.effective(source,
            revision: .init(programmeID: source.id, baseline: original, policyVersion: ProgrammeVolumePlanner.policyVersion, acceptedAt: now), at: now)
        let provenance = try XCTUnwrap(effective.makeSession(asOf: now).programmeProvenance)
        XCTAssertEqual(provenance.authoredRevision, original)
        XCTAssertEqual(provenance.effectiveRevision, try ProgrammeVolumeSource.fingerprint(effective))
        XCTAssertNotEqual(provenance.authoredRevision, provenance.effectiveRevision)
        XCTAssertEqual(provenance.occurrences[0].startedTarget?.plannedSetCount, 2)
    }

    func testTimeAdaptationKeepsSourceBindingsAndRotatesBySessionDespiteChangedTitle() throws {
        let source = programme([plan(sets: 6, rest: 300), plan(sets: 6, rest: 300)], sessions: 2)
        let original = source.makeSession(sessionID: "session-0", asOf: now)
        let adapted = try DeterministicWorkoutAdapter().proposal(for: original, targetMinutes: 10).adaptedSession
        let a = try XCTUnwrap(adapted.programmeProvenance)
        XCTAssertTrue(adapted.isAdapted)
        XCTAssertNotEqual(adapted.title, original.title)
        XCTAssertEqual(a.startedPrescription, original.programmeProvenance?.startedPrescription)
        XCTAssertEqual(a.occurrences.map(\.executionID), adapted.exercises.map(\.id))
        let saved = try completed(adapted, at: now.addingTimeInterval(-1_000))
        XCTAssertEqual(source.makeSession(previousHistory: [saved], asOf: now).programmeProvenance?.sessionID, "session-1")
        XCTAssertEqual(saved.programmeProvenance, a)
    }

    func testDemandAdaptationsKeepStartSourceSeparateFromLoggedTarget() throws {
        let original = programme([plan(sets: 3)]).makeSession(asOf: now)
        let context = try volumeContext(programme([plan(sets: 3)]))
        for change in [WorkoutDemandChange.fewerSets, .longerRest] {
            let adapted = try WorkoutDemandAdapter().proposal(for: original, change: change,
                assessment: context.assessment, at: now, calendar: calendar).adaptedSession
            XCTAssertEqual(adapted.programmeProvenance, original.programmeProvenance)
            XCTAssertNotEqual(adapted.exercises[0].plan, original.exercises[0].plan)
            let saved = try completed(adapted, at: now.addingTimeInterval(-1_000))
            let observed = try observation(programme([plan(sets: 3)]), history: [saved])
            XCTAssertEqual(observed.input.evidence[0].occurrences?.first?.prescription.sets, adapted.exercises[0].plan.plannedSetCount)
            XCTAssertEqual(observed.input.evidence[0].occurrences?.first?.prescription.restSeconds, adapted.exercises[0].plan.restSeconds)
            XCTAssertEqual(saved.programmeProvenance?.occurrences[0].startedTarget?.plannedSetCount, 3)
        }
    }

    func testCurrentSnapshotRetainsEmbeddedProvenanceAndOlderVersionRejectsIt() throws {
        let original = programme([plan(sets: 6, rest: 300)]).makeSession(asOf: now)
        let pending = try DeterministicWorkoutAdapter().proposal(for: original, targetMinutes: 10)
        let snapshot = ActiveWorkoutSnapshot(session: original, enteredLoadValue: 10, enteredReps: 12, enteredRIR: 3,
            isPaused: false, pausedRemainingRestSeconds: nil, pendingAdaptation: pending,
            sessionBeforeAdaptation: pending.originalSession, lastSetGuidance: nil)
        XCTAssertEqual(snapshot.version, ActiveWorkoutSnapshot.currentVersion)
        let restored = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(restored.isCompatible)
        XCTAssertEqual(restored.pendingAdaptation?.adaptedSession.programmeProvenance, pending.adaptedSession.programmeProvenance)
        var old = try object(snapshot); old["version"] = 6
        let rejected = try decode(ActiveWorkoutSnapshot.self, old)
        XCTAssertFalse(rejected.isCompatible)
        var missingMain = old; var main = try XCTUnwrap(missingMain["session"] as? [String: Any])
        main.removeValue(forKey: "programmeProvenance"); missingMain["session"] = main
        XCTAssertFalse(try decode(ActiveWorkoutSnapshot.self, missingMain).isCompatible)
    }

    func testLegacySnapshotKeepsUnknownProvenanceAndExactStoredBytes() throws {
        let current = ActiveWorkoutSnapshot(session: programme([plan()]).makeSession(asOf: now), enteredLoadValue: 10,
            enteredReps: 12, enteredRIR: 3, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        var old = try object(current); old["version"] = 6
        var main = try XCTUnwrap(old["session"] as? [String: Any]); main.removeValue(forKey: "programmeProvenance"); old["session"] = main
        let bytes = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("active-workout.json")
        let store = FileActiveWorkoutStore(directory: directory)
        // The actual store filename is resolved from its established contract.
        try bytes.write(to: url)
        let restored = try XCTUnwrap(store.load())
        XCTAssertTrue(restored.isCompatible); XCTAssertNil(restored.session.programmeProvenance)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testHistoryEnvelopeAndExportIntroduceProvenanceWithoutLoss() throws {
        let saved = try completed(programme([plan()]).makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let bytes = try WorkoutHistoryStorageCodec.encode([saved])
        XCTAssertEqual(try WorkoutHistoryStorageCodec.decode(bytes), [saved])
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 2)
        envelope["version"] = 1
        XCTAssertThrowsError(try WorkoutHistoryStorageCodec.decode(JSONSerialization.data(withJSONObject: envelope)))
        XCTAssertThrowsError(try WorkoutHistoryStorageCodec.decode(JSONEncoder().encode([saved])))
        let package = export([saved])
        XCTAssertEqual(package.schemaVersion, 6)
        XCTAssertEqual(try WorkoutHistoryImportDecoder.decode(JSONEncoder().encode(package)).entries, [saved])
        var old = try object(package); old["schemaVersion"] = 5
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.decode(JSONSerialization.data(withJSONObject: old)))
    }

    func testOlderHistoryEnvelopeReadsWithoutBackfillOrRewrite() throws {
        let saved = try completed(programme([plan()]).makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        var row = try object(saved); row.removeValue(forKey: "programmeProvenance")
        let envelope: [String: Any] = ["format": "zeroone-workout-history", "version": 1, "entries": [row]]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let restored = try WorkoutHistoryStorageCodec.decode(bytes)
        XCTAssertNil(restored[0].programmeProvenance)
        XCTAssertEqual(restored[0].exercises, saved.exercises)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json"); try bytes.write(to: url)
        XCTAssertEqual(try FileWorkoutHistoryStore(directory: directory).load(), restored)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testStrictProvenanceRejectsUnknownFieldsAndMisboundTarget() throws {
        let value = try XCTUnwrap(programme([plan(), plan()]).makeSession(asOf: now).programmeProvenance)
        var row = try object(value); row["futureFact"] = 1
        XCTAssertThrowsError(try decode(WorkoutProgrammeProvenance.self, row))
        row = try object(value); var occurrences = try XCTUnwrap(row["occurrences"] as? [[String: Any]])
        occurrences[1]["templateID"] = "slot-0"; row["occurrences"] = occurrences
        XCTAssertThrowsError(try decode(WorkoutProgrammeProvenance.self, row))
        row = try object(value); occurrences = try XCTUnwrap(row["occurrences"] as? [[String: Any]])
        var target = try XCTUnwrap(occurrences[0]["startedTarget"] as? [String: Any])
        target["occurrenceID"] = UUID().uuidString; occurrences[0]["startedTarget"] = target; row["occurrences"] = occurrences
        XCTAssertThrowsError(try decode(WorkoutProgrammeProvenance.self, row))
        row = try object(value); occurrences = try XCTUnwrap(row["occurrences"] as? [[String: Any]])
        target = try XCTUnwrap(occurrences[0]["startedTarget"] as? [String: Any]); target["futureFact"] = 1
        occurrences[0]["startedTarget"] = target; row["occurrences"] = occurrences
        XCTAssertThrowsError(try decode(WorkoutProgrammeProvenance.self, row))
        row = try object(value); occurrences = try XCTUnwrap(row["occurrences"] as? [[String: Any]])
        target = try XCTUnwrap(occurrences[0]["startedTarget"] as? [String: Any])
        let exercise: [String: Any] = ["rawValue": try XCTUnwrap(target["exerciseID"] as? String), "futureFact": 1]
        target["exerciseID"] = exercise; occurrences[0]["startedTarget"] = target; row["occurrences"] = occurrences
        XCTAssertThrowsError(try decode(WorkoutProgrammeProvenance.self, row))
    }

    func testOwnerMismatchAndMetadataOnlyRetryConflictAreNotSilentlyAccepted() throws {
        let saved = try completed(programme([plan()]).makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        var wrongOwner = try object(saved); wrongOwner["programmeID"] = WorkoutProgrammeID.arms.rawValue
        XCTAssertThrowsError(try WorkoutHistoryImportDecoder.validate([decode(WorkoutHistoryEntry.self, wrongOwner)]))
        var changed = try object(saved); var provenance = try XCTUnwrap(changed["programmeProvenance"] as? [String: Any])
        provenance["authoredRevision"] = String(repeating: "a", count: 64); changed["programmeProvenance"] = provenance
        let corrected = try decode(WorkoutHistoryEntry.self, changed)
        XCTAssertFalse(saved.hasSameSummary(as: corrected))
        XCTAssertNotEqual(WorkoutProgressionEvidence.fingerprint(saved), WorkoutProgressionEvidence.fingerprint(corrected))
    }

    func testProjectionRetainsTimeSideFractionalRestAndUnknownHumanFacts() throws {
        let source = programme([plan(timed: true, perSide: true)])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let result = try observation(source, history: [saved])
        let occurrence = try XCTUnwrap(result.input.evidence[0].occurrences?.first)
        XCTAssertEqual(occurrence.occurrenceID, "slot-0")
        XCTAssertEqual(occurrence.prescription.targetUnit, .seconds)
        XCTAssertEqual(occurrence.prescription.perSide, true)
        XCTAssertEqual(occurrence.prescription.restSeconds, 90.25)
        XCTAssertEqual(occurrence.sets[0].durationSeconds, 12)
        XCTAssertEqual(occurrence.sets[0].reps, 0)
        XCTAssertEqual(occurrence.sets[0].isPerSide, true)
        XCTAssertNil(occurrence.sets[0].techniqueConfirmed)
        XCTAssertEqual(occurrence.sets[0].safety, .unknown)
        XCTAssertEqual(result.proposal.reasons, [.missingPolicy])
    }

    func testUnknownCalendarAndRepeatedObservationNeverInventFrequencyOrNewIdentity() throws {
        let source = programme([plan()])
        let first = try observation(source, history: [])
        let second = try ProgrammePlanningObservation.capture(programme: source, history: [], sessionsPerWeek: nil,
            hasActiveSession: false, constraints: unknownConstraints, at: now.addingTimeInterval(1))
        XCTAssertNil(first.input.state.sessionsPerWeek)
        XCTAssertEqual(first.sourceFingerprint, second.sourceFingerprint)
        XCTAssertEqual(first.proposal, second.proposal)
        XCTAssertEqual(first.proposal.reasons, [.missingPolicy])
    }

    func testMissingExplicitTargetStaysUnknownInPlanningState() throws {
        var raw = try object(plan()); raw.removeValue(forKey: "targetPrescription")
        let source = try programme([decode(ExercisePlan.self, raw)])
        let observed = try observation(source, history: [])
        let target = try XCTUnwrap(observed.input.state.sessions.first?.occurrences.first?.prescription)
        XCTAssertNil(target.targetUnit); XCTAssertNil(target.perSide)
        XCTAssertEqual(observed.proposal.reasons, [.invalidState])
        XCTAssertNil(source.makeSession(asOf: now).programmeProvenance?.occurrences[0].startedTarget)
    }

    func testReversedStoredSetOrderCannotLoseChronologyDuringProjection() throws {
        let source = programme([plan()])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        var row = try object(saved); var exercises = try XCTUnwrap(row["exercises"] as? [[String: Any]])
        let sets = try XCTUnwrap(exercises[0]["completedSets"] as? [[String: Any]])
        exercises[0]["completedSets"] = Array(sets.reversed()); row["exercises"] = exercises
        let reordered = try decode(WorkoutHistoryEntry.self, row)
        XCTAssertNoThrow(try WorkoutHistoryImportDecoder.validate([reordered]))
        XCTAssertThrowsError(try observation(source, history: [reordered]))
    }

    func testNewUnknownSessionBarrierIsNotSkippedForOlderDetailedWork() throws {
        let source = programme([plan()])
        let older = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-2_000))
        let recent = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        var row = try object(recent); row.removeValue(forKey: "programmeProvenance")
        let unknown = try decode(WorkoutHistoryEntry.self, row)
        let result = try ProgrammePlanningObservation.capture(programme: source, history: [older, unknown], sessionsPerWeek: 2,
            hasActiveSession: false, constraints: clearConstraints, policy: fixturePolicy(source), at: now)
        XCTAssertEqual(result.input.evidence.first?.id, unknown.id.uuidString)
        XCTAssertNil(result.input.evidence.first?.sessionID)
        XCTAssertEqual(result.proposal.reasons, [.legacyEvidence])
        XCTAssertTrue(result.proposal.evaluatedEvidenceIDs.contains(older.id.uuidString))
        XCTAssertTrue(result.proposal.evaluatedEvidenceIDs.contains(unknown.id.uuidString))
    }

    func testChangedActualPrescriptionBlocksComparisonBeforeUnknownTechnique() throws {
        let source = programme([plan(sets: 3)])
        let initial = source.makeSession(asOf: now)
        let adapted = try WorkoutDemandAdapter().proposal(for: initial, change: .fewerSets,
            assessment: volumeContext(source).assessment, at: now, calendar: calendar).adaptedSession
        let saved = try completed(adapted, at: now.addingTimeInterval(-1_000))
        let result = try ProgrammePlanningObservation.capture(programme: source, history: [saved], sessionsPerWeek: 2,
            hasActiveSession: false, constraints: clearConstraints, policy: fixturePolicy(source), at: now)
        XCTAssertEqual(result.proposal.reasons, [.incomparablePrescription])
        XCTAssertEqual(saved.completedSetCount, 2)
    }

    func testFreshProgrammeVolumeAcceptanceBindsMetadataOnlyHistoryCorrection() throws {
        let source = programme([plan(sets: 3)])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        var context = try volumeContext(source)
        context.planningObservation = try observation(source, history: [saved])
        let planner = ProgrammeVolumePlanner()
        let offered = try planner.proposal(change: .ease, context: context, at: now, calendar: calendar)
        XCTAssertEqual(offered.planningSource, context.planningObservation?.sourceFingerprint)
        XCTAssertNoThrow(try planner.revalidated(offered, context: context, at: now.addingTimeInterval(1), calendar: calendar))
        var row = try object(saved); var provenance = try XCTUnwrap(row["programmeProvenance"] as? [String: Any])
        provenance["startedPrescription"] = String(repeating: "b", count: 64); row["programmeProvenance"] = provenance
        context.planningObservation = try observation(source, history: [decode(WorkoutHistoryEntry.self, row)])
        XCTAssertThrowsError(try planner.revalidated(offered, context: context, at: now.addingTimeInterval(1), calendar: calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
        XCTAssertEqual(context.assessment, try volumeContext(source).assessment)
    }

    func testActualHistoryReadFailureDoesNotReplacePlanningWithCachedSuccess() throws {
        let saved = try completed(programme([plan()]).makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let store = ProvenanceHistoryStore([saved]); let model = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try model.confirmedEntries(), [saved])
        store.failRead = true
        XCTAssertThrowsError(try model.confirmedEntries())
        XCTAssertEqual(model.availability, .unavailable)
    }

    func testActualHistoryRetryRejectsChangedProvenanceWithoutWriting() throws {
        let session = try completedSession(programme([plan()]).makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let saved = WorkoutHistoryEntry(session: session)
        let store = ProvenanceHistoryStore([saved]); let repository = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try repository.record(session), .alreadyRecorded)
        var row = try object(session); var provenance = try XCTUnwrap(row["programmeProvenance"] as? [String: Any])
        provenance["authoredRevision"] = String(repeating: "c", count: 64); row["programmeProvenance"] = provenance
        let changed = try decode(WorkoutSession.self, row)
        XCTAssertThrowsError(try repository.record(changed)) { error in
            if case WorkoutPersistenceError.conflictingSession = error { return }
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(store.entries, [saved]); XCTAssertEqual(store.writes, 0)
    }

    func testTypedTimedEvidenceUsesDurationAndKeepsFractionalRestInInjectedRule() throws {
        let source = programme([plan(timed: true, perSide: true)])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let input = try qualifiedFixture(source, history: [saved])
        let proposal = try ProgrammePlanningEngine().proposal(for: input)
        XCTAssertEqual(proposal.outcome, .change)
        guard case let .prescription(after) = try XCTUnwrap(proposal.changes.first).after else { return XCTFail("Missing target") }
        XCTAssertEqual(after.targetUnit, .seconds); XCTAssertEqual(after.perSide, true)
        XCTAssertEqual(after.restSeconds, 100.25)
        XCTAssertEqual(proposal.changes.first?.evidence.first?.setIDs, saved.exercises?[0].completedSets.map { $0.id.uuidString })
    }

    func testUnknownSideCannotPassAnOtherwiseQualifiedPlanningRule() throws {
        let source = programme([plan()])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let initial = try qualifiedFixture(source, history: [saved])
        let evidence = initial.evidence.map { record in
            ProgrammePlanningEvidence(id: record.id, programmeID: record.programmeID, revisionID: record.revisionID,
                sessionID: record.sessionID, completedAt: record.completedAt, completion: record.completion,
                occurrences: record.occurrences?.map { occurrence in
                    .init(occurrenceID: occurrence.occurrenceID, prescription: occurrence.prescription,
                        sets: occurrence.sets.map { set in
                            var unknown = set; unknown.isPerSide = nil; return unknown
                        })
                })
        }
        let input = ProgrammePlanningInput(state: initial.state, evidence: evidence, constraints: initial.constraints,
            policy: initial.policy, asOf: now)
        XCTAssertEqual(try ProgrammePlanningEngine().proposal(for: input).reasons, [.invalidEvidence])
    }

    func testUnknownCurrentFrequencyBlocksInjectedFrequencyRule() throws {
        let source = programme([plan()])
        let saved = try completed(source.makeSession(asOf: now), at: now.addingTimeInterval(-1_000))
        let initial = try qualifiedFixture(source, history: [saved])
        let policy = try XCTUnwrap(initial.policy)
        let frequency = ProgrammePlanningPolicy(id: "frequency-fixture", evidence: policy.evidence, exerciseRules: [],
            alternatives: [], structureRules: [.init(id: "frequency", trigger: .consistentCompletion, adjustment: .frequency(sessionsPerWeek: 3))],
            structureBounds: policy.structureBounds, maximumChanges: 1)
        let state = ProgrammePlanningState(identity: initial.state.identity, sessions: initial.state.sessions,
            sessionsPerWeek: nil, hasActiveSession: false)
        let input = ProgrammePlanningInput(state: state, evidence: initial.evidence, constraints: initial.constraints, policy: frequency, asOf: now)
        XCTAssertEqual(try ProgrammePlanningEngine().proposal(for: input).reasons, [.unknownConstraints])
    }

    private func qualifiedFixture(_ source: WorkoutProgramme, history: [WorkoutHistoryEntry]) throws -> ProgrammePlanningInput {
        let observed = try ProgrammePlanningObservation.capture(programme: source, history: history, sessionsPerWeek: 2,
            hasActiveSession: false, constraints: clearConstraints, policy: fixturePolicy(source), at: now)
        // Test-only explicit answers. Production projection never supplies these.
        let evidence = observed.input.evidence.map { record in
            ProgrammePlanningEvidence(id: record.id, programmeID: record.programmeID, revisionID: record.revisionID,
                sessionID: record.sessionID, completedAt: record.completedAt, completion: record.completion,
                occurrences: record.occurrences?.map { occurrence in
                    .init(occurrenceID: occurrence.occurrenceID, prescription: occurrence.prescription,
                        sets: occurrence.sets.map { set in
                            .init(id: set.id, load: set.load, reps: set.reps, effortRemaining: set.effortRemaining,
                                techniqueConfirmed: true, safety: .clear, durationSeconds: set.durationSeconds, isPerSide: set.isPerSide)
                        })
                })
        }
        return .init(state: observed.input.state, evidence: evidence, constraints: observed.input.constraints,
            policy: observed.input.policy, asOf: now)
    }

    private var clearConstraints: ProgrammePlanningConstraints {
        .init(safety: .clear, availableEquipmentIDs: ["dumbbell"], blockedExerciseIDs: [],
            allowedSessionIDs: ["session-0", "session-1"], maximumSessionsPerWeek: 3)
    }
    // Injected engineering fixture, not a production progression prescription.
    private func fixturePolicy(_ source: WorkoutProgramme) -> ProgrammePlanningPolicy {
        .init(id: "provenance-fixture", evidence: .init(minimumSessions: 1, maximumAgeSeconds: 100_000, minimumReportedEffortForProgression: nil),
            exerciseRules: [.init(id: "one", sessionID: "session-0", occurrenceID: "slot-0", trigger: .targetMet,
                adjustment: .rest(deltaSeconds: 10), bounds: .init(loadUnit: .kilograms, minimumLoad: 0, maximumLoad: 100,
                    maximumLoadChange: 5, minimumReps: 1, maximumReps: 100, maximumRepChange: 5,
                    minimumSets: 1, maximumSets: 10, maximumSetChange: 1,
                    minimumRestSeconds: 0, maximumRestSeconds: 600, maximumRestChange: 30))],
            alternatives: [], structureRules: [], structureBounds: .init(minimumSessionsPerWeek: 1,
                maximumSessionsPerWeek: 7, maximumFrequencyChange: 1, maximumMovedSessions: 1), maximumChanges: 1)
    }
    private func observation(_ source: WorkoutProgramme, history: [WorkoutHistoryEntry]) throws -> ProgrammePlanningObservation {
        try .capture(programme: source, history: history, sessionsPerWeek: nil, hasActiveSession: false,
            constraints: unknownConstraints, at: now)
    }
    private func completed(_ initial: WorkoutSession, at date: Date) throws -> WorkoutHistoryEntry {
        WorkoutHistoryEntry(session: try completedSession(initial, at: date))
    }
    private func completedSession(_ initial: WorkoutSession, at date: Date) throws -> WorkoutSession {
        var session = initial; session.resolveWarmUp(as: .skipped, at: date)
        for index in 0..<session.totalPlannedSetCount {
            let stamp = date.addingTimeInterval(Double(index) * 120)
            session.skipRest(at: stamp)
            let plan = session.exercises[session.currentExerciseIndex].plan
            _ = try session.completeCurrentSet(load: plan.targetLoad, reps: plan.isTimed ? 0 : plan.prescription.upperBound,
                rir: plan.isTimed ? nil : 3, durationSeconds: plan.isTimed ? plan.prescription.upperBound : nil, at: stamp)
        }
        XCTAssertTrue(session.confirmCompletedExecution(at: date.addingTimeInterval(Double(session.totalPlannedSetCount) * 120)))
        return session
    }
    private func plan(load: Double = 10, sets: Int = 2, rest: TimeInterval = 90.25,
                      timed: Bool = false, perSide: Bool = false) -> ExercisePlan {
        .init(exerciseID: ExerciseIDs.gobletSquat, name: "Goblet Squat", targetLoad: Load(load), targetReps: RepRange(8, 12),
            plannedSetCount: sets, restSeconds: rest, previousPerformance: [], equipmentIdentifiers: ["dumbbell"],
            targetPrescription: .init(unit: timed ? .seconds : .repetitions, lowerBound: 8, upperBound: 12, perSide: perSide))
    }
    private func programme(_ plans: [ExercisePlan], sessions: Int = 1) -> WorkoutProgramme {
        .init(id: base.id, title: base.title, summary: base.summary, durationMinutes: base.durationMinutes,
            equipmentContext: base.equipmentContext, experienceBand: base.experienceBand, goalSupport: base.goalSupport,
            schedule: base.schedule, durationWeeks: base.durationWeeks, rules: base.rules, evidenceReferenceKeys: base.evidenceReferenceKeys,
            sessions: (0..<sessions).map { .init(id: "session-\($0)", title: "Session \($0)", exercisePlans: plans) })
    }
    private func volumeContext(_ source: WorkoutProgramme) throws -> ProgrammeVolumeContext {
        let report = RecoveryCheckIn(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            day: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier, reportedAt: now,
            energy: .usual, soreness: .severe, sleepHours: nil, hasNewOrWorseningPain: false,
            feelsUnwell: false, feelsUnusuallyHungry: false, feelsThirsty: false)
        let assessment = WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [report], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
        return .init(programme: source, revision: nil, calendarEvidence: .absent, assessment: assessment,
            recovery: report, hasUnfinishedWorkout: false)
    }
    private func export(_ entries: [WorkoutHistoryEntry]) -> LocalDataExportPackage {
        .init(exportedAt: now, completedWorkouts: entries, bodyWeightReadings: [],
            selection: .init(workouts: true, mealsAndWater: false, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false),
            meals: nil, waterSnapshot: nil, outdoorActivities: nil, goalsAndPreferences: nil)
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}

private final class ProvenanceHistoryStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry]
    var failRead = false
    private(set) var writes = 0
    init(_ entries: [WorkoutHistoryEntry]) { self.entries = entries }
    var isAvailable: Bool { !failRead }
    func load() throws -> [WorkoutHistoryEntry] {
        if failRead { throw WorkoutPersistenceError.unavailable }; return entries
    }
    func save(_ entries: [WorkoutHistoryEntry]) throws { self.entries = entries; writes += 1 }
}
