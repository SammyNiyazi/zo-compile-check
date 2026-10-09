import Foundation
import XCTest
@testable import ZeroOne

final class ZeroOneSharePermitRegistryTests: XCTestCase {
    func testStartsClosedAndRejectsIncomingPermitSynchronously() {
        let registry = ZeroOneSharePermitRegistry()
        let permit = Permit()
        XCTAssertNil(registry.register(permit, for: registry.currentGeneration))
        XCTAssertFalse(permit.isValid)
    }

    func testActualSharedRegistrationRevokesBeforeNextMutationEvenWhenWriteFails() {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let permit = Permit()
        XCTAssertNotNil(registry.register(permit, for: generation))
        let registration = registry.revocationRegistration
        XCTAssertTrue(registration === registry.revocationRegistration)
        registration.revokeBeforeChange()
        XCTAssertThrowsError(try failingMutation(permit))
        XCTAssertFalse(permit.isValid)
    }

    func testRevocationRejectsCapturedLateRegistrationAndCannotReactivateOldGeneration() {
        let registry = ZeroOneSharePermitRegistry()
        let captured = registry.currentGeneration
        XCTAssertTrue(registry.activate(captured))
        registry.revokeAll()
        let late = Permit()
        XCTAssertNil(registry.register(late, for: captured))
        XCTAssertFalse(late.isValid)
        XCTAssertFalse(registry.activate(captured))
        let fresh = registry.currentGeneration
        let stillClosed = Permit()
        XCTAssertNil(registry.register(stillClosed, for: fresh))
        XCTAssertFalse(stillClosed.isValid)
        XCTAssertTrue(registry.activate(fresh))
        let new = Permit()
        XCTAssertNotNil(registry.register(new, for: fresh))
        XCTAssertTrue(new.isValid)
    }

    func testForeignGenerationDeniesAndForeignRemovalDoesNotAffectOtherRegistry() throws {
        let first = ZeroOneSharePermitRegistry()
        let second = ZeroOneSharePermitRegistry()
        let generation = first.currentGeneration
        XCTAssertTrue(first.activate(generation))
        XCTAssertTrue(second.activate(second.currentGeneration))
        XCTAssertFalse(second.activate(generation))
        let rejected = Permit()
        XCTAssertNil(second.register(rejected, for: generation))
        XCTAssertFalse(rejected.isValid)
        let retained = Permit()
        let handle = try XCTUnwrap(first.register(retained, for: generation))
        second.remove(handle)
        XCTAssertTrue(retained.isValid)
        first.remove(handle)
        XCTAssertFalse(retained.isValid)
    }

