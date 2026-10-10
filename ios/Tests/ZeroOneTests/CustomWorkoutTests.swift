import XCTest
import UIKit
@testable import ZeroOne

final class CustomWorkoutTests: XCTestCase {
    @MainActor
    func testPickerPosterDownsamplesBundledJPEGAndHandlesMissingResource() async throws {
        let store = CustomWorkoutPosterStore.shared
        let loaded = await store.image(for: "abdominals-stretch-variation-one", maxPixel: 144)
        let first = try XCTUnwrap(loaded)
        let pixels = try XCTUnwrap(first.cgImage)
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 144)

        let cached = await store.image(for: "abdominals-stretch-variation-one", maxPixel: 144)
        let second = try XCTUnwrap(cached)
        let repeatedPixels = try XCTUnwrap(second.cgImage)
        XCTAssertLessThanOrEqual(max(repeatedPixels.width, repeatedPixels.height), 144)
        let missing = await store.image(for: "not-a-bundled-poster", maxPixel: 144)
        XCTAssertNil(missing)
    }

    @MainActor
    func testEveryLicensedExerciseCanStartACustomSession() throws {
        XCTAssertEqual(MoveKitExercise.all.count, 412)
        for exercise in MoveKitExercise.all {
            let workout = CustomWorkout(
                name: "My session",
                items: [CustomWorkoutItem(videoID: exercise.id)]
            )
            let session = try XCTUnwrap(workout.makeSession(), exercise.id)
            XCTAssertEqual(session.exercises.count, 1)
            XCTAssertEqual(session.customWorkoutID, workout.id)
            XCTAssertNil(session.programmeID)
            XCTAssertTrue(session.requiresWarmUp)
            XCTAssertEqual(
                MoveKitExerciseCatalog.match(for: session.exercises[0].plan.exerciseID)?.exercise.id,
                exercise.id
            )
        }
    }

    @MainActor
    func testCustomSessionWarmUpLengthCanBeSelectedBeforeStarting() throws {
        let workout = CustomWorkout(name: "Arms", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl")
        ])

        var full = try XCTUnwrap(workout.makeSession())
        full.selectWarmUpLength(.full, at: .now)
        XCTAssertEqual(full.warmUp?.length, .full)
        XCTAssertEqual(full.warmUp?.steps.count, 3)
        XCTAssertTrue(full.requiresWarmUp)

        var short = try XCTUnwrap(workout.makeSession())
        short.selectWarmUpLength(.short, at: .now)
        XCTAssertEqual(short.warmUp?.length, .short)
        XCTAssertEqual(short.warmUp?.steps.count, 2)
        XCTAssertTrue(short.requiresWarmUp)

        var none = try XCTUnwrap(workout.makeSession())
        none.selectWarmUpLength(.none, at: .now)
        XCTAssertEqual(none.warmUp?.length, WorkoutWarmUpLength.none)
        XCTAssertEqual(none.warmUp?.status, .skipped)
        XCTAssertFalse(none.requiresWarmUp)
    }

    @MainActor
    func testCustomSessionSnapshotRoundTripsAndIsRecoverable() throws {
        let workout = CustomWorkout(name: "Arms", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl", sets: 4, reps: 8, restSeconds: 90, targetLoad: 12),
            CustomWorkoutItem(videoID: "band-high-face-pull", sets: 3, reps: 12, restSeconds: 60)
        ])
        let session = try XCTUnwrap(workout.makeSession())
        XCTAssertEqual(session.exercises.map(\.plan.targetReps.upperBound), [8, 12])
        let snapshot = ActiveWorkoutSnapshot(
            session: session, enteredLoadValue: 12, enteredReps: 8, enteredRIR: nil,
            isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil
        )
        XCTAssertTrue(snapshot.isCompatible)
        let restored = try JSONDecoder().decode(
            ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(restored.session.customWorkoutID, workout.id)
        XCTAssertTrue(restored.isCompatible)
    }

    func testOlderProgrammeSessionDecodesWithoutCustomWorkoutID() throws {
        let original = MockWorkoutFactory.upperBodyA()
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        payload.removeValue(forKey: "customWorkoutID")
        let restored = try JSONDecoder().decode(
            WorkoutSession.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(restored.programmeID, original.programmeID)
        XCTAssertNil(restored.customWorkoutID)
    }

    @MainActor
    func testLicensedCustomExerciseContributesItsRecordedSetsToWeeklyMap() throws {
        let workout = CustomWorkout(name: "Curl session", items: [
            CustomWorkoutItem(videoID: "dumbbell-concentration-curl")
        ])
        let plan = try XCTUnwrap(workout.makeSession()?.exercises.first?.plan)
        XCTAssertTrue(plan.exerciseID.rawValue.hasPrefix("MOV-"))
        let now = Date()
        let completed = WorkoutSession(
            title: workout.name, customWorkoutID: workout.id,
            exercises: [WorkoutExercise(plan: plan, completedSets: [
                CompletedSet(load: Load(12), reps: 10, completedAt: now)
            ])],
            completedAt: now
        )
        let week = WorkoutMuscleWeek(
            entries: [WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: completed))],
            now: now, calendar: .current
        )
        XCTAssertEqual(week.regions.first(where: { $0.region == .biceps })?.directSets, 1)
        XCTAssertEqual(week.setsWithoutMuscleMapping, 0)
    }

    @MainActor
    func testSavedCustomSessionsSurviveRepositoryRecreation() throws {
        let suite = "custom-workout-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCustomWorkoutStore(defaults: defaults)
        let repository = CustomWorkoutRepository(store: store)
        let workout = CustomWorkout(name: "Leg day", items: [
            CustomWorkoutItem(videoID: "barbell-squat", sets: 4, reps: 6)
        ])
        XCTAssertTrue(repository.save(workout))
        let reloaded = CustomWorkoutRepository(store: store)
        XCTAssertEqual(reloaded.workouts.map(\.id), [workout.id])
        XCTAssertEqual(reloaded.workouts[0].items[0].videoID, "barbell-squat")
    }

    @MainActor
    func testGeneratedPlanSavesBothSessionsTogetherAndPreservesExistingCustomWork() throws {
        let suite = "custom-workout-plan-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCustomWorkoutStore(defaults: defaults)
        let repository = CustomWorkoutRepository(store: store)
        let existing = CustomWorkout(name: "My original session", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl")
        ])
        XCTAssertTrue(repository.save(existing))

        let first = CustomWorkout(name: "Full Body A", items: [
            CustomWorkoutItem(videoID: "bodyweight-squat")
        ])
        let second = CustomWorkout(name: "Full Body B", items: [
            CustomWorkoutItem(videoID: "push-up")
        ])
        XCTAssertTrue(repository.saveTogether([first, second]))
        XCTAssertEqual(Set(CustomWorkoutRepository(store: store).workouts.map(\.id)),
                       Set([existing.id, first.id, second.id]))

        let invalid = CustomWorkout(name: "Missing movement", items: [
            CustomWorkoutItem(videoID: "not-in-library")
        ])
        XCTAssertFalse(repository.saveTogether([first, invalid]))
        XCTAssertEqual(Set(CustomWorkoutRepository(store: store).workouts.map(\.id)),
                       Set([existing.id, first.id, second.id]))
    }

    @MainActor
    func testCorruptCustomSessionStoreIsNeverOverwritten() throws {
        let suite = "custom-workout-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "custom-workout-corrupt"
        let original = Data("unreadable".utf8)
        defaults.set(original, forKey: key)
        let repository = CustomWorkoutRepository(
            store: UserDefaultsCustomWorkoutStore(defaults: defaults, key: key)
        )
        XCTAssertFalse(repository.isAvailable)
        XCTAssertFalse(repository.save(CustomWorkout(name: "No overwrite", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl")
        ])))
        XCTAssertEqual(defaults.data(forKey: key), original)
    }

    @MainActor
    func testUnfinishedBuilderDraftSurvivesRelaunchWithoutChangingSavedWorkout() throws {
        let suite = "custom-builder-draft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = CustomWorkoutRepository(
            store: UserDefaultsCustomWorkoutStore(defaults: defaults),
            draftStore: UserDefaultsCustomWorkoutDraftStore(defaults: defaults)
        )
        let saved = CustomWorkout(name: "Push day", items: [CustomWorkoutItem(videoID: "barbell-bench-press")])
        XCTAssertTrue(repository.save(saved))
        var edited = saved
        edited.name = "Push day revised"
        edited.warmUpLength = .short
        edited.items.append(CustomWorkoutItem(videoID: "dumbbell-curl"))
        XCTAssertTrue(repository.keepDraft(edited))

        let relaunched = CustomWorkoutRepository(
            store: UserDefaultsCustomWorkoutStore(defaults: defaults),
            draftStore: UserDefaultsCustomWorkoutDraftStore(defaults: defaults)
        )
        XCTAssertEqual(relaunched.workouts.first?.name, "Push day")
        XCTAssertEqual(relaunched.workouts.first?.items.count, 1)
        XCTAssertEqual(relaunched.draft?.workout, edited)
        XCTAssertTrue(relaunched.discardDraft())
        XCTAssertNil(try UserDefaultsCustomWorkoutDraftStore(defaults: defaults).load())
    }

    func testOldSavedWorkoutDecodesWithoutWarmUpChoice() throws {
        let original = CustomWorkout(name: "Legs", items: [CustomWorkoutItem(videoID: "barbell-squat")])
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        payload.removeValue(forKey: "warmUpLength")
        let restored = try JSONDecoder().decode(
            CustomWorkout.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertNil(restored.warmUpLength)
        XCTAssertEqual(restored.items, original.items)
    }

    func testBuilderValidationChecksDuplicateNameAndOptionalLoad() {
        let saved = CustomWorkout(name: "Push Day", items: [CustomWorkoutItem(videoID: "barbell-bench-press")])
        let another = CustomWorkout(name: " push day ", items: saved.items)
        XCTAssertNotNil(CustomWorkoutBuilderValidation.nameError(for: another, among: [saved]))
        XCTAssertNil(CustomWorkoutBuilderValidation.nameError(for: saved, among: [saved]))
        XCTAssertNil(CustomWorkoutBuilderValidation.loadError(for: CustomWorkoutItem(videoID: "push-up")))
        XCTAssertNotNil(CustomWorkoutBuilderValidation.loadError(for: CustomWorkoutItem(videoID: "push-up", targetLoad: -1)))
        XCTAssertNotNil(CustomWorkoutBuilderValidation.loadError(for: CustomWorkoutItem(videoID: "push-up", targetLoad: 1.1)))
        XCTAssertNil(CustomWorkoutBuilderValidation.loadError(for: CustomWorkoutItem(videoID: "push-up", targetLoad: 1.25)))
        XCTAssertNotNil(CustomWorkoutBuilderValidation.exercisesError(for: CustomWorkout(name: "Empty")))
        XCTAssertNil(CustomWorkoutBuilderValidation.exercisesError(for: saved))
    }
}

