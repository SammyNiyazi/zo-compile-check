import XCTest
@testable import ZeroOne

/// Explicit synthetic evidence, not enrichment of unknown legacy fixtures.
struct WorkoutProgressionTestFixture {
    static let clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let plan: ExercisePlan
    let session: WorkoutSession
    let entry: WorkoutHistoryEntry
    let review: WorkoutProgressionReview
    let now: Date
    var engine: WorkoutProgressionEngine { .init(reviews: [review], asOf: now) }
    var performance: RecordedExercisePerformance {
        .init(sessionID: entry.id, sessionTitle: entry.title, completedAt: entry.completedAt,
            occurrences: entry.exercises ?? [], hasNewerUnknownDetails: false,
            executionCompleteness: entry.executionCompleteness,
            executionCompletionConfirmedAt: entry.executionCompletionConfirmedAt, sourceEntry: entry)
    }
    var upgrade: WorkoutCompletionUpgrade? {
        WorkoutCompletionUpgrade.readyAfter(session: session, savedHistory: [entry],
            progressionReviews: [review], asOf: now).first
    }

    init(rirs: [Int?] = [2, 3], increment: Double = 2.5, controlled: Bool? = true,
         painFree: Bool? = true, higherResistance: Bool? = true, confirmed: Bool = true,
         at now: Date = clock, plan customPlan: ExercisePlan? = nil,
         programmeID: WorkoutProgrammeID? = .zeroOneBuild, sessionID: UUID = UUID(), customWorkoutID: UUID? = nil) throws {
        self.now = now
        let plan = customPlan ?? ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench press",
            targetLoad: Load(40), targetReps: RepRange(8, 10), plannedSetCount: 2,
            restSeconds: 0, previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10))
        self.plan = plan
        var session = WorkoutSession(id: sessionID, title: "Qualified synthetic execution", programmeID: programmeID,
            customWorkoutID: customWorkoutID,
            exercises: [WorkoutExercise(plan: plan)])
        for index in 0 ..< plan.plannedSetCount {
            let date = now.addingTimeInterval(-Double(plan.plannedSetCount - index) * (plan.restSeconds + 1) - 100)
            // completeCurrentSet closes an elapsed countdown at this supplied
            // timestamp; snapshot recovery is a separate boundary.
            _ = try session.completeCurrentSet(load: plan.targetLoad, reps: plan.targetReps.upperBound,
                rir: index < rirs.count ? rirs[index] : nil,
                at: date)
        }
        if confirmed { XCTAssertTrue(session.confirmCompletedExecution(at: now.addingTimeInterval(-10))) }
        self.session = session
        entry = WorkoutHistoryEntry(session: session)
        review = .init(id: UUID(), sourceSessionID: session.id, occurrenceID: plan.id, exerciseID: plan.exerciseID,
            sourceFingerprint: try XCTUnwrap(WorkoutProgressionEvidence.fingerprint(entry)),
            planFingerprint: try XCTUnwrap(WorkoutProgressionEvidence.planFingerprint(plan)),
            reviewedAt: now.addingTimeInterval(-5), controlledMovement: controlled, painFree: painFree,
            availableIncrement: Load(increment, unit: plan.targetLoad.unit),
            higherValueMeansMoreResistance: higherResistance)
    }
}

