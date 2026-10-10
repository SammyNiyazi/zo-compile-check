import Foundation

/// Proof 12 and 48: decoded projections of supabase/migrations/202610100002_club_crews.sql.
struct ClubCrew: Decodable, Equatable, Identifiable, Sendable {
    struct Invite: Decodable, Equatable, Sendable {
        let token: String
        let expiresAt: Date
        private enum CodingKeys: String, CodingKey { case token, expiresAt = "expires_at" }
    }

    let id: UUID
    let name: String
    let anyoneWithLink: Bool
    let monthlyGoal: Int
    let isOwner: Bool
    let monthWorkouts: Int
    let members: [ClubPerson]
    let invite: Invite?

    private enum CodingKeys: String, CodingKey {
        case id, name, joinPolicy = "join_policy", monthlyGoal = "monthly_goal", isOwner = "is_owner",
             monthWorkouts = "month_workouts", members, invite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        anyoneWithLink = try values.decode(String.self, forKey: .joinPolicy) == "link"
        monthlyGoal = try values.decode(Int.self, forKey: .monthlyGoal)
        isOwner = try values.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        monthWorkouts = try values.decodeIfPresent(Int.self, forKey: .monthWorkouts) ?? 0
        members = try values.decodeIfPresent([ClubPerson].self, forKey: .members) ?? []
        invite = try values.decodeIfPresent(Invite.self, forKey: .invite)
    }

    /// The owner always invites; in an "anyone with the link" crew every member can.
    var canInvite: Bool { isOwner || anyoneWithLink }
    var trainedThisWeek: Int { members.filter(\.trainedThisWeek).count }
}

struct ClubCrewList: Decodable, Sendable { let crews: [ClubCrew] }

struct ClubCrewInviteToken: Decodable, Sendable {
    let token: String
    let expiresAt: Date
    private enum CodingKeys: String, CodingKey { case token, expiresAt = "expires_at" }
}

/// What an invite shows before joining: the crew, who invited, how many, this month.
struct ClubCrewInvitePreview: Decodable, Equatable, Sendable {
    let crewID: UUID
    let name: String
    let monthlyGoal: Int
    let inviter: ClubPerson
    let membersCount: Int
    let monthWorkouts: Int
    let isMember: Bool

    private enum CodingKeys: String, CodingKey {
        case crewID = "crew_id", name, monthlyGoal = "monthly_goal", inviter, membersCount = "members_count",
             monthWorkouts = "month_workouts", isMember = "is_member"
    }
}

/// Invite links: the01://crew/<token>. People open them with 01 installed; the
/// token is checked by the server and lasts 7 days.
enum ClubCrewLink {
    static let pendingKey = "01.club.pendingCrewInvite"

    static func url(token: String) -> URL? {
        guard isToken(token) else { return nil }
        return URL(string: "the01://crew/" + token)
    }

    static func token(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "the01", url.host?.lowercased() == "crew",
              url.query == nil, url.fragment == nil else { return nil }
        let token = String(url.path.dropFirst())
        return isToken(token) ? token : nil
    }

    static func isToken(_ value: String) -> Bool {
        (22 ... 64).contains(value.count)
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && value.allSatisfy(\.isASCII)
    }
}
