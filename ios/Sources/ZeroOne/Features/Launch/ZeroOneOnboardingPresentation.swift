import Foundation

/// Display-only progress. The router supplies its actual page count; no persisted
/// legacy index is reinterpreted as the proposed ten-page flow.
struct ZeroOneSetupProgress: Equatable, Sendable {
    enum Mark: Equatable, Sendable { case completed, current, ahead }
    struct Segment: Identifiable, Equatable, Sendable {
        let ordinal: Int
        let mark: Mark
        var id: Int { ordinal }
    }
    let current: Int
    let total: Int

    init?(current: Int, total: Int) {
        guard (1...10).contains(total), (1...total).contains(current) else { return nil }
        self.current = current
        self.total = total
    }

    var segments: [Segment] {
        (1...total).map { ordinal in
            Segment(ordinal: ordinal, mark: ordinal < current ? .completed : ordinal == current ? .current : .ahead)
        }
    }
}

/// Connected means the system request completed, not that each read was granted.
/// A read-only scope stays read-only in the permission copy.
struct ZeroOneSetupHealthPresentation: Equatable, Sendable {
    let scope: HealthAuthorizationScope
    let status: HealthConnectionStatus
    let issue: HealthConnectionIssue?

    var readTypes: [HealthReadDataType] { scope.readTypes.sorted { $0.rawValue < $1.rawValue } }
    var writeTypes: [HealthReadDataType] { scope.writeTypes.sorted { $0.rawValue < $1.rawValue } }
    var canRequest: Bool { status == .notConnected }
    var isRequesting: Bool { status == .connecting }
    var statusKey: String {
        switch status {
        case .notConnected: "Apple Health is optional."
        case .connecting: "Waiting for Apple Health…"
        case .connected: "Access request completed. Data appears only when available."
        case .unavailable: "Apple Health is unavailable on this device."
        }
    }
}

/// Presentation gates mirror the existing view's busy/absent-plan behavior.
/// These do not authorize a save or bypass the root's persistence validation.
struct ZeroOneSetupPlanControls: Equatable, Sendable {
    let hasPlan: Bool
    let isSaving: Bool
    let isImportingBodyWeight: Bool

    var canEdit: Bool { !isSaving && !isImportingBodyWeight }
    var canSave: Bool { hasPlan && canEdit }
    var canReload: Bool { canEdit }
}
