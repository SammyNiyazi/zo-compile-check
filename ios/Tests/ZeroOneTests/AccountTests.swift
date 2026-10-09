import XCTest
@testable import ZeroOne

@MainActor
final class AccountTests: XCTestCase {
    private func make(_ service: FakeAccountService, persistence: MemoryAccountPersistence = MemoryAccountPersistence(), defaults: UserDefaults? = nil,
                      googleAuthorizationFactory: (@MainActor () -> any ZeroOneGoogleAuthorizing)? = nil) -> ZeroOneAccountStore {
        let defaults = defaults ?? UserDefaults(suiteName: "01.account.tests.\(UUID().uuidString)")!
        return ZeroOneAccountStore(configuration: .init(url: URL(string: "https://example.supabase.co")!,
            publishableKey: "sb_publishable_test", googleEnabled: googleAuthorizationFactory != nil, appleEnabled: false),
            service: service, persistence: persistence, defaults: defaults, googleAuthorizationFactory: googleAuthorizationFactory)
    }

    func testCodeRequestDoesNotAuthenticateOrSaveASession() async {
        let persistence = MemoryAccountPersistence()
        let account = make(FakeAccountService(), persistence: persistence)
        let requested = await account.requestEmailCode(" user@example.com ")
        XCTAssertTrue(requested)
        XCTAssertEqual(account.pendingEmail, "user@example.com")
        XCTAssertNil(account.identity)
        XCTAssertNil(persistence.saved)
        XCTAssertFalse(account.hasAuthenticatedBefore)
    }

    func testInvalidCodeNeverCreatesAccountState() async {
        let service = FakeAccountService()
        service.error = .expiredCode
        let account = make(service)
        service.error = nil
        _ = await account.requestEmailCode("user@example.com")
        service.error = .expiredCode
        let verified = await account.verifyEmailCode("123456")
        XCTAssertFalse(verified)
        XCTAssertNil(account.identity)
        XCTAssertFalse(account.hasAuthenticatedBefore)
    }

    func testFailedSecureSaveDoesNotClaimSignedIn() async {
        let persistence = MemoryAccountPersistence()
        persistence.failSave = true
        let account = make(FakeAccountService(), persistence: persistence)
        _ = await account.requestEmailCode("user@example.com")
        let verified = await account.verifyEmailCode("123456")
        XCTAssertFalse(verified)
        XCTAssertNil(account.identity)
        XCTAssertFalse(account.hasAuthenticatedBefore)
    }

