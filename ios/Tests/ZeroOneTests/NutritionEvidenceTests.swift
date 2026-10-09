import XCTest
@testable import ZeroOne

@MainActor
final class NutritionEvidenceTests: XCTestCase {
    func testCalorieOnlyMealsAndEmptyDayHaveUnknownMacros() {
        let now = Date.now
        let repository = NutritionRepository(store: Store([meal(at: now, protein: nil, carbs: nil, fat: nil)]))
        let summary = repository.macroSummary(on: now)
        XCTAssertEqual(summary?.protein.coverage, .notRecorded)
        XCTAssertNil(summary?.protein.knownSubtotalGrams)
        XCTAssertEqual(summary?.carbohydrates.coverage, .notRecorded)
        XCTAssertNil(summary?.fat.knownSubtotalGrams)
        let empty = NutritionRepository(store: Store([])).macroSummary(on: now)
        XCTAssertEqual(empty?.protein.loggedEntryCount, 0)
        XCTAssertEqual(empty?.protein.coverage, .notRecorded)
        XCTAssertNil(empty?.protein.knownSubtotalGrams)
    }

    func testCoverageIsIndependentForEachMacroAndZeroRemainsRecorded() throws {
        let now = Date.now
        let entries = [meal(at: now, protein: 0, carbs: nil, fat: 10),
                       meal(at: now, protein: 20, carbs: 30, fat: 0)]
        let repository = NutritionRepository(store: Store(entries))
        let summary = try XCTUnwrap(repository.macroSummary(on: now))
        XCTAssertEqual(summary.protein.coverage, .allLoggedEntries)
        XCTAssertEqual(summary.protein.knownSubtotalGrams, 20)
        XCTAssertEqual(summary.carbohydrates.coverage, .partial)
        XCTAssertEqual(summary.carbohydrates.recordedEntryCount, 1)
        XCTAssertEqual(summary.carbohydrates.loggedEntryCount, 2)
        XCTAssertEqual(summary.carbohydrates.knownSubtotalGrams, 30)
        XCTAssertEqual(summary.fat.coverage, .allLoggedEntries)
        XCTAssertEqual(summary.fat.knownSubtotalGrams, 10)
        let zero = NutritionMacroTotal(values: [0])
        XCTAssertEqual(zero.coverage, .allLoggedEntries)
        XCTAssertEqual(zero.knownSubtotalGrams, 0)
    }

    func testAcknowledgedEditsRemovalAndRelaunchUpdateCoverageWithoutFillingMissingFacts() throws {
        let now = Date.now
        let first = meal(at: now, protein: nil, carbs: nil, fat: nil)
        let second = meal(at: now, protein: 20, carbs: nil, fat: nil)
        let store = Store([first, second])
        let repository = NutritionRepository(store: store)
        XCTAssertEqual(repository.macroSummary(on: now)?.protein.coverage, .partial)
        var draft = NutritionEntryDraft(entry: first)
        draft.proteinGrams = "0"
        try repository.update(id: first.id, with: draft)
        XCTAssertEqual(repository.macroSummary(on: now)?.protein.coverage, .allLoggedEntries)
        XCTAssertNil(store.entries.first { $0.id == first.id }?.carbohydrateGrams)
        XCTAssertTrue(repository.remove(id: second.id))
        let restored = NutritionRepository(store: store)
        XCTAssertEqual(restored.macroSummary(on: now)?.protein.knownSubtotalGrams, 0)
        XCTAssertEqual(restored.macroSummary(on: now)?.carbohydrates.coverage, .notRecorded)
    }

    func testOtherDaysUnavailableAndMalformedValuesDoNotEstablishIntake() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_024_000)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let repository = NutritionRepository(store: Store([meal(at: yesterday, protein: 30, carbs: 40, fat: 10)]), calendar: calendar)
        XCTAssertNil(repository.macroSummary(on: now)?.protein.knownSubtotalGrams)
        XCTAssertEqual(repository.macroSummary(on: yesterday)?.protein.knownSubtotalGrams, 30)
        let unavailable = Store([])
        unavailable.isAvailable = false
        XCTAssertNil(NutritionRepository(store: unavailable).macroSummary(on: now))
        XCTAssertEqual(NutritionMacroTotal(values: [.nan]).coverage, .unavailable)
        XCTAssertNil(NutritionMacroTotal(values: [Double.infinity]).knownSubtotalGrams)
        XCTAssertEqual(NutritionMacroTotal(values: [-1, 20]).coverage, .unavailable)
    }

    private func meal(at date: Date, protein: Double?, carbs: Double?, fat: Double?) -> NutritionEntry {
        NutritionEntry(id: UUID(), title: "Recorded meal", calories: 500, proteinGrams: protein,
            carbohydrateGrams: carbs, fatGrams: fat, loggedAt: date)
    }

    private final class Store: NutritionPersisting {
        var entries: [NutritionEntry]
        var isAvailable = true
        init(_ entries: [NutritionEntry]) { self.entries = entries }
        func load() -> [NutritionEntry] { entries }
        func save(_ entries: [NutritionEntry]) { self.entries = entries }
    }
}
