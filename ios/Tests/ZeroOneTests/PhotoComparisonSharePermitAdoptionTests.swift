import Dispatch
import Foundation
import XCTest
@testable import ZeroOne

/// All admission activation below belongs to isolated in-memory test registries.
/// These tests never install production hooks, read photos or activate app services.
@MainActor
final class PhotoComparisonSharePermitAdoptionTests: XCTestCase {
    func testClosedRegistryAcquisitionInvalidatesActualLifetimeSynchronously() {
        let registry = ZeroOneSharePermitRegistry()
        let version = UUID()
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: version)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: lifetime, sourceVersion: version,
            registry: registry, generation: registry.currentGeneration))
        XCTAssertFalse(lifetime.allows(version))
    }

    func testStaleGenerationAcquisitionCannotSurviveReopening() {
        let registry = ZeroOneSharePermitRegistry()
        let stale = registry.currentGeneration
        XCTAssertTrue(registry.activate(stale))
        registry.revocationRegistration.revokeBeforeChange()
        XCTAssertTrue(registry.activate(registry.currentGeneration))
        let version = UUID()
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: version)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: lifetime, sourceVersion: version,
            registry: registry, generation: stale))
        XCTAssertFalse(lifetime.allows(version))
    }

    func testForeignGenerationAcquisitionInvalidatesActualLifetime() {
        let registry = ZeroOneSharePermitRegistry()
        XCTAssertTrue(registry.activate(registry.currentGeneration))
        let foreign = ZeroOneSharePermitRegistry()
        let version = UUID()
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: version)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: lifetime, sourceVersion: version,
            registry: registry, generation: foreign.currentGeneration))
        XCTAssertFalse(lifetime.allows(version))
    }

    func testMismatchedSourceVersionAcquisitionInvalidatesAndRemovesAcceptedToken() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let actualVersion = UUID()
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: actualVersion)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: lifetime, sourceVersion: UUID(),
            registry: registry, generation: generation))
        XCTAssertFalse(lifetime.allows(actualVersion))
        let freshVersion = UUID()
        let fresh = PhotoComparisonShareLifetime(sourceVersion: freshVersion)
        let replacement = try XCTUnwrap(PhotoComparisonShareRegistration.acquire(lifetime: fresh,
            sourceVersion: freshVersion, registry: registry, generation: generation))
        XCTAssertTrue(replacement.isCurrent)
    }

    func testRegistryRevokeInvalidatesSameLifetimeRetainedByExportPermit() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        XCTAssertEqual(try fixture.permit.authorizedData(fixture.png), fixture.png)
        fixture.registry.revocationRegistration.revokeBeforeChange()
        XCTAssertFalse(fixture.registration.isCurrent)
        XCTAssertFalse(fixture.root.allows(fixture.version))
        XCTAssertTrue(fixture.local.allows(fixture.ticket))
        assertDenied(fixture.permit, data: fixture.png)
    }

    func testPermitRequiresExactReviewedBytesAndRejectsEmptyRaster() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        XCTAssertEqual(try fixture.permit.authorizedData(fixture.png), fixture.png)
        assertDenied(fixture.permit, data: Data([0x89, 0x50, 0x4e, 0x46]))
        assertDenied(fixture.permit, data: Data())
        let empty = PhotoComparisonShareExportPermit(reviewedPNG: Data(), rootLifetime: fixture.root,
            rootVersion: fixture.version, localLifetime: fixture.local, ticket: fixture.ticket)
        assertDenied(empty, data: Data())
    }

    func testPermitDeniesEveryMissingOrWrongRootAndLocalBinding() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        let variants: [PhotoComparisonShareExportPermit] = [
            .init(reviewedPNG: fixture.png, rootLifetime: nil, rootVersion: fixture.version,
                localLifetime: fixture.local, ticket: fixture.ticket),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: nil,
                localLifetime: fixture.local, ticket: fixture.ticket),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: UUID(),
                localLifetime: fixture.local, ticket: fixture.ticket),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: fixture.version,
                localLifetime: nil, ticket: fixture.ticket),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: fixture.version,
                localLifetime: fixture.local, ticket: nil),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: fixture.version,
                localLifetime: fixture.local, ticket: UUID()),
            .init(reviewedPNG: fixture.png, rootLifetime: PhotoComparisonShareLifetime(sourceVersion: UUID()),
                rootVersion: fixture.version, localLifetime: fixture.local, ticket: fixture.ticket),
            .init(reviewedPNG: fixture.png, rootLifetime: fixture.root, rootVersion: fixture.version,
                localLifetime: PhotoComparisonShareLifetime(sourceVersion: UUID()), ticket: fixture.ticket)
        ]
        for variant in variants { assertDenied(variant, data: fixture.png) }
    }

    func testLocalInvalidationDeniesPermitWhileRootRegistrationRemainsCurrent() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        fixture.local.invalidate()
        XCTAssertTrue(fixture.registration.isCurrent)
        XCTAssertTrue(fixture.root.allows(fixture.version))
        assertDenied(fixture.permit, data: fixture.png)
    }

    func testReopenCannotReviveRevokedRegistrationOrExportPermit() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        fixture.registry.revokeAll()
        XCTAssertTrue(fixture.registry.activate(fixture.registry.currentGeneration))
        XCTAssertFalse(fixture.registration.isCurrent)
        XCTAssertFalse(fixture.root.allows(fixture.version))
        assertDenied(fixture.permit, data: fixture.png)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: fixture.root,
            sourceVersion: fixture.version, registry: fixture.registry,
            generation: fixture.registry.currentGeneration))
    }

    func testRepeatedOldRemovalDoesNotRemoveExactReplacementRegistration() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let oldVersion = UUID()
        let oldLifetime = PhotoComparisonShareLifetime(sourceVersion: oldVersion)
        let old = try XCTUnwrap(PhotoComparisonShareRegistration.acquire(lifetime: oldLifetime,
            sourceVersion: oldVersion, registry: registry, generation: generation))
        old.invalidate()
        let version = UUID()
        let lifetime = PhotoComparisonShareLifetime(sourceVersion: version)
        let replacement = try XCTUnwrap(PhotoComparisonShareRegistration.acquire(lifetime: lifetime,
            sourceVersion: version, registry: registry, generation: generation))
        old.invalidate()
        XCTAssertFalse(oldLifetime.allows(oldVersion))
        XCTAssertTrue(replacement.isCurrent)
        registry.revokeAll()
        XCTAssertFalse(lifetime.allows(version))
    }

    func testRegistrationDeinitInvalidatesIndependentlyRetainedLifetimeAndPermit() throws {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let version = UUID(), ticket = UUID()
        let root = PhotoComparisonShareLifetime(sourceVersion: version)
        let local = PhotoComparisonShareLifetime(sourceVersion: ticket)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let permit = PhotoComparisonShareExportPermit(reviewedPNG: png, rootLifetime: root,
            rootVersion: version, localLifetime: local, ticket: ticket)
        var registration = PhotoComparisonShareRegistration.acquire(lifetime: root,
            sourceVersion: version, registry: registry, generation: generation)
        weak var weakRegistration = registration
        XCTAssertNotNil(registration)
        XCTAssertEqual(try permit.authorizedData(png), png)
        registration = nil
        XCTAssertNil(weakRegistration)
        XCTAssertFalse(root.allows(version))
        XCTAssertTrue(local.allows(ticket))
        assertDenied(permit, data: png)
    }

    func testWorkerThreadRegistryInvalidationCompletesBeforeRetainedExportDenial() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        let registration = fixture.registration
        let registry = fixture.registry
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            registry.revocationRegistration.revokeBeforeChange()
            group.leave()
        }
        guard group.wait(timeout: .now() + 5) == .success else {
            XCTFail("Synchronous worker revocation did not finish within five seconds")
            return
        }
        XCTAssertFalse(registration.isCurrent)
        XCTAssertFalse(fixture.root.allows(fixture.version))
        XCTAssertTrue(fixture.local.allows(fixture.ticket))
        assertDenied(fixture.permit, data: fixture.png)
    }

    func testConcurrentWorkerPermanentInvalidationsPreserveSeparateLocalTicket() throws {
        let fixture = try registeredPermit()
        defer { withExtendedLifetime(fixture.registration) {} }
        let registry = fixture.registry
        let registration = fixture.registration
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                registry.invalidatePermanently()
                registration.invalidate()
                group.leave()
            }
        }
        guard group.wait(timeout: .now() + 5) == .success else {
            XCTFail("Concurrent synchronous invalidations did not finish within five seconds")
            return
        }
        XCTAssertFalse(registry.activate(registry.currentGeneration))
        XCTAssertFalse(registration.isCurrent)
        XCTAssertFalse(fixture.root.allows(fixture.version))
        XCTAssertTrue(fixture.local.allows(fixture.ticket))
        assertDenied(fixture.permit, data: fixture.png)
    }

    func testPermanentlyClosedRegistryCannotAdmitNewActualLifetime() {
        let registry = ZeroOneSharePermitRegistry()
        XCTAssertTrue(registry.activate(registry.currentGeneration))
        registry.invalidatePermanently()
        let generation = registry.currentGeneration
        XCTAssertFalse(registry.activate(generation))
        let version = UUID()
        let root = PhotoComparisonShareLifetime(sourceVersion: version)
        XCTAssertNil(PhotoComparisonShareRegistration.acquire(lifetime: root, sourceVersion: version,
            registry: registry, generation: generation))
        XCTAssertFalse(root.allows(version))
    }

    func testReadinessWithoutRegistryIsClosedBeforeSyntheticStoreRead() throws {
        let store = Store()
        let host = PhotoComparisonShareHostAuthority(store: store)
        host.installAuditedReadiness { true }
        XCTAssertFalse(host.isInstalled)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
        XCTAssertEqual(store.reads, 0)
        XCTAssertTrue(store.requestedPaths.isEmpty)
    }

    func testRegistryInstallationAloneGrantsNeitherReadinessNorAdmission() throws {
        let store = Store()
        let host = PhotoComparisonShareHostAuthority(store: store)
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        host.installSharePermitRegistry(registry, for: generation)
        XCTAssertFalse(host.isInstalled)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
        XCTAssertEqual(store.reads, 0)
        host.installAuditedReadiness { true }
        XCTAssertTrue(host.isInstalled)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
        let version = UUID()
        let token = PhotoComparisonShareLifetime(sourceVersion: version)
        XCTAssertNil(registry.register(token, for: generation))
        XCTAssertFalse(token.allows(version))
    }

    func testInstalledBindingsWithoutActualStoreRemainClosed() throws {
        let store = Store()
        let host = PhotoComparisonShareHostAuthority(store: nil)
        let registry = ZeroOneSharePermitRegistry()
        host.installAuditedReadiness { true }
        host.installSharePermitRegistry(registry, for: registry.currentGeneration)
        XCTAssertFalse(host.isInstalled)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
        XCTAssertEqual(store.reads, 0)
    }

    func testStaleInstalledGenerationRejectsFreshSourceAfterSyntheticOwnerCallback() throws {
        let fixture = installedHost()
        let route = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        let beforeReads = fixture.store.reads
        fixture.registry.revocationRegistration.revokeBeforeChange()
        XCTAssertTrue(fixture.registry.activate(fixture.registry.currentGeneration))
        XCTAssertFalse(route.lifetime.allows(route.id))
        XCTAssertNil(fixture.host.freshSource(route.source, for: route))
        XCTAssertEqual(fixture.store.reads, beforeReads)
        XCTAssertNil(try fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
    }

    func testChangedGenerationBindingRevokesOldRouteAndOldCloseCannotRevokeReplacement() throws {
        let fixture = installedHost()
        let old = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        fixture.registry.revocationRegistration.revokeBeforeChange()
        let generation = fixture.registry.currentGeneration
        XCTAssertTrue(fixture.registry.activate(generation))
        fixture.host.installSharePermitRegistry(fixture.registry, for: generation)
        let fresh = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        fixture.host.close(old)
        XCTAssertFalse(old.lifetime.allows(old.id))
        XCTAssertTrue(fresh.lifetime.allows(fresh.id))
        XCTAssertNotNil(fixture.host.freshSource(fresh.source, for: fresh))
        XCTAssertEqual(fixture.store.mutations, 0)
    }

    func testReplacementRegistryBindingClosesOldPresentationAndPreservesSelectedOriginalOrder() throws {
        let fixture = installedHost()
        let records = fixture.store.records
        let old = try XCTUnwrap(fixture.host.prepare(first: records[1], second: records[0]))
        let replacement = ZeroOneSharePermitRegistry()
        let generation = replacement.currentGeneration
        XCTAssertTrue(replacement.activate(generation))
        fixture.host.installSharePermitRegistry(replacement, for: generation)
        XCTAssertFalse(old.lifetime.allows(old.id))
        let fresh = try XCTUnwrap(fixture.host.prepare(first: records[1], second: records[0]))
        fixture.host.close(old)
        fixture.registry.revokeAll()
        let snapshot = try XCTUnwrap(fixture.host.freshSource(fresh.source, for: fresh))
        XCTAssertTrue(fresh.lifetime.allows(fresh.id))
        XCTAssertEqual(fresh.source.first.record, records[1])
        XCTAssertEqual(fresh.source.second.record, records[0])
        XCTAssertEqual(fresh.source.first.imageData, Data([2]))
        XCTAssertEqual(fresh.source.second.imageData, Data([1]))
        XCTAssertFalse(fresh.source.hasStrictChronology)
        XCTAssertEqual(snapshot.records, records)
        XCTAssertEqual(fixture.store.records, records)
        XCTAssertTrue(fixture.store.requestedPaths.allSatisfy { $0.hasSuffix("/master.jpg") })
        XCTAssertEqual(fixture.store.mutations, 0)
    }

    func testPrepareDeniesPublicationWhenStoreSynchronouslyRevokesBetweenReadPasses() throws {
        let fixture = installedHost()
        fixture.store.onLoad = { [registry = fixture.registry] count in
            if count == 2 { registry.revocationRegistration.revokeBeforeChange() }
        }
        XCTAssertNil(try fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        XCTAssertEqual(fixture.store.reads, 3)
        XCTAssertEqual(fixture.store.mutations, 0)
    }

    func testPrepareDeniesPublicationWhenFinalReadinessCallbackReplacesBinding() throws {
        let fixture = installedHost()
        let replacement = ZeroOneSharePermitRegistry()
        let generation = replacement.currentGeneration
        XCTAssertTrue(replacement.activate(generation))
        var checks = 0
        fixture.host.installAuditedReadiness { [weak host = fixture.host] in
            checks += 1
            if checks == 3 { host?.installSharePermitRegistry(replacement, for: generation) }
            return true
        }
        XCTAssertNil(try fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(fixture.store.mutations, 0)
        let fresh = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        XCTAssertTrue(fresh.lifetime.allows(fresh.id))
        fixture.registry.revokeAll()
        XCTAssertTrue(fresh.lifetime.allows(fresh.id))
        replacement.revokeAll()
        XCTAssertFalse(fresh.lifetime.allows(fresh.id))
    }

    func testFreshSourceDeniesWhenStoreRevokesDuringFirstManifestRead() throws {
        let fixture = installedHost()
        let route = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        let trigger = fixture.store.reads + 1
        fixture.store.onLoad = { [registry = fixture.registry] count in
            if count == trigger { registry.revocationRegistration.revokeBeforeChange() }
        }
        XCTAssertNil(fixture.host.freshSource(route.source, for: route))
        XCTAssertFalse(route.lifetime.allows(route.id))
        XCTAssertEqual(fixture.store.mutations, 0)
    }

    func testFreshSourceDeniesWhenFinalReadinessCallbackRevokesAndReopensRegistry() throws {
        let fixture = installedHost()
        var checks = 0
        var revokeOnCheck: Int?
        fixture.host.installAuditedReadiness { [registry = fixture.registry] in
            checks += 1
            if checks == revokeOnCheck {
                registry.revocationRegistration.revokeBeforeChange()
                XCTAssertTrue(registry.activate(registry.currentGeneration))
            }
            return true
        }
        let route = try XCTUnwrap(fixture.host.prepare(first: fixture.store.records[0], second: fixture.store.records[1]))
        revokeOnCheck = checks + 2
        XCTAssertNil(fixture.host.freshSource(route.source, for: route))
        XCTAssertFalse(route.lifetime.allows(route.id))
        XCTAssertEqual(fixture.store.mutations, 0)
    }

    private func assertDenied(_ permit: PhotoComparisonShareExportPermit, data: Data,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try permit.authorizedData(data), file: file, line: line) {
            XCTAssertEqual($0 as? PhotoComparisonShareError, .unavailable, file: file, line: line)
        }
    }

    private func registeredPermit() throws -> (registry: ZeroOneSharePermitRegistry,
        registration: PhotoComparisonShareRegistration, permit: PhotoComparisonShareExportPermit,
        root: PhotoComparisonShareLifetime, version: UUID, local: PhotoComparisonShareLifetime,
        ticket: UUID, png: Data) {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let version = UUID(), ticket = UUID()
        let root = PhotoComparisonShareLifetime(sourceVersion: version)
        let local = PhotoComparisonShareLifetime(sourceVersion: ticket)
        let registration = try XCTUnwrap(PhotoComparisonShareRegistration.acquire(lifetime: root,
            sourceVersion: version, registry: registry, generation: generation))
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let permit = PhotoComparisonShareExportPermit(reviewedPNG: png, rootLifetime: root,
            rootVersion: version, localLifetime: local, ticket: ticket)
        return (registry, registration, permit, root, version, local, ticket, png)
    }

    private func installedHost() -> (host: PhotoComparisonShareHostAuthority, store: Store,
                                   registry: ZeroOneSharePermitRegistry) {
        let store = Store()
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        let host = PhotoComparisonShareHostAuthority(store: store)
        host.installAuditedReadiness { true }
        host.installSharePermitRegistry(registry, for: generation)
        return (host, store, registry)
    }

    /// Same persistence API as the frozen host fixture, with synchronous callbacks
    /// added only to expose revocation between known reads. No local file I/O.
    private final class Store: ProgressPhotoPersisting {
        var isAvailable = true
        var reads = 0
        var mutations = 0
        var requestedPaths: [String] = []
        var onLoad: ((Int) -> Void)?
        var records: [ProgressPhotoRecord] = [Store.record(1), Store.record(2)]
        private static func record(_ value: Int) -> ProgressPhotoRecord {
            let id = UUID(uuidString: value == 1 ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002")!
            let paths = LocalProgressPhotoStore.relativePaths(for: id)
            return .init(id: id, createdAt: Date(timeIntervalSince1970: Double(value)), label: .progress,
                imageRelativePath: paths.image, thumbnailRelativePath: paths.thumbnail)
        }
        func loadRecords() throws -> [ProgressPhotoRecord] {
            reads += 1
            onLoad?(reads)
            return records
        }
        func data(at path: String, for record: ProgressPhotoRecord) -> Data? {
            requestedPaths.append(path)
            return records.contains(record) ? Data([UInt8(record.createdAt.timeIntervalSince1970)]) : nil
        }
        func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws { mutations += 1 }
        func delete(_ record: ProgressPhotoRecord) throws { mutations += 1 }
    }
}
