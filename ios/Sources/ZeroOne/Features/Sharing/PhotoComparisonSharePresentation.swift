import Foundation

/// Full saved originals, never thumbnails or external file URLs. Values are
/// deliberately immutable so an open review cannot change underneath a tap.
struct PhotoComparisonShareImage: Equatable, Sendable {
    let record: ProgressPhotoRecord
    let imageData: Data
}

struct PhotoComparisonShareSource: Equatable, Sendable {
    let first: PhotoComparisonShareImage
    let second: PhotoComparisonShareImage

    // Preserve the caller's reviewed order. Equal or reversed dates cannot be
    // described as before/after, even if a sort could manufacture that order.
    var hasStrictChronology: Bool { first.record.createdAt < second.record.createdAt }
}

struct PhotoComparisonShareSnapshot: Equatable, Sendable {
    let records: [ProgressPhotoRecord]
    let originalImageData: [UUID: Data]
}

struct PhotoComparisonShareOptions: Equatable, Sendable {
    var includeDates = false
    var includeLabels = false
}

enum PhotoComparisonShareError: Error, Equatable {
    case unavailable, duplicateIdentity, invalidRecord, missingRecord
    case changedRecord, unreadableImage, changedImage
}

enum PhotoComparisonShareAuthority {
    static func capture(
        first: ProgressPhotoRecord,
        second: ProgressPhotoRecord,
        snapshot: PhotoComparisonShareSnapshot
    ) throws -> PhotoComparisonShareSource {
        guard first.id != second.id else { throw PhotoComparisonShareError.duplicateIdentity }
        try validateRecords(snapshot.records)
        let firstImage = try image(for: first, in: snapshot)
        let secondImage = try image(for: second, in: snapshot)
        return PhotoComparisonShareSource(first: firstImage, second: secondImage)
    }

    static func validate(
        _ source: PhotoComparisonShareSource,
        current: PhotoComparisonShareSnapshot?
    ) throws {
        guard let current else { throw PhotoComparisonShareError.unavailable }
        let fresh = try capture(first: source.first.record, second: source.second.record, snapshot: current)
        guard fresh.first.imageData == source.first.imageData,
              fresh.second.imageData == source.second.imageData else {
            throw PhotoComparisonShareError.changedImage
        }
    }

    /// Use the retained app-owned persistence instance, not repository.entries.
    /// This is a bounded read-only observation, not a lock across OS delivery.
    /// Root must also invalidate sourceVersion for deletion/recovery transitions.
    static func read(
        store: any ProgressPhotoPersisting,
        source: PhotoComparisonShareSource
    ) throws -> PhotoComparisonShareSnapshot {
        guard store.isAvailable else { throw PhotoComparisonShareError.unavailable }
        let before = try store.loadRecords()
        try validateRecords(before)
        let selected = [source.first.record, source.second.record]
        var bytes: [UUID: Data] = [:]
        for record in selected {
            guard let current = before.first(where: { $0.id == record.id }) else {
                throw PhotoComparisonShareError.missingRecord
            }
            guard current == record else { throw PhotoComparisonShareError.changedRecord }
            guard let data = store.data(at: record.imageRelativePath, for: record), !data.isEmpty else {
                throw PhotoComparisonShareError.unreadableImage
            }
            bytes[record.id] = data
        }
        guard store.isAvailable else { throw PhotoComparisonShareError.unavailable }
        let after = try store.loadRecords()
        try validateRecords(after)
        guard before.sorted(by: byIdentity) == after.sorted(by: byIdentity) else {
            throw PhotoComparisonShareError.changedRecord
        }
        for record in selected {
            guard let data = store.data(at: record.imageRelativePath, for: record), !data.isEmpty else {
                throw PhotoComparisonShareError.unreadableImage
            }
            guard data == bytes[record.id] else { throw PhotoComparisonShareError.changedImage }
        }
        guard store.isAvailable else { throw PhotoComparisonShareError.unavailable }
        let snapshot = PhotoComparisonShareSnapshot(records: after, originalImageData: bytes)
        try validate(source, current: snapshot)
        return snapshot
    }

    private static func byIdentity(_ lhs: ProgressPhotoRecord, _ rhs: ProgressPhotoRecord) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validateRecords(_ records: [ProgressPhotoRecord]) throws {
        guard Set(records.map(\.id)).count == records.count else {
            throw PhotoComparisonShareError.duplicateIdentity
        }
        for record in records {
            guard record.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  ownedPath(record.imageRelativePath, id: record.id, filename: "master.jpg"),
                  ownedPath(record.thumbnailRelativePath, id: record.id, filename: "thumbnail.jpg") else {
                throw PhotoComparisonShareError.invalidRecord
            }
        }
    }

    private static func ownedPath(_ path: String, id: UUID, filename: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].lowercased() == id.uuidString.lowercased()
            && parts[1] == Substring(filename) && !path.hasPrefix("/")
    }

    private static func image(
        for selected: ProgressPhotoRecord,
        in snapshot: PhotoComparisonShareSnapshot
    ) throws -> PhotoComparisonShareImage {
        guard let record = snapshot.records.first(where: { $0.id == selected.id }) else {
            throw PhotoComparisonShareError.missingRecord
        }
        guard record == selected else { throw PhotoComparisonShareError.changedRecord }
        guard let bytes = snapshot.originalImageData[selected.id], !bytes.isEmpty else {
            throw PhotoComparisonShareError.unreadableImage
        }
        // Decode/readability is also checked by the raster renderer before any
        // image is reviewable. Pure authority retains all exact original bytes.
        return PhotoComparisonShareImage(record: record, imageData: bytes)
    }
}

/// Both sheet-local operation tickets and root's source version are required.
/// Byte equality alone cannot detect a transient delete followed by recovery.
struct PhotoComparisonShareGeneration: Equatable, Sendable {
    private(set) var revision = UUID()

    mutating func invalidate() { revision = UUID() }

    func accepts(
        _ ticket: UUID,
        sourceVersion: UUID,
        currentSourceVersion: UUID,
        isActive: Bool,
        isCancelled: Bool
    ) -> Bool {
        revision == ticket && sourceVersion == currentSourceVersion && isActive && !isCancelled
    }
}

/// The only egress payload. No record IDs, paths, original metadata or image
/// bytes are forwarded to destinations. The preview decodes these same bytes.
struct PhotoComparisonShareRaster: Equatable, Sendable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Revocation remains visible to a system document that outlives its SwiftUI
/// sheet. Root owns one token per presentation, invalidating it BEFORE teardown,
/// source mutation, deletion or recovery. A token can never be reactivated.
/// FileDocument may read this on a background thread; no UI state is consulted.
final class PhotoComparisonShareLifetime: ZeroOneShareRevocablePermit, @unchecked Sendable {
    private let lock = NSLock()
    private let sourceVersion: UUID
    private var isValid = true

    init(sourceVersion: UUID) { self.sourceVersion = sourceVersion }

    func allows(_ version: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isValid && sourceVersion == version
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        isValid = false
    }
}
