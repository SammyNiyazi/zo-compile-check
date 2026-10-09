import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutAdaptationAndHistoryTests: XCTestCase {
    func testMuscleDayAndWeekUseLocalCalendarBoundariesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        calendar.firstWeekday = 1
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        let day = try XCTUnwrap(WorkoutMusclePeriod.day.interval(containing: date, calendar: calendar))
        let week = try XCTUnwrap(WorkoutMusclePeriod.week.interval(containing: date, calendar: calendar))
        XCTAssertEqual(day.duration, 25 * 3_600)
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertEqual(calendar.component(.hour, from: week.end), 0)
        XCTAssertEqual(week.duration, 7 * 24 * 3_600 + 3_600)
        XCTAssertTrue(day.start >= week.start && day.end <= week.end)
    }
    func testLocalDayPercentageUsesRealDayDurationAtDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let springNoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let autumnNoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        XCTAssertEqual(calendar.dateInterval(of: .day, for: springNoon)?.duration, 23 * 3_600)
        XCTAssertEqual(calendar.dateInterval(of: .day, for: autumnNoon)?.duration, 25 * 3_600)
        XCTAssertEqual(LocalDayProgress(at: springNoon, calendar: calendar)?.percentage, 47)
        XCTAssertEqual(LocalDayProgress(at: autumnNoon, calendar: calendar)?.percentage, 52)
    }

    func testLocalDayPercentageResetsAtMidnightAndDoesNotRoundUpBeforeIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        XCTAssertEqual(LocalDayProgress(at: midnight, calendar: calendar)?.percentage, 0)
        XCTAssertEqual(LocalDayProgress(at: midnight.addingTimeInterval(12 * 3_600), calendar: calendar)?.percentage, 50)
        XCTAssertEqual(LocalDayProgress(at: midnight.addingTimeInterval(24 * 3_600 - 1), calendar: calendar)?.percentage, 99)
        XCTAssertEqual(LocalDayProgress(at: midnight.addingTimeInterval(24 * 3_600), calendar: calendar)?.percentage, 0)
    }

    func testLocalDayPercentageRecalculatesForChangedTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var local = utc
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let date = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        XCTAssertEqual(LocalDayProgress(at: date, calendar: utc)?.percentage, 50)
        XCTAssertEqual(LocalDayProgress(at: date, calendar: local)?.percentage, 62)
    }

    func testPrimaryDockDoesNotConsumeOfferedWorkoutHeight() {
        let actions: [WorkoutPrimaryAction] = [
            .logSet(number: 1),
            .rest(deadline: Date().addingTimeInterval(60), duration: 90),
            .startSet(number: 1, exerciseName: "Seated overhead triceps extension")
        ]
        for action in actions {
            for motion in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    for size in [DynamicTypeSize.large, .accessibility3] {
                        let dock = WorkoutPrimaryDock(
                            action: action, savedSetNumber: 1, confirmationTrigger: 0,
                            commit: .steady, motionEnabled: motion, onActivate: {}
                        )
                        .zeroOneTheme(.resolve(.liquidMidnight, colorScheme: scheme))
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                        let host = UIHostingController(rootView: dock)
                        let compact = host.sizeThatFits(in: CGSize(width: 320, height: 400))
                        let tall = host.sizeThatFits(in: CGSize(width: 320, height: 1_000))
                        XCTAssertEqual(compact.height, tall.height, accuracy: 1)
                        XCTAssertGreaterThanOrEqual(tall.height, 56) // study 30 primary action height
                        XCTAssertLessThan(tall.height, 300, "The dock must leave space for workout content")
                        XCTAssertLessThanOrEqual(tall.width, 320)
                    }
                }
            }
        }
    }

    func testUnchosenLoadedWeightStaysBlankAndCannotBeLogged() throws {
        let source = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.gobletSquat))
        let plan = ExercisePlan(
            exerciseID: source.id, name: source.name, targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
            previousPerformance: [], alternativeExerciseIDs: source.resolvedAlternativeIDs
        )
        let viewModel = WorkoutViewModel(session: WorkoutSession(
            title: "Legs", exercises: [WorkoutExercise(plan: plan)]
        ))

        XCTAssertEqual(viewModel.loadDraft, "")
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(viewModel.inputErrorMessage, "Enter a positive load for this exercise.")

        viewModel.adjustLoad(by: 2.5)
        XCTAssertEqual(viewModel.loadDraft, "2.5")
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.session.completedSetCount, 1)
        XCTAssertEqual(viewModel.session.currentExercise?.completedSets.first?.load, Load(2.5))
    }

    func testCustomBodyweightCanLogWithoutExternalLoad() {
        let plan = ExercisePlan(
            exerciseID: ExerciseID(rawValue: "MOV-custom-bodyweight"), name: "Custom bodyweight",
            targetLoad: Load(0), targetReps: RepRange(8, 12), plannedSetCount: 2,
            restSeconds: 0, previousPerformance: [], equipmentIdentifiers: ["Bodyweight"]
        )
        let viewModel = WorkoutViewModel(session: WorkoutSession(
            title: "Custom", exercises: [WorkoutExercise(plan: plan)]
        ))

        XCTAssertEqual(viewModel.loadDraft, "0.0")
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.session.completedSetCount, 1)
        XCTAssertEqual(viewModel.session.currentExercise?.completedSets.first?.load, Load(0))
    }

    func testRestoredBodyweightDraftUsesRecoveredExerciseInsteadOfFallbackSession() throws {
        let active = InMemoryActiveWorkoutStore()
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.pushUp, name: "Push-Up", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 0,
            previousPerformance: []
        )
        let savedSession = WorkoutSession(
            title: "Bodyweight", programmeID: .zeroOneBuild, exercises: [WorkoutExercise(plan: plan)]
        )
        let original = WorkoutViewModel(session: savedSession, onSnapshotChanged: active.handle)
        original.repsDraft = "11"
        XCTAssertTrue(original.commitDrafts())
        let snapshot = try XCTUnwrap(active.load())

        let recovered = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), restoredSnapshot: snapshot,
            persistInitialSnapshot: false
        )

        XCTAssertEqual(recovered.session.id, savedSession.id)
        XCTAssertEqual(recovered.session.currentExercise?.plan.exerciseID, ExerciseIDs.pushUp)
        XCTAssertEqual(recovered.loadDraft, "0.0")
        XCTAssertEqual(recovered.repsDraft, "11")
        XCTAssertEqual(recovered.enteredReps, 11)
    }

    func testWorkoutSwapUsesManualLoadPersistsAndCanUndoBeforeFirstSet() throws {
        let active = InMemoryActiveWorkoutStore()
        let source = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let plan = ExercisePlan(
            exerciseID: source.id, name: source.name, targetLoad: Load(16),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
            previousPerformance: [PreviousSetPerformance(load: Load(16), reps: 10)],
            alternativeExerciseIDs: source.resolvedAlternativeIDs
        )
        let session = WorkoutSession(title: "Arms", exercises: [WorkoutExercise(plan: plan)])
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)

        XCTAssertTrue(viewModel.canSubstituteCurrentExercise)
        XCTAssertTrue(try confirmedTestSwap(viewModel, with: ExerciseIDs.dumbbellCurl, load: Load(12)))
        XCTAssertEqual(viewModel.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellCurl)
        XCTAssertEqual(viewModel.enteredLoadValue, 12)
        XCTAssertEqual(viewModel.loadDraft, "12.0")
        XCTAssertTrue(viewModel.session.currentExercise?.plan.previousPerformance.isEmpty == true)
        XCTAssertEqual(active.load()?.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellCurl)

        XCTAssertTrue(viewModel.undoCurrentSubstitution())
        XCTAssertEqual(viewModel.session.currentExercise?.plan, plan)
        XCTAssertEqual(active.load()?.session.currentExercise?.plan, plan)
    }

    func testAdaptationUndoDoesNotRevertAnExerciseSwap() throws {
        let source = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let plan = ExercisePlan(
            exerciseID: source.id, name: source.name, targetLoad: Load(16),
            targetReps: RepRange(8, 12), plannedSetCount: 4, restSeconds: 120,
            previousPerformance: [], alternativeExerciseIDs: source.resolvedAlternativeIDs
        )
        let viewModel = WorkoutViewModel(session: WorkoutSession(
            title: "Arms", exercises: [WorkoutExercise(plan: plan)]
        ))

        viewModel.proposeThirtyMinuteAdaptation()
        viewModel.applyPendingAdaptation()
        XCTAssertTrue(try confirmedTestSwap(viewModel, with: ExerciseIDs.dumbbellCurl, load: Load(12)))
        viewModel.undoAdaptation()

        XCTAssertEqual(viewModel.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellCurl)
        XCTAssertEqual(viewModel.session.currentExercise?.plan.targetLoad, Load(12))
        XCTAssertEqual(viewModel.session.currentExercise?.plan.plannedSetCount, 4)
    }

    func testSwapSaveFailureBlocksLoggingUntilRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let source = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let plan = ExercisePlan(
            exerciseID: source.id, name: source.name, targetLoad: Load(16),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
            previousPerformance: [], alternativeExerciseIDs: source.resolvedAlternativeIDs
        )
        let viewModel = WorkoutViewModel(
            session: WorkoutSession(title: "Arms", exercises: [WorkoutExercise(plan: plan)]),
            onSnapshotChanged: active.handle
        )

        active.failSave = true
        XCTAssertFalse(try confirmedTestSwap(viewModel, with: ExerciseIDs.dumbbellCurl, load: Load(12)))
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellCurl)
    }

    func testDraftSaveFailureKeepsEnteredValuesUntilExplicitRetry() {
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle
        )
        let priorSnapshot = active.load()

        active.failSave = true
        viewModel.loadDraft = "12.5"
        viewModel.repsDraft = "10"

        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertNil(viewModel.unconfirmedWorkingSet)
        XCTAssertEqual(viewModel.loadDraft, "12.5")
        XCTAssertEqual(viewModel.repsDraft, "10")
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(active.load(), priorSnapshot)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.enteredLoadValue, 12.5)
        XCTAssertEqual(active.load()?.enteredReps, 10)
    }

    func testColdStartPlaceholderDoesNotBecomeAnActiveWorkout() throws {
        let active = InMemoryActiveWorkoutStore()
        let placeholder = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(),
            persistInitialSnapshot: false,
            onSnapshotChanged: active.handle
        )
        XCTAssertNil(active.load())
        XCTAssertNil(placeholder.persistedActivity)

        let selected = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps)?.makeSession())
        let started = WorkoutViewModel(session: selected, onSnapshotChanged: active.handle)
        XCTAssertEqual(active.load()?.session.id, selected.id)
        XCTAssertEqual(active.load()?.session.warmUp?.status, .pending)
        XCTAssertNotNil(started.persistedActivity)
    }

    func testWarmUpSaveFailureKeepsSetGateUntilRetryAndRestoresOutcome() throws {
        let active = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps)?.makeSession())
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        let pending = try XCTUnwrap(active.load())
        XCTAssertEqual(pending.session.warmUp?.status, .pending)

        active.failSave = true
        viewModel.resolveWarmUp(as: .completed, at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(viewModel.session.warmUp?.status, .completed)
        XCTAssertTrue(viewModel.requiresWarmUpGate)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(active.load()?.session.warmUp?.status, .pending)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertFalse(viewModel.requiresWarmUpGate)
        XCTAssertNil(viewModel.persistenceErrorMessage)
        let saved = try XCTUnwrap(active.load())
        XCTAssertEqual(saved.session.warmUp?.status, .completed)
        let restored = WorkoutViewModel(
            session: saved.session, restoredSnapshot: saved, onSnapshotChanged: active.handle
        )
        XCTAssertFalse(restored.requiresWarmUpGate)
        XCTAssertEqual(restored.session.warmUp?.status, .completed)
    }

    func testWarmUpStepProgressRestoresAndFailedSaveRequiresRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps)?.makeSession())
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)

        viewModel.toggleWarmUpStep(at: 1)
        XCTAssertEqual(active.load()?.session.warmUp?.checkedStepIndices, Set([1]))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)

        let saved = try XCTUnwrap(active.load())
        let restored = WorkoutViewModel(
            session: saved.session, restoredSnapshot: saved, onSnapshotChanged: active.handle
        )
        XCTAssertEqual(restored.session.warmUp?.checkedStepIndices, Set([1]))
        XCTAssertTrue(restored.requiresWarmUpGate)

        active.failSave = true
        restored.toggleWarmUpStep(at: 2)
        XCTAssertNotNil(restored.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.warmUp?.checkedStepIndices, Set([1]))
        restored.toggleWarmUpStep(at: 0)
        XCTAssertEqual(restored.session.warmUp?.checkedStepIndices, Set([1, 2]))

        active.failSave = false
        restored.retryPersistence()
        XCTAssertNil(restored.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.warmUp?.checkedStepIndices, Set([1, 2]))
        XCTAssertEqual(restored.session.completedSetCount, 0)
    }

    func testWarmUpOutcomeIsSeparateFromSavedWorkingSetHistory() throws {
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let plan = ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
            plannedSetCount: 1, restSeconds: 0, previousPerformance: []
        )
        let session = WorkoutSession(
            title: "Biceps", programmeID: .biceps,
            warmUp: WorkoutWarmUp(estimatedMinutes: 5, steps: ["Move easily."]),
            exercises: [WorkoutExercise(plan: plan)]
        )
        let viewModel = WorkoutViewModel(session: session, onSessionCompleted: history.record)
        viewModel.resolveWarmUp(as: .skipped, at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.warmUp?.status, .skipped)
        XCTAssertEqual(WorkoutHistoryDisplayItem(entry: entry).warmUp?.status, .skipped)
        XCTAssertEqual(entry.completedSetCount, 1)
        XCTAssertEqual(entry.plannedSetCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testThirtyMinuteAdaptationUsesStableLocalRules() throws {
        let source = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .lowerBodyA)?.makeSession())

        let proposal = try DeterministicWorkoutAdapter().proposal(for: source)

        XCTAssertEqual(proposal.targetMinutes, 30)
        XCTAssertEqual(proposal.adaptedSession.programmeID, .lowerBodyA)
        XCTAssertEqual(proposal.adaptedSession.targetDurationMinutes, 30)
        XCTAssertEqual(proposal.adaptedSession.warmUp, source.warmUp)
        XCTAssertTrue(proposal.adaptedSession.isAdapted)
        XCTAssertLessThanOrEqual(proposal.adaptedSession.exercises.count, source.exercises.count)
        XCTAssertLessThan(proposal.adaptedSession.totalPlannedSetCount, source.totalPlannedSetCount)
        XCTAssertTrue(WorkoutTimeEstimator().estimate(for: proposal.adaptedSession)?.fitsWithin(minutes: 30) == true)
        for exercise in proposal.adaptedSession.exercises {
            let original = try XCTUnwrap(source.exercises.first { $0.id == exercise.id })
            XCTAssertEqual(exercise.plan.restSeconds, original.plan.restSeconds)
            XCTAssertLessThanOrEqual(exercise.plan.plannedSetCount, original.plan.plannedSetCount)
        }
        XCTAssertEqual(
            proposal.adaptedSession.exercises.map(\.plan.exerciseID),
            Array(source.exercises.prefix(proposal.adaptedSession.exercises.count)).map(\.plan.exerciseID)
        )
        XCTAssertEqual(proposal.changes.first, "11 to \(proposal.adaptedSession.totalPlannedSetCount) working sets")
        XCTAssertEqual(proposal.changes.dropFirst().first, "Prescribed rest retained")
        XCTAssertEqual(
            proposal.adaptedSession.currentExercise?.plan.coachingCue,
            source.currentExercise?.plan.coachingCue
        )
    }

    func testAppliedAdaptationCanBeUndoneBeforeWorkStarts() throws {
        let original = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        let viewModel = WorkoutViewModel(session: original)

        viewModel.proposeThirtyMinuteAdaptation()
        XCTAssertNotNil(viewModel.pendingAdaptation)

        viewModel.applyPendingAdaptation()
        XCTAssertTrue(viewModel.session.isAdapted)
        XCTAssertTrue(viewModel.canUndoAdaptation)

        viewModel.undoAdaptation()
        XCTAssertEqual(viewModel.session, original)
        XCTAssertFalse(viewModel.canUndoAdaptation)
    }

    func testAdaptationCannotApplyUntilItsProposalIsSaved() throws {
        let active = InMemoryActiveWorkoutStore()
        let original = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        let viewModel = WorkoutViewModel(session: original, onSnapshotChanged: active.handle)

        active.failSave = true
        viewModel.proposeThirtyMinuteAdaptation()
        XCTAssertNotNil(viewModel.pendingAdaptation)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session, original)

        viewModel.applyPendingAdaptation()
        XCTAssertEqual(viewModel.session, original)
        XCTAssertNotNil(viewModel.pendingAdaptation)
        XCTAssertFalse(viewModel.canUndoAdaptation)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertNotNil(active.load()?.pendingAdaptation)

        viewModel.applyPendingAdaptation()
        XCTAssertTrue(viewModel.session.isAdapted)
        XCTAssertTrue(active.load()?.session.isAdapted == true)
    }

    func testAdaptationAfterLoggedSetIsRejectedWithoutChangingSetData() throws {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        let completionDate = Date(timeIntervalSince1970: 1_000)

        viewModel.completeCurrentSet(at: completionDate)
        let loggedSession = viewModel.session
        viewModel.proposeThirtyMinuteAdaptation()

        XCTAssertEqual(viewModel.adaptationError, .workoutAlreadyStarted)
        XCTAssertNil(viewModel.pendingAdaptation)
        XCTAssertEqual(viewModel.session, loggedSession)
        XCTAssertEqual(viewModel.session.completedSetCount, 1)
    }

    func testCompletingSetPublishesGuidanceFromLoggedRIR() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        viewModel.enteredRIR = 0

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(viewModel.lastSetGuidance?.kind, .limitReached)
        XCTAssertEqual(viewModel.session.exercises[0].completedSets[0].rir, 0)
    }

    func testDirectEntryRecordsExactValuesWithoutInventingEffort() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        viewModel.loadDraft = "12,5"
        viewModel.repsDraft = "10"

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))

        let set = viewModel.session.exercises[0].completedSets[0]
        XCTAssertEqual(set.load.value, 12.5)
        XCTAssertEqual(set.reps, 10)
        XCTAssertNil(set.rir)
        XCTAssertNil(viewModel.lastSetGuidance)
        XCTAssertEqual(viewModel.enteredLoadValue, 12.5)
        XCTAssertEqual(viewModel.enteredReps, 10)
        XCTAssertEqual(viewModel.loadDraft, "12.5")
        XCTAssertNil(viewModel.enteredRIR)
    }

    func testValidTypedValuesRestoreWithoutDoneOrLog() throws {
        let active = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let first = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        first.loadDraft = "12,5"
        first.repsDraft = "10"

        let pending = try XCTUnwrap(active.load())
        XCTAssertEqual(pending.enteredLoadValue, 12.5)
        XCTAssertEqual(pending.enteredReps, 10)
        let restored = WorkoutViewModel(
            session: pending.session, restoredSnapshot: pending, onSnapshotChanged: active.handle
        )
        XCTAssertEqual(restored.loadDraft, "12.5")
        XCTAssertEqual(restored.repsDraft, "10")
    }

    func testInvalidDirectEntryDoesNotLogOrReplaceDraft() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        viewModel.loadDraft = ""
        viewModel.repsDraft = "10"

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        viewModel.adjustLoad(by: 2.5)

        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(viewModel.loadDraft, "")
        XCTAssertNotNil(viewModel.inputErrorMessage)
    }

    func testProgressionLoadChoiceUpdatesEditorAndRecoverySnapshot() throws {
        let active = InMemoryActiveWorkoutStore()
        let session = MockWorkoutFactory.upperBodyA()
        let unit = try XCTUnwrap(session.currentExercise?.plan.targetLoad.unit)
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)

        viewModel.loadDraft = ""
        XCTAssertFalse(viewModel.commitDrafts())
        viewModel.selectLoad(Load(42.5, unit: unit))

        XCTAssertEqual(viewModel.loadDraft, "42.5")
        XCTAssertEqual(viewModel.enteredLoadValue, 42.5)
        XCTAssertNil(viewModel.inputErrorMessage)
        let firstSaved = try XCTUnwrap(active.load())
        XCTAssertEqual(firstSaved.enteredLoadValue, 42.5)

        viewModel.selectLoad(Load(40, unit: unit))
        XCTAssertEqual(viewModel.loadDraft, "40.0")
        let repeatedSaved = try XCTUnwrap(active.load())
        XCTAssertEqual(repeatedSaved.enteredLoadValue, 40)
    }

    func testProgressionOfferDoesNotReplayAfterFirstSetUndoOrRestore() throws {
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle
        )
        let exerciseID = try XCTUnwrap(viewModel.session.currentExercise?.plan.id)
        XCTAssertTrue(viewModel.canShowProgressionOffer(
            for: try XCTUnwrap(viewModel.session.currentExercise)
        ))

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(viewModel.progressionOfferConsumedExerciseIDs.contains(exerciseID))
        viewModel.undoLastSet()
        XCTAssertFalse(viewModel.canShowProgressionOffer(
            for: try XCTUnwrap(viewModel.session.currentExercise)
        ))

        let saved = try XCTUnwrap(active.load())
        XCTAssertEqual(saved.progressionOfferConsumedExerciseIDs, Set([exerciseID]))
        let restored = WorkoutViewModel(
            session: saved.session, restoredSnapshot: saved, onSnapshotChanged: active.handle
        )
        XCTAssertFalse(restored.canShowProgressionOffer(
            for: try XCTUnwrap(restored.session.currentExercise)
        ))
    }

    func testContextFreeProgressionOfferCannotMutateOrPersist() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle)
        let before = model.enteredLoadValue
        let opportunity = WorkoutProgressionOpportunity(previousLoad: Load(40), suggestedLoad: Load(42.5))
        model.selectProgressionOffer(.tryNext, opportunity: opportunity)
        model.selectProgressionOffer(.repeatPrevious, opportunity: opportunity)
        XCTAssertEqual(model.enteredLoadValue, before)
        XCTAssertTrue(model.progressionOfferSelections.isEmpty)
        XCTAssertTrue(active.load()?.progressionOfferSelections?.isEmpty ?? true)
    }

    func testRenderingProgressionOfferNeverResetsAMatchingDraft() throws {
        let active = InMemoryActiveWorkoutStore()
        let plan = ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(42.5), targetReps: RepRange(8, 12),
            plannedSetCount: 2, restSeconds: 60, previousPerformance: []
        )
        let viewModel = WorkoutViewModel(
            session: WorkoutSession(title: "Arms", programmeID: .arms, exercises: [WorkoutExercise(plan: plan)]),
            onSnapshotChanged: active.handle
        )
        let opportunity = WorkoutProgressionOpportunity(
            previousLoad: Load(40), suggestedLoad: Load(42.5)
        )

        viewModel.prepareProgressionOffer(opportunity)
        XCTAssertEqual(viewModel.enteredLoadValue, 42.5, "Rendering preserves an authored or manually edited draft")
        XCTAssertNil(viewModel.progressionOfferSelections[plan.id])
        XCTAssertEqual(active.load()?.progressionOfferPreparedExerciseIDs, Set([plan.id]))

        viewModel.selectLoad(Load(42.5))
        viewModel.prepareProgressionOffer(opportunity)
        XCTAssertEqual(viewModel.enteredLoadValue, 42.5)
    }

    func testLegacySnapshotWithSavedFirstSetAlsoConsumesProgressionOffer() throws {
        var session = MockWorkoutFactory.upperBodyA()
        let exercise = try XCTUnwrap(session.currentExercise)
        _ = try session.completeCurrentSet(
            load: exercise.plan.targetLoad, reps: 8,
            at: Date(timeIntervalSince1970: 1_000)
        )
        let snapshot = ActiveWorkoutSnapshot(
            session: session, enteredLoadValue: exercise.plan.targetLoad.value,
            enteredReps: 8, enteredRIR: nil, isPaused: false,
            pausedRemainingRestSeconds: nil, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
        let restored = WorkoutViewModel(session: session, restoredSnapshot: snapshot)
        XCTAssertTrue(restored.progressionOfferConsumedExerciseIDs.contains(exercise.plan.id))
        restored.undoLastSet()
        XCTAssertFalse(restored.canShowProgressionOffer(
            for: try XCTUnwrap(restored.session.currentExercise)
        ))
    }

    func testUndoLastSetRestoresLoggedInputsAndRecoverySnapshot() throws {
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle
        )
        viewModel.loadDraft = "12.5"
        viewModel.repsDraft = "10"
        viewModel.enteredRIR = 2
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        viewModel.completeCurrentSet(at: loggedAt)
        XCTAssertTrue(viewModel.canUndoLastSet)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)

        viewModel.undoLastSet()
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(viewModel.loadDraft, "12.5")
        XCTAssertEqual(viewModel.repsDraft, "10")
        XCTAssertEqual(viewModel.enteredRIR, 2)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: loggedAt), 0)
        XCTAssertEqual(viewModel.persistedActivity?.state.phase, .active)
        let recovered = try XCTUnwrap(active.load())
        XCTAssertEqual(recovered.session.completedSetCount, 0)
        XCTAssertEqual(recovered.enteredLoadValue, 12.5)
        XCTAssertEqual(recovered.enteredReps, 10)
        XCTAssertEqual(recovered.enteredRIR, 2)
    }

    func testUndoNoticeAppearsOnlyAfterPersistedUndoAndClearsOnNextSet() throws {
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(viewModel.undoNotice)

        viewModel.undoLastSet()
        XCTAssertEqual(viewModel.undoNotice, "Set 1 removed. Its numbers are back below.")
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_010))
        XCTAssertNil(viewModel.undoNotice)

        active.failSave = true
        viewModel.undoLastSet()
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertNil(viewModel.undoNotice)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
    }

    func testDockRoleFollowsSavedStateThroughLogRestAndNextSet() throws {
        let plan = ExercisePlan(
            name: "Dock test", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 90, previousPerformance: []
        )
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: WorkoutSession(title: "Dock test", exercises: [WorkoutExercise(plan: plan)]),
            onSnapshotChanged: active.handle
        )
        XCTAssertEqual(viewModel.dockRole, .logSet(exerciseIndex: 0, setNumber: 1))
        XCTAssertEqual(viewModel.primaryAction(at: Date(timeIntervalSince1970: 1_000)), .logSet(number: 1))

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.dockRole, .rest(exerciseIndex: 0, nextSetNumber: 2))
        XCTAssertEqual(viewModel.primaryAction(at: Date(timeIntervalSince1970: 1_001)), .rest(
            deadline: Date(timeIntervalSince1970: 1_090), duration: 90
        ))
        // Same-exercise timed rest stays a drained line until the model opens
        // the next set; it never offers a Start that would vanish a tick later.
        let expired = try XCTUnwrap(viewModel.primaryAction(at: Date(timeIntervalSince1970: 1_090)))
        XCTAssertEqual(expired, .rest(deadline: Date(timeIntervalSince1970: 1_090), duration: 90))
        XCTAssertEqual(expired.remainingFraction(at: Date(timeIntervalSince1970: 1_090)), 0)

        XCTAssertTrue(viewModel.advanceElapsedRest(at: Date(timeIntervalSince1970: 1_090)))
        XCTAssertEqual(viewModel.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))
        XCTAssertEqual(viewModel.primaryAction(at: Date(timeIntervalSince1970: 1_090)), .logSet(number: 2))
        XCTAssertEqual(viewModel.session.completedSetCount, 1)

        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(viewModel.dockRole, .retry)
        XCTAssertNil(viewModel.primaryAction(at: Date(timeIntervalSince1970: 1_100)))
    }

    func testElapsedTimedRestOpensNextSetWithoutLoggingIt() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        model.completeCurrentSet(at: loggedAt)
        let savedID = model.session.latestCompletedSetID

        XCTAssertEqual(model.nextExercisePreview?.caption, "After 1 more set")
        XCTAssertFalse(model.nextExercisePreview?.canStart ?? true)
        XCTAssertFalse(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(89)))
        XCTAssertTrue(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(90)))
        XCTAssertEqual(model.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))
        XCTAssertEqual(model.session.completedSetCount, 1)
        XCTAssertEqual(model.session.latestCompletedSetID, savedID)
        XCTAssertNil(active.load()?.session.restEndsAt)
        XCTAssertNil(model.nextExercisePreview)
        XCTAssertFalse(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(91)))
    }

    func testNextExerciseWaitsForHandoffAndUndoReopensFinishedExercise() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        model.completeCurrentSet(at: loggedAt)
        model.skipRest()
        model.completeCurrentSet(at: loggedAt.addingTimeInterval(100))

        XCTAssertEqual(model.session.currentExerciseIndex, 1)
        XCTAssertEqual(model.restingCompletedExercise?.plan.name, "Curl")
        XCTAssertEqual(model.nextExercisePreview?.exercise.plan.name, "Press")
        XCTAssertEqual(model.nextExercisePreview?.caption, "Next exercise")
        XCTAssertTrue(model.nextExercisePreview?.canStart ?? false)
        XCTAssertFalse(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(300)))
        XCTAssertEqual(model.dockRole, .rest(exerciseIndex: 1, nextSetNumber: 1))
        // A new exercise waits for an explicit start and never logs a set.
        XCTAssertEqual(
            model.primaryAction(at: loggedAt.addingTimeInterval(300)),
            .startSet(number: 1, exerciseName: "Press")
        )
        XCTAssertEqual(model.session.completedSetCount, 2)

        model.undoLastSet()
        XCTAssertEqual(model.session.currentExerciseIndex, 0)
        XCTAssertEqual(model.session.completedSetCount, 1)
        XCTAssertNil(model.restingCompletedExercise)
        XCTAssertNil(model.nextExercisePreview)
        XCTAssertEqual(model.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))

        model.completeCurrentSet(at: loggedAt.addingTimeInterval(301))
        model.skipRest()
        XCTAssertNil(model.restingCompletedExercise)
        XCTAssertNil(model.nextExercisePreview)
        XCTAssertEqual(model.dockRole, .logSet(exerciseIndex: 1, setNumber: 1))
        XCTAssertEqual(model.session.completedSetCount, 2)
        XCTAssertEqual(active.load()?.session.completedSetCount, 2)
    }

    func testElapsedRestTransitionSaveFailureRequiresRetryAndNeverDuplicatesSet() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        model.completeCurrentSet(at: loggedAt)
        let savedID = model.session.latestCompletedSetID
        active.failSave = true

        XCTAssertFalse(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(90)))
        XCTAssertEqual(model.dockRole, .retry)
        XCTAssertNotNil(active.load()?.session.restEndsAt)
        XCTAssertFalse(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(91)))
        model.completeCurrentSet(at: loggedAt.addingTimeInterval(92))
        XCTAssertEqual(model.session.completedSetCount, 1)

        active.failSave = false
        model.retryPersistence(at: loggedAt.addingTimeInterval(93))
        XCTAssertEqual(model.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))
        XCTAssertEqual(model.session.latestCompletedSetID, savedID)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertNil(active.load()?.session.restEndsAt)
    }

    func testRecoveredElapsedRestAdvancesSameExerciseButPreservesNewExerciseHandoff() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        model.completeCurrentSet(at: loggedAt)
        var saved = try XCTUnwrap(active.load())
        saved.resolveElapsedRest(at: loggedAt.addingTimeInterval(100))
        XCTAssertTrue(saved.isCompatible)
        let recovered = WorkoutViewModel(
            session: saved.session, restoredSnapshot: saved, onSnapshotChanged: active.handle
        )
        XCTAssertTrue(recovered.advanceElapsedRest(at: loggedAt.addingTimeInterval(100)))
        XCTAssertFalse(recovered.awaitingNextSetAcknowledgement)
        recovered.completeCurrentSet(at: loggedAt.addingTimeInterval(101))

        var handoff = try XCTUnwrap(active.load())
        handoff.resolveElapsedRest(at: loggedAt.addingTimeInterval(300))
        XCTAssertTrue(handoff.isCompatible)
        let reopened = WorkoutViewModel(
            session: handoff.session, restoredSnapshot: handoff, onSnapshotChanged: active.handle
        )
        XCTAssertFalse(reopened.advanceElapsedRest(at: loggedAt.addingTimeInterval(300)))
        XCTAssertEqual(reopened.restingCompletedExercise?.plan.name, "Curl")
        XCTAssertEqual(reopened.nextExercisePreview?.exercise.plan.name, "Press")
        reopened.skipRest()
        XCTAssertEqual(reopened.dockRole, .logSet(exerciseIndex: 1, setNumber: 1))
    }

    func testAutomaticRestAdvanceRespectsPauseAndZeroRestAcknowledgement() {
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let paused = WorkoutViewModel(session: handoffSession())
        paused.completeCurrentSet(at: loggedAt)
        paused.togglePause(at: loggedAt.addingTimeInterval(10))
        XCTAssertFalse(paused.advanceElapsedRest(at: loggedAt.addingTimeInterval(200)))
        paused.togglePause(at: loggedAt.addingTimeInterval(200))
        XCTAssertFalse(paused.advanceElapsedRest(at: loggedAt.addingTimeInterval(279)))
        XCTAssertTrue(paused.advanceElapsedRest(at: loggedAt.addingTimeInterval(280)))

        let zeroRest = WorkoutViewModel(session: handoffSession(restSeconds: 0))
        zeroRest.completeCurrentSet(at: loggedAt)
        XCTAssertFalse(zeroRest.advanceElapsedRest(at: loggedAt.addingTimeInterval(200)))
        XCTAssertTrue(zeroRest.awaitingNextSetAcknowledgement)
        XCTAssertEqual(zeroRest.session.completedSetCount, 1)
    }

    func testPauseAtElapsedRestResumesSameExerciseButKeepsNewExerciseConfirmation() {
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        let model = WorkoutViewModel(session: handoffSession())
        model.completeCurrentSet(at: loggedAt)
        model.togglePause(at: loggedAt.addingTimeInterval(100))
        model.togglePause(at: loggedAt.addingTimeInterval(200))
        XCTAssertEqual(model.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))

        model.completeCurrentSet(at: loggedAt.addingTimeInterval(201))
        model.togglePause(at: loggedAt.addingTimeInterval(400))
        model.togglePause(at: loggedAt.addingTimeInterval(500))
        XCTAssertTrue(model.awaitingNextSetAcknowledgement)
        XCTAssertEqual(model.restingCompletedExercise?.plan.name, "Curl")
        XCTAssertEqual(model.dockRole, .rest(exerciseIndex: 1, nextSetNumber: 1))
    }

    func testSessionRailFillsOnlyPersistedSetsThroughFailureAndRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        func marks(showsCurrent: Bool) -> [WorkoutSetRail.Mark] {
            WorkoutSetRail(
                session: model.session,
                confirmedSetCount: model.persistedActivity?.state.completedSets ?? 0,
                showsCurrent: showsCurrent
            ).segments.map(\.mark)
        }

        XCTAssertEqual(marks(showsCurrent: true), [.current, .open, .open, .open])

        model.completeCurrentSet(at: loggedAt)
        XCTAssertEqual(marks(showsCurrent: false), [.saved, .open, .open, .open])
        XCTAssertTrue(model.advanceElapsedRest(at: loggedAt.addingTimeInterval(90)))
        XCTAssertEqual(marks(showsCurrent: true), [.saved, .current, .open, .open])

        active.failSave = true
        model.completeCurrentSet(at: loggedAt.addingTimeInterval(100))
        XCTAssertEqual(model.session.completedSetCount, 2)
        XCTAssertEqual(model.dockRole, .retry)
        // The held set is in memory but never drawn as saved.
        XCTAssertEqual(marks(showsCurrent: false), [.saved, .open, .open, .open])

        active.failSave = false
        model.retryPersistence(at: loggedAt.addingTimeInterval(101))
        XCTAssertEqual(marks(showsCurrent: false), [.saved, .saved, .open, .open])
        let rail = WorkoutSetRail(session: model.session, confirmedSetCount: 2, showsCurrent: false)
        XCTAssertEqual(rail.savedCount, 2)
        XCTAssertEqual(Set(rail.segments.map(\.id)).count, 4)
    }

    func testDockTransitionFollowsPersistedRolesAcrossSaveHandoffAndUndo() {
        let active = InMemoryActiveWorkoutStore()
        let model = WorkoutViewModel(session: handoffSession(), onSnapshotChanged: active.handle)
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        var role = model.dockRole
        func step(_ change: () -> Void) -> WorkoutDockTransition {
            change()
            defer { role = model.dockRole }
            return WorkoutDockTransition(from: role, to: model.dockRole)
        }

        XCTAssertEqual(step { model.completeCurrentSet(at: loggedAt) }, .save)
        XCTAssertEqual(step { _ = model.advanceElapsedRest(at: loggedAt.addingTimeInterval(90)) }, .restOver)
        XCTAssertEqual(step { model.completeCurrentSet(at: loggedAt.addingTimeInterval(100)) }, .save)
        XCTAssertEqual(step { model.undoLastSet() }, .undo)
        XCTAssertEqual(step { model.completeCurrentSet(at: loggedAt.addingTimeInterval(110)) }, .save)
        XCTAssertEqual(step { model.skipRest() }, .handoff)
        XCTAssertEqual(role, .logSet(exerciseIndex: 1, setNumber: 1))

        active.failSave = true
        XCTAssertEqual(step { model.completeCurrentSet(at: loggedAt.addingTimeInterval(120)) }, .other)
        XCTAssertEqual(role, .retry)
    }

    private func handoffSession(restSeconds: TimeInterval = 90) -> WorkoutSession {
        let curl = ExercisePlan(
            name: "Curl", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: restSeconds, previousPerformance: []
        )
        let press = ExercisePlan(
            name: "Press", targetLoad: Load(20), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: restSeconds, previousPerformance: []
        )
        return WorkoutSession(
            title: "Handoff", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: curl), WorkoutExercise(plan: press)]
        )
    }

    func testHeldSetFailureNamesTheSetUntilItsRetrySucceeds() throws {
        let plan = ExercisePlan(
            name: "Held set", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 90, previousPerformance: []
        )
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: WorkoutSession(title: "Held set", exercises: [WorkoutExercise(plan: plan)]),
            onSnapshotChanged: active.handle
        )
        XCTAssertEqual(viewModel.retryActionTitle, "Retry Save")

        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(viewModel.persistenceFailureTitle, "Set 1 was not saved.")
        XCTAssertEqual(viewModel.retryActionTitle, "Try again: log set 1")
        XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.reps, viewModel.session.exercises[0].completedSets.last?.reps)
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)

        active.failSave = false
        viewModel.retryPersistence(at: Date(timeIntervalSince1970: 1_050))
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(viewModel.persistenceFailureTitle, "Your workout is still here.")
        XCTAssertEqual(viewModel.retryActionTitle, "Retry Save")
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
    }

    func testUndoSaveFailureBlocksFurtherSetsUntilRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(
            session: MockWorkoutFactory.upperBodyA(), onSnapshotChanged: active.handle
        )
        let loggedAt = Date(timeIntervalSince1970: 1_000)
        viewModel.completeCurrentSet(at: loggedAt)
        active.failSave = true

        viewModel.undoLastSet()
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        viewModel.completeCurrentSet(at: loggedAt.addingTimeInterval(1))
        XCTAssertEqual(viewModel.session.completedSetCount, 0)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)
    }

    func testOptionalEffortSnapshotRoundTripsAndVersionOneValueSurvives() throws {
        let session = MockWorkoutFactory.upperBodyA()
        let newSnapshot = ActiveWorkoutSnapshot(
            session: session, enteredLoadValue: 12.5, enteredReps: 10, enteredRIR: nil,
            isPaused: false, pausedRemainingRestSeconds: nil, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
        let legacySnapshot = ActiveWorkoutSnapshot(
            version: 1, session: session, enteredLoadValue: 12.5, enteredReps: 10, enteredRIR: 2,
            isPaused: false, pausedRemainingRestSeconds: nil, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
        for snapshot in [newSnapshot, legacySnapshot] {
            let decoded = try JSONDecoder().decode(
                ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot)
            )
            XCTAssertTrue(decoded.isCompatible)
            XCTAssertEqual(decoded.enteredRIR, snapshot.enteredRIR)
        }

        var rawLegacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacySnapshot)
        ) as? [String: Any])
        rawLegacy.removeValue(forKey: "enteredRIR")
        let missingLegacyRIR = try JSONSerialization.data(withJSONObject: rawLegacy)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ActiveWorkoutSnapshot.self, from: missingLegacyRIR
        ))
    }

    func testEffortNeedsExplicitFirstSelectionAndClearsToNil() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        viewModel.adjustRIR(by: 1)
        viewModel.adjustRIR(by: -1)
        XCTAssertNil(viewModel.enteredRIR)

        viewModel.startTrackingRIR()
        XCTAssertEqual(viewModel.enteredRIR, 2)
        viewModel.adjustRIR(by: -1)
        XCTAssertEqual(viewModel.enteredRIR, 1)
        viewModel.clearRIR()
        XCTAssertNil(viewModel.enteredRIR)
    }

    func testZeroRestRequiresPersistedNextAcknowledgementBeforeAnotherSet() throws {
        let plan = ExercisePlan(
            name: "Zero rest test", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 3, restSeconds: 0, previousPerformance: []
        )
        let session = WorkoutSession(
            title: "Zero rest test", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: plan)]
        )
        let active = InMemoryActiveWorkoutStore()
        let first = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        let firstTap = Date(timeIntervalSince1970: 1_000)

        first.completeCurrentSet(at: firstTap)
        first.completeCurrentSet(at: firstTap.addingTimeInterval(1))
        XCTAssertEqual(first.session.completedSetCount, 1)
        XCTAssertTrue(first.awaitingNextSetAcknowledgement)
        let pending = try XCTUnwrap(active.load())
        XCTAssertTrue(pending.awaitingNextSetAcknowledgement == true)

        let restored = WorkoutViewModel(
            session: pending.session, restoredSnapshot: pending, onSnapshotChanged: active.handle
        )
        restored.completeCurrentSet(at: firstTap.addingTimeInterval(2))
        XCTAssertEqual(restored.session.completedSetCount, 1)
        restored.acknowledgeNextSet()
        XCTAssertFalse(restored.awaitingNextSetAcknowledgement)
        restored.completeCurrentSet(at: firstTap.addingTimeInterval(3))
        XCTAssertEqual(restored.session.completedSetCount, 2)
    }

    func testLegacyZeroRestSnapshotRecoversIntoNextAcknowledgement() throws {
        let plan = ExercisePlan(
            name: "Zero rest test", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 0, previousPerformance: []
        )
        var session = WorkoutSession(
            title: "Zero rest test", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: plan)]
        )
        _ = try session.completeCurrentSet(load: Load(10), reps: 10, at: Date(timeIntervalSince1970: 1_000))
        var snapshot = ActiveWorkoutSnapshot(
            version: 2, session: session, enteredLoadValue: 10, enteredReps: 10,
            enteredRIR: nil, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var legacySession = try XCTUnwrap(legacy["session"] as? [String: Any])
        var legacyExercises = try XCTUnwrap(legacySession["exercises"] as? [[String: Any]])
        var legacySets = try XCTUnwrap(legacyExercises[0]["completedSets"] as? [[String: Any]])
        for index in legacySets.indices { legacySets[index].removeValue(forKey: "restTimerObservation") }
        legacyExercises[0]["completedSets"] = legacySets
        legacySession["exercises"] = legacyExercises
        legacy["session"] = legacySession
        snapshot = try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        snapshot.resolveElapsedRest(at: Date(timeIntervalSince1970: 1_100))
        XCTAssertTrue(snapshot.awaitingNextSetAcknowledgement == true)
        XCTAssertTrue(snapshot.isCompatible)
    }

    func testPauseFreezesAndResumeRestoresCountdown() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        let completionDate = Date(timeIntervalSince1970: 1_000)

        viewModel.completeCurrentSet(at: completionDate)
        viewModel.togglePause(at: completionDate.addingTimeInterval(10))

        XCTAssertTrue(viewModel.isPaused)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: completionDate.addingTimeInterval(500)), 140)

        let resumeDate = completionDate.addingTimeInterval(500)
        viewModel.togglePause(at: resumeDate)

        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: resumeDate), 140)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: resumeDate.addingTimeInterval(100)), 40)
    }

    func testSkipRestWorksWhileWorkoutIsPaused() throws {
        let active = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        let completionDate = Date(timeIntervalSince1970: 1_000)

        viewModel.resolveWarmUp(as: .completed, at: completionDate.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: completionDate)
        viewModel.togglePause(at: completionDate.addingTimeInterval(10))
        viewModel.skipRest()

        XCTAssertEqual(viewModel.remainingRestSeconds(at: completionDate.addingTimeInterval(10)), 0)
        XCTAssertFalse(viewModel.isResting(at: completionDate.addingTimeInterval(10)))
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertNil(viewModel.persistenceErrorMessage)
        let saved = try XCTUnwrap(active.load())
        XCTAssertTrue(saved.isCompatible)
        XCTAssertEqual(saved.pausedRemainingRestSeconds, 0)

        let restored = WorkoutViewModel(session: session, restoredSnapshot: saved, onSnapshotChanged: active.handle)
        XCTAssertTrue(restored.isPaused)
        restored.togglePause(at: completionDate.addingTimeInterval(20))
        XCTAssertFalse(restored.isPaused)
        XCTAssertEqual(restored.remainingRestSeconds(at: completionDate.addingTimeInterval(20)), 0)
        XCTAssertNil(restored.persistenceErrorMessage)
    }

    func testActiveSetAndCurrentInputsRestoreFromLocalSnapshot() throws {
        let store = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session,
            onSnapshotChanged: store.handle
        )
        let completionDate = Date(timeIntervalSince1970: 1_000)

        viewModel.resolveWarmUp(as: .completed, at: completionDate.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: completionDate)
        viewModel.skipRest()
        viewModel.adjustLoad(by: 2.5)
        viewModel.adjustReps(by: -1)
        viewModel.startTrackingRIR()
        viewModel.adjustRIR(by: 1)

        let snapshot = try XCTUnwrap(store.load())
        let restored = WorkoutViewModel(
            session: snapshot.session,
            restoredSnapshot: snapshot,
            onSnapshotChanged: store.handle
        )

        XCTAssertEqual(restored.session.id, session.id)
        XCTAssertEqual(restored.session.completedSetCount, 1)
        XCTAssertEqual(restored.session.currentSetNumber, 2)
        XCTAssertEqual(restored.enteredLoadValue, viewModel.enteredLoadValue)
        XCTAssertEqual(restored.enteredReps, viewModel.enteredReps)
        XCTAssertEqual(restored.enteredRIR, viewModel.enteredRIR)
        XCTAssertEqual(restored.enteredRIR, 3)
    }

    func testPausedWorkoutRestoresWithoutAdvancingCountdown() throws {
        let store = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session,
            onSnapshotChanged: store.handle
        )
        let completionDate = Date(timeIntervalSince1970: 2_000)

        viewModel.resolveWarmUp(as: .skipped, at: completionDate.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: completionDate)
        viewModel.togglePause(at: completionDate.addingTimeInterval(10))
        let frozenSeconds = viewModel.remainingRestSeconds(at: completionDate.addingTimeInterval(10))

        let snapshot = try XCTUnwrap(store.load())
        let restored = WorkoutViewModel(
            session: snapshot.session,
            restoredSnapshot: snapshot,
            onSnapshotChanged: store.handle
        )

        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.remainingRestSeconds(at: completionDate.addingTimeInterval(10)), frozenSeconds)
        XCTAssertEqual(restored.remainingRestSeconds(at: completionDate.addingTimeInterval(10_000)), frozenSeconds)
    }

    func testElapsedRestRestoresAwaitingExplicitNextSet() throws {
        let store = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session,
            onSnapshotChanged: store.handle
        )
        let completionDate = Date(timeIntervalSince1970: 3_000)

        viewModel.resolveWarmUp(as: .completed, at: completionDate.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: completionDate)
        var snapshot = try XCTUnwrap(store.load())
        snapshot.resolveElapsedRest(at: completionDate.addingTimeInterval(1_000))
        let restored = WorkoutViewModel(
            session: snapshot.session,
            restoredSnapshot: snapshot,
            onSnapshotChanged: store.handle
        )

        XCTAssertEqual(restored.session.completedSetCount, 1)
        XCTAssertEqual(restored.session.currentSetNumber, 2)
        XCTAssertFalse(restored.isResting(at: completionDate.addingTimeInterval(1_000)))
        XCTAssertNotNil(restored.session.restEndsAt)
        XCTAssertTrue(restored.awaitingNextSetAcknowledgement)
        XCTAssertNotNil(restored.session.activeRestDuration)

        restored.acknowledgeNextSet()
        XCTAssertFalse(restored.awaitingNextSetAcknowledgement)
        XCTAssertNil(restored.session.restEndsAt)
        XCTAssertNil(restored.session.activeRestDuration)
    }

    func testMinusFifteenPersistsRestAndWaitsForNextSetWhenItReachesZero() throws {
        let store = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: store.handle)
        let loggedAt = Date(timeIntervalSince1970: 5_000)
        viewModel.resolveWarmUp(as: .completed, at: loggedAt.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: loggedAt)

        let almostDone = try XCTUnwrap(viewModel.session.restEndsAt).addingTimeInterval(-5)
        viewModel.shortenRestSeconds(at: almostDone)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: almostDone), 0)
        XCTAssertNotNil(viewModel.session.restEndsAt)
        XCTAssertNotNil(store.load()?.session.restEndsAt)
        XCTAssertEqual(viewModel.session.completedSetCount, 1)

        viewModel.completeCurrentSet(at: almostDone.addingTimeInterval(1))
        XCTAssertEqual(viewModel.session.completedSetCount, 1, "Elapsed rest must not log a set before Start")

        viewModel.skipRest()
        XCTAssertNil(viewModel.session.restEndsAt)
        XCTAssertEqual(store.load()?.session.currentSetNumber, 2)
    }

    /// Study 18: rest that ends within the same exercise opens the next set by itself and never
    /// logs one. A new exercise still waits for confirmation (see
    /// testPauseAtElapsedRestResumesSameExerciseButKeepsNewExerciseConfirmation).
    func testPausingAfterRestExpiresOpensNextSetInSameExerciseWithoutLogging() {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        let loggedAt = Date(timeIntervalSince1970: 6_000)
        viewModel.completeCurrentSet(at: loggedAt)

        viewModel.togglePause(at: loggedAt.addingTimeInterval(200))
        viewModel.togglePause(at: loggedAt.addingTimeInterval(220))
        XCTAssertFalse(viewModel.awaitingNextSetAcknowledgement)
        XCTAssertNil(viewModel.session.restEndsAt)
        XCTAssertEqual(viewModel.session.completedSetCount, 1)
        XCTAssertEqual(viewModel.dockRole, .logSet(exerciseIndex: 0, setNumber: 2))
    }

    func testFullyShortenedRestRemainsAwaitingAfterRelaunch() throws {
        let store = InMemoryActiveWorkoutStore()
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: store.handle)
        let loggedAt = Date(timeIntervalSince1970: 7_000)
        viewModel.resolveWarmUp(as: .completed, at: loggedAt.addingTimeInterval(-1))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: loggedAt)
        viewModel.shortenRestSeconds(1_000, at: loggedAt)

        var snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.session.activeRestDuration, 0)
        snapshot.resolveElapsedRest(at: loggedAt.addingTimeInterval(1))
        XCTAssertTrue(snapshot.awaitingNextSetAcknowledgement == true)
        XCTAssertNotNil(snapshot.session.restEndsAt)
    }

    func testCompletionClearsSnapshotAndRecordsHistoryOnce() {
        let snapshotStore = InMemoryActiveWorkoutStore()
        let history = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        let viewModel = WorkoutViewModel(
            session: singleSetSession(),
            onSnapshotChanged: snapshotStore.handle,
            onSessionCompleted: history.record
        )

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))

        XCTAssertNil(snapshotStore.load())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.id, viewModel.session.id)
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(viewModel.lastCompletionRecordResult, .inserted)
    }

    func testEarlyFinishSavesOnlyLoggedSetsOnceAndZeroSetExitSavesNothing() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session, onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        XCTAssertFalse(viewModel.finishEarly(at: Date(timeIntervalSince1970: 900)))
        XCTAssertEqual(history.entries.count, 0)
        XCTAssertTrue(viewModel.clearSnapshotForExit())
        XCTAssertNil(active.load())

        let resumed = WorkoutViewModel(
            session: session, onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        resumed.resolveWarmUp(as: .completed, at: Date(timeIntervalSince1970: 950))
        resumed.loadDraft = "10"
        resumed.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        resumed.skipRest()
        resumed.completeCurrentSet(at: Date(timeIntervalSince1970: 1_100))
        XCTAssertTrue(resumed.finishEarly(at: Date(timeIntervalSince1970: 1_200)))
        XCTAssertTrue(resumed.finishEarly(at: Date(timeIntervalSince1970: 1_300)))
        resumed.retryPersistence()

        XCTAssertTrue(resumed.session.endedEarly)
        XCTAssertEqual(resumed.session.completedSetCount, 2)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].id, session.id)
        XCTAssertEqual(history.entries[0].exercises?.flatMap(\.completedSets).count, 2)
        XCTAssertTrue(WorkoutHistoryDisplayItem(entry: history.entries[0]).endedEarly)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNil(active.load())
    }

    func testEarlyFinishFromZeroRestAcknowledgementSavesOnce() throws {
        let plan = ExercisePlan(
            name: "Zero rest test", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 3, restSeconds: 0, previousPerformance: []
        )
        let session = WorkoutSession(
            title: "Zero rest test", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: plan)]
        )
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: session, onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(viewModel.awaitingNextSetAcknowledgement)
        XCTAssertTrue(viewModel.finishEarly(at: Date(timeIntervalSince1970: 1_001)))
        viewModel.retryPersistence()

        XCTAssertFalse(viewModel.awaitingNextSetAcknowledgement)
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].exercises?.flatMap(\.completedSets).count, 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNil(active.load())
    }

    func testFailedSetSaveBlocksAnotherSetAndRestAdvanceUntilRetry() throws {
        for restSeconds in [0, 90] {
            let plan = ExercisePlan(
                name: "Save retry test", targetLoad: Load(10), targetReps: RepRange(8, 10),
                plannedSetCount: 2, restSeconds: TimeInterval(restSeconds), previousPerformance: []
            )
            let session = WorkoutSession(title: "Save retry test", exercises: [WorkoutExercise(plan: plan)])
            let active = InMemoryActiveWorkoutStore()
            let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
            let savedBeforeSet = active.load()
            XCTAssertEqual(viewModel.persistedActivity?.state.completedSets, 0)
            active.failSave = true

            viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
            XCTAssertEqual(viewModel.session.completedSetCount, 1)
            XCTAssertNotNil(viewModel.persistenceErrorMessage)
            XCTAssertEqual(viewModel.unconfirmedWorkingSet?.exerciseName, "Save retry test")
            XCTAssertEqual(viewModel.unconfirmedWorkingSet?.number, 1)
            XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.load.value, 10)
            XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.reps, 8)
            XCTAssertEqual(active.load(), savedBeforeSet)
            XCTAssertEqual(viewModel.persistedActivity?.state.completedSets, 0)
            XCTAssertFalse(viewModel.finishEarly(at: Date(timeIntervalSince1970: 1_050)))
            XCTAssertFalse(viewModel.session.isComplete)

            viewModel.togglePause(at: Date(timeIntervalSince1970: 1_050))
            XCTAssertFalse(viewModel.isPaused)
            viewModel.proposeThirtyMinuteAdaptation()
            XCTAssertNil(viewModel.pendingAdaptation)

            viewModel.skipRest()
            viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_100))
            XCTAssertEqual(viewModel.session.completedSetCount, 1)
            XCTAssertEqual(viewModel.session.currentSetNumber, 2)
            if restSeconds == 0 {
                XCTAssertTrue(viewModel.awaitingNextSetAcknowledgement)
            }

            active.failSave = false
            let retriedAt = Date(timeIntervalSince1970: 1_200)
            viewModel.retryPersistence(at: retriedAt)
            XCTAssertNil(viewModel.persistenceErrorMessage)
            XCTAssertNil(viewModel.unconfirmedWorkingSet)
            XCTAssertEqual(active.load()?.session.completedSetCount, 1)
            XCTAssertEqual(viewModel.persistedActivity?.state.completedSets, 1)
            if restSeconds > 0 {
                XCTAssertEqual(viewModel.remainingRestSeconds(at: retriedAt), restSeconds)
            }

            viewModel.skipRest()
            XCTAssertNil(viewModel.persistenceErrorMessage)
            XCTAssertFalse(viewModel.awaitingNextSetAcknowledgement)
        }
    }

    func testCompletingWorkingSetPublishesOneCoherentSnapshot() throws {
        let plan = ExercisePlan(
            name: "Snapshot transition", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 90, previousPerformance: []
        )
        let session = WorkoutSession(title: "Snapshot transition", exercises: [WorkoutExercise(plan: plan)])
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        let writesBeforeSet = active.saveCount

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(active.saveCount - writesBeforeSet, 1)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertEqual(active.load()?.enteredLoadValue, viewModel.enteredLoadValue)
        XCTAssertEqual(active.load()?.enteredReps, viewModel.enteredReps)
        XCTAssertNil(viewModel.persistenceErrorMessage)
    }

    func testDraftObservationCannotSilentlyAcknowledgeFailedSetSave() throws {
        let plan = ExercisePlan(
            name: "Interrupted set", targetLoad: Load(10), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 90, previousPerformance: []
        )
        let session = WorkoutSession(title: "Interrupted set", exercises: [WorkoutExercise(plan: plan)])
        let active = InMemoryActiveWorkoutStore()
        let viewModel = WorkoutViewModel(session: session, onSnapshotChanged: active.handle)
        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)

        active.failSave = false
        viewModel.enteredReps = 9
        _ = viewModel.commitDrafts()
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)
        XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.reps, 8)

        let retriedAt = Date(timeIntervalSince1970: 1_200)
        viewModel.retryPersistence(at: retriedAt)
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertEqual(viewModel.remainingRestSeconds(at: retriedAt), 90)
    }

    func testFailedEarlyFinishSaveRetainsRecoverySnapshotForRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        store.failSave = true
        let history = WorkoutHistoryRepository(store: store)
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session, onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.resolveWarmUp(as: .skipped, at: Date(timeIntervalSince1970: 950))
        viewModel.loadDraft = "10"
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(viewModel.finishEarly(at: Date(timeIntervalSince1970: 1_100)))
        XCTAssertFalse(viewModel.isCompletionSaved)
        XCTAssertNotNil(active.load())
        XCTAssertTrue(history.entries.isEmpty)

        store.failSave = false
        viewModel.retryPersistence()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(active.load())
    }

    func testFailedSetSaveCannotBeDiscardedAndCanFinishAfterRetry() throws {
        let active = InMemoryActiveWorkoutStore()
        let history = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        let viewModel = WorkoutViewModel(
            session: session, onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.resolveWarmUp(as: .skipped, at: Date(timeIntervalSince1970: 950))
        viewModel.loadDraft = "10"

        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertFalse(viewModel.clearSnapshotForExit())
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)

        active.failSave = false
        viewModel.retryPersistence(at: Date(timeIntervalSince1970: 1_100))
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertFalse(viewModel.clearSnapshotForExit())
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)

        XCTAssertTrue(viewModel.finishEarly(at: Date(timeIntervalSince1970: 1_200)))
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.completedSetCount, 1)
        XCTAssertNil(active.load())
    }

    func testUnfinishedExitClearsSnapshotWithoutChangingHistoryOrToday() throws {
        let snapshotStore = InMemoryActiveWorkoutStore()
        let history = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        let session = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession())
        _ = WorkoutViewModel(
            session: session,
            onSnapshotChanged: snapshotStore.handle,
            onSessionCompleted: history.record
        )

        XCTAssertNotNil(snapshotStore.load())
        try snapshotStore.clear(expectedSessionID: session.id)

        XCTAssertNil(snapshotStore.load())
        XCTAssertEqual(history.surfaceState, .empty)
        XCTAssertEqual(TodayWorkoutStateDeriver().state(for: session, history: history), .ready)
    }

    func testCorruptSnapshotFailsSafelyWithoutHistoryMutation() throws {
        let suiteName = "WorkoutSnapshotTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "test.activeWorkout"
        defaults.set(Data("not-json".utf8), forKey: key)
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: key)
        let history = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.data(forKey: key), Data("not-json".utf8))
        XCTAssertEqual(history.surfaceState, .empty)
    }

    func testCompletionPersistsActualAdaptedSessionToLocalHistory() {
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let source = singleSetSession()
        let viewModel = WorkoutViewModel(
            session: source,
            onSessionCompleted: history.record
        )

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(viewModel.session.isComplete)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.title, "Upper Body A · 30 min")
        XCTAssertEqual(history.entries.first?.programmeID, .upperBodyA)
        XCTAssertEqual(history.entries.first?.completedSetCount, 1)
        XCTAssertEqual(history.entries.first?.targetDurationMinutes, 30)
        XCTAssertEqual(history.entries.first?.wasAdapted, true)
        XCTAssertEqual(store.savedEntries, history.entries)
    }

    func testHistoryIsDuplicateSafeAndRestoresDisplayModel() throws {
        let store = InMemoryWorkoutHistoryStore()
        let firstRepository = WorkoutHistoryRepository(store: store)
        let completionDate = Date(timeIntervalSince1970: 4_000)
        var session = singleSetSession()
        _ = try session.completeCurrentSet(
            load: session.exercises[0].plan.targetLoad,
            reps: 8,
            at: completionDate
        )

        try firstRepository.record(session)
        try firstRepository.record(session)

        XCTAssertEqual(firstRepository.entries.count, 1)

        let restoredRepository = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(restoredRepository.entries.count, 1)
        XCTAssertEqual(
            restoredRepository.surfaceState,
            .entries([
                WorkoutHistoryDisplayItem(entry: try XCTUnwrap(restoredRepository.entries.first))
            ])
        )
    }

    func testTodayDerivesCompletedStateFromPersistedLocalRecord() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 10_000)
        let store = InMemoryWorkoutHistoryStore()
        let firstRepository = WorkoutHistoryRepository(store: store)
        var completedSession = singleSetSession()
        _ = try completedSession.completeCurrentSet(
            load: completedSession.exercises[0].plan.targetLoad,
            reps: 8,
            at: now
        )
        try firstRepository.record(completedSession)

        let restoredRepository = WorkoutHistoryRepository(store: store)
        let newReadySession = MockWorkoutFactory.upperBodyA()
        let state = TodayWorkoutStateDeriver(calendar: calendar).state(
            for: newReadySession,
            history: restoredRepository,
            now: now
        )

        guard case let .completed(item) = state else {
            return XCTFail("Expected persisted completion to drive Today.")
        }
        XCTAssertEqual(item.id, completedSession.id)
        XCTAssertEqual(item.completedSetCount, 1)
        XCTAssertTrue(item.wasAdapted)
    }

    func testTodayKeepsActiveSessionResumableAfterEarlierSameDayCompletion() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let repository = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        var earlier = singleSetSession()
        _ = try earlier.completeCurrentSet(
            load: earlier.exercises[0].plan.targetLoad,
            reps: 8,
            at: now
        )
        try repository.record(earlier)

        let active = MockWorkoutFactory.upperBodyA()
        XCTAssertEqual(
            TodayWorkoutStateDeriver(calendar: Calendar(identifier: .gregorian)).state(
                for: active,
                history: repository,
                activeSession: true,
                now: now
            ),
            .ready
        )
    }

    func testUnfinishedExitDoesNotAffectHistoryOrToday() {
        let repository = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        let unfinishedSession = MockWorkoutFactory.upperBodyA()

        XCTAssertThrowsError(try repository.record(unfinishedSession))

        XCTAssertEqual(repository.surfaceState, .empty)
        XCTAssertEqual(
            TodayWorkoutStateDeriver().state(for: unfinishedSession, history: repository),
            .ready
        )
    }

    func testUnavailableHistoryProducesIntentionalUnavailableStates() {
        let repository = WorkoutHistoryRepository(store: UnavailableWorkoutHistoryStore())

        XCTAssertEqual(repository.surfaceState, .unavailable)
        XCTAssertEqual(
            TodayWorkoutStateDeriver().state(for: MockWorkoutFactory.upperBodyA(), history: repository),
            .unavailable
        )
    }

    func testHistoryRoundTripPreservesEveryRecordedPerformanceField() throws {
        let session = try performanceSession()
        let entry = WorkoutHistoryEntry(session: session)
        let decoded = try JSONDecoder().decode(
            WorkoutHistoryEntry.self, from: JSONEncoder().encode(entry)
        )

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.completedAt, session.completedAt)
        XCTAssertEqual(decoded.exercises?.map(\.id), session.exercises.map(\.id))
        XCTAssertEqual(decoded.exercises?.map(\.exerciseID), session.exercises.map(\.plan.exerciseID))
        XCTAssertEqual(decoded.exercises?.map(\.completedSets), session.exercises.map(\.completedSets))
        XCTAssertNil(decoded.exercises?[0].completedSets[0].rir)
        XCTAssertEqual(decoded.exercises?[0].completedSets[1].rir, 0)
        XCTAssertEqual(decoded.exercises?[1].completedSets[0].load.unit, .pounds)
        XCTAssertEqual(decoded.exercises?[1].completedSets[0].load.value, 42.125)

        let displayItem = WorkoutHistoryDisplayItem(entry: decoded)
        XCTAssertEqual(displayItem.plannedSetCount, session.totalPlannedSetCount)
        XCTAssertEqual(displayItem.targetDurationMinutes, session.targetDurationMinutes)
        XCTAssertEqual(displayItem.exercises, decoded.exercises)
    }

    func testLegacySummariesRemainUnknownAndSurviveFileMigration() throws {
        let suiteName = "HistoryMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [[
            "id": legacyID.uuidString,
            "title": "Original summary",
            "completedAt": 1234.125,
            "completedSetCount": 9,
            "plannedSetCount": 12,
            "wasAdapted": true
        ]])
        defaults.set(data, forKey: "history")
        let legacy = UserDefaultsWorkoutHistoryStore(defaults: defaults, key: "history")
        let store = FileWorkoutHistoryStore(directory: directory, legacyStore: legacy)
        let original = try XCTUnwrap(store.load().first)
        XCTAssertEqual(original.id, legacyID)
        XCTAssertEqual(original.completedAt, Date(timeIntervalSinceReferenceDate: 1234.125))
        XCTAssertNil(original.programmeID)
        XCTAssertNil(original.targetDurationMinutes)
        XCTAssertNil(original.exercises)

        let repository = WorkoutHistoryRepository(store: store)
        try repository.record(performanceSession())
        let migrated = try store.load()
        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(migrated.first(where: { $0.id == legacyID }), original)
        XCTAssertEqual(defaults.data(forKey: "history"), data)
        XCTAssertEqual(try FileWorkoutHistoryStore(directory: directory, legacyStore: legacy).load(), migrated)
    }

    func testRepeatedCompletionAndRelaunchDoNotRepeatRecordOrEffects() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 8_000))
        viewModel.retryPersistence()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(viewModel.completionFeedbackCount, 1)
        // Reading the flag does not consume it; the summary's first render
        // uses it to decide whether the rail may travel.
        XCTAssertTrue(viewModel.hasPendingCompletionPresentation)
        XCTAssertTrue(viewModel.hasPendingCompletionPresentation)
        XCTAssertTrue(viewModel.consumeCompletionPresentation())
        XCTAssertFalse(viewModel.hasPendingCompletionPresentation)
        XCTAssertFalse(viewModel.consumeCompletionPresentation())

        let relaunched = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try relaunched.record(viewModel.session), .alreadyRecorded)
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testFinalSetReviewCanUndoBeforeHistoryAndFinishExactlyOnce() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), requiresFinalSetReview: true,
            onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        XCTAssertTrue(viewModel.session.isComplete)
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
        XCTAssertTrue(viewModel.canUndoFinalSet)
        XCTAssertFalse(viewModel.isCompletionSaved)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(active.load()?.awaitingFinalSetConfirmation, true)
        XCTAssertEqual(viewModel.persistedActivity?.state.phase, .readyToFinish)

        viewModel.undoFinalSet()
        XCTAssertFalse(viewModel.session.isComplete)
        XCTAssertEqual(viewModel.session.completedSetCount, 0)
        XCTAssertEqual(viewModel.enteredLoadValue, 80)
        XCTAssertEqual(viewModel.enteredReps, 8)
        XCTAssertFalse(viewModel.awaitingFinalSetConfirmation)
        XCTAssertEqual(active.load()?.session.completedSetCount, 0)
        XCTAssertTrue(history.entries.isEmpty)

        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_100))
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
        XCTAssertTrue(viewModel.canUndoFinalSet)
        viewModel.confirmFinalSetAndFinish()
        viewModel.confirmFinalSetAndFinish()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertNil(active.load())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].completedSetCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testFinalSetReviewRestoresWithoutAutomaticallyWritingHistory() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), requiresFinalSetReview: true,
            onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        let saved = try XCTUnwrap(active.load())
        let restored = WorkoutViewModel(
            session: saved.session, restoredSnapshot: saved, requiresFinalSetReview: true,
            onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        XCTAssertTrue(restored.awaitingFinalSetConfirmation)
        XCTAssertTrue(restored.canUndoFinalSet)
        XCTAssertTrue(history.entries.isEmpty)
        restored.confirmFinalSetAndFinish()
        XCTAssertTrue(restored.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testFinalSetReviewWaitsForSnapshotRetryBeforeUndoOrFinish() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), requiresFinalSetReview: true,
            onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        let before = active.load()
        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        XCTAssertTrue(viewModel.awaitingFinalSetConfirmation)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.load.value, 80)
        XCTAssertEqual(viewModel.unconfirmedWorkingSet?.set.reps, 8)
        XCTAssertFalse(viewModel.canUndoFinalSet)
        XCTAssertEqual(active.load(), before)
        XCTAssertTrue(history.entries.isEmpty)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertNil(viewModel.persistenceErrorMessage)
        XCTAssertTrue(viewModel.canUndoFinalSet)
        XCTAssertEqual(active.load()?.session.completedSetCount, 1)
        XCTAssertTrue(history.entries.isEmpty)
        viewModel.confirmFinalSetAndFinish()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testFailedHistorySaveRetainsFinalSetAndCanRetryAfterRelaunch() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        store.failSave = true
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000.25))
        let pending = try XCTUnwrap(active.load())
        XCTAssertTrue(pending.isCompatible)
        XCTAssertEqual(pending.session, viewModel.session)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(viewModel.isCompletionSaved)
        XCTAssertFalse(viewModel.clearSnapshotForExit())
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        XCTAssertEqual(viewModel.completionFeedbackCount, 0)
        XCTAssertEqual(TodayWorkoutStateDeriver().state(for: viewModel.session, history: history), .ready)

        store.failSave = false
        let relaunchedHistory = WorkoutHistoryRepository(store: store)
        let restored = WorkoutViewModel(
            session: pending.session, restoredSnapshot: pending,
            onSnapshotChanged: active.handle, onSessionCompleted: relaunchedHistory.record
        )
        XCTAssertTrue(restored.isCompletionSaved)
        XCTAssertNil(active.load())
        XCTAssertNil(restored.persistenceErrorMessage)
        XCTAssertEqual(relaunchedHistory.entries, [WorkoutHistoryEntry(session: pending.session)])
    }

    func testRecoveryAfterHistorySaveBeforeSnapshotCleanupDoesNotDuplicate() throws {
        let active = InMemoryActiveWorkoutStore()
        active.failClear = true
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        let pending = try XCTUnwrap(active.load())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertFalse(viewModel.isCompletionSaved)
        XCTAssertNil(viewModel.lastCompletionRecordResult)
        XCTAssertEqual(viewModel.completionFeedbackCount, 0)
        XCTAssertFalse(viewModel.clearSnapshotForExit())

        active.failClear = false
        let relaunchedHistory = WorkoutHistoryRepository(store: store)
        let restored = WorkoutViewModel(
            session: pending.session, restoredSnapshot: pending,
            onSnapshotChanged: active.handle, onSessionCompleted: relaunchedHistory.record
        )
        restored.retryPersistence()
        XCTAssertTrue(restored.isCompletionSaved)
        XCTAssertEqual(restored.lastCompletionRecordResult, .alreadyRecorded)
        XCTAssertNil(active.load())
        XCTAssertEqual(relaunchedHistory.entries.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(restored.completionFeedbackCount, 0)
        XCTAssertFalse(restored.consumeCompletionPresentation())
    }

    func testCompletedSnapshotFailureDoesNotWriteHistoryOrClearPriorRecovery() throws {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        let priorSnapshot = active.load()
        active.failSave = true
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        XCTAssertEqual(active.load(), priorSnapshot)
        XCTAssertTrue(viewModel.session.isComplete)
        XCTAssertEqual(viewModel.session.completedSetCount, 1)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)

        active.failSave = false
        viewModel.retryPersistence()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertNil(active.load())
        XCTAssertEqual(history.entries.first?.exercises?.first?.completedSets, viewModel.session.exercises.first?.completedSets)
    }

    func testAmbiguousHistoryWriteAcknowledgementIsReconciledOnRetry() {
        let active = InMemoryActiveWorkoutStore()
        let store = InMemoryWorkoutHistoryStore()
        store.failAfterSave = true
        let history = WorkoutHistoryRepository(store: store)
        let viewModel = WorkoutViewModel(
            session: singleSetSession(), onSnapshotChanged: active.handle, onSessionCompleted: history.record
        )
        viewModel.completeCurrentSet(at: Date(timeIntervalSince1970: 4_000))
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(store.savedEntries.count, 1)
        XCTAssertNotNil(active.load())
        store.failAfterSave = false
        viewModel.retryPersistence()
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(viewModel.completionFeedbackCount, 0)
    }

    func testCompletedSnapshotAndCleanupSurviveRealFileStoreRelaunch() throws {
        let suiteName = "SnapshotMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "active")
        let session = singleSetSession()
        let original = snapshot(for: session)
        try legacy.save(original)
        let originalBytes = defaults.data(forKey: "active")
        let store = FileActiveWorkoutStore(directory: directory, legacyStore: legacy)
        XCTAssertEqual(try store.load(), original)
        var completedSession = session
        _ = try completedSession.completeCurrentSet(load: Load(42.125), reps: 8, rir: nil, at: .now)
        let completed = snapshot(for: completedSession)
        try store.save(completed)
        let relaunched = FileActiveWorkoutStore(directory: directory, legacyStore: legacy)
        XCTAssertEqual(try relaunched.load(), completed)
        try relaunched.clear(expectedSessionID: session.id)
        XCTAssertNil(try FileActiveWorkoutStore(directory: directory, legacyStore: legacy).load())
        XCTAssertEqual(defaults.data(forKey: "active"), originalBytes)
    }

    func testFileHistoryFailureLeavesExistingBytesAndRepositoryUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWorkoutHistoryStore(directory: directory, legacyStore: InMemoryWorkoutHistoryStore())
        let history = WorkoutHistoryRepository(store: store)
        try history.record(performanceSession())
        let originalEntries = history.entries
        let url = directory.appendingPathComponent("history.json")
        let bytes = try Data(contentsOf: url)
        // A corrupted recovered set can still reach storage; encoding must fail
        // without replacing the previously verified History file.
        let plan = singleSetSession().exercises[0].plan
        let invalid = WorkoutSession(
            title: "Corrupted recovery", programmeID: .upperBodyA,
            exercises: [WorkoutExercise(plan: plan, completedSets: [
                CompletedSet(load: Load(.infinity), reps: 8, completedAt: .now)
            ])],
            completedAt: .now
        )
        XCTAssertThrowsError(try history.record(invalid))
        XCTAssertEqual(history.entries, originalEntries)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnreadableFileStoresRefuseToOverwriteRecoveryData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data("not-json".utf8)
        let historyURL = directory.appendingPathComponent("history.json")
        let activeURL = directory.appendingPathComponent("active-workout.json")
        try bytes.write(to: historyURL)
        try bytes.write(to: activeURL)
        let history = FileWorkoutHistoryStore(directory: directory)
        let active = FileActiveWorkoutStore(directory: directory)
        XCTAssertThrowsError(try history.load())
        XCTAssertThrowsError(try history.save([]))
        XCTAssertThrowsError(try active.load())
        XCTAssertThrowsError(try active.save(snapshot(for: singleSetSession())))
        XCTAssertThrowsError(try active.clear(expectedSessionID: UUID()))
        XCTAssertEqual(try Data(contentsOf: historyURL), bytes)
        XCTAssertEqual(try Data(contentsOf: activeURL), bytes)
    }

    func testDiskInterruptionBetweenHistoryAndCleanupReconcilesExactPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = FileActiveWorkoutStore(directory: directory, legacyStore: InMemoryActiveWorkoutStore())
        let historyStore = FileWorkoutHistoryStore(directory: directory, legacyStore: InMemoryWorkoutHistoryStore())
        let session = try performanceSession()
        try active.save(snapshot(for: session))
        try WorkoutHistoryRepository(store: historyStore).record(session)
        // Simulate termination here, before clearing the completed recovery snapshot.
        let historyBytes = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        let restoredHistory = WorkoutHistoryRepository(store: historyStore)
        let pending = try XCTUnwrap(active.load())
        let viewModel = WorkoutViewModel(
            session: pending.session, restoredSnapshot: pending,
            onSnapshotChanged: { snapshot, sessionID in
                if let snapshot { try active.save(snapshot) } else { try active.clear(expectedSessionID: sessionID) }
            },
            onSessionCompleted: restoredHistory.record
        )
        XCTAssertTrue(viewModel.isCompletionSaved)
        XCTAssertEqual(restoredHistory.entries, [WorkoutHistoryEntry(session: session)])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("history.json")), historyBytes)
        XCTAssertNil(try active.load())
        XCTAssertEqual(viewModel.completionFeedbackCount, 0)
        XCTAssertFalse(viewModel.consumeCompletionPresentation())
    }

    func testCompletionCallbacksAreOrderedAndFailedLaunchesKeepPendingData() throws {
        var events: [String] = []
        let active = InMemoryActiveWorkoutStore()
        let history = WorkoutHistoryRepository(store: InMemoryWorkoutHistoryStore())
        let session = try performanceSession()
        let pending = snapshot(for: session)
        try active.save(pending)
        for _ in 0..<3 {
            let restored = WorkoutViewModel(
                session: session, restoredSnapshot: pending,
                onSnapshotChanged: { value, sessionID in
                    events.append(value == nil ? "cleanup" : "snapshot")
                    try active.handle(value, sessionID)
                },
                onSessionCompleted: { _ in
                    events.append("history failed")
                    throw WorkoutPersistenceError.unavailable
                }
            )
            XCTAssertFalse(restored.isCompletionSaved)
            XCTAssertEqual(active.load(), pending)
        }
        XCTAssertEqual(events, Array(repeating: ["snapshot", "history failed"], count: 3).flatMap { $0 })
        events = []
        _ = WorkoutViewModel(
            session: session, restoredSnapshot: pending,
            onSnapshotChanged: { value, sessionID in
                events.append(value == nil ? "cleanup" : "snapshot")
                try active.handle(value, sessionID)
            },
            onSessionCompleted: { session in
                let result = try history.record(session)
                events.append("history acknowledged")
                return result
            }
        )
        XCTAssertEqual(events, ["snapshot", "history acknowledged", "cleanup"])
    }

    func testExistingEmptyFileIsAuthoritativeOverLegacyHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = InMemoryWorkoutHistoryStore()
        try legacy.save([WorkoutHistoryEntry(session: performanceSession())])
        let file = FileWorkoutHistoryStore(directory: directory, legacyStore: legacy)
        try file.save([])
        XCTAssertTrue(try file.load().isEmpty)
        XCTAssertEqual(legacy.savedEntries.count, 1)
    }

    func testRetryDoesNotReorderOlderHistoryAndEqualDatesAreStable() throws {
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        var older = singleSetSession()
        var newer = singleSetSession()
        var sameDate = singleSetSession()
        _ = try older.completeCurrentSet(load: Load(1), reps: 8, at: Date(timeIntervalSince1970: 100))
        _ = try newer.completeCurrentSet(load: Load(2), reps: 8, at: Date(timeIntervalSince1970: 200))
        _ = try sameDate.completeCurrentSet(load: Load(3), reps: 8, at: Date(timeIntervalSince1970: 200))
        try history.record(newer)
        try history.record(older)
        try history.record(sameDate)
        let order = history.entries.map(\.id)
        XCTAssertEqual(order.last, older.id)
        XCTAssertEqual(Array(order.prefix(2)), [newer.id, sameDate.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(try history.record(older), .alreadyRecorded)
        XCTAssertEqual(history.entries.map(\.id), order)
        XCTAssertEqual(WorkoutHistoryRepository(store: store).entries.map(\.id), order)
        XCTAssertEqual(store.saveCount, 3)
    }

    func testConflictingCompletionCannotOverwriteExistingRecordedValues() throws {
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        let session = try performanceSession()
        try history.record(session)
        let conflicting = WorkoutSession(
            id: session.id, title: "Changed title", programmeID: session.programmeID,
            exercises: session.exercises, completedAt: session.completedAt
        )
        XCTAssertThrowsError(try history.record(conflicting))
        XCTAssertEqual(history.entries, [WorkoutHistoryEntry(session: session)])
        XCTAssertEqual(store.saveCount, 1)
    }

    func testDifferentSessionCannotOverwriteOrClearPendingRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = FileActiveWorkoutStore(directory: directory, legacyStore: InMemoryActiveWorkoutStore())
        let pending = snapshot(for: try performanceSession())
        try active.save(pending)
        let url = directory.appendingPathComponent("active-workout.json")
        let bytes = try Data(contentsOf: url)
        let other = snapshot(for: singleSetSession())
        XCTAssertThrowsError(try active.save(other))
        XCTAssertThrowsError(try active.clear(expectedSessionID: other.session.id))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try active.load(), pending)
    }

    func testLegacyDuplicateRequiresMatchingRecordedSummary() throws {
        let session = try performanceSession()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkoutHistoryEntry(session: session))
        ) as? [String: Any])
        json.removeValue(forKey: "exercises")
        let legacy = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let store = InMemoryWorkoutHistoryStore()
        try store.save([legacy])
        let history = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(try history.record(session), .alreadyRecorded)
        XCTAssertNil(history.entries.first?.exercises)
        XCTAssertEqual(store.saveCount, 1)

        json["completedSetCount"] = 999
        let conflicting = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        try store.save([conflicting])
        XCTAssertThrowsError(try history.record(session))
        XCTAssertEqual(store.savedEntries, [conflicting])
        XCTAssertEqual(store.saveCount, 2)
    }

    private func snapshot(for session: WorkoutSession) -> ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(
            session: session, enteredLoadValue: 42.125, enteredReps: 8, enteredRIR: 2,
            isPaused: false, pausedRemainingRestSeconds: nil, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
    }

    func testPreviousPerformancePreservesRepeatedOccurrencesAndEveryRecordedField() throws {
        let session = try performanceSession()
        let store = InMemoryWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: store)
        try history.record(session)
        let before = store.savedEntries
        let result = history.previousPerformance(for: session.exercises[0].plan.exerciseID, excluding: UUID())
        guard case let .recorded(recorded) = result else { return XCTFail("Expected recorded performance") }
        XCTAssertEqual(recorded.sessionID, session.id)
        XCTAssertEqual(recorded.completedAt, session.completedAt)
        XCTAssertEqual(recorded.occurrences, before[0].exercises)
        XCTAssertEqual(recorded.occurrences.count, 2)
        XCTAssertEqual(recorded.occurrences[0].completedSets[0].load, Load(0))
        XCTAssertNil(recorded.occurrences[0].completedSets[0].rir)
        XCTAssertEqual(recorded.occurrences[1].completedSets[0].load, Load(42.125, unit: .pounds))
        XCTAssertEqual(recorded.latestSavedSet?.load, Load(42.125, unit: .pounds))
        XCTAssertEqual(recorded.latestSavedSet?.reps, 11)
        XCTAssertEqual(history.previousPerformance(for: session.exercises[0].plan.exerciseID), result)
        XCTAssertEqual(store.savedEntries, before)
        XCTAssertEqual(store.saveCount, 1, "Lookup must not write history")
    }

    func testPreviousPerformanceUsesStableExerciseIDAcrossChangedNamesAndProgramme() throws {
        let session = try performanceSession()
        let store = InMemoryWorkoutHistoryStore()
        try store.save([WorkoutHistoryEntry(session: session)])
        let translatedPlan = ExercisePlan(
            exerciseID: session.exercises[0].plan.exerciseID, name: "Translated name",
            targetLoad: Load(900), targetReps: RepRange(1, 2), plannedSetCount: 1,
            restSeconds: 0, previousPerformance: []
        )
        let history = WorkoutHistoryRepository(store: store)
        guard case let .recorded(recorded) = history.previousPerformance(
            for: translatedPlan.exerciseID, excluding: UUID()
        ) else { return XCTFail("Identity should match without a title or programme match") }
        XCTAssertEqual(recorded.sessionID, session.id)
        XCTAssertEqual(recorded.occurrences, session.exercises.map(WorkoutHistoryExercise.init))
    }

    func testPreviousPerformanceExcludesCurrentSessionAndSkipsUnrelatedNewerHistory() throws {
        let old = try performanceSession()
        let current = WorkoutSession(
            title: "Current pending save", programmeID: .zeroOneBuild, exercises: old.exercises,
            completedAt: Date(timeIntervalSince1970: 8_000)
        )
        let otherPlan = ExercisePlan(
            exerciseID: ExerciseID(exerciseName: "Unrelated"), name: "Unrelated",
            targetLoad: Load(1), targetReps: RepRange(1, 1), plannedSetCount: 1,
            restSeconds: 0, previousPerformance: []
        )
        let unrelated = WorkoutSession(
            title: "Newer unrelated", exercises: [WorkoutExercise(plan: otherPlan)],
            completedAt: Date(timeIntervalSince1970: 9_000)
        )
        let store = InMemoryWorkoutHistoryStore()
        try store.save([old, current, unrelated].map(WorkoutHistoryEntry.init))
        let history = WorkoutHistoryRepository(store: store)
        guard case let .recorded(recorded) = history.previousPerformance(
            for: old.exercises[0].plan.exerciseID, excluding: current.id
        ) else { return XCTFail("Expected earlier matching history") }
        XCTAssertEqual(recorded.sessionID, old.id)
        XCTAssertFalse(recorded.hasNewerUnknownDetails,
                       "A detailed workout without this exercise is not missing historical detail")
    }

    func testPreviousPerformanceUsesDeterministicTieBreakRegardlessOfStoredOrder() throws {
        let first = try performanceSession()
        let second = WorkoutSession(
            title: "Same completion date", programmeID: .zeroOneBuild,
            exercises: first.exercises, completedAt: first.completedAt
        )
        let entries = [first, second].map(WorkoutHistoryEntry.init)
        let store = InMemoryWorkoutHistoryStore()
        try store.save(Array(entries.reversed()))
        let history = WorkoutHistoryRepository(store: store)
        guard case let .recorded(recorded) = history.previousPerformance(
            for: first.exercises[0].plan.exerciseID, excluding: UUID()
        ) else { return XCTFail("Expected recorded performance") }
        XCTAssertEqual(recorded.sessionID, entries.sorted(by: WorkoutHistoryEntry.newestFirst)[0].id)
    }

    func testPreviousPerformanceDistinguishesMissingLegacyDetailsFromEmptyHistory() throws {
        let session = try performanceSession()
        let entry = WorkoutHistoryEntry(session: session)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "exercises")
        let legacy = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let store = InMemoryWorkoutHistoryStore()
        let emptyHistory = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(emptyHistory.previousPerformance(for: session.exercises[0].plan.exerciseID, excluding: UUID()),
                       .noRecordedSets(hasUnknownDetails: false))
        try store.save([legacy])
        let legacyHistory = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(legacyHistory.previousPerformance(for: session.exercises[0].plan.exerciseID, excluding: UUID()),
                       .noRecordedSets(hasUnknownDetails: true))
        XCTAssertNil(store.savedEntries[0].exercises)
    }

    func testPreviousPerformanceDisclosesNewerUnknownDetailsWithoutFabricatingSets() throws {
        let old = try performanceSession()
        let newer = WorkoutSession(
            title: "Legacy", programmeID: .zeroOneBuild, exercises: old.exercises,
            completedAt: Date(timeIntervalSince1970: 9_000)
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkoutHistoryEntry(session: newer))
        ) as? [String: Any])
        json.removeValue(forKey: "exercises")
        let legacy = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let store = InMemoryWorkoutHistoryStore()
        try store.save([legacy, WorkoutHistoryEntry(session: old)])
        let history = WorkoutHistoryRepository(store: store)
        guard case let .recorded(recorded) = history.previousPerformance(
            for: old.exercises[0].plan.exerciseID, excluding: UUID()
        ) else { return XCTFail("Expected older recorded details") }
        XCTAssertEqual(recorded.sessionID, old.id)
        XCTAssertTrue(recorded.hasNewerUnknownDetails)
    }

    func testPreviousPerformanceDoesNotUseEmptyOccurrencesOrUnavailableHistoryAsZero() throws {
        let session = singleSetSession()
        let empty = WorkoutSession(title: "No logged sets", exercises: session.exercises, completedAt: .now)
        let store = InMemoryWorkoutHistoryStore()
        try store.save([WorkoutHistoryEntry(session: empty)])
        let history = WorkoutHistoryRepository(store: store)
        XCTAssertEqual(history.previousPerformance(for: session.exercises[0].plan.exerciseID, excluding: UUID()),
                       .noRecordedSets(hasUnknownDetails: false))
        let unavailable = WorkoutHistoryRepository(store: UnavailableWorkoutHistoryStore())
        XCTAssertEqual(unavailable.previousPerformance(for: session.exercises[0].plan.exerciseID, excluding: UUID()), .unavailable)
    }

    func testWorkoutTargetCueDoesNotClaimProgressFromMockPreviousSets() throws {
        let viewModel = WorkoutViewModel(session: MockWorkoutFactory.upperBodyA())
        let exercise = try XCTUnwrap(viewModel.session.currentExercise)
        let before = viewModel.session
        let cue = viewModel.progressionRecommendation(for: exercise)
        XCTAssertTrue(cue.hasPrefix("Suggested:"))
        XCTAssertFalse(cue.contains("today"))
        XCTAssertEqual(viewModel.session, before)
    }

    func testMissingRecordedLoadCannotDecodeAsInventedZero() throws {
        let original = CompletedSet(load: Load(0, unit: .pounds), reps: 8, rir: nil, completedAt: .now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any])
        json.removeValue(forKey: "load")
        XCTAssertThrowsError(try JSONDecoder().decode(
            CompletedSet.self, from: JSONSerialization.data(withJSONObject: json)
        ))
        let restored = try JSONDecoder().decode(CompletedSet.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.load, Load(0, unit: .pounds))
        XCTAssertNil(restored.rir)
    }

    private func performanceSession() throws -> WorkoutSession {
        // A bodyweight set can legitimately record zero external load. Repeat
        // that exercise identity with a weighted occurrence in another unit.
        let first = ExercisePlan(
            exerciseID: ExerciseIDs.pushUp, name: "Push-Up", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 0,
            previousPerformance: []
        )
        let plans = [Load(0), Load(42.125, unit: .pounds)].map { load in
            ExercisePlan(
                exerciseID: first.exerciseID, name: first.name, targetLoad: load,
                targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 0,
                previousPerformance: []
            )
        }
        var session = WorkoutSession(
            title: "Recorded values", programmeID: .zeroOneBuild,
            exercises: plans.map { WorkoutExercise(plan: $0) }
        )
        let efforts: [Int?] = [nil, 0, 5, 2]
        for index in 0..<4 {
            let load = try XCTUnwrap(session.currentExercise?.plan.targetLoad)
            _ = try session.completeCurrentSet(
                load: load, reps: 8 + index, rir: efforts[index],
                at: Date(timeIntervalSince1970: 4_000.125 + Double(index) * 10.25)
            )
        }
        return session
    }

    private func singleSetSession() -> WorkoutSession {
        WorkoutSession(
            title: "Upper Body A · 30 min",
            programmeID: .upperBodyA,
            targetDurationMinutes: 30,
            isAdapted: true,
            exercises: [
                WorkoutExercise(
                    plan: ExercisePlan(
                        name: "Barbell Bench Press",
                        targetLoad: Load(80),
                        targetReps: RepRange(8, 8),
                        plannedSetCount: 1,
                        restSeconds: 90,
                        previousPerformance: []
                    )
                )
            ]
        )
    }
}

