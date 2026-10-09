import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class AccountShareRevocationEventTests: XCTestCase {
    private func make(_ service: AccountEventService? = nil,
                      persistence: AccountEventPersistence = AccountEventPersistence(),
                      google: AccountEventGoogleAuthorization? = nil,
                      defaults: UserDefaults? = nil) -> ZeroOneAccountStore {
        let service = service ?? AccountEventService()
        let googleFactory: (@MainActor () -> any ZeroOneGoogleAuthorizing)?
        if let google { googleFactory = { google } } else { googleFactory = nil }
        return ZeroOneAccountStore(configuration: .init(url: URL(string: "https://example.supabase.co")!,
            publishableKey: "sb_publishable_test", googleEnabled: google != nil, appleEnabled: false),
            service: service, persistence: persistence,
            defaults: defaults ?? UserDefaults(suiteName: "01.account.export-event.tests.\(UUID().uuidString)")!,
            googleAuthorizationFactory: googleFactory)
    }

    private func install(_ account: ZeroOneAccountStore, probe: AccountEventPermitProbe)
        -> AccountEventObservation {
        let observation = AccountEventObservation(account: account)
        let registration = ZeroOneShareRevocationRegistration {
            probe.invalidate()
            // Test-only state observation proves the callback precedes mutation.
            // Production callbacks must touch only retained thread-safe permits.
            MainActor.assumeIsolated { observation.record() }
        }
        account.installShareRevocationRegistration(registration)
        observation.clear()
        probe.arm()
        return observation
    }

    func testMissingRegistrationStaysClosedAndPreservesOrdinaryAccountActions() async {
        let account = make()
        let unrelated = ZeroOneShareRevocationRegistration {}
        XCTAssertFalse(account.isShareRevocationRegistered(nil))
        XCTAssertFalse(account.isShareRevocationRegistered(unrelated))
        let requested = await account.requestEmailCode("user@example.com")
        XCTAssertTrue(requested)
        XCTAssertNil(account.identity)
        XCTAssertEqual(account.pendingEmail, "user@example.com")
        XCTAssertFalse(account.isBusy)
        XCTAssertFalse(account.isShareRevocationRegistered(unrelated))
    }

    func testReplacementRemovalAndSameRegistrationReinstallRevokeBeforeReturning() {
        let account = make(), first = AccountEventPermitProbe(), second = AccountEventPermitProbe()
        let a = ZeroOneShareRevocationRegistration { first.invalidate() }
        let b = ZeroOneShareRevocationRegistration { second.invalidate() }
        account.installShareRevocationRegistration(a)
        XCTAssertTrue(first.wasRevoked)
        XCTAssertTrue(account.isShareRevocationRegistered(a))
        first.arm(); second.arm()
        account.installShareRevocationRegistration(b)
        XCTAssertTrue(first.wasRevoked)
        XCTAssertTrue(second.wasRevoked)
        XCTAssertFalse(account.isShareRevocationRegistered(a))
        XCTAssertTrue(account.isShareRevocationRegistered(b))
        second.arm()
        account.installShareRevocationRegistration(b)
        XCTAssertTrue(second.wasRevoked)
        second.arm()
        account.installShareRevocationRegistration(nil)
        XCTAssertTrue(second.wasRevoked)
        XCTAssertFalse(account.isShareRevocationRegistered(b))
        XCTAssertFalse(account.isShareRevocationRegistered(nil))
    }

    func testRequestEntryRevokesWhileBusyIsStillFalseAndBeforeServiceCall() async throws {
        let service = AccountEventService(), probe = AccountEventPermitProbe()
        let account = make(service), observed = install(account, probe: probe)
        service.beforeRequestReturn = { XCTAssertTrue(probe.wasRevoked) }
        let result = await account.requestEmailCode("user@example.com")
        XCTAssertTrue(result)
        XCTAssertFalse(try XCTUnwrap(observed.snapshots.first).busy)
        XCTAssertFalse(account.isBusy)
        XCTAssertEqual(account.pendingEmail, "user@example.com")
    }

    func testRestoreRevokesBeforeBothVerificationEdgesAndBusyExit() async throws {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        persistence.saved = service.result
        let account = make(service, persistence: persistence)
        await account.restore() // Establish the already-verified starting state.
        XCTAssertFalse(account.needsVerification)
        let probe = AccountEventPermitProbe(), observed = install(account, probe: probe)
        await account.restore()
        let first = try XCTUnwrap(observed.snapshots.first)
        XCTAssertFalse(first.needsVerification)
        XCTAssertFalse(first.busy)
        XCTAssertTrue(observed.snapshots.contains { $0.needsVerification && $0.busy })
        let last = try XCTUnwrap(observed.snapshots.last)
        XCTAssertTrue(last.busy)
        XCTAssertFalse(last.needsVerification)
        XCTAssertFalse(account.needsVerification)
        XCTAssertFalse(account.isBusy)
        XCTAssertEqual(account.identity, service.result.identity)
    }

    func testAcceptRevokesRearmedPermitBeforeTheFirstSecureSave() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        _ = await account.requestEmailCode("user@example.com")
        service.beforeEmailResult = { probe.arm() }
        persistence.beforeSave = { XCTAssertTrue(probe.wasRevoked) }
        let verified = await account.verifyEmailCode("123456")
        XCTAssertTrue(verified)
        XCTAssertEqual(persistence.saved?.identity, service.result.identity)
        XCTAssertEqual(account.identity, service.result.identity)
        XCTAssertTrue(account.hasAuthenticatedBefore)
        XCTAssertNil(account.pendingEmail)
    }

    func testFailedAcceptStillRevokesAndDoesNotInstallIdentity() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        persistence.failSave = true
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        _ = await account.requestEmailCode("user@example.com")
        service.beforeEmailResult = { probe.arm() }
        persistence.beforeSave = { XCTAssertTrue(probe.wasRevoked) }
        let verified = await account.verifyEmailCode("123456")
        XCTAssertFalse(verified)
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertNil(persistence.saved)
        XCTAssertNil(account.identity)
        XCTAssertFalse(account.hasAuthenticatedBefore)
        XCTAssertEqual(account.pendingEmail, "user@example.com")
    }

    func testRotatedRefreshRevokesAgainBeforeSavingTheNewIdentity() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        let expired = ZeroOneAccountSession(accessToken: "synthetic-old-access", refreshToken: "synthetic-old-refresh",
            expiresAt: Date().addingTimeInterval(-1), identity: .init(id: UUID(), authenticationID: UUID(), email: nil))
        persistence.saved = expired
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        service.beforeRefreshResult = { probe.arm() }
        persistence.beforeSave = { XCTAssertTrue(probe.wasRevoked) }
        await account.restore()
        XCTAssertEqual(persistence.saved?.identity, service.result.identity)
        XCTAssertEqual(account.identity, service.result.identity)
        XCTAssertFalse(account.needsVerification)
        XCTAssertEqual(service.refreshRequests, 1)
    }

    func testFailedRotatedRefreshSavePreservesCachedIdentityAndRevokes() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        let expired = ZeroOneAccountSession(accessToken: "synthetic-old-access", refreshToken: "synthetic-old-refresh",
            expiresAt: Date().addingTimeInterval(-1), identity: .init(id: UUID(), authenticationID: UUID(), email: nil))
        persistence.saved = expired; persistence.failSave = true
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        service.beforeRefreshResult = { probe.arm() }
        persistence.beforeSave = { XCTAssertTrue(probe.wasRevoked) }
        await account.restore()
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertEqual(account.identity, expired.identity)
        XCTAssertEqual(persistence.saved?.identity, expired.identity)
        XCTAssertTrue(account.needsVerification)
        XCTAssertNotNil(account.errorMessage)
    }

    func testCancelRevokesSynchronouslyBeforeGoogleCancellationAndKeepsLateResultRejected() async throws {
        let service = AccountEventService(), google = AccountEventGoogleAuthorization()
        let account = make(service, google: google), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        let entered = expectation(description: "Google authorization fixture suspended")
        google.authorizationStarted = entered
        let attempt = Task { await account.signInWithGoogle() }
        defer {
            attempt.cancel()
            if let pending = google.continuation {
                google.continuation = nil
                pending.resume(throwing: ZeroOneAccountError.cancelled)
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let continuation = try XCTUnwrap(google.continuation)
        probe.arm()
        google.beforeCancel = { XCTAssertTrue(probe.wasRevoked) }
        account.cancelSignIn()
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertEqual(google.cancelCalls, 1)
        google.continuation = nil
        continuation.resume(returning: URL(string: "the01://auth/callback?code=synthetic-code")!)
        let result = await attempt.value
        XCTAssertFalse(result)
        XCTAssertEqual(service.googleExchanges, 0)
        XCTAssertNil(account.identity)
        XCTAssertNil(account.errorMessage)
    }

    func testExpiryAfterCancellationRevokesBeforeAuthoritativeCleanupAndSuppressesStaleError() async throws {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        persistence.saved = service.result
        service.holdVerification = true
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        let entered = expectation(description: "Account verification fixture suspended")
        service.verificationStarted = entered
        let restore = Task { await account.restore() }
        defer {
            restore.cancel()
            if let pending = service.verificationContinuation {
                service.verificationContinuation = nil
                pending.resume()
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let continuation = try XCTUnwrap(service.verificationContinuation)
        account.cancelSignIn()
        probe.arm() // Cleanup must revoke again even after cancellation already did.
        persistence.beforeClear = { XCTAssertTrue(probe.wasRevoked) }
        service.error = .sessionExpired
        service.verificationContinuation = nil
        continuation.resume()
        await restore.value
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertNil(account.identity)
        XCTAssertNil(persistence.saved)
        XCTAssertFalse(account.needsVerification)
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.isBusy)
    }

    func testFailedLogoutCleanupRevokesBeforeClearAndPreservesTheDiscardMarkerRetry() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        persistence.saved = service.result; persistence.failClear = true
        let defaults = UserDefaults(suiteName: "01.account.export-event.retry.\(UUID().uuidString)")!
        let account = make(service, persistence: persistence, defaults: defaults), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        service.beforeSignOutReturn = { probe.arm() }
        persistence.beforeClear = { XCTAssertTrue(probe.wasRevoked) }
        await account.signOut()
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertNil(account.identity)
        XCTAssertNotNil(persistence.saved)
        XCTAssertNotNil(account.errorMessage)
        XCTAssertTrue(defaults.bool(forKey: "01.account.discardedSession.example.supabase.co"))
        persistence.beforeClear = nil
        let reopened = make(service, persistence: persistence, defaults: defaults)
        XCTAssertNil(reopened.identity)
        persistence.failClear = false
        let cleaned = make(service, persistence: persistence, defaults: defaults)
        XCTAssertNil(cleaned.identity)
        XCTAssertNil(persistence.saved)
    }

    func testFailedDeletionLeavesIdentityIntactButNeverRestoresARevokedPermit() async {
        let service = AccountEventService(), persistence = AccountEventPersistence()
        persistence.saved = service.result
        service.deletionFails = true
        let account = make(service, persistence: persistence), probe = AccountEventPermitProbe()
        _ = install(account, probe: probe)
        let deleted = await account.deleteAccount()
        XCTAssertFalse(deleted)
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertEqual(account.identity, service.result.identity)
        XCTAssertEqual(persistence.saved?.identity, service.result.identity)
        XCTAssertEqual(service.deletionRequests, 1)
        XCTAssertNotNil(account.errorMessage)
    }

    func testBusyExitRevokesARearmedPermitBeforeReturningToIdle() async throws {
        let service = AccountEventService(), account = make(service), probe = AccountEventPermitProbe()
        let observed = install(account, probe: probe)
        service.beforeRequestReturn = { probe.arm() }
        let requested = await account.requestEmailCode("user@example.com")
        XCTAssertTrue(requested)
        XCTAssertTrue(probe.wasRevoked)
        XCTAssertTrue(try XCTUnwrap(observed.snapshots.last).busy)
        XCTAssertFalse(account.isBusy)
    }

    func testImmutableRegistrationCallsCompleteSynchronouslyFromConcurrentThreadsWithoutRegistryLock() {
        let inner = AccountEventPermitProbe(), outer = AccountEventPermitProbe()
        let innerRegistration = ZeroOneShareRevocationRegistration { inner.invalidate() }
        let registration = ZeroOneShareRevocationRegistration {
            innerRegistration.revokeBeforeChange()
            outer.invalidate()
        }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in registration.revokeBeforeChange() }
        XCTAssertEqual(inner.count, 32)
        XCTAssertEqual(outer.count, 32)
        XCTAssertTrue(inner.wasRevoked)
        XCTAssertTrue(outer.wasRevoked)
    }
}

