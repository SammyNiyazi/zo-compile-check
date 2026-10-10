import XCTest
@testable import ZeroOne

final class SocialPolicyTests: XCTestCase {
    private let author = UUID()
    private let viewer = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadinessRequiresEveryOperationalGate() {
        XCTAssertFalse(ZeroOneSocialReadiness.disabled.socialEnabled)
        XCTAssertFalse(ZeroOneSocialReadiness(serviceAccepted: true, privacyAccepted: true,
            moderationOperational: false, nearbyAccepted: true).nearbyEnabled)
        XCTAssertTrue(ZeroOneSocialReadiness(serviceAccepted: true, privacyAccepted: true,
            moderationOperational: true, nearbyAccepted: true).nearbyEnabled)
    }

    func testAnonymousAndRevokedCannotReadEvenCommunityPosts() {
        XCTAssertFalse(ZeroOneSocialPolicy.canReadPost(viewer: nil, author: author, audience: .community,
            selected: [], follows: true, mutualFriends: true, blockedEitherWay: false,
            deleted: false, sessionActive: true))
        XCTAssertFalse(read(audience: .community, sessionActive: false))
        XCTAssertTrue(read(audience: .community))
    }

    func testAudienceIsReevaluatedAfterUnfollowOrFriendRevocation() {
        XCTAssertFalse(read(audience: .followers))
        XCTAssertTrue(read(audience: .followers, follows: true))
        XCTAssertFalse(read(audience: .friends))
        XCTAssertTrue(read(audience: .friends, friends: true))
        XCTAssertFalse(read(audience: .selected, selected: [viewer]))
        XCTAssertTrue(read(audience: .selected, selected: [viewer], friends: true))
        XCTAssertFalse(read(audience: .selected, selected: [], friends: true))
    }

    func testBlockAndDeleteOverrideEveryAudience() {
        for audience in [ZeroOneSocialAudience.community, .followers, .friends, .selected] {
            XCTAssertFalse(read(audience: audience, selected: [viewer], follows: true, friends: true, blocked: true))
            XCTAssertFalse(read(audience: audience, selected: [viewer], follows: true, friends: true, deleted: true))
        }
    }

    func testPublishingNeedsIntentAndAudienceSelection() throws {
        let valid = post(audience: .selected, recipients: [viewer], confirmed: true)
        XCTAssertNoThrow(try valid.validate())
        XCTAssertThrowsError(try post(audience: .community, recipients: [], confirmed: false).validate())
        XCTAssertThrowsError(try post(audience: .selected, recipients: [], confirmed: true).validate())
        XCTAssertThrowsError(try post(audience: .friends, recipients: [viewer], confirmed: true).validate())
    }

    func testSelectedNumbersPreserveExplicitUnitsAndRejectInvalidSets() throws {
        let exact = ZeroOneSocialSelectedSet(exercise: "Bench press", reps: 8, seconds: nil, load: 80, unit: "kg")
        XCTAssertTrue(exact.isValid)
        let encoded = String(decoding: try JSONEncoder().encode(exact), as: UTF8.self)
        XCTAssertTrue(encoded.contains("80"))
        XCTAssertTrue(encoded.contains("kg"))
        XCTAssertFalse(ZeroOneSocialSelectedSet(exercise: "Bench", reps: 8, seconds: nil, load: .nan, unit: "kg").isValid)
        XCTAssertFalse(ZeroOneSocialSelectedSet(exercise: "Bench", reps: 8, seconds: nil, load: 80, unit: nil).isValid)
        XCTAssertFalse(ZeroOneSocialSelectedSet(exercise: "Hold", reps: 8, seconds: 30, load: nil, unit: nil).isValid)
        XCTAssertTrue(ZeroOneSocialSelectedSet(exercise: "Hold", reps: nil, seconds: 30, load: nil, unit: nil).isValid)
    }

    func testNearbyNeedsReciprocalConsentAndAcceptedFriendship() {
        XCTAssertTrue(nearby())
        XCTAssertFalse(nearby(friends: false))
        XCTAssertFalse(nearby(incoming: nil))
        XCTAssertFalse(nearby(outgoing: nil))
        XCTAssertFalse(nearby(blocked: true))
        XCTAssertFalse(nearby(session: false))
    }

