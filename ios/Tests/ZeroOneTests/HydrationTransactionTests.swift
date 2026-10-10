import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class HydrationTransactionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var start: Date { calendar.startOfDay(for: now) }
    private func initial(_ amount: Int = 500) -> HydrationTransactionState {
        .init(state: .init(date: now, currentMilliliters: amount, goalMilliliters: 2_500, dayStart: start))
    }

    func testGoalEditPreservesWidgetDrinkAndUndoReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-goal-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = SharedHydrationStore(directory: directory)
        try app.migrate(from: TransactionMemoryStore(initial()), at: now)
        let widget = SharedHydrationStore(directory: directory)
        let drink = try widget.add(250, at: now, calendar: calendar)
        let updated = try app.setGoal(3_000, replacing: 2_500)
        XCTAssertEqual(updated.state.currentMilliliters, 750)
        XCTAssertEqual(updated.revision, drink.revision)
        XCTAssertEqual(updated.lastAddition, drink.lastAddition)
        XCTAssertEqual(updated.state.date, drink.state.date)
        let undone = try widget.undo(try XCTUnwrap(drink.lastAddition).id, at: now, calendar: calendar)
        XCTAssertEqual(undone.state.currentMilliliters, 500)
        XCTAssertEqual(undone.state.goalMilliliters, 3_000)
        XCTAssertTrue(undone.isValid)
    }

    func testStaleGoalEditCannotOverwriteNewGoalOrDrink() throws {
        let drink = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let changed = try drink.changingGoal(3_000, replacing: 2_500)
        XCTAssertThrowsError(try changed.changingGoal(2_000, replacing: 2_500))
        XCTAssertThrowsError(try changed.changingGoal(0, replacing: 3_000))
        XCTAssertEqual(changed.state.currentMilliliters, 750)
        XCTAssertEqual(changed.lastAddition, drink.lastAddition)
    }

    func testSavedGoalSurvivesNextDayAndGoalEditDoesNotCreateTodaysDrink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-goal-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedHydrationStore(directory: directory)
        try store.migrate(from: TransactionMemoryStore(initial()), at: now)
        _ = try store.setGoal(3_000, replacing: 2_500)
        let tomorrow = now.addingTimeInterval(86_400)
        let model = HydrationViewModel(store: store, calendar: calendar, currentDate: { tomorrow })
        XCTAssertEqual(model.state.goalMilliliters, 3_000)
        XCTAssertEqual(model.state.currentMilliliters, 0)
        XCTAssertTrue(model.setWaterGoal(milliliters: 3_500, replacing: 3_000))
        XCTAssertEqual(model.state.currentMilliliters, 0)
        XCTAssertEqual(model.state.goalMilliliters, 3_500)
        XCTAssertEqual(try store.readTransaction().state.date, now)
        XCTAssertEqual(try store.readTransaction().state.currentMilliliters, 500)
    }

    func testWaterGoalInputRequiresWholePositiveMilliliters() {
        XCTAssertEqual(ZeroOneSetupWaterGoal.milliliters("2.5"), 2_500)
        XCTAssertEqual(ZeroOneSetupWaterGoal.milliliters("2,345"), 2_345)
        for text in ["", "0", "-1", "2 liters", "2.0001", "999999999999999999999999"] {
            XCTAssertNil(ZeroOneSetupWaterGoal.milliliters(text), text)
        }
    }

    func testDistinctAppAddsAccumulateAndUndoOnlyLatest() throws {
        let first = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let second = try first.adding(500, expectedRevision: nil, at: now, calendar: calendar)
        XCTAssertEqual(second.state.currentMilliliters, 1_250)
        XCTAssertThrowsError(try second.undoing(try XCTUnwrap(first.lastAddition).id, at: now, calendar: calendar))
        let restored = try second.undoing(try XCTUnwrap(second.lastAddition).id, at: now, calendar: calendar)
        XCTAssertEqual(restored.state.currentMilliliters, 750)
        XCTAssertEqual(try restored.undoing(try XCTUnwrap(second.lastAddition).id, at: now, calendar: calendar), restored)
    }

    func testGroupUndoRestoresTheBaselineInOneTransaction() throws {
        let first = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let second = try first.adding(250, expectedRevision: nil, at: now.addingTimeInterval(1), calendar: calendar)
        let third = try second.adding(250, expectedRevision: nil, at: now.addingTimeInterval(2), calendar: calendar)
        let additions = try [first, second, third].map { try XCTUnwrap($0.lastAddition) }
        let restored = try third.undoingGroup(additions, at: now.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(restored.state.currentMilliliters, 500)
        XCTAssertEqual(restored.state.goalMilliliters, 2_500)
        XCTAssertTrue(restored.isValid)
        XCTAssertThrowsError(try restored.undoingGroup(additions, at: now.addingTimeInterval(31), calendar: calendar))
        XCTAssertEqual(try JSONDecoder().decode(HydrationTransactionState.self, from: JSONEncoder().encode(third)), third)
    }

    func testGroupUndoRejectsInterveningWidgetWritesOrSingleUndo() throws {
        let first = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let second = try first.adding(250, expectedRevision: nil, at: now.addingTimeInterval(1), calendar: calendar)
        let additions = try [first, second].map { try XCTUnwrap($0.lastAddition) }
        let widgetUndo = try second.undoing(additions[1].id, at: now.addingTimeInterval(2), calendar: calendar)
        XCTAssertThrowsError(try widgetUndo.undoingGroup(additions, at: now.addingTimeInterval(3), calendar: calendar))
        XCTAssertEqual(widgetUndo.state.currentMilliliters, 750)
        let replaced = try second.replacing(1_000, expectedRevision: second.revision, at: now.addingTimeInterval(2), calendar: calendar)
        XCTAssertThrowsError(try replaced.undoingGroup(additions, at: now.addingTimeInterval(3), calendar: calendar))

        let widgetAdd = try first.adding(100, expectedRevision: nil, at: now.addingTimeInterval(1), calendar: calendar)
        let appAdd = try widgetAdd.adding(250, expectedRevision: nil, at: now.addingTimeInterval(2), calendar: calendar)
        let interrupted = try [first, appAdd].map { try XCTUnwrap($0.lastAddition) }
        XCTAssertThrowsError(try appAdd.undoingGroup(interrupted, at: now.addingTimeInterval(3), calendar: calendar))
        XCTAssertEqual(appAdd.state.currentMilliliters, 1_100)
    }

    func testGroupUndoRejectsExpiredMalformedAndPausedChains() throws {
        let first = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let second = try first.adding(250, expectedRevision: nil, at: now.addingTimeInterval(6), calendar: calendar)
        let additions = try [first, second].map { try XCTUnwrap($0.lastAddition) }
        XCTAssertThrowsError(try second.undoingGroup(additions, at: now.addingTimeInterval(7), calendar: calendar))
        XCTAssertThrowsError(try first.undoingGroup([], at: now, calendar: calendar))
        XCTAssertThrowsError(try first.undoingGroup([additions[0], additions[0]], at: now, calendar: calendar))
        XCTAssertThrowsError(try first.undoingGroup([additions[0]], at: now.addingTimeInterval(-1), calendar: calendar))
        XCTAssertThrowsError(try first.undoingGroup([additions[0]], at: now.addingTimeInterval(86_400), calendar: calendar))
    }

    func testQuickGroupBreaksAfterPauseInterveningWriteAndDayChange() throws {
        var date = now
        let store = TransactionMemoryStore(initial())
        let model = HydrationViewModel(store: store, calendar: calendar, currentDate: { date })
        let first = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        date = date.addingTimeInterval(1)
        let second = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        let group = HydrationQuickLogGroup(first).appending(second)
        XCTAssertEqual(group.addedMilliliters, 500)
        date = date.addingTimeInterval(6)
        let third = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        XCTAssertEqual(group.appending(third).receipts, [third])
        store.value = try store.value.replacing(store.value.state.currentMilliliters,
            expectedRevision: store.value.revision, at: date, calendar: calendar)
        let fourth = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        XCTAssertEqual(HydrationQuickLogGroup(third).appending(fourth).receipts, [fourth])
        date = calendar.startOfDay(for: date).addingTimeInterval(86_400)
        let fifth = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        XCTAssertEqual(group.appending(fifth).receipts, [fifth])
        XCTAssertEqual(HydrationQuickLogGroup(second).appending(first).receipts, [first])
    }

    func testGroupUndoReportsEachOriginalReceiptOnlyAfterConfirmedWrite() throws {
        var date = now
        let store = TransactionMemoryStore(initial())
        let suite = "01-water-group-learning-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MainActionStore(defaults: defaults)
        var undos: [HydrationQuickLogReceipt] = []
        let model = HydrationViewModel(store: store, calendar: calendar, currentDate: { date },
            onConfirmedAddition: { preferences.recordConfirmedWaterUse($0) },
            onConfirmedUndo: { undos.append($0); preferences.undoConfirmedWaterUse($0) })
        let first = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        date = date.addingTimeInterval(1)
        let second = try XCTUnwrap(model.addWaterFromQuickAction(milliliters: 250))
        let group = HydrationQuickLogGroup(first).appending(second)
        XCTAssertEqual(preferences.count(for: .water, at: date), 2)
        store.rejectsGroupUndo = true
        XCTAssertFalse(model.undoQuickWaterLog(group))
        XCTAssertEqual(store.value.state.currentMilliliters, 1_000)
        XCTAssertTrue(undos.isEmpty)
        XCTAssertEqual(preferences.count(for: .water, at: date), 2)
        store.rejectsGroupUndo = false
        XCTAssertTrue(model.undoQuickWaterLog(group))
        XCTAssertEqual(undos, [first, second])
        XCTAssertEqual(preferences.count(for: .water, at: date), 0)
        XCTAssertEqual(model.state.currentMilliliters, 500)
        XCTAssertEqual(store.groupUndoCount, 1)
        XCTAssertEqual(store.blindSaveCount, 0)
        XCTAssertFalse(model.undoQuickWaterLog(group))
        XCTAssertEqual(undos.count, 2)
    }

    func testCoordinatedGroupUndoIsVisibleToIndependentStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-water-group-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedHydrationStore(directory: directory)
        try store.migrate(from: TransactionMemoryStore(initial()), at: now)
        let first = try store.add(250, at: now, calendar: calendar)
        let second = try store.add(250, at: now.addingTimeInterval(1), calendar: calendar)
        let additions = try [first, second].map { try XCTUnwrap($0.lastAddition) }
        _ = try SharedHydrationStore(directory: directory).undoGroup(additions, at: now.addingTimeInterval(2), calendar: calendar)
        XCTAssertEqual(try store.readTransaction().state.currentMilliliters, 500)
    }

    func testWidgetRedeliveryIsIdempotentButAnotherDrinkIsNotTheSameRequest() throws {
        let base = initial(), request = UUID()
        let first = try base.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar)
        XCTAssertEqual(try first.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar), first)
        XCTAssertThrowsError(try first.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: UUID(), at: now, calendar: calendar))
        let appAdd = try base.adding(250, expectedRevision: nil, at: now, calendar: calendar)
        XCTAssertThrowsError(try appAdd.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar))
        let afterRefresh = try appAdd.adding(250, expectedRevision: appAdd.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar)
        XCTAssertEqual(afterRefresh.state.currentMilliliters, 1_000)
    }

    func testReplayAfterUndoCannotReAddTheDrink() throws {
        let base = initial(), request = UUID()
        let added = try base.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar)
        let undone = try added.undoing(try XCTUnwrap(added.lastAddition).id, at: now, calendar: calendar)
        XCTAssertThrowsError(try undone.adding(250, expectedRevision: base.revision, expectedDayStart: start, requestID: request, at: now, calendar: calendar))
        XCTAssertEqual(undone.state.currentMilliliters, 500)
    }

    func testCorrectionInvalidatesUndoEvenWhenTotalReturnsToSameNumber() throws {
        let added = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let corrected = try added.replacing(750, expectedRevision: added.revision, at: now, calendar: calendar)
        XCTAssertThrowsError(try corrected.undoing(try XCTUnwrap(added.lastAddition).id, at: now, calendar: calendar))
        XCTAssertNil(corrected.lastAddition)
    }

    func testRolloverRejectsOldWidgetButAllowsFreshWidgetOnNewDay() throws {
        let base = initial(), tomorrow = now.addingTimeInterval(86_400)
        XCTAssertThrowsError(try base.adding(250, expectedRevision: base.revision, expectedDayStart: start, at: tomorrow, calendar: calendar))
        let fresh = try base.adding(250, expectedRevision: base.revision, expectedDayStart: calendar.startOfDay(for: tomorrow), at: tomorrow, calendar: calendar)
        XCTAssertEqual(fresh.state.currentMilliliters, 250)
        XCTAssertEqual(fresh.state.goalMilliliters, 2_500)
        XCTAssertThrowsError(try fresh.undoing(try XCTUnwrap(fresh.lastAddition).id, at: tomorrow.addingTimeInterval(86_400), calendar: calendar))
    }

    func testTimezoneChangeAndClockRollbackRejectStaleActions() throws {
        let base = initial()
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertThrowsError(try base.adding(250, expectedRevision: base.revision, expectedDayStart: start, at: now, calendar: tokyo))
        XCTAssertThrowsError(try base.adding(250, expectedRevision: nil, at: now.addingTimeInterval(-1), calendar: calendar))
        XCTAssertThrowsError(try base.replacing(10, expectedRevision: base.revision, at: now.addingTimeInterval(-1), calendar: calendar))
    }

    func testInvalidAmountsAndOverflowDoNotProduceState() throws {
        XCTAssertThrowsError(try initial().adding(0, expectedRevision: nil, at: now, calendar: calendar))
        XCTAssertThrowsError(try initial().adding(-250, expectedRevision: nil, at: now, calendar: calendar))
        XCTAssertThrowsError(try initial(Int.max).adding(1, expectedRevision: nil, at: now, calendar: calendar))
        let valid = initial()
        XCTAssertThrowsError(try valid.replacing(-1, expectedRevision: valid.revision, at: now, calendar: calendar))
        let corrupt = HydrationTransactionState(state: .init(date: now, currentMilliliters: -1, goalMilliliters: 0))
        XCTAssertFalse(corrupt.isValid)
    }

    func testViewModelStaleCorrectionCannotOverwriteWidgetAddition() throws {
        let store = TransactionMemoryStore(initial())
        let viewModel = HydrationViewModel(store: store, calendar: calendar, currentDate: { self.now })
        store.value = try store.value.adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let executor = LocalAssistantActionExecutor(hydrationViewModel: viewModel, dailyContext: DailyAssistantContextStore())
        XCTAssertEqual(executor.execute(.setHydration(milliliters: 400, date: now)).kind, .error)
        XCTAssertEqual(store.value.state.currentMilliliters, 750)
        XCTAssertEqual(viewModel.state.currentMilliliters, 750)
        XCTAssertNotNil(viewModel.persistenceErrorMessage)
        viewModel.setWater(milliliters: 400)
        XCTAssertEqual(store.value.state.currentMilliliters, 400, "A new action after reconciliation may correct the now-observed total.")
        XCTAssertEqual(store.blindSaveCount, 0)
    }

    func testViewModelUsesTransactionReceiptsAndKeepsNewerEntryOnUndo() throws {
        let store = TransactionMemoryStore(initial())
        var saves = 0
        let viewModel = HydrationViewModel(store: store, calendar: calendar, currentDate: { self.now }, onConfirmedAddition: { _ in saves += 1 })
        let receipt = try XCTUnwrap(viewModel.addWaterFromQuickAction(milliliters: 250))
        XCTAssertNotNil(receipt.transactionID)
        XCTAssertEqual(saves, 1)
        store.value = try store.value.adding(500, expectedRevision: nil, at: now, calendar: calendar)
        XCTAssertFalse(viewModel.undoQuickWaterLog(receipt))
        XCTAssertEqual(store.value.state.currentMilliliters, 1_250)
        XCTAssertEqual(store.blindSaveCount, 0)
    }

    func testWidgetReadsCanonicalWaterInsteadOfStaleCacheAndExpiresUndo() throws {
        let added = try initial().adding(250, expectedRevision: nil, at: now, calendar: calendar)
        let water = try XCTUnwrap(DailyWidgetWaterState(transaction: added, at: now, calendar: calendar))
        let display = water.displaySnapshot(base: nil, at: now, calendar: calendar)
        XCTAssertEqual(display.waterMilliliters.value, 750)
        XCTAssertEqual(display.steps.state, .needsRefresh)
        XCTAssertTrue(display.isValid)
        let unavailable = DailyWidgetWaterState.unavailableSnapshot(base: display, at: now, calendar: calendar)
        XCTAssertNil(unavailable.waterMilliliters.value, "Do not resurrect cached water when its canonical store is unreadable.")
        XCTAssertEqual(unavailable.waterMilliliters.state, .unavailable)
        XCTAssertNotNil(water.undo)
        XCTAssertNil(DailyWidgetWaterState(transaction: added, at: now.addingTimeInterval(900), calendar: calendar)?.undo)
        let tomorrow = now.addingTimeInterval(86_400)
        let next = try XCTUnwrap(DailyWidgetWaterState(transaction: added, at: tomorrow, calendar: calendar))
        XCTAssertEqual(next.displaySnapshot(base: nil, at: tomorrow, calendar: calendar).waterMilliliters.value, 0)
        XCTAssertNil(next.undo)
    }

    func testSharedStoreMigrationPreservesLegacyAndDoesNotReimportOverNewerState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-water-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = TransactionMemoryStore(initial())
        let appStore = SharedHydrationStore(directory: directory)
        try appStore.migrate(from: legacy, at: now)
        let widgetStore = SharedHydrationStore(directory: directory)
        let added = try widgetStore.add(250, at: now, calendar: calendar)
        try appStore.migrate(from: legacy, at: now)
        XCTAssertEqual(try appStore.readTransaction(), added)
        XCTAssertEqual(legacy.value.state.currentMilliliters, 500)
        XCTAssertEqual(legacy.blindSaveCount, 0)
        let final = try appStore.add(500, at: now, calendar: calendar)
        XCTAssertEqual(try widgetStore.readTransaction().state.currentMilliliters, 1_250)
        XCTAssertEqual(try JSONDecoder().decode(HydrationTransactionState.self, from: JSONEncoder().encode(final)), final)
    }

    func testCorruptCanonicalFileIsPreservedNotReimported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-water-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("water-v1.json"), original = Data("broken".utf8)
        try original.write(to: url)
        let store = SharedHydrationStore(directory: directory)
        XCTAssertThrowsError(try store.migrate(from: TransactionMemoryStore(initial()), at: now))
        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.add(250, at: now, calendar: calendar))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(SharedHydrationStore(directory: nil).isAvailable)
    }

    func testIndependentCoordinatorsSerializeConcurrentAdds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("01-water-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedHydrationStore(directory: directory)
        try store.migrate(from: TransactionMemoryStore(initial()), at: now)
        let date = now, testCalendar = calendar, failures = HydrationTestFailures()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                _ = try SharedHydrationStore(directory: directory).add(250, at: date, calendar: testCalendar)
            } catch { failures.record(error) }
        }
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(try store.readTransaction().state.currentMilliliters, 3_500)
    }
}

