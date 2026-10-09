import Foundation
import XCTest
@testable import ZeroOne

/// Synthetic opaque bytes test the authority contract. Image decoding, rendering,
/// permission UI and native export execution require separate macOS/iOS acceptance.
final class PhotoComparisonSharePresentationTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let firstBytes = Data([0x01, 0x10, 0xFF])
    private let secondBytes = Data([0x02, 0x20, 0xFE])

    func testCaptureBindsCompleteSelectedRecordsAndOriginalBytes() throws {
        let first = record(firstID, time: 100, label: .postWorkout)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        XCTAssertEqual(source.first.record, first)
        XCTAssertEqual(source.second.record, second)
        XCTAssertEqual(source.first.imageData, firstBytes)
        XCTAssertEqual(source.second.imageData, secondBytes)
    }

    func testManifestOrderingDoesNotChangeSelectedPairOrInvalidateExactSource() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let reversedManifest = snapshot([second, first])
        let source = try PhotoComparisonShareAuthority.capture(first: first, second: second, snapshot: reversedManifest)
        XCTAssertEqual(source.first.record, first)
        XCTAssertEqual(source.second.record, second)
        XCTAssertNoThrow(try PhotoComparisonShareAuthority.validate(source, current: snapshot([first, second])))
    }

    func testSameSelectedIdentityCannotBecomeAComparison() {
        let first = record(firstID, time: 100)
        assertError(.duplicateIdentity) {
            _ = try PhotoComparisonShareAuthority.capture(first: first, second: first, snapshot: snapshot([first]))
        }
    }

    func testDuplicateSelectedIdentityInManifestFailsClosed() {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        assertError(.duplicateIdentity) {
            _ = try PhotoComparisonShareAuthority.capture(first: first, second: second,
                snapshot: snapshot([first, second, first]))
        }
    }

    func testDuplicateUnrelatedIdentityCannotAuthorizeAnOtherwiseExactPair() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let other = record(otherID, time: 300)
        assertError(.duplicateIdentity) {
            try PhotoComparisonShareAuthority.validate(source, current: snapshot([first, second, other, other]))
        }
    }

    func testMissingRecordAtCaptureNeverSubstitutesANewerRecord() {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let replacement = record(otherID, time: 300)
        assertError(.missingRecord) {
            _ = try PhotoComparisonShareAuthority.capture(first: first, second: second,
                snapshot: snapshot([first, replacement]))
        }
    }

    func testDeletionOfEitherSelectedRecordInvalidatesOpenSource() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        for remaining in [[first], [second], []] {
            assertError(.missingRecord) {
                try PhotoComparisonShareAuthority.validate(source, current: snapshot(remaining))
            }
        }
    }

    func testSameDateAndLabelReplacementWithDifferentIDDoesNotRecoverDeletedSelection() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        assertError(.missingRecord) {
            try PhotoComparisonShareAuthority.validate(source,
                current: snapshot([first, record(otherID, time: 200)]))
        }
    }

    func testTimestampAndLabelMutationOnEitherSideInvalidatesExactRecordBinding() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let mutations = [
            [record(firstID, time: 101), second],
            [record(firstID, time: 100, label: .postWorkout), second],
            [first, record(secondID, time: 201)],
            [first, record(secondID, time: 200, label: .postWorkout)]
        ]
        for records in mutations {
            assertError(.changedRecord) {
                try PhotoComparisonShareAuthority.validate(source, current: snapshot(records))
            }
        }
    }

    func testOriginalAndThumbnailPathMutationCannotPassAnIDOnlyCheck() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        for target in [first, second] {
            for paths in [("other/master.jpg", target.thumbnailRelativePath),
                          (target.imageRelativePath, "other/thumbnail.jpg")] {
                let changed = ProgressPhotoRecord(id: target.id, createdAt: target.createdAt,
                    label: target.label, imageRelativePath: paths.0, thumbnailRelativePath: paths.1)
                let records = target.id == first.id ? [changed, second] : [first, changed]
                XCTAssertThrowsError(try PhotoComparisonShareAuthority.validate(source, current: snapshot(records)))
            }
        }
    }

    func testValidUnrelatedRecordChangesDoNotInvalidateSelectedPhotoFacts() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        XCTAssertNoThrow(try PhotoComparisonShareAuthority.validate(source,
            current: snapshot([record(otherID, time: 301, label: .postWorkout), second, first])))
    }

    func testSameRecordsWithChangedOriginalBytesOnEitherSideAreRejected() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        for id in [firstID, secondID] {
            var bytes = [firstID: firstBytes, secondID: secondBytes]
            bytes[id] = Data([0xAA, 0xBB, 0xCC])
            assertError(.changedImage) {
                try PhotoComparisonShareAuthority.validate(source,
                    current: PhotoComparisonShareSnapshot(records: [first, second], originalImageData: bytes))
            }
        }
    }

    func testMissingOrEmptyOriginalBytesCannotBeCaptured() {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        for id in [firstID, secondID] {
            for unavailable in [nil, Data()] as [Data?] {
                var bytes = [firstID: firstBytes, secondID: secondBytes]
                bytes[id] = unavailable
                assertError(.unreadableImage) {
                    _ = try PhotoComparisonShareAuthority.capture(first: first, second: second,
                        snapshot: PhotoComparisonShareSnapshot(records: [first, second], originalImageData: bytes))
                }
            }
        }
    }

    func testMissingOrEmptyCurrentOriginalBytesInvalidateAnOpenSource() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        for id in [firstID, secondID] {
            for unavailable in [nil, Data()] as [Data?] {
                var bytes = [firstID: firstBytes, secondID: secondBytes]
                bytes[id] = unavailable
                assertError(.unreadableImage) {
                    try PhotoComparisonShareAuthority.validate(source,
                        current: PhotoComparisonShareSnapshot(records: [first, second], originalImageData: bytes))
                }
            }
        }
    }

    func testAbsentFreshAuthorityFailsClosedWithExactCachedSource() throws {
        let source = try capture(record(firstID, time: 100), record(secondID, time: 200))
        assertError(.unavailable) {
            try PhotoComparisonShareAuthority.validate(source, current: nil)
        }
    }

    func testNonfiniteDateCannotBecomeFactualShareContent() {
        let second = record(secondID, time: 200)
        for invalidTime in [Double.nan, Double.infinity, -Double.infinity] {
            let first = record(firstID, time: invalidTime)
            assertError(.invalidRecord) {
                _ = try capture(first, second)
            }
        }
    }

    func testForeignAndTraversalOriginalPathsAreRejectedBeforeCapture() {
        let second = record(secondID, time: 200)
        for path in ["../master.jpg", "/master.jpg", "other/master.jpg", "thumbnail.jpg"] {
            let first = ProgressPhotoRecord(id: firstID, createdAt: Date(timeIntervalSince1970: 100),
                label: .progress, imageRelativePath: path,
                thumbnailRelativePath: firstID.uuidString.lowercased() + "/thumbnail.jpg")
            assertError(.invalidRecord) { _ = try capture(first, second) }
        }
    }

    func testUppercaseOwnedUUIDFolderMatchesActualStorePathSemantics() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = ProgressPhotoRecord(id: id, createdAt: Date(timeIntervalSince1970: 100), label: .progress,
            imageRelativePath: id.uuidString.uppercased() + "/master.jpg",
            thumbnailRelativePath: id.uuidString.uppercased() + "/thumbnail.jpg")
        let second = record(secondID, time: 200)
        let snapshot = PhotoComparisonShareSnapshot(records: [first, second],
            originalImageData: [id: firstBytes, secondID: secondBytes])
        let source = try PhotoComparisonShareAuthority.capture(first: first, second: second, snapshot: snapshot)
        XCTAssertEqual(source.first.record, first)
        XCTAssertNoThrow(try PhotoComparisonShareAuthority.validate(source, current: snapshot))
    }

    func testChangingOnlyOwnedPathCaseStillInvalidatesExactSavedRecordVersion() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = record(id, time: 100)
        let second = record(secondID, time: 200)
        let bytes = [id: firstBytes, secondID: secondBytes]
        let source = try PhotoComparisonShareAuthority.capture(first: first, second: second,
            snapshot: PhotoComparisonShareSnapshot(records: [first, second], originalImageData: bytes))
        let changed = ProgressPhotoRecord(id: id, createdAt: first.createdAt, label: first.label,
            imageRelativePath: id.uuidString.uppercased() + "/master.jpg",
            thumbnailRelativePath: id.uuidString.uppercased() + "/thumbnail.jpg")
        XCTAssertNotEqual(first.imageRelativePath, changed.imageRelativePath)
        XCTAssertNotEqual(first.thumbnailRelativePath, changed.thumbnailRelativePath)
        assertError(.changedRecord) {
            try PhotoComparisonShareAuthority.validate(source,
                current: PhotoComparisonShareSnapshot(records: [changed, second], originalImageData: bytes))
        }
    }

    func testChronologicalSelectionRetainsActualDatesAndSavedLabels() throws {
        let first = record(firstID, time: 100, label: .postWorkout)
        let second = record(secondID, time: 200, label: .progress)
        let source = try capture(first, second)
        XCTAssertTrue(source.hasStrictChronology)
        XCTAssertEqual(source.first.record.createdAt, first.createdAt)
        XCTAssertEqual(source.first.record.label, .postWorkout)
        XCTAssertEqual(source.second.record.createdAt, second.createdAt)
        XCTAssertEqual(source.second.record.label, .progress)
    }

    func testEqualDatesNeverInventBeforeAfterChronologyOrSwapLabels() throws {
        let first = record(firstID, time: 200, label: .postWorkout)
        let second = record(secondID, time: 200, label: .progress)
        let source = try capture(first, second)
        XCTAssertFalse(source.hasStrictChronology)
        XCTAssertEqual(source.first.record, first)
        XCTAssertEqual(source.second.record, second)
        XCTAssertEqual(source.first.imageData, firstBytes)
        XCTAssertEqual(source.second.imageData, secondBytes)
    }

    func testReversedDatesPreserveReviewedOrderWithoutInventingChronology() throws {
        let first = record(firstID, time: 300, label: .postWorkout)
        let second = record(secondID, time: 100, label: .progress)
        let source = try capture(first, second)
        XCTAssertFalse(source.hasStrictChronology)
        XCTAssertEqual(source.first.record, first)
        XCTAssertEqual(source.second.record, second)
        XCTAssertGreaterThan(source.first.record.createdAt, source.second.record.createdAt)
    }

    func testNewOptionsExcludeDatesAndLabelsByDefault() {
        let options = PhotoComparisonShareOptions()
        XCTAssertFalse(options.includeDates)
        XCTAssertFalse(options.includeLabels)
    }

    func testPrivacyChoicesAreIndependentAndNewComposerDefaultsRemainPrivate() {
        var options = PhotoComparisonShareOptions()
        options.includeDates = true
        XCTAssertTrue(options.includeDates)
        XCTAssertFalse(options.includeLabels)
        options.includeDates = false
        options.includeLabels = true
        XCTAssertFalse(options.includeDates)
        XCTAssertTrue(options.includeLabels)
        XCTAssertFalse(PhotoComparisonShareOptions().includeDates)
        XCTAssertFalse(PhotoComparisonShareOptions().includeLabels)
    }

    func testExactActiveUncancelledExportTicketIsAccepted() {
        let generation = PhotoComparisonShareGeneration()
        let sourceVersion = UUID()
        XCTAssertTrue(generation.accepts(generation.revision, sourceVersion: sourceVersion,
            currentSourceVersion: sourceVersion, isActive: true, isCancelled: false))
    }

    func testInvalidationRejectsPendingTicketEvenWithUnchangedPhotoFacts() {
        var generation = PhotoComparisonShareGeneration()
        let ticket = generation.revision
        let version = UUID()
        generation.invalidate()
        XCTAssertNotEqual(generation.revision, ticket)
        XCTAssertFalse(generation.accepts(ticket, sourceVersion: version,
            currentSourceVersion: version, isActive: true, isCancelled: false))
    }

    func testMultipleInvalidationsDoNotReauthorizeAnyEarlierExportTicket() {
        var generation = PhotoComparisonShareGeneration()
        let original = generation.revision
        generation.invalidate()
        let intermediate = generation.revision
        generation.invalidate()
        let version = UUID()
        for ticket in [original, intermediate] {
            XCTAssertFalse(generation.accepts(ticket, sourceVersion: version,
                currentSourceVersion: version, isActive: true, isCancelled: false))
        }
        XCTAssertTrue(generation.accepts(generation.revision, sourceVersion: version,
            currentSourceVersion: version, isActive: true, isCancelled: false))
    }

    func testCancelledOrInactiveOperationRejectsEvenCurrentExportTicket() {
        let generation = PhotoComparisonShareGeneration()
        let version = UUID()
        XCTAssertFalse(generation.accepts(generation.revision, sourceVersion: version,
            currentSourceVersion: version, isActive: true, isCancelled: true))
        XCTAssertFalse(generation.accepts(generation.revision, sourceVersion: version,
            currentSourceVersion: version, isActive: false, isCancelled: false))
    }

    func testChangedSourceVersionInvalidatesCurrentExportTicket() {
        let generation = PhotoComparisonShareGeneration()
        XCTAssertFalse(generation.accepts(generation.revision, sourceVersion: firstID,
            currentSourceVersion: secondID, isActive: true, isCancelled: false))
    }

    func testFreshStoreReadUsesOnlySelectedOriginalPathsAndNeverMutatesStorage() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [record(otherID, time: 300), second, first],
            originals: [firstID: firstBytes, secondID: secondBytes])
        let fresh = try PhotoComparisonShareAuthority.read(store: store, source: source)
        XCTAssertNoThrow(try PhotoComparisonShareAuthority.validate(source, current: fresh))
        XCTAssertEqual(store.loadCount, 2)
        XCTAssertEqual(store.pathsRead, [first.imageRelativePath, second.imageRelativePath,
                                       first.imageRelativePath, second.imageRelativePath])
        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(fresh.originalImageData, [firstID: firstBytes, secondID: secondBytes])
    }

    func testUnavailableStoreNeverUsesCachedRecordsOrReadsImages() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second],
            originals: [firstID: firstBytes, secondID: secondBytes])
        store.available = false
        assertError(.unavailable) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertTrue(store.pathsRead.isEmpty)
    }

    func testUnreadableManifestPropagatesFailureWithoutUsingPreviouslyCapturedSource() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second],
            originals: [firstID: firstBytes, secondID: secondBytes])
        store.readFailure = .unavailable
        XCTAssertThrowsError(try PhotoComparisonShareAuthority.read(store: store, source: source)) { error in
            XCTAssertEqual(error as? ProgressPhotoStoreError, .unavailable)
        }
        XCTAssertTrue(store.pathsRead.isEmpty)
        XCTAssertEqual(store.mutationCount, 0)
    }

    func testFreshStoreDeletionCannotBeMaskedByCapturedRecordAndBytes() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, record(otherID, time: 200)],
            originals: [firstID: firstBytes, secondID: secondBytes])
        assertError(.missingRecord) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
        XCTAssertEqual(store.mutationCount, 0)
    }

    func testManifestMutationDuringFreshReadRejectsTheObservation() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second],
            originals: [firstID: firstBytes, secondID: secondBytes])
        store.afterLoad = { count, store in
            if count == 1 { store.records = [first] }
        }
        assertError(.changedRecord) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
    }

    func testOriginalByteMutationBetweenReadPassesRejectsTheObservation() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second],
            originals: [firstID: firstBytes, secondID: secondBytes])
        store.beforeData = { count, store in
            if count == 3 { store.originals[first.id] = Data([0x55, 0x66, 0x77]) }
        }
        assertError(.changedImage) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
    }

    func testUnreadableSelectedOriginalDoesNotFallBackToThumbnail() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second], originals: [secondID: secondBytes])
        assertError(.unreadableImage) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
        XCTAssertEqual(store.pathsRead, [first.imageRelativePath])
        XCTAssertEqual(store.mutationCount, 0)
    }

    func testAvailabilityLossDuringFinalOriginalReadCannotReturnFreshAuthority() throws {
        let first = record(firstID, time: 100)
        let second = record(secondID, time: 200)
        let source = try capture(first, second)
        let store = SyntheticPhotoShareStore(records: [first, second],
            originals: [firstID: firstBytes, secondID: secondBytes])
        store.beforeData = { count, store in
            if count == 4 { store.available = false }
        }
        assertError(.unavailable) { _ = try PhotoComparisonShareAuthority.read(store: store, source: source) }
    }

    func testLifetimeAllowsOnlyTheExactRootSourceVersion() {
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: firstID)
        XCTAssertTrue(lifetime.allows(firstID))
        XCTAssertFalse(lifetime.allows(secondID))
        XCTAssertTrue(lifetime.allows(firstID))
    }

    func testLifetimeRevocationIsPermanentForAllVersionsAndRepeatedInvalidation() {
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: firstID)
        lifetime.invalidate()
        XCTAssertFalse(lifetime.allows(firstID))
        XCTAssertFalse(lifetime.allows(secondID))
        lifetime.invalidate()
        XCTAssertFalse(lifetime.allows(firstID))
    }

    func testRetainedDocumentTokenRemainsRevokedAfterRootOwnershipEnds() throws {
        var rootOwnedToken: PhotoComparisonShareLifetime? = PhotoComparisonShareLifetime(sourceVersion: firstID)
        let retainedByDocument = try XCTUnwrap(rootOwnedToken)
        XCTAssertTrue(retainedByDocument.allows(firstID))
        // Root revokes before releasing ownership. The retained document alias
        // cannot outlive that revocation by holding the same object alive.
        rootOwnedToken?.invalidate()
        rootOwnedToken = nil
        XCTAssertNil(rootOwnedToken)
        XCTAssertFalse(retainedByDocument.allows(firstID))
    }

    func testNewPresentationTokenCannotReactivatePreviouslyRevokedDocumentToken() {
        let previousDocumentToken = PhotoComparisonShareLifetime(sourceVersion: firstID)
        previousDocumentToken.invalidate()
        let newPresentationToken = PhotoComparisonShareLifetime(sourceVersion: firstID)
        XCTAssertTrue(newPresentationToken.allows(firstID))
        XCTAssertFalse(previousDocumentToken.allows(firstID))
        newPresentationToken.invalidate()
        XCTAssertFalse(newPresentationToken.allows(firstID))
        XCTAssertFalse(previousDocumentToken.allows(firstID))
    }

    func testDistinctRootVersionsAndRevocationsStayIndependent() {
        let firstRoot = PhotoComparisonShareLifetime(sourceVersion: firstID)
        let secondRoot = PhotoComparisonShareLifetime(sourceVersion: secondID)
        XCTAssertFalse(firstRoot.allows(secondID))
        XCTAssertFalse(secondRoot.allows(firstID))
        firstRoot.invalidate()
        XCTAssertFalse(firstRoot.allows(firstID))
        XCTAssertTrue(secondRoot.allows(secondID))
    }

    func testDetachedRetainedReaderObservesCompletedRootRevocation() async {
        let version = firstID
        let retainedToken = PhotoComparisonShareLifetime(sourceVersion: version)
        retainedToken.invalidate()
        // Revocation precedes the detached read, so no timing/sleep assumption
        // or nondeterministic winner of a revoke/read race enters the oracle.
        let permitted = await Task.detached {
            retainedToken.allows(version)
        }.value
        XCTAssertFalse(permitted)
    }

    private func record(_ id: UUID, time: TimeInterval, label: ProgressPhotoLabel = .progress) -> ProgressPhotoRecord {
        let directory = id.uuidString.lowercased()
        return ProgressPhotoRecord(id: id, createdAt: Date(timeIntervalSince1970: time), label: label,
            imageRelativePath: directory + "/master.jpg", thumbnailRelativePath: directory + "/thumbnail.jpg")
    }

    private func snapshot(_ records: [ProgressPhotoRecord]) -> PhotoComparisonShareSnapshot {
        PhotoComparisonShareSnapshot(records: records, originalImageData: [firstID: firstBytes, secondID: secondBytes])
    }

    private func capture(_ first: ProgressPhotoRecord, _ second: ProgressPhotoRecord) throws -> PhotoComparisonShareSource {
        try PhotoComparisonShareAuthority.capture(first: first, second: second, snapshot: snapshot([first, second]))
    }

    private func assertError(_ expected: PhotoComparisonShareError, file: StaticString = #filePath, line: UInt = #line,
                             operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PhotoComparisonShareError, expected, file: file, line: line)
        }
    }
}