private final class AccountEventPermitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var invocations = 0
    func arm() { lock.lock(); invalidated = false; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; invocations += 1; lock.unlock() }
    var wasRevoked: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
    var count: Int { lock.lock(); defer { lock.unlock() }; return invocations }
}

@MainActor
private final class AccountEventObservation {
    struct Snapshot { let busy: Bool; let needsVerification: Bool; let identity: UUID? }
    weak var account: ZeroOneAccountStore?
    private(set) var snapshots: [Snapshot] = []
    init(account: ZeroOneAccountStore) { self.account = account }
    func record() {
        guard let account else { return }
        snapshots.append(.init(busy: account.isBusy, needsVerification: account.needsVerification, identity: account.identity?.id))
    }
    func clear() { snapshots = [] }
}

private final class AccountEventPersistence: ZeroOneAccountSessionPersisting {
    var saved: ZeroOneAccountSession?
    var failSave = false
    var failClear = false
    var beforeSave: (@Sendable () -> Void)?
    var beforeClear: (@Sendable () -> Void)?
    func load() throws -> ZeroOneAccountSession? { saved }
    func save(_ session: ZeroOneAccountSession) throws {
        beforeSave?()
        if failSave { throw ZeroOneAccountError.secureStorage }
        saved = session
    }
    func clear() throws {
        beforeClear?()
        if failClear { throw ZeroOneAccountError.secureStorage }
        saved = nil
    }
}

