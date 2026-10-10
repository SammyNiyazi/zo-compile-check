import Foundation

/// Integrator supplies the CURRENT verified session for each action. Never persist a second session.
/// Responses are explicitly selected JSON projections; caller must discard them on account changes.
protocol ZeroOneSocialServicing: Sendable {
    func read(_ query: ZeroOneSocialQuery, session: ZeroOneAccountSession) async throws -> Data
    func saveProfile(handle: String, displayName: String, discoverability: ZeroOneSocialDiscoverability,
                     session: ZeroOneAccountSession) async throws
    func connect(_ action: ZeroOneSocialConnectionAction, to accountID: UUID,
                 session: ZeroOneAccountSession) async throws
    func publish(_ selection: ZeroOneSocialPostSelection, session: ZeroOneAccountSession) async throws
    func deletePost(_ id: UUID, session: ZeroOneAccountSession) async throws
    func reportPost(_ id: UUID, reason: String, session: ZeroOneAccountSession) async throws
    func startNearby(_ selection: ZeroOneNearbySelection, session: ZeroOneAccountSession) async throws
    func updateNearby(_ id: UUID, fix: ZeroOneNearbyFix, session: ZeroOneAccountSession) async throws
    func stopNearby(_ id: UUID?, session: ZeroOneAccountSession) async throws
    func deleteSocialData(confirmed: Bool, session: ZeroOneAccountSession) async throws
}

enum ZeroOneSocialQuery: String, Sendable { case profile, connections, feed, nearby }

/// No operational values are assumed: approved short lifetime/fix freshness are required inputs.
struct ZeroOneNearbyLimits: Sendable {
    let maximumSharingDuration: TimeInterval
    let maximumFixAge: TimeInterval
}

struct SupabaseZeroOneSocialService: ZeroOneSocialServicing {
    let configuration: ZeroOneAccountConfiguration
    let readiness: ZeroOneSocialReadiness
    let nearbyLimits: ZeroOneNearbyLimits?
    var network: URLSession = .shared

    func read(_ query: ZeroOneSocialQuery, session: ZeroOneAccountSession) async throws -> Data {
        try requireEnabled(nearby: query == .nearby)
        return try await call("read_" + query.rawValue, session: session)
    }

    func saveProfile(handle: String, displayName: String, discoverability: ZeroOneSocialDiscoverability,
                     session: ZeroOneAccountSession) async throws {
        try requireEnabled()
        _ = try await call("profile", payload: ["handle": handle, "display_name": displayName,
            "discoverability": discoverability.rawValue], session: session)
    }

    func connect(_ action: ZeroOneSocialConnectionAction, to accountID: UUID,
                 session: ZeroOneAccountSession) async throws {
        // Removal/blocking remain available during service suspension.
        if ![.remove, .unfollow, .block].contains(action) { try requireEnabled() }
        _ = try await call(action.rawValue, payload: ["target": accountID.uuidString], session: session)
    }

    func publish(_ selection: ZeroOneSocialPostSelection, session: ZeroOneAccountSession) async throws {
        try requireEnabled()
        try selection.validate()
        let selectedSets = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection.sets))
        _ = try await call("publish", payload: ["id": selection.id.uuidString,
            "text": selection.text, "sets": selectedSets, "audience": selection.audience.rawValue,
            "recipients": selection.recipients.map(\.uuidString).sorted(), "confirmed": true], session: session)
    }

    func deletePost(_ id: UUID, session: ZeroOneAccountSession) async throws {
        _ = try await call("delete_post", payload: ["id": id.uuidString], session: session)
    }

    func reportPost(_ id: UUID, reason: String, session: ZeroOneAccountSession) async throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 1000
        else { throw ZeroOneSocialError.invalidSelection }
        _ = try await call("report", payload: ["id": id.uuidString, "reason": reason], session: session)
    }

    func startNearby(_ selection: ZeroOneNearbySelection, session: ZeroOneAccountSession) async throws {
        try requireEnabled(nearby: true)
        guard let nearbyLimits else { throw ZeroOneSocialError.unavailable }
        try selection.validate(now: Date(), maximumDuration: nearbyLimits.maximumSharingDuration)
        _ = try await call("start_nearby", payload: ["id": selection.id.uuidString,
            "target": selection.recipientID.uuidString,
            "expires_at": Self.timestamp(selection.expiresAt), "confirmed": true], session: session)
    }

    func updateNearby(_ id: UUID, fix: ZeroOneNearbyFix, session: ZeroOneAccountSession) async throws {
        try requireEnabled(nearby: true)
        guard let nearbyLimits else { throw ZeroOneSocialError.unavailable }
        try fix.validate(now: Date(), maximumAge: nearbyLimits.maximumFixAge)
        _ = try await call("update_nearby", payload: ["id": id.uuidString, "latitude": fix.latitude,
            "longitude": fix.longitude, "accuracy_metres": fix.accuracyMetres,
            "captured_at": Self.timestamp(fix.capturedAt)], session: session)
    }

    func stopNearby(_ id: UUID?, session: ZeroOneAccountSession) async throws {
        _ = try await call("stop_nearby", payload: id.map { ["id": $0.uuidString] } ?? [:], session: session)
    }

    func deleteSocialData(confirmed: Bool, session: ZeroOneAccountSession) async throws {
        guard confirmed else { throw ZeroOneSocialError.consentRequired }
        _ = try await call("delete_social", payload: ["confirmed": true], session: session)
    }

    private func requireEnabled(nearby: Bool = false) throws {
        guard nearby ? readiness.nearbyEnabled : readiness.socialEnabled
        else { throw ZeroOneSocialError.unavailable }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func call(_ action: String, payload: [String: Any] = [:],
                      session: ZeroOneAccountSession) async throws -> Data {
        guard session.expiresAt > Date(), !session.accessToken.isEmpty
        else { throw ZeroOneSocialError.authenticationRequired }
        var request = URLRequest(url: configuration.url.appendingPathComponent("rest/v1/rpc/social_execute"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "payload": payload])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch { throw ZeroOneSocialError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw ZeroOneSocialError.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ZeroOneSocialError.staleSession
        case 403: throw ZeroOneSocialError.forbidden
        case 400, 409, 422: throw ZeroOneSocialError.invalidSelection
        default: throw ZeroOneSocialError.unavailable
        }
    }
}