    func testReplacementPermanentlyInvalidatesOldTokenAndObsoleteRemovalCannotAffectNew() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let old = Permit()
        let oldHandle = try XCTUnwrap(registry.register(old, for: generation))
        registry.remove(oldHandle)
        XCTAssertFalse(old.isValid)
        let replacement = Permit()
        let newHandle = try XCTUnwrap(registry.register(replacement, for: generation))
        registry.remove(oldHandle)
        XCTAssertTrue(replacement.isValid)
        registry.remove(newHandle)
        XCTAssertFalse(replacement.isValid)
        XCTAssertFalse(old.isValid)
    }

    func testReinstallationDoesNotReviveTokensAndPermanentTeardownCannotReopen() {
        let registry = ZeroOneSharePermitRegistry()
        let first = registry.currentGeneration
        XCTAssertTrue(registry.activate(first))
        let old = Permit()
        XCTAssertNotNil(registry.register(old, for: first))
        registry.revokeAll()
        let second = registry.currentGeneration
        XCTAssertTrue(registry.activate(second))
        XCTAssertFalse(old.isValid)
        let new = Permit()
        XCTAssertNotNil(registry.register(new, for: second))
        registry.invalidatePermanently()
        XCTAssertFalse(new.isValid)
        XCTAssertFalse(registry.activate(registry.currentGeneration))
        let late = Permit()
        XCTAssertNil(registry.register(late, for: registry.currentGeneration))
        XCTAssertFalse(late.isValid)
    }

    func testOverlappingRevokeCannotReturnWhileRetainedOldPermitIsStillValid() {
        let registry = ZeroOneSharePermitRegistry()
        let captured = registry.currentGeneration
        XCTAssertTrue(registry.activate(captured))
        let permit = BlockingPermit()
        XCTAssertNotNil(registry.register(permit, for: captured))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.revocationRegistration.revokeBeforeChange()
            finished.signal()
        }
        XCTAssertEqual(permit.firstEntered.wait(timeout: .now() + 2), .success)
        defer { permit.releaseFirst.signal() }
        XCTAssertTrue(permit.isValid)
        XCTAssertFalse(registry.activate(registry.currentGeneration))
        let late = Permit()
        XCTAssertNil(registry.register(late, for: captured))
        XCTAssertFalse(late.isValid)
        registry.revocationRegistration.revokeBeforeChange()
        XCTAssertFalse(permit.isValid)
        permit.releaseFirst.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(permit.didTimeOut)
    }

    func testOverlappingRemovalStillLeavesPermitVisibleToSynchronousRevoke() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let permit = BlockingPermit()
        let handle = try XCTUnwrap(registry.register(permit, for: generation))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.remove(handle)
            finished.signal()
        }
        XCTAssertEqual(permit.firstEntered.wait(timeout: .now() + 2), .success)
        defer { permit.releaseFirst.signal() }
        registry.revokeAll()
        XCTAssertFalse(permit.isValid)
        permit.releaseFirst.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(permit.didTimeOut)
    }

    func testInvalidatorCanReadRegistryWithoutHoldingItsLock() {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let permit = ReadbackPermit(registry)
        XCTAssertNotNil(registry.register(permit, for: generation))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { registry.revokeAll(); finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(permit.isValid)
        XCTAssertNotEqual(permit.observedGeneration, generation)
    }

    func testOwnerReleaseRevokesDocumentsEvenIfActualRegistrationOutlivesOwner() {
        let permit = Permit()
        var registry: ZeroOneSharePermitRegistry? = ZeroOneSharePermitRegistry()
        let generation = registry!.currentGeneration
        XCTAssertTrue(registry!.activate(generation))
        XCTAssertNotNil(registry!.register(permit, for: generation))
        let registration = registry!.revocationRegistration
        withExtendedLifetime(registry) { XCTAssertTrue(permit.isValid) }
        registry = nil
        XCTAssertFalse(permit.isValid)
        registration.revokeBeforeChange()
        XCTAssertFalse(permit.isValid)
    }

    private enum MutationError: Error { case expectedFailure }
    private func failingMutation(_ permit: Permit) throws {
        XCTAssertFalse(permit.isValid, "Pre-change callback must revoke before a failing write starts")
        throw MutationError.expectedFailure
    }

    private final class Permit: ZeroOneShareRevocablePermit, @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
    }

    /// First call pauses before invalidating; every later call independently
    /// invalidates before returning. No callback or actor/UI state is involved.
    private final class BlockingPermit: ZeroOneShareRevocablePermit, @unchecked Sendable {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var valid = true
        private var timedOut = false
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
        func invalidate() {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            if first {
                firstEntered.signal()
                let result = releaseFirst.wait(timeout: .now() + 4)
                lock.lock(); timedOut = result != .success; lock.unlock()
            }
            lock.lock(); valid = false; lock.unlock()
        }
    }

    private final class ReadbackPermit: ZeroOneShareRevocablePermit, @unchecked Sendable {
        private let registry: ZeroOneSharePermitRegistry
        private let lock = NSLock()
        private var valid = true
        private var observed: ZeroOneSharePermitRegistry.Generation?
        init(_ registry: ZeroOneSharePermitRegistry) { self.registry = registry }
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        var observedGeneration: ZeroOneSharePermitRegistry.Generation? {
            lock.lock(); defer { lock.unlock() }; return observed
        }
        func invalidate() {
            let generation = registry.currentGeneration
            lock.lock(); valid = false; observed = generation; lock.unlock()
        }
    }
}