@MainActor final class WorkoutProgressionEvidenceTests: XCTestCase {
    func testOnlyExplicitComparableExecutionAndReviewedIncrementEarnAnIncrease() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        XCTAssertEqual(upgrade.opportunity.previousLoad, Load(40))
        XCTAssertEqual(upgrade.opportunity.suggestedLoad, Load(42.5))
        XCTAssertEqual(upgrade.opportunity.context?.sourceSessionID, fixture.entry.id)
        XCTAssertEqual(upgrade.opportunity.context?.reviewID, fixture.review.id)
        XCTAssertEqual(upgrade.completedSets, fixture.entry.exercises?.first?.completedSets)
        XCTAssertEqual(fixture.entry.exercises?.first?.completedSets.map(\.rir), [2, 3])
    }

    func testUnknownOrNearLimitEffortCannotEarnAnIncrease() throws {
        let efforts: [[Int?]] = [[nil, 3], [2, nil], [2, 1]]
        for effort in efforts {
            let fixture = try WorkoutProgressionTestFixture(rirs: effort)
            XCTAssertNil(fixture.upgrade)
            XCTAssertEqual(fixture.engine.plan(fixture.plan, using: [fixture.entry]).targetLoad, Load(40))
        }
    }

    func testUnknownMovementPainOrResistanceDirectionCannotEarnAnIncrease() throws {
        XCTAssertNil(try WorkoutProgressionTestFixture(controlled: nil).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(controlled: false).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(painFree: nil).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(painFree: false).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(higherResistance: nil).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(higherResistance: false).upgrade)
    }

    func testWholeExecutionConfirmationIsRequiredEvenWithAReview() throws {
        let fixture = try WorkoutProgressionTestFixture(confirmed: false)
        XCTAssertEqual(fixture.entry.executionCompleteness, .unknown)
        XCTAssertNil(fixture.upgrade)
    }

    func testRealIncrementMustFitProductBoundsWithoutRoundingOrGuessing() throws {
        XCTAssertNil(try WorkoutProgressionTestFixture(increment: 5).upgrade)
        XCTAssertEqual(try WorkoutProgressionTestFixture(increment: 1).upgrade?.opportunity.suggestedLoad, Load(41))
        let fixture = try WorkoutProgressionTestFixture()
        XCTAssertNil(WorkoutProgressionEngine(asOf: fixture.now).earnedOpportunity(for: fixture.plan, performance: fixture.performance))
    }

    func testExpiredFutureAndDuplicateEvidenceCannotEarnMore() throws {
        let fixture = try WorkoutProgressionTestFixture()
        XCTAssertNil(WorkoutProgressionEngine(reviews: [fixture.review], asOf: fixture.now.addingTimeInterval(43 * 86_400))
            .earnedOpportunity(for: fixture.plan, performance: fixture.performance))
        XCTAssertNil(WorkoutProgressionEngine(reviews: [fixture.review], asOf: fixture.entry.completedAt.addingTimeInterval(-1))
            .earnedOpportunity(for: fixture.plan, performance: fixture.performance))
        XCTAssertNil(WorkoutProgressionEngine(reviews: [fixture.review, fixture.review], asOf: fixture.now)
            .earnedOpportunity(for: fixture.plan, performance: fixture.performance))
        XCTAssertNil(fixture.engine.latestPerformance(for: fixture.plan, history: [fixture.entry, fixture.entry]))
    }

    func testLatestSkippedWorkBlocksAnOlderQualifiedSuccess() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let other = ExercisePlan(exerciseID: ExerciseIDs.dumbbellCurl, name: "Curl", targetLoad: Load(10),
            targetReps: RepRange(8, 10), plannedSetCount: 1, restSeconds: 0, previousPerformance: [])
        var skipped = WorkoutSession(title: "Skipped", exercises: [WorkoutExercise(plan: other), WorkoutExercise(plan: fixture.plan)])
        _ = try skipped.completeCurrentSet(load: Load(10), reps: 8, at: fixture.now.addingTimeInterval(-1))
        XCTAssertTrue(skipped.finishEarly(at: fixture.now))
        let history = [WorkoutHistoryEntry(session: skipped), fixture.entry]
        let latest = try XCTUnwrap(fixture.engine.latestPerformance(for: fixture.plan, history: history))
        XCTAssertEqual(latest.sessionID, skipped.id)
        XCTAssertNil(fixture.engine.earnedOpportunity(for: fixture.plan, performance: latest))
    }

    func testChangedPrescriptionAndManualTargetCannotReuseAReview() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let changed = ExercisePlan(id: fixture.plan.id, exerciseID: fixture.plan.exerciseID, name: fixture.plan.name,
            targetLoad: Load(40), targetReps: RepRange(6, 8), plannedSetCount: 2, restSeconds: 0,
            previousPerformance: [], targetPrescription: .init(unit: .repetitions, lowerBound: 6, upperBound: 8))
        XCTAssertNil(fixture.engine.earnedOpportunity(for: changed, performance: fixture.performance))
        XCTAssertNil(fixture.engine.earnedOpportunity(for: fixture.plan.replacingTargetLoad(Load(60)), performance: fixture.performance))
    }

    func testSavedChoiceRequiresExactCurrentPolicyContextAfterRelaunchAndExpiry() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let choice = WorkoutLoadChoice(upgrade: upgrade, sourceSessionID: fixture.entry.id, selection: .tryNext)
        let restored = try JSONDecoder().decode(WorkoutLoadChoice.self, from: JSONEncoder().encode(choice))
        let proposed = fixture.engine.plan(fixture.plan, using: [fixture.entry])
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: [restored], history: [fixture.entry],
            engine: fixture.engine).targetLoad, Load(42.5))
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: [], history: [fixture.entry],
            engine: fixture.engine).targetLoad, Load(40))
        let expired = WorkoutProgressionEngine(reviews: [fixture.review], asOf: fixture.now.addingTimeInterval(43 * 86_400))
        XCTAssertEqual(expired.plan(fixture.plan, using: [fixture.entry]).targetLoad, Load(40))
    }

    func testUnclosedAndPostCompletionTimerEvidenceCannotEarnAnIncreaseEvenWithFreshReview() throws {
        let fixture = try WorkoutProgressionTestFixture()
        for closed in [false, true] {
            var exercises = fixture.session.exercises
            let first = exercises[0].completedSets[0]
            let deadline = first.completedAt.addingTimeInterval(120)
            var observation = WorkoutRestTimerObservation(afterSetID: first.id, at: first.completedAt, deadline: deadline)
            if closed { observation.record(.skipped, at: fixture.entry.completedAt.addingTimeInterval(5), deadline: deadline) }
            exercises[0].completedSets[0].restTimerObservation = observation
            let session = WorkoutSession(id: fixture.session.id, title: fixture.session.title, programmeID: fixture.session.programmeID,
                exercises: exercises, completedAt: fixture.session.completedAt,
                executionCompletionConfirmedAt: fixture.session.executionCompletionConfirmedAt)
            let entry = WorkoutHistoryEntry(session: session)
            let review = WorkoutProgressionReview(id: UUID(), sourceSessionID: entry.id, occurrenceID: fixture.plan.id,
                exerciseID: fixture.plan.exerciseID, sourceFingerprint: try XCTUnwrap(WorkoutProgressionEvidence.fingerprint(entry)),
                planFingerprint: fixture.review.planFingerprint, reviewedAt: fixture.review.reviewedAt,
                controlledMovement: true, painFree: true, availableIncrement: Load(2.5), higherValueMeansMoreResistance: true)
            let engine = WorkoutProgressionEngine(reviews: [review], asOf: fixture.now)
            let performance = try XCTUnwrap(engine.latestPerformance(for: fixture.plan, history: [entry]))
            XCTAssertNil(engine.earnedOpportunity(for: fixture.plan, performance: performance))
        }
    }

    func testCorrectedTimerMetadataInvalidatesOldReviewWithoutInventingPhysicalRest() throws {
        let fixture = try WorkoutProgressionTestFixture()
        var exercises = fixture.session.exercises
        let first = exercises[0].completedSets[0]
        let deadline = first.completedAt.addingTimeInterval(120)
        var observation = WorkoutRestTimerObservation(afterSetID: first.id, at: first.completedAt, deadline: deadline)
        observation.record(.skipped, at: first.completedAt.addingTimeInterval(0.5), deadline: deadline)
        exercises[0].completedSets[0].restTimerObservation = observation
        let session = WorkoutSession(id: fixture.session.id, title: fixture.session.title, programmeID: fixture.session.programmeID,
            exercises: exercises, completedAt: fixture.session.completedAt,
            executionCompletionConfirmedAt: fixture.session.executionCompletionConfirmedAt)
        let entry = WorkoutHistoryEntry(session: session)
        let performance = try XCTUnwrap(fixture.engine.latestPerformance(for: fixture.plan, history: [entry]))
        XCTAssertNil(fixture.engine.earnedOpportunity(for: fixture.plan, performance: performance))
        let review = WorkoutProgressionReview(id: UUID(), sourceSessionID: entry.id, occurrenceID: fixture.plan.id,
            exerciseID: fixture.plan.exerciseID, sourceFingerprint: try XCTUnwrap(WorkoutProgressionEvidence.fingerprint(entry)),
            planFingerprint: fixture.review.planFingerprint, reviewedAt: fixture.review.reviewedAt,
            controlledMovement: true, painFree: true, availableIncrement: Load(2.5), higherValueMeansMoreResistance: true)
        // A new human review still qualifies the existing bounded repetition/RIR
        // policy. Countdown metadata does not impose a physiological rest target.
        XCTAssertNotNil(WorkoutProgressionEngine(reviews: [review], asOf: fixture.now)
            .earnedOpportunity(for: fixture.plan, performance: performance))
    }

    func testLegacyContextFreeChoiceCannotAuthorizeCurrentProposal() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let legacy = WorkoutCompletionUpgrade(exerciseID: fixture.plan.exerciseID, exerciseName: fixture.plan.name,
            opportunity: .init(previousLoad: Load(40), suggestedLoad: Load(42.5)),
            completedSets: fixture.entry.exercises?.first?.completedSets ?? [], targetRepUpperBound: 10)
        let choice = WorkoutLoadChoice(upgrade: legacy, sourceSessionID: fixture.entry.id, selection: .tryNext)
        let proposed = fixture.engine.plan(fixture.plan, using: [fixture.entry])
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: [choice], history: [fixture.entry],
            engine: fixture.engine).targetLoad, Load(40))
    }

    func testProgressProjectionRetainsWholeCompletionAndExactSource() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let display = WorkoutHistoryDisplayItem(entry: fixture.entry)
        let result = ProgressLoadReview.available(for: fixture.session, entries: [display],
            progressionReviews: [fixture.review], asOf: fixture.now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.upgrade, fixture.upgrade)
        XCTAssertTrue(ProgressLoadReview.available(for: fixture.session, entries: [display], asOf: fixture.now).isEmpty)
    }

    func testReviewPersistenceRejectsStaleFormsAndPreservesRecordedSets() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let historyStore = ProgressionHistoryTestStore([fixture.entry])
        let history = WorkoutHistoryRepository(store: historyStore)
        let store = ProgressionReviewTestStore()
        let repository = WorkoutProgressionReviewRepository(store: store)
        let baseline = repository.snapshot
        try repository.save(fixture.review, for: fixture.plan, history: history, replacing: baseline, at: fixture.now)
        XCTAssertEqual(repository.snapshot.reviews, [fixture.review])
        XCTAssertEqual(historyStore.entries, [fixture.entry])
        XCTAssertThrowsError(try repository.save(fixture.review, for: fixture.plan, history: history,
            replacing: baseline, at: fixture.now))
        let restored = WorkoutProgressionReviewRepository(store: store)
        XCTAssertEqual(restored.snapshot, repository.snapshot)
        try restored.deleteAll(replacing: restored.snapshot)
        XCTAssertTrue(restored.snapshot.reviews.isEmpty)
        XCTAssertEqual(historyStore.entries, [fixture.entry])
    }

    func testFailedReviewWriteDoesNotPublishAnAnswer() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let store = ProgressionReviewTestStore()
        let repository = WorkoutProgressionReviewRepository(store: store)
        store.rejectSave = true
        XCTAssertThrowsError(try repository.save(fixture.review, for: fixture.plan,
            history: WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry])),
            replacing: repository.snapshot, at: fixture.now))
        XCTAssertTrue(repository.snapshot.reviews.isEmpty)
    }

    func testFutureOrCorruptReviewStoreIsPreserved() throws {
        let name = "01.progression-review." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "reviews"
        for data in [Data("{broken".utf8), try JSONEncoder().encode(WorkoutProgressionReviewSnapshot(version: 2))] {
            defaults.set(data, forKey: key)
            let store = UserDefaultsWorkoutProgressionReviewStore(defaults: defaults, key: key)
            XCTAssertFalse(WorkoutProgressionReviewRepository(store: store).isAvailable)
            XCTAssertThrowsError(try store.save(.init()))
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
    }

    func testAuthorityRejectsNewWorkAndChangedCurrentManualTarget() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let historyStore = ProgressionHistoryTestStore([fixture.entry])
        let authority = WorkoutProgressionAuthority(history: WorkoutHistoryRepository(store: historyStore),
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([fixture.review])))
        var current = fixture.plan
        authority.install(currentPlans: { _ in [current] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { true })
        let opportunity = try XCTUnwrap(fixture.upgrade?.opportunity)
        XCTAssertTrue(authority.validate(plan: fixture.plan, opportunity: opportunity, at: fixture.now))
        current = fixture.plan.replacingTargetLoad(Load(60))
        XCTAssertFalse(authority.validate(plan: fixture.plan, opportunity: opportunity, at: fixture.now))
        current = fixture.plan
        let newer = try WorkoutProgressionTestFixture(rirs: [1, 1], at: fixture.now.addingTimeInterval(1_000), plan: current)
        historyStore.entries.insert(newer.entry, at: 0)
        XCTAssertFalse(authority.validate(plan: fixture.plan, opportunity: opportunity, at: newer.now))
    }

    func testAuthorityRejectsChangedReviewAndARecoveryHoldAtAcceptance() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let store = ProgressionReviewTestStore([fixture.review])
        let authority = WorkoutProgressionAuthority(history: WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry])),
            reviews: WorkoutProgressionReviewRepository(store: store))
        var allowed = true
        authority.install(currentPlans: { _ in [fixture.plan] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { allowed })
        let opportunity = try XCTUnwrap(fixture.upgrade?.opportunity)
        XCTAssertTrue(authority.validate(plan: fixture.plan, opportunity: opportunity, at: fixture.now))
        allowed = false
        XCTAssertFalse(authority.validate(plan: fixture.plan, opportunity: opportunity, at: fixture.now))
        XCTAssertTrue(authority.validate(plan: fixture.plan, opportunity: opportunity, requireIncrease: false, at: fixture.now))
        allowed = true
        store.snapshot = .init()
        XCTAssertFalse(authority.validate(plan: fixture.plan, opportunity: opportunity, at: fixture.now))
    }

    func testContextFreeActionsFailClosedAndRenderingPreservesManualDraft() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let model = WorkoutViewModel(session: WorkoutSession(title: "Next", exercises: [WorkoutExercise(plan: fixture.plan)]))
        let opportunity = try XCTUnwrap(fixture.upgrade?.opportunity)
        model.selectLoad(Load(42.5))
        model.prepareProgressionOffer(opportunity)
        XCTAssertEqual(model.enteredLoadValue, 42.5)
        model.selectProgressionOffer(.repeatPrevious, opportunity: opportunity)
        XCTAssertEqual(model.enteredLoadValue, 42.5)
        XCTAssertTrue(model.progressionOfferSelections.isEmpty)
        let repository = WorkoutLoadChoiceRepository(store: ProgressionChoiceTestStore())
        XCTAssertFalse(repository.choose(.tryNext, for: try XCTUnwrap(fixture.upgrade), sourceSessionID: fixture.entry.id))
        XCTAssertTrue(repository.choices.isEmpty)
    }

    func testFreshValidatedEditorChoicePersistsAndAChangedGateLeavesDraftUntouched() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let authority = WorkoutProgressionAuthority(history: WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry])),
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([fixture.review])))
        var allowed = true
        authority.install(currentPlans: { _ in [fixture.plan] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { allowed })
        let model = WorkoutViewModel(session: WorkoutSession(title: "Next", exercises: [WorkoutExercise(plan: fixture.plan)]),
            progressionValidator: { plan, opportunity in authority.validate(plan: plan, opportunity: opportunity, at: fixture.now) })
        let opportunity = try XCTUnwrap(fixture.upgrade?.opportunity)
        model.selectProgressionOffer(.tryNext, opportunity: opportunity)
        XCTAssertEqual(model.enteredLoadValue, 42.5)
        allowed = false
        model.selectProgressionOffer(.repeatPrevious, opportunity: opportunity)
        XCTAssertEqual(model.enteredLoadValue, 42.5)
        XCTAssertEqual(model.progressionOfferSelections[fixture.plan.id], .tryNext)
    }

    func testConflictingDuplicateChoicesRepeatInsteadOfAcceptingAnUnchosenProposal() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let first = WorkoutLoadChoice(upgrade: upgrade, sourceSessionID: fixture.entry.id, selection: .tryNext)
        let second = WorkoutLoadChoice(upgrade: upgrade, sourceSessionID: fixture.entry.id, selection: .repeatPrevious)
        let proposed = fixture.engine.plan(fixture.plan, using: [fixture.entry])
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: [first, second],
            history: [fixture.entry], engine: fixture.engine).targetLoad, Load(40))
        let store = ProgressionChoiceTestStore()
        store.choices = [first, second]
        XCTAssertFalse(WorkoutLoadChoiceRepository(store: store).isAvailable)
        XCTAssertEqual(store.choices, [first, second])
    }

    func testWrongTypeChoicePayloadCannotBeOverwrittenAsAnEmptyCollection() throws {
        let name = "01.progression-choice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unreadable evidence", forKey: "choices")
        let store = UserDefaultsWorkoutLoadChoiceStore(defaults: defaults, key: "choices")
        XCTAssertFalse(WorkoutLoadChoiceRepository(store: store).isAvailable)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(defaults.string(forKey: "choices"), "unreadable evidence")
    }

    func testAnIdempotentNotificationStillRejectsAChangedCurrentTarget() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let history = WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry]))
        let authority = WorkoutProgressionAuthority(history: history,
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([fixture.review])))
        var current = fixture.plan
        authority.install(currentPlans: { _ in [current] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { true })
        let choices = WorkoutLoadChoiceRepository(store: ProgressionChoiceTestStore())
        choices.setProgressionPolicy { true }
        choices.setProgressionValidator { value, id in authority.validate(value, sourceSessionID: id, at: fixture.now) }
        var note = SmartNoteCandidate(id: "synthetic-progress", occurrenceID: upgrade.completedSets.last?.id ?? UUID(),
            revision: 1, kind: .progress, title: "Review", body: "Known work", directTitle: nil, directBody: nil,
            reasons: [], unknowns: [], deliveryDate: fixture.now, expiresAt: fixture.now.addingTimeInterval(60),
            isRestDay: false, isCurrent: true, isFreshEvent: true,
            programmeID: WorkoutProgrammeID.zeroOneBuild.rawValue, sessionID: fixture.entry.id.uuidString)
        note.progressEvidence = .init(plan: fixture.plan, opportunity: upgrade.opportunity)
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history, choices: choices,
            programmeID: .zeroOneBuild, now: fixture.now, progressionReviews: [fixture.review]).savedLoad, Load(42.5))
        let before = choices.choices
        current = fixture.plan.replacingTargetLoad(Load(60))
        XCTAssertEqual(SmartNoteProgressAction.apply(.tryNext, to: note, history: history, choices: choices,
            programmeID: .zeroOneBuild, now: fixture.now, progressionReviews: [fixture.review]), .stale)
        XCTAssertEqual(choices.choices, before)
    }

    func testCustomPlannerConsumesOnlyAnExactReviewedChoiceAndPreservesManualTargets() throws {
        var workout = CustomWorkout(name: "Synthetic custom", items: [CustomWorkoutItem(videoID: "",
            sets: 2, reps: 8, restSeconds: 0, targetLoad: 40, repUpperBound: 10,
            authoredExerciseID: ExerciseIDs.barbellBenchPress)])
        let plan = try XCTUnwrap(workout.makeSession()?.exercises.first?.plan)
        let fixture = try WorkoutProgressionTestFixture(plan: plan, programmeID: nil, customWorkoutID: workout.id)
        let choice = WorkoutLoadChoice(upgrade: try XCTUnwrap(fixture.upgrade), sourceSessionID: fixture.entry.id, selection: .tryNext)
        let next = try XCTUnwrap(workout.makeSession(previousHistory: [fixture.entry], asOf: fixture.now,
            loadChoices: [choice], progressionReviews: [fixture.review]))
        XCTAssertEqual(next.exercises.first?.plan.targetLoad, Load(42.5))
        let undecided = try XCTUnwrap(workout.makeSession(previousHistory: [fixture.entry], asOf: fixture.now,
            progressionReviews: [fixture.review]))
        XCTAssertEqual(undecided.exercises.first?.plan.targetLoad, Load(40))
        workout.items[0].targetLoad = 60
        let manual = try XCTUnwrap(workout.makeSession(previousHistory: [fixture.entry], asOf: fixture.now,
            loadChoices: [choice], progressionReviews: [fixture.review]))
        XCTAssertEqual(manual.exercises.first?.plan.targetLoad, Load(60))
    }
}

final class ProgressionHistoryTestStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry]
    init(_ entries: [WorkoutHistoryEntry]) { self.entries = entries }
    func load() throws -> [WorkoutHistoryEntry] { entries }
    func save(_ entries: [WorkoutHistoryEntry]) throws { self.entries = entries }
}

final class ProgressionReviewTestStore: WorkoutProgressionReviewPersisting {
    var snapshot: WorkoutProgressionReviewSnapshot
    var rejectSave = false
    init(_ reviews: [WorkoutProgressionReview] = []) { snapshot = .init(reviews: reviews) }
    func load() throws -> WorkoutProgressionReviewSnapshot { snapshot }
    func save(_ snapshot: WorkoutProgressionReviewSnapshot) throws {
        if rejectSave { throw WorkoutProgressionReviewError.unavailable }
        self.snapshot = snapshot
    }
}

final class ProgressionChoiceTestStore: WorkoutLoadChoicePersisting {
    var choices: [WorkoutLoadChoice] = []
    var rejectSave = false
    func load() throws -> [WorkoutLoadChoice] { choices }
    func save(_ choices: [WorkoutLoadChoice]) throws {
        if rejectSave { throw WorkoutPersistenceError.unavailable }
        self.choices = choices
    }
}
