import Foundation
import SwiftUI
import UIKit

#if DEBUG
/// XCTest may supply observed OS facts while keeping the complete actual owner,
/// registration, route and persisted-source audit. Release always reads UIKit.
@MainActor
protocol ZeroOneShareLifecycleObservation: AnyObject {
    var applicationState: UIApplication.State { get }
    var isProtectedDataAvailable: Bool { get }
}
#endif

/// Mounted parent identity owns the actual observable models and synchronous
/// revocation capability. No property here grants source/export admission.
@MainActor
final class ZeroOneShareParentLifetime: ObservableObject {
    let account: ZeroOneAccountStore
    let profile: ZeroOneUserProfileRepository
    let registry: ZeroOneSharePermitRegistry
    let rootGate: ZeroOneShareRootGate
    let hasAuditedProfileStore: Bool
    private let lifecycle: ZeroOneShareLifecycleObservers
    #if DEBUG
    private var testingLifecycle: (any ZeroOneShareLifecycleObservation)?
    #endif

    var registration: ZeroOneShareRevocationRegistration {
        registry.revocationRegistration
    }

    init(account: ZeroOneAccountStore, profile: ZeroOneUserProfileRepository,
         hasAuditedProfileStore: Bool, registry: ZeroOneSharePermitRegistry = ZeroOneSharePermitRegistry()) {
        self.account = account
        self.profile = profile
        self.registry = registry
        self.hasAuditedProfileStore = hasAuditedProfileStore
        rootGate = ZeroOneShareRootGate(registry: registry)
        lifecycle = ZeroOneShareLifecycleObservers(registry: registry)
        account.installShareRevocationRegistration(registry.revocationRegistration)
        profile.installShareRevocationRegistration(registry.revocationRegistration)
    }

    var hasMatchingOwnerRegistrations: Bool {
        account.isShareRevocationRegistered(registration)
            && profile.isShareRevocationRegistered(registration)
    }

    var hasLifecycleObserversInstalled: Bool { lifecycle.isInstalled }

    #if DEBUG
    convenience init(account: ZeroOneAccountStore, profile: ZeroOneUserProfileRepository,
                     hasAuditedProfileStore: Bool, registry: ZeroOneSharePermitRegistry,
                     testingLifecycle: any ZeroOneShareLifecycleObservation) {
        self.init(account: account, profile: profile,
                  hasAuditedProfileStore: hasAuditedProfileStore, registry: registry)
        self.testingLifecycle = testingLifecycle
    }
    #endif

    // Read current UIKit state on MainActor at each Root audit. Never cache a
    // readiness true across scene/protected-data transitions.
    var isApplicationActive: Bool {
        #if DEBUG
        if let testingLifecycle { return testingLifecycle.applicationState == .active }
        #endif
        return UIApplication.shared.applicationState == .active
    }
    var isProtectedDataAvailable: Bool {
        #if DEBUG
        if let testingLifecycle { return testingLifecycle.isProtectedDataAvailable }
        #endif
        return UIApplication.shared.isProtectedDataAvailable
    }

    deinit { registry.invalidatePermanently() }
}

/// Only stale Root cleanup is conditional on identity. Actual mutation owners
/// always revoke the shared registry directly, including pending old owners.
/// The lock keeps identity comparison, revocation and identity storage ordered.
/// Registry tokens must not call this gate from their invalidation callbacks.
final class ZeroOneShareRootGate: @unchecked Sendable {
    private let registry: ZeroOneSharePermitRegistry
    private let lock = NSLock()
    private var currentRootID: UUID?

    init(registry: ZeroOneSharePermitRegistry) { self.registry = registry }

    func claim(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        registry.revokeAll()
        currentRootID = id
    }

    func retireIfCurrent(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard currentRootID == id else { return }
        registry.revokeAll()
        currentRootID = nil
    }

    func revokeIfCurrent(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard currentRootID == id else { return }
        registry.revokeAll()
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentRootID == id
    }
}

/// Retained nonactor observer owner. Immutable tokens/center/registry are safe
/// for teardown on any thread. queue:nil callbacks synchronously revoke and
/// capture only the immutable registry, without UI reads or an actor/Task hop.
private final class ZeroOneShareLifecycleObservers: @unchecked Sendable {
    private let registry: ZeroOneSharePermitRegistry
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    @MainActor
    init(registry: ZeroOneSharePermitRegistry, center: NotificationCenter = .default) {
        self.registry = registry
        self.center = center
        tokens = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.willTerminateNotification
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [registry] _ in
                registry.revokeAll()
            }
        }
    }

    var isInstalled: Bool { tokens.count == 4 }

    // Teardown permanently retires the parent registry before releasing the
    // notification registrations. An overlapping callback can only revoke it.
    deinit {
        registry.invalidatePermanently()
        for token in tokens { center.removeObserver(token) }
    }
}
