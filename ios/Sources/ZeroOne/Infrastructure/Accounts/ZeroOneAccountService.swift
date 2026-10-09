import Foundation
import CryptoKit
import Security

/// Provider-neutral account identity. No workout/Health repositories participate in authentication.
struct ZeroOneAccountIdentity: Codable, Equatable, Sendable {
    let id: UUID
    let authenticationID: UUID
    let email: String?
}

struct ZeroOneAccountSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let identity: ZeroOneAccountIdentity
}

enum ZeroOneAccountError: Error, LocalizedError {
    case notConfigured, invalidInput, expiredCode, rateLimited, unavailable, invalidResponse, secureStorage
    case sessionExpired, cancelled, providerNotReady, appleReauthenticationRequired
    case googleReturnInvalid, googleProviderFailed, googleAccessDenied

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Accounts are being connected. Training is available without an account."
        case .invalidInput: "Check your email address and verification code."
        case .expiredCode: "That code is invalid or has expired. Request a new one."
        case .rateLimited: "Too many attempts. Wait a moment before trying again."
        case .unavailable: "Couldn't connect. Check your internet connection and try again."
        case .invalidResponse: "Couldn't verify your account. Please try again."
        case .secureStorage: "Couldn't securely save your sign-in on this iPhone. Please try again."
        case .sessionExpired: "Please sign in again. Your training is still on this iPhone."
        case .cancelled: "Sign-in cancelled."
        case .providerNotReady: "This sign-in method is still being configured."
        case .appleReauthenticationRequired: "Confirm with Apple to delete your account."
        case .googleReturnInvalid: "Google couldn't return to 01. Please try again."
        case .googleProviderFailed: "Google couldn't complete sign-in. Try again or continue with email."
        case .googleAccessDenied: "Google didn't allow sign-in. Try a different Google account or continue with email."
        }
    }
}

struct ZeroOneAccountConfiguration: Sendable {
    let url: URL
    let publishableKey: String
    let googleEnabled: Bool
    let appleEnabled: Bool
    static let callbackURL = URL(string: "the01://auth/callback")!

    /// The ignored resource is generated from public client settings. Never bundle a secret/admin key.
    static func load(bundle: Bundle = .main) -> Self? {
        guard let path = bundle.url(forResource: "AccountConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: path) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Self? {
        guard let values = try? JSONDecoder().decode(Values.self, from: data),
              let url = URL(string: values.url), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              values.publishableKey.hasPrefix("sb_publishable_") else { return nil }
        return Self(url: url, publishableKey: values.publishableKey,
                    googleEnabled: values.googleEnabled, appleEnabled: values.appleEnabled)
    }

    private struct Values: Decodable {
        let url: String
        let publishableKey: String
        let googleEnabled: Bool
        let appleEnabled: Bool
    }
}

protocol ZeroOneAccountServicing: Sendable {
    func requestEmailCode(email: String) async throws
    func verifyEmailCode(email: String, code: String) async throws -> ZeroOneAccountSession
    func exchangeGoogleCode(_ code: String, verifier: String) async throws -> ZeroOneAccountSession
    func exchangeAppleToken(_ token: String, nonce: String) async throws -> ZeroOneAccountSession
    func refresh(_ session: ZeroOneAccountSession) async throws -> ZeroOneAccountSession
    func verify(_ session: ZeroOneAccountSession) async throws
    func signOut(_ session: ZeroOneAccountSession) async throws
    func deleteAccount(_ session: ZeroOneAccountSession, appleProof: ZeroOneAppleDeletionProof?) async throws
}

/// A fresh one-use Apple authorization, kept in memory only during account deletion.
struct ZeroOneAppleDeletionProof: Sendable {
    let code: String
    let nonce: String
}

/// A small adapter over the documented Supabase Auth HTTP API; tokens are issued/verified by Supabase.
/// Apple frameworks provide networking, system OAuth presentation, cryptography and secure storage.
struct SupabaseZeroOneAccountService: ZeroOneAccountServicing {
    let configuration: ZeroOneAccountConfiguration
    var network: URLSession = .shared

    func requestEmailCode(email: String) async throws {
        guard Self.validEmail(email) else { throw ZeroOneAccountError.invalidInput }
        _ = try await request("auth/v1/otp", body: ["email": email, "create_user": true])
    }

