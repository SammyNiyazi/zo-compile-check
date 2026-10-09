import Foundation
import SwiftUI

/// Actual mounted Root facts. These describe routing only; the coordinator reads
/// the retained owners and persistence itself before admitting any presentation.
struct ZeroOneRootShareFacts: Equatable {
    let selectedTab: AppTab
    let showsProfile: Bool
    let showsOutdoor: Bool
    let hasActiveWorkoutRoute: Bool
    let recoveryFailed: Bool
    let scenePhase: ScenePhase
}

@MainActor
struct ZeroOneRootShareContext {
    let facts: ZeroOneRootShareFacts
    let workout: WorkoutViewModel
    let history: WorkoutHistoryRepository
    let historyImport: WorkoutHistoryImportCoordinator
    let savedHistoryAuthority: SavedWorkoutHistoryShareAuthority
    let photos: ProgressPhotoRepository
    let photoHost: PhotoComparisonShareHostAuthority
    let outdoor: OutdoorActivityViewModel
    let outdoorRepository: OutdoorActivityRepository
    let outdoorTransfer: OutdoorHistoryTransferCoordinator
    let activeStore: any ActiveWorkoutPersisting
    /// True only for the concrete stores constructed by this retained assembly.
    /// Supplied/custom stores keep their domain behavior but cannot acquire export.
    let ownsAuditedStores: Bool

    func hasSameOwners(as other: Self) -> Bool {
        workout === other.workout && history === other.history
            && historyImport === other.historyImport && savedHistoryAuthority === other.savedHistoryAuthority
            && photos === other.photos && photoHost === other.photoHost
            && outdoor === other.outdoor && outdoorRepository === other.outdoorRepository
            && outdoorTransfer === other.outdoorTransfer
    }
}

enum ZeroOneRootShareSource: Equatable {
    case workout(WorkoutHistoryEntry, [WorkoutHistoryEntry])
    case outdoor(OutdoorActivityRecord)
    case photos
}

/// A route owns this exact handle. Retained destination objects need only its
/// permanent lifetime; they cannot re-open registry admission or source authority.
final class ZeroOneRootSharePresentation: Identifiable {
    let id: UUID
    let lifetime: ZOShareExportLifetime
    fileprivate let source: ZeroOneRootShareSource
    fileprivate let review: ZeroOneRootShareCoordinator.Review
    private let registry: ZeroOneSharePermitRegistry
    private let handle: ZeroOneSharePermitRegistry.Registration

    fileprivate init(id: UUID, lifetime: ZOShareExportLifetime,
                     source: ZeroOneRootShareSource, review: ZeroOneRootShareCoordinator.Review,
                     registry: ZeroOneSharePermitRegistry, handle: ZeroOneSharePermitRegistry.Registration) {
        self.id = id; self.lifetime = lifetime; self.source = source; self.review = review
        self.registry = registry; self.handle = handle
    }

    func invalidate() {
        lifetime.invalidate()
        registry.remove(handle)
    }

    deinit { invalidate() }
}

@MainActor
final class ZeroOneRootShareCoordinator: ObservableObject {
    struct Request: Equatable {
        fileprivate let rootID: UUID
        fileprivate let routeRevision: UUID
    }

    /// Weak references preserve exact object identity without retaining a host
    /// through the readiness closure that the same host owns.
    @MainActor
    final class Owners {
        weak var workout: WorkoutViewModel?
        weak var history: WorkoutHistoryRepository?
        weak var historyImport: WorkoutHistoryImportCoordinator?
        weak var savedHistoryAuthority: SavedWorkoutHistoryShareAuthority?
        weak var photos: ProgressPhotoRepository?
        weak var photoHost: PhotoComparisonShareHostAuthority?
        weak var outdoor: OutdoorActivityViewModel?
        weak var outdoorRepository: OutdoorActivityRepository?
        weak var outdoorTransfer: OutdoorHistoryTransferCoordinator?

        init(_ context: ZeroOneRootShareContext) {
            workout = context.workout; history = context.history
            historyImport = context.historyImport; savedHistoryAuthority = context.savedHistoryAuthority
            photos = context.photos; photoHost = context.photoHost
            outdoor = context.outdoor; outdoorRepository = context.outdoorRepository
            outdoorTransfer = context.outdoorTransfer
        }

