import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class CustomWorkoutPersistenceTests: XCTestCase {
    func testDiscardedSaveDoesNotBecomeVisibleOrLeakIntoNextSave() {
        let store = CustomWorkoutPersistenceDouble()
        let repository = makeRepository(store)
        let first = workout("First")
        store.discardsWrites = true
        XCTAssertFalse(repository.save(first))
        XCTAssertTrue(repository.workouts.isEmpty)

        store.discardsWrites = false
        let second = workout("Second")
        XCTAssertTrue(repository.save(second))
        XCTAssertEqual(repository.workouts.map(\.id), [second.id])
        XCTAssertEqual(store.values.map(\.id), [second.id])
    }

    func testDiscardedDeleteKeepsSavedSessionVisible() {
        let original = workout("Keep me")
        let store = CustomWorkoutPersistenceDouble(values: [original])
        let repository = makeRepository(store)
        store.discardsWrites = true
        XCTAssertFalse(repository.remove(id: original.id))
        XCTAssertEqual(repository.workouts, [original])
        XCTAssertEqual(store.values, [original])
    }

    func testStaleCollectionCannotOverwriteNewerSavedWork() {
        let original = workout("Original")
        let newer = workout("Saved elsewhere")
        let store = CustomWorkoutPersistenceDouble(values: [original])
        let repository = makeRepository(store)
        store.values.append(newer)

        XCTAssertFalse(repository.remove(id: original.id))
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(repository.workouts, [original, newer])
        XCTAssertEqual(store.values, [original, newer])
        // A new explicit operation uses the refreshed collection, preserving newer.
        XCTAssertTrue(repository.remove(id: original.id))
        XCTAssertEqual(store.values, [newer])
    }

    func testPlanSaveConfirmsEntireCollectionNotOnlyNewSessionIDs() {
        let existing = workout("Existing")
        let store = CustomWorkoutPersistenceDouble(values: [existing])
        let repository = makeRepository(store)
        store.droppedID = existing.id
        XCTAssertFalse(repository.saveTogether([workout("A"), workout("B")]))
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(repository.workouts, store.values)
    }

    func testErrorAfterWriteIsSuccessfulOnlyWithExactConfirmedReadback() {
        let store = CustomWorkoutPersistenceDouble()
        let repository = makeRepository(store)
        store.throwsAfterWrite = true
        let plan = workout("Saved despite late error")
        XCTAssertTrue(repository.save(plan))
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(repository.workouts, store.values)
        XCTAssertEqual(repository.workouts.first?.id, plan.id)
    }

    func testUnavailableOrInvalidStorageIsNotReplacedWithDefaults() {
        let original = workout("Original")
        let store = CustomWorkoutPersistenceDouble(values: [original])
        let repository = makeRepository(store)
        store.readsFail = true
        XCTAssertFalse(repository.save(workout("New")))
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.values, [original])
        XCTAssertFalse(repository.isAvailable)

        let invalidStore = CustomWorkoutPersistenceDouble(values: [original, original])
        let invalidRepository = makeRepository(invalidStore)
        XCTAssertFalse(invalidRepository.isAvailable)
        XCTAssertFalse(invalidRepository.save(workout("New")))
        XCTAssertEqual(invalidStore.writes, 0)
    }

    func testUnavailableExerciseRecordSurvivesSavingAnotherWorkout() throws {
        let suite = "01-custom-preservation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "workouts"
        let orphan = CustomWorkout(name: "Preserve original", items: [
            CustomWorkoutItem(videoID: "temporarily-unavailable-exercise")
        ])
        defaults.set(try JSONEncoder().encode([orphan]), forKey: key)
        let store = UserDefaultsCustomWorkoutStore(defaults: defaults, key: key)
        let repository = CustomWorkoutRepository(store: store,
            draftStore: UserDefaultsCustomWorkoutDraftStore(defaults: defaults))

        XCTAssertTrue(repository.isAvailable)
        XCTAssertFalse(orphan.isValid)
        XCTAssertNil(orphan.makeSession())
        XCTAssertTrue(repository.save(workout("Available")))
        XCTAssertEqual(try store.load().first(where: { $0.id == orphan.id }), orphan)
        // New invalid edits still cannot enter through the repository.
        var invalidNew = orphan
        invalidNew.name = "Invalid edit"
        XCTAssertFalse(repository.save(invalidNew))
        XCTAssertEqual(try store.load().first(where: { $0.id == orphan.id }), orphan)
    }

    func testReloadRecoversInitialReadFailureWithoutWritingOrLosingWorkouts() {
        let original = workout("Saved plan")
        let store = CustomWorkoutPersistenceDouble(values: [original])
        store.readsFail = true
        let repository = makeRepository(store)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertFalse(repository.reload())
        XCTAssertEqual(store.writes, 0)

        store.readsFail = false
        XCTAssertTrue(repository.reload())
        XCTAssertTrue(repository.isAvailable)
        XCTAssertEqual(repository.workouts, [original])
        XCTAssertEqual(store.writes, 0)
        let added = workout("New plan")
        XCTAssertTrue(repository.save(added))
        XCTAssertEqual(Set(store.values.map(\.id)), Set([original.id, added.id]))
    }

    func testFailedReloadRetainsLastReadableCollectionAndRejectsWrites() {
        let original = workout("Keep visible")
        let store = CustomWorkoutPersistenceDouble(values: [original])
        let repository = makeRepository(store)
        // Invalid bytes/data must not be treated as an empty library.
        store.values = [original, original]
        XCTAssertFalse(repository.reload())
        XCTAssertEqual(repository.workouts, [original])
        XCTAssertFalse(repository.save(workout("Do not save")))
        XCTAssertEqual(store.writes, 0)

        let newer = workout("Newly recovered")
        store.values = [original, newer]
        XCTAssertTrue(repository.reload())
        XCTAssertEqual(repository.workouts, [original, newer])
        XCTAssertEqual(store.writes, 0)
    }

    private func workout(_ name: String) -> CustomWorkout {
        CustomWorkout(name: name, items: [CustomWorkoutItem(videoID: "dumbbell-curl")])
    }

    private func makeRepository(_ store: CustomWorkoutPersistenceDouble) -> CustomWorkoutRepository {
        CustomWorkoutRepository(store: store,
            draftStore: UserDefaultsCustomWorkoutDraftStore(key: "01-unused-test-draft-\(UUID().uuidString)"))
    }
}