private final class HydrationTestFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors }
    func record(_ error: Error) { lock.lock(); errors += 1; lock.unlock() }
}

private final class TransactionMemoryStore: HydrationTransactionalPersisting {
    var value: HydrationTransactionState
    var blindSaveCount = 0
    var rejectsGroupUndo = false
    var groupUndoCount = 0
    init(_ value: HydrationTransactionState) { self.value = value }
    func load() -> HydrationStoredState? { value.state }
    func save(_ state: HydrationStoredState) { blindSaveCount += 1 }
    func readTransaction() throws -> HydrationTransactionState { value }
    func add(_ amount: Int, expectedRevision: UUID?, expectedDayStart: Date?, requestID: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        value = try value.adding(amount, expectedRevision: expectedRevision, expectedDayStart: expectedDayStart, requestID: requestID, at: date, calendar: calendar)
        return value
    }
    func replace(_ amount: Int, expectedRevision: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        value = try value.replacing(amount, expectedRevision: expectedRevision, at: date, calendar: calendar)
        return value
    }
    func undo(_ id: UUID, at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        value = try value.undoing(id, at: date, calendar: calendar)
        return value
    }
    func undoGroup(_ additions: [HydrationAddition], at date: Date, calendar: Calendar) throws -> HydrationTransactionState {
        if rejectsGroupUndo { throw HydrationTransactionError.verificationFailed }
        value = try value.undoingGroup(additions, at: date, calendar: calendar)
        groupUndoCount += 1
        return value
    }
}