private final class InMemoryWorkoutHistoryStore: WorkoutHistoryPersisting {
    private(set) var savedEntries: [WorkoutHistoryEntry] = []
    private(set) var saveCount = 0
    var failSave = false
    var failAfterSave = false

    func load() -> [WorkoutHistoryEntry] {
        savedEntries
    }

    func save(_ entries: [WorkoutHistoryEntry]) throws {
        if failSave { throw WorkoutPersistenceError.unavailable }
        savedEntries = entries
        saveCount += 1
        if failAfterSave { throw WorkoutPersistenceError.verificationFailed }
    }
}

private final class InMemoryActiveWorkoutStore: ActiveWorkoutPersisting {
    private var snapshot: ActiveWorkoutSnapshot?
    var failSave = false
    var failClear = false
    private(set) var saveCount = 0

    func load() -> ActiveWorkoutSnapshot? {
        snapshot
    }

    func save(_ snapshot: ActiveWorkoutSnapshot) throws {
        if failSave { throw WorkoutPersistenceError.unavailable }
        self.snapshot = snapshot
        saveCount += 1
    }

    func clear(expectedSessionID: UUID) throws {
        if failClear { throw WorkoutPersistenceError.unavailable }
        if let snapshot, snapshot.session.id != expectedSessionID {
            throw WorkoutPersistenceError.conflictingSession
        }
        snapshot = nil
    }

