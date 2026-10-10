import Foundation

/// App-owned authorization for a saved-data image. The complete acknowledged
/// input is checked again, including history used to derive a personal best.
/// This check does not grant permission to publish or activate a service.
@MainActor
enum SavedShareExportAuthority {
    static func verify<Record: Identifiable & Equatable>(
        expected: [Record],
        readCurrentRecords: @MainActor () async throws -> [Record],
        isReady: @MainActor () throws -> Bool
    ) async -> Bool {
        do {
            guard !Task.isCancelled, try isReady(), !expected.isEmpty,
                  Set(expected.map(\.id)).count == expected.count else { return false }
            let current = try await readCurrentRecords()
            // Actor reads can suspend. Recovery, deletion or a new activity can
            // invalidate permission while the records are being retrieved.
            guard !Task.isCancelled, try isReady(),
                  Set(current.map(\.id)).count == current.count else { return false }
            return current == expected
        } catch {
            // An unreadable store is unavailable, never a usable cached value.
            return false
        }
    }
}
