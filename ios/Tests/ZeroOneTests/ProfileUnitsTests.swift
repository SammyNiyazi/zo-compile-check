import XCTest
@testable import ZeroOne

@MainActor
final class ProfileUnitsTests: XCTestCase {
    func testRawValueValidationAndBodyWeightDisplayMapping() {
        let imperial = ZeroOneProfileUnitSelection.validated(weightRawValue: "lb", distanceRawValue: "mi")
        XCTAssertEqual(imperial, ZeroOneProfileUnitSelection(weight: .pounds, distance: .miles))
        XCTAssertEqual(imperial?.bodyWeightUnitRawValue, BodyWeightUnit.pounds.rawValue)

        let metric = ZeroOneProfileUnitSelection(weight: .kilograms, distance: .kilometers)
        XCTAssertEqual(metric.bodyWeightUnitRawValue, BodyWeightUnit.kilograms.rawValue)
        XCTAssertNil(ZeroOneProfileUnitSelection.validated(weightRawValue: "stone", distanceRawValue: "km"))
        XCTAssertNil(ZeroOneProfileUnitSelection.validated(weightRawValue: "kg", distanceRawValue: "yards"))
    }

    func testResolutionUsesExistingBodyWeightDisplayPreferenceBeforeLocaleDefault() {
        let locale = Locale(identifier: "en_US")
        let resolved = ZeroOneProfileUnitSelection.resolved(
            profile: ZeroOneUserProfile(),
            bodyWeightUnitRawValue: BodyWeightUnit.kilograms.rawValue,
            locale: locale
        )

        XCTAssertEqual(resolved.weight, .kilograms)
        XCTAssertEqual(resolved.distance, .miles)
    }

    func testVerifiedUnitChangeUpdatesPreferencesWithoutRewritingHistoricalValues() {
        var originalProfile = ZeroOneUserProfile()
        originalProfile.preferredWeightUnit = .kilograms
        originalProfile.preferredDistanceUnit = .kilometers
        originalProfile.startingBodyWeight = 81.25
        let store = ProfileUnitsMemoryStore(savedProfile: originalProfile)
        let repository = ZeroOneUserProfileRepository(store: store)

        let recordedSets = [
            CompletedSet(load: Load(82.5, unit: .kilograms), reps: 8, completedAt: Date(timeIntervalSince1970: 1_000)),
            CompletedSet(load: Load(180, unit: .pounds), reps: 6, completedAt: Date(timeIntervalSince1970: 2_000))
        ]
        let bodyWeightEntries = [
            BodyWeightEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                recordedAt: Date(timeIntervalSince1970: 3_000),
                kilograms: Decimal(string: "81.25")!
            )
        ]
        let selection = ZeroOneProfileUnitSelection(weight: .pounds, distance: .miles)

        XCTAssertTrue(repository.updateVerified { profile in
            profile = selection.applying(to: profile, previousWeight: .kilograms)
        })

        XCTAssertEqual(repository.profile.preferredWeightUnit, .pounds)
        XCTAssertEqual(repository.profile.preferredDistanceUnit, .miles)
        XCTAssertEqual(repository.profile.startingBodyWeight ?? 0, 179.125, accuracy: 0.01)
        let retry = selection.applying(to: repository.profile, previousWeight: .pounds)
        XCTAssertEqual(retry.startingBodyWeight ?? 0, repository.profile.startingBodyWeight ?? 0, accuracy: 0.0001)
        XCTAssertEqual(recordedSets.map(\.load), [Load(82.5, unit: .kilograms), Load(180, unit: .pounds)])
        XCTAssertEqual(bodyWeightEntries.first?.kilograms, Decimal(string: "81.25"))
    }

    func testFailedVerifiedSaveKeepsOldPreferencesAndAllowsRetry() {
        var originalProfile = ZeroOneUserProfile()
        originalProfile.preferredWeightUnit = .kilograms
        originalProfile.preferredDistanceUnit = .kilometers
        let store = ProfileUnitsMemoryStore(savedProfile: originalProfile)
        let repository = ZeroOneUserProfileRepository(store: store)
        let selection = ZeroOneProfileUnitSelection(weight: .pounds, distance: .miles)

        store.acceptsSaves = false
        XCTAssertFalse(repository.updateVerified { profile in
            profile = selection.applying(to: profile, previousWeight: .kilograms)
        })
        XCTAssertEqual(repository.profile.preferredWeightUnit, .kilograms)
        XCTAssertEqual(repository.profile.preferredDistanceUnit, .kilometers)

        store.acceptsSaves = true
        XCTAssertTrue(repository.updateVerified { profile in
            profile = selection.applying(to: profile, previousWeight: .kilograms)
        })
        XCTAssertEqual(repository.profile.preferredWeightUnit, .pounds)
        XCTAssertEqual(repository.profile.preferredDistanceUnit, .miles)
    }
}

private final class ProfileUnitsMemoryStore: ZeroOneUserProfilePersisting {
    var acceptsSaves = true
    private var savedProfile: ZeroOneUserProfile?

    init(savedProfile: ZeroOneUserProfile?) {
        self.savedProfile = savedProfile
    }

    func load() -> ZeroOneUserProfile? { savedProfile }

    func save(_ profile: ZeroOneUserProfile) {
        if acceptsSaves { savedProfile = profile }
    }

    func clear() { savedProfile = nil }
}
