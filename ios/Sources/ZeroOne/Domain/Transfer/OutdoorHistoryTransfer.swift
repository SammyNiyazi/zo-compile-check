import Foundation
import Observation

struct OutdoorHistoryTransferPackage: Codable, Equatable, Sendable {
    static let formatName = "01.outdoor-history"
    static let currentSchemaVersion = 1
    static let fullRoutePolicy = "full recorded route state; deleted routes remain deleted"
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let routePolicy: String
    let records: [OutdoorActivityRecord]

    init(records: [OutdoorActivityRecord], exportedAt: Date = .now) {
        format = Self.formatName
        schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        routePolicy = Self.fullRoutePolicy
        self.records = records
    }
}

enum OutdoorHistoryTransferError: Error, Equatable, LocalizedError {
    case invalidFile, unsupportedSchema, oversizedFile, invalidRecords, conflictingIdentifier
    case outdoorInProgress, appGateBlocked, storeUnavailable, storeChanged, reviewExpired
    case routeAcknowledgementRequired, writeUnconfirmed, busy

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose an 01 outdoor-history transfer JSON file. Older general exports cannot restore full outdoor records."
        case .unsupportedSchema: "This outdoor transfer version is not supported. No records were saved."
        case .oversizedFile: "Choose an outdoor transfer JSON file smaller than 16 MB."
        case .invalidRecords: "Outdoor records could not be validated without changing their meaning. No records were saved."
        case .conflictingIdentifier: "An outdoor identifier has different saved values. The entire import is blocked, including previously deleted routes."
        case .outdoorInProgress: "Finish or resolve the active or recoverable walk or run before transferring history."
        case .appGateBlocked: "Resolve active or recoverable work before transferring outdoor history."
        case .storeUnavailable: "Saved outdoor state could not be read. Transfer is blocked to protect it."
        case .storeChanged: "Saved outdoor history changed after review. Start a fresh review."
        case .reviewExpired: "Start a fresh review before transferring records."
        case .routeAcknowledgementRequired: "Acknowledge the recorded route coordinates before exporting or importing."
        case .writeUnconfirmed: "Saving could not be confirmed. Check saved history without writing again before a fresh review."
        case .busy: "Wait for the current transfer operation to finish."
        }
    }
}

enum OutdoorHistoryTransferMode: Equatable, Sendable { case exporting, importing }
/// Review-only identity keeps exact duplicate source rows separately reviewable.
/// It is never encoded into a record or assigned to a recorded coordinate fix.
struct OutdoorHistoryTransferReviewRow: Identifiable, Sendable {
    let id = UUID()
    let record: OutdoorActivityRecord
}
struct OutdoorHistoryTransferReview: Identifiable, Sendable {
    let id: UUID
    let mode: OutdoorHistoryTransferMode
    let package: OutdoorHistoryTransferPackage
    let appendedCount: Int
    let skippedCount: Int
    let rows: [OutdoorHistoryTransferReviewRow]
    init(id: UUID, mode: OutdoorHistoryTransferMode, package: OutdoorHistoryTransferPackage, appendedCount: Int, skippedCount: Int) {
        self.id = id
        self.mode = mode
        self.package = package
        self.appendedCount = appendedCount
        self.skippedCount = skippedCount
        rows = package.records.map { OutdoorHistoryTransferReviewRow(record: $0) }
    }
    var records: [OutdoorActivityRecord] { package.records }
    var coordinateCount: Int { records.reduce(0) { $0 + ($1.route?.segments.reduce(0) { $0 + $1.points.count } ?? 0) } }
    var deletedRouteCount: Int { records.filter { $0.routeDeletedAt != nil }.count }
}
struct OutdoorHistoryTransferResult: Sendable {
    let confirmedRecords: [OutdoorActivityRecord]
    let appendedCount: Int
    let skippedCount: Int
}