    func handle(_ snapshot: ActiveWorkoutSnapshot?, _ sessionID: UUID) throws {
        if let snapshot {
            try save(snapshot)
        } else {
            try clear(expectedSessionID: sessionID)
        }
    }
}

private struct UnavailableWorkoutHistoryStore: WorkoutHistoryPersisting {
    var isAvailable: Bool { false }

    func load() -> [WorkoutHistoryEntry] { [] }
    func save(_ entries: [WorkoutHistoryEntry]) {}
}

// These existing persistence/Undo regressions now state actual selection facts.
@MainActor
private func confirmedTestSwap(_ model: WorkoutViewModel, with id: ExerciseID, load: Load) throws -> Bool {
    let now = Date.now
    var profile = ZeroOneUserProfile()
    profile.availableEquipment = [.dumbbells]
    profile.trainingConstraint = .some(.none)
    profile.trainingExperience = .startingOut
    let assessment = WellbeingAssessment(recommendations: [], recordedTrainingDays: 0, reviewedNutritionDays: 0,
        hasCurrentRecoveryReport: false, hasConflictingSleep: false, evaluatedAt: now,
        timeZoneID: Calendar.current.timeZone.identifier)
    let context = ExerciseSubstitutionContext(profile: profile, assessment: assessment)
    let review = try ExerciseSubstitutionSelector().review(session: model.session, input: model.substitutionInput,
        context: context, availableVideoIDs: MoveKitExercise.availableVideoIDs, at: now)
    return try model.substituteCurrentExercise(with: id, load: load, review: review, context: context, confirmedAt: now, at: now)
}
