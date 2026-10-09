import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutDemandAdaptationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var today: Date { calendar.startOfDay(for: now) }
    private let adapter = WorkoutDemandAdapter()

    func testFewerSetsPreservesIdentityTargetsSubstitutionAndWarmUp() throws {
        let original = session(warmUp: WorkoutWarmUp(estimatedMinutes: 5, steps: ["Prepare"]))
        let proposal = try adapter.proposal(for: original, change: .fewerSets,
            assessment: assessment(), at: now, calendar: calendar)
        XCTAssertEqual(proposal.originalSession, original)
        let changed = proposal.adaptedSession
        XCTAssertEqual(changed.id, original.id)
        XCTAssertEqual(changed.customWorkoutID, original.customWorkoutID)
        XCTAssertEqual(changed.programmeID, original.programmeID)
        XCTAssertEqual(changed.title, original.title)
        XCTAssertEqual(changed.targetDurationMinutes, original.targetDurationMinutes)
        XCTAssertEqual(changed.warmUp, original.warmUp)
        XCTAssertTrue(changed.isAdapted)
        XCTAssertEqual(changed.exercises.map(\.id), original.exercises.map(\.id))
        for (before, after) in zip(original.exercises, changed.exercises) {
            XCTAssertEqual(after.plan, copy(before.plan, sets: max(1, before.plan.plannedSetCount - 1)))
            XCTAssertEqual(after.originalPlan, before.originalPlan.map { copy($0, sets: min($0.plannedSetCount, after.plan.plannedSetCount)) })
            XCTAssertEqual(after.completedSets, [])
        }
        XCTAssertLessThan(proposal.adaptedEstimate.maximumSeconds, proposal.originalEstimate.maximumSeconds)
    }

    func testLongerRestPreservesVolumeAndOnlyChangesActualPrescribedIntervals() throws {
        let original = session(plans: [plan(sets: 2, rest: 120), plan(sets: 1, rest: 45)])
        let proposal = try adapter.proposal(for: original, change: .longerRest,
            assessment: assessment(), at: now, calendar: calendar)
        XCTAssertEqual(proposal.adaptedSession.exercises[0].plan, copy(original.exercises[0].plan, rest: 150))
        // No rest after the final working set of the whole workout.
        XCTAssertEqual(proposal.adaptedSession.exercises[1].plan, original.exercises[1].plan)
        XCTAssertEqual(proposal.adaptedSession.totalPlannedSetCount, original.totalPlannedSetCount)
        XCTAssertEqual(proposal.adaptedEstimate.maximumSeconds - proposal.originalEstimate.maximumSeconds, 60)
        XCTAssertEqual(proposal.adaptedSession.targetDurationMinutes, original.targetDurationMinutes)
    }

    func testZeroRestLongRestAndMinimumOneSetArePreserved() throws {
        let original = session(plans: [plan(sets: 3, rest: 0), plan(sets: 2, rest: 590),
            plan(sets: 2, rest: 900), plan(sets: 1, rest: 600)])
        let rest = try adapter.proposal(for: original, change: .longerRest,
            assessment: assessment(), at: now, calendar: calendar)
        XCTAssertEqual(rest.adaptedSession.exercises.map { $0.plan.restSeconds }, [0, 600, 900, 600])
        let fewer = try adapter.proposal(for: original, change: .fewerSets,
            assessment: assessment(), at: now, calendar: calendar)
        XCTAssertEqual(fewer.adaptedSession.exercises.map { $0.plan.plannedSetCount }, [2, 1, 1, 1])
        XCTAssertEqual(fewer.adaptedSession.exercises.map { $0.plan.restSeconds }, [0, 590, 900, 600])
    }

    func testNoMeaningfulChangeDoesNotOfferAnIdenticalWorkout() {
        assertRejected(session(plans: [plan(sets: 1, rest: 0)]), change: .fewerSets, error: .noBoundedChange)
        assertRejected(session(plans: [plan(sets: 1, rest: 120)]), change: .longerRest, error: .noBoundedChange)
        assertRejected(session(plans: [plan(sets: 3, rest: 600)]), change: .longerRest, error: .noBoundedChange)
    }

    func testActualRepeatedCompleteFoodDiscrepancyQualifiesWhilePartialLogsDoNot() throws {
        let days = [-1, -2].map { calendar.date(byAdding: .day, value: $0, to: today)! }
        let meals = days.map { NutritionEntry(id: UUID(), title: "Meal", calories: 900,
            proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil, loggedAt: $0.addingTimeInterval(3_600)) }
        let histories = days.map { day in
            WorkoutHistoryEntry(session: WorkoutSession(title: "Training",
                exercises: [WorkoutExercise(plan: plan(sets: 1), completedSets: [CompletedSet(load: Load(10),
                    reps: 8, completedAt: day.addingTimeInterval(3_600))])], completedAt: day.addingTimeInterval(3_600)))
        }
        for coverage in [NutritionLogCoverage.complete, .partial] {
            let reviews = try days.map { day in
                NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier, reviewedAt: now,
                    coverage: coverage, mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: meals, on: day, calendar: calendar)),
                    reviewedFoodGroups: nil, reportedCalorieGoal: 2_500,
                    energyTargetContext: .init(source: .selfChosen, intent: .performance))
            }
            let evaluated = WellbeingRecommendationEngine().assess(WellbeingContext(asOf: now, calendar: calendar,
                strengthHistory: histories, outdoorHistory: [], recoveryCheckIns: [report(soreness: .none, energy: .low)],
                meals: meals, nutritionReviews: reviews, chosenFoodGoal: 2_500, hydration: nil, healthSleep: nil,
                nutritionGuidance: .init(reportedAt: now, isAdult: true, needsTailoredNutrition: false,
                    hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)))
            if coverage == .complete {
                let offered = try adapter.proposal(for: session(), change: .fewerSets, assessment: evaluated, at: now, calendar: calendar)
                XCTAssertEqual(offered.concerns.map(\.kind), [.fuelling])
                XCTAssertTrue(offered.concerns[0].evidence.contains(.completeFoodLogsBelowChosenGoal))
            } else {
                assertRejected(session(), assessment: evaluated, error: .noCurrentConcern)
            }
        }
    }

    func testMissingPassiveAndMildSignalsCannotAuthoriseAdjustment() {
        assertRejected(session(), assessment: nil, error: .contextUnavailable)
        assertRejected(session(), assessment: assessment(soreness: .none), error: .noCurrentConcern)
        assertRejected(session(), assessment: assessment(soreness: .moderate), error: .noCurrentConcern)
        let passive = WellbeingAssessment(recommendations: [.init(kind: .hydration, demand: .review,
            evidence: [.waterLogBelowStoredGoal], policyVersion: WellbeingRecommendationEngine.policyVersion,
            sourceReferences: ["WATER"])], recordedTrainingDays: 1, reviewedNutritionDays: 0,
            hasCurrentRecoveryReport: false, hasConflictingSleep: false, evaluatedAt: now,
            timeZoneID: calendar.timeZone.identifier)
        assertRejected(session(), assessment: passive, error: .contextUnavailable)
    }

    func testNewPainOrIllnessPreventsTrainingAdjustment() throws {
        let original = session()
        let proposal = try adapter.proposal(for: original, change: .fewerSets,
            assessment: assessment(), at: now, calendar: calendar)
        for input in [assessment(pain: true), assessment(ill: true)] {
            assertRejected(original, assessment: input, error: .symptomsNeedReview)
            XCTAssertThrowsError(try adapter.revalidated(proposal, current: original, assessment: input, at: now, calendar: calendar)) {
                XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .symptomsNeedReview)
            }
        }
    }

    func testOldFutureDifferentZoneAndSupersededAssessmentAreRejected() {
        let current = assessment()
        for stamp in [now.addingTimeInterval(-601), now.addingTimeInterval(1)] {
            let stale = assessmentCopy(current, evaluatedAt: stamp)
            assertRejected(session(), assessment: stale, error: .contextUnavailable)
        }
        assertRejected(session(), assessment: assessmentCopy(current, zone: "Europe/Sofia"), error: .contextUnavailable)
        let oldRule = WellbeingAssessment(recommendations: current.recommendations.map {
            .init(kind: $0.kind, demand: $0.demand, evidence: $0.evidence, policyVersion: "wellbeing-v0", sourceReferences: $0.sourceReferences)
        }, recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: true,
            hasConflictingSleep: false, evaluatedAt: now, timeZoneID: calendar.timeZone.identifier)
        assertRejected(session(), assessment: oldRule, error: .contextUnavailable)
    }

    func testFreshContextMustStillQualifyAtAcceptance() throws {
        let original = session()
        let proposal = try adapter.proposal(for: original, change: .fewerSets, assessment: assessment(), at: now, calendar: calendar)
        XCTAssertThrowsError(try adapter.revalidated(proposal, current: original, assessment: assessment(soreness: .none), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .noCurrentConcern)
        }
        // A changed corroborating recovery concern must be reviewed again.
        XCTAssertThrowsError(try adapter.revalidated(proposal, current: original,
            assessment: assessment(energy: .low), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .staleProposal)
        }
    }

    func testExpiredCrossDayAndAlteredProposalAreRejected() throws {
        let original = session()
        let proposal = try adapter.proposal(for: original, change: .longerRest, assessment: assessment(), at: now, calendar: calendar)
        let later = now.addingTimeInterval(601)
        XCTAssertThrowsError(try adapter.revalidated(proposal, current: original, assessment: assessment(at: later), at: later, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .staleProposal)
        }
        let midnight = calendar.date(byAdding: .day, value: 1, to: today)!
        let late = midnight.addingTimeInterval(-30)
        let night = try adapter.proposal(for: original, change: .fewerSets, assessment: assessment(at: late), at: late, calendar: calendar)
        XCTAssertThrowsError(try adapter.revalidated(night, current: original, assessment: assessment(at: midnight), at: midnight, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .staleProposal)
        }
        let tampered = WorkoutDemandAdaptationProposal(policyVersion: proposal.policyVersion, change: .longerRest,
            offeredAt: now, timeZoneID: proposal.timeZoneID, concerns: proposal.concerns,
            originalSession: original, adaptedSession: original,
            originalEstimate: proposal.originalEstimate, adaptedEstimate: proposal.adaptedEstimate)
        XCTAssertThrowsError(try adapter.revalidated(tampered, current: original, assessment: assessment(), at: now, calendar: calendar))
    }

    func testSessionChangeOrPerformedWorkCannotBeOverwritten() throws {
        let original = session()
        let proposal = try adapter.proposal(for: original, change: .fewerSets, assessment: assessment(), at: now, calendar: calendar)
        let edited = WorkoutSession(id: original.id, title: original.title, customWorkoutID: original.customWorkoutID,
            exercises: [WorkoutExercise(plan: copy(original.exercises[0].plan, sets: 8))])
        XCTAssertThrowsError(try adapter.revalidated(proposal, current: edited, assessment: assessment(), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .staleProposal)
        }
        var performed = original
        _ = try performed.completeCurrentSet(load: Load(10), reps: 10, at: now)
        assertRejected(performed, error: .workoutStarted)
        XCTAssertThrowsError(try adapter.revalidated(proposal, current: performed, assessment: assessment(), at: now, calendar: calendar))
        XCTAssertEqual(performed.completedSetCount, 1)
        assertRejected(WorkoutSession(title: "Moved", exercises: original.exercises, currentExerciseIndex: 1), error: .workoutStarted)
        assertRejected(WorkoutSession(title: "Rest", exercises: original.exercises, restEndsAt: now.addingTimeInterval(20)), error: .workoutStarted)
        assertRejected(WorkoutSession(title: "Duration", exercises: original.exercises, activeRestDuration: 30), error: .workoutStarted)
        assertRejected(WorkoutSession(title: "Complete", exercises: original.exercises, completedAt: now), error: .workoutStarted)
        assertRejected(proposal.adaptedSession, error: .alreadyAdapted)
    }

    func testInvalidPrescriptionAndDuplicateOccurrenceAreRejected() {
        assertRejected(session(plans: [plan(rest: .infinity)]), error: .invalidPrescription)
        assertRejected(session(plans: [plan(load: -.infinity)]), error: .invalidPrescription)
        let duplicate = plan()
        assertRejected(session(plans: [duplicate, duplicate]), error: .invalidPrescription)
    }

    func testManualDraftsAndEffortSurviveProposalAcceptanceAndUndo() throws {
        for change in WorkoutDemandChange.allCases {
            let original = session()
            let model = WorkoutViewModel(session: original)
            model.loadDraft = "17.5"
            model.repsDraft = "11"
            model.enteredRIR = 3
            model.proposeDemandAdaptation(change, assessment: assessment(), at: now, calendar: calendar)
            XCTAssertEqual(model.session, original)
            XCTAssertTrue(model.applyPendingDemandAdaptation(assessment: assessment(), at: now, calendar: calendar))
            XCTAssertEqual(model.loadDraft, "17.5")
            XCTAssertEqual(model.repsDraft, "11")
            XCTAssertEqual(model.enteredRIR, 3)
            XCTAssertTrue(model.canUndoAdaptation)
            model.undoAdaptation()
            XCTAssertEqual(model.session, original)
            XCTAssertEqual(model.loadDraft, "17.5")
            XCTAssertEqual(model.repsDraft, "11")
            XCTAssertEqual(model.enteredRIR, 3)
        }
        let timed = WorkoutViewModel(session: session(plans: [plan(timed: true, perSide: true)]))
        timed.durationDraft = "47"
        timed.proposeDemandAdaptation(.fewerSets, assessment: assessment(), at: now, calendar: calendar)
        XCTAssertTrue(timed.applyPendingDemandAdaptation(assessment: assessment(), at: now, calendar: calendar))
        timed.undoAdaptation()
        XCTAssertEqual(timed.durationDraft, "47")
    }

    func testUnacceptedOptionDoesNotPersistAndAcceptedOptionsRecoverWithUndo() throws {
        let name = "01.workout-demand." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "active")
        for change in WorkoutDemandChange.allCases {
            let original = session()
            var writes = 0
            let model = WorkoutViewModel(session: original, onSnapshotChanged: { snapshot, _ in
                writes += 1
                try store.save(XCTUnwrap(snapshot))
            })
            let initialWrites = writes
            model.proposeDemandAdaptation(change, assessment: assessment(), at: now, calendar: calendar)
            XCTAssertEqual(writes, initialWrites)
            let before = try XCTUnwrap(store.load())
            XCTAssertEqual(before.session, original)
            XCTAssertNil(before.sessionBeforeAdaptation)
            let beforeRelaunch = WorkoutViewModel(session: original, restoredSnapshot: before, persistInitialSnapshot: false)
            XCTAssertNil(beforeRelaunch.pendingDemandAdaptation)
            XCTAssertTrue(model.applyPendingDemandAdaptation(assessment: assessment(), at: now, calendar: calendar))
            let saved = try XCTUnwrap(store.load())
            XCTAssertTrue(saved.isCompatible)
            XCTAssertEqual(saved.version, ActiveWorkoutSnapshot.currentVersion)
            XCTAssertEqual(saved.session, model.session)
            XCTAssertEqual(saved.sessionBeforeAdaptation, original)
            let restored = WorkoutViewModel(session: original, restoredSnapshot: saved, persistInitialSnapshot: false,
                onSnapshotChanged: { snapshot, _ in try store.save(XCTUnwrap(snapshot)) })
            XCTAssertNil(restored.pendingDemandAdaptation)
            XCTAssertTrue(restored.canUndoAdaptation)
            restored.undoAdaptation()
            XCTAssertEqual(restored.session, original)
            let undone = try XCTUnwrap(store.load())
            XCTAssertEqual(undone.session, original)
            XCTAssertNil(undone.sessionBeforeAdaptation)
            try store.clear(expectedSessionID: original.id)
        }
    }

    func testFailedSaveHoldsAcceptedPrescriptionWithoutFalseAcknowledgement() throws {
        let original = session()
        var fail = false
        var saved: ActiveWorkoutSnapshot?
        let model = WorkoutViewModel(session: original, onSnapshotChanged: { snapshot, _ in
            if fail { throw WorkoutPersistenceError.unavailable }
            saved = snapshot
        })
        model.proposeDemandAdaptation(.longerRest, assessment: assessment(), at: now, calendar: calendar)
        fail = true
        XCTAssertFalse(model.applyPendingDemandAdaptation(assessment: assessment(), at: now, calendar: calendar))
        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertTrue(model.session.isAdapted)
        XCTAssertEqual(saved?.session, original)
        XCTAssertNil(model.pendingDemandAdaptation)
        XCTAssertFalse(model.canUndoAdaptation)
        fail = false
        model.retryPersistence(at: now)
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(saved?.session, model.session)
        XCTAssertTrue(model.canUndoAdaptation)
        model.undoAdaptation()
        XCTAssertEqual(saved?.session, original)
    }

    func testLoggingAfterAcceptedAdjustmentKeepsAuthoredExecutionAndDisablesUndo() throws {
        let model = WorkoutViewModel(session: session())
        model.proposeDemandAdaptation(.longerRest, assessment: assessment(), at: now, calendar: calendar)
        XCTAssertTrue(model.applyPendingDemandAdaptation(assessment: assessment(), at: now, calendar: calendar))
        let target = try XCTUnwrap(model.session.currentExercise?.plan)
        model.completeCurrentSet(at: now)
        let actual = try XCTUnwrap(model.session.exercises[0].completedSets.first)
        XCTAssertEqual(actual.executionTarget?.restSeconds, target.restSeconds)
        XCTAssertEqual(actual.executionTarget?.plannedSetCount, target.plannedSetCount)
        XCTAssertEqual(model.session.activeRestDuration, target.restSeconds)
        XCTAssertFalse(model.canUndoAdaptation)
        XCTAssertFalse(model.canReviewDemandAdaptation)
        model.undoAdaptation()
        XCTAssertEqual(model.session.completedSetCount, 1)
    }

    func testFreshHostSourceIsReadAgainAndUnavailableContextRejectsAcceptance() async throws {
        let authority = WorkoutDemandAuthority()
        let unavailable = await authority.assessment(at: now, calendar: calendar)
        XCTAssertNil(unavailable)
        var reads = 0
        var current: WellbeingAssessment? = assessment()
        authority.install { _, _ in reads += 1; return current }
        let model = WorkoutViewModel(session: session())
        let offered = await authority.assessment(at: now, calendar: calendar)
        model.proposeDemandAdaptation(.fewerSets, assessment: offered, at: now, calendar: calendar)
        let original = model.session
        current = nil
        let refreshed = await authority.assessment(at: now, calendar: calendar)
        XCTAssertFalse(model.applyPendingDemandAdaptation(assessment: refreshed, at: now, calendar: calendar))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.session, original)
        XCTAssertEqual(model.demandAdaptationError, .contextUnavailable)
        current = assessmentCopy(assessment(), evaluatedAt: now.addingTimeInterval(-601))
        let stale = await authority.assessment(at: now, calendar: calendar)
        XCTAssertNil(stale)
    }

    func testThirtyMinuteProposalExcludesSimultaneousDemandChange() {
        let model = WorkoutViewModel(session: session())
        model.proposeThirtyMinuteAdaptation()
        XCTAssertNotNil(model.pendingAdaptation)
        XCTAssertFalse(model.canReviewDemandAdaptation)
        model.proposeDemandAdaptation(.fewerSets, assessment: assessment(), at: now, calendar: calendar)
        XCTAssertNil(model.pendingDemandAdaptation)
        XCTAssertFalse(model.session.isAdapted)
    }

    func testTimeAdaptationUndoAlsoKeepsManualInputWhenFirstTargetIsUnchanged() {
        let original = session()
        let model = WorkoutViewModel(session: original)
        model.proposeThirtyMinuteAdaptation()
        model.applyPendingAdaptation()
        model.loadDraft = "21.5"
        model.repsDraft = "12"
        model.enteredRIR = 2
        model.undoAdaptation()
        XCTAssertEqual(model.session, original)
        XCTAssertEqual(model.loadDraft, "21.5")
        XCTAssertEqual(model.repsDraft, "12")
        XCTAssertEqual(model.enteredRIR, 2)
    }

    func testUndoingASwapKeepsAcceptedRecoverySetAndRestChanges() throws {
        let source = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let originalPlan = ExercisePlan(exerciseID: source.id, name: source.name, targetLoad: Load(14),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 120, previousPerformance: [],
            alternativeExerciseIDs: source.resolvedAlternativeIDs)
        var workout = WorkoutSession(title: "Swapped arms", programmeID: .biceps, exercises: [.init(plan: originalPlan)])
        let inputs = WorkoutSubstitutionInput(loadDraft: "14", repsDraft: "11", durationDraft: "",
            load: 14, reps: 11, rir: 3)
        try workout.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10), input: inputs)
        for change in WorkoutDemandChange.allCases {
            var adapted = try adapter.proposal(for: workout, change: change,
                assessment: assessment(), at: now, calendar: calendar).adaptedSession
            let acceptedPlan = try XCTUnwrap(adapted.currentExercise?.plan)
            XCTAssertEqual(adapted.currentExercise?.substitutionInput, inputs)
            XCTAssertTrue(adapted.undoCurrentSubstitution())
            XCTAssertEqual(adapted.currentExercise?.plan.exerciseID, source.id)
            XCTAssertEqual(adapted.currentExercise?.plan.plannedSetCount, acceptedPlan.plannedSetCount)
            XCTAssertEqual(adapted.currentExercise?.plan.restSeconds, acceptedPlan.restSeconds)
            XCTAssertNil(adapted.currentExercise?.substitutionInput)
        }
    }

    private func assertRejected(_ workout: WorkoutSession, change: WorkoutDemandChange = .fewerSets,
                                assessment: WellbeingAssessment? = nil, error: WorkoutDemandAdaptationError,
                                file: StaticString = #filePath, line: UInt = #line) {
        // Nil explicitly means unavailable in the missing-context fixture.
        let input = error == .contextUnavailable ? assessment : (assessment ?? self.assessment())
        XCTAssertThrowsError(try adapter.proposal(for: workout, change: change, assessment: input, at: now, calendar: calendar), file: file, line: line) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, error, file: file, line: line)
        }
    }

    private func report(soreness: RecoverySoreness = .severe, energy: RecoveryEnergy = .usual,
                        pain: Bool = false, ill: Bool = false, at stamp: Date? = nil) -> RecoveryCheckIn {
        let stamp = stamp ?? now
        return .init(id: UUID(), day: calendar.startOfDay(for: stamp), timeZoneID: calendar.timeZone.identifier,
            reportedAt: stamp, energy: energy, soreness: soreness, sleepHours: nil,
            hasNewOrWorseningPain: pain, feelsUnwell: ill, feelsUnusuallyHungry: false, feelsThirsty: false)
    }

    private func assessment(soreness: RecoverySoreness = .severe, energy: RecoveryEnergy = .usual,
                            pain: Bool = false, ill: Bool = false, at stamp: Date? = nil) -> WellbeingAssessment {
        let stamp = stamp ?? now
        return WellbeingRecommendationEngine().assess(WellbeingContext(asOf: stamp, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [report(soreness: soreness, energy: energy, pain: pain, ill: ill, at: stamp)],
            meals: [], nutritionReviews: [], chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
    }

    private func assessmentCopy(_ value: WellbeingAssessment, evaluatedAt: Date? = nil, zone: String? = nil) -> WellbeingAssessment {
        .init(recommendations: value.recommendations, recordedTrainingDays: value.recordedTrainingDays,
            reviewedNutritionDays: value.reviewedNutritionDays, hasCurrentRecoveryReport: value.hasCurrentRecoveryReport,
            hasConflictingSleep: value.hasConflictingSleep, evaluatedAt: evaluatedAt ?? value.evaluatedAt,
            timeZoneID: zone ?? value.timeZoneID)
    }

    private func session(plans: [ExercisePlan]? = nil, warmUp: WorkoutWarmUp? = nil) -> WorkoutSession {
        let plans = plans ?? [plan(), plan(sets: 2, timed: true, perSide: true)]
        return .init(title: "My workout", customWorkoutID: UUID(), targetDurationMinutes: 30, warmUp: warmUp,
            exercises: plans.enumerated().map { index, plan in
                WorkoutExercise(plan: plan, originalPlan: index == 0 ? copy(plan, rest: 180) : nil)
            })
    }

    private func plan(sets: Int = 3, rest: Double = 120, load: Double = 10,
                      timed: Bool = false, perSide: Bool = false) -> ExercisePlan {
        .init(exerciseID: ExerciseIDs.gobletSquat, name: "User movement", targetLoad: Load(load), targetReps: RepRange(8, 12),
            plannedSetCount: sets, restSeconds: rest, previousPerformance: [PreviousSetPerformance(load: Load(8), reps: 9)],
            sourcePrescription: "Authored work", coachingCue: "My cue", painGuardrail: "My guardrail",
            equipmentIdentifiers: ["dumbbell"], alternativeExerciseIDs: [ExerciseIDs.gobletSquat],
            unresolvedAlternativeNames: ["My alternative"], targetPrescription: .init(unit: timed ? .seconds : .repetitions,
                lowerBound: timed ? 30 : 8, upperBound: timed ? 60 : 12, perSide: perSide))
    }

    private func copy(_ plan: ExercisePlan, sets: Int? = nil, rest: Double? = nil) -> ExercisePlan {
        .init(id: plan.id, exerciseID: plan.exerciseID, name: plan.name, targetLoad: plan.targetLoad, targetReps: plan.targetReps,
            plannedSetCount: sets ?? plan.plannedSetCount, restSeconds: rest ?? plan.restSeconds,
            previousPerformance: plan.previousPerformance, sourcePrescription: plan.sourcePrescription,
            coachingCue: plan.coachingCue, painGuardrail: plan.painGuardrail, equipmentIdentifiers: plan.equipmentIdentifiers,
            alternativeExerciseIDs: plan.alternativeExerciseIDs, unresolvedAlternativeNames: plan.unresolvedAlternativeNames,
            targetPrescription: plan.targetPrescription)
    }
}
