import Foundation
import Observation

/// The Club on this iPhone: one owner for every Club request and what the screens show.
/// Each request borrows a current session from the account store and never keeps it.
/// Everything is cleared when the signed-in account changes.
@Observable
@MainActor
final class ClubStore {
    enum Phase: Equatable {
        case notConfigured, signedOut, loading, closed, notJoined, member, suspended, unavailable
    }

    private(set) var phase: Phase = .loading
    private(set) var me: ClubSelf?
    private(set) var isAdmin = false
    private(set) var home: ClubHome?
    private(set) var isWorking = false
    /// One short line for the last failed action; never raw server text.
    var notice: String?

    @ObservationIgnored private let service: (any ClubServicing)?
    @ObservationIgnored private let sessions: @MainActor () async -> ZeroOneAccountSession?
    @ObservationIgnored private var accountID: UUID?
    @ObservationIgnored private var reportedTrained = Set<UUID>()

    init(service: (any ClubServicing)?, sessions: @escaping @MainActor () async -> ZeroOneAccountSession?) {
        self.service = service
        self.sessions = sessions
        if service == nil { phase = .notConfigured }
    }

    static func live(account: ZeroOneAccountStore) -> ClubStore {
        ClubStore(service: account.configuration.map { SupabaseClubService(configuration: $0) },
                  sessions: { [weak account] in await account?.sessionForRequest() })
    }

    /// Call when the signed-in identity changes: nothing from another account survives.
    func accountChanged(to id: UUID?) {
        guard id != accountID else { return }
        accountID = id
        me = nil; home = nil; isAdmin = false; notice = nil
        reportedTrained.removeAll()
        phase = service == nil ? .notConfigured : (id == nil ? .signedOut : .loading)
    }

    // MARK: Reading

    func refresh(history: [WorkoutHistoryEntry] = []) async {
        guard service != nil, accountID != nil else { return }
        do {
            let state: ClubMe = try await read(.club, "read_me")
            isAdmin = state.isAdmin
            me = state.member
            guard let member = state.member else { phase = .notJoined; home = nil; return }
            if member.suspended { phase = .suspended; home = nil; return }
            if member.showTrained { await reportTrained(history) }
            home = try await read(.club, "read_home")
            phase = .member
        } catch let error as ClubServiceError {
            apply(error)
        } catch {
            phase = .unavailable
        }
    }

    func member(_ id: UUID) async -> ClubMemberDetail? {
        try? await read(.club, "read_member", ["target": .string(id.uuidString)])
    }

    func people(_ kind: PeopleKind) async -> [ClubPerson]? {
        try? await read(.club, "read_people", ["kind": .string(kind.rawValue)])
    }

