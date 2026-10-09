import Foundation
import Observation
import AuthenticationServices
import UIKit

@MainActor
protocol ZeroOneGoogleAuthorizing: AnyObject {
    func authorize(_ url: URL) async throws -> URL
    func cancel()
}

/// Fixed categories only. No callback URL, account details, code or token is retained.
enum ZeroOneGoogleFailurePhase: String {
    case authorization, callback, exchange, secureSave
}

@Observable
@MainActor
final class ZeroOneAccountStore {
    private(set) var identity: ZeroOneAccountIdentity?
    private(set) var isBusy = false
    private(set) var needsVerification = false
    private(set) var pendingEmail: String?
    private(set) var nextCodeRequestAt = Date.distantPast
    private(set) var googleFailurePhase: ZeroOneGoogleFailurePhase?
    private(set) var googleCallbackFailure: ZeroOneGoogleCallbackFailure?
    var errorMessage: String?
    let configuration: ZeroOneAccountConfiguration?
    @ObservationIgnored private let service: (any ZeroOneAccountServicing)?
    @ObservationIgnored private let persistence: any ZeroOneAccountSessionPersisting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var session: ZeroOneAccountSession?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var oauth: (any ZeroOneGoogleAuthorizing)?
    @ObservationIgnored private let googleAuthorizationFactory: @MainActor () -> any ZeroOneGoogleAuthorizing
    @ObservationIgnored private var appleDeletion: ZeroOneAppleDeletionAuthorization?
    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    var isConfigured: Bool { configuration != nil && service != nil }
    var hasAuthenticatedBefore: Bool { defaults.bool(forKey: "01.account.hasAuthenticatedBefore") }
    private var discardedSessionKey: String { "01.account.discardedSession.\(configuration?.url.host ?? "unconfigured")" }

    static func live() -> ZeroOneAccountStore {
        let configuration = ZeroOneAccountConfiguration.load()
        return ZeroOneAccountStore(configuration: configuration,
            service: configuration.map { SupabaseZeroOneAccountService(configuration: $0) },
            persistence: KeychainZeroOneAccountStore(namespace: configuration?.url.host ?? "unconfigured"))
    }

    init(configuration: ZeroOneAccountConfiguration?, service: (any ZeroOneAccountServicing)?,
         persistence: any ZeroOneAccountSessionPersisting, defaults: UserDefaults = .standard,
         googleAuthorizationFactory: (@MainActor () -> any ZeroOneGoogleAuthorizing)? = nil) {
        self.configuration = configuration
        self.service = service
        self.persistence = persistence
        self.defaults = defaults
        self.googleAuthorizationFactory = googleAuthorizationFactory ?? { ZeroOneGoogleAuthorization() }
        do {
            if defaults.bool(forKey: discardedSessionKey) {
                try persistence.clear()
                defaults.set(false, forKey: discardedSessionKey)
            } else if configuration != nil { session = try persistence.load() }
            identity = session?.identity
            needsVerification = session != nil
        } catch { errorMessage = ZeroOneAccountError.secureStorage.localizedDescription }
    }

    /// Missing registration is closed export authority. Installing this capability
    /// only supplies pre-change revocation; it never creates an export permit.
    /// Replace/remove on MainActor before changing its retained presentation owner.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Root must retain and match this exact installed capability, not a cached Bool.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    /// Foreground verification never gates app routing or any local training action.
    func restore() async {
        guard !isBusy, let saved = session, let service else { return }
        shareRevocationRegistration?.revokeBeforeChange()
        needsVerification = true
        await perform {
            let current = try await self.current(saved, service: service)
            try await service.verify(current)
            self.shareRevocationRegistration?.revokeBeforeChange()
            self.needsVerification = false
        }
    }

    func requestEmailCode(_ input: String) async -> Bool {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Date() >= nextCodeRequestAt else {
            errorMessage = "Wait a minute before requesting another code."
            return false
        }
        return await perform {
            guard let service = self.service else { throw ZeroOneAccountError.notConfigured }
            let started = self.revision
            try await service.requestEmailCode(email: email)
            guard started == self.revision else { throw ZeroOneAccountError.cancelled }
            self.pendingEmail = email
            self.nextCodeRequestAt = Date().addingTimeInterval(60)
        }
    }

