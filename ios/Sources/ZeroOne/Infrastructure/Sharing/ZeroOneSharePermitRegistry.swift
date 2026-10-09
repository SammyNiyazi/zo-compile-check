import Foundation

/// A retained token whose valid state can change only to permanently invalid.
/// `invalidate` must synchronously make all subsequent token checks fail before
/// returning, including repeated/concurrent calls. Implementations must protect
/// their own state and must not read UI/actor state, await, dispatch work, mutate
/// an authority owner or recursively invoke a revocation registration.
/// Conformance is an audited contract; Sendable alone cannot enforce it.
protocol ZeroOneShareRevocablePermit: AnyObject, Sendable {
    func invalidate()
}

/// Synchronous retention and generation admission, never source authorization.
/// Root must explicitly activate a captured generation only after installing
/// and auditing every actual authority/readiness hook. Starts closed. A revoke
/// closes admission and changes generation; reinstalling cannot revive tokens.
/// A Registration is a removal handle, NOT evidence that a permit is still valid.
final class ZeroOneSharePermitRegistry: Sendable {
    struct Generation: Equatable, Sendable {
        fileprivate let registryID: UUID
        fileprivate let revision: UUID
    }

    struct Registration: Equatable, Sendable {
        fileprivate let registryID: UUID
        fileprivate let id: UUID
    }

    private let storage: Storage
    /// Install this exact retained instance into all audited mutation owners.
    /// Its immutable callback directly revokes retained permits on any thread.
    let revocationRegistration: ZeroOneShareRevocationRegistration

    init() {
        let storage = Storage()
        self.storage = storage
        revocationRegistration = ZeroOneShareRevocationRegistration {
            storage.revoke(permanently: false)
        }
    }

    deinit { storage.revoke(permanently: true) }

    var currentGeneration: Generation { storage.currentGeneration }

    /// A stale/foreign generation cannot reopen admission. Call only after the
    /// owner has completed its transition and re-established audited readiness.
    /// Mere successful fresh reads or possession of this value are insufficient.
    @discardableResult
    func activate(_ capturedGeneration: Generation) -> Bool {
        storage.activate(capturedGeneration)
    }

    /// Publish nothing until this returns a handle. Rejected registrations are
    /// invalidated synchronously before returning nil. A concurrent revoke may
    /// invalidate an accepted token before this returns; destinations must still
    /// check the same retained token at every serialization/item-supply boundary.
    func register(_ permit: any ZeroOneShareRevocablePermit,
                  for capturedGeneration: Generation) -> Registration? {
        storage.register(permit, for: capturedGeneration)
    }

    /// Always revoke the old token before dropping/replacing its route. For a
    /// replacement, remove the old handle first, then register a NEW permanent
    /// token with the captured generation. A racing revoke rejects that attempt.
    /// A foreign or obsolete handle cannot remove a newer registration.
    func remove(_ registration: Registration) {
        storage.remove(registration)
    }

    func revokeAll() { storage.revoke(permanently: false) }

    /// Owner teardown permanently closes this registry as well as its tokens.
    func invalidatePermanently() { storage.revoke(permanently: true) }

    /// All mutable fields are protected by lock. External token code executes
    /// ONLY after unlock. Entries stay retained until invalidation has finished,
    /// so another overlapping revoke independently invalidates those entries
    /// before returning instead of observing a prematurely emptied collection.
    private final class Storage: @unchecked Sendable {
        private final class Entry: Sendable {
            let id = UUID()
            let permit: any ZeroOneShareRevocablePermit
            init(_ permit: any ZeroOneShareRevocablePermit) { self.permit = permit }
        }

        private let lock = NSLock()
        private let registryID = UUID()
        private var revision = UUID()
        private var acceptsRegistrations = false
        private var isPermanentlyClosed = false
        private var activeInvalidations = 0
        private var entries: [UUID: Entry] = [:]

        var currentGeneration: Generation {
            lock.lock()
            defer { lock.unlock() }
            return Generation(registryID: registryID, revision: revision)
        }

        func activate(_ generation: Generation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isPermanentlyClosed, activeInvalidations == 0, generation.registryID == registryID,
                  generation.revision == revision else { return false }
            acceptsRegistrations = true
            return true
        }

        func register(_ permit: any ZeroOneShareRevocablePermit,
                      for generation: Generation) -> Registration? {
            lock.lock()
            let accepted = !isPermanentlyClosed && activeInvalidations == 0 && acceptsRegistrations
                && generation.registryID == registryID && generation.revision == revision
            var registration: Registration?
            if accepted {
                let entry = Entry(permit)
                entries[entry.id] = entry
                registration = Registration(registryID: registryID, id: entry.id)
            }
            lock.unlock()
            if registration == nil { permit.invalidate() }
            return registration
        }

        func remove(_ registration: Registration) {
            lock.lock()
            let entry = registration.registryID == registryID ? entries[registration.id] : nil
            if entry != nil { activeInvalidations += 1 }
            lock.unlock()
            guard let entry else { return }
            entry.permit.invalidate()
            lock.lock()
            entries.removeValue(forKey: entry.id)
            activeInvalidations -= 1
            lock.unlock()
            withExtendedLifetime(entry) {}
        }

        func revoke(permanently: Bool) {
            lock.lock()
            revision = UUID()
            acceptsRegistrations = false
            isPermanentlyClosed = isPermanentlyClosed || permanently
            activeInvalidations += 1
            let pending = Array(entries.values)
            lock.unlock()
            for entry in pending { entry.permit.invalidate() }
            lock.lock()
            for entry in pending { entries.removeValue(forKey: entry.id) }
            activeInvalidations -= 1
            lock.unlock()
            withExtendedLifetime(pending) {}
        }
    }
}
