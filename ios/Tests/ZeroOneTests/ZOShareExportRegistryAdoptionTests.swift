import Dispatch
import Foundation
import XCTest
@testable import ZeroOne

/// Synthetic registry/lifetime interoperability only. Activating these local
/// registries does not install application authority hooks or enable exports.
final class ZOShareExportRegistryAdoptionTests: XCTestCase {
    private let sourceVersion = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let reviewVersion = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let reviewedBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0xFF])

    func testClosedRegistrySynchronouslyInvalidatesActualLifetimeThroughExistential() throws {
        let registry = ZeroOneSharePermitRegistry()
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        let revocable: any ZeroOneShareRevocablePermit = root
        XCTAssertEqual(try retained.authorizedData(reviewedBytes), reviewedBytes)

        let rejected = registry.register(revocable, for: registry.currentGeneration)

        // No queued work or second explicit invalidation may be needed here.
        XCTAssertNil(rejected)
        XCTAssertFalse(root.allows(sourceVersion))
        XCTAssertTrue(review.allows(reviewVersion))
        XCTAssertFalse(retained.isAuthorized)
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
    }

    func testWorkerThreadRegistryRevocationDeniesRetainedPermitWithReviewStillValid() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        let revocable: any ZeroOneShareRevocablePermit = root
        _ = try XCTUnwrap(registry.register(revocable, for: generation))
        XCTAssertEqual(try retained.authorizedData(reviewedBytes), reviewedBytes)

        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            XCTAssertFalse(Thread.isMainThread)
            // The real immutable registration invokes the real token's locked
            // invalidate implementation, including overlapping/repeated calls.
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                registry.revocationRegistration.revokeBeforeChange()
            }
        }
        // This synchronous XCTest is not actor-isolated. The bound avoids a
        // polling/sleep fixture and establishes completed revocation ordering.
        guard completed.wait(timeout: .now() + 5) == .success else {
            XCTFail("Worker-thread registry revocation did not complete within five seconds")
            return
        }

        XCTAssertFalse(root.allows(sourceVersion))
        XCTAssertTrue(review.allows(reviewVersion))
        XCTAssertFalse(retained.isAuthorized)
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
    }

    func testRemovalKeepsDistinctNewRootValidAndReopenedAdmissionCannotReviveOldRoot() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let oldRoot = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let newRoot = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let oldPermit = permit(root: oldRoot, review: review)
        let newPermit = permit(root: newRoot, review: review)
        let oldRevocable: any ZeroOneShareRevocablePermit = oldRoot
        let newRevocable: any ZeroOneShareRevocablePermit = newRoot
        let oldHandle = try XCTUnwrap(registry.register(oldRevocable, for: generation))
        _ = try XCTUnwrap(registry.register(newRevocable, for: generation))
        XCTAssertFalse(oldRoot === newRoot)
        XCTAssertEqual(try oldPermit.authorizedData(reviewedBytes), reviewedBytes)
        XCTAssertEqual(try newPermit.authorizedData(reviewedBytes), reviewedBytes)

        registry.remove(oldHandle)

        XCTAssertFalse(oldRoot.allows(sourceVersion))
        XCTAssertFalse(oldPermit.isAuthorized)
        assertUnavailable { _ = try oldPermit.authorizedData(reviewedBytes) }
        XCTAssertEqual(try newPermit.authorizedData(reviewedBytes), reviewedBytes)
        registry.remove(oldHandle)
        XCTAssertTrue(newRoot.allows(sourceVersion))

        registry.revokeAll()
        let reopenedGeneration = registry.currentGeneration
        XCTAssertTrue(registry.activate(reopenedGeneration))
        // Registry admission alone is not authorization: even an accepted
        // registration of the same old object cannot reset its permanent state.
        _ = try XCTUnwrap(registry.register(oldRevocable, for: reopenedGeneration))
        let freshRoot = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let freshRevocable: any ZeroOneShareRevocablePermit = freshRoot
        _ = try XCTUnwrap(registry.register(freshRevocable, for: reopenedGeneration))
        let freshPermit = permit(root: freshRoot, review: review)

        XCTAssertFalse(oldRoot.allows(sourceVersion))
        XCTAssertFalse(oldPermit.isAuthorized)
        assertUnavailable { _ = try oldPermit.authorizedData(reviewedBytes) }
        XCTAssertFalse(newPermit.isAuthorized)
        XCTAssertTrue(review.allows(reviewVersion))
        XCTAssertEqual(try freshPermit.authorizedData(reviewedBytes), reviewedBytes)
    }

    private func permit(root: ZOShareExportLifetime, review: ZOShareExportLifetime) -> ZOShareExportPermit {
        ZOShareExportPermit(root: root, sourceVersion: sourceVersion, review: review, reviewVersion: reviewVersion)
    }

    private func assertUnavailable(file: StaticString = #filePath, line: UInt = #line,
                                   operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ZOShareExportAuthorizationError, .unavailable, file: file, line: line)
        }
    }
}
