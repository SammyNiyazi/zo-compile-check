import Foundation
import XCTest
@testable import ZeroOne

/// Pure retained-authorization invariants only. Synthetic bytes are not a native
/// image/Files/share fixture and do not establish rendering or OS delivery.
final class ZOShareExportAuthorityTests: XCTestCase {
    private let sourceVersion = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let reviewVersion = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let replacementVersion = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
    private let reviewedBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0xFF])

    func testDefaultPermitHasNoEgressAuthority() {
        let permit = ZOShareExportPermit()
        XCTAssertFalse(permit.isAuthorized)
        assertUnavailable { _ = try permit.authorizedData(reviewedBytes) }
    }

    func testAnyMissingRootOrReviewCapabilityOrRevisionFailsClosed() {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let incomplete = [
            ZOShareExportPermit(sourceVersion: sourceVersion, review: review, reviewVersion: reviewVersion),
            ZOShareExportPermit(root: root, review: review, reviewVersion: reviewVersion),
            ZOShareExportPermit(root: root, sourceVersion: sourceVersion, reviewVersion: reviewVersion),
            ZOShareExportPermit(root: root, sourceVersion: sourceVersion, review: review)
        ]
        for permit in incomplete {
            XCTAssertFalse(permit.isAuthorized)
            assertUnavailable { _ = try permit.authorizedData(reviewedBytes) }
        }
    }

    func testExactIndependentRootAndReviewRevisionsAuthorizeReviewedBytesUnchanged() throws {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let permit = permit(root: root, review: review)
        XCTAssertNotEqual(sourceVersion, reviewVersion)
        XCTAssertTrue(permit.isAuthorized)
        XCTAssertEqual(try permit.authorizedData(reviewedBytes), reviewedBytes)
    }

    func testWrongSourceRevisionCannotUseAnOtherwiseValidReview() {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let permit = ZOShareExportPermit(root: root, sourceVersion: replacementVersion,
            review: review, reviewVersion: reviewVersion)
        XCTAssertFalse(permit.isAuthorized)
        assertUnavailable { _ = try permit.authorizedData(reviewedBytes) }
    }

    func testWrongReviewRevisionCannotUseAnOtherwiseValidSource() {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let permit = ZOShareExportPermit(root: root, sourceVersion: sourceVersion,
            review: review, reviewVersion: replacementVersion)
        XCTAssertFalse(permit.isAuthorized)
        assertUnavailable { _ = try permit.authorizedData(reviewedBytes) }
    }

    func testAuthorizedPermitCannotSerializeEmptyDataAsASuccessfulImage() {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let permit = permit(root: root, review: review)
        XCTAssertTrue(permit.isAuthorized)
        assertUnavailable { _ = try permit.authorizedData(Data()) }
    }

    func testRootRevocationDeniesAnAlreadyRetainedSerializationPermit() throws {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        XCTAssertEqual(try retained.authorizedData(reviewedBytes), reviewedBytes)
        root.invalidate()
        XCTAssertTrue(review.allows(reviewVersion))
        XCTAssertFalse(retained.isAuthorized)
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
    }

    func testReviewChoiceInvalidationDeniesRetainedBytesWhileSourceStillMatches() throws {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        XCTAssertEqual(try retained.authorizedData(reviewedBytes), reviewedBytes)
        review.invalidate()
        XCTAssertTrue(root.allows(sourceVersion))
        XCTAssertFalse(retained.isAuthorized)
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
    }

    func testRevocationBeforeRootTeardownSurvivesRetainedPermitAndBytes() throws {
        var rootOwner: ZOShareExportLifetime? = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: try XCTUnwrap(rootOwner), review: review)
        rootOwner?.invalidate()
        rootOwner = nil
        XCTAssertNil(rootOwner)
        XCTAssertFalse(retained.isAuthorized)
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
    }

    func testSameRevisionNewPresentationCannotReactivateOldRetainedPermit() throws {
        let oldRoot = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let oldPermit = permit(root: oldRoot, review: review)
        oldRoot.invalidate()
        let newRoot = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let newPermit = permit(root: newRoot, review: review)
        XCTAssertEqual(try newPermit.authorizedData(reviewedBytes), reviewedBytes)
        assertUnavailable { _ = try oldPermit.authorizedData(reviewedBytes) }
        oldRoot.invalidate()
        XCTAssertTrue(newPermit.isAuthorized)
        XCTAssertFalse(oldPermit.isAuthorized)
    }

    func testNewReviewedImageDoesNotReactivateAnOlderReviewPermit() throws {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let oldReview = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let oldPermit = permit(root: root, review: oldReview)
        oldReview.invalidate()
        let newReview = ZOShareExportLifetime(sourceVersion: replacementVersion)
        let newPermit = ZOShareExportPermit(root: root, sourceVersion: sourceVersion,
            review: newReview, reviewVersion: replacementVersion)
        let newBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x02, 0xFE])
        XCTAssertEqual(try newPermit.authorizedData(newBytes), newBytes)
        assertUnavailable { _ = try oldPermit.authorizedData(reviewedBytes) }
        XCTAssertTrue(root.allows(sourceVersion))
    }

    func testRevokingOneReviewDoesNotRevokeAnotherReviewedImageForSameSource() throws {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let firstReview = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let secondReview = ZOShareExportLifetime(sourceVersion: replacementVersion)
        let firstPermit = permit(root: root, review: firstReview)
        let secondPermit = ZOShareExportPermit(root: root, sourceVersion: sourceVersion,
            review: secondReview, reviewVersion: replacementVersion)
        firstReview.invalidate()
        assertUnavailable { _ = try firstPermit.authorizedData(reviewedBytes) }
        XCTAssertEqual(try secondPermit.authorizedData(reviewedBytes), reviewedBytes)
        root.invalidate()
        assertUnavailable { _ = try secondPermit.authorizedData(reviewedBytes) }
    }

    func testLifetimeVersionMismatchNeverMutatesOrRevivesItsBoundAuthority() {
        let lifetime = ZOShareExportLifetime(sourceVersion: sourceVersion)
        XCTAssertFalse(lifetime.allows(replacementVersion))
        XCTAssertTrue(lifetime.allows(sourceVersion))
        lifetime.invalidate()
        XCTAssertFalse(lifetime.allows(sourceVersion))
        XCTAssertFalse(lifetime.allows(replacementVersion))
        lifetime.invalidate()
        XCTAssertFalse(lifetime.allows(sourceVersion))
    }

    func testDetachedRetainedSerializerObservesCompletedRootRevocation() async {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        let bytes = reviewedBytes
        root.invalidate()
        let supplied = await Task.detached {
            try? retained.authorizedData(bytes)
        }.value
        XCTAssertNil(supplied)
    }

    func testCurrentGenerationAllowsOnlyActiveUncancelledOperation() {
        let generation = ZOShareExportGeneration()
        let ticket = generation.revision
        XCTAssertTrue(generation.accepts(ticket, isActive: true, isCancelled: false))
        XCTAssertFalse(generation.accepts(ticket, isActive: false, isCancelled: false))
        XCTAssertFalse(generation.accepts(ticket, isActive: true, isCancelled: true))
    }

    func testObsoleteCompletionTicketCannotAuthorizeAfterNewOperationStarts() {
        var generation = ZOShareExportGeneration()
        let obsoleteTicket = generation.revision
        generation.invalidate()
        let newerTicket = generation.revision
        XCTAssertNotEqual(obsoleteTicket, newerTicket)
        XCTAssertFalse(generation.accepts(obsoleteTicket, isActive: true, isCancelled: false))
        XCTAssertTrue(generation.accepts(newerTicket, isActive: true, isCancelled: false))
    }

    func testRepeatedChoiceOrSourceInvalidationsDoNotReauthorizeEarlierTickets() {
        var generation = ZOShareExportGeneration()
        let initial = generation.revision
        generation.invalidate()
        let intermediate = generation.revision
        generation.invalidate()
        for obsolete in [initial, intermediate] {
            XCTAssertFalse(generation.accepts(obsolete, isActive: true, isCancelled: false))
        }
        XCTAssertTrue(generation.accepts(generation.revision, isActive: true, isCancelled: false))
    }

    func testRootRevocationBlocksBytesEvenWhenOperationTicketStillMatches() {
        let root = ZOShareExportLifetime(sourceVersion: sourceVersion)
        let review = ZOShareExportLifetime(sourceVersion: reviewVersion)
        let retained = permit(root: root, review: review)
        let generation = ZOShareExportGeneration()
        root.invalidate()
        XCTAssertTrue(generation.accepts(generation.revision, isActive: true, isCancelled: false))
        assertUnavailable { _ = try retained.authorizedData(reviewedBytes) }
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