    func verifyEmailCode(_ code: String) async -> Bool {
        await perform {
            guard let email = self.pendingEmail, let service = self.service else { throw ZeroOneAccountError.invalidInput }
            let started = self.revision
            let session = try await service.verifyEmailCode(email: email, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            guard started == self.revision else { throw ZeroOneAccountError.cancelled }
            try self.accept(session)
        }
    }

    func signInWithGoogle() async -> Bool {
        await perform {
            self.googleFailurePhase = nil
            self.googleCallbackFailure = nil
            guard let configuration = self.configuration, configuration.googleEnabled,
                  let service = self.service else { throw ZeroOneAccountError.providerNotReady }
            let started = self.revision
            let verifier = try ZeroOneAccountProof.random()
            let presentation = self.googleAuthorizationFactory()
            self.oauth = presentation
            defer { self.oauth = nil }
            let url = SupabaseZeroOneAccountService(configuration: configuration).googleURL(verifier: verifier)
            var phase = ZeroOneGoogleFailurePhase.authorization
            do {
                let callback = try await presentation.authorize(url)
                guard started == self.revision else { throw ZeroOneAccountError.cancelled }
                phase = .callback
                let code = try ZeroOneAccountProof.callbackCode(callback)
                phase = .exchange
                let session = try await service.exchangeGoogleCode(code, verifier: verifier)
                guard started == self.revision else { throw ZeroOneAccountError.cancelled }
                phase = .secureSave
                try self.accept(session)
            } catch ZeroOneAccountError.cancelled { throw ZeroOneAccountError.cancelled }
            catch {
                if started == self.revision {
                    self.googleFailurePhase = phase
                    self.googleCallbackFailure = error as? ZeroOneGoogleCallbackFailure
                }
                throw error
            }
        }
    }

    func signInWithApple(token: String, nonce: String) async -> Bool {
        await perform {
            guard self.configuration?.appleEnabled == true, let service = self.service else { throw ZeroOneAccountError.providerNotReady }
            let started = self.revision
            let session = try await service.exchangeAppleToken(token, nonce: nonce)
            guard started == self.revision else { throw ZeroOneAccountError.cancelled }
            try self.accept(session)
        }
    }

    func cancelSignIn() {
        shareRevocationRegistration?.revokeBeforeChange()
        revision += 1
        oauth?.cancel()
        appleDeletion?.cancel()
        pendingEmail = nil
        errorMessage = nil
        googleFailurePhase = nil
        googleCallbackFailure = nil
    }

    func clearEmailStep() { cancelSignIn() }

    func signOut() async {
        await perform {
            guard let saved = self.session else { return }
            var warning: String?
            if let service = self.service {
                do {
                    let current = try await self.current(saved, service: service)
                    try await service.signOut(current)
                } catch {
                    warning = "Signed out on this iPhone. The server couldn't be reached to revoke the session."
                }
            }
            if !self.discardSession() {
                let cleanup = "Signed out on this iPhone. Secure session cleanup will retry when you reopen the app."
                warning = [warning, cleanup].compactMap { $0 }.joined(separator: " ")
            }
            self.errorMessage = warning
        }
    }

    func deleteAccount() async -> Bool {
        await perform {
            guard let saved = self.session, let service = self.service else { throw ZeroOneAccountError.sessionExpired }
            let started = self.revision
            let current = try await self.current(saved, service: service)
            guard started == self.revision else { throw ZeroOneAccountError.cancelled }
            try await service.verify(current)
            guard started == self.revision else { throw ZeroOneAccountError.cancelled }
            do { try await service.deleteAccount(current, appleProof: nil) }
            catch ZeroOneAccountError.appleReauthenticationRequired {
                guard started == self.revision else { throw ZeroOneAccountError.cancelled }
                guard self.configuration?.appleEnabled == true else { throw ZeroOneAccountError.providerNotReady }
                let authorization = ZeroOneAppleDeletionAuthorization()
                self.appleDeletion = authorization
                defer { self.appleDeletion = nil }
                let proof = try await authorization.authorize()
                guard started == self.revision else { throw ZeroOneAccountError.cancelled }
                try await service.deleteAccount(current, appleProof: proof)
            }
            // A deleted server account must never be restored from an old Keychain item.
            let cleaned = self.discardSession()
            self.defaults.set(false, forKey: "01.account.hasAuthenticatedBefore")
            if !cleaned {
                self.errorMessage = "Your online account was deleted. Secure session cleanup on this iPhone will retry when you reopen the app."
            }
        }
    }

    private func discardSession() -> Bool {
        shareRevocationRegistration?.revokeBeforeChange()
        defaults.set(true, forKey: discardedSessionKey)
        session = nil
        identity = nil
        needsVerification = false
        pendingEmail = nil
        do {
            try persistence.clear()
            defaults.set(false, forKey: discardedSessionKey)
            return true
        } catch { return false }
    }

    private func accept(_ session: ZeroOneAccountSession) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        try persistence.save(session)
        defaults.set(false, forKey: discardedSessionKey)
        self.session = session
        identity = session.identity
        needsVerification = false
        pendingEmail = nil
        defaults.set(true, forKey: "01.account.hasAuthenticatedBefore")
    }