/// Scripted in-memory protocol boundary. No filesystem, camera, gallery,
/// application repository, image decoder, network or real personal data.
private final class SyntheticPhotoShareStore: ProgressPhotoPersisting {
    var available = true
    var records: [ProgressPhotoRecord]
    var originals: [UUID: Data]
    var readFailure: ProgressPhotoStoreError?
    var afterLoad: ((Int, SyntheticPhotoShareStore) -> Void)?
    var beforeData: ((Int, SyntheticPhotoShareStore) -> Void)?
    private(set) var loadCount = 0
    private(set) var pathsRead: [String] = []
    private(set) var mutationCount = 0

    init(records: [ProgressPhotoRecord], originals: [UUID: Data]) {
        self.records = records
        self.originals = originals
    }

    var isAvailable: Bool { available }

    func loadRecords() throws -> [ProgressPhotoRecord] {
        loadCount += 1
        if let readFailure { throw readFailure }
        let result = records
        afterLoad?(loadCount, self)
        return result
    }

    func data(at relativePath: String, for record: ProgressPhotoRecord) -> Data? {
        pathsRead.append(relativePath)
        beforeData?(pathsRead.count, self)
        // This fixture has only original images. A thumbnail request cannot
        // accidentally pass as the retained original image for a selected ID.
        guard relativePath == record.imageRelativePath else { return nil }
        return originals[record.id]
    }

    func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws {
        mutationCount += 1
        throw ProgressPhotoStoreError.unavailable
    }

    func delete(_ record: ProgressPhotoRecord) throws {
        mutationCount += 1
        throw ProgressPhotoStoreError.unavailable
    }
}
