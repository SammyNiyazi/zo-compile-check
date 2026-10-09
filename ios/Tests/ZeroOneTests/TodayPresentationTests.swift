import XCTest
@testable import ZeroOne

final class TodayPresentationTests: XCTestCase {
    func testMissingOrInvalidGoalDoesNotBecomeZeroOrAPrototypeGoal() {
        XCTAssertNil(TodayGoalPresentation.progress(value: 7_842, goal: nil))
        XCTAssertNil(TodayGoalPresentation.progress(value: 7_842, goal: 0))
        XCTAssertNil(TodayGoalPresentation.progress(value: 7_842, goal: -1))
        XCTAssertNil(TodayGoalPresentation.progress(value: -1, goal: 8_000))
    }

    func testKnownZeroAndGoalCompletionStayDifferent() {
        XCTAssertEqual(TodayGoalPresentation.progress(value: 0, goal: 8_000), 0)
        XCTAssertEqual(TodayGoalPresentation.progress(value: 8_000, goal: 8_000), 1)
        XCTAssertEqual(TodayGoalPresentation.progress(value: 9_000, goal: 8_000), 1)
        XCTAssertEqual(TodayGoalPresentation.progress(value: 4_000, goal: 8_000), 0.5)
    }
}