    func verifyEmailCode(email: String, code: String) async throws -> ZeroOneAccountSession {
        guard Self.validEmail(email), (6...10).contains(code.count),
              code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ZeroOneAccountError.invalidInput }
        let data = try await request("auth/v1/verify", body: ["email": email, "token": code, "type": "email"])
        return try await session(from: data)
    }

    func exchangeGoogleCode(_ code: String, verifier: String) async throws -> ZeroOneAccountSession {
        guard !code.isEmpty, verifier.count >= 43 else { throw ZeroOneAccountError.invalidInput }
        let data = try await request("auth/v1/token", query: ["grant_type": "pkce"], body: ["auth_code": code, "code_verifier": verifier])
        return try await session(from: data)
    }

    func exchangeAppleToken(_ token: String, nonce: String) async throws -> ZeroOneAccountSession {
        let data = try await request("auth/v1/token", query: ["grant_type": "id_token"], body: ["provider": "apple", "id_token": token, "nonce": nonce])
        return try await session(from: data)
    }

    func refresh(_ session: ZeroOneAccountSession) async throws -> ZeroOneAccountSession {
        let data = try await request("auth/v1/token", query: ["grant_type": "refresh_token"], body: ["refresh_token": session.refreshToken])
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard response.user.id == session.identity.authenticationID, response.expiresIn > 0,
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              response.tokenType.lowercased() == "bearer" else { throw ZeroOneAccountError.invalidResponse }
        return ZeroOneAccountSession(accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            identity: ZeroOneAccountIdentity(id: session.identity.id, authenticationID: response.user.id, email: response.user.email))
    }

    func verify(_ session: ZeroOneAccountSession) async throws {
        let data = try await request("auth/v1/user", method: "GET", bearer: session.accessToken)
        let user = try JSONDecoder().decode(UserResponse.self, from: data)
        guard user.id == session.identity.authenticationID else { throw ZeroOneAccountError.invalidResponse }
    }

    func signOut(_ session: ZeroOneAccountSession) async throws {
        _ = try await request("auth/v1/logout", query: ["scope": "local"], bearer: session.accessToken)
    }

    func deleteAccount(_ session: ZeroOneAccountSession, appleProof: ZeroOneAppleDeletionProof?) async throws {
        var body = ["confirmation": "DELETE"]
        if let appleProof {
            body["apple_authorization_code"] = appleProof.code
            body["apple_nonce"] = appleProof.nonce
        }
        _ = try await request("functions/v1/delete-account", body: body, bearer: session.accessToken)
    }

    func googleURL(verifier: String) -> URL {
        var components = URLComponents(url: configuration.url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: ZeroOneAccountConfiguration.callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: ZeroOneAccountProof.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        return components.url!
    }

    static func validEmail(_ email: String) -> Bool {
        email.count <= 254 && email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private func session(from data: Data) async throws -> ZeroOneAccountSession {
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              response.expiresIn > 0, response.tokenType.lowercased() == "bearer" else { throw ZeroOneAccountError.invalidResponse }
        // The database allocates a separate 01 ID. Never use the provider's subject as our domain ID.
        let accountData = try await request("rest/v1/rpc/current_account", bearer: response.accessToken)
        let account = try JSONDecoder().decode(AccountResponse.self, from: accountData)
        guard account.authenticationID == response.user.id else { throw ZeroOneAccountError.invalidResponse }
        return ZeroOneAccountSession(accessToken: response.accessToken, refreshToken: response.refreshToken,
                                     expiresAt: Date().addingTimeInterval(response.expiresIn),
                                     identity: ZeroOneAccountIdentity(id: account.id, authenticationID: response.user.id, email: response.user.email))
    }

    private func request(_ path: String, method: String = "POST", query: [String: String] = [:],
                         body: [String: Any]? = nil, bearer: String? = nil) async throws -> Data {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch is CancellationError { throw ZeroOneAccountError.cancelled }
        catch { throw ZeroOneAccountError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw ZeroOneAccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(APIError.self, from: data))?.code
            switch (http.statusCode, code) {
            case (429, _): throw ZeroOneAccountError.rateLimited
            case (_, "otp_expired"): throw ZeroOneAccountError.expiredCode
            case (401, _), (403, _), (_, "refresh_token_not_found"), (_, "refresh_token_already_used"):
                throw ZeroOneAccountError.sessionExpired
            case (409, "apple_reauthentication_required"): throw ZeroOneAccountError.appleReauthenticationRequired
            case (409, _): throw ZeroOneAccountError.providerNotReady
            default: throw ZeroOneAccountError.unavailable
            }
        }
        return data
    }

    private struct APIError: Decodable {
        let code: String?
        enum CodingKeys: String, CodingKey { case code = "error_code" }
    }
    private struct UserResponse: Decodable { let id: UUID; let email: String? }
    private struct AccountResponse: Decodable {
        let id: UUID
        let authenticationID: UUID
        enum CodingKeys: String, CodingKey { case id; case authenticationID = "auth_user_id" }
    }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let tokenType: String
        let user: UserResponse
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", tokenType = "token_type", user
        }
    }
}

