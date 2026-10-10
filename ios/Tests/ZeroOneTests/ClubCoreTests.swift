import XCTest
@testable import ZeroOne

/// Club core v1: projections, error mapping, join rules, Respect, account isolation and posting.
@MainActor
final class ClubCoreTests: XCTestCase {
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let postID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    func testPostgresTimestampsWithMicrosecondsDecode() throws {
        let date = try XCTUnwrap(ClubDate.parse("2026-10-10T12:34:56.123456+00:00"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_791_635_696.123, accuracy: 0.001)
        XCTAssertNotNil(ClubDate.parse("2026-10-10T12:34:56+00:00"))
        XCTAssertNotNil(ClubDate.parse("2026-10-10T12:34:56Z"))
        XCTAssertNil(ClubDate.parse("yesterday"))
    }

    func testHomeProjectionDecodesPostsPeopleAndRespect() throws {
        let home = try ClubDate.decoder().decode(ClubHome.self, from: Data(homeJSON(respected: true, count: 3).utf8))
        XCTAssertEqual(home.feed.count, 1)
        XCTAssertEqual(home.feed[0].author?.memberNo, 42)
        XCTAssertEqual(home.feed[0].sets, [ZeroOneSocialSelectedSet(exercise: "Squat", reps: 5, seconds: nil, load: 80, unit: "kg")])
        XCTAssertTrue(home.feed[0].respected)
        XCTAssertEqual(home.trained.map(\.displayName), ["Maya Lund"])
        XCTAssertEqual(ClubPerson.memberNumber(42), "0042")
        XCTAssertEqual(ClubPostCard.setLine(home.feed[0].sets[0]), "Squat 80 kg × 5")
    }

    func testMeProjectionWithoutMembershipAndWithSettings() throws {
        let none = try ClubDate.decoder().decode(ClubMe.self, from: Data(#"{"member":null,"is_admin":false}"#.utf8))
        XCTAssertNil(none.member)
        let me = try ClubDate.decoder().decode(ClubMe.self, from: Data(meJSON().utf8))
        XCTAssertEqual(me.member?.person.memberNo, 1)
        XCTAssertEqual(me.member?.findable, true)
        XCTAssertEqual(me.member?.followers, 7)
        XCTAssertTrue(me.isAdmin)
    }

    func testServerMessagesMapToClubStates() {
        func map(_ status: Int, _ message: String) -> ClubServiceError {
            SupabaseClubService.error(status: status, body: Data(#"{"message":"\#(message)"}"#.utf8))
        }
        XCTAssertEqual(map(403, "Club unavailable"), .closed)
        XCTAssertEqual(map(403, "Join the Club first"), .notJoined)
        XCTAssertEqual(map(403, "Account suspended"), .suspended)
        XCTAssertEqual(map(409, "Handle taken"), .handleTaken)
        XCTAssertEqual(map(403, "The Club is 16+"), .ageRequired)
        XCTAssertEqual(map(500, "anything"), .unavailable)
        XCTAssertEqual(map(400, "Invalid profile"), .invalid)
    }

    func testJoinNeedsSixteenAndAValidHandleBeforeAnyRequest() async {
        let service = FakeClubService()
        let club = store(service)
        XCTAssertFalse(await club.join(handle: "maya_l", displayName: "Maya", findable: true, showTrained: true, confirmedSixteen: false))
        XCTAssertFalse(await club.join(handle: "M!", displayName: "Maya", findable: true, showTrained: true, confirmedSixteen: true))
        XCTAssertTrue(service.calls.isEmpty, "Nothing is sent before the member confirms 16+ and picks a valid handle")
        XCTAssertEqual(ClubStore.validHandle(" Maya_L "), "maya_l")
        XCTAssertNil(ClubStore.validHandle("ab"))
        XCTAssertTrue(await club.join(handle: "maya_l", displayName: " Maya ", findable: false, showTrained: true, confirmedSixteen: true))
        let join = service.calls.first { $0.action == "join" }
        XCTAssertEqual(join?.payload["age_confirmed"], .bool(true))
        XCTAssertEqual(join?.payload["display_name"], .string("Maya"))
        XCTAssertEqual(join?.payload["discoverability"], .string("private"))
    }

    func testRespectShowsAtOnceAndIsPutBackWhenRefused() async {
        let service = FakeClubService()
        service.replies["read_home"] = homeJSON(respected: false, count: 2)
        let club = store(service)
        await club.refresh()
        XCTAssertEqual(club.phase, .member)
        let post = try! XCTUnwrap(club.home?.feed.first)
        service.failing = ["respect": .notAllowed]
        await club.setRespect(post, on: true)
        XCTAssertEqual(club.home?.feed.first?.respectCount, 2)
        XCTAssertEqual(club.home?.feed.first?.respected, false)
        service.failing = [:]
        await club.setRespect(post, on: true)
        XCTAssertEqual(club.home?.feed.first?.respectCount, 3)
        XCTAssertEqual(club.home?.feed.first?.respected, true)
    }

    func testAnotherAccountNeverSeesThePreviousAccountsClub() async {
        let service = FakeClubService()
        service.replies["read_home"] = homeJSON(respected: false, count: 0)
        let club = store(service)
        await club.refresh()
        XCTAssertNotNil(club.home)
        club.accountChanged(to: bob)
        XCTAssertNil(club.home)
        XCTAssertNil(club.me)
        XCTAssertFalse(club.isAdmin)
        club.accountChanged(to: nil)
        XCTAssertEqual(club.phase, .signedOut)
    }

    func testClosedClubAndNotJoinedAreDistinct() async {
        let service = FakeClubService()
        service.failing = ["read_me": .closed]
        let club = store(service)
        await club.refresh()
        XCTAssertEqual(club.phase, .closed)
        service.failing = [:]
        service.replies["read_me"] = #"{"member":null,"is_admin":false}"#
        await club.refresh()
        XCTAssertEqual(club.phase, .notJoined)
    }

    func testPostingSendsOnlyTheBestSetPerExerciseToFollowers() async throws {
        var session = WorkoutSession(title: "Legs", customWorkoutID: UUID(), exercises: [
            WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Goblet squat", targetLoad: Load(16),
                targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 0, previousPerformance: []))
        ])
        _ = try session.completeCurrentSet(load: Load(16), reps: 12, at: Date(timeIntervalSince1970: 100))
        session.skipRest()
        _ = try session.completeCurrentSet(load: Load(18), reps: 10, at: Date(timeIntervalSince1970: 200))
        let sets = ClubComposeView.sets(for: WorkoutHistoryEntry(session: session))
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.load, 18)
        XCTAssertEqual(sets.first?.reps, 10)
        XCTAssertEqual(sets.first?.unit, "kg")

        let service = FakeClubService()
        let club = store(service)
        let id = UUID()
        XCTAssertTrue(await club.publish(id: id, text: "Legs done", sets: sets))
        let publish = try XCTUnwrap(service.calls.first { $0.action == "publish" })
        XCTAssertEqual(publish.endpoint, .social)
        XCTAssertEqual(publish.payload["audience"], .string("followers"))
        XCTAssertEqual(publish.payload["id"], .string(id.uuidString))
        XCTAssertEqual(publish.payload["confirmed"], .bool(true))
        XCTAssertFalse(await club.publish(id: UUID(), text: "   ", sets: []), "Nothing to post is refused locally")
    }

    func testReportsQueueIsOnlyAskedForByModerators() async {
        let service = FakeClubService()
        service.replies["read_me"] = #"{"member":null,"is_admin":false}"#
        let club = store(service)
        await club.refresh()
        let reports = await club.reports(open: true)
        XCTAssertNil(reports)
        XCTAssertFalse(service.calls.contains { $0.action == "admin_reports" })
    }

    // MARK: Fixtures

    private func store(_ service: FakeClubService) -> ClubStore {
        let session = ZeroOneAccountSession(accessToken: "token", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600), identity: .init(id: alice, authenticationID: alice, email: nil))
        let club = ClubStore(service: service, sessions: { session })
        club.accountChanged(to: alice)
        return club
    }

    private func person(_ id: UUID, _ name: String, number: Int) -> String {
        #"{"account_id":"\#(id.uuidString)","handle":"h\#(number)","display_name":"\#(name)","member_no":\#(number),"joined_at":"2026-10-01T09:00:00.5+00:00","trained_this_week":true,"i_follow":true,"follows_me":false}"#
    }

    private func homeJSON(respected: Bool, count: Int) -> String {
        #"{"feed":[{"id":"\#(postID.uuidString)","author":\#(person(bob, "Maya Lund", number: 42)),"text":"Legs","sets":[{"exercise":"Squat","reps":5,"load":80,"unit":"kg"}],"created_at":"2026-10-10T08:00:00.123456+00:00","respect_count":\#(count),"respected":\#(respected)}],"trained":[\#(person(bob, "Maya Lund", number: 42))]}"#
    }

    private func meJSON() -> String {
        let base = person(alice, "Sammy", number: 1).dropLast()
        return #"{"member":\#(base),"discoverability":"community","show_trained":true,"workouts_count":12,"suspended":false,"followers":7,"following":3},"is_admin":true}"#
    }
}

/// Records every request; replies from a table, or fails per action.
private final class FakeClubService: ClubServicing, @unchecked Sendable {
    struct Call { let endpoint: ClubEndpoint; let action: String; let payload: [String: ClubValue] }
    var calls: [Call] = []
    var replies: [String: String] = [
        "read_me": #"{"member":{"account_id":"00000000-0000-0000-0000-0000000000A1","handle":"sammy","display_name":"Sammy","member_no":1,"joined_at":null,"trained_this_week":false,"i_follow":false,"follows_me":false,"discoverability":"community","show_trained":false,"workouts_count":0,"suspended":false,"followers":0,"following":0},"is_admin":false}"#,
        "read_home": #"{"feed":[],"trained":[]}"#
    ]
    var failing: [String: ClubServiceError] = [:]

    func execute(_ endpoint: ClubEndpoint, _ action: String, payload: [String: ClubValue],
                 session: ZeroOneAccountSession) async throws -> Data {
        calls.append(Call(endpoint: endpoint, action: action, payload: payload))
        if let error = failing[action] { throw error }
        return Data((replies[action] ?? #"{"accepted":true}"#).utf8)
    }
}