        func matches(_ current: ZeroOneRootShareContext) -> Bool {
            workout === current.workout && history === current.history
                && historyImport === current.historyImport && savedHistoryAuthority === current.savedHistoryAuthority
                && photos === current.photos && photoHost === current.photoHost
                && outdoor === current.outdoor && outdoorRepository === current.outdoorRepository
                && outdoorTransfer === current.outdoorTransfer
        }
    }

    @MainActor
    struct Review {
        let generation: ZeroOneSharePermitRegistry.Generation
        let request: Request
        let owners: Owners
        let facts: ZeroOneRootShareFacts
        let photoRevision: UUID?

        init(generation: ZeroOneSharePermitRegistry.Generation, request: Request,
             context: ZeroOneRootShareContext, photoRevision: UUID? = nil) {
            self.generation = generation; self.request = request
            owners = Owners(context); facts = context.facts
            self.photoRevision = photoRevision
        }
    }

    let rootID = UUID()
    let parent: ZeroOneShareParentLifetime?
    private let rootGate: ZeroOneShareRootGate?
    private var routeRevision = UUID()
    private var context: (@MainActor () -> ZeroOneRootShareContext?)?
    private var installedOutdoor: (OutdoorActivityRepository, OutdoorActivityViewModel)?

    init(parent: ZeroOneShareParentLifetime?) {
        self.parent = parent
        rootGate = parent?.rootGate
        rootGate?.claim(rootID)
    }

    var registration: ZeroOneShareRevocationRegistration? { parent?.registration }

    /// Install after SwiftUI State is mounted. The content's coordinator field is
    /// weak, so this closure does not retain this coordinator through its content.
    func installContext(_ context: @escaping @MainActor () -> ZeroOneRootShareContext?) {
        guard parent?.rootGate.isCurrent(rootID) == true else { return }
        // Owned covers can report another onAppear while this mounted provider
        // is still valid. Its State-backed reads already follow model changes;
        // reinstalling here must not revoke a newly presented child permit.
        guard self.context == nil else { return }
        revokeBeforeRouteChange()
        self.context = context
    }

    func beginRequest() -> Request? {
        guard rootGate?.isCurrent(rootID) == true, context?() != nil else { return nil }
        return Request(rootID: rootID, routeRevision: routeRevision)
    }

    func isCurrent(_ request: Request) -> Bool {
        request.rootID == rootID && request.routeRevision == routeRevision
            && rootGate?.isCurrent(rootID) == true
    }

    func revokeBeforeRouteChange() {
        routeRevision = UUID()
        rootGate?.revokeIfCurrent(rootID)
    }

    /// SwiftUI may report disappearance while retaining this storage under a
    /// cover. Reappearance may reinstall context only if no newer root claimed it.
    func suspend() {
        revokeBeforeRouteChange()
        context = nil
    }

    func retire() {
        routeRevision = UUID()
        rootGate?.retireIfCurrent(rootID)
        context = nil
    }

    deinit { rootGate?.retireIfCurrent(rootID) }

    /// Installation completes while admission is closed. The actual VM forwards
    /// installation into its private recorder; no second recorder/store is made.
    @discardableResult
    func installOutdoorOwners() async -> Bool {
        guard let parent, let initial = context?(), parent.rootGate.isCurrent(rootID),
              let installationRequest = beginRequest(), syncRegistrationsMatch(initial) else { return false }
        if let installedOutdoor, installedOutdoor.0 === initial.outdoorRepository,
           installedOutdoor.1 === initial.outdoor {
            return true
        }
        parent.registry.revokeAll()
        await initial.outdoorRepository.installShareRevocationRegistration(parent.registration)
        guard isCurrent(installationRequest), installationStillCurrent(initial) else { return false }
        await initial.outdoor.installShareRevocationRegistration(parent.registration)
        guard isCurrent(installationRequest), installationStillCurrent(initial) else { return false }
        let repositoryMatches = await initial.outdoorRepository.isShareRevocationRegistered(parent.registration)
        guard repositoryMatches, isCurrent(installationRequest), installationStillCurrent(initial) else { return false }
        let recorderMatches = await initial.outdoor.isShareRevocationRegistered(parent.registration)
        guard recorderMatches, isCurrent(installationRequest), installationStillCurrent(initial) else { return false }
        installedOutdoor = (initial.outdoorRepository, initial.outdoor)
        return true
    }

