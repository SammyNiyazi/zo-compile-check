import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class ProfilePersistenceTests: XCTestCase {
    func testFailedImmediateAnswerDoesNotPublishOrAdvanceSavedProfile() {
        let store = ProfilePersistenceTestStore()
        let repository = ZeroOneUserProfileRepository(store: store)
        store.acceptsWrites = false
        XCTAssertFalse(repository.update { $0.trainingGoal = .buildStrength })
        XCTAssertNil(repository.profile.trainingGoal)
        XCTAssertNotNil(repository.saveError)
        store.acceptsWrites = true
        XCTAssertTrue(repository.update { $0.trainingGoal = .buildStrength })
        XCTAssertEqual(store.saved?.trainingGoal, .buildStrength)
        XCTAssertNil(repository.saveError)
    }

    func testStaleEditorCannotOverwriteAnotherSavedChoice() {
        let store = ProfilePersistenceTestStore()
        let first = ZeroOneUserProfileRepository(store: store)
        let second = ZeroOneUserProfileRepository(store: store)
        XCTAssertTrue(first.updateVerified { $0.preferredSessionMinutes = 30 })
        let writes = store.writes
        XCTAssertFalse(second.updateVerified { $0.displayName = "Sammy" })
        XCTAssertEqual(store.writes, writes)
        XCTAssertEqual(store.saved?.preferredSessionMinutes, 30)
        XCTAssertNil(store.saved?.displayName)
        XCTAssertTrue(second.reload())
        XCTAssertTrue(second.updateVerified { $0.displayName = "Sammy" })
        XCTAssertEqual(store.saved?.preferredSessionMinutes, 30)
        XCTAssertEqual(store.saved?.displayName, "Sammy")
    }

    func testUnreadableProfileCannotBeReplacedByDefaults() {
        let store = ProfilePersistenceTestStore()
        store.failsReads = true
        let repository = ZeroOneUserProfileRepository(store: store)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertFalse(repository.updateVerified { $0.displayName = "Replacement" })
        XCTAssertEqual(store.writes, 0)
        XCTAssertFalse(repository.reload())
        store.failsReads = false
        XCTAssertTrue(repository.reload())
        XCTAssertTrue(repository.updateVerified { $0.displayName = "Recovered" })
    }

    func testFailedReadbackRequiresReloadAndDoesNotDuplicateConfirmedRetry() {
        let store = ProfilePersistenceTestStore()
        let repository = ZeroOneUserProfileRepository(store: store)
        store.failAfterWrite = true
        XCTAssertFalse(repository.updateVerified { $0.preferredSessionMinutes = 60 })
        XCTAssertNil(repository.profile.preferredSessionMinutes)
        XCTAssertEqual(store.saved?.preferredSessionMinutes, 60)
        XCTAssertFalse(repository.isAvailable)
        store.failsReads = false
        store.failAfterWrite = false
        XCTAssertTrue(repository.reload())
        let writes = store.writes
        XCTAssertTrue(repository.updateVerified { $0.preferredSessionMinutes = 60 })
        XCTAssertEqual(store.writes, writes)
    }

    func testPreferenceSavePreservesPlanAndBodyWeightMetadata() {
        var profile = ZeroOneUserProfile()
        profile.onboardingComplete = true
        profile.startingBodyWeight = 80.125
        profile.startingBodyWeightEntryID = UUID()
        profile.firstWeekDraftWorkoutIDs = [UUID(), UUID()]
        let store = ProfilePersistenceTestStore(saved: profile)
        let repository = ZeroOneUserProfileRepository(store: store)
        XCTAssertTrue(repository.update { $0.preferredTrainingDays = [.monday, .friday] })
        XCTAssertEqual(store.saved?.startingBodyWeight, profile.startingBodyWeight)
        XCTAssertEqual(store.saved?.startingBodyWeightEntryID, profile.startingBodyWeightEntryID)
        XCTAssertEqual(store.saved?.firstWeekDraftWorkoutIDs, profile.firstWeekDraftWorkoutIDs)
        XCTAssertEqual(store.saved?.onboardingComplete, true)
    }
}

private final class ProfilePersistenceTestStore: ZeroOneUserProfilePersisting {
    var saved: ZeroOneUserProfile?
    var acceptsWrites = true
    var failsReads = false
    var failAfterWrite = false
    var writes = 0
    init(saved: ZeroOneUserProfile? = nil) { self.saved = saved }
    func load() -> ZeroOneUserProfile? { saved }
    func loadForExport() throws -> ZeroOneUserProfile? {
        if failsReads { throw CocoaError(.fileReadNoPermission) }
        return saved
    }
    func save(_ profile: ZeroOneUserProfile) {
        writes += 1
        if acceptsWrites { saved = profile }
        if failAfterWrite { failsReads = true }
    }
    func clear() { saved = nil }
}
