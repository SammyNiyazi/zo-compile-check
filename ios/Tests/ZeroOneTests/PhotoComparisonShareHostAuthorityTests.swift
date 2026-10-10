import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class PhotoComparisonShareHostAuthorityTests: XCTestCase {
    func testUninstalledAuthorityIsClosedWithoutReadingActualStore() throws {
        let store = Store(); let host = PhotoComparisonShareHostAuthority(store: store)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
        XCTAssertEqual(store.reads, 0)
    }

    func testUnknownFixtureStoreStaysClosedEvenWithReadiness() throws {
        let store = Store(); let host = PhotoComparisonShareHostAuthority(store: nil)
        host.installAuditedReadiness { true }
        XCTAssertFalse(host.isInstalled)
        XCTAssertNil(try host.prepare(first: store.records[0], second: store.records[1]))
    }

    func testFreshReadsPreserveExactSelectedOrderAndMasterPaths() throws {
        let store = Store(); let host = PhotoComparisonShareHostAuthority(store: store)
        installSyntheticRegistry(on: host)
        host.installAuditedReadiness { true }
        let route = try XCTUnwrap(host.prepare(first: store.records[1], second: store.records[0]))
        XCTAssertEqual(route.source.first.record, store.records[1])
        XCTAssertEqual(route.source.second.record, store.records[0])
        XCTAssertFalse(route.source.hasStrictChronology)
        XCTAssertGreaterThanOrEqual(store.reads, 3)
        XCTAssertTrue(store.requestedPaths.allSatisfy { $0.hasSuffix("/master.jpg") })
        XCTAssertNotNil(host.freshSource(route.source, for: route))
        XCTAssertEqual(store.mutations, 0)
    }

    func testRevocationPermanentlyClosesRetainedRouteAfterByteIdenticalRecovery() throws {
        let store = Store(); let host = PhotoComparisonShareHostAuthority(store: store)
        installSyntheticRegistry(on: host)
        host.installAuditedReadiness { true }
        let route = try XCTUnwrap(host.prepare(first: store.records[0], second: store.records[1]))
        let records = store.records
        host.revokeAll(before: .photoMutation)
        store.records = []
        store.records = records
        XCTAssertFalse(route.lifetime.allows(route.id))
        XCTAssertNil(host.freshSource(route.source, for: route))
        let replacement = try XCTUnwrap(host.prepare(first: records[0], second: records[1]))
        XCTAssertNotEqual(route.id, replacement.id)
        XCTAssertTrue(replacement.lifetime.allows(replacement.id))
    }

    func testCloseAndReadinessReplacementRevokeOutsideRetainedDocuments() throws {
        let store = Store(); let host = PhotoComparisonShareHostAuthority(store: store)
        installSyntheticRegistry(on: host)
        host.installAuditedReadiness { true }
        let closed = try XCTUnwrap(host.prepare(first: store.records[0], second: store.records[1]))
        host.close(closed)
        XCTAssertFalse(closed.lifetime.allows(closed.id))
        let route = try XCTUnwrap(host.prepare(first: store.records[0], second: store.records[1]))
        host.installAuditedReadiness { false }
        XCTAssertFalse(route.lifetime.allows(route.id))
        XCTAssertNil(host.freshSource(route.source, for: route))
    }

    private func installSyntheticRegistry(on host: PhotoComparisonShareHostAuthority) {
        let registry = ZeroOneSharePermitRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.activate(generation))
        host.installSharePermitRegistry(registry, for: generation)
    }

    private final class Store: ProgressPhotoPersisting {
        var isAvailable = true
        var reads = 0
        var mutations = 0
        var requestedPaths: [String] = []
        var records: [ProgressPhotoRecord] = [Store.record(1), Store.record(2)]
        private static func record(_ value: Int) -> ProgressPhotoRecord {
            let id = UUID(uuidString: value == 1 ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002")!
            let paths = LocalProgressPhotoStore.relativePaths(for: id)
            return .init(id: id, createdAt: Date(timeIntervalSince1970: Double(value)), label: .progress,
                imageRelativePath: paths.image, thumbnailRelativePath: paths.thumbnail)
        }
        func loadRecords() throws -> [ProgressPhotoRecord] { reads += 1; return records }
        func data(at path: String, for record: ProgressPhotoRecord) -> Data? {
            requestedPaths.append(path)
            return records.contains(record) ? Data([UInt8(record.createdAt.timeIntervalSince1970)]) : nil
        }
        func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws { mutations += 1 }
        func delete(_ record: ProgressPhotoRecord) throws { mutations += 1 }
    }
}