    func prepareWorkout(_ entry: WorkoutHistoryEntry,
                        acknowledgedHistory: [WorkoutHistoryEntry],
                        request: Request) async -> ZeroOneRootSharePresentation? {
        await prepare(.workout(entry, acknowledgedHistory), request: request)
    }

    func prepareOutdoor(_ record: OutdoorActivityRecord, request: Request) async -> ZeroOneRootSharePresentation? {
        await prepare(.outdoor(record), request: request)
    }

    func authorize(_ presentation: ZeroOneRootSharePresentation) async -> Bool {
        guard presentation.lifetime.allows(presentation.id), stillCurrent(presentation.review) else { return false }
        guard await audit(presentation.source, review: presentation.review) else { return false }
        return presentation.lifetime.allows(presentation.id) && stillCurrent(presentation.review)
    }

    func close(_ presentation: ZeroOneRootSharePresentation) { presentation.invalidate() }

    func preparePhoto(first: ProgressPhotoRecord, second: ProgressPhotoRecord,
                      host: PhotoComparisonShareHostAuthority,
                      request: Request) async -> PhotoComparisonShareHostAuthority.Presentation? {
        let selectedRevision = host.revision
        guard let parent, isCurrent(request), await installOutdoorOwners(), isCurrent(request), let current = context?(),
              current.photoHost === host, host.revision == selectedRevision else { return nil }
        let review = Review(generation: parent.registry.currentGeneration, request: request,
                            context: current, photoRevision: selectedRevision)
        guard await audit(.photos, review: review), stillCurrent(review),
              parent.registry.activate(review.generation) else { return nil }
        // These two synchronous host configuration operations intentionally
        // advance its revision. All suspended selection checks are now finished.
        // Keep the SAME audited generation/owners/route; host.prepare checks its
        // new revision through both exact manifest/master reads and publication.
        let publicationReview = Review(generation: review.generation, request: request, context: current)
        host.installSharePermitRegistry(parent.registry, for: review.generation)
        host.installAuditedReadiness { [weak self] in self?.stillCurrent(publicationReview) == true }
        guard stillCurrent(publicationReview), let presentation = try? host.prepare(first: first, second: second) else { return nil }
        guard stillCurrent(publicationReview), presentation.lifetime.allows(presentation.id) else {
            host.close(presentation)
            return nil
        }
        return presentation
    }

    private func prepare(_ source: ZeroOneRootShareSource, request: Request) async -> ZeroOneRootSharePresentation? {
        guard let parent, isCurrent(request), await installOutdoorOwners(), isCurrent(request),
              let current = context?() else { return nil }
        // Never recapture this generation after an await or a failed read.
        let review = Review(generation: parent.registry.currentGeneration, request: request, context: current)
        guard await audit(source, review: review), stillCurrent(review),
              parent.registry.activate(review.generation) else { return nil }
        let id = UUID()
        let lifetime = ZOShareExportLifetime(sourceVersion: id)
        guard let handle = parent.registry.register(lifetime, for: review.generation) else { return nil }
        let presentation = ZeroOneRootSharePresentation(id: id, lifetime: lifetime, source: source,
            review: review, registry: parent.registry, handle: handle)
        guard stillCurrent(review), lifetime.allows(id) else {
            presentation.invalidate()
            return nil
        }
        return presentation
    }

