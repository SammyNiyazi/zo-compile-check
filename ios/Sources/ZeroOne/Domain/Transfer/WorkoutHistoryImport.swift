import Foundation
import Observation

enum WorkoutHistoryImportError: Error, Equatable, LocalizedError {
    case oversizedFile, invalidFile, unsupportedSchema, workoutsNotSelected
    case invalidHistory, conflictingIdentifier, historyUnavailable
    case workoutInProgress, reviewExpired, historyChanged, writeUnconfirmed

    var errorDescription: String? {
        switch self {
        case .oversizedFile: "Choose a JSON export smaller than 16 MB."
        case .invalidFile: "This file is not a supported 01 JSON export. No records were saved."
        case .unsupportedSchema: "This export version is not supported. No records were saved."
        case .workoutsNotSelected: "This export does not include workout history."
        case .invalidHistory: "Workout records could not be validated without changing their meaning. No records were saved."
        case .conflictingIdentifier: "A saved identifier has different records in this file. The entire import is blocked."
        case .historyUnavailable: "Saved history could not be read. Import is blocked to protect it."
        case .workoutInProgress: "Finish or resolve your active or recoverable workout before importing history."
        case .reviewExpired: "Choose the file again and review its records before importing."
        case .historyChanged: "Saved history changed after review. Choose the file again for a fresh review."
        case .writeUnconfirmed: "Import could not be confirmed. Keep this review and retry to check saved history before another write."
        }
    }
}

struct WorkoutHistoryImportReview: Identifiable {
    let id: UUID
    let schemaVersion: Int
    let exportedAt: Date
    let records: [WorkoutHistoryEntry]
    let appendedCount: Int
    let skippedCount: Int
    let summaryOnlyCount: Int
    let legacyEffortCount: Int
    let untouchedCategories: [String]
}

struct WorkoutHistoryImportResult {
    let confirmedEntries: [WorkoutHistoryEntry]
    let appendedCount: Int
    let skippedCount: Int
}

/// All app-side history mutations and the import gate execute on the main actor.
/// There is no suspension between the fresh gate/read and the atomic store write.
/// Production uses FileWorkoutHistoryStore. Injected stores must replace the whole
/// collection atomically; this coordinator never performs per-record writes.
@MainActor
@Observable
final class WorkoutHistoryImportCoordinator {
    private let store: any WorkoutHistoryPersisting
    private let canImport: @MainActor () throws -> Bool
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private var pending: Pending?
    private(set) var review: WorkoutHistoryImportReview?
    private(set) var needsReconciliation = false

    private struct Pending {
        let review: WorkoutHistoryImportReview
        let original: [WorkoutHistoryEntry]
        let expected: [WorkoutHistoryEntry]
    }

    init(store: any WorkoutHistoryPersisting = FileWorkoutHistoryStore(),
         canImport: @escaping @MainActor () throws -> Bool) {
        self.store = store
        self.canImport = canImport
    }

    /// This capability revokes retained permits synchronously; it never grants export.
    /// Replacement/removal revokes old and incoming permits before changing ownership.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Root must verify the exact nonnil installed capability before granting export.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    /// Starts a new read-only review after an explicitly abandoned confirmation.
    /// Saved bytes are never rolled back or erased; choosing the same export again
    /// rechecks identifiers against the fresh store and skips exact records.
    func discardReview() {
        shareRevocationRegistration?.revokeBeforeChange()
        pending = nil
        review = nil
        needsReconciliation = false
    }

    func prepare(data: Data) throws -> WorkoutHistoryImportReview {
        shareRevocationRegistration?.revokeBeforeChange()
        // A failed write must be reconciled through its existing review first.
        guard !needsReconciliation else { throw WorkoutHistoryImportError.writeUnconfirmed }
        pending = nil
        review = nil
        try checkGate()
        let source = try WorkoutHistoryImportDecoder.decode(data)
        let original = try readHistory()
        var byID = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        var added: [WorkoutHistoryEntry] = []
        var skipped = 0
        for entry in source.entries {
            if let existing = byID[entry.id] {
                // Exact equality includes unknown versus known metadata. A summary
                // is never permission to enrich or replace a historical record.
                guard existing == entry else { throw WorkoutHistoryImportError.conflictingIdentifier }
                skipped += 1
            } else {
                byID[entry.id] = entry
                added.append(entry)
            }
        }
        let expected = (original + added).sorted(by: WorkoutHistoryEntry.newestFirst)
        try WorkoutHistoryImportDecoder.validate(expected)
        let next = WorkoutHistoryImportReview(id: UUID(), schemaVersion: source.schemaVersion,
            exportedAt: source.exportedAt, records: source.entries,
            appendedCount: added.count, skippedCount: skipped,
            summaryOnlyCount: source.entries.filter { $0.exercises == nil }.count,
            legacyEffortCount: source.entries.flatMap { $0.exercises ?? [] }
                .flatMap(\.completedSets).filter { $0.rir.map { !(0...5).contains($0) } ?? false }.count,
            untouchedCategories: source.untouchedCategories)
        pending = Pending(review: next, original: original, expected: expected)
        review = next
        return next
    }

    func confirm(reviewID: UUID) throws -> WorkoutHistoryImportResult {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let pending, pending.review.id == reviewID else { throw WorkoutHistoryImportError.reviewExpired }
        try checkGate()
        let fresh = try readHistory()
        // A previous atomic write can have landed even when acknowledgement failed.
        // Reconcile exact full collections, never just the imported identifiers.
        if needsReconciliation && fresh == pending.expected {
            return finish(pending, entries: fresh)
        }
        guard fresh == pending.original else {
            if !needsReconciliation { self.pending = nil; review = nil }
            throw WorkoutHistoryImportError.historyChanged
        }
        if pending.review.appendedCount == 0 { return finish(pending, entries: fresh) }
        needsReconciliation = true
        do {
            try store.save(pending.expected)
            let confirmed = try readHistory()
            guard confirmed == pending.expected else { throw WorkoutHistoryImportError.writeUnconfirmed }
            return finish(pending, entries: confirmed)
        } catch {
            // No success publication and no rollback after an ambiguous write.
            // Retry re-reads the store and either confirms or writes the same payload.
            throw WorkoutHistoryImportError.writeUnconfirmed
        }
    }

    private func checkGate() throws {
        guard try canImport() else { throw WorkoutHistoryImportError.workoutInProgress }
    }

    private func readHistory() throws -> [WorkoutHistoryEntry] {
        do {
            guard store.isAvailable else { throw WorkoutHistoryImportError.historyUnavailable }
            let entries = try store.load()
            try WorkoutHistoryImportDecoder.validate(entries)
            return entries.sorted(by: WorkoutHistoryEntry.newestFirst)
        } catch { throw WorkoutHistoryImportError.historyUnavailable }
    }

    private func finish(_ pending: Pending, entries: [WorkoutHistoryEntry]) -> WorkoutHistoryImportResult {
        let result = WorkoutHistoryImportResult(confirmedEntries: entries,
            appendedCount: pending.review.appendedCount, skippedCount: pending.review.skippedCount)
        self.pending = nil
        review = nil
        needsReconciliation = false
        return result
    }
}