private final class CustomWorkoutPersistenceDouble: CustomWorkoutPersisting {
    var values: [CustomWorkout]
    var discardsWrites = false
    var throwsAfterWrite = false
    var readsFail = false
    var droppedID: UUID?
    var writes = 0

    init(values: [CustomWorkout] = []) { self.values = values }
    func load() throws -> [CustomWorkout] {
        if readsFail { throw CustomWorkoutStoreError.unavailable }
        return values
    }
    func save(_ workouts: [CustomWorkout]) throws {
        writes += 1
        if !discardsWrites { values = workouts.filter { $0.id != droppedID } }
        if throwsAfterWrite { throw CustomWorkoutStoreError.unavailable }
    }
}

extension CustomWorkoutPersistenceTests {
    func testProgrammeCopyFailedSaveRetainsItsEditableDraftAndOriginalSavedWorkout() throws {
        let suite = "01-programme-copy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = workout("Keep my original")
        let store = CustomWorkoutPersistenceDouble(values: [existing])
        let repository = CustomWorkoutRepository(store: store,
            draftStore: UserDefaultsCustomWorkoutDraftStore(defaults: defaults))
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneConsistency))
        let copy = try ProgrammeSessionCustomization.makeCopy(programme: programme,
            previewSession: programme.makeSession(), warmUpLength: .short)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(repository.workouts, [existing])
        XCTAssertTrue(repository.keepDraft(copy))
        store.discardsWrites = true
        XCTAssertFalse(repository.save(copy))
        XCTAssertEqual(repository.draft?.workout, copy)
        XCTAssertEqual(repository.workouts, [existing])
        XCTAssertEqual(store.values, [existing])
        let relaunched = CustomWorkoutRepository(store: store,
            draftStore: UserDefaultsCustomWorkoutDraftStore(defaults: defaults))
        XCTAssertEqual(relaunched.draft?.workout, copy)
        XCTAssertEqual(relaunched.workouts, [existing])
        let restoredSession = try XCTUnwrap(relaunched.draft?.workout.makeSession())
        XCTAssertEqual(restoredSession.exercises.map { $0.plan.exerciseID }, programme.exercisePlans.map(\.exerciseID))
        let plank = try XCTUnwrap(restoredSession.exercises.first { $0.plan.exerciseID == ExerciseIDs.plank })
        XCTAssertEqual(plank.plan.prescription.unit, .seconds)
        XCTAssertTrue(plank.completedSets.isEmpty)
        store.discardsWrites = false
        XCTAssertTrue(repository.save(copy))
        let savedCopy = try XCTUnwrap(repository.workouts.first { $0.id == copy.id })
        XCTAssertEqual(savedCopy.items, copy.items)
        XCTAssertEqual(repository.workouts.first { $0.id == existing.id }, existing)
        XCTAssertTrue(relaunched.reload())
        let confirmedCopy = try XCTUnwrap(relaunched.workouts.first { $0.id == copy.id })
        XCTAssertEqual(confirmedCopy.items, copy.items)
        XCTAssertEqual(confirmedCopy.items.map(\.authoredExerciseID), copy.items.map(\.authoredExerciseID))
    }
}
