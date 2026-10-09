import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class DailyGoalsTests: XCTestCase {
    func testBlankTargetsStayAbsentAndLocalizedWholeDigitsParse() throws {
        XCTAssertEqual(try DailyGoalsDraft(value: .empty).validated(), .empty)
        var draft = DailyGoalsDraft(value: .empty)
        draft.steps = " ١٠٠٠٠ "
        draft.foodKilocalories = "２０００"
        XCTAssertEqual(try draft.validated(), DailyGoals(steps: 10_000, foodKilocalories: 2_000))
        draft.foodKilocalories = "  "
        XCTAssertNil(try draft.validated().foodKilocalories)
    }

    func testInvalidPartialFractionalAndOverflowTargetsAreRejected() {
        for text in ["0", "-1", "2.5", "1,000", "1e3", "12foo", "²", String(Int.max) + "0"] {
            var draft = DailyGoalsDraft(value: .empty)
            draft.steps = text
            XCTAssertThrowsError(try draft.validated(), text)
        }
        XCTAssertFalse(DailyGoals(steps: 0, foodKilocalories: nil).isValid)
        XCTAssertFalse(DailyGoals(steps: nil, foodKilocalories: -1).isValid)
    }

    func testOnlyAcknowledgedWritesPublishAndClearingIsPersistent() {
        let store = DailyGoalsMemoryStore()
        let repository = DailyGoalsRepository(store: store)
        let desired = DailyGoals(steps: 8_000, foodKilocalories: 2_000)
        store.discardWrites = true
        XCTAssertFalse(repository.save(desired, replacing: .empty))
        XCTAssertEqual(repository.value, .empty)
        XCTAssertNotNil(repository.errorMessage)
        store.discardWrites = false
        XCTAssertTrue(repository.save(desired, replacing: .empty))
        XCTAssertEqual(DailyGoalsRepository(store: store).value, desired)
        XCTAssertTrue(repository.save(.empty, replacing: desired))
        XCTAssertEqual(DailyGoalsRepository(store: store).value, .empty)
    }

    func testConflictingEditRequiresReloadWithoutOverwritingOtherValues() {
        let store = DailyGoalsMemoryStore()
        let repository = DailyGoalsRepository(store: store)
        let other = DailyGoals(steps: 9_000, foodKilocalories: nil)
        store.value = other
        XCTAssertFalse(repository.save(DailyGoals(steps: 6_000, foodKilocalories: nil), replacing: .empty))
        XCTAssertEqual(store.value, other)
        XCTAssertEqual(repository.value, other)
        XCTAssertEqual(store.writes, 0)
        repository.reload()
        XCTAssertEqual(repository.value, other)
        XCTAssertTrue(repository.save(.empty, replacing: other))
    }

    func testReadFailureAndInvalidValuesCannotBeOverwrittenAsDefaults() {
        let store = DailyGoalsMemoryStore()
        store.readFails = true
        let repository = DailyGoalsRepository(store: store)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertFalse(repository.save(.empty, replacing: .empty))
        XCTAssertEqual(store.writes, 0)
        store.readFails = false
        store.value = DailyGoals(steps: -1, foodKilocalories: nil)
        repository.reload()
        XCTAssertFalse(repository.isAvailable)
    }

    func testCorruptUserDefaultsPayloadIsPreserved() throws {
        let suite = "01-daily-goals-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "goals", bytes = Data("invalid".utf8)
        defaults.set(bytes, forKey: key)
        let store = UserDefaultsDailyGoalsStore(defaults: defaults, key: key)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(defaults.data(forKey: key), bytes)
    }

    func testStorageBecomingUnreadableDoesNotPublishOldTargetsAsCurrent() {
        let store = DailyGoalsMemoryStore()
        let original = DailyGoals(steps: 8_000, foodKilocalories: nil)
        store.value = original
        let repository = DailyGoalsRepository(store: store)
        store.readFails = true

        XCTAssertFalse(repository.save(.empty, replacing: original))
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.value, original)
        XCTAssertNotNil(repository.errorMessage)

        store.readFails = false
        repository.reload()
        XCTAssertTrue(repository.isAvailable)
        XCTAssertEqual(repository.value, original)
        XCTAssertNil(repository.errorMessage)
    }

    func testLostReadbackDoesNotClaimSuccessOrAutomaticallyRetryWrite() {
        let store = DailyGoalsMemoryStore()
        let repository = DailyGoalsRepository(store: store)
        let desired = DailyGoals(steps: 8_000, foodKilocalories: 2_000)
        store.failReadsAfterWrite = true

        XCTAssertFalse(repository.save(desired, replacing: .empty))
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(store.writes, 1)
        XCTAssertNotNil(repository.errorMessage)
        // The write may have landed. Only a later successful read can establish it.
        store.readFails = false
        repository.reload()
        XCTAssertTrue(repository.isAvailable)
        XCTAssertEqual(repository.value, desired)
        XCTAssertEqual(store.writes, 1)
    }

    func testTargetsSurviveCanonicalWaterOverlayAndDoNotAlterEnergyNumbers() throws {
        let now = Date(), start = Calendar.current.startOfDay(for: now)
        let base = DailyWidgetSnapshot(generatedAt: now, dayStart: start,
            steps: .reading(4_000, at: now), eatenKilocalories: .reading(1_500, at: now),
            burnedKilocalories: .reading(400, at: now), waterMilliliters: .reading(500, at: now),
            waterGoalMilliliters: 2_500, stepGoal: 8_000, foodGoalKilocalories: 2_000)
        let water = try XCTUnwrap(DailyWidgetWaterState(transaction: .init(state: .init(date: now,
            currentMilliliters: 750, goalMilliliters: 2_500, dayStart: start)), at: now))
        let overlay = water.displaySnapshot(base: base, at: now)
        XCTAssertEqual(overlay.stepGoal, 8_000)
        XCTAssertEqual(overlay.foodGoalKilocalories, 2_000)
        XCTAssertEqual(overlay.eatenKilocalories.value, 1_500)
        XCTAssertEqual(overlay.burnedKilocalories.value, 400)
        XCTAssertEqual(DailyWidgetWaterState.unavailableSnapshot(base: base, at: now).foodGoalKilocalories, 2_000)
        XCTAssertTrue(overlay.isValid)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json.removeValue(forKey: "stepGoal")
        json.removeValue(forKey: "foodGoalKilocalories")
        let legacy = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.stepGoal)
        XCTAssertNil(legacy.foodGoalKilocalories)
        XCTAssertTrue(legacy.isValid)
    }
}

private final class DailyGoalsMemoryStore: DailyGoalsPersisting {
    var value = DailyGoals.empty
    var discardWrites = false
    var readFails = false
    var failReadsAfterWrite = false
    var writes = 0
    func load() throws -> DailyGoals {
        if readFails { throw DailyGoalsError.unavailable }
        return value
    }
    func save(_ value: DailyGoals) throws {
        writes += 1
        if !discardWrites { self.value = value }
        if failReadsAfterWrite { readFails = true }
    }
}
