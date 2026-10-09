import XCTest
@testable import ZeroOne

final class DietsPresentationTests: XCTestCase {
    func testWaterGlassesPreservePartialAmountsInsteadOfRoundingToAFullDrink() throws {
        let glasses = try XCTUnwrap(DietsPresentation.waterGlasses(current: 375, goal: 2_500))
        XCTAssertEqual(glasses.count, 10)
        XCTAssertEqual(glasses[0].filledMilliliters, 250)
        XCTAssertEqual(glasses[1].filledMilliliters, 125)
        XCTAssertEqual(glasses[1].fraction, 0.5)
        XCTAssertTrue(glasses.dropFirst(2).allSatisfy { $0.filledMilliliters == 0 })
    }

    func testNonstandardGoalKeepsItsActualLastGlassAndCapsOnlyVisualOverflow() throws {
        let glasses = try XCTUnwrap(DietsPresentation.waterGlasses(current: 825, goal: 900))
        XCTAssertEqual(glasses.map(\.capacityMilliliters), [250, 250, 250, 150])
        XCTAssertEqual(glasses.last?.filledMilliliters, 75)
        let completed = try XCTUnwrap(DietsPresentation.waterGlasses(current: 1_150, goal: 900))
        XCTAssertEqual(completed.reduce(0) { $0 + $1.filledMilliliters }, 900)
        XCTAssertTrue(completed.allSatisfy { $0.fraction == 1 })
    }

    func testInvalidOrUnboundedWaterPresentationDoesNotAllocateOrInventTenGlasses() {
        XCTAssertNil(DietsPresentation.waterGlasses(current: 0, goal: 0))
        XCTAssertNil(DietsPresentation.waterGlasses(current: -1, goal: 2_500))
        XCTAssertNil(DietsPresentation.waterGlasses(current: 0, goal: Int.max))
    }

    func testMealUndoRequiresExactSavedRowIncludingUnknownVersusExplicitZero() {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let saved = NutritionEntry(id: id, title: "Meal", calories: 100, proteinGrams: nil,
            carbohydrateGrams: 0, fatGrams: nil, loggedAt: date)
        XCTAssertTrue(DietsPresentation.canUndoAddition(saved, current: [saved]))
        XCTAssertFalse(DietsPresentation.canUndoAddition(saved, current: []))
        let edited = NutritionEntry(id: id, title: "Meal", calories: 100, proteinGrams: 0,
            carbohydrateGrams: 0, fatGrams: nil, loggedAt: date)
        XCTAssertFalse(DietsPresentation.canUndoAddition(saved, current: [edited]))
        let other = NutritionEntry(id: UUID(), title: saved.title, calories: saved.calories,
            proteinGrams: nil, carbohydrateGrams: 0, fatGrams: nil, loggedAt: date)
        XCTAssertFalse(DietsPresentation.canUndoAddition(saved, current: [other]))
    }
}
