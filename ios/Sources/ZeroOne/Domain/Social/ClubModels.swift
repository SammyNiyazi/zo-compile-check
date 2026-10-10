import Foundation

/// Club core v1 (Sammy, 10 Oct 2026): decoded projections of supabase/migrations/202610100001_club_core.sql.
/// A member as other members see them: never health, body, food or photos.
struct ClubPerson: Decodable, Equatable, Identifiable, Sendable {
    let accountID: UUID
    let handle: String
    let displayName: String
    let memberNo: Int?
    let joinedAt: Date?
    let trainedThisWeek: Bool
    let iFollow: Bool
    let followsMe: Bool

    var id: UUID { accountID }

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id", handle, displayName = "display_name", memberNo = "member_no",
             joinedAt = "joined_at", trainedThisWeek = "trained_this_week", iFollow = "i_follow", followsMe = "follows_me"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(UUID.self, forKey: .accountID)
        handle = try values.decode(String.self, forKey: .handle)
        displayName = try values.decode(String.self, forKey: .displayName)
        memberNo = try values.decodeIfPresent(Int.self, forKey: .memberNo)
        joinedAt = try values.decodeIfPresent(Date.self, forKey: .joinedAt)
        trainedThisWeek = try values.decodeIfPresent(Bool.self, forKey: .trainedThisWeek) ?? false
        iFollow = try values.decodeIfPresent(Bool.self, forKey: .iFollow) ?? false
        followsMe = try values.decodeIfPresent(Bool.self, forKey: .followsMe) ?? false
    }

    init(accountID: UUID, handle: String, displayName: String, memberNo: Int?, joinedAt: Date? = nil,
         trainedThisWeek: Bool = false, iFollow: Bool = false, followsMe: Bool = false) {
        self.accountID = accountID; self.handle = handle; self.displayName = displayName; self.memberNo = memberNo
        self.joinedAt = joinedAt; self.trainedThisWeek = trainedThisWeek; self.iFollow = iFollow; self.followsMe = followsMe
    }

    /// Study 30 card: "No. 0042". Numbers past 9999 keep every digit.
    static func memberNumber(_ number: Int) -> String { String(format: "%04d", number) }
}

/// Your own membership, with the private settings only you see.
struct ClubSelf: Decodable, Equatable, Sendable {
    let person: ClubPerson
    let findable: Bool
    let showTrained: Bool
    let workoutsCount: Int
    let suspended: Bool
    let followers: Int
    let following: Int

    private enum CodingKeys: String, CodingKey {
        case discoverability, showTrained = "show_trained", workoutsCount = "workouts_count", suspended, followers, following
    }

    init(from decoder: Decoder) throws {
        person = try ClubPerson(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        findable = try values.decode(String.self, forKey: .discoverability) == "community"
        showTrained = try values.decode(Bool.self, forKey: .showTrained)
        workoutsCount = try values.decode(Int.self, forKey: .workoutsCount)
        suspended = try values.decode(Bool.self, forKey: .suspended)
        followers = try values.decode(Int.self, forKey: .followers)
        following = try values.decode(Int.self, forKey: .following)
    }
}

struct ClubMe: Decodable, Equatable, Sendable {
    let member: ClubSelf?
    let isAdmin: Bool
    private enum CodingKeys: String, CodingKey { case member, isAdmin = "is_admin" }
}

struct ClubPost: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// Nil when the author left the Club; the post is then shown without a name.
    let author: ClubPerson?
    let text: String
    let sets: [ZeroOneSocialSelectedSet]
    let createdAt: Date
    var respectCount: Int
    var respected: Bool

    private enum CodingKeys: String, CodingKey {
        case id, author, text, sets, createdAt = "created_at", respectCount = "respect_count", respected
    }
}

struct ClubHome: Decodable, Equatable, Sendable {
    var feed: [ClubPost]
    let trained: [ClubPerson]
}

struct ClubMemberDetail: Decodable, Equatable, Sendable {
    let person: ClubPerson
    let workoutsCount: Int
    let followers: Int
    let following: Int
    let hidden: Bool
    var posts: [ClubPost]

    private enum CodingKeys: String, CodingKey {
        case workoutsCount = "workouts_count", followers, following, hidden, posts
    }

    init(from decoder: Decoder) throws {
        person = try ClubPerson(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workoutsCount = try values.decode(Int.self, forKey: .workoutsCount)
        followers = try values.decode(Int.self, forKey: .followers)
        following = try values.decode(Int.self, forKey: .following)
        hidden = try values.decode(Bool.self, forKey: .hidden)
        posts = try values.decode([ClubPost].self, forKey: .posts)
    }
}

struct ClubActivity: Decodable, Equatable, Sendable {
    struct Respects: Decodable, Equatable, Identifiable, Sendable {
        let postID: UUID
        let postText: String
        let count: Int
        let latest: Date
        let givers: [ClubPerson]
        var id: UUID { postID }
        private enum CodingKeys: String, CodingKey {
            case postID = "post_id", postText = "post_text", count, latest, givers
        }
    }
    let respects: [Respects]
    let followers: [ClubPerson]
}

struct ClubBlockedPerson: Decodable, Equatable, Identifiable, Sendable {
    let accountID: UUID
    let handle: String
    let displayName: String
    var id: UUID { accountID }
    private enum CodingKeys: String, CodingKey { case accountID = "account_id", handle, displayName = "display_name" }
}

/// Study 30 screen 50: what's wrong with this post.
enum ClubReportCategory: String, CaseIterable, Identifiable, Sendable {
    case harassment, sexual, spam, dangerous, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: "Harassment or hate"
        case .sexual: "Sexual content"
        case .spam: "Spam or a scam"
        case .dangerous: "Dangerous advice"
        case .other: "Something else"
        }
    }
    var detail: String? { self == .dangerous ? "Like pushing someone through pain" : nil }
}

/// One reported post in Sammy's queue. Reporters stay anonymous: only a count.
struct ClubReportItem: Decodable, Equatable, Identifiable, Sendable {
    struct Author: Decodable, Equatable, Sendable {
        let accountID: UUID
        let handle: String
        let displayName: String
        let memberNo: Int?
        let suspended: Bool
        private enum CodingKeys: String, CodingKey {
            case accountID = "account_id", handle, displayName = "display_name", memberNo = "member_no", suspended
        }
    }
    let postID: UUID
    let text: String
    let sets: [ZeroOneSocialSelectedSet]
    let postedAt: Date
    let author: Author
    let reports: Int
    let categories: [String?]
    let details: [String]?
    let latest: Date
    let status: String
    var id: UUID { postID }

    private enum CodingKeys: String, CodingKey {
        case postID = "post_id", text, sets, postedAt = "posted_at", author, reports, categories, details, latest, status
    }
}

enum ClubModerationDecision: String, Sendable { case remove, block, dismiss }

/// Postgres timestamptz in JSON carries up to six fractional digits and a +00:00 offset.
enum ClubDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
        // Trim the fraction to milliseconds, which ISO8601DateFormatter always reads.
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let digits = text[text.index(after: dot)..<zone].prefix(3)
        return fractional.date(from: String(text[..<dot]) + "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0)
            + String(text[zone...]))
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date"))
            }
            return date
        }
        return decoder
    }
}