    private func audit(_ source: ZeroOneRootShareSource, review: Review) async -> Bool {
        guard let parent, stillCurrent(review), let current = context?(),
              routeAllows(source, in: current) else { return false }
        let repositoryRegistered = await current.outdoorRepository.isShareRevocationRegistered(parent.registration)
        guard repositoryRegistered, stillCurrent(review) else { return false }
        let recorderRegistered = await current.outdoor.isShareRevocationRegistered(parent.registration)
        guard recorderRegistered, stillCurrent(review) else { return false }
        let recorderReady = await current.outdoor.confirmsRecorderShareReadiness()
        guard recorderReady, stillCurrent(review) else { return false }
        let unconfirmed = await current.outdoorRepository.hasUnconfirmedHistoryTransfer
        guard !unconfirmed, stillCurrent(review) else { return false }
        do {
            let checkpoint = try await current.outdoorRepository.loadCheckpoint()
            guard checkpoint == nil, stillCurrent(review) else { return false }
            switch source {
            case let .workout(entry, history):
                guard history.filter({ $0.id == entry.id }) == [entry],
                      try current.history.confirmedEntries() == history else { return false }
            case let .outdoor(record):
                let observation = try await current.outdoorRepository.loadRecommendationObservation()
                guard stillCurrent(review), observation.records.filter({ $0.id == record.id }) == [record],
                      current.outdoorRepository.confirmsRecommendationSource(observation.source) else { return false }
            case .photos:
                // The exact selected manifest/master-byte passes are performed
                // by the retained actual photo host immediately before publish.
                break
            }
        } catch { return false }
        return stillCurrent(review) && routeAllows(source, in: current)
    }

    private func routeAllows(_ source: ZeroOneRootShareSource, in context: ZeroOneRootShareContext) -> Bool {
        switch source {
        case let .workout(entry, _):
            return context.facts.showsProfile || (context.facts.selectedTab == .workout
                && context.facts.hasActiveWorkoutRoute && context.workout.isCompletionSaved
                && context.workout.session.id == entry.id)
        case .outdoor: return context.facts.showsOutdoor
        case .photos: return context.facts.showsProfile
        }
    }

    private func installationStillCurrent(_ expected: ZeroOneRootShareContext) -> Bool {
        guard let parent, parent.rootGate.isCurrent(rootID), let current = context?() else { return false }
        return current.hasSameOwners(as: expected) && current.facts == expected.facts && syncRegistrationsMatch(current)
    }

    private func syncRegistrationsMatch(_ current: ZeroOneRootShareContext) -> Bool {
        guard let parent else { return false }
        let registration = parent.registration
        return parent.hasMatchingOwnerRegistrations
            && current.workout.isShareRevocationRegistered(registration)
            && current.history.isShareRevocationRegistered(registration)
            && current.historyImport.isShareRevocationRegistered(registration)
            && current.savedHistoryAuthority.isShareRevocationRegistered(registration)
            && current.photos.isShareRevocationRegistered(registration)
            && current.outdoorTransfer.isShareRevocationRegistered(registration)
    }

    private func stillCurrent(_ review: Review) -> Bool {
        guard let parent, isCurrent(review.request),
              parent.registry.currentGeneration == review.generation,
              parent.hasAuditedProfileStore, parent.hasLifecycleObserversInstalled,
              parent.isApplicationActive, parent.isProtectedDataAvailable,
              !parent.account.isBusy, parent.profile.isAvailable, parent.profile.rootRoute == .appShell,
              let current = context?(), current.ownsAuditedStores,
              review.owners.matches(current), current.facts == review.facts,
              review.photoRevision == nil || current.photoHost.revision == review.photoRevision,
              current.facts.scenePhase == .active, !current.facts.recoveryFailed,
              syncRegistrationsMatch(current), current.workout.persistenceErrorMessage == nil,
              current.outdoor.canShareSavedRecords, !current.historyImport.needsReconciliation,
              !current.outdoorTransfer.isBusy, !current.outdoorTransfer.needsReconciliation,
              !current.facts.hasActiveWorkoutRoute || current.workout.isCompletionSaved,
              !Task.isCancelled else { return false }
        do {
            guard try current.activeStore.load() == nil,
                  try parent.profile.profileForExport() == parent.profile.profile else { return false }
        } catch { return false }
        // Reads must not have changed the captured registration/source generation.
        return parent.registry.currentGeneration == review.generation && parent.rootGate.isCurrent(rootID)
    }
}

private struct ZeroOneRootShareCoordinatorKey: EnvironmentKey {
    static let defaultValue: ZeroOneRootShareCoordinator? = nil
}

extension EnvironmentValues {
    var zeroOneRootShareCoordinator: ZeroOneRootShareCoordinator? {
        get { self[ZeroOneRootShareCoordinatorKey.self] }
        set { self[ZeroOneRootShareCoordinatorKey.self] = newValue }
    }
}
