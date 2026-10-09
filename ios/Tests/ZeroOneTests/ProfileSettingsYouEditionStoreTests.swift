import XCTest
@testable import ZeroOne

final class ProfileSettingsYouEditionStoreTests: XCTestCase {
    private final class Memory: ProfileSettingsYouEditionPersisting {
        var raw: String?
        var failRead = false
        var failSave = false
        var ignoreSave = false
        var writes = 0
        func load() throws -> String? {
            if failRead { throw CocoaError(.fileReadCorruptFile) }
            return raw
        }
        func save(_ value: String) throws {
            writes += 1
            if failSave { throw CocoaError(.fileWriteUnknown) }
            if !ignoreSave { raw = value }
        }
    }

    @MainActor func testFollowsChangingThemeUntilExplicitChoiceThenSurvivesRelaunch() {
        let memory = Memory()
        let store = ProfileSettingsYouEditionStore(persistence: memory)
        XCTAssertEqual(store.resolved(fallback: .pink), .pink)
        XCTAssertEqual(store.resolved(fallback: .neon), .neon)
        XCTAssertEqual(memory.writes, 0)
        XCTAssertTrue(store.select(.chrome))
        XCTAssertEqual(store.resolved(fallback: .pink), .chrome)
        XCTAssertEqual(ProfileSettingsYouEditionStore(persistence: memory).selected, .chrome)
    }

    @MainActor func testCorruptFutureValueCannotBeOverwrittenByOpeningOrChoosing() {
        let memory = Memory(); memory.raw = "future-edition"
        let store = ProfileSettingsYouEditionStore(persistence: memory)
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.select(.onyx))
        XCTAssertEqual(memory.raw, "future-edition")
        XCTAssertEqual(memory.writes, 0)
        XCTAssertNil(store.selected)
    }

    @MainActor func testFailedOrUnacknowledgedSaveKeepsPreviouslyConfirmedSelection() {
        let memory = Memory(); memory.raw = "pink"
        let store = ProfileSettingsYouEditionStore(persistence: memory)
        memory.failSave = true
        XCTAssertFalse(store.select(.neon))
        XCTAssertEqual(store.selected, .pink)
        XCTAssertTrue(store.saveFailed)
        memory.failSave = false; memory.ignoreSave = true
        XCTAssertFalse(store.select(.chrome))
        XCTAssertEqual(store.selected, .pink)
        memory.ignoreSave = false
        XCTAssertTrue(store.select(.chrome))
        XCTAssertFalse(store.saveFailed)
    }

    @MainActor func testExternalChangeIsRereadBeforeAnyWrite() {
        let memory = Memory(); memory.raw = "pink"
        let store = ProfileSettingsYouEditionStore(persistence: memory)
        memory.raw = "neon"
        XCTAssertFalse(store.select(.chrome))
        XCTAssertEqual(store.selected, .neon)
        XCTAssertEqual(memory.writes, 0)
        XCTAssertTrue(store.select(.chrome))
    }

    @MainActor func testUnreadableStorageKeepsUnavailableUntilExplicitReload() {
        let memory = Memory(); memory.failRead = true
        let store = ProfileSettingsYouEditionStore(persistence: memory)
        XCTAssertFalse(store.select(.chrome))
        XCTAssertEqual(memory.writes, 0)
        memory.failRead = false; memory.raw = "pink"; store.reload()
        XCTAssertEqual(store.selected, .pink)
        XCTAssertTrue(store.isAvailable)
    }

    func testUserDefaultsRoundTripUsesOnlyIsolatedKey() throws {
        let name = "ProfileSettingsYouEditionStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("retained-profile-bytes", forKey: "slick.userProfile")
        defaults.set("retro", forKey: "slick.designTheme")
        let persistence = UserDefaultsProfileSettingsYouEditionStore(defaults: defaults)
        XCTAssertNil(try persistence.load())
        try persistence.save("neon")
        XCTAssertEqual(try persistence.load(), "neon")
        XCTAssertEqual(defaults.string(forKey: "slick.userProfile"), "retained-profile-bytes")
        XCTAssertEqual(defaults.string(forKey: "slick.designTheme"), "retro")
    }
}