/// Callback shape only. These cases never contain provider data or secret parameter values.
enum ZeroOneGoogleCallbackFailure: Error, Equatable, LocalizedError {
    case destination, credentialsOrPort, unexpectedFragment, missingCode, duplicateCode, emptyCode, ambiguousError

    var errorDescription: String? {
        switch self {
        case .unexpectedFragment: "Google returned an unsupported sign-in. Try again or continue with email."
        case .missingCode, .emptyCode: "Google returned an incomplete sign-in. Please try again."
        case .destination, .credentialsOrPort, .duplicateCode, .ambiguousError:
            ZeroOneAccountError.googleReturnInvalid.errorDescription
        }
    }
}

enum ZeroOneAccountProof {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ZeroOneAccountError.secureStorage }
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func appleNonce(_ nonce: String) -> String { SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func callbackCode(_ url: URL) throws -> String {
        guard url.scheme == "the01", url.host == "auth", url.path == "/callback" else {
            throw ZeroOneGoogleCallbackFailure.destination
        }
        guard url.user == nil, url.password == nil, url.port == nil else {
            throw ZeroOneGoogleCallbackFailure.credentialsOrPort
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZeroOneGoogleCallbackFailure.destination
        }
        // Only inspect fixed error classifications. Never retain/display the provider's description or URL.
        let fragmentItems = url.fragment.flatMap { URLComponents(string: "?\($0)")?.queryItems } ?? []
        let items = (components.queryItems ?? []) + fragmentItems
        if items.contains(where: { $0.name == "error" || $0.name == "error_code" }) {
            guard !items.contains(where: { ["code", "access_token", "refresh_token", "id_token"].contains($0.name) }) else {
                throw ZeroOneGoogleCallbackFailure.ambiguousError
            }
            let errors = items.filter { $0.name == "error" }.compactMap(\.value)
            let codes = items.filter { $0.name == "error_code" }.compactMap(\.value)
            if !errors.isEmpty && errors.allSatisfy({ $0 == "access_denied" }),
               codes.allSatisfy({ $0 == "access_denied" }) { throw ZeroOneAccountError.googleAccessDenied }
            throw ZeroOneAccountError.googleProviderFailed
        }
        guard url.fragment == nil else { throw ZeroOneGoogleCallbackFailure.unexpectedFragment }
        let codes = components.queryItems?.filter({ $0.name == "code" }) ?? []
        guard !codes.isEmpty else { throw ZeroOneGoogleCallbackFailure.missingCode }
        guard codes.count == 1 else { throw ZeroOneGoogleCallbackFailure.duplicateCode }
        guard let code = codes.first?.value, !code.isEmpty else { throw ZeroOneGoogleCallbackFailure.emptyCode }
        return code
    }
}

protocol ZeroOneAccountSessionPersisting {
    func load() throws -> ZeroOneAccountSession?
    func save(_ session: ZeroOneAccountSession) throws
    func clear() throws
}

struct KeychainZeroOneAccountStore: ZeroOneAccountSessionPersisting {
    let namespace: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.the01.account", kSecAttrAccount as String: namespace]
    }
    func load() throws -> ZeroOneAccountSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let session = try? JSONDecoder().decode(ZeroOneAccountSession.self, from: data) else { throw ZeroOneAccountError.secureStorage }
        return session
    }
    func save(_ session: ZeroOneAccountSession) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ZeroOneAccountError.secureStorage }
        } else if status != errSecSuccess { throw ZeroOneAccountError.secureStorage }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ZeroOneAccountError.secureStorage }
    }
}