    func testVerifiedSessionRestoresWithoutEmailInDefaults() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        let account = make(service, persistence: persistence)
        _ = await account.requestEmailCode("user@example.com")
        let verified = await account.verifyEmailCode("123456")
        XCTAssertTrue(verified)
        XCTAssertEqual(account.identity?.id, service.session.identity.id)
        XCTAssertTrue(account.hasAuthenticatedBefore)
        let restored = make(service, persistence: persistence)
        XCTAssertEqual(restored.identity?.id, service.session.identity.id)
        XCTAssertTrue(restored.needsVerification)
        await restored.restore()
        XCTAssertFalse(restored.needsVerification)
    }

    func testOfflineSignOutClearsSecureSessionAndReportsRevocationLimit() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        let account = make(service, persistence: persistence)
        _ = await account.requestEmailCode("user@example.com")
        _ = await account.verifyEmailCode("123456")
        service.error = .unavailable
        await account.signOut()
        XCTAssertNil(account.identity)
        XCTAssertNil(persistence.saved)
        XCTAssertNotNil(account.errorMessage)
    }

    func testOfflineRestoreRetainsCachedIdentityButDoesNotMarkItVerified() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        let account = make(service, persistence: persistence)
        service.error = .unavailable
        await account.restore()
        XCTAssertEqual(account.identity?.id, service.session.identity.id)
        XCTAssertTrue(account.needsVerification)
        XCTAssertNotNil(persistence.saved)
    }

    func testFailedDeletionKeepsAccountAndSecureSession() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        let account = make(service, persistence: persistence)
        service.deletionFails = true
        let deleted = await account.deleteAccount()
        XCTAssertFalse(deleted)
        XCTAssertNotNil(account.identity)
        XCTAssertNotNil(persistence.saved)
    }

    func testClosingAccountDuringVerificationNeverSubmitsDeletion() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        let account = make(service, persistence: persistence)
        service.holdVerification = true
        let deletion = Task { await account.deleteAccount() }
        while service.verificationContinuation == nil { await Task.yield() }
        account.cancelSignIn()
        service.verificationContinuation?.resume()
        let deleted = await deletion.value
        XCTAssertFalse(deleted)
        XCTAssertEqual(service.deletionRequests, 0)
        XCTAssertNotNil(account.identity)
        XCTAssertNil(account.errorMessage)
    }

    func testCancelledDeletionNeverContinuesAfterLateAppleReauthenticationResponse() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        let account = make(service, persistence: persistence)
        service.holdDeletion = true
        let deletion = Task { await account.deleteAccount() }
        while service.deletionContinuation == nil { await Task.yield() }
        account.cancelSignIn()
        service.error = .appleReauthenticationRequired
        service.deletionContinuation?.resume()
        let deleted = await deletion.value
        XCTAssertFalse(deleted)
        XCTAssertEqual(service.deletionRequests, 1)
        XCTAssertNotNil(account.identity)
        XCTAssertNil(account.errorMessage)
    }

    func testBackDiscardsARequestThatFinishesLater() async {
        let service = FakeAccountService()
        service.holdRequest = true
        let account = make(service)
        let request = Task { await account.requestEmailCode("user@example.com") }
        while service.requestContinuation == nil { await Task.yield() }
        account.clearEmailStep()
        service.requestContinuation?.resume()
        let requested = await request.value
        XCTAssertFalse(requested)
        XCTAssertNil(account.pendingEmail)
        XCTAssertNil(account.identity)
    }

    func testDeletedAccountCannotRestoreWhenKeychainCleanupFails() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        persistence.failClear = true
        let defaults = UserDefaults(suiteName: "01.account.tests.\(UUID().uuidString)")!
        let configuration = ZeroOneAccountConfiguration(url: URL(string: "https://example.supabase.co")!,
            publishableKey: "sb_publishable_test", googleEnabled: false, appleEnabled: false)
        let account = ZeroOneAccountStore(configuration: configuration, service: service, persistence: persistence, defaults: defaults)
        let deleted = await account.deleteAccount()
        XCTAssertTrue(deleted)
        XCTAssertNil(account.identity)
        XCTAssertNotNil(account.errorMessage)
        let restored = ZeroOneAccountStore(configuration: configuration, service: service, persistence: persistence, defaults: defaults)
        XCTAssertNil(restored.identity)
        persistence.failClear = false
        let cleaned = ZeroOneAccountStore(configuration: configuration, service: service, persistence: persistence, defaults: defaults)
        XCTAssertNil(cleaned.identity)
        XCTAssertNil(persistence.saved)
    }

    func testSignOutDiscardsIdentityEvenWhenKeychainCleanupFails() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        persistence.failClear = true
        let defaults = UserDefaults(suiteName: "01.account.tests.\(UUID().uuidString)")!
        let account = make(service, persistence: persistence, defaults: defaults)
        service.error = .unavailable
        await account.signOut()
        XCTAssertNil(account.identity)
        XCTAssertFalse(account.needsVerification)
        XCTAssertNotNil(account.errorMessage)
        let restored = make(service, persistence: persistence, defaults: defaults)
        XCTAssertNil(restored.identity)
        persistence.failClear = false
        let cleaned = make(service, persistence: persistence, defaults: defaults)
        XCTAssertNil(cleaned.identity)
        XCTAssertNil(persistence.saved)
    }

    func testExpiredSessionDiscardsIdentityEvenWhenKeychainCleanupFails() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        persistence.failClear = true
        let defaults = UserDefaults(suiteName: "01.account.tests.\(UUID().uuidString)")!
        let account = make(service, persistence: persistence, defaults: defaults)
        service.error = .sessionExpired
        await account.restore()
        XCTAssertNil(account.identity)
        XCTAssertFalse(account.needsVerification)
        XCTAssertNotNil(account.errorMessage)
        let restored = make(service, persistence: persistence, defaults: defaults)
        XCTAssertNil(restored.identity)
    }

    func testMismatchedAndDuplicateOAuthCallbacksAreRejected() throws {
        XCTAssertEqual(try ZeroOneAccountProof.callbackCode(URL(string: "the01://auth/callback?code=example")!), "example")
        for raw in ["the01://widget/callback?code=example", "the01://auth/other?code=example",
                    "https://auth/callback?code=example", "the01://auth/callback?code=one&code=two",
                    "the01://auth/callback?code=example&error=denied", "the01://auth/callback#access_token=example",
                    "the01://user@auth/callback?code=example", "the01://auth:443/callback?code=example"] {
            XCTAssertThrowsError(try ZeroOneAccountProof.callbackCode(URL(string: raw)!))
        }
    }

    func testGoogleProviderErrorsNeverExchangeOrSaveTokens() async {
        for raw in ["the01://auth/callback?error=server_error&error_code=unexpected_failure",
                    "the01://auth/callback#error=server_error&error_code=unexpected_failure",
                    "the01://auth/callback?error=server_error#error=server_error"] {
            let service = FakeAccountService()
            let persistence = MemoryAccountPersistence()
            let authorization = FakeGoogleAuthorization(callback: URL(string: raw)!)
            let account = make(service, persistence: persistence, googleAuthorizationFactory: { authorization })
            let signedIn = await account.signInWithGoogle()
            XCTAssertFalse(signedIn)
            XCTAssertEqual(account.googleFailurePhase, .callback)
            XCTAssertEqual(account.errorMessage, ZeroOneAccountError.googleProviderFailed.localizedDescription)
            XCTAssertTrue(service.googleExchanges.isEmpty)
            XCTAssertNil(account.identity)
            XCTAssertNil(persistence.saved)
        }
    }

    func testGoogleAccessDenialIsVisibleAndNeverExchanged() async {
        let service = FakeAccountService()
        let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?error=access_denied#error=access_denied")!)
        let account = make(service, googleAuthorizationFactory: { authorization })
        let signedIn = await account.signInWithGoogle()
        XCTAssertFalse(signedIn)
        XCTAssertEqual(account.errorMessage, ZeroOneAccountError.googleAccessDenied.localizedDescription)
        XCTAssertEqual(account.googleFailurePhase, .callback)
        XCTAssertTrue(service.googleExchanges.isEmpty)
    }

    func testSystemGoogleCancellationDoesNotShowAnError() async {
        let service = FakeAccountService()
        let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=synthetic")!)
        authorization.error = .cancelled
        let account = make(service, googleAuthorizationFactory: { authorization })
        let signedIn = await account.signInWithGoogle()
        XCTAssertFalse(signedIn)
        XCTAssertNil(account.errorMessage)
        XCTAssertNil(account.googleFailurePhase)
        XCTAssertTrue(service.googleExchanges.isEmpty)
    }

    func testClosingDuringRestoreDoesNotRetainAnExpiredSessionOrShowALateError() async {
        let service = FakeAccountService()
        service.holdVerification = true
        let persistence = MemoryAccountPersistence()
        persistence.saved = service.session
        let account = make(service, persistence: persistence)
        let restore = Task { await account.restore() }
        while service.verificationContinuation == nil { await Task.yield() }
        account.cancelSignIn()
        service.error = .sessionExpired
        service.verificationContinuation?.resume()
        await restore.value
        XCTAssertNil(account.identity)
        XCTAssertNil(persistence.saved)
        XCTAssertFalse(account.needsVerification)
        XCTAssertNil(account.errorMessage)
    }

    func testMalformedGoogleReturnRecordsOnlyShapeAndNeverExchanges() async {
        let service = FakeAccountService()
        let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback#access_token=synthetic")!)
        let account = make(service, googleAuthorizationFactory: { authorization })
        let signedIn = await account.signInWithGoogle()
        XCTAssertFalse(signedIn)
        XCTAssertEqual(account.googleFailurePhase, .callback)
        XCTAssertEqual(account.googleCallbackFailure, .unexpectedFragment)
        XCTAssertEqual(account.errorMessage, ZeroOneGoogleCallbackFailure.unexpectedFragment.localizedDescription)
        XCTAssertTrue(service.googleExchanges.isEmpty)
    }

    func testGoogleSignInAfterLogoutUsesANewVerifierAndRestoresNewSession() async throws {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        let defaults = UserDefaults(suiteName: "01.account.tests.\(UUID().uuidString)")!
        let first = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=first")!)
        let second = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=second")!)
        var authorizations = [first, second]
        let account = make(service, persistence: persistence, defaults: defaults, googleAuthorizationFactory: { authorizations.removeFirst() })
        let firstSignIn = await account.signInWithGoogle()
        XCTAssertTrue(firstSignIn)
        persistence.failClear = true
        await account.signOut()
        XCTAssertNil(account.identity)
        persistence.failClear = false
        service.session = ZeroOneAccountSession(accessToken: "second-test-access", refreshToken: "second-test-refresh",
            expiresAt: Date().addingTimeInterval(3600), identity: service.session.identity)
        let secondSignIn = await account.signInWithGoogle()
        XCTAssertTrue(secondSignIn)
        XCTAssertEqual(service.googleExchanges.map(\.code), ["first", "second"])
        guard service.googleExchanges.count == 2 else { return }
        XCTAssertNotEqual(service.googleExchanges[0].verifier, service.googleExchanges[1].verifier)
        XCTAssertEqual(persistence.saved?.accessToken, "second-test-access")
        XCTAssertEqual(persistence.saved?.refreshToken, "second-test-refresh")
        XCTAssertFalse(defaults.bool(forKey: "01.account.discardedSession.example.supabase.co"))
        for (authorization, exchange) in zip([first, second], service.googleExchanges) {
            let url = try XCTUnwrap(authorization.requests.first)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first(where: { $0.name == "code_challenge" })?.value, ZeroOneAccountProof.challenge(exchange.verifier))
            XCTAssertEqual(items.first(where: { $0.name == "prompt" })?.value, "select_account")
            XCTAssertEqual(items.first(where: { $0.name == "redirect_to" })?.value, "the01://auth/callback")
        }
        let restored = make(service, persistence: persistence, defaults: defaults)
        XCTAssertEqual(restored.identity, service.session.identity)
        await restored.restore()
        XCTAssertEqual(service.verifiedAccessTokens.last, "second-test-access")
    }

    func testCancelledGoogleReturnCannotSubmitAnExchange() async {
        let service = FakeAccountService()
        let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=synthetic")!)
        authorization.holdReturn = true
        let account = make(service, googleAuthorizationFactory: { authorization })
        let attempt = Task { await account.signInWithGoogle() }
        while authorization.continuation == nil { await Task.yield() }
        account.cancelSignIn()
        authorization.continuation?.resume()
        let signedIn = await attempt.value
        XCTAssertFalse(signedIn)
        XCTAssertEqual(authorization.cancellations, 1)
        XCTAssertTrue(service.googleExchanges.isEmpty)
        XCTAssertNil(account.identity)
        XCTAssertNil(account.errorMessage)
    }

    func testCancelledGoogleExchangeCannotRestoreIdentityOrShowALateError() async {
        for error in [Optional<ZeroOneAccountError>.none, .invalidResponse] {
            let service = FakeAccountService()
            service.holdGoogleExchange = true
            let persistence = MemoryAccountPersistence()
            let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=synthetic")!)
            let account = make(service, persistence: persistence, googleAuthorizationFactory: { authorization })
            let attempt = Task { await account.signInWithGoogle() }
            while service.googleContinuation == nil { await Task.yield() }
            account.cancelSignIn()
            service.error = error
            service.googleContinuation?.resume()
            let signedIn = await attempt.value
            XCTAssertFalse(signedIn)
            XCTAssertNil(account.identity)
            XCTAssertNil(persistence.saved)
            XCTAssertNil(account.errorMessage)
            XCTAssertNil(account.googleFailurePhase)
        }
    }

    func testGoogleSecureSaveFailureDoesNotClaimAuthentication() async {
        let service = FakeAccountService()
        let persistence = MemoryAccountPersistence()
        persistence.failSave = true
        let authorization = FakeGoogleAuthorization(callback: URL(string: "the01://auth/callback?code=synthetic")!)
        let account = make(service, persistence: persistence, googleAuthorizationFactory: { authorization })
        let signedIn = await account.signInWithGoogle()
        XCTAssertFalse(signedIn)
        XCTAssertEqual(account.googleFailurePhase, .secureSave)
        XCTAssertNil(account.identity)
        XCTAssertNil(persistence.saved)
        XCTAssertFalse(account.hasAuthenticatedBefore)
    }

    func testPKCEUsesPublishedRFC7636Vector() {
        XCTAssertEqual(ZeroOneAccountProof.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testConfigurationRejectsPrivateKeysAndUnexpectedURLComponents() throws {
        func decode(_ url: String, key: String = "sb_publishable_test") throws -> ZeroOneAccountConfiguration? {
            ZeroOneAccountConfiguration.decode(try JSONSerialization.data(withJSONObject: ["url": url,
                "publishableKey": key, "googleEnabled": false, "appleEnabled": false]))
        }
        XCTAssertNotNil(try decode("https://example.supabase.co"))
        for url in ["http://example.supabase.co", "https://user@example.supabase.co", "https://example.supabase.co:443",
                    "https://example.supabase.co/path", "https://example.supabase.co?key=example", "https://example.supabase.co#example"] {
            XCTAssertNil(try decode(url))
        }
        XCTAssertNil(try decode("https://example.supabase.co", key: "sb_secret_synthetic"))
    }

    func testBundledAccountConfigurationLoadsWhenIncluded() throws {
        guard Bundle.main.url(forResource: "AccountConfiguration", withExtension: "json") != nil else {
            throw XCTSkip("Optional account resource is absent. Accounts validation CI separately requires it in the built app.")
        }
        XCTAssertNotNil(ZeroOneAccountConfiguration.load())
    }
}

private final class MemoryAccountPersistence: ZeroOneAccountSessionPersisting {
    var saved: ZeroOneAccountSession?
    var failSave = false
    var failClear = false
    func load() throws -> ZeroOneAccountSession? { saved }
    func save(_ session: ZeroOneAccountSession) throws {
        if failSave { throw ZeroOneAccountError.secureStorage }
        saved = session
    }
    func clear() throws {
        if failClear { throw ZeroOneAccountError.secureStorage }
        saved = nil
    }
}

@MainActor
private final class FakeGoogleAuthorization: ZeroOneGoogleAuthorizing {
    let callback: URL
    var error: ZeroOneAccountError?
    var holdReturn = false
    var continuation: CheckedContinuation<Void, Never>?
    var requests: [URL] = []
    var cancellations = 0
    init(callback: URL) { self.callback = callback }
    func authorize(_ url: URL) async throws -> URL {
        requests.append(url)
        if holdReturn { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return callback
    }
    func cancel() { cancellations += 1 }
}

@MainActor
private final class FakeAccountService: ZeroOneAccountServicing {
    var error: ZeroOneAccountError?
    var deletionFails = false
    var holdRequest = false
    var holdVerification = false
    var holdDeletion = false
    var deletionRequests = 0
    var requestContinuation: CheckedContinuation<Void, Never>?
    var verificationContinuation: CheckedContinuation<Void, Never>?
    var deletionContinuation: CheckedContinuation<Void, Never>?
    var holdGoogleExchange = false
    var googleContinuation: CheckedContinuation<Void, Never>?
    var googleExchanges: [(code: String, verifier: String)] = []
    var verifiedAccessTokens: [String] = []
    var session = ZeroOneAccountSession(accessToken: "test-access", refreshToken: "test-refresh",
        expiresAt: Date().addingTimeInterval(3600),
        identity: ZeroOneAccountIdentity(id: UUID(), authenticationID: UUID(), email: "user@example.com"))
    func requestEmailCode(email: String) async throws {
        if holdRequest { await withCheckedContinuation { requestContinuation = $0 } }
        if let error { throw error }
    }
    func verifyEmailCode(email: String, code: String) async throws -> ZeroOneAccountSession { try checked() }
    func exchangeGoogleCode(_ code: String, verifier: String) async throws -> ZeroOneAccountSession {
        googleExchanges.append((code, verifier))
        if holdGoogleExchange { await withCheckedContinuation { googleContinuation = $0 } }
        return try checked()
    }
    func exchangeAppleToken(_ token: String, nonce: String) async throws -> ZeroOneAccountSession { try checked() }
    func refresh(_ session: ZeroOneAccountSession) async throws -> ZeroOneAccountSession { try checked() }
    func verify(_ session: ZeroOneAccountSession) async throws {
        verifiedAccessTokens.append(session.accessToken)
        if holdVerification { await withCheckedContinuation { verificationContinuation = $0 } }
        if let error { throw error }
    }
    func signOut(_ session: ZeroOneAccountSession) async throws { if let error { throw error } }
    func deleteAccount(_ session: ZeroOneAccountSession, appleProof: ZeroOneAppleDeletionProof?) async throws {
        deletionRequests += 1
        if holdDeletion { await withCheckedContinuation { deletionContinuation = $0 } }
        if deletionFails { throw ZeroOneAccountError.unavailable }
        if let error { throw error }
    }
    private func checked() throws -> ZeroOneAccountSession { if let error { throw error }; return session }
}