/// Optional fault seam affects only transfer writes. Production leaves it nil.
/// Ordinary recorder/checkpoint/finish/delete behavior remains unchanged.
enum OutdoorHistoryTransferIOPhase: Equatable, Sendable { case beforeWrite, afterWrite, beforeReadback }

@MainActor
@Observable
final class OutdoorHistoryTransferCoordinator {
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private let repository: OutdoorActivityRepository
    private let canTransfer: @MainActor () throws -> Bool
    private(set) var review: OutdoorHistoryTransferReview?
    private(set) var needsReconciliation = false
    private(set) var isBusy = false

    init(repository: OutdoorActivityRepository, canTransfer: @escaping @MainActor () throws -> Bool) {
        self.repository = repository
        self.canTransfer = canTransfer
    }

    /// Synchronous invalidation only; this capability never grants export.
    /// Retire old and distinct incoming permits before replacing/removing it.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    func prepareImport(data: Data) async throws -> OutdoorHistoryTransferReview {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        guard !needsReconciliation else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        // Failed replacement reviews cannot leave a previous confirmation active.
        let oldID = review?.id
        review = nil
        try await repository.discardHistoryTransferReview(reviewID: oldID)
        try checkGate()
        let decoding = Task.detached(priority: .userInitiated) { try OutdoorHistoryTransferDecoder.decode(data) }
        let package = try await withTaskCancellationHandler(operation: { try await decoding.value }, onCancel: { decoding.cancel() })
        try Task.checkCancellation()
        try checkGate() // fresh immediately before the actor hop
        let next = try await repository.prepareHistoryImport(package)
        review = next
        return next
    }

    func prepareExport() async throws -> OutdoorHistoryTransferReview {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        guard !needsReconciliation else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        let oldID = review?.id
        review = nil
        try await repository.discardHistoryTransferReview(reviewID: oldID)
        try checkGate()
        let next = try await repository.prepareHistoryExport()
        review = next
        return next
    }

    func confirmImport(reviewID: UUID, acknowledgesRouteData: Bool) async throws -> OutdoorHistoryTransferResult {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        guard review?.id == reviewID else { throw OutdoorHistoryTransferError.reviewExpired }
        guard !needsReconciliation else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        try checkGate()
        do {
            let result = try await repository.confirmHistoryImport(reviewID: reviewID, acknowledgesRouteData: acknowledgesRouteData)
            review = nil
            return result
        } catch {
            // The actor is the authority on whether a write was actually attempted.
            let unconfirmed = await repository.historyTransferNeedsReconciliation(reviewID: reviewID)
            shareRevocationRegistration?.revokeBeforeChange(); needsReconciliation = unconfirmed
            throw error
        }
    }

    func confirmExport(reviewID: UUID, acknowledgesRouteData: Bool) async throws -> Data {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        guard review?.id == reviewID else { throw OutdoorHistoryTransferError.reviewExpired }
        try checkGate()
        return try await repository.confirmHistoryExport(reviewID: reviewID, acknowledgesRouteData: acknowledgesRouteData)
    }

    func reconcile(reviewID: UUID) async throws -> OutdoorHistoryTransferResult? {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        try checkGate()
        let result = try await repository.reconcileHistoryImport(reviewID: reviewID)
        review = nil
        shareRevocationRegistration?.revokeBeforeChange(); needsReconciliation = false
        return result
    }

    func discardReview() async throws {
        try begin()
        defer { shareRevocationRegistration?.revokeBeforeChange(); isBusy = false }
        if needsReconciliation { try checkGate() }
        try await repository.discardHistoryTransferReview(reviewID: review?.id)
        review = nil
        shareRevocationRegistration?.revokeBeforeChange(); needsReconciliation = false
    }

    private func begin() throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard !isBusy else { throw OutdoorHistoryTransferError.busy }
        shareRevocationRegistration?.revokeBeforeChange(); isBusy = true
    }
    private func checkGate() throws {
        guard try canTransfer() else { throw OutdoorHistoryTransferError.appGateBlocked }
    }
}
