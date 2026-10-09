import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class NutritionAndHydrationTests: XCTestCase {
    func testDailyTotalsAggregateOnlyEntriesFromRequestedDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let store = InMemoryNutritionStore()
        let repository = NutritionRepository(store: store, calendar: calendar)

        try repository.add(
            draft(title: "Lunch", calories: "620", protein: "42", carbohydrates: "70", fat: "18"),
            at: today
        )
        try repository.add(
            draft(title: "Yesterday", calories: "400", protein: "20", carbohydrates: "35", fat: "12"),
            at: yesterday
        )

        XCTAssertEqual(
            repository.totals(on: today),
            NutritionDailyTotals(
                calories: 620,
                proteinGrams: 42,
                carbohydrateGrams: 70,
                fatGrams: 18
            )
        )
    }

    func testNutritionPersistsAcrossRepositoryInstances() throws {
        let store = InMemoryNutritionStore()
        let first = NutritionRepository(store: store)

        let entry = try first.add(
            draft(title: "Breakfast", calories: "430", protein: "31", carbohydrates: "48", fat: "11")
        )
        let restored = NutritionRepository(store: store)

        XCTAssertEqual(restored.entries, [entry])
        XCTAssertEqual(restored.totals().calories, 430)
    }

    func testNutritionEntryCanBeCorrectedAndRemoved() throws {
        let store = InMemoryNutritionStore()
        let repository = NutritionRepository(store: store)
        let entry = try repository.add(
            draft(title: "Snack", calories: "200", protein: "10", carbohydrates: "25", fat: "6")
        )

        var correction = NutritionEntryDraft(entry: entry)
        correction.title = "Protein snack"; correction.calories = "260"
        correction.proteinGrams = "22"; correction.carbohydrateGrams = "24"; correction.fatGrams = "7"
        let corrected = try repository.update(
            id: entry.id,
            with: correction
        )

        XCTAssertEqual(corrected.id, entry.id)
        XCTAssertEqual(repository.totals().calories, 260)
        XCTAssertEqual(repository.totals().proteinGrams, 22)

        repository.remove(id: entry.id)

        XCTAssertTrue(repository.entries.isEmpty)
        XCTAssertEqual(store.savedEntries, [])
    }

    func testInvalidManualEntryDoesNotMutateLocalData() {
        let store = InMemoryNutritionStore()
        let repository = NutritionRepository(store: store)
        let incomplete = NutritionEntryDraft()

        XCTAssertThrowsError(try repository.add(incomplete)) { error in
            XCTAssertEqual(error as? NutritionEntryValidationError, .titleRequired)
        }
        XCTAssertTrue(repository.entries.isEmpty)
        XCTAssertNil(store.savedEntries)
    }

    func testHydrationPersistsAndCanBeSharedByTodayAndDiets() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        let shared = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750, goalMilliliters: 2_500),
            store: store,
            currentDate: { date }
        )

        shared.addWater(milliliters: 250)

        XCTAssertEqual(shared.state.currentMilliliters, 1_000)

        let restored = HydrationViewModel(
            state: HydrationState(currentMilliliters: 0, goalMilliliters: 2_500),
            store: store,
            currentDate: { date }
        )
        XCTAssertEqual(restored.state.currentMilliliters, 1_000)
        XCTAssertEqual(restored.state.goalMilliliters, 2_500)
    }

    func testQuickWaterActionConfirmsSaveAndUndoesOnlyItsOwnChange() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750),
            store: store,
            currentDate: { date }
        )

        guard let receipt = hydration.addWaterFromQuickAction(milliliters: 250) else {
            return XCTFail("Expected a verified quick water save.")
        }
        XCTAssertEqual(hydration.state.currentMilliliters, 1_000)
        XCTAssertEqual(store.state?.currentMilliliters, 1_000)
        XCTAssertTrue(hydration.undoQuickWaterLog(receipt))
        XCTAssertEqual(hydration.state.currentMilliliters, 750)
        XCTAssertEqual(store.state?.currentMilliliters, 750)
        XCTAssertFalse(hydration.undoQuickWaterLog(receipt))
    }

    func testQuickWaterActionNeverClaimsAnUnconfirmedSave() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        store.dropsSaves = true
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750),
            store: store,
            currentDate: { date }
        )

        XCTAssertNil(hydration.addWaterFromQuickAction(milliliters: 250))
        XCTAssertEqual(hydration.state.currentMilliliters, 750)
        XCTAssertNil(store.state)
    }

    func testLegacyWaterGroupUndoRestoresAllTapsAndRejectsStaleSnapshot() throws {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        var undos: [HydrationQuickLogReceipt] = []
        let model = HydrationViewModel(state: HydrationState(currentMilliliters: 500), store: store,
            currentDate: { date }, onConfirmedUndo: { undos.append($0) })
        let first = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        date = date.addingTimeInterval(1)
        let second = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        let group = HydrationQuickLogGroup(first).appending(second)
        store.dropsSaves = true
        XCTAssertFalse(model.undoQuickWaterLog(group))
        XCTAssertTrue(undos.isEmpty)
        XCTAssertEqual(store.state?.currentMilliliters, 1_000)
        store.dropsSaves = false
        XCTAssertTrue(model.undoQuickWaterLog(group))
        XCTAssertEqual(store.state?.currentMilliliters, 500)
        XCTAssertEqual(undos, [first, second])
        XCTAssertFalse(model.undoQuickWaterLog(group))

        date = date.addingTimeInterval(1)
        let third = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        date = date.addingTimeInterval(1)
        let fourth = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        let nextGroup = HydrationQuickLogGroup(third).appending(fourth)
        date = date.addingTimeInterval(1)
        store.save(HydrationStoredState(date: date, currentMilliliters: 1_000,
            goalMilliliters: 2_500, dayStart: fourth.dayStart))
        XCTAssertFalse(model.undoQuickWaterLog(nextGroup), "A later same-total write is not our snapshot.")
        XCTAssertEqual(undos.count, 2)
    }

    func testQuickWaterUndoDoesNotEraseLaterHydrationOrAnotherDay() {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750),
            store: store,
            currentDate: { date }
        )
        guard let receipt = hydration.addWaterFromQuickAction(milliliters: 250) else {
            return XCTFail("Expected a verified quick water save.")
        }
        hydration.addWater(milliliters: 100)
        XCTAssertFalse(hydration.undoQuickWaterLog(receipt))
        XCTAssertEqual(store.state?.currentMilliliters, 1_100)

        date = date.addingTimeInterval(86_400)
        XCTAssertFalse(hydration.undoQuickWaterLog(receipt))
        XCTAssertEqual(store.state?.currentMilliliters, 1_100)
    }

    func testQuickWaterAfterMidnightStartsNewDayWithoutCarryingYesterday() {
        let yesterday = Date(timeIntervalSince1970: 2_000_000_000)
        var today = yesterday
        let store = InMemoryHydrationStore()
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750),
            store: store,
            currentDate: { today }
        )
        hydration.addWater(milliliters: 250)
        today = yesterday.addingTimeInterval(86_400)

        let receipt = hydration.addWaterFromQuickAction(milliliters: 250)

        XCTAssertEqual(receipt?.previousMilliliters, 0)
        XCTAssertEqual(hydration.state.currentMilliliters, 250)
        XCTAssertEqual(store.state?.currentMilliliters, 250)
        XCTAssertEqual(store.state?.date, today)
    }

    func testAllWaterEntryPathsReportOnlyConfirmedAddsAndUndo() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        var additions: [HydrationQuickLogReceipt] = []
        var undos: [HydrationQuickLogReceipt] = []
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 0), store: store,
            currentDate: { date },
            onConfirmedAddition: { additions.append($0) },
            onConfirmedUndo: { undos.append($0) }
        )
        hydration.addWater(milliliters: 500)
        XCTAssertEqual(additions.count, 1)
        XCTAssertEqual(additions.first?.savedMilliliters, 500)
        guard let receipt = hydration.addWaterFromQuickAction(milliliters: 250) else {
            return XCTFail("Expected confirmed save.")
        }
        XCTAssertEqual(additions.count, 2)
        XCTAssertTrue(hydration.undoQuickWaterLog(receipt))
        XCTAssertEqual(undos, [receipt])
        XCTAssertFalse(hydration.undoQuickWaterLog(receipt))
        XCTAssertEqual(undos.count, 1)
        hydration.setWater(milliliters: 400)
        XCTAssertEqual(additions.count, 2, "A total correction is not a logged drink.")
    }

    func testUnconfirmedAndMemoryOnlyWaterNeverTeachShortcutPreferences() {
        let store = InMemoryHydrationStore()
        store.dropsSaves = true
        var additions = 0
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 0), store: store,
            onConfirmedAddition: { _ in additions += 1 }
        )
        hydration.addWater(milliliters: 500)
        XCTAssertNil(hydration.addWaterFromQuickAction(milliliters: 250))
        XCTAssertEqual(additions, 0)
        let memoryOnly = HydrationViewModel(onConfirmedAddition: { _ in additions += 1 })
        memoryOnly.addWater(milliliters: 250)
        XCTAssertEqual(additions, 0)
    }

    func testMealLearningUsesAcknowledgedAdditionsNotEditsOrLoading() throws {
        let store = InMemoryNutritionStore()
        var additions: [NutritionEntry] = []
        var removals: [UUID] = []
        let repository = NutritionRepository(
            store: store,
            onConfirmedAddition: { additions.append($0) },
            onConfirmedRemoval: { removals.append($0) }
        )
        let entry = try repository.add(draft(title: "Lunch", calories: "500", protein: "", carbohydrates: "", fat: ""))
        XCTAssertEqual(additions, [entry])
        var correction = NutritionEntryDraft(entry: entry)
        correction.title = "Lunch corrected"; correction.calories = "550"
        _ = try repository.update(id: entry.id, with: correction)
        XCTAssertEqual(additions.count, 1, "Editing a meal must not count as eating twice.")
        let restored = NutritionRepository(store: store, onConfirmedAddition: { additions.append($0) })
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(additions.count, 1)
        repository.remove(id: entry.id)
        repository.remove(id: entry.id)
        XCTAssertEqual(removals, [entry.id])
    }

    func testUnacknowledgedMealSavesAndRemovalsDoNotChangeLearning() throws {
        let store = InMemoryNutritionStore()
        var additions = 0
        var removals = 0
        let repository = NutritionRepository(
            store: store,
            onConfirmedAddition: { _ in additions += 1 },
            onConfirmedRemoval: { _ in removals += 1 }
        )
        let entry = try repository.add(draft(title: "Lunch", calories: "500", protein: "", carbohydrates: "", fat: ""))
        store.dropsSaves = true
        XCTAssertFalse(repository.remove(id: entry.id))
        XCTAssertEqual(removals, 0)
        XCTAssertNotNil(repository.removalFailureMessage)
        repository.dismissRemovalFailure()
        XCTAssertNil(repository.removalFailureMessage)
        XCTAssertEqual(repository.entries, [entry])
        XCTAssertThrowsError(try repository.add(draft(title: "Snack", calories: "100", protein: "", carbohydrates: "", fat: "")))
        XCTAssertEqual(additions, 1)
        XCTAssertThrowsError(try repository.add(NutritionEntryDraft()))
        XCTAssertEqual(additions, 1)
        store.dropsSaves = false
        _ = try repository.add(draft(title: "Dinner", calories: "600", protein: "", carbohydrates: "", fat: ""))
        XCTAssertEqual(additions, 2)
        XCTAssertEqual(Set(repository.entries.map(\.title)), ["Dinner", "Lunch"])
        XCTAssertEqual(removals, 0, "A failed removal must not ride along in an unrelated save.")
        XCTAssertNil(repository.persistenceErrorMessage)
        XCTAssertTrue(repository.remove(id: entry.id))
        XCTAssertEqual(removals, 1)
    }

    func testFailedMealCorrectionKeepsAcknowledgedValuesForTheNextSave() throws {
        let store = InMemoryNutritionStore()
        let repository = NutritionRepository(store: store)
        let entry = try repository.add(draft(title: "Lunch", calories: "500", protein: "", carbohydrates: "", fat: ""))
        store.dropsSaves = true
        var correction = NutritionEntryDraft(entry: entry)
        correction.title = "Unsaved edit"; correction.calories = "900"
        XCTAssertThrowsError(try repository.update(id: entry.id, with: correction))
        XCTAssertEqual(repository.entries, [entry])
        store.dropsSaves = false
        _ = try repository.add(draft(title: "Dinner", calories: "600", protein: "", carbohydrates: "", fat: ""))
        XCTAssertEqual(store.load().first(where: { $0.id == entry.id }), entry)
    }

    func testOrdinaryWaterLoggingStartsANewDayAndRefreshDoesNotWrite() {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = InMemoryHydrationStore()
        var additions = 0
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 750), store: store,
            currentDate: { date }, onConfirmedAddition: { _ in additions += 1 }
        )
        hydration.addWater(milliliters: 250)
        let yesterday = store.state
        date = date.addingTimeInterval(86_400)
        hydration.refreshForCurrentDay()
        XCTAssertEqual(hydration.state.currentMilliliters, 0)
        XCTAssertEqual(store.state, yesterday, "Refreshing must not erase the prior day's persisted evidence.")
        XCTAssertEqual(additions, 1)
        hydration.addWater(milliliters: 300)
        XCTAssertEqual(hydration.state.currentMilliliters, 300)
        XCTAssertEqual(store.state?.currentMilliliters, 300)
        XCTAssertEqual(additions, 2)
    }

    func testFailedOrdinaryWaterWriteIsNotRolledIntoNextSuccessfulAddition() {
        let store = InMemoryHydrationStore()
        var receipts: [HydrationQuickLogReceipt] = []
        let hydration = HydrationViewModel(
            state: HydrationState(currentMilliliters: 0), store: store,
            onConfirmedAddition: { receipts.append($0) }
        )
        hydration.addWater(milliliters: 250)
        store.dropsSaves = true
        hydration.addWater(milliliters: 500)
        hydration.setWater(milliliters: 2_000)
        XCTAssertEqual(hydration.state.currentMilliliters, 250)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertNotNil(hydration.persistenceErrorMessage)
        store.dropsSaves = false
        hydration.addWater(milliliters: 100)
        XCTAssertEqual(hydration.state.currentMilliliters, 350)
        XCTAssertEqual(receipts.last?.previousMilliliters, 250)
        XCTAssertEqual(receipts.last?.savedMilliliters, 350)
        XCTAssertNil(hydration.persistenceErrorMessage)
    }

    func testHydrationRejectsAStoredTotalFromADifferentDayBoundary() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = InMemoryHydrationStore()
        store.save(HydrationStoredState(
            date: date, currentMilliliters: 1_500, goalMilliliters: 2_500,
            dayStart: utc.startOfDay(for: date).addingTimeInterval(-3600)
        ))
        let hydration = HydrationViewModel(store: store, calendar: utc, currentDate: { date })
        hydration.refreshForCurrentDay()
        XCTAssertEqual(hydration.state.currentMilliliters, 0)
        let receipt = hydration.addWaterFromQuickAction(milliliters: 250)
        XCTAssertEqual(receipt?.previousMilliliters, 0)
        XCTAssertEqual(store.state?.dayStart, utc.startOfDay(for: date))
    }

    func testLegacyHydrationSnapshotWithoutDayBoundaryStillDecodes() throws {
        let data = Data("{\"date\":0,\"currentMilliliters\":500,\"goalMilliliters\":2500}".utf8)
        let stored = try JSONDecoder().decode(HydrationStoredState.self, from: data)
        XCTAssertNil(stored.dayStart)
        XCTAssertEqual(stored.currentMilliliters, 500)
    }

    func testWaterUndoCannotEraseAnEqualTotalAfterTimezoneBoundaryChanges() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let store = InMemoryHydrationStore()
        let original = HydrationViewModel(store: store, calendar: tokyo, currentDate: { date })
        let oldReceipt = try XCTUnwrap(original.addWaterFromQuickAction(milliliters: 250))
        let afterTravel = HydrationViewModel(store: store, calendar: utc, currentDate: { date })
        let newReceipt = try XCTUnwrap(afterTravel.addWaterFromQuickAction(milliliters: 250))

        XCTAssertNotEqual(oldReceipt.dayStart, newReceipt.dayStart)
        XCTAssertFalse(afterTravel.undoQuickWaterLog(oldReceipt))
        XCTAssertEqual(afterTravel.state.currentMilliliters, 250)
        XCTAssertEqual(store.state?.currentMilliliters, 250)
        XCTAssertTrue(afterTravel.undoQuickWaterLog(newReceipt))
        XCTAssertEqual(afterTravel.state.currentMilliliters, 0)
    }

    private func draft(
        title: String,
        calories: String,
        protein: String,
        carbohydrates: String,
        fat: String
    ) -> NutritionEntryDraft {
        var draft = NutritionEntryDraft()
        draft.title = title
        draft.calories = calories
        draft.proteinGrams = protein
        draft.carbohydrateGrams = carbohydrates
        draft.fatGrams = fat
        return draft
    }
}

private final class InMemoryNutritionStore: NutritionPersisting {
    private var initialEntries: [NutritionEntry]
    private(set) var savedEntries: [NutritionEntry]?
    var dropsSaves = false

    init(entries: [NutritionEntry] = []) {
        initialEntries = entries
    }

    func load() -> [NutritionEntry] {
        savedEntries ?? initialEntries
    }

    func save(_ entries: [NutritionEntry]) {
        guard !dropsSaves else { return }
        savedEntries = entries
    }
}

private final class InMemoryHydrationStore: HydrationPersisting {
    private(set) var state: HydrationStoredState?
    var dropsSaves = false

    func load() -> HydrationStoredState? {
        state
    }

    func save(_ state: HydrationStoredState) {
        guard !dropsSaves else { return }
        self.state = state
    }
}