    private func current(_ saved: ZeroOneAccountSession, service: any ZeroOneAccountServicing) async throws -> ZeroOneAccountSession {
        if saved.expiresAt > Date().addingTimeInterval(60) { return saved }
        let refreshed = try await service.refresh(saved)
        // Save the rotated refresh token immediately; never keep using the consumed token.
        shareRevocationRegistration?.revokeBeforeChange()
        try persistence.save(refreshed)
        session = refreshed
        identity = refreshed.identity
        return refreshed
    }

    @discardableResult private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        shareRevocationRegistration?.revokeBeforeChange()
        isBusy = true
        errorMessage = nil
        let started = revision
        defer {
            shareRevocationRegistration?.revokeBeforeChange()
            isBusy = false
        }
        do { try await operation(); return true }
        catch ZeroOneAccountError.cancelled { return false }
        catch ZeroOneAccountError.sessionExpired {
            // Closing the screen suppresses stale UI, not authoritative invalid-session cleanup.
            let cleaned = discardSession()
            guard started == revision else { return false }
            errorMessage = ZeroOneAccountError.sessionExpired.localizedDescription
            if !cleaned { errorMessage = "Please sign in again. Secure session cleanup will retry when you reopen the app. Your training stays here." }
            return false
        }
        catch {
            guard started == revision else { return false }
            // Don't display or log raw server errors, tokens, codes, URLs or email payloads.
            errorMessage = (error as? ZeroOneGoogleCallbackFailure)?.localizedDescription
                ?? (error as? ZeroOneAccountError)?.localizedDescription ?? ZeroOneAccountError.unavailable.localizedDescription
            return false
        }
    }
}

@MainActor
private final class ZeroOneAppleDeletionAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ZeroOneAppleDeletionProof, Error>?
    private var controller: ASAuthorizationController?
    private var window: UIWindow?
    private var nonce: String?

    func authorize() async throws -> ZeroOneAppleDeletionProof {
        window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first { $0.isKeyWindow }
        guard window != nil else { throw ZeroOneAccountError.unavailable }
        let nonce = try ZeroOneAccountProof.random()
        self.nonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.nonce = ZeroOneAccountProof.appleNonce(nonce)
        return try await withCheckedThrowingContinuation { waiting in
            continuation = waiting
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.authorizationCode, let code = String(data: data, encoding: .utf8),
              !code.isEmpty, let nonce else { finish(.failure(ZeroOneAccountError.invalidResponse)); return }
        finish(.success(ZeroOneAppleDeletionProof(code: code, nonce: nonce)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure((error as? ASAuthorizationError)?.code == .canceled ? ZeroOneAccountError.cancelled : ZeroOneAccountError.unavailable))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window ?? ASPresentationAnchor() }
    func cancel() { finish(.failure(ZeroOneAccountError.cancelled)) }
    private func finish(_ result: Result<ZeroOneAppleDeletionProof, Error>) {
        guard let waiting = continuation else { return }
        continuation = nil
        controller = nil
        window = nil
        nonce = nil
        waiting.resume(with: result)
    }
}

@MainActor
private final class ZeroOneGoogleAuthorization: NSObject, ZeroOneGoogleAuthorizing, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var window: UIWindow?
    private var continuation: CheckedContinuation<URL, Error>?

    func authorize(_ url: URL) async throws -> URL {
        window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first { $0.isKeyWindow }
        guard window != nil else { throw ZeroOneAccountError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "the01") { callback, error in
                Task { @MainActor in
                    if let callback { self.finish(.success(callback)) }
                    else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        self.finish(.failure(ZeroOneAccountError.cancelled))
                    } else { self.finish(.failure(ZeroOneAccountError.unavailable)) }
                }
            }
            self.session = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { self.finish(.failure(ZeroOneAccountError.unavailable)) }
        }
    }
    func cancel() {
        let active = session
        finish(.failure(ZeroOneAccountError.cancelled))
        active?.cancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let waiting = continuation else { return }
        continuation = nil
        session = nil
        window = nil
        waiting.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? ASPresentationAnchor() }
}
