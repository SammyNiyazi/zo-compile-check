import Foundation

enum ZeroOneSocialError: Error, Equatable {
    case unavailable, authenticationRequired, invalidSelection, consentRequired, forbidden, staleSession
}

/// Social is a separate release capability. Account sign-in never enables it.
struct ZeroOneSocialReadiness: Equatable, Sendable {
    let serviceAccepted: Bool
    let privacyAccepted: Bool
    let moderationOperational: Bool
    let nearbyAccepted: Bool

    static let disabled = Self(serviceAccepted: false, privacyAccepted: false,
                               moderationOperational: false, nearbyAccepted: false)
    var socialEnabled: Bool { serviceAccepted && privacyAccepted && moderationOperational }
    var nearbyEnabled: Bool { socialEnabled && nearbyAccepted }
}

enum ZeroOneSocialAudience: String, Codable, Sendable {
    case community, followers, friends, selected
}

enum ZeroOneSocialDiscoverability: String, Codable, Sendable {
    case privateProfile = "private"
    case community
}

struct ZeroOneSocialProfile: Codable, Equatable, Sendable {
    let accountID: UUID
    let handle: String
    let displayName: String
    let discoverability: ZeroOneSocialDiscoverability
}

/// Deliberately selected public training text/numbers, never a WorkoutHistoryEntry or Health object.
/// No source workout ID, route, photo, body measurement, nutrition or background export is accepted.
struct ZeroOneSocialSelectedSet: Codable, Equatable, Sendable {
    let exercise: String
    let reps: Int?
    let seconds: Int?
    let load: Double?
    let unit: String?

    var isValid: Bool {
        !exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && exercise.count <= 120
            && ((reps.map { (1...10000).contains($0) } ?? false)
                != (seconds.map { (1...86400).contains($0) } ?? false))
            && (reps == nil || seconds == nil)
            && (load.map { $0.isFinite && (0...10000).contains($0) } ?? true)
            && ((load == nil && unit == nil) || (load != nil && ["kg", "lb"].contains(unit ?? "")))
    }
}

struct ZeroOneSocialPostSelection: Equatable, Sendable {
    /// Stable for one explicit Publish action and all of its network retries.
    let id: UUID
    let text: String
    let sets: [ZeroOneSocialSelectedSet]
    let audience: ZeroOneSocialAudience
    let recipients: Set<UUID>
    let publishConfirmed: Bool

    func validate() throws {
        guard publishConfirmed else { throw ZeroOneSocialError.consentRequired }
        guard text.count <= 2000, sets.count <= 100, sets.allSatisfy(\.isValid),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sets.isEmpty,
              (audience == .selected ? (!recipients.isEmpty && recipients.count <= 100) : recipients.isEmpty)
        else { throw ZeroOneSocialError.invalidSelection }
    }
}

enum ZeroOneSocialConnectionAction: String, Sendable {
    case request, accept, decline, remove, follow, unfollow, block, unblock
}

struct ZeroOneNearbySelection: Equatable, Sendable {
    /// A stopped/expired ID is never reused. A new consent action needs a new UUID.
    let id: UUID
    let recipientID: UUID
    let expiresAt: Date
    let sharingConfirmed: Bool

    func validate(now: Date, maximumDuration: TimeInterval) throws {
        guard sharingConfirmed else { throw ZeroOneSocialError.consentRequired }
        guard maximumDuration.isFinite, maximumDuration > 0,
              expiresAt.timeIntervalSince(now) > 0,
              expiresAt.timeIntervalSince(now) <= maximumDuration
        else { throw ZeroOneSocialError.invalidSelection }
    }
}

struct ZeroOneNearbyFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyMetres: Double
    let capturedAt: Date

    func validate(now: Date, maximumAge: TimeInterval) throws {
        guard latitude.isFinite, (-90...90).contains(latitude), longitude.isFinite,
              (-180...180).contains(longitude), accuracyMetres.isFinite, accuracyMetres > 0,
              maximumAge.isFinite, maximumAge > 0, capturedAt <= now,
              now.timeIntervalSince(capturedAt) <= maximumAge
        else { throw ZeroOneSocialError.invalidSelection }
    }
}

/// Pure display policy, not server authorization. All checks are repeated by the database RPC.
enum ZeroOneSocialPolicy {
    static func canReadPost(viewer: UUID?, author: UUID, audience: ZeroOneSocialAudience,
                            selected: Set<UUID>, follows: Bool, mutualFriends: Bool,
                            blockedEitherWay: Bool, deleted: Bool, sessionActive: Bool) -> Bool {
        guard let viewer, sessionActive, !deleted, !blockedEitherWay else { return false }
        if viewer == author { return true }
        switch audience {
        case .community: return true
        case .followers: return follows
        case .friends: return mutualFriends
        case .selected: return mutualFriends && selected.contains(viewer)
        }
    }

    static func canReadNearby(sessionActive: Bool, mutualFriends: Bool, blockedEitherWay: Bool,
                              outgoingExpiresAt: Date?, incomingExpiresAt: Date?,
                              outgoingRevoked: Bool, incomingRevoked: Bool, now: Date) -> Bool {
        guard sessionActive, mutualFriends, !blockedEitherWay, !outgoingRevoked, !incomingRevoked,
              let outgoingExpiresAt, let incomingExpiresAt else { return false }
        return outgoingExpiresAt > now && incomingExpiresAt > now
    }
}
