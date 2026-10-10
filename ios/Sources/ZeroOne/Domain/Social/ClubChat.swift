import Foundation

/// Proof 25: decoded projections of supabase/migrations/202610100003_club_chat.sql.
struct ClubMessage: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case text, workout, together, answer, photo }

    struct Payload: Decodable, Equatable, Sendable {
        var sets: [ZeroOneSocialSelectedSet]?
        var title: String?
        var when: Date?
        var place: String?
        /// A photo message (202610100004_club_live_photos.sql): the stored key and its pixel size.
        var photo: ClubPhotoKey?
        var w: Double?
        var h: Double?
    }

    struct Answer: Decodable, Equatable, Sendable {
        let name: String
        let mine: Bool
        let answer: String
        var isIn: Bool { answer == "in" }
    }

    let id: UUID
    let author: ClubPerson
    let mine: Bool
    let kind: Kind
    let body: String
    let payload: Payload
    let createdAt: Date
    let answers: [Answer]

    private enum CodingKeys: String, CodingKey {
        case id, author, mine, kind, body, payload, createdAt = "created_at", answers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        author = try values.decode(ClubPerson.self, forKey: .author)
        mine = try values.decodeIfPresent(Bool.self, forKey: .mine) ?? false
        kind = (try? values.decode(Kind.self, forKey: .kind)) ?? .text
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        payload = (try? values.decode(Payload.self, forKey: .payload)) ?? Payload()
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        answers = (try? values.decodeIfPresent([Answer].self, forKey: .answers)) ?? []
    }

    /// One line for the Messages list.
    func preview(_ localization: AppLocalization) -> String {
        switch kind {
        case .text: body
        case .workout: localization.string("Shared a workout")
        case .together: localization.format("Train together · %1$@", .text(payload.title ?? ""))
        case .photo: localization.string("Photo")
        case .answer: ""
        }
    }
}

struct ClubConversation: Decodable, Identifiable, Equatable, Sendable {
    let crewID: UUID?
    let title: String?
    let person: ClubPerson?
    let last: ClubMessage?
    let unread: Int

    var id: String { crewID.map { "crew:" + $0.uuidString } ?? "dm:" + (person?.accountID.uuidString ?? "") }
    var name: String { title ?? person?.displayName ?? "" }

    private enum CodingKeys: String, CodingKey { case crewID = "crew", title, person, last, unread }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        crewID = try values.decodeIfPresent(UUID.self, forKey: .crewID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        person = try values.decodeIfPresent(ClubPerson.self, forKey: .person)
        last = try? values.decodeIfPresent(ClubMessage.self, forKey: .last)
        unread = try values.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }
}

struct ClubInbox: Decodable, Sendable { let conversations: [ClubConversation] }
struct ClubThread: Decodable, Sendable { let messages: [ClubMessage] }

struct ClubMessageReport: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let body: String
    let author: ClubPerson
    let reports: Int
    let category: String?
}
struct ClubMessageReports: Decodable, Sendable { let reports: [ClubMessageReport] }

/// Which conversation an action is about.
enum ClubChatTarget: Equatable, Hashable, Sendable {
    case crew(UUID), person(UUID)
}
