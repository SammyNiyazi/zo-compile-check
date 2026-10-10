import Foundation

/// Root retains one token per exact saved-source/presentation revision and
/// revokes it BEFORE source transitions or host teardown. Never reactivate or
/// recycle a token, even after byte-identical recovery. FileDocument may read
/// validity off-main, so this boundary intentionally contains no UI state.
final class ZOShareExportLifetime: ZeroOneShareRevocablePermit, @unchecked Sendable {
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

enum ZOShareExportAuthorizationError: Error, Equatable {
    case unavailable
}

/// A document/item retains this pair, not a view closure or a cached Bool. The
/// local token binds the reviewed PNG/choices; the root token binds its source.
/// Authorization checked after completed revocation is denied. An in-flight
/// request authorized at an earlier valid decision point may still finish after
/// revoke; this check and the OS handoff are not a single atomic transaction.
struct ZOShareExportPermit: Sendable {
    let root: ZOShareExportLifetime?
    let sourceVersion: UUID?
    let review: ZOShareExportLifetime?
    let reviewVersion: UUID?

    init(root: ZOShareExportLifetime? = nil, sourceVersion: UUID? = nil,
         review: ZOShareExportLifetime? = nil, reviewVersion: UUID? = nil) {
        self.root = root
        self.sourceVersion = sourceVersion
        self.review = review
        self.reviewVersion = reviewVersion
    }

    var isAuthorized: Bool {
        guard let sourceVersion, let reviewVersion else { return false }
        return root?.allows(sourceVersion) == true && review?.allows(reviewVersion) == true
    }

    func authorizedData(_ data: Data) throws -> Data {
        guard !data.isEmpty, isAuthorized else { throw ZOShareExportAuthorizationError.unavailable }
        return data
    }
}

/// An obsolete async task cannot supply pixels or clear a newer operation.
struct ZOShareExportGeneration: Equatable, Sendable {
    private(set) var revision = UUID()

    mutating func invalidate() { revision = UUID() }

    func accepts(_ ticket: UUID, isActive: Bool, isCancelled: Bool) -> Bool {
        revision == ticket && isActive && !isCancelled
    }
}
