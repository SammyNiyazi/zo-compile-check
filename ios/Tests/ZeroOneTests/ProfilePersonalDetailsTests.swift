import XCTest
@testable import ZeroOne

@MainActor
final class ProfilePersonalDetailsTests: XCTestCase {
    func testNameNormalizationAndValidation() {
        XCTAssertEqual(ZeroOneProfileDisplayName.storedValue(for: "  Sammy  "), "Sammy")
        XCTAssertNil(ZeroOneProfileDisplayName.storedValue(for: "   "))
        XCTAssertNil(ZeroOneProfileDisplayName.validationMessage(for: String(repeating: "A", count: 30)))
        XCTAssertNotNil(ZeroOneProfileDisplayName.validationMessage(for: String(repeating: "A", count: 31)))
        XCTAssertNotNil(ZeroOneProfileDisplayName.validationMessage(for: "A\nB"))
    }

    func testOlderVersionOneProfileDecodesWithoutAName() throws {
        let original = try JSONEncoder().encode(ZeroOneUserProfile())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "displayName")
        object.removeValue(forKey: "initialsTone")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(ZeroOneUserProfile.self, from: legacy)
        XCTAssertNil(restored.displayName)
        XCTAssertNil(restored.initialsTone)
        XCTAssertEqual(restored.version, ZeroOneUserProfile.currentVersion)
    }

    func testVerifiedUpdatePersistsNameBeforeShowingIt() {
        let store = InMemoryProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)
        XCTAssertTrue(repository.updateVerified { $0.displayName = "Sammy" })
        XCTAssertEqual(store.load()?.displayName, "Sammy")
        XCTAssertEqual(repository.profile.displayName, "Sammy")
        XCTAssertTrue(repository.updateVerified { $0.initialsTone = .signalYellow })
        XCTAssertEqual(store.load()?.initialsTone, .signalYellow)
    }

    func testFailedSaveKeepsPreviousNameAndAllowsRetry() {
        let store = InMemoryProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)
        store.acceptsSaves = false
        XCTAssertFalse(repository.updateVerified { $0.displayName = "Sammy" })
        XCTAssertNil(repository.profile.displayName)
        store.acceptsSaves = true
        XCTAssertTrue(repository.updateVerified { $0.displayName = "Sammy" })
        XCTAssertEqual(repository.profile.displayName, "Sammy")
    }
}

private final class InMemoryProfileStore: ZeroOneUserProfilePersisting {
    var acceptsSaves = true
    private var savedProfile: ZeroOneUserProfile?

    func load() -> ZeroOneUserProfile? { savedProfile }
    func save(_ profile: ZeroOneUserProfile) {
        if acceptsSaves { savedProfile = profile }
    }
    func clear() { savedProfile = nil }
}
