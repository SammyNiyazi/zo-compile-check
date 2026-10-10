import Foundation

/// The chat "doorbell" from supabase/migrations/202610100004_club_live_photos.sql: a private Supabase Realtime
/// channel (topic inbox:<auth user id>) that only says which conversation changed. It never carries message
/// text; the app then reads through chat_execute as before. One WebSocket while Club screens are open.
enum ClubLiveProtocol {
    /// wss://<project>.supabase.co/realtime/v1/websocket?apikey=…&vsn=1.0.0
    static func socketURL(_ configuration: ZeroOneAccountConfiguration) -> URL? {
        guard var components = URLComponents(url: configuration.url.appendingPathComponent("realtime/v1/websocket"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "apikey", value: configuration.publishableKey),
                                 URLQueryItem(name: "vsn", value: "1.0.0")]
        return components.url
    }

    /// The signed-in person's auth user ID (the token's "sub"), lowercased as Postgres prints it.
    static func authUserID(fromToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String, let id = UUID(uuidString: sub) else { return nil }
        return id.uuidString.lowercased()
    }

    static func topic(authUserID: String) -> String { "realtime:inbox:" + authUserID }

    static func join(topic: String, token: String, ref: String) -> Data? {
        message(topic: topic, event: "phx_join", ref: ref, joinRef: ref, payload: [
            "config": ["broadcast": ["ack": false, "self": false], "presence": ["key": ""],
                       "postgres_changes": [Any](), "private": true],
            "access_token": token,
        ])
    }

    static func heartbeat(ref: String) -> Data? {
        message(topic: "phoenix", event: "heartbeat", ref: ref, joinRef: nil, payload: [:])
    }

    private static func message(topic: String, event: String, ref: String, joinRef: String?,
                                payload: [String: Any]) -> Data? {
        var object: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": ref]
        if let joinRef { object["join_ref"] = joinRef }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    enum Incoming: Equatable {
        /// A conversation changed: "crew:<id>" or "dm:<other account id>", lowercased.
        case doorbell(String)
        case joined, refused, closed, other
    }

    static func parse(_ data: Data, topic: String) -> Incoming {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return .other }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch event {
        case "broadcast":
            guard object["topic"] as? String == topic else { return .other }
            // Database broadcasts arrive as {event, payload: {conversation}, type}; accept either nesting.
            let inner = payload["payload"] as? [String: Any] ?? payload
            guard let conversation = inner["conversation"] as? String,
                  conversation.hasPrefix("crew:") || conversation.hasPrefix("dm:") else { return .other }
            return .doorbell(conversation.lowercased())
        case "phx_reply":
            guard object["topic"] as? String == topic else { return .other }
            return payload["status"] as? String == "ok" ? .joined : .refused
        case "phx_error", "phx_close":
            return object["topic"] as? String == topic ? .closed : .other
        default:
            return .other
        }
    }
}

/// One connection at a time. `run` returns when the task is cancelled or the socket ends; the caller
/// reconnects with a fresh session. A ring only nudges a refresh, so a missed one costs nothing but time.
@MainActor
final class ClubLiveConnection {
    private let configuration: ZeroOneAccountConfiguration
    private let session: URLSession

    init(configuration: ZeroOneAccountConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Returns true when the channel was joined before the connection ended.
    func run(token: String, onJoined: @escaping @MainActor () -> Void,
             onDoorbell: @escaping @MainActor (String) -> Void) async -> Bool {
        guard let url = ClubLiveProtocol.socketURL(configuration),
              let userID = ClubLiveProtocol.authUserID(fromToken: token) else { return false }
        let topic = ClubLiveProtocol.topic(authUserID: userID)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        guard let join = ClubLiveProtocol.join(topic: topic, token: token, ref: "1") else { return false }
        do { try await socket.send(.data(join)) } catch { return false }

        // Phoenix closes a socket that stays quiet for about a minute.
        let heartbeat = Task { [socket] in
            var ref = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let beat = ClubLiveProtocol.heartbeat(ref: String(ref)) else { break }
                ref += 1
                try? await socket.send(.data(beat))
            }
        }
        defer { heartbeat.cancel() }

        // A pending receive() ignores task cancellation; closing the socket ends it at once.
        return await withTaskCancellationHandler {
            var joined = false
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { break }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                switch ClubLiveProtocol.parse(data, topic: topic) {
                case .joined:
                    if !joined { joined = true; await onJoined() }
                case .doorbell(let conversation):
                    await onDoorbell(conversation)
                case .refused, .closed:
                    return joined
                case .other:
                    continue
                }
            }
            return joined
        } onCancel: { [socket] in
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}
