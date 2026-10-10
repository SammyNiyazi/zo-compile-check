import Foundation

/// Why the Club refused, from the server's own message. Never shows raw server text.
enum ClubServiceError: Error, Equatable {
    case signedOut, closed, notJoined, suspended, handleTaken, ageRequired, invalid, notAllowed, unavailable
}

/// A JSON value a Club action may send. Nothing else can be put in a request.
enum ClubValue: Encodable, Equatable, Sendable {
    case string(String), bool(Bool), number(Double), strings([String]), sets([ZeroOneSocialSelectedSet])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .sets(let value): try container.encode(value)
        }
    }
}

/// The two database entry points: Codex's social_execute (follow, block, publish, delete) and club_execute.
enum ClubEndpoint: String, Sendable { case social = "social_execute", club = "club_execute" }

protocol ClubServicing: Sendable {
    func execute(_ endpoint: ClubEndpoint, _ action: String, payload: [String: ClubValue],
                 session: ZeroOneAccountSession) async throws -> Data
}

struct SupabaseClubService: ClubServicing {
    let configuration: ZeroOneAccountConfiguration
    var network: URLSession = .shared

    private struct Body: Encodable {
        let action: String
        let payload: [String: ClubValue]
    }

    func execute(_ endpoint: ClubEndpoint, _ action: String, payload: [String: ClubValue],
                 session: ZeroOneAccountSession) async throws -> Data {
        guard session.expiresAt > Date(), !session.accessToken.isEmpty else { throw ClubServiceError.signedOut }
        var request = URLRequest(url: configuration.url.appendingPathComponent("rest/v1/rpc/" + endpoint.rawValue))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(action: action, payload: payload))
        let data: Data, response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch { throw ClubServiceError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw ClubServiceError.unavailable }
        if (200..<300).contains(http.statusCode) { return data }
        throw Self.error(status: http.statusCode, body: data)
    }

    /// PostgREST returns the raised message; only the known ones are recognised.
    static func error(status: Int, body: Data) -> ClubServiceError {
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String ?? ""
        switch message {
        case "Club unavailable", "Social unavailable": return .closed
        case "Join the Club first": return .notJoined
        case "Account suspended": return .suspended
        case "Handle taken": return .handleTaken
        case "The Club is 16+": return .ageRequired
        case "Session unavailable", "Authentication required": return .signedOut
        default: break
        }
        switch status {
        case 401: return .signedOut
        case 403: return .notAllowed
        case 400, 409, 422: return .invalid
        default: return .unavailable
        }
    }
}
