import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

#if DEBUG
@MainActor
final class ZeroOneRootShareCoordinatorTests: XCTestCase {
    func testSignedOutUnconfiguredOfflineWorkoutAuditAndFreshReopen() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        XCTAssertFalse(fixture.account.isConfigured)
        XCTAssertNil(fixture.account.identity)
        XCTAssertTrue(fixture.parent.hasLifecycleObserversInstalled)
        XCTAssertTrue(fixture.parent.hasMatchingOwnerRegistrations)
        XCTAssertTrue(fixture.profile.isAvailable)
        XCTAssertEqual(fixture.profile.rootRoute, .appShell)
        XCTAssertTrue(fixture.outdoor.canShareSavedRecords)
        XCTAssertNil(try fixture.activeStore.load())

        let first = try await presentation(fixture)
        let firstAllowed = await fixture.coordinator.authorize(first)
        XCTAssertTrue(firstAllowed)
        XCTAssertTrue(first.lifetime.allows(first.id))
        fixture.coordinator.close(first)
        XCTAssertFalse(first.lifetime.allows(first.id))

        let reopened = try await presentation(fixture)
        XCTAssertNotEqual(reopened.id, first.id)
        XCTAssertTrue(reopened.lifetime.allows(reopened.id))
        let oldAllowed = await fixture.coordinator.authorize(first)
        let newAllowed = await fixture.coordinator.authorize(reopened)
        XCTAssertFalse(oldAllowed)
        XCTAssertTrue(newAllowed)
        // Repeated old-handle cleanup cannot remove the reopened presentation.
        fixture.coordinator.close(first)
        XCTAssertTrue(reopened.lifetime.allows(reopened.id))
    }

    func testActualProfileOwnerMutationAndRestorationNeverReviveOldPermit() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let original = fixture.profile.profile
        XCTAssertTrue(fixture.profile.updateVerified { $0.preferredSessionMinutes = 45 })
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertEqual(try fixture.profile.profileForExport(), fixture.profile.profile)
        XCTAssertTrue(fixture.profile.updateVerified { $0 = original })
        let restored = try await presentation(fixture)
        let oldAllowed = await fixture.coordinator.authorize(old)
        let restoredAllowed = await fixture.coordinator.authorize(restored)
        XCTAssertFalse(oldAllowed)
        XCTAssertTrue(restoredAllowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertEqual(fixture.profile.profile, original)
    }

    func testActualHistoryCollectionMutationRevokesOldAcknowledgedCollection() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let secondSession = Self.completedSession(at: Self.date.addingTimeInterval(60))
        XCTAssertEqual(try fixture.history.record(secondSession), .inserted)
        XCTAssertFalse(old.lifetime.allows(old.id))
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let stale = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(stale)
        XCTAssertEqual(try fixture.history.confirmedEntries().count, 2)
        let fresh = try await presentation(fixture)
        let freshAllowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(freshAllowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testActualOutdoorRecordAuditAndPrivacyDeletionRejectsOriginalSource() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        fixture.showOutdoor()
        let record = try await fixture.saveOutdoorActivity()
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let prepared = await fixture.coordinator.prepareOutdoor(record, request: request)
        let old = try XCTUnwrap(prepared)
        let allowed = await fixture.coordinator.authorize(old)
        XCTAssertTrue(allowed)
        XCTAssertEqual(record.confirmedActiveSeconds, 20)
        XCTAssertNil(record.recordedDistanceMeters)

        let updated = try await fixture.outdoorRepository.deleteRoute(for: record.id,
            at: Self.date.addingTimeInterval(30))
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.confirmedActiveSeconds, record.confirmedActiveSeconds)
        XCTAssertNotNil(updated.routeDeletedAt)
        let nextRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        let stale = await fixture.coordinator.prepareOutdoor(record, request: nextRequest)
        XCTAssertNil(stale)
        let freshPrepared = await fixture.coordinator.prepareOutdoor(updated, request: nextRequest)
        let fresh = try XCTUnwrap(freshPrepared)
        let freshAllowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(freshAllowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testOriginalRequestCannotBeAdmittedAfterRouteRevisionWithIdenticalRootFacts() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let facts = fixture.facts
        let oldRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        // A detail pop/replacement must revoke even while showsProfile stays true.
        fixture.coordinator.revokeBeforeRouteChange()
        XCTAssertEqual(fixture.facts, facts)
        XCTAssertFalse(fixture.coordinator.isCurrent(oldRequest))
        let stale = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: try fixture.history.confirmedEntries(), request: oldRequest)
        XCTAssertNil(stale)
        let freshRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        XCTAssertNotEqual(freshRequest, oldRequest)
        let fresh = try await presentation(fixture)
        let allowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(allowed)
    }

    func testRedundantMountedContextInstallPreservesCurrentRequestAndPermit() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let generation = fixture.parent.registry.currentGeneration
        fixture.installContext(on: fixture.coordinator)
        XCTAssertTrue(fixture.coordinator.isCurrent(request))
        XCTAssertEqual(fixture.parent.registry.currentGeneration, generation)
        XCTAssertTrue(old.lifetime.allows(old.id))
        let retainedAllowed = await fixture.coordinator.authorize(old)
        XCTAssertTrue(retainedAllowed)
        let prepared = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        let reopened = try XCTUnwrap(prepared)
        let allowed = await fixture.coordinator.authorize(reopened)
        XCTAssertTrue(allowed)
        XCTAssertTrue(old.lifetime.allows(old.id))
    }

    func testSameIDAlteredWorkoutAndDuplicateCollectionDenyWithoutChangingPersistence() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.historyDirectory.appendingPathComponent("history.json"))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.entry)) as? [String: Any])
        encoded["title"] = "Changed synthetic title with the same source ID"
        let altered = try JSONDecoder().decode(WorkoutHistoryEntry.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertEqual(altered.id, fixture.entry.id)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let changed = await fixture.coordinator.prepareWorkout(altered,
            acknowledgedHistory: [altered], request: request)
        let duplicate = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry, fixture.entry], request: request)
        XCTAssertNil(changed)
        XCTAssertNil(duplicate)
        XCTAssertEqual(try Data(contentsOf: fixture.historyDirectory.appendingPathComponent("history.json")), before)
        let exact = try await presentation(fixture)
        let allowed = await fixture.coordinator.authorize(exact)
        XCTAssertTrue(allowed)
    }

    func testUnknownStoreProvenanceDeniesDespiteAvailableRegisteredActualStores() async throws {
        let fixture = try await fixture(ownsAuditedStores: false); defer { fixture.cleanup() }
        XCTAssertTrue(fixture.profile.isAvailable)
        XCTAssertTrue(fixture.parent.hasMatchingOwnerRegistrations)
        XCTAssertTrue(fixture.outdoor.canShareSavedRecords)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let denied = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(denied)
    }

    func testUnknownParentProfileProvenanceDeniesAvailableCompletedProfile() async throws {
        let fixture = try await fixture(hasAuditedProfileStore: false); defer { fixture.cleanup() }
        XCTAssertTrue(fixture.profile.isAvailable)
        XCTAssertEqual(fixture.profile.rootRoute, .appShell)
        XCTAssertFalse(fixture.parent.hasAuditedProfileStore)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let denied = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(denied)
    }

    func testRemovingActualImportOwnerRegistrationRevokesAndBlocksUntilReinstalled() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        fixture.historyImport.installShareRevocationRegistration(nil)
        XCTAssertFalse(old.lifetime.allows(old.id))
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let denied = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(denied)
        fixture.historyImport.installShareRevocationRegistration(fixture.parent.registration)
        let fresh = try await presentation(fixture)
        let freshAllowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(freshAllowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testInactiveAndProtectedDataObservationTransitionsDenyAndNeverReviveOldPermit() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        fixture.observation.transition(to: .inactive, protectedData: true)
        XCTAssertFalse(old.lifetime.allows(old.id))
        let inactiveRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        let inactive = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: inactiveRequest)
        XCTAssertNil(inactive)
        fixture.observation.transition(to: .active, protectedData: false)
        let lockedRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        let locked = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: lockedRequest)
        XCTAssertNil(locked)
        fixture.observation.transition(to: .active, protectedData: true)
        let fresh = try await presentation(fixture)
        let freshAllowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(freshAllowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testRetainedActualUIKitObserversSynchronouslyRevokeOnPostedLifecycleEvents() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification,
                     UIApplication.willTerminateNotification] {
            let old = try await presentation(fixture)
            let generation = fixture.parent.registry.currentGeneration
            NotificationCenter.default.post(name: name, object: nil)
            // No yield/Task/dispatch is needed for the actual retained observer.
            XCTAssertFalse(old.lifetime.allows(old.id))
            XCTAssertNotEqual(fixture.parent.registry.currentGeneration, generation)
        }
    }

    func testSuspendAndReappearRequiresNewOriginalRequestWithSameOwners() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let oldRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        fixture.coordinator.suspend()
        XCTAssertNil(fixture.coordinator.beginRequest())
        XCTAssertFalse(old.lifetime.allows(old.id))
        fixture.installContext(on: fixture.coordinator)
        let stale = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: oldRequest)
        XCTAssertNil(stale)
        let newRequest = try XCTUnwrap(fixture.coordinator.beginRequest())
        XCTAssertNotEqual(newRequest, oldRequest)
        let fresh = try await presentation(fixture)
        let allowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(allowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testOldRootRetireSuspendAndExactCloseCannotRevokeNewRootPermit() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let oldRoot = fixture.coordinator
        let old = try await presentation(fixture)
        let newRoot = ZeroOneRootShareCoordinator(parent: fixture.parent)
        fixture.installContext(on: newRoot)
        let installed = await newRoot.installOutdoorOwners()
        XCTAssertTrue(installed)
        let new = try await presentation(fixture, coordinator: newRoot)
        XCTAssertFalse(old.lifetime.allows(old.id))
        oldRoot.retire()
        oldRoot.suspend()
        oldRoot.close(old)
        XCTAssertTrue(new.lifetime.allows(new.id))
        let allowed = await newRoot.authorize(new)
        XCTAssertTrue(allowed)
        XCTAssertNil(oldRoot.beginRequest())
    }

    func testExactOwnerReplacementRevokesOldPermitWithByteIdenticalHistory() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let previousOwner = fixture.history
        let replacement = WorkoutHistoryRepository(store: fixture.historyStore)
        // An actual installation revokes the same registry before publishing ownership.
        replacement.installShareRevocationRegistration(fixture.parent.registration)
        fixture.history = replacement
        XCTAssertFalse(previousOwner === replacement)
        XCTAssertEqual(try replacement.confirmedEntries(), [fixture.entry])
        XCTAssertFalse(old.lifetime.allows(old.id))
        let fresh = try await presentation(fixture)
        let oldAllowed = await fixture.coordinator.authorize(old)
        let freshAllowed = await fixture.coordinator.authorize(fresh)
        XCTAssertFalse(oldAllowed)
        XCTAssertTrue(freshAllowed)
    }

    func testActualActiveSnapshotPresenceDeniesUntilAcknowledgedTombstone() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        let snapshot = ActiveWorkoutSnapshot(session: fixture.session, enteredLoadValue: 42,
            enteredReps: 8, enteredRIR: 2, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        try fixture.activeStore.save(snapshot)
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertEqual(try fixture.activeStore.load()?.session.id, fixture.session.id)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let denied = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(denied)
        try fixture.activeStore.clear(expectedSessionID: fixture.session.id)
        XCTAssertNil(try fixture.activeStore.load())
        let fresh = try await presentation(fixture)
        let allowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(allowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testPersistedProfileMismatchDeniesUntilActualOwnerReload() async throws {
        let fixture = try await fixture(); defer { fixture.cleanup() }
        let old = try await presentation(fixture)
        var replacement = fixture.profile.profile
        replacement.displayName = "Another synthetic local profile value"
        // This test simulates an external source transition, never fake readiness.
        fixture.parent.registration.revokeBeforeChange()
        fixture.profileStore.save(replacement)
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertNotEqual(try fixture.profile.profileForExport(), fixture.profile.profile)
        let request = try XCTUnwrap(fixture.coordinator.beginRequest())
        let denied = await fixture.coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: [fixture.entry], request: request)
        XCTAssertNil(denied)
        XCTAssertTrue(fixture.profile.reload())
        let fresh = try await presentation(fixture)
        let allowed = await fixture.coordinator.authorize(fresh)
        XCTAssertTrue(allowed)
        XCTAssertFalse(old.lifetime.allows(old.id))
    }

    func testPhotoAuditedReadinessDoesNotRetainCoordinatorOrParentAfterTeardown() async throws {
        var fixture: Fixture? = try await self.fixture()
        let directory = try XCTUnwrap(fixture?.directory)
        let defaults = try XCTUnwrap(fixture?.defaults)
        let suiteName = try XCTUnwrap(fixture?.suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try fixture!.savePhoto(at: Self.date, color: .black)
        let second = try fixture!.savePhoto(at: Self.date.addingTimeInterval(60), color: .white)
        let host = fixture!.photoHost
        let request = try XCTUnwrap(fixture!.coordinator.beginRequest())
        let prepared = await fixture!.coordinator.preparePhoto(first: first, second: second,
            host: host, request: request)
        let photo = try XCTUnwrap(prepared)
        XCTAssertTrue(photo.lifetime.allows(photo.id))
        XCTAssertNotNil(host.freshSource(photo.source, for: photo))
        weak var weakCoordinator = fixture!.coordinator
        weak var weakParent = fixture!.parent
        fixture = nil
        XCTAssertNil(weakCoordinator)
        XCTAssertNil(weakParent)
        XCTAssertFalse(photo.lifetime.allows(photo.id))
        XCTAssertNil(host.freshSource(photo.source, for: photo))
    }

    private static var date: Date { Date(timeIntervalSinceReferenceDate: 2_000_000) }

    private static func completedSession(at completedAt: Date) -> WorkoutSession {
        let set = CompletedSet(load: Load(42), reps: 8, rir: 2,
            completedAt: completedAt.addingTimeInterval(-10))
        let plan = ExercisePlan(name: "Synthetic bench press", targetLoad: set.load,
            targetReps: RepRange(8, 8), plannedSetCount: 1, restSeconds: 90,
            previousPerformance: [])
        return WorkoutSession(title: "Synthetic coordinator workout",
            customWorkoutID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            exercises: [WorkoutExercise(plan: plan, completedSets: [set])],
            completedAt: completedAt)
    }

    private func fixture(ownsAuditedStores: Bool = true,
                         hasAuditedProfileStore: Bool = true) async throws -> Fixture {
        let fixture = try Fixture(session: Self.completedSession(at: Self.date),
            ownsAuditedStores: ownsAuditedStores, hasAuditedProfileStore: hasAuditedProfileStore)
        fixture.installContext(on: fixture.coordinator)
        let installed = await fixture.coordinator.installOutdoorOwners()
        XCTAssertTrue(installed)
        await fixture.outdoor.load()
        return fixture
    }

    private func presentation(_ fixture: Fixture,
                              coordinator: ZeroOneRootShareCoordinator? = nil) async throws -> ZeroOneRootSharePresentation {
        let coordinator = coordinator ?? fixture.coordinator
        let request = try XCTUnwrap(coordinator.beginRequest())
        let prepared = await coordinator.prepareWorkout(fixture.entry,
            acknowledgedHistory: try fixture.history.confirmedEntries(), request: request)
        return try XCTUnwrap(prepared)
    }

    @MainActor
    private final class ObservedLifecycle: ZeroOneShareLifecycleObservation {
        private let registry: ZeroOneSharePermitRegistry
        private(set) var applicationState: UIApplication.State = .active
        private(set) var isProtectedDataAvailable = true

        init(registry: ZeroOneSharePermitRegistry) { self.registry = registry }

        func transition(to applicationState: UIApplication.State, protectedData: Bool) {
            registry.revocationRegistration.revokeBeforeChange()
            self.applicationState = applicationState
            isProtectedDataAvailable = protectedData
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let historyDirectory: URL
        let suiteName: String
        let defaults: UserDefaults
        let session: WorkoutSession
        let entry: WorkoutHistoryEntry
        let account: ZeroOneAccountStore
        let profileStore: UserDefaultsZeroOneUserProfileStore
        let profile: ZeroOneUserProfileRepository
        let parent: ZeroOneShareParentLifetime
        let observation: ObservedLifecycle
        let coordinator: ZeroOneRootShareCoordinator
        let historyStore: FileWorkoutHistoryStore
        var history: WorkoutHistoryRepository
        let historyImport: WorkoutHistoryImportCoordinator
        let savedAuthority: SavedWorkoutHistoryShareAuthority
        let activeStore: FileActiveWorkoutStore
        let workout: WorkoutViewModel
        let photoStore: LocalProgressPhotoStore
        let photos: ProgressPhotoRepository
        let photoHost: PhotoComparisonShareHostAuthority
        let outdoorRepository: OutdoorActivityRepository
        let outdoor: OutdoorActivityViewModel
        let outdoorTransfer: OutdoorHistoryTransferCoordinator
        let ownsAuditedStores: Bool
        private(set) var facts = ZeroOneRootShareFacts(selectedTab: .workout,
            showsProfile: true, showsOutdoor: false, hasActiveWorkoutRoute: false,
            recoveryFailed: false, scenePhase: .active)

        init(session: WorkoutSession, ownsAuditedStores: Bool, hasAuditedProfileStore: Bool) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RootShareCoordinator-" + UUID().uuidString, isDirectory: true)
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suiteName = "RootShareCoordinator." + UUID().uuidString
            self.suiteName = suiteName
            guard let testDefaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileWriteUnknown) }
            defaults = testDefaults
            self.session = session
            let entry = WorkoutHistoryEntry(session: session)
            self.entry = entry
            self.ownsAuditedStores = ownsAuditedStores
            let account = ZeroOneAccountStore(configuration: nil, service: nil,
                persistence: KeychainZeroOneAccountStore(namespace: suiteName), defaults: testDefaults)
            self.account = account
            let profileStore = UserDefaultsZeroOneUserProfileStore(defaults: testDefaults, key: "test.profile")
            self.profileStore = profileStore
            var completedProfile = ZeroOneUserProfile()
            completedProfile.onboardingComplete = true
            completedProfile.displayName = "Synthetic local profile"
            profileStore.save(completedProfile)
            let profile = ZeroOneUserProfileRepository(store: profileStore)
            self.profile = profile
            let registry = ZeroOneSharePermitRegistry()
            let observation = ObservedLifecycle(registry: registry)
            self.observation = observation
            let parent = ZeroOneShareParentLifetime(account: account, profile: profile,
                hasAuditedProfileStore: hasAuditedProfileStore, registry: registry,
                testingLifecycle: observation)
            self.parent = parent
            let registration = parent.registration
            coordinator = ZeroOneRootShareCoordinator(parent: parent)
            let historyDirectory = directory.appendingPathComponent("workout", isDirectory: true)
            self.historyDirectory = historyDirectory
            let historyStore = FileWorkoutHistoryStore(directory: historyDirectory,
                legacyStore: UserDefaultsWorkoutHistoryStore(defaults: testDefaults, key: "test.legacyHistory"))
            self.historyStore = historyStore
            try historyStore.save([entry])
            let history = WorkoutHistoryRepository(store: historyStore)
            self.history = history
            history.installShareRevocationRegistration(registration)
            let historyImport = WorkoutHistoryImportCoordinator(store: historyStore, canImport: { false })
            self.historyImport = historyImport
            historyImport.installShareRevocationRegistration(registration)
            let savedAuthority = SavedWorkoutHistoryShareAuthority()
            self.savedAuthority = savedAuthority
            savedAuthority.installShareRevocationRegistration(registration)
            let activeStore = FileActiveWorkoutStore(directory: historyDirectory,
                legacyStore: UserDefaultsActiveWorkoutStore(defaults: testDefaults, key: "test.legacyActive",
                    shareRevocationRegistration: registration), shareRevocationRegistration: registration)
            self.activeStore = activeStore
            workout = WorkoutViewModel(session: session, persistInitialSnapshot: false,
                onSnapshotChanged: { snapshot, id in
                    if let snapshot { try activeStore.save(snapshot) }
                    else { try activeStore.clear(expectedSessionID: id) }
                }, onSessionCompleted: { try history.record($0) },
                shareRevocationRegistration: registration)
            let photoStore = LocalProgressPhotoStore(rootURL: directory.appendingPathComponent("photos", isDirectory: true))
            self.photoStore = photoStore
            let photos = ProgressPhotoRepository(store: photoStore)
            self.photos = photos
            photos.installShareRevocationRegistration(registration)
            photoHost = PhotoComparisonShareHostAuthority(store: photoStore)
            let outdoorRepository = OutdoorActivityRepository(directory: directory.appendingPathComponent("outdoor", isDirectory: true))
            self.outdoorRepository = outdoorRepository
            outdoor = OutdoorActivityViewModel(repository: outdoorRepository)
            let outdoorTransfer = OutdoorHistoryTransferCoordinator(repository: outdoorRepository, canTransfer: { false })
            self.outdoorTransfer = outdoorTransfer
            outdoorTransfer.installShareRevocationRegistration(registration)
        }

        var context: ZeroOneRootShareContext {
            ZeroOneRootShareContext(facts: facts, workout: workout, history: history,
                historyImport: historyImport, savedHistoryAuthority: savedAuthority,
                photos: photos, photoHost: photoHost, outdoor: outdoor,
                outdoorRepository: outdoorRepository, outdoorTransfer: outdoorTransfer,
                activeStore: activeStore, ownsAuditedStores: ownsAuditedStores)
        }

        func installContext(on coordinator: ZeroOneRootShareCoordinator) {
            coordinator.installContext { [weak self] in self?.context }
        }

        func showOutdoor() {
            coordinator.revokeBeforeRouteChange()
            facts = ZeroOneRootShareFacts(selectedTab: .today, showsProfile: false,
                showsOutdoor: true, hasActiveWorkoutRoute: false, recoveryFailed: false,
                scenePhase: .active)
        }

        func saveOutdoorActivity() async throws -> OutdoorActivityRecord {
            let recorder = OutdoorActivityRecorder(repository: outdoorRepository)
            await recorder.installShareRevocationRegistration(parent.registration)
            let monotonic = ContinuousClock.now
            _ = try await recorder.start(kind: .walk, trackingMode: .timerOnly,
                at: ZeroOneRootShareCoordinatorTests.date, monotonic: monotonic)
            _ = try await recorder.finish(at: ZeroOneRootShareCoordinatorTests.date.addingTimeInterval(20),
                monotonic: monotonic.advanced(by: .seconds(20)))
            let records = try await outdoorRepository.loadRecords()
            return try XCTUnwrap(records.first)
        }

        func savePhoto(at date: Date, color: UIColor) throws -> ProgressPhotoRecord {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 1))
            let draft = ProgressPhotoDraft(id: UUID(), createdAt: date, label: .progress,
                imageData: bytes, thumbnailData: bytes)
            return try photos.save(draft)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
#endif