    func testNearbyExpiryIsExclusiveAndStopRevokesEitherDirection() {
        XCTAssertFalse(nearby(incoming: now))
        XCTAssertFalse(nearby(outgoing: now.addingTimeInterval(-1)))
        XCTAssertFalse(nearby(outgoingRevoked: true))
        XCTAssertFalse(nearby(incomingRevoked: true))
    }

    func testNearbySelectionRequiresExplicitDurationAndConsent() {
        XCTAssertNoThrow(try ZeroOneNearbySelection(id: UUID(), recipientID: viewer,
            expiresAt: now.addingTimeInterval(60), sharingConfirmed: true).validate(now: now, maximumDuration: 60))
        for duration in [-1.0, 0, 61] {
            XCTAssertThrowsError(try ZeroOneNearbySelection(id: UUID(), recipientID: viewer,
                expiresAt: now.addingTimeInterval(duration), sharingConfirmed: true).validate(now: now, maximumDuration: 60))
        }
        XCTAssertThrowsError(try ZeroOneNearbySelection(id: UUID(), recipientID: viewer,
            expiresAt: now.addingTimeInterval(60), sharingConfirmed: false).validate(now: now, maximumDuration: 60))
    }

    func testFixRejectsStaleFutureAndNonFiniteCoordinates() {
        XCTAssertNoThrow(try fix(captured: now).validate(now: now, maximumAge: 30))
        XCTAssertThrowsError(try fix(captured: now.addingTimeInterval(-31)).validate(now: now, maximumAge: 30))
        XCTAssertThrowsError(try fix(captured: now.addingTimeInterval(1)).validate(now: now, maximumAge: 30))
        XCTAssertThrowsError(try fix(latitude: .nan, captured: now).validate(now: now, maximumAge: 30))
        XCTAssertThrowsError(try fix(latitude: 91, captured: now).validate(now: now, maximumAge: 30))
    }

    func testDisabledAdapterDeniesGuestPostingBeforeNetwork() async {
        let service = SupabaseZeroOneSocialService(configuration: ZeroOneAccountConfiguration(
            url: URL(string: "https://invalid.example")!, publishableKey: "sb_publishable_fixture",
            googleEnabled: false, appleEnabled: false), readiness: .disabled, nearbyLimits: nil)
        let session = ZeroOneAccountSession(accessToken: "synthetic", refreshToken: "synthetic",
            expiresAt: Date().addingTimeInterval(60), identity: ZeroOneAccountIdentity(
                id: author, authenticationID: UUID(), email: nil))
        do {
            try await service.publish(post(audience: .community, recipients: [], confirmed: true), session: session)
            XCTFail("Disabled service accepted a post")
        } catch {
            XCTAssertEqual(error as? ZeroOneSocialError, .unavailable)
        }
    }

    private func read(audience: ZeroOneSocialAudience, selected: Set<UUID> = [],
                      follows: Bool = false, friends: Bool = false, blocked: Bool = false,
                      deleted: Bool = false, sessionActive: Bool = true) -> Bool {
        ZeroOneSocialPolicy.canReadPost(viewer: viewer, author: author, audience: audience, selected: selected,
            follows: follows, mutualFriends: friends, blockedEitherWay: blocked, deleted: deleted, sessionActive: sessionActive)
    }

    private func post(audience: ZeroOneSocialAudience, recipients: Set<UUID>, confirmed: Bool) -> ZeroOneSocialPostSelection {
        ZeroOneSocialPostSelection(id: UUID(), text: "Training today", sets: [],
            audience: audience, recipients: recipients, publishConfirmed: confirmed)
    }

    private func nearby(friends: Bool = true, blocked: Bool = false, session: Bool = true,
                        outgoing: Date? = Date(timeIntervalSince1970: 1_800_000_060),
                        incoming: Date? = Date(timeIntervalSince1970: 1_800_000_060),
                        outgoingRevoked: Bool = false, incomingRevoked: Bool = false) -> Bool {
        ZeroOneSocialPolicy.canReadNearby(sessionActive: session, mutualFriends: friends,
            blockedEitherWay: blocked, outgoingExpiresAt: outgoing, incomingExpiresAt: incoming,
            outgoingRevoked: outgoingRevoked, incomingRevoked: incomingRevoked, now: now)
    }

    private func fix(latitude: Double = 42, captured: Date) -> ZeroOneNearbyFix {
        ZeroOneNearbyFix(latitude: latitude, longitude: 23, accuracyMetres: 10, capturedAt: captured)
    }
}