extension CustomWorkoutTests {
    @MainActor
    func testCustomTimedTargetAndPerSideChoiceSurviveRoundTripAndSessionCreation() throws {
        let clip = try XCTUnwrap(MoveKitExercise.all.first)
        let item = CustomWorkoutItem(videoID: clip.id, sets: 2, reps: 10,
                                     durationSeconds: 30, perSide: true)
        let workout = CustomWorkout(name: "Timed practice", items: [item])
        let decoded = try JSONDecoder().decode(CustomWorkout.self, from: JSONEncoder().encode(workout))
        XCTAssertEqual(decoded, workout)
        let session = try XCTUnwrap(decoded.makeSession())
        let plan = session.exercises[0].plan
        XCTAssertTrue(plan.isTimed)
        XCTAssertEqual(plan.prescriptionDisplayText, "30 sec per side")
        XCTAssertTrue(plan.allowsZeroLoad)
        XCTAssertTrue(session.exercises[0].completedSets.isEmpty)
        let adapted = try DeterministicWorkoutAdapter().proposal(for: session).adaptedSession
        XCTAssertEqual(adapted.exercises[0].plan.targetPrescription, plan.targetPrescription)
    }

    @MainActor
    func testOldCustomWorkoutKeepsRepTargetAndUnknownDurationAfterDecoding() throws {
        let clip = try XCTUnwrap(MoveKitExercise.all.first)
        let item = CustomWorkoutItem(videoID: clip.id, sets: 3, reps: 12)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "durationSeconds")
        object.removeValue(forKey: "perSide")
        object.removeValue(forKey: "authoredExerciseID")
        let decoded = try JSONDecoder().decode(CustomWorkoutItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, item)
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertNil(decoded.authoredExerciseID)
        XCTAssertEqual(decoded.resolvedExerciseID, MoveKitExerciseCatalog.workoutExerciseID(for: clip.id))
        let session = try XCTUnwrap(CustomWorkout(name: "Legacy reps", items: [decoded]).makeSession())
        XCTAssertFalse(session.exercises[0].plan.isTimed)
        XCTAssertEqual(session.exercises[0].plan.targetReps, RepRange(12, 12))
    }

    func testCustomTimedTargetsRejectNonpositiveAndUnboundedDuration() {
        for seconds in [0, -1, 86_401] {
            let item = CustomWorkoutItem(videoID: "not-required-for-structural-check", durationSeconds: seconds)
            XCTAssertFalse(item.isStructurallyValid)
        }
    }
}
extension CustomWorkoutTests {
    private func copyProgramme(plans: [ExercisePlan]) throws -> WorkoutProgramme {
        let base = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps))
        return WorkoutProgramme(id: base.id, title: base.title, summary: base.summary,
            durationMinutes: base.durationMinutes, equipmentContext: base.equipmentContext,
            experienceBand: base.experienceBand, goalSupport: base.goalSupport,
            schedule: base.schedule, durationWeeks: base.durationWeeks, rules: base.rules,
            evidenceReferenceKeys: base.evidenceReferenceKeys,
            sessions: [WorkoutProgrammeSession(id: "copy-test", title: "Copy source", exercisePlans: plans)])
    }

    @MainActor
    func testBicepsProgrammeCreatesACompleteEditableCopyWithoutChangingItsSource() throws {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps))
        let preview = programme.makeSession()
        let original = preview
        let copy = try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: preview, warmUpLength: .short)
        XCTAssertEqual(preview, original)
        XCTAssertNotEqual(copy.id, preview.id)
        XCTAssertEqual(copy.items.count, programme.exercisePlans.count)
        XCTAssertEqual(copy.warmUpLength, .short)
        let copiedSession = try XCTUnwrap(copy.makeSession())
        XCTAssertNil(copiedSession.programmeID)
        XCTAssertEqual(copiedSession.customWorkoutID, copy.id)
        XCTAssertEqual(copiedSession.exercises.map { $0.plan.exerciseID }, programme.exercisePlans.map(\.exerciseID))
        XCTAssertTrue(copiedSession.exercises.allSatisfy { $0.completedSets.isEmpty && $0.plan.previousPerformance.isEmpty })
        for (copied, authored) in zip(copiedSession.exercises.map(\.plan), programme.exercisePlans) {
            XCTAssertEqual(copied.prescription, authored.prescription)
            XCTAssertEqual(copied.plannedSetCount, authored.plannedSetCount)
            XCTAssertEqual(copied.restSeconds, authored.restSeconds)
            XCTAssertEqual(copied.targetLoad, authored.targetLoad)
        }
    }

    @MainActor
    func testCopyPreservesDuplicateOrderRangesSideAndUnitsWithoutBorrowingPreviewPerformance() throws {
        let repPlan = ExercisePlan(exerciseID: "EX-DUMBBELL-CURL", name: "Dumbbell Curl", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 75, previousPerformance: [],
            targetPrescription: WorkingSetPrescription(unit: .repetitions, lowerBound: 8, upperBound: 12, perSide: true))
        let timedPlan = ExercisePlan(exerciseID: "EX-INCLINE-WALK", name: "Incline Treadmill Walk", targetLoad: Load(0),
            targetReps: RepRange(1, 1), plannedSetCount: 1, restSeconds: 0, previousPerformance: [],
            targetPrescription: WorkingSetPrescription(unit: .seconds, lowerBound: 600, upperBound: 1_200, perSide: false))
        let programme = try copyProgramme(plans: [repPlan, timedPlan, repPlan])
        let previewPlans = programme.exercisePlans.map { plan in
            ExercisePlan(exerciseID: plan.exerciseID, name: plan.name, targetLoad: Load(41.5, unit: .pounds),
                targetReps: plan.targetReps, plannedSetCount: plan.plannedSetCount, restSeconds: plan.restSeconds,
                previousPerformance: [PreviousSetPerformance(load: Load(88, unit: .pounds), reps: 12)],
                targetPrescription: plan.targetPrescription)
        }
        let preview = WorkoutSession(title: "Copy source", programmeID: programme.id,
                                     exercises: previewPlans.map { WorkoutExercise(plan: $0) })
        let copy = try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: preview, warmUpLength: .none)
        XCTAssertEqual(copy.items.map(\.videoID), ["dumbbell-curl", "incline-treadmill-walk", "dumbbell-curl"])
        XCTAssertEqual(Set(copy.items.map(\.id)).count, 3)
        XCTAssertEqual(copy.items.map(\.targetLoad), [0, 0, 0])
        XCTAssertEqual(copy.items.map(\.loadUnit), [.pounds, .pounds, .pounds])
        XCTAssertEqual(copy.items[0].repUpperBound, 12)
        XCTAssertEqual(copy.items[1].durationUpperBound, 1_200)
        XCTAssertEqual(copy.items[0].perSide, true)
        let decoded = try JSONDecoder().decode(CustomWorkout.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(decoded, copy)
        let session = try XCTUnwrap(decoded.makeSession())
        XCTAssertEqual(session.exercises.map { $0.plan.prescription }, programme.exercisePlans.map(\.prescription))
        XCTAssertEqual(session.exercises[0].plan.targetReps, RepRange(8, 12))
        XCTAssertTrue(session.exercises.allSatisfy { $0.completedSets.isEmpty && $0.plan.previousPerformance.isEmpty })
    }

    @MainActor
    func testCopyRejectsUnknownDefinitionsInsteadOfMakingAPartialSession() throws {
        let exact = ExercisePlan(exerciseID: "EX-DUMBBELL-CURL", name: "Dumbbell Curl", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 75, previousPerformance: [])
        for missing in ["EX-UNKNOWN-AUTHORED", "MOV-not-in-catalog"] {
            let unmapped = ExercisePlan(exerciseID: ExerciseID(rawValue: missing), name: "Unmapped movement",
                targetLoad: Load(0), targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 60,
                previousPerformance: [])
            let programme = try copyProgramme(plans: [exact, unmapped])
            XCTAssertThrowsError(try ProgrammeSessionCustomization.makeCopy(programme: programme,
                previewSession: programme.makeSession(), warmUpLength: .full)) {
                XCTAssertEqual($0 as? ProgrammeSessionCustomizationError, .unavailableExercise("Unmapped movement"))
            }
        }
    }

    @MainActor
    func testCopyRejectsUnrepresentableRestAndAMismatchedPreviewWithoutRoundingOrSubstituting() throws {
        let fractionalRest = ExercisePlan(exerciseID: "EX-DUMBBELL-CURL", name: "Dumbbell Curl", targetLoad: Load(0),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 75.5, previousPerformance: [])
        let programme = try copyProgramme(plans: [fractionalRest])
        XCTAssertThrowsError(try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: programme.makeSession(), warmUpLength: .full)) {
            XCTAssertEqual($0 as? ProgrammeSessionCustomizationError, .unsupportedPrescription("Dumbbell Curl"))
        }
        let wrongPreview = WorkoutSession(title: "Another session", programmeID: programme.id,
                                         exercises: [WorkoutExercise(plan: fractionalRest)])
        XCTAssertThrowsError(try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: wrongPreview, warmUpLength: .full)) {
            XCTAssertEqual($0 as? ProgrammeSessionCustomizationError, .unavailableSession)
        }
    }

    func testCustomRangesRejectReversedOrOrphanDurationBounds() {
        XCTAssertFalse(CustomWorkoutItem(videoID: "dumbbell-curl", reps: 10, repUpperBound: 8).isStructurallyValid)
        XCTAssertFalse(CustomWorkoutItem(videoID: "dumbbell-curl", reps: 10, repUpperBound: 51).isStructurallyValid)
        XCTAssertFalse(CustomWorkoutItem(videoID: "dumbbell-curl", durationUpperBound: 45).isStructurallyValid)
        XCTAssertFalse(CustomWorkoutItem(videoID: "dumbbell-curl", durationSeconds: 30, durationUpperBound: 20).isStructurallyValid)
    }

    @MainActor
    func testCopyRejectsNonzeroLoadUnitMismatchAndAlreadyLoggedWork() throws {
        let authored = ExercisePlan(exerciseID: "EX-DUMBBELL-CURL", name: "Dumbbell Curl", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 75, previousPerformance: [])
        let programme = try copyProgramme(plans: [authored])
        let differentlyMeasured = ExercisePlan(exerciseID: authored.exerciseID, name: authored.name,
            targetLoad: Load(22, unit: .pounds), targetReps: authored.targetReps,
            plannedSetCount: authored.plannedSetCount, restSeconds: authored.restSeconds, previousPerformance: [])
        let preview = WorkoutSession(title: "Copy source", programmeID: programme.id,
            exercises: [WorkoutExercise(plan: differentlyMeasured)])
        XCTAssertThrowsError(try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: preview, warmUpLength: .full)) {
            XCTAssertEqual($0 as? ProgrammeSessionCustomizationError, .unsupportedPrescription("Dumbbell Curl"))
        }
        var logged = WorkoutSession(title: "Copy source", programmeID: programme.id,
            exercises: [WorkoutExercise(plan: authored)])
        _ = try logged.completeCurrentSet(load: Load(10), reps: 8, at: Date(timeIntervalSince1970: 1_000))
        XCTAssertThrowsError(try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: logged, warmUpLength: .full)) {
            XCTAssertEqual($0 as? ProgrammeSessionCustomizationError, .unavailableSession)
        }
    }

    @MainActor
    func testEveryAuthoredProgrammeSessionCopiesWithoutRequiringExactMedia() throws {
        XCTAssertFalse(WorkoutProgrammeLibrary.all.isEmpty)
        for programme in WorkoutProgrammeLibrary.all {
            for authored in programme.sessions {
                let preview = programme.makeSession(sessionID: authored.id)
                let copy = try ProgrammeSessionCustomization.makeCopy(programme: programme,
                    previewSession: preview, warmUpLength: .full)
                XCTAssertEqual(copy.items.map(\.authoredExerciseID), authored.exercisePlans.map { Optional($0.exerciseID) })
                XCTAssertNil(CustomWorkoutBuilderValidation.exercisesError(for: copy))
                let restored = try JSONDecoder().decode(CustomWorkout.self, from: JSONEncoder().encode(copy))
                XCTAssertEqual(restored, copy)
                let session = try XCTUnwrap(restored.makeSession())
                XCTAssertEqual(session.exercises.map { $0.plan.exerciseID }, authored.exercisePlans.map(\.exerciseID))
                for (copied, original) in zip(session.exercises.map(\.plan), authored.exercisePlans) {
                    let definition = try XCTUnwrap(ExerciseLibrary.exercise(id: original.exerciseID))
                    XCTAssertEqual(copied.name, definition.name)
                    XCTAssertEqual(copied.prescription, original.prescription)
                    XCTAssertEqual(copied.plannedSetCount, original.plannedSetCount)
                    XCTAssertEqual(copied.restSeconds, original.restSeconds)
                    XCTAssertEqual(copied.equipmentIdentifiers, definition.equipmentIdentifiers)
                    XCTAssertEqual(copied.coachingCue, definition.shortCoachingCue)
                    XCTAssertEqual(copied.painGuardrail, definition.painGuardrail)
                    XCTAssertTrue(copied.previousPerformance.isEmpty)
                }
                XCTAssertTrue(session.exercises.allSatisfy { $0.completedSets.isEmpty })
            }
        }
    }

    @MainActor
    func testAuthoredIdentityControlsNameMetadataAndMediaWithoutVariantSubstitution() throws {
        for id in [ExerciseIDs.gobletSquat, ExerciseIDs.plank, ExerciseIDs.deadBug] {
            // An unrelated stored video must not become this exercise's identity or poster.
            let item = CustomWorkoutItem(videoID: "dumbbell-curl", authoredExerciseID: id)
            let definition = try XCTUnwrap(ExerciseLibrary.exercise(id: id))
            XCTAssertTrue(item.isValid)
            XCTAssertEqual(item.displayName, definition.name)
            XCTAssertEqual(item.resolvedExerciseID, id)
            XCTAssertNil(item.mediaExercise)
            let session = try XCTUnwrap(CustomWorkout(name: "Authored copy", items: [item]).makeSession())
            XCTAssertEqual(session.exercises[0].plan.exerciseID, id)
            XCTAssertEqual(session.exercises[0].plan.equipmentIdentifiers, definition.equipmentIdentifiers)
        }
        let unknown = CustomWorkoutItem(videoID: "dumbbell-curl", authoredExerciseID: "EX-UNKNOWN-AUTHORED")
        XCTAssertTrue(unknown.isStructurallyValid)
        XCTAssertFalse(unknown.isValid)
        XCTAssertNil(unknown.resolvedExerciseID)
        XCTAssertNil(unknown.mediaExercise)
        XCTAssertEqual(unknown.displayName, "Unavailable exercise")
        XCTAssertNil(CustomWorkout(name: "Unknown copy", items: [unknown]).makeSession())
    }

    @MainActor
    func testReplacingAuthoredItemClearsIdentityAndPreservesOnlyValidTypedTargets() throws {
        let replacement = try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: "dumbbell-curl"))
        let original = CustomWorkoutItem(videoID: "", sets: 2, reps: 1, restSeconds: 75,
            targetLoad: 12, loadUnit: .pounds, durationSeconds: 20, perSide: true,
            durationUpperBound: 45, authoredExerciseID: ExerciseIDs.plank)
        let replaced = original.replacing(with: replacement)
        XCTAssertEqual(replaced.id, original.id)
        XCTAssertNil(replaced.authoredExerciseID)
        XCTAssertEqual(replaced.resolvedExerciseID, ExerciseIDs.dumbbellCurl)
        XCTAssertEqual(replaced.prescription, original.prescription)
        XCTAssertEqual(replaced.sets, original.sets)
        XCTAssertEqual(replaced.restSeconds, original.restSeconds)
        XCTAssertEqual(replaced.loadUnit, .pounds)
        XCTAssertEqual(replaced.targetLoad, 0)
        XCTAssertTrue(replaced.isValid)
        var invalid = original
        invalid.durationUpperBound = 10
        let reset = invalid.replacing(with: replacement)
        XCTAssertTrue(reset.isValid)
        XCTAssertNil(reset.authoredExerciseID)
        XCTAssertNil(reset.durationSeconds)
        XCTAssertNil(reset.durationUpperBound)
        XCTAssertNil(reset.perSide)
        XCTAssertEqual(reset.prescription, WorkingSetPrescription(unit: .repetitions, lowerBound: 10, upperBound: 10))
    }
}
