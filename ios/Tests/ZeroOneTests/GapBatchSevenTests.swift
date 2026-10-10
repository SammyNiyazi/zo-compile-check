import XCTest
@testable import ZeroOne

/// Study 36 widgets: the snapshot carries today's workout, the week and the card,
/// and an older snapshot without them still decodes.
final class GapBatchSevenTests: XCTestCase {
    private func snapshot() -> DailyWidgetSnapshot {
        let now = Date.now
        let start = Calendar.autoupdatingCurrent.startOfDay(for: now)
        return DailyWidgetSnapshot(generatedAt: now, dayStart: start, steps: .reading(4_200, at: now),
            eatenKilocalories: .missing(.noData), burnedKilocalories: .missing(.noData),
            waterMilliliters: .reading(750, at: now), waterGoalMilliliters: 2_500)
    }

    func testTrainingAndCardSurviveTheSharedFile() throws {
        var value = snapshot()
        value.training = .init(state: .next, workoutTitle: "Full Body A", exerciseCount: 6, minutes: 48,
            days: (0 ..< 7).map { .init(trained: $0 < 2, planned: $0 % 2 == 0, isToday: $0 == 2) },
            workoutsThisWeek: 2, plannedThisWeek: 4, setsThisWeek: 22, workoutsLastWeek: 3)
        value.memberCard = .init(holderName: "Alex Kim", number: "0127", workouts: 9)
        let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.training, value.training)
        XCTAssertEqual(decoded.memberCard, value.memberCard)
    }

    func testAnOlderSnapshotWithoutThemStillDecodes() throws {
        let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: JSONEncoder().encode(snapshot()))
        XCTAssertNil(decoded.training)
        XCTAssertNil(decoded.memberCard)
        XCTAssertEqual(decoded.waterGoalMilliliters, 2_500)
    }

    /// Proof 48: invite links carry only a server-checked token.
    func testCrewInviteLinksRoundTripAndRejectAnythingElse() {
        let token = "AbCdEfGhIjKlMnOpQrStUv"
        let url = ClubCrewLink.url(token: token)
        XCTAssertEqual(url?.absoluteString, "the01://crew/" + token)
        XCTAssertEqual(url.flatMap(ClubCrewLink.token(from:)), token)
        XCTAssertNil(ClubCrewLink.url(token: "short"))
        XCTAssertNil(ClubCrewLink.token(from: URL(string: "the01://crew/" + token + "?x=1")!))
        XCTAssertNil(ClubCrewLink.token(from: URL(string: "https://example.com/crew/" + token)!))
        XCTAssertNil(ClubCrewLink.token(from: URL(string: "the01://crew/" + token + "%20drop")!))
    }

    func testACrewDecodesFromTheServerShape() throws {
        let json = """
        {"id":"5B1F1B7A-7E2D-4C55-9A8F-1C2D3E4F5A6B","name":"Sofia Lifters","join_policy":"link","monthly_goal":60,
         "is_owner":false,"month_workouts":48,"invite":null,
         "members":[{"account_id":"6B1F1B7A-7E2D-4C55-9A8F-1C2D3E4F5A6B","handle":"maya","display_name":"Maya","member_no":12,
                     "trained_this_week":true}]}
        """
        let crew = try JSONDecoder().decode(ClubCrew.self, from: Data(json.utf8))
        XCTAssertTrue(crew.anyoneWithLink)
        XCTAssertTrue(crew.canInvite, "Anyone in a link crew can invite")
        XCTAssertEqual(crew.trainedThisWeek, 1)
        XCTAssertEqual(crew.monthWorkouts, 48)
    }

    func testTheWorkoutControlOpensItsOwnRoute() {
        XCTAssertEqual(DailyWidgetRoute(url: DailyWidgetRoute.workout.url), .workout)
    }
}
