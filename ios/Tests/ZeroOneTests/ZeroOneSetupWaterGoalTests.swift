import XCTest
@testable import ZeroOne

final class ZeroOneSetupWaterGoalTests: XCTestCase {
    func testSuggestionIsThirtyMillilitersPerKilogramRoundedAndClamped() {
        XCTAssertEqual(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: 76.5), 2_250)
        XCTAssertEqual(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: 70), 2_000)
        XCTAssertEqual(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: 40), 1_500)
        XCTAssertEqual(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: 130), 3_000)
        for invalid in [0, 19.9, 401, .nan, .infinity] {
            XCTAssertNil(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: invalid))
        }
    }

    func testSuggestionIsAValidEditableWaterTarget() throws {
        let suggestion = try XCTUnwrap(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms: 82))
        XCTAssertEqual(ZeroOneSetupWaterGoal.milliliters(String(Double(suggestion) / 1_000)), suggestion)
    }
}
