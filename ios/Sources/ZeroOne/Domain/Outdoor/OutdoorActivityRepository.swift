import Foundation

extension Notification.Name {
    static let outdoorHistoryDidChange = Notification.Name("01.outdoorHistoryDidChange")
}

enum OutdoorActivityKind: String, Codable, Equatable, Sendable {
    case walk
    case run
}

enum OutdoorTrackingMode: String, Codable, Equatable, Sendable {
    case route
    case timerOnly
}

enum OutdoorActivityPhase: String, Codable, Equatable, Sendable {
    case recording
    case paused
    case readyToSave
}

enum OutdoorActivityRecoveryState: Equatable, Sendable {
    case needsExplicitResume
    case paused
    case savePending
}

struct OutdoorActivityCheckpoint: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let kind: OutdoorActivityKind
    let trackingMode: OutdoorTrackingMode
    let startedAt: Date
    var checkpointedAt: Date
    var revision: Int
    var confirmedActiveSeconds: TimeInterval
    var phase: OutdoorActivityPhase
    var finishedAt: Date?
    var route: OutdoorRouteAccumulator
    var steps: OutdoorStepAccumulator

    init(
        id: UUID = UUID(),
        kind: OutdoorActivityKind,
        trackingMode: OutdoorTrackingMode = .route,
        startedAt: Date,
        checkpointedAt: Date,
        revision: Int = 1,
        confirmedActiveSeconds: TimeInterval,
        phase: OutdoorActivityPhase,
        finishedAt: Date? = nil,
        route: OutdoorRouteAccumulator = OutdoorRouteAccumulator(),
        steps: OutdoorStepAccumulator = OutdoorStepAccumulator()
    ) {
        version = Self.currentVersion
        self.id = id
        self.kind = kind
        self.trackingMode = trackingMode
        self.startedAt = startedAt
        self.checkpointedAt = checkpointedAt
        self.revision = revision
        self.confirmedActiveSeconds = confirmedActiveSeconds
        self.phase = phase
        self.finishedAt = finishedAt
        self.route = route
        self.steps = steps
    }

    var recoveryState: OutdoorActivityRecoveryState {
        switch phase {
        case .recording: .needsExplicitResume
        case .paused: .paused
        case .readyToSave: .savePending
        }
    }

    var isValid: Bool {
        version == Self.currentVersion
            && revision > 0
            && startedAt.timeIntervalSinceReferenceDate.isFinite
            && checkpointedAt.timeIntervalSinceReferenceDate.isFinite
            && confirmedActiveSeconds.isFinite
            && confirmedActiveSeconds >= 0
            && (finishedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && ((phase == .readyToSave) == (finishedAt != nil))
            && (trackingMode == .route || route.segments.isEmpty)
            && route.isInternallyConsistent
            && steps.isInternallyConsistent
            && (phase == .recording || steps.activeInterval == nil)
    }
}

struct OutdoorActivityRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let kind: OutdoorActivityKind
    let trackingMode: OutdoorTrackingMode
    let startedAt: Date
    let finishedAt: Date
    let confirmedActiveSeconds: TimeInterval
    let recordedDistanceMeters: Double?
    let hasMissingLocationCoverage: Bool
    let recordedSteps: Int?
    let hasIncompleteStepCoverage: Bool
    let steps: OutdoorStepAccumulator
    var route: OutdoorRouteAccumulator?
    var routeDeletedAt: Date?

    init(checkpoint: OutdoorActivityCheckpoint, finishedAt: Date) {
        version = Self.currentVersion
        id = checkpoint.id
        kind = checkpoint.kind
        trackingMode = checkpoint.trackingMode
        startedAt = checkpoint.startedAt
        self.finishedAt = finishedAt
        confirmedActiveSeconds = checkpoint.confirmedActiveSeconds
        recordedDistanceMeters = checkpoint.route.recordedDistanceMeters
        hasMissingLocationCoverage = checkpoint.route.hasMissingLocationCoverage
        recordedSteps = checkpoint.steps.recordedSteps
        hasIncompleteStepCoverage = checkpoint.steps.hasIncompleteCoverage
        steps = checkpoint.steps
        route = checkpoint.route
        routeDeletedAt = nil
    }

    var isValid: Bool {
        guard version == Self.currentVersion,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              finishedAt.timeIntervalSinceReferenceDate.isFinite,
              confirmedActiveSeconds.isFinite,
              confirmedActiveSeconds >= 0,
              recordedDistanceMeters.map({ $0.isFinite && $0 >= 0 }) ?? true,
              recordedSteps.map({ $0 >= 0 }) ?? true,
              (trackingMode == .route || recordedDistanceMeters == nil),
              steps.isInternallyConsistent,
              steps.activeInterval == nil,
              steps.recordedSteps == recordedSteps,
              steps.hasIncompleteCoverage == hasIncompleteStepCoverage,
              (routeDeletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true) else { return false }
        if let route {
            return routeDeletedAt == nil
                && route.isInternallyConsistent
                && route.recordedDistanceMeters == recordedDistanceMeters
                && route.hasMissingLocationCoverage == hasMissingLocationCoverage
        }
        return routeDeletedAt != nil
    }
}

