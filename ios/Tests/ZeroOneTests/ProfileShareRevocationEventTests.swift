import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class ProfileShareRevocationEventTests: XCTestCase {
    func testReloadRevokesBeforeReadAndRouteChangingReplacement() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: completed())
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        store.saved?.onboardingComplete = false
        XCTAssertTrue(repository.reload())
        XCTAssertEqual(bank.events, ["revoke", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertEqual(repository.profile, store.saved)
        XCTAssertEqual(store.writes, 0)
    }

    func testByteIdenticalReloadRevokesWithoutWritingOrChangingProfileFacts() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        XCTAssertTrue(repository.reload())
        XCTAssertEqual(bank.events, ["revoke", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile, original)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertEqual(store.writes, 0)
    }

    func testQuarantineRevokesBeforeBackupAttemptAndFreshOnboardingInstall() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: completed())
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        store.readFails = true; store.canQuarantine = true
        XCTAssertTrue(repository.reload())
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "quarantine:revoked", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile, ZeroOneUserProfile())
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertTrue(repository.isAvailable)
        XCTAssertEqual(store.quarantined?.onboardingComplete, true)
        XCTAssertEqual(store.writes, 0)
    }

    func testFailedQuarantineRevokesButKeepsPreviousProfileAndAvailabilityFailure() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents(); store.readFails = true
        XCTAssertFalse(repository.reload())
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "quarantine:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile, original)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertNotNil(repository.saveError)
        XCTAssertEqual(store.saved, original)
    }

    func testRecoveryToSameFactsNeverRevivesOldPermit() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        let installed = registration(bank); repository.installShareRevocationRegistration(installed)
        let old = bank.issue(); store.readFails = true
        XCTAssertFalse(repository.reload())
        store.readFails = false; bank.clearEvents()
        XCTAssertTrue(repository.reload())
        XCTAssertEqual(bank.events, ["revoke", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertTrue(repository.isAvailable)
        XCTAssertNil(repository.saveError)
        XCTAssertEqual(repository.profile, original)
        XCTAssertTrue(repository.isShareRevocationRegistered(installed))
    }

    func testVerifiedProfileChangeRevokesBeforeBothReadsAndWriteWithMetadataPreserved() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        XCTAssertTrue(repository.updateVerified { $0.preferredSessionMinutes = 45 })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "save:revoked", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile.preferredSessionMinutes, 45)
        XCTAssertEqual(repository.profile.startingBodyWeight, original.startingBodyWeight)
        XCTAssertEqual(repository.profile.startingBodyWeightEntryID, original.startingBodyWeightEntryID)
        XCTAssertEqual(repository.profile.firstWeekDraftWorkoutIDs, original.firstWeekDraftWorkoutIDs)
        XCTAssertEqual(repository.profile.displayName, original.displayName)
        XCTAssertEqual(repository.rootRoute, .appShell)
    }

    func testAcknowledgedRouteChangeRevokesBeforePersistenceAndPublishing() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: completed())
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        XCTAssertTrue(repository.update { $0.onboardingComplete = false })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "save:revoked", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertEqual(repository.profile, store.saved)
    }

    func testFailedReadbackRevokesAndPreservesDisplayedRootBeforeRecovery() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents(); store.failAfterWrite = true
        XCTAssertFalse(repository.updateVerified { $0.onboardingComplete = false })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "save:revoked", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile, original)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(store.saved?.onboardingComplete, false)
    }

    func testUnconfirmedWriteDoesNotPublishRouteDespiteRevocation() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents(); store.acceptsWrites = false
        XCTAssertFalse(repository.updateVerified { $0.onboardingComplete = false })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked", "save:revoked", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.profile, original)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertTrue(repository.isAvailable)
        XCTAssertNotNil(repository.saveError)
    }

    func testAlreadyPersistedReconciliationRevokesBeforeRouteInstallWithoutAnotherWrite() {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents()
        var persisted = original; persisted.onboardingComplete = false; store.saved = persisted
        XCTAssertTrue(repository.updateVerified { $0.onboardingComplete = false })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked"])
        XCTAssertFalse(old.allows)
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertEqual(repository.profile, persisted)
        XCTAssertEqual(store.writes, 0)
    }

    func testSameFactsAcknowledgementAndInvalidProposalBothKeepOldPermitsRevoked() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: completed())
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let unchanged = bank.issue(); bank.clearEvents()
        XCTAssertTrue(repository.updateVerified { _ in })
        XCTAssertEqual(bank.events, ["revoke", "read:revoked"])
        XCTAssertFalse(unchanged.allows)
        let invalid = bank.issue(); bank.clearEvents()
        XCTAssertFalse(repository.updateVerified { $0.version = 999 })
        XCTAssertEqual(bank.events, ["revoke"])
        XCTAssertFalse(invalid.allows)
        XCTAssertEqual(store.writes, 0)
    }

    func testUnavailableUpdateRevokesBeforeGuardWithoutCallingChangeOrStore() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: completed())
        store.readFails = true
        let repository = ZeroOneUserProfileRepository(store: store)
        repository.installShareRevocationRegistration(registration(bank))
        let old = bank.issue(); bank.clearEvents(); var changed = false
        XCTAssertFalse(repository.updateVerified { _ in changed = true })
        XCTAssertEqual(bank.events, ["revoke"])
        XCTAssertFalse(old.allows); XCTAssertFalse(changed)
        XCTAssertEqual(store.writes, 0)
    }

    func testRegistrationReplacementRemovalAndSameReferenceReinstallArePermanent() {
        let firstBank = ProfileEventPermitBank(); let secondBank = ProfileEventPermitBank()
        let repository = ZeroOneUserProfileRepository(store: Store(bank: firstBank, saved: completed()))
        let first = registration(firstBank); let second = registration(secondBank)
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
        repository.installShareRevocationRegistration(first)
        let old = firstBank.issue(); let incoming = secondBank.issue()
        repository.installShareRevocationRegistration(second)
        XCTAssertFalse(old.allows); XCTAssertFalse(incoming.allows)
        XCTAssertFalse(repository.isShareRevocationRegistered(first))
        XCTAssertTrue(repository.isShareRevocationRegistered(second))
        let same = secondBank.issue(); secondBank.clearEvents()
        repository.installShareRevocationRegistration(second)
        XCTAssertEqual(secondBank.events, ["revoke"]); XCTAssertFalse(same.allows)
        let removed = secondBank.issue()
        repository.installShareRevocationRegistration(nil)
        XCTAssertFalse(removed.allows)
        XCTAssertFalse(repository.isShareRevocationRegistered(second))
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
    }

    func testReadOnlyExportAndRouteReadDoNotRevokeInstalledPermit() throws {
        let bank = ProfileEventPermitBank(); let original = completed()
        let store = Store(bank: bank, saved: original)
        let repository = ZeroOneUserProfileRepository(store: store)
        let installed = registration(bank); repository.installShareRevocationRegistration(installed)
        let old = bank.issue(); bank.clearEvents()
        XCTAssertEqual(try repository.profileForExport(), original)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertTrue(repository.isShareRevocationRegistered(installed))
        XCTAssertEqual(bank.events, ["read:VALID"])
        XCTAssertTrue(old.allows)
    }

    func testUnregisteredRepositoryKeepsOnboardingAndSaveBehaviorUsable() {
        let bank = ProfileEventPermitBank(); let store = Store(bank: bank, saved: nil)
        let repository = ZeroOneUserProfileRepository(store: store)
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertFalse(repository.isShareRevocationRegistered(nil))
        repository.completeOnboarding()
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertEqual(store.saved?.onboardingComplete, true)
        XCTAssertEqual(store.writes, 1)
    }

    private func registration(_ bank: ProfileEventPermitBank) -> ZeroOneShareRevocationRegistration {
        ZeroOneShareRevocationRegistration { bank.revoke() }
    }
    private func completed() -> ZeroOneUserProfile {
        var value = ZeroOneUserProfile(); value.onboardingComplete = true
        value.displayName = "Existing"; value.startingBodyWeight = 81.25
        value.startingBodyWeightEntryID = UUID(); value.firstWeekDraftWorkoutIDs = [UUID(), UUID()]
        return value
    }
    private final class Store: ZeroOneUserProfilePersisting {
        let bank: ProfileEventPermitBank
        var saved: ZeroOneUserProfile?
        var quarantined: ZeroOneUserProfile?
        var readFails = false
        var canQuarantine = false
        var acceptsWrites = true
        var failAfterWrite = false
        var writes = 0
        init(bank: ProfileEventPermitBank, saved: ZeroOneUserProfile?) { self.bank = bank; self.saved = saved }
        func load() -> ZeroOneUserProfile? { saved }
        func loadForExport() throws -> ZeroOneUserProfile? {
            bank.observe("read")
            if readFails { throw CocoaError(.fileReadNoPermission) }
            return saved
        }
        func save(_ profile: ZeroOneUserProfile) {
            bank.observe("save"); writes += 1
            if acceptsWrites { saved = profile }
            if failAfterWrite { readFails = true }
        }
        func clear() { bank.observe("clear"); saved = nil }
        func quarantineUnreadableProfile() -> Bool {
            bank.observe("quarantine")
            guard canQuarantine else { return false }
            quarantined = saved; saved = nil; readFails = false; return true
        }
    }
}

private final class ProfileEventPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var allows: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func revoke() { lock.lock(); defer { lock.unlock() }; valid = false }
}

private final class ProfileEventPermitBank: @unchecked Sendable {
    private let lock = NSLock()
    private var permit: ProfileEventPermit?
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func issue() -> ProfileEventPermit {
        lock.lock(); defer { lock.unlock() }
        let fresh = ProfileEventPermit(); permit = fresh; return fresh
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        permit?.revoke(); recorded.append("revoke")
    }
    func observe(_ action: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(action + (permit?.allows == true ? ":VALID" : ":revoked"))
    }
    func clearEvents() { lock.lock(); defer { lock.unlock() }; recorded.removeAll() }
}
