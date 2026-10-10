import CoreGraphics
import XCTest
@testable import ZeroOne

/// Logging food (proof 54): meal preset, portion scaling into the existing meal
/// record, Open Food Facts parsing, label reading, bundled basic foods, Recent,
/// Same as yesterday and adding with Undo.
@MainActor
final class FoodLogTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testMealIsPresetByTheTimeOfDay() {
        XCTAssertEqual(FoodMeal.preset(for: date(10, 10, 29), calendar: calendar), .breakfast)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 10, 30), calendar: calendar), .lunch)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 14, 59), calendar: calendar), .lunch)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 15, 0), calendar: calendar), .dinner)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 20, 59), calendar: calendar), .dinner)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 21, 0), calendar: calendar), .snack)
        XCTAssertEqual(FoodMeal.preset(for: date(10, 2, 0), calendar: calendar), .breakfast)
    }

    func testAPortionScalesThroughTheExistingMealRecordWithItsSource() throws {
        let skyr = product()
        XCTAssertEqual(skyr.calories(for: 150), 95)
        let entry = try skyr.draft(amount: 150).validatedEntry(loggedAt: date(10, 8))
        XCTAssertEqual(entry.title, "Skyr, natural")
        XCTAssertEqual(entry.calories, 95)
        XCTAssertEqual(try XCTUnwrap(entry.proteinGrams), 16.5, accuracy: 0.0001)
        XCTAssertEqual(entry.foodEvidence?.origin, .databaseReported)
        XCTAssertEqual(entry.foodEvidence?.valueBasis, .per100Grams)
        XCTAssertEqual(entry.foodEvidence?.portion?.amount, 150)
        XCTAssertEqual(entry.foodEvidence?.portion?.unit, .grams)
        XCTAssertEqual(entry.foodEvidence?.source?.name, "Open Food Facts")
        XCTAssertEqual(entry.foodEvidence?.source?.recordID, "5901234123457")
        XCTAssertEqual(entry.foodEvidence?.source?.revision, "1790000000")
    }

    func testOpenFoodFactsProductParsesPortionsBasisAndAttribution() throws {
        let json = #"{"status":1,"product":{"code":"5901234123457","product_name":"Skyr, natural","brands":"Skyr","quantity":"450 g","serving_quantity":"150","product_quantity":450,"nutriments":{"energy-kcal_100g":63,"proteins_100g":11,"carbohydrates_100g":4,"fat_100g":0.2,"salt_100g":0.1},"last_modified_t":1790000000}}"#
        guard case let .found(item) = try OpenFoodFactsClient.parseProductResponse(Data(json.utf8), barcode: "5901234123457") else {
            return XCTFail("Expected a product")
        }
        XCTAssertEqual(item.name, "Skyr, natural")
        XCTAssertEqual(item.detail, "450 g · 5 901234 123457")
        XCTAssertEqual(item.basis, .per100Grams)
        XCTAssertEqual(item.portions.map(\.amount), [150, 450, 100])
        XCTAssertEqual(item.portions[1].label, "whole:450 g")
        XCTAssertEqual(item.values.calories, 63)
        XCTAssertEqual(item.sourceName, "Open Food Facts")
        XCTAssertEqual(item.barcode, "5901234123457")
    }

    func testOpenFoodFactsWithoutEnergyOrStatusIsNotFound() throws {
        let missing = #"{"status":1,"product":{"product_name":"Mystery bar","nutriments":{"proteins_100g":9}}}"#
        XCTAssertEqual(try OpenFoodFactsClient.parseProductResponse(Data(missing.utf8), barcode: "12345670"), .missingCalories(name: "Mystery bar"))
        let absent = #"{"status":0,"status_verbose":"product not found"}"#
        XCTAssertEqual(try OpenFoodFactsClient.parseProductResponse(Data(absent.utf8), barcode: "12345670"), .notFound)
    }

    func testKilojoulesOnlyAndDrinksUseTheRightBasis() throws {
        let json = #"{"status":1,"product":{"product_name":"Orange juice","quantity":"1 l","nutriments":{"energy_100g":188,"carbohydrates_100g":10.4}}}"#
        guard case let .found(item) = try OpenFoodFactsClient.parseProductResponse(Data(json.utf8), barcode: "40000000") else {
            return XCTFail("Expected a product")
        }
        XCTAssertEqual(item.basis, .per100Milliliters)
        XCTAssertEqual(item.values.calories, 188 / 4.184, accuracy: 0.001)
        XCTAssertEqual(item.portions.last?.label, "100 ml")
    }

    func testBarcodeNumbersAreValidated() {
        XCTAssertEqual(OpenFoodFactsClient.normalizedBarcode("5901234123457"), "5901234123457")
        XCTAssertEqual(OpenFoodFactsClient.normalizedBarcode("12345670"), "12345670")
        XCTAssertNil(OpenFoodFactsClient.normalizedBarcode("59012341234ab"))
        XCTAssertNil(OpenFoodFactsClient.normalizedBarcode("123"))
    }

    func testLabelReadingJoinsColumnsAndKeepsSaturatesApartFromFat() {
        func token(_ text: String, x: CGFloat, y: CGFloat, confidence: Float = 0.95) -> NutritionLabelToken {
            NutritionLabelToken(text: text, box: CGRect(x: x, y: y, width: 0.3, height: 0.04), confidence: confidence)
        }
        let tokens = [
            token("Typical values", x: 0.1, y: 0.10), token("per 100 g", x: 0.6, y: 0.10),
            token("Energy", x: 0.1, y: 0.16), token("1810 kJ / 432 kcal", x: 0.6, y: 0.165),
            token("Fat", x: 0.1, y: 0.22), token("18 g", x: 0.6, y: 0.22),
            token("of which saturates", x: 0.1, y: 0.28), token("5,1 g", x: 0.6, y: 0.28),
            token("Carbohydrate", x: 0.1, y: 0.34), token("38 g", x: 0.6, y: 0.34),
            token("of which sugars", x: 0.1, y: 0.40), token("22 g", x: 0.6, y: 0.40),
            token("Fibre", x: 0.1, y: 0.46), token("6.2 g", x: 0.6, y: 0.46, confidence: 0.3),
            token("Protein", x: 0.1, y: 0.52), token("27 g", x: 0.6, y: 0.52),
            token("Salt", x: 0.1, y: 0.58), token("420 mg", x: 0.6, y: 0.58),
            token("1 bar (45 g)", x: 0.1, y: 0.64)
        ]
        let reading = NutritionLabelParser.parse(tokens)
        XCTAssertEqual(reading.foundCount, 8)
        XCTAssertEqual(reading.values[.energy], 432)
        XCTAssertEqual(reading.values[.fat], 18)
        XCTAssertEqual(reading.values[.saturates], 5.1)
        XCTAssertEqual(reading.values[.carbohydrate], 38)
        XCTAssertEqual(reading.values[.sugars], 22)
        XCTAssertEqual(reading.values[.fibre], 6.2)
        XCTAssertEqual(reading.values[.protein], 27)
        XCTAssertEqual(try XCTUnwrap(reading.values[.salt]), 0.42, accuracy: 0.0001)
        XCTAssertEqual(reading.lowConfidence, [.fibre])
        XCTAssertEqual(reading.portionAmount, 45)
        XCTAssertFalse(reading.isPer100Milliliters)
    }

    func testBulgarianLabelAndKilojouleOnlyEnergy() {
        let reading = NutritionLabelParser.parse(lines: [
            ("Енергийна стойност 1000 kJ", 0.9), ("Мазнини 3,5 g", 0.9), ("Белтъци 8 g", 0.9), ("Сол 0,9 g", 0.9)
        ])
        XCTAssertEqual(reading.values[.energy], 239)
        XCTAssertEqual(reading.values[.fat], 3.5)
        XCTAssertEqual(reading.values[.protein], 8)
        XCTAssertEqual(reading.values[.salt], 0.9)
    }

    func testCheckedLabelBecomesAMyFoodCopiedFromALabel() throws {
        var draft = FoodLabelDraft(reading: NutritionLabelParser.parse(lines: [("Energy 432 kcal", 0.9), ("Protein 27 g", 0.2)]), barcode: "5901234123457")
        XCTAssertEqual(draft.needsCheck, [.protein])
        XCTAssertEqual(draft.problems(), [.nameRequired])
        draft.name = "Protein bar, peanut"
        draft.portionLabel = "1 bar"
        draft.portionAmount = "45"
        draft.set(.protein, "27")
        XCTAssertTrue(draft.needsCheck.isEmpty)
        XCTAssertEqual(draft.previewCalories, 194)
        let item = try XCTUnwrap(draft.item(id: "mine:test"))
        XCTAssertEqual(item.kind, .mine)
        XCTAssertEqual(item.origin, .labelReported)
        XCTAssertEqual(item.portions.first?.label, "1 bar, 45 g")
        XCTAssertEqual(item.calories(for: 45), 194)
        XCTAssertEqual(item.barcode, "5901234123457")
        let entry = try item.draft(amount: 45).validatedEntry()
        XCTAssertEqual(entry.foodEvidence?.origin, .labelReported)
        XCTAssertNil(entry.foodEvidence?.source)
    }

    func testBundledBasicFoodsSearchOfflineAndRankRawFirst() throws {
        let foods = BasicFoodsCatalog.shared.foods
        XCTAssertGreaterThan(foods.count, 5_000, "USDA basic foods must be bundled in the app")
        let banana = try XCTUnwrap(BasicFoodsCatalog.shared.search("banana").first)
        XCTAssertEqual(banana.name, "Bananas, raw")
        XCTAssertEqual(banana.portions.first?.label, "1 medium, 118 g")
        XCTAssertEqual(banana.calories(for: 118), 105)
        XCTAssertEqual(banana.sourceName, "USDA FoodData Central")
        XCTAssertEqual(banana.recordID, "173944")
        XCTAssertTrue(BasicFoodsCatalog.shared.search("").isEmpty)
    }

    func testRecentIsDistinctNewestFirstAndRepeatsThePortion() throws {
        let skyr = try product().draft(amount: 150).validatedEntry(loggedAt: date(9, 8))
        let skyrAgain = try product().draft(amount: 200).validatedEntry(loggedAt: date(10, 8))
        var manual = NutritionEntryDraft()
        manual.title = "Chicken rice bowl"
        manual.calories = "640"
        let bowl = try manual.validatedEntry(loggedAt: date(10, 12, 40))
        let recents = FoodRecents.items(from: [skyr, skyrAgain, bowl])
        XCTAssertEqual(recents.map(\.name), ["Chicken rice bowl", "Skyr, natural"])
        XCTAssertEqual(recents[1].defaultAmount, 200)
        XCTAssertEqual(recents[1].calories(for: 200), skyrAgain.calories)
        XCTAssertEqual(recents[0].basis, .consumedPortion)
        XCTAssertEqual(recents[0].calories(for: recents[0].defaultAmount), 640)
    }

    func testAddingLabelsTheMealAndSameAsYesterdayAndUndo() throws {
        let suite = "FoodLogTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let nutrition = NutritionRepository(store: UserDefaultsNutritionStore(defaults: defaults, key: "meals"), calendar: calendar)
        var clock = date(9, 8)
        let model = FoodLogModel(nutrition: nutrition, store: FoodLogStore(defaults: defaults),
            catalog: BasicFoodsCatalog(items: []), now: { clock }, calendar: calendar)
        XCTAssertEqual(model.meal, .breakfast)
        let first = try model.add(product(), amount: 150)
        model.meal = .snack
        let snack = try model.add(product(), amount: 100)
        XCTAssertEqual(model.labels.meal(for: first, calendar: calendar), .breakfast)
        XCTAssertEqual(model.labels.meal(for: snack, calendar: calendar), .snack)

        clock = date(10, 7, 30)
        model.meal = .breakfast
        XCTAssertEqual(model.yesterday.map(\.id), [first.id])
        let added = try model.addYesterday()
        XCTAssertEqual(added.map(\.calories), [95])
        XCTAssertEqual(nutrition.entries(on: clock).count, 1)
        XCTAssertTrue(model.undo(added))
        XCTAssertTrue(nutrition.entries(on: clock).isEmpty)

        let groups = FoodMealGroup.groups(nutrition.entries(on: date(9, 12)), labels: model.labels, calendar: calendar)
        XCTAssertEqual(Set(groups.map(\.meal)), [.breakfast, .snack])
    }

    // MARK: Fixtures

    private func product() -> FoodItem {
        FoodItem(id: "off:5901234123457", kind: .product, name: "Skyr, natural", detail: "450 g",
            basis: .per100Grams, values: FoodNutrients(calories: 63, protein: 11, carbohydrate: 4, fat: 0.2),
            portions: [FoodPortionOption(label: "150 g", amount: 150), FoodPortionOption(label: "100 g", amount: 100)],
            origin: .databaseReported, sourceName: "Open Food Facts", recordID: "5901234123457",
            revision: "1790000000", barcode: "5901234123457")
    }
}