    func search(_ query: String) async -> [ClubPerson]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(trimmed.count) else { return [] }
        return try? await read(.club, "search", ["query": .string(trimmed)])
    }

    func activity() async -> ClubActivity? { try? await read(.club, "read_activity") }
    func blocked() async -> [ClubBlockedPerson]? { try? await read(.club, "read_blocked") }

    func reports(open: Bool) async -> [ClubReportItem]? {
        guard isAdmin else { return nil }
        return try? await read(.club, "admin_reports", ["status": .string(open ? "open" : "done")])
    }

    enum PeopleKind: String { case followers, following }

    // MARK: Acting

    /// Study 30: the Club is 16+, confirmed by the member at join.
    @discardableResult
    func join(handle: String, displayName: String, findable: Bool, showTrained: Bool, confirmedSixteen: Bool) async -> Bool {
        guard confirmedSixteen else { notice = "The Club is for people aged 16 and over."; return false }
        guard let handle = Self.validHandle(handle) else { notice = "Use 3 to 30 letters, numbers or underscores."; return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { notice = "Add the name people will see."; return false }
        return await act(.club, "join", ["handle": .string(handle), "display_name": .string(name),
            "discoverability": .string(findable ? "community" : "private"), "show_trained": .bool(showTrained),
            "age_confirmed": .bool(true)], refreshAfter: true)
    }

    @discardableResult
    func updateSettings(displayName: String? = nil, findable: Bool? = nil, showTrained: Bool? = nil) async -> Bool {
        var payload: [String: ClubValue] = [:]
        if let displayName { payload["display_name"] = .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let findable { payload["discoverability"] = .string(findable ? "community" : "private") }
        if let showTrained { payload["show_trained"] = .bool(showTrained) }
        return await act(.club, "settings", payload, refreshAfter: true)
    }

    /// Respect shows at once and is put back if the server refuses.
    func setRespect(_ post: ClubPost, on: Bool) async {
        updatePost(post.id) { $0.respected = on; $0.respectCount = max(0, $0.respectCount + (on ? 1 : -1)) }
        if !(await act(.club, on ? "respect" : "unrespect", ["id": .string(post.id.uuidString)])) {
            updatePost(post.id) { $0.respected = post.respected; $0.respectCount = post.respectCount }
        }
    }

    @discardableResult
    func report(_ post: ClubPost, category: ClubReportCategory, details: String) async -> Bool {
        let trimmed = String(details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        var payload: [String: ClubValue] = ["id": .string(post.id.uuidString), "category": .string(category.rawValue)]
        if !trimmed.isEmpty { payload["details"] = .string(trimmed) }
        return await act(.club, "report", payload)
    }

    @discardableResult
    func follow(_ id: UUID, _ on: Bool) async -> Bool {
        await act(.social, on ? "follow" : "unfollow", ["target": .string(id.uuidString)], refreshAfter: true)
    }

    /// Blocking also removes follows both ways (social_execute) and their posts from your feed.
    @discardableResult
    func block(_ id: UUID, _ on: Bool) async -> Bool {
        await act(.social, on ? "block" : "unblock", ["target": .string(id.uuidString)], refreshAfter: true)
    }

    @discardableResult
    func hidePosts(of id: UUID, _ on: Bool) async -> Bool {
        await act(.club, on ? "hide" : "unhide", ["target": .string(id.uuidString)], refreshAfter: true)
    }

    @discardableResult
    func deletePost(_ id: UUID) async -> Bool {
        let removed = await act(.social, "delete_post", ["id": .string(id.uuidString)])
        if removed { home?.feed.removeAll { $0.id == id } }
        return removed
    }

    /// Publishes exactly the selected sets and text to your followers. The ID is the one explicit
    /// Publish action, so a retry can never post twice.
    @discardableResult
    func publish(id: UUID, text: String, sets: [ZeroOneSocialSelectedSet]) async -> Bool {
        let selection = ZeroOneSocialPostSelection(id: id, text: text, sets: sets, audience: .followers,
                                                   recipients: [], publishConfirmed: true)
        do { try selection.validate() } catch { notice = "Pick at least one set or write something."; return false }
        return await act(.social, "publish", ["id": .string(id.uuidString), "text": .string(text), "sets": .sets(sets),
            "audience": .string("followers"), "recipients": .strings([]), "confirmed": .bool(true)], refreshAfter: true)
    }

    @discardableResult
    func resolve(_ item: ClubReportItem, _ decision: ClubModerationDecision) async -> Bool {
        guard isAdmin else { return false }
        return await act(.club, "admin_resolve", ["id": .string(item.postID.uuidString), "decision": .string(decision.rawValue)])
    }

    /// Removes your Club profile, follows and post content. Your training on this iPhone is untouched.
    @discardableResult
    func leaveClub() async -> Bool {
        await act(.social, "delete_social", ["confirmed": .bool(true)], refreshAfter: true)
    }

    // MARK: Internals

    static func validHandle(_ text: String) -> String? {
        let handle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...30).contains(handle.count),
              handle.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
        else { return nil }
        return handle
    }

    /// Tells the Club that recent saved workouts happened: only an ID and a time, within the
    /// server's two-day window. The workout itself stays on this iPhone.
    private func reportTrained(_ history: [WorkoutHistoryEntry]) async {
        let recent = history.filter { $0.completedAt > Date().addingTimeInterval(-2 * 86_400) && $0.completedAt <= Date()
            && !reportedTrained.contains($0.id) }
        for entry in recent.prefix(10) {
            if (try? await send(.club, "trained", ["id": .string(entry.id.uuidString),
                "trained_at": .string(ISO8601DateFormatter().string(from: entry.completedAt))])) != nil {
                reportedTrained.insert(entry.id)
            }
        }
    }

    private func updatePost(_ id: UUID, _ change: (inout ClubPost) -> Void) {
        guard let index = home?.feed.firstIndex(where: { $0.id == id }) else { return }
        change(&home!.feed[index])
    }

    private func apply(_ error: ClubServiceError) {
        switch error {
        case .signedOut: phase = .signedOut
        case .closed: phase = .closed
        case .notJoined: phase = .notJoined
        case .suspended: phase = .suspended
        default: phase = .unavailable
        }
    }

    private func read<Value: Decodable>(_ endpoint: ClubEndpoint, _ action: String,
                                        _ payload: [String: ClubValue] = [:]) async throws -> Value {
        try ClubDate.decoder().decode(Value.self, from: try await send(endpoint, action, payload))
    }

    @discardableResult
    private func act(_ endpoint: ClubEndpoint, _ action: String, _ payload: [String: ClubValue],
                     refreshAfter: Bool = false) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        notice = nil
        do {
            _ = try await send(endpoint, action, payload)
            if refreshAfter { await refresh() }
            return true
        } catch let error as ClubServiceError {
            notice = Self.message(error)
            if [.signedOut, .closed, .suspended].contains(error) { apply(error) }
            return false
        } catch {
            notice = Self.message(.unavailable)
            return false
        }
    }

    private func send(_ endpoint: ClubEndpoint, _ action: String, _ payload: [String: ClubValue]) async throws -> Data {
        guard let service else { throw ClubServiceError.unavailable }
        let owner = accountID
        // Another account operation may hold the session briefly; wait a moment rather than race it.
        var session = await sessions()
        for _ in 0..<3 where session == nil {
            try? await Task.sleep(for: .milliseconds(400))
            session = await sessions()
        }
        guard let session else { throw ClubServiceError.signedOut }
        let data = try await service.execute(endpoint, action, payload: payload, session: session)
        // A reply for an account that is no longer signed in is dropped.
        guard owner == accountID else { throw ClubServiceError.signedOut }
        return data
    }

    static func message(_ error: ClubServiceError) -> String {
        switch error {
        case .signedOut: "Sign in again to use the Club."
        case .closed: "The Club isn't open yet."
        case .notJoined: "Join the Club first."
        case .suspended: "Your Club account is paused. Write to Sammy if you think this is wrong."
        case .handleTaken: "That handle is taken. Try another."
        case .ageRequired: "The Club is for people aged 16 and over."
        case .invalid: "That didn't work. Check it and try again."
        case .notAllowed: "That isn't available."
        case .unavailable: "The Club can't be reached right now. Try again."
        }
    }
}
