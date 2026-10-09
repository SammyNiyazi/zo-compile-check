import Foundation
import XCTest
@testable import ZeroOne

final class SmartNoteCandidatesTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func savedSession(
        reps: [Int] = [10, 10, 10],
        rirs: [Int?] = [2, 2, 2],
        completedAt: Date,
        programmeID: WorkoutProgrammeID? = .zeroOneBuild,
        customWorkoutID: UUID? = nil
    ) throws -> WorkoutSession {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press",
            targetLoad: Load(40),
            targetReps: RepRange(8, 10),
            plannedSetCount: 3,
            restSeconds: 0,
            previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10)
        )
        var session = WorkoutSession(
            title: "Upper body", programmeID: programmeID,
            customWorkoutID: customWorkoutID,
            exercises: [WorkoutExercise(plan: plan)]
        )
        for index in reps.indices {
            _ = try session.completeCurrentSet(
                load: Load(40), reps: reps[index], rir: rirs[index],
                at: completedAt.addingTimeInterval(Double(index + 1 - reps.count))
            )
            session.skipRest()
        }
        if !session.isComplete {
            XCTAssertTrue(session.finishEarly(at: completedAt))
        } else {
            // Explicit synthetic final-review action. Missing RIR stays nil.
            XCTAssertTrue(session.confirmCompletedExecution(at: completedAt))
        }
        return session
    }

    private func generate(
        _ session: WorkoutSession,
        result: WorkoutHistoryRecordResult = .inserted,
        origin: SmartNoteWorkoutSaveOrigin = .liveWorkout,
        currentProgrammeID: WorkoutProgrammeID? = .zeroOneBuild,
        history: [WorkoutHistoryEntry]? = nil,
        choices: [WorkoutLoadChoice]? = [],
        records: [SmartNoteRecord] = [],
        now: Date? = nil,
        calendar: Calendar? = nil
    ) -> SmartNoteCandidate? {
        SmartNoteCandidates.progressAfterAcknowledgedSave(
            session: session, recordResult: result, origin: origin,
            currentProgrammeID: currentProgrammeID,
            savedHistory: history ?? [WorkoutHistoryEntry(session: session)],
            loadChoices: choices, records: records,
            now: now ?? session.completedAt!.addingTimeInterval(30),
            calendar: calendar ?? self.calendar,
            progressionReviews: sessionReviews(session)
        )
    }


    /// Deliberately authored review facts for these synthetic fixtures. This
    /// does not infer production movement control or fill missing effort.
    private func sessionReviews(_ session: WorkoutSession) -> [WorkoutProgressionReview] {
        let source = WorkoutHistoryEntry(session: session)
        guard let plan = session.exercises.first?.plan,
              let sourceHash = WorkoutProgressionEvidence.fingerprint(source),
              let planHash = WorkoutProgressionEvidence.planFingerprint(plan) else { return [] }
        return [.init(id: session.id, sourceSessionID: session.id, occurrenceID: plan.id,
            exerciseID: plan.exerciseID, sourceFingerprint: sourceHash, planFingerprint: planHash,
            reviewedAt: source.completedAt.addingTimeInterval(1), controlledMovement: true,
            painFree: true, availableIncrement: Load(2.5), higherValueMeansMoreResistance: true)]
    }

    @MainActor private func reviewedChoices(store: NoteChoiceStore, session: WorkoutSession,
                                          at now: Date) -> WorkoutLoadChoiceRepository {
        let repository = WorkoutLoadChoiceRepository(store: store)
        let authority = WorkoutProgressionAuthority(
            history: WorkoutHistoryRepository(store: NoteHistoryStore([WorkoutHistoryEntry(session: session)])),
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore(sessionReviews(session))))
        authority.install(currentPlans: { _ in session.exercises.map(\.plan) },
            refreshCurrentPlans: { _ in true }, increaseAllowed: { true })
        repository.setProgressionValidator { upgrade, id in
            authority.validate(upgrade, sourceSessionID: id, requireIncrease: false, at: now)
        }
        repository.setProgressionPolicy { true }
        return repository
    }

    func testNewAcknowledgedProgressionProducesStableNextMorningCandidate() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let first = try XCTUnwrap(generate(session))
        let second = try XCTUnwrap(generate(session))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.kind, .progress)
        XCTAssertEqual(first.occurrenceID, session.exercises[0].completedSets.last?.id)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.deliveryDate, date("2026-09-29T08:30:00Z"))
        XCTAssertEqual(first.expiresAt, date("2026-09-30T00:00:00Z"))
        XCTAssertTrue(first.title.contains("42"))
        XCTAssertTrue(first.title.contains("kg"))
        XCTAssertTrue(first.body.contains("3 sets at 40 kg, each with at least 10 reps"))
        XCTAssertTrue(first.reasons.contains(where: { $0.hasPrefix("Workout History:") }))
        XCTAssertEqual(first.programmeID, WorkoutProgrammeID.zeroOneBuild.rawValue)
        XCTAssertEqual(first.sessionID, session.id.uuidString)
        XCTAssertTrue(first.isFreshEvent)
    }

    func testNoCandidateForRepeatBackfillUnavailableOrCustomSave() throws {
        let completedAt = date("2026-09-28T18:00:00Z")
        let session = try savedSession(completedAt: completedAt)

        XCTAssertNil(generate(session, result: .alreadyRecorded))
        XCTAssertNil(generate(session, origin: .importedHistory))
        XCTAssertNil(generate(session, history: []))
        XCTAssertNil(SmartNoteCandidates.progressAfterAcknowledgedSave(
            session: session, recordResult: .inserted, origin: .liveWorkout,
            currentProgrammeID: .zeroOneBuild, savedHistory: nil,
            loadChoices: [], records: [], now: completedAt.addingTimeInterval(30),
            calendar: calendar
        ))
        XCTAssertNil(generate(session, choices: nil))
        XCTAssertNil(generate(session, currentProgrammeID: nil))
        XCTAssertNil(generate(session, currentProgrammeID: .zeroOneStart))
        XCTAssertNil(generate(session, now: completedAt.addingTimeInterval(11 * 60)))
        let custom = try savedSession(completedAt: completedAt, programmeID: nil, customWorkoutID: UUID())
        XCTAssertNil(generate(custom))
    }

    func testOnlyEarnedUnresolvedCurrentProgressIsEligible() throws {
        let completedAt = date("2026-09-28T18:00:00Z")
        let earned = try savedSession(completedAt: completedAt)
        let entry = WorkoutHistoryEntry(session: earned)
        let upgrade = try XCTUnwrap(WorkoutCompletionUpgrade.readyAfter(
            session: earned, savedHistory: [entry], progressionReviews: sessionReviews(earned), asOf: completedAt.addingTimeInterval(30)
        ).first)
        let choice = WorkoutLoadChoice(
            upgrade: upgrade, sourceSessionID: earned.id, selection: .repeatPrevious
        )
        XCTAssertNil(generate(earned, choices: [choice]))

        let belowGoal = try savedSession(reps: [10, 9, 10], completedAt: completedAt)
        XCTAssertNil(generate(belowGoal))
        let nearLimit = try savedSession(rirs: [2, 1, 2], completedAt: completedAt)
        XCTAssertNil(generate(nearLimit))
        let partial = try savedSession(reps: [10, 10], rirs: [2, 2], completedAt: completedAt)
        XCTAssertNil(generate(partial))

        let newer = try savedSession(completedAt: completedAt.addingTimeInterval(10))
        XCTAssertNil(generate(earned, history: [WorkoutHistoryEntry(session: newer), entry]))

        let olderSameMilestone = try savedSession(
            completedAt: completedAt.addingTimeInterval(-86_400)
        )
        XCTAssertNil(generate(earned, history: [entry, WorkoutHistoryEntry(session: olderSameMilestone)]))

        let olderAtLimit = try savedSession(
            rirs: [0, 0, 0], completedAt: completedAt.addingTimeInterval(-86_400)
        )
        XCTAssertNotNil(generate(earned, history: [entry, WorkoutHistoryEntry(session: olderAtLimit)]))
    }

    func testDeliveredEventNeverReappearsAndOptInStillGatesScheduling() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let candidate = try XCTUnwrap(generate(session))
        let record = SmartNoteRecord(
            requestID: candidate.requestID, candidateID: candidate.id,
            kind: .progress, date: candidate.deliveryDate,
            outcome: .delivered, reason: "Reported by iOS"
        )
        XCTAssertNil(generate(session, records: [record]))

        let disabled = SmartNoteRules.decisions(
            candidates: [candidate], preferences: SmartNotePreferences(), records: [],
            authorized: true, workoutActive: false,
            now: session.completedAt!.addingTimeInterval(30), calendar: calendar
        )
        XCTAssertNil(disabled.first?.deliveryDate)
    }

    func testDeliveryUsesSavedCalendarZoneAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let session = try savedSession(completedAt: date("2026-10-31T22:00:00Z"))
        let candidate = try XCTUnwrap(generate(session, calendar: newYork))
        XCTAssertEqual(candidate.deliveryDate, date("2026-11-01T13:30:00Z"))
    }

    @MainActor func testNotificationLoadChoicePersistsAndReachesNextWorkout() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let entry = WorkoutHistoryEntry(session: session)
        for selection in [WorkoutLoadChoiceSelection.tryNext, .repeatPrevious] {
            let store = NoteChoiceStore()
            let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
            let history = WorkoutHistoryRepository(store: NoteHistoryStore([entry]))
            let expected = selection == .tryNext ? Load(42.5) : Load(40)
            XCTAssertEqual(SmartNoteProgressAction.apply(selection, to: note, history: history,
                choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)).savedLoad, expected)
            let restored = reviewedChoices(store: store, session: session, at: note.deliveryDate)
            let engine = WorkoutProgressionEngine(reviews: sessionReviews(session), asOf: note.deliveryDate)
            let plan = engine.plan(session.exercises[0].plan, using: [entry])
            XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: plan,
                choices: restored.choices, history: [entry], engine: engine).targetLoad, expected)
            XCTAssertEqual(SmartNoteProgressAction.apply(selection, to: note, history: history,
                choices: restored, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)).savedLoad, expected)
            XCTAssertEqual(store.writes, 1, "Repeated delivery must not write again")
            XCTAssertEqual(history.entries, [entry], "A load choice never rewrites recorded sets")
        }
    }

    @MainActor func testNotificationRechecksHistoryAndPreservesConflictingChoice() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let historyStore = NoteHistoryStore([WorkoutHistoryEntry(session: session)])
        let history = WorkoutHistoryRepository(store: historyStore)
        let store = NoteChoiceStore()
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        historyStore.entries = [] // Changed after repository initialization.
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)), .stale)
        XCTAssertEqual(store.writes, 0)
        historyStore.entries = [WorkoutHistoryEntry(session: session)]
        XCTAssertEqual(SmartNoteProgressAction.apply(.repeatPrevious, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)).savedLoad, Load(40))
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)), .stale)
        XCTAssertEqual(store.writes, 1)
        historyStore.available = false
        XCTAssertEqual(SmartNoteProgressAction.apply(.repeatPrevious, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)), .unavailable)
    }

    func testProgressActionRejectsNewerPerformanceExpiredPlanAndChangedEvidence() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        var note = try XCTUnwrap(generate(session))
        let original = WorkoutHistoryEntry(session: session)
        let newer = try savedSession(completedAt: date("2026-09-29T07:00:00Z"))
        XCTAssertNil(SmartNoteProgressAction.upgrade(for: note,
            history: [WorkoutHistoryEntry(session: newer), original], programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)))
        XCTAssertNil(SmartNoteProgressAction.upgrade(for: note, history: [original],
            programmeID: .arms, now: note.deliveryDate, progressionReviews: sessionReviews(session)))
        XCTAssertNil(SmartNoteProgressAction.upgrade(for: note, history: [original],
            programmeID: .zeroOneBuild, now: note.expiresAt, progressionReviews: sessionReviews(session)))
        note.progressEvidence = .init(plan: session.exercises[0].plan,
            opportunity: .init(previousLoad: Load(40), suggestedLoad: Load(50)))
        XCTAssertNil(SmartNoteProgressAction.upgrade(for: note, history: [original],
            programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)))
    }

    @MainActor func testNotificationNeverConfirmsDiscardedChoiceWrite() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let store = NoteChoiceStore()
        store.discardWrites = true
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        let history = WorkoutHistoryRepository(store: NoteHistoryStore([WorkoutHistoryEntry(session: session)]))
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)), .unavailable)
        XCTAssertTrue(choices.choices.isEmpty)
        store.discardWrites = false
        store.throwAfterWrite = true
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)).savedLoad, Load(42.5))
        XCTAssertEqual(store.writes, 2)
    }

    func testProgressEvidenceRoundTripAndLegacyNoteCompatibility() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let encoded = try JSONEncoder().encode(note)
        XCTAssertEqual(try JSONDecoder().decode(SmartNoteCandidate.self, from: encoded), note)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "progressEvidence")
        let restored = try JSONDecoder().decode(SmartNoteCandidate.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.progressEvidence)
        XCTAssertNil(SmartNoteProgressAction.upgrade(for: restored,
            history: [WorkoutHistoryEntry(session: session)], programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)))
    }

    @MainActor func testActiveWorkoutRefusesNotificationChoiceWithoutWriting() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let store = NoteChoiceStore()
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note,
            history: WorkoutHistoryRepository(store: NoteHistoryStore([WorkoutHistoryEntry(session: session)])),
            choices: reviewedChoices(store: store, session: session, at: note.deliveryDate), programmeID: .zeroOneBuild,
            now: note.deliveryDate, workoutActive: true), .workoutActive)
        XCTAssertEqual(store.writes, 0)
    }

    @MainActor func testPriorSessionChoiceCanBeReplacedByNewEarnedChoice() throws {
        let older = try savedSession(completedAt: date("2026-09-27T18:00:00Z"))
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let priorUpgrade = try XCTUnwrap(WorkoutCompletionUpgrade.readyAfter(
            session: older, savedHistory: [WorkoutHistoryEntry(session: older)], progressionReviews: sessionReviews(older), asOf: older.completedAt!.addingTimeInterval(30)).first)
        let store = NoteChoiceStore()
        store.values = [.init(upgrade: priorUpgrade, sourceSessionID: older.id, selection: .repeatPrevious)]
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note,
            history: WorkoutHistoryRepository(store: NoteHistoryStore([
                WorkoutHistoryEntry(session: session), WorkoutHistoryEntry(session: older)
            ])), choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)).savedLoad, Load(42.5))
        XCTAssertEqual(choices.choices.first?.sourceSessionID, session.id)
        XCTAssertEqual(store.writes, 1)
    }

    @MainActor func testNotificationUndoSurvivesReloadAndIsIdempotent() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let entry = WorkoutHistoryEntry(session: session)
        let history = WorkoutHistoryRepository(store: NoteHistoryStore([entry]))
        let store = NoteChoiceStore()
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        let result = SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session))
        guard case let .saved(_, undo) = result else { return XCTFail("Expected a saved choice") }
        let receipt = try XCTUnwrap(undo)
        var snapshot = SmartNoteSnapshot()
        snapshot.loadChoiceUndo = receipt
        let restored = try JSONDecoder().decode(SmartNoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restoredReceipt = try XCTUnwrap(restored.loadChoiceUndo)
        let reloadedChoices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        XCTAssertTrue(SmartNoteProgressAction.undo(restoredReceipt, history: history,
            choices: reloadedChoices, workoutActive: false))
        XCTAssertTrue(reloadedChoices.choices.isEmpty)
        XCTAssertTrue(SmartNoteProgressAction.undo(restoredReceipt, history: history,
            choices: reloadedChoices, workoutActive: false))
        XCTAssertEqual(store.writes, 2, "Exactly one selection and one undo")
        XCTAssertEqual(history.entries, [entry])
    }

    @MainActor func testNotificationUndoCannotOverrideLaterIdenticalChoice() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let entry = WorkoutHistoryEntry(session: session)
        let history = WorkoutHistoryRepository(store: NoteHistoryStore([entry]))
        let store = NoteChoiceStore()
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        let result = SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session))
        guard case let .saved(_, undo) = result else { return XCTFail("Expected a saved choice") }
        let receipt = try XCTUnwrap(undo)
        let resolved = try XCTUnwrap(SmartNoteProgressAction.upgrade(for: note,
            history: [entry], programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session)))
        XCTAssertTrue(choices.choose(.tryNext, for: resolved.upgrade, sourceSessionID: session.id))
        let newerChoice = try XCTUnwrap(choices.choices.first)
        XCTAssertNotEqual(newerChoice.mutationID, receipt.expected.mutationID)
        XCTAssertFalse(SmartNoteProgressAction.undo(receipt, history: history,
            choices: choices, workoutActive: false))
        XCTAssertEqual(choices.choices, [newerChoice])
        XCTAssertEqual(store.writes, 2)
    }

    @MainActor func testNotificationUndoGuardsWorkoutNewerHistoryAndFailedStorage() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let entry = WorkoutHistoryEntry(session: session)
        let historyStore = NoteHistoryStore([entry])
        let history = WorkoutHistoryRepository(store: historyStore)
        let store = NoteChoiceStore()
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        let result = SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session))
        guard case let .saved(_, undo) = result else { return XCTFail("Expected a saved choice") }
        let receipt = try XCTUnwrap(undo)
        XCTAssertFalse(SmartNoteProgressAction.undo(receipt, history: history,
            choices: choices, workoutActive: true))
        let newer = try savedSession(completedAt: date("2026-09-29T10:00:00Z"))
        historyStore.entries = [WorkoutHistoryEntry(session: newer), entry]
        XCTAssertFalse(SmartNoteProgressAction.undo(receipt, history: history,
            choices: choices, workoutActive: false))
        historyStore.entries = [entry]
        store.discardWrites = true
        XCTAssertFalse(SmartNoteProgressAction.undo(receipt, history: history,
            choices: choices, workoutActive: false))
        XCTAssertEqual(choices.choices, [receipt.expected])
        store.discardWrites = false
        XCTAssertTrue(SmartNoteProgressAction.undo(receipt, history: history,
            choices: choices, workoutActive: false))
    }

    @MainActor func testUndoRestoresExactPreviousChoiceIncludingLegacyIdentity() throws {
        let older = try savedSession(completedAt: date("2026-09-27T18:00:00Z"))
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let note = try XCTUnwrap(generate(session))
        let priorUpgrade = try XCTUnwrap(WorkoutCompletionUpgrade.readyAfter(
            session: older, savedHistory: [WorkoutHistoryEntry(session: older)], progressionReviews: sessionReviews(older), asOf: older.completedAt!.addingTimeInterval(30)).first)
        let prior = WorkoutLoadChoice(upgrade: priorUpgrade, sourceSessionID: older.id, selection: .repeatPrevious)
        var legacyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prior)) as? [String: Any])
        legacyPayload.removeValue(forKey: "mutationID")
        let legacy = try JSONDecoder().decode(WorkoutLoadChoice.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        XCTAssertNil(legacy.mutationID)
        let store = NoteChoiceStore()
        store.values = [legacy]
        let choices = reviewedChoices(store: store, session: session, at: note.deliveryDate)
        let history = WorkoutHistoryRepository(store: NoteHistoryStore([
            WorkoutHistoryEntry(session: session), WorkoutHistoryEntry(session: older)
        ]))
        let result = SmartNoteProgressAction.apply(.tryNext, to: note, history: history,
            choices: choices, programmeID: .zeroOneBuild, now: note.deliveryDate, progressionReviews: sessionReviews(session))
        guard case let .saved(_, undo) = result else { return XCTFail("Expected a saved choice") }
        XCTAssertTrue(SmartNoteProgressAction.undo(try XCTUnwrap(undo), history: history,
            choices: choices, workoutActive: false))
        XCTAssertEqual(choices.choices, [legacy])
    }

    func testUndoJournalRetainsReceiptAndClearUntilAcknowledged() throws {
        let session = try savedSession(completedAt: date("2026-09-28T18:00:00Z"))
        let upgrade = try XCTUnwrap(WorkoutCompletionUpgrade.readyAfter(
            session: session, savedHistory: [WorkoutHistoryEntry(session: session)], progressionReviews: sessionReviews(session), asOf: session.completedAt!.addingTimeInterval(30)).first)
        let receipt = WorkoutLoadChoiceUndo(expected: .init(upgrade: upgrade,
            sourceSessionID: session.id, selection: .tryNext), previous: nil, createdAt: session.completedAt!)
        var journal = SmartNoteUndoJournal()
        let oldSnapshot = SmartNoteSnapshot()
        journal.stage(receipt)
        _ = journal.applying(to: oldSnapshot) // Simulate a failed second-store write: no acknowledgment.
        XCTAssertTrue(journal.hasPendingChange)
        XCTAssertEqual(journal.applying(to: oldSnapshot).loadChoiceUndo, receipt)
        let durable = try JSONDecoder().decode(SmartNoteSnapshot.self,
            from: JSONEncoder().encode(journal.applying(to: oldSnapshot)))
        journal.confirmed()
        XCTAssertFalse(journal.hasPendingChange)
        XCTAssertEqual(journal.applying(to: durable).loadChoiceUndo, receipt)
        journal.stage(nil)
        XCTAssertNil(journal.applying(to: durable).loadChoiceUndo)
        XCTAssertTrue(journal.hasPendingChange, "A failed clear must not revive the old receipt on reconciliation")
        XCTAssertNil(journal.applying(to: durable).loadChoiceUndo)
        journal.confirmed()
        XCTAssertFalse(journal.hasPendingChange)
    }
}

private final class NoteHistoryStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry]
    var available = true
    var isAvailable: Bool { available }
    init(_ entries: [WorkoutHistoryEntry]) { self.entries = entries }
    func load() throws -> [WorkoutHistoryEntry] {
        guard available else { throw WorkoutPersistenceError.unavailable }
        return entries
    }
    func save(_ entries: [WorkoutHistoryEntry]) throws { self.entries = entries }
}

private final class NoteChoiceStore: WorkoutLoadChoicePersisting {
    var values: [WorkoutLoadChoice] = []
    var writes = 0
    var discardWrites = false
    var throwAfterWrite = false
    func load() throws -> [WorkoutLoadChoice] { values }
    func save(_ choices: [WorkoutLoadChoice]) throws {
        writes += 1
        if !discardWrites { values = choices }
        if throwAfterWrite { throw WorkoutPersistenceError.verificationFailed }
    }
}
