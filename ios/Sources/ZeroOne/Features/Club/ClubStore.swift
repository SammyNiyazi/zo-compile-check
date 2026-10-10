import Foundation
import Observation
import UIKit

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
    /// Proof 12 and 48: the crews this member is in.
    private(set) var crews: [ClubCrew] = []
    /// Proof 25: crew chats and friends, newest first.
    private(set) var inbox: [ClubConversation] = []
    var unreadMessages: Int { inbox.reduce(0) { $0 + $1.unread } }
    private(set) var isWorking = false
    /// One short line for the last failed action; never raw server text.
    var notice: String?

    /// Chat doorbell (202610100004): bumps when a conversation changed; `lastRang` says which one,
    /// lowercased "crew:<id>" or "dm:<other account id>". Views reload when it changes.
    private(set) var doorbell = 0
    private(set) var lastRang: String?
    /// True while the doorbell channel is joined; chats then refresh slowly as a safety net only.
    private(set) var isLive = false
    /// A photo is being shrunk and uploaded.
    private(set) var isUploadingPhoto = false

    @ObservationIgnored private let service: (any ClubServicing)?
    @ObservationIgnored private let sessions: @MainActor () async -> ZeroOneAccountSession?
    @ObservationIgnored private let photoStorage: ClubPhotoStorage?
    @ObservationIgnored private let liveConfiguration: ZeroOneAccountConfiguration?
    @ObservationIgnored private var accountID: UUID?
    @ObservationIgnored private var reportedTrained = Set<UUID>()
    @ObservationIgnored private var liveUsers = 0
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    init(service: (any ClubServicing)?, sessions: @escaping @MainActor () async -> ZeroOneAccountSession?,
         photoStorage: ClubPhotoStorage? = nil, liveConfiguration: ZeroOneAccountConfiguration? = nil) {
        self.service = service
        self.sessions = sessions
        self.photoStorage = photoStorage
        self.liveConfiguration = liveConfiguration
        if service == nil { phase = .notConfigured }
    }

    static func live(account: ZeroOneAccountStore) -> ClubStore {
        ClubStore(service: account.configuration.map { SupabaseClubService(configuration: $0) },
                  sessions: { [weak account] in await account?.sessionForRequest() },
                  photoStorage: account.configuration.map { ClubPhotoStorage(configuration: $0) },
                  liveConfiguration: account.configuration)
    }

    /// Call when the signed-in identity changes: nothing from another account survives.
    func accountChanged(to id: UUID?) {
        guard id != accountID else { return }
        accountID = id
        me = nil; home = nil; isAdmin = false; notice = nil; crews = []; inbox = []
        lastRang = nil; isLive = false
        // The next loop turn reconnects with the new account's session.
        if liveTask != nil { liveTask?.cancel(); liveTask = nil; if liveUsers > 0 { startLiveLoop() } }
        WidgetMemberCard.save(nil)
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
            WidgetMemberCard.save(state.member)
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
    /// Photos (already uploaded with `uploadPhoto`) are attached right after, once.
    @discardableResult
    func publish(id: UUID, text: String, sets: [ZeroOneSocialSelectedSet], photos: [ClubPhotoKey] = []) async -> Bool {
        let selection = ZeroOneSocialPostSelection(id: id, text: text, sets: sets, audience: .followers,
                                                   recipients: [], publishConfirmed: true)
        do { try selection.validate() } catch { notice = "Pick at least one set or write something."; return false }
        guard await act(.social, "publish", ["id": .string(id.uuidString), "text": .string(text), "sets": .sets(sets),
            "audience": .string("followers"), "recipients": .strings([]), "confirmed": .bool(true)],
            refreshAfter: photos.isEmpty) else { return false }
        guard !photos.isEmpty else { return true }
        let attached = await act(.photo, "attach", ["id": .string(id.uuidString),
                                                    "photos": .strings(photos.prefix(4).map(\.value))], refreshAfter: true)
        if !attached { notice = "Your post is up, but its photos didn't attach. Try posting again." }
        return attached
    }

    // MARK: Photos (202610100004)

    /// Shrinks one photo on this iPhone and uploads it with its thumbnail. Returns its key and pixel size.
    func uploadPhoto(_ data: Data) async -> (key: ClubPhotoKey, width: Int, height: Int)? {
        guard let photoStorage, phase == .member else { notice = Self.message(.unavailable); return nil }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        notice = nil
        let prepared = await Task.detached(priority: .userInitiated) { ClubPhotoEncoder.prepare(data) }.value
        guard let prepared else { notice = "This photo couldn't be prepared. Try another one."; return nil }
        guard let session = await currentSession(),
              let user = ClubLiveProtocol.authUserID(fromToken: session.accessToken),
              let key = ClubPhotoKey(user + "/" + prepared.hash) else { notice = Self.message(.signedOut); return nil }
        do {
            try await photoStorage.upload(prepared.full, name: key.objectName(thumbnail: false), session: session)
            try await photoStorage.upload(prepared.thumbnail, name: key.objectName(thumbnail: true), session: session)
        } catch let error as ClubServiceError {
            notice = Self.message(error); return nil
        } catch {
            notice = Self.message(.unavailable); return nil
        }
        // The sender never downloads their own photo.
        ClubPhotoCache.shared.store(prepared.full, name: key.objectName(thumbnail: false))
        ClubPhotoCache.shared.store(prepared.thumbnail, name: key.objectName(thumbnail: true))
        return (key, prepared.width, prepared.height)
    }

    /// A Club photo from the cache, downloading it once if this iPhone hasn't seen it.
    func photo(_ key: ClubPhotoKey, thumbnail: Bool, maxSide: CGFloat) async -> UIImage? {
        let name = key.objectName(thumbnail: thumbnail)
        let storage = photoStorage
        return await ClubPhotoCache.shared.image(name, maxSide: maxSide) { [weak self] in
            guard let storage, let session = await self?.currentSession() else { return nil }
            return try? await storage.download(name: name, session: session)
        }
    }

    @discardableResult
    func sendPhoto(_ target: ClubChatTarget, data: Data) async -> Bool {
        guard let photo = await uploadPhoto(data) else { return false }
        return await send(target, id: UUID(), kind: .photo, payload: [
            "photo": .string(photo.key.value), "w": .number(Double(photo.width)), "h": .number(Double(photo.height))])
    }

    // MARK: Live chat doorbell (202610100004)

    /// Keeps the doorbell connected while a Club chat screen is open. Call from `.task`; returns when cancelled.
    func stayLive() async {
        liveUsers += 1
        if liveTask == nil { startLiveLoop() }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) } catch { break }
        }
        liveUsers -= 1
        if liveUsers == 0 { liveTask?.cancel(); liveTask = nil; isLive = false }
    }

    private func startLiveLoop() {
        guard let liveConfiguration else { return }
        liveTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let store = self else { return }
                guard store.phase == .member, let session = await store.currentSession() else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                let owner = store.accountID
                let joined = await ClubLiveConnection(configuration: liveConfiguration).run(
                    token: session.accessToken,
                    onJoined: { [weak store] in store?.isLive = true },
                    onDoorbell: { [weak store] conversation in
                        guard let store, store.accountID == owner else { return }
                        store.lastRang = conversation
                        store.doorbell &+= 1
                        Task { await store.loadInbox() }
                    })
                store.isLive = false
                // Back off when the channel is refused (e.g. before the migration): 10 s up to about 5 minutes.
                failures = joined ? 0 : min(failures + 1, 5)
                try? await Task.sleep(for: .seconds(joined ? 2 : 5 * (1 << failures)))
            }
        }
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

    // MARK: Crews (proof 12, 48)

    func loadCrews() async {
        guard phase == .member else { crews = []; return }
        if let list: ClubCrewList = try? await read(.crew, "read_crews") { crews = list.crews }
    }

    @discardableResult
    func createCrew(name: String, anyoneWithLink: Bool, monthlyGoal: Int) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 40).contains(trimmed.count) else { notice = "Give the crew a name."; return false }
        guard ClubWordFilter.isClean(trimmed) else { notice = "That name breaks the Club rules. Pick another."; return false }
        guard (1 ... 1000).contains(monthlyGoal) else { notice = "Pick a goal between 1 and 1,000."; return false }
        guard await act(.crew, "create", ["name": .string(trimmed), "join_policy": .string(anyoneWithLink ? "link" : "invite"),
                                           "monthly_goal": .number(Double(monthlyGoal))]) else { return false }
        await loadCrews()
        return true
    }

    /// A fresh 7-day link; the previous one stops working.
    func inviteLink(for crew: ClubCrew) async -> URL? {
        do {
            let invite: ClubCrewInviteToken = try await read(.crew, "invite", ["crew": .string(crew.id.uuidString)])
            await loadCrews()
            return ClubCrewLink.url(token: invite.token)
        } catch {
            notice = Self.message((error as? ClubServiceError) ?? .unavailable)
            return nil
        }
    }

    @discardableResult
    func turnOffInvite(for crew: ClubCrew) async -> Bool {
        guard await act(.crew, "revoke_invite", ["crew": .string(crew.id.uuidString)]) else { return false }
        await loadCrews()
        return true
    }

    @discardableResult
    func setGoal(_ goal: Int, for crew: ClubCrew) async -> Bool {
        guard (1 ... 1000).contains(goal),
              await act(.crew, "set_goal", ["crew": .string(crew.id.uuidString), "monthly_goal": .number(Double(goal))]) else { return false }
        await loadCrews()
        return true
    }

    @discardableResult
    func leave(_ crew: ClubCrew) async -> Bool {
        guard await act(.crew, "leave", ["crew": .string(crew.id.uuidString)]) else { return false }
        await loadCrews()
        return true
    }

    // MARK: Chat (proof 25, 50)

    private func chatPayload(_ target: ClubChatTarget) -> [String: ClubValue] {
        switch target {
        case let .crew(id): ["crew": .string(id.uuidString)]
        case let .person(id): ["person": .string(id.uuidString)]
        }
    }

    func loadInbox() async {
        guard phase == .member else { inbox = []; return }
        if let value: ClubInbox = try? await read(.chat, "read_inbox") { inbox = value.conversations }
    }

    /// Reading a thread also marks it read on the server.
    func messages(_ target: ClubChatTarget) async -> [ClubMessage]? {
        (try? await read(.chat, "read_thread", chatPayload(target)) as ClubThread)?.messages
    }

    /// A text line passes the word filter first (proof 50); a held line is never sent.
    @discardableResult
    func send(_ target: ClubChatTarget, id: UUID, kind: ClubMessage.Kind, body: String = "",
              payload: [String: ClubValue] = [:]) async -> Bool {
        let line = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClubWordFilter.isClean(line) else { notice = "This looks like it breaks the Club rules. Edit it, then send."; return false }
        var request = chatPayload(target)
        request["id"] = .string(id.uuidString)
        request["kind"] = .string(kind.rawValue)
        request["body"] = .string(line)
        if !payload.isEmpty { request["payload"] = .object(payload) }
        return await act(.chat, "send", request)
    }

    @discardableResult
    func deleteMessage(_ message: ClubMessage) async -> Bool {
        await act(.chat, "delete", ["id": .string(message.id.uuidString)])
    }

    @discardableResult
    func reportMessage(_ message: ClubMessage, category: String, details: String) async -> Bool {
        var payload: [String: ClubValue] = ["id": .string(message.id.uuidString), "category": .string(category)]
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { payload["details"] = .string(String(trimmed.prefix(1000))) }
        return await act(.chat, "report", payload)
    }

    func messageReports() async -> [ClubMessageReport] {
        guard isAdmin else { return [] }
        return (try? await read(.chat, "admin_reports") as ClubMessageReports)?.reports ?? []
    }

    @discardableResult
    func resolveMessageReport(_ id: UUID, remove: Bool) async -> Bool {
        await act(.chat, "admin_resolve", ["id": .string(id.uuidString), "decision": .string(remove ? "removed" : "dismissed")])
    }

    /// Proof 33: the member behind a scanned week code.
    func member(number: Int) async -> ClubPerson? {
        guard (1 ... 0xFF_FFFF).contains(number) else { return nil }
        return try? await read(.crew, "member_by_number", ["number": .number(Double(number))])
    }

    func crewInvite(token: String) async -> ClubCrewInvitePreview? {
        guard ClubCrewLink.isToken(token) else { return nil }
        return try? await read(.crew, "read_invite", ["token": .string(token)])
    }

    @discardableResult
    func joinCrew(token: String) async -> Bool {
        guard ClubCrewLink.isToken(token), await act(.crew, "join", ["token": .string(token)]) else { return false }
        await loadCrews()
        return true
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
        guard let session = await currentSession() else { throw ClubServiceError.signedOut }
        let data = try await service.execute(endpoint, action, payload: payload, session: session)
        // A reply for an account that is no longer signed in is dropped.
        guard owner == accountID else { throw ClubServiceError.signedOut }
        return data
    }

    /// Another account operation may hold the session briefly; wait a moment rather than race it.
    private func currentSession() async -> ZeroOneAccountSession? {
        var session = await sessions()
        for _ in 0..<3 where session == nil {
            try? await Task.sleep(for: .milliseconds(400))
            session = await sessions()
        }
        return session
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