@MainActor
private final class AccountEventGoogleAuthorization: ZeroOneGoogleAuthorizing {
    var continuation: CheckedContinuation<URL, Error>?
    var authorizationStarted: XCTestExpectation?
    var beforeCancel: (() -> Void)?
    var cancelCalls = 0
    func authorize(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
            continuation = $0
            authorizationStarted?.fulfill()
        }
    }
    func cancel() { beforeCancel?(); cancelCalls += 1 }
}

@MainActor
private final class AccountEventService: ZeroOneAccountServicing {
    var result = ZeroOneAccountSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        expiresAt: Date().addingTimeInterval(3600), identity: .init(id: UUID(), authenticationID: UUID(), email: nil))
    var error: ZeroOneAccountError?
    var deletionFails = false
    var holdVerification = false
    var verificationContinuation: CheckedContinuation<Void, Never>?
    var verificationStarted: XCTestExpectation?
    var beforeRequestReturn: (() -> Void)?
    var beforeEmailResult: (() -> Void)?
    var beforeRefreshResult: (() -> Void)?
    var beforeSignOutReturn: (() -> Void)?
    var refreshRequests = 0
    var googleExchanges = 0
    var deletionRequests = 0
    func requestEmailCode(email: String) async throws { beforeRequestReturn?(); if let error { throw error } }
    func verifyEmailCode(email: String, code: String) async throws -> ZeroOneAccountSession {
        beforeEmailResult?(); if let error { throw error }; return result
    }
    func exchangeGoogleCode(_ code: String, verifier: String) async throws -> ZeroOneAccountSession {
        googleExchanges += 1; if let error { throw error }; return result
    }
    func exchangeAppleToken(_ token: String, nonce: String) async throws -> ZeroOneAccountSession {
        if let error { throw error }; return result
    }
    func refresh(_ session: ZeroOneAccountSession) async throws -> ZeroOneAccountSession {
        refreshRequests += 1; beforeRefreshResult?(); if let error { throw error }; return result
    }
    func verify(_ session: ZeroOneAccountSession) async throws {
        try Task.checkCancellation()
        if holdVerification {
            await withCheckedContinuation {
                verificationContinuation = $0
                verificationStarted?.fulfill()
            }
        }
        if let error { throw error }
    }
    func signOut(_ session: ZeroOneAccountSession) async throws { beforeSignOutReturn?(); if let error { throw error } }
    func deleteAccount(_ session: ZeroOneAccountSession, appleProof: ZeroOneAppleDeletionProof?) async throws {
        deletionRequests += 1
        if deletionFails { throw ZeroOneAccountError.unavailable }
        if let error { throw error }
    }
}