enum OutdoorActivityPersistenceError: Error, Equatable {
    case invalidCheckpoint
    case invalidHistory
    case conflictingActivity
    case staleCheckpoint
    case notReadyToSave
    case recordNotFound
    case verificationFailed
}

enum OutdoorFinishResult: Equatable, Sendable {
    case saved(OutdoorActivityRecord)
    case alreadySaved(OutdoorActivityRecord)
}

/// Serializes the two-file outdoor journal. It never reuses strength-workout storage.
actor OutdoorActivityRepository: OutdoorRecommendationLoading {
    private nonisolated let directory: URL?
    private let transferFault: (@Sendable (OutdoorHistoryTransferIOPhase) throws -> Void)?
    private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private var transferReview: OutdoorHistoryTransferReview?
    private var transferBaseline: [OutdoorActivityRecord]?
    private var transferExpected: [OutdoorActivityRecord]?
    private var transferUnconfirmed = false

    init(directory: URL? = nil, transferFault: (@Sendable (OutdoorHistoryTransferIOPhase) throws -> Void)? = nil) {
        self.directory = directory
        self.transferFault = transferFault
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

    /// The actor owns attempted-write reconciliation; UI mirrors may arrive later.
    var hasUnconfirmedHistoryTransfer: Bool { transferUnconfirmed }

    func loadCheckpoint() throws -> OutdoorActivityCheckpoint? {
        guard let data = try readIfPresent(fileURL("active-outdoor.json")) else { return nil }
        let checkpoint = try JSONDecoder().decode(OutdoorActivityCheckpoint?.self, from: data)
        guard checkpoint?.isValid ?? true else { throw OutdoorActivityPersistenceError.invalidCheckpoint }
        return checkpoint
    }

    func loadRecords() throws -> [OutdoorActivityRecord] {
        guard let data = try readIfPresent(fileURL("outdoor-history.json")) else { return [] }
        let records = try JSONDecoder().decode([OutdoorActivityRecord].self, from: data)
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy(\.isValid) else { throw OutdoorActivityPersistenceError.invalidHistory }
        return records
    }

    func loadRecommendationObservation() throws -> OutdoorRecommendationObservation {
        try OutdoorRecommendationObservation.load(from: recommendationHistoryURL())
    }

    /// Rechecks exact persisted bytes at synchronous increase/start boundaries.
    /// Atomic file writes supply an old-or-new observation, not an atomic
    /// transaction across outdoor history and a subsequent load-choice write.
    nonisolated func confirmsRecommendationSource(_ source: OutdoorRecommendationObservation.Source) -> Bool {
        (try? OutdoorRecommendationObservation.currentSource(at: recommendationHistoryURL())) == source
    }

    private nonisolated func recommendationHistoryURL() throws -> URL {
        let root: URL
        if let directory { root = directory }
        else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
                .appendingPathComponent("01", isDirectory: true).appendingPathComponent("Outdoor", isDirectory: true)
        }
        return root.appendingPathComponent("outdoor-history.json", isDirectory: false)
    }

    func saveCheckpoint(_ checkpoint: OutdoorActivityCheckpoint) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard checkpoint.isValid else { throw OutdoorActivityPersistenceError.invalidCheckpoint }
        if let existing = try loadCheckpoint() {
            guard existing.id == checkpoint.id else { throw OutdoorActivityPersistenceError.conflictingActivity }
            if existing == checkpoint { return }
            guard existing.phase != .readyToSave,
                  checkpoint.revision == existing.revision + 1,
                  checkpoint.confirmedActiveSeconds >= existing.confirmedActiveSeconds else {
                throw OutdoorActivityPersistenceError.staleCheckpoint
            }
        } else {
            guard checkpoint.revision == 1 else { throw OutdoorActivityPersistenceError.staleCheckpoint }
            guard !(try loadRecords().contains(where: { $0.id == checkpoint.id })) else {
                throw OutdoorActivityPersistenceError.conflictingActivity
            }
        }
        try write(JSONEncoder().encode(checkpoint), to: fileURL("active-outdoor.json"))
    }

    /// Journal order is frozen checkpoint, saved history, then active tombstone.
    /// A retry after either write is safe and never creates a second record.
    func finish(_ checkpoint: OutdoorActivityCheckpoint) throws -> OutdoorFinishResult {
        shareRevocationRegistration?.revokeBeforeChange()
        guard checkpoint.isValid, checkpoint.phase == .readyToSave,
              let finishedAt = checkpoint.finishedAt else {
            throw OutdoorActivityPersistenceError.notReadyToSave
        }
        let proposed = OutdoorActivityRecord(checkpoint: checkpoint, finishedAt: finishedAt)
        let records = try loadRecords()
        if let existing = records.first(where: { $0.id == checkpoint.id }) {
            guard existing == proposed else { throw OutdoorActivityPersistenceError.conflictingActivity }
            if let active = try loadCheckpoint() {
                guard active == checkpoint else { throw OutdoorActivityPersistenceError.conflictingActivity }
                try clearCheckpoint(expectedID: checkpoint.id)
            }
            NotificationCenter.default.post(name: .outdoorHistoryDidChange, object: nil)
            return .alreadySaved(existing)
        }

        try saveCheckpoint(checkpoint)
        try write(JSONEncoder().encode([proposed] + records), to: fileURL("outdoor-history.json"))
        try clearCheckpoint(expectedID: checkpoint.id)
        NotificationCenter.default.post(name: .outdoorHistoryDidChange, object: nil)
        return .saved(proposed)
    }

    @discardableResult
    func deleteRoute(for id: UUID, at date: Date) throws -> OutdoorActivityRecord {
        shareRevocationRegistration?.revokeBeforeChange()
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw OutdoorActivityPersistenceError.invalidHistory
        }
        guard try loadCheckpoint()?.id != id else { throw OutdoorActivityPersistenceError.conflictingActivity }
        var records = try loadRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw OutdoorActivityPersistenceError.recordNotFound
        }
        if records[index].routeDeletedAt != nil { return records[index] }
        records[index].route = nil
        records[index].routeDeletedAt = date
        try write(JSONEncoder().encode(records), to: fileURL("outdoor-history.json"))
        NotificationCenter.default.post(name: .outdoorHistoryDidChange, object: nil)
        return records[index]
    }

    @discardableResult
    func deleteSession(_ id: UUID) throws -> Bool {
        shareRevocationRegistration?.revokeBeforeChange()
        guard try loadCheckpoint()?.id != id else { throw OutdoorActivityPersistenceError.conflictingActivity }
        var records = try loadRecords()
        let oldCount = records.count
        records.removeAll { $0.id == id }
        guard records.count != oldCount else { return false }
        try write(JSONEncoder().encode(records), to: fileURL("outdoor-history.json"))
        NotificationCenter.default.post(name: .outdoorHistoryDidChange, object: nil)
        return true
    }

    // Transfer operations stay synchronous within this actor. Checkpoint checks,
    // fresh collection comparison and whole-collection write have no suspension.
    // MainActor strength/recovery gating is additional, not a cross-actor lock.
    func prepareHistoryImport(_ package: OutdoorHistoryTransferPackage) throws -> OutdoorHistoryTransferReview {
        shareRevocationRegistration?.revokeBeforeChange()
        guard !transferUnconfirmed else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        clearTransferReview()
        try Task.checkCancellation()
        let original = try readHistoryForTransfer()
        try OutdoorHistoryTransferDecoder.validate(package)
        var byID = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        var added: [OutdoorActivityRecord] = []
        var skipped = 0
        for record in package.records {
            if let existing = byID[record.id] {
                guard existing == record else { throw OutdoorHistoryTransferError.conflictingIdentifier }
                skipped += 1
            } else {
                byID[record.id] = record
                added.append(record)
            }
        }
        let expected = original + added
        try OutdoorHistoryTransferDecoder.validateRecords(expected, requireUniqueIDs: true)
        let review = OutdoorHistoryTransferReview(id: UUID(), mode: .importing,
            package: package, appendedCount: added.count, skippedCount: skipped)
        transferReview = review
        transferBaseline = original
        transferExpected = expected
        return review
    }

    func prepareHistoryExport(at date: Date = .now) throws -> OutdoorHistoryTransferReview {
        shareRevocationRegistration?.revokeBeforeChange()
        guard !transferUnconfirmed else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        clearTransferReview()
        try Task.checkCancellation()
        let records = try readHistoryForTransfer()
        let package = OutdoorHistoryTransferPackage(records: records, exportedAt: date)
        try OutdoorHistoryTransferDecoder.validate(package)
        let review = OutdoorHistoryTransferReview(id: UUID(), mode: .exporting,
            package: package, appendedCount: 0, skippedCount: 0)
        transferReview = review
        transferBaseline = records
        return review
    }

    func confirmHistoryExport(reviewID: UUID, acknowledgesRouteData: Bool) throws -> Data {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let review = transferReview, review.id == reviewID, review.mode == .exporting,
              let baseline = transferBaseline else { throw OutdoorHistoryTransferError.reviewExpired }
        guard acknowledgesRouteData else { throw OutdoorHistoryTransferError.routeAcknowledgementRequired }
        try Task.checkCancellation()
        guard try readHistoryForTransfer() == baseline else { throw OutdoorHistoryTransferError.storeChanged }
        // The package contains precisely the reviewed saved snapshot, including
        // private optional route state. No omitted/deleted coordinates are invented.
        return try OutdoorHistoryTransferDecoder.encode(review.package)
    }

    func confirmHistoryImport(reviewID: UUID, acknowledgesRouteData: Bool) throws -> OutdoorHistoryTransferResult {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let review = transferReview, review.id == reviewID, review.mode == .importing,
              let baseline = transferBaseline, let expected = transferExpected else { throw OutdoorHistoryTransferError.reviewExpired }
        guard !transferUnconfirmed else { throw OutdoorHistoryTransferError.writeUnconfirmed }
        guard acknowledgesRouteData else { throw OutdoorHistoryTransferError.routeAcknowledgementRequired }
        try Task.checkCancellation()
        guard try readHistoryForTransfer() == baseline else { throw OutdoorHistoryTransferError.storeChanged }
        // Defense in depth: every baseline identifier and value must survive.
        let byID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        guard baseline.allSatisfy({ byID[$0.id] == $0 }) else { throw OutdoorHistoryTransferError.conflictingIdentifier }
        if review.appendedCount == 0 { return finishTransferImport(review, records: baseline) }
        let data = try JSONEncoder().encode(expected)
        guard try OutdoorHistoryTransferDecoder.decodeStoredRecords(data) == expected else { throw OutdoorHistoryTransferError.invalidRecords }
        transferUnconfirmed = true
        do {
            try transferFault?(.beforeWrite)
            try write(data, to: fileURL("outdoor-history.json"))
            try transferFault?(.afterWrite)
            try transferFault?(.beforeReadback)
            let confirmed = try readHistoryForTransfer()
            guard confirmed == expected else { throw OutdoorHistoryTransferError.writeUnconfirmed }
            return finishTransferImport(review, records: confirmed)
        } catch {
            // Keep the exact expected/original collections. No rollback, replay,
            // checkpoint clear, or notification after an ambiguous write.
            throw OutdoorHistoryTransferError.writeUnconfirmed
        }
    }

    /// Reconciliation performs no write. Exact full-collection readback confirms
    /// once, baseline means retry needs a fresh review, third state blocks success.
    func reconcileHistoryImport(reviewID: UUID) throws -> OutdoorHistoryTransferResult? {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let review = transferReview, review.id == reviewID, transferUnconfirmed,
              let baseline = transferBaseline, let expected = transferExpected else { throw OutdoorHistoryTransferError.reviewExpired }
        let fresh = try readHistoryForTransfer()
        if fresh == expected { return finishTransferImport(review, records: fresh) }
        if fresh == baseline { clearTransferReview(); return nil }
        throw OutdoorHistoryTransferError.storeChanged
    }

    func historyTransferNeedsReconciliation(reviewID: UUID) -> Bool {
        transferReview?.id == reviewID && transferUnconfirmed
    }

    func discardHistoryTransferReview(reviewID: UUID?) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        if let reviewID, let current = transferReview, current.id != reviewID {
            throw OutdoorHistoryTransferError.reviewExpired
        }
        // An uncertain attempt must be checked read-only before retry can begin,
        // even when its caller deliberately abandons the confirmation review.
        if transferUnconfirmed { _ = try readHistoryForTransfer() }
        // This abandons review state only; any saved write stays on disk.
        clearTransferReview()
    }

    private func finishTransferImport(_ review: OutdoorHistoryTransferReview, records: [OutdoorActivityRecord]) -> OutdoorHistoryTransferResult {
        let result = OutdoorHistoryTransferResult(confirmedRecords: records,
            appendedCount: review.appendedCount, skippedCount: review.skippedCount)
        clearTransferReview()
        if review.appendedCount > 0 { NotificationCenter.default.post(name: .outdoorHistoryDidChange, object: nil) }
        return result
    }

    private func clearTransferReview() {
        shareRevocationRegistration?.revokeBeforeChange()
        transferReview = nil
        transferBaseline = nil
        transferExpected = nil
        transferUnconfirmed = false
    }

    private func readHistoryForTransfer() throws -> [OutdoorActivityRecord] {
        do {
            // A fresh journal checkpoint is authoritative even if the root UI
            // has not restored or observed it. Corruption fails closed as well.
            if let activeData = try readTransferFile("active-outdoor.json") {
                var syntax = ImportJSONSyntax(data: activeData)
                try syntax.validate()
                let active = try JSONDecoder().decode(OutdoorActivityCheckpoint?.self, from: activeData)
                guard active?.isValid ?? true else { throw OutdoorHistoryTransferError.storeUnavailable }
                guard active == nil else { throw OutdoorHistoryTransferError.outdoorInProgress }
            }
            guard let data = try readTransferFile("outdoor-history.json") else { return [] }
            return try OutdoorHistoryTransferDecoder.decodeStoredRecords(data)
        } catch let error as OutdoorHistoryTransferError {
            if error == .outdoorInProgress { throw error }
            // Malformed saved state is not a claim that a prior ambiguous write
            // saved nothing. Its bytes stay untouched and transfer stays blocked.
            throw OutdoorHistoryTransferError.storeUnavailable
        }
        catch { throw OutdoorHistoryTransferError.storeUnavailable }
    }

    private func readTransferFile(_ name: String) throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL(name)) }
        catch {
            let failure = error as NSError
            if failure.isMissingFile { return nil }
            throw error
        }
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = OutdoorHistoryTransferDecoder.maximumFileBytes - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw OutdoorHistoryTransferError.storeUnavailable }
            data.append(chunk)
        }
        return data
    }

    private func clearCheckpoint(expectedID: UUID) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let existing = try loadCheckpoint() else { return }
        guard existing.id == expectedID else { throw OutdoorActivityPersistenceError.conflictingActivity }
        let tombstone: OutdoorActivityCheckpoint? = nil
        try write(JSONEncoder().encode(tombstone), to: fileURL("active-outdoor.json"))
    }

    private func fileURL(_ name: String) throws -> URL {
        let root: URL
        if let directory {
            root = directory
        } else {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("01", isDirectory: true)
                .appendingPathComponent("Outdoor", isDirectory: true)
        }
        return root.appendingPathComponent(name, isDirectory: false)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            guard failure.isMissingFile else { throw error }
            return nil
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try Data(contentsOf: url) == data else {
            throw OutdoorActivityPersistenceError.verificationFailed
        }
    }
}
