import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class ZeroOneFirstWeekPlanCommitterTests: XCTestCase {
    func testAcknowledgedPlanIsImmediatelyAvailableThroughSharedRepository() throws {
        var initial = ZeroOneUserProfile()
        initial.preferredWeightUnit = .pounds
        let profileStore = PlanProfileStore(value: initial)
        let profile = ZeroOneUserProfileRepository(store: profileStore)
        let existing = CustomWorkout(name: "My own session", items: [CustomWorkoutItem(videoID: "dumbbell-curl")])
        let workoutStore = PlanWorkoutStore(values: [existing])
        let workouts = repository(workoutStore)
        // These are the same observable references supplied to Profile, Today
        // and Library. No reload or new repository is needed after the save.
        let library = workouts
        let today = workouts
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: workouts, completesOnboarding: true, skippedSetup: false, savedAt: date)

        XCTAssertTrue(profile.profile.onboardingComplete)
        XCTAssertEqual(profile.profile.savedFirstWeekPlan, saved)
        XCTAssertNil(profile.profile.firstWeekDraftWorkoutIDs)
        XCTAssertEqual(library.workouts.count, 3)
        XCTAssertEqual(library.workouts.first { $0.id == existing.id }, existing)
        let nextID = try XCTUnwrap(saved.nextWorkoutID(on: date))
        let next = try XCTUnwrap(today.workouts.first { $0.id == nextID })
        XCTAssertEqual(next.makeSession()?.customWorkoutID, nextID)
        XCTAssertTrue(next.items.allSatisfy { $0.loadUnit == .pounds })
    }

    func testUnconfirmedProfileDraftNeverWritesWorkoutsOrCompletesSetup() {
        let profileStore = PlanProfileStore()
        profileStore.rejectAllWrites = true
        let profile = ZeroOneUserProfileRepository(store: profileStore)
        let workoutStore = PlanWorkoutStore()
        XCTAssertThrowsError(try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: repository(workoutStore), completesOnboarding: true, skippedSetup: true))
        XCTAssertEqual(workoutStore.writes, 0)
        XCTAssertFalse(profile.profile.onboardingComplete)
        XCTAssertNil(profile.profile.savedFirstWeekPlan)
    }

    func testWorkoutFailureKeepsPreviousPlanAndPendingIDsForRetry() throws {
        let oldPlan = ZeroOneSavedFirstWeekPlan(plan: plan(), workoutIDs: [UUID(), UUID()], savedAt: .distantPast)
        var initial = ZeroOneUserProfile()
        initial.savedFirstWeekPlan = oldPlan
        initial.onboardingComplete = true
        let profile = ZeroOneUserProfileRepository(store: PlanProfileStore(value: initial))
        let store = PlanWorkoutStore()
        store.rejectWrites = true
        let workouts = repository(store)
        XCTAssertThrowsError(try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: workouts, completesOnboarding: false, skippedSetup: false))
        XCTAssertEqual(profile.profile.savedFirstWeekPlan, oldPlan)
        let ids = try XCTUnwrap(profile.profile.firstWeekDraftWorkoutIDs)
        XCTAssertTrue(workouts.workouts.isEmpty)

        store.rejectWrites = false
        let saved = try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: workouts, completesOnboarding: false, skippedSetup: false)
        XCTAssertEqual(saved.workoutIDs, ids)
        XCTAssertEqual(Set(workouts.workouts.map(\.id)), Set(ids))
        XCTAssertTrue(profile.profile.onboardingComplete)
    }

    func testActivationRetryReusesSessionIDsInsteadOfDuplicatingLibrary() throws {
        let store = PlanProfileStore()
        store.rejectActivation = true
        let profile = ZeroOneUserProfileRepository(store: store)
        let workouts = repository(PlanWorkoutStore())
        XCTAssertThrowsError(try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: workouts, completesOnboarding: true, skippedSetup: false))
        let pendingIDs = try XCTUnwrap(profile.profile.firstWeekDraftWorkoutIDs)
        XCTAssertEqual(workouts.workouts.count, 2)
        XCTAssertFalse(profile.profile.onboardingComplete)
        XCTAssertNil(profile.profile.savedFirstWeekPlan)

        store.rejectActivation = false
        let saved = try ZeroOneFirstWeekPlanCommitter.save(plan(), profile: profile,
            workouts: workouts, completesOnboarding: true, skippedSetup: false)
        XCTAssertEqual(saved.workoutIDs, pendingIDs)
        XCTAssertEqual(workouts.workouts.count, 2)
        XCTAssertTrue(profile.profile.onboardingComplete)
    }

    private func plan() -> ZeroOneFirstWeekPlan {
        // A first-week save accepts a reviewed, current selection rather than an
        // arbitrary hand-built workout. The repository acknowledgement tests stay
        // independent of which exercises that policy chooses.
        ZeroOneFirstWeekPlanner.recommend(for: ZeroOneUserProfile(),
            availableVideoIDs: Set(MoveKitExercise.all.map(\.id)))!
    }

    func testChangedSelectionContextRejectsBeforeEitherRepositoryWrites() throws {
        let profileStore = PlanProfileStore()
        let profile = ZeroOneUserProfileRepository(store: profileStore)
        let proposal = plan()
        XCTAssertTrue(profile.updateVerified {
            $0.trainingConstraint = .movementSensitivity
        })
        let savedPreferences = profileStore.value
        let workoutStore = PlanWorkoutStore()
        XCTAssertThrowsError(try ZeroOneFirstWeekPlanCommitter.save(proposal, profile: profile,
            workouts: repository(workoutStore), completesOnboarding: true, skippedSetup: false)) { error in
            XCTAssertEqual(error as? ZeroOneFirstWeekPlanCommitter.CommitError, .reviewRequired)
        }
        XCTAssertEqual(workoutStore.writes, 0)
        XCTAssertEqual(profileStore.value, savedPreferences)
        XCTAssertNil(profile.profile.firstWeekDraftWorkoutIDs)
        XCTAssertFalse(profile.profile.onboardingComplete)
    }

    private func repository(_ store: PlanWorkoutStore) -> CustomWorkoutRepository {
        CustomWorkoutRepository(store: store,
            draftStore: UserDefaultsCustomWorkoutDraftStore(key: "01-plan-test-unused-\(UUID().uuidString)"))
    }
}

private final class PlanProfileStore: ZeroOneUserProfilePersisting {
    var value: ZeroOneUserProfile?
    var rejectAllWrites = false
    var rejectActivation = false
    init(value: ZeroOneUserProfile? = nil) { self.value = value }
    func load() -> ZeroOneUserProfile? { value }
    func save(_ proposed: ZeroOneUserProfile) {
        guard !rejectAllWrites, !(rejectActivation && proposed.onboardingComplete) else { return }
        value = proposed
    }
    func clear() { value = nil }
}

private final class PlanWorkoutStore: CustomWorkoutPersisting {
    var values: [CustomWorkout]
    var rejectWrites = false
    var writes = 0
    init(values: [CustomWorkout] = []) { self.values = values }
    func load() throws -> [CustomWorkout] { values }
    func save(_ proposed: [CustomWorkout]) throws {
        writes += 1
        if !rejectWrites { values = proposed }
    }
}
