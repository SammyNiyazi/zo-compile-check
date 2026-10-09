import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class DailyWidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testFoodAndActiveEnergyAreSeparateAndTimestamped() {
        let result = snapshot(health: health(steps: 1234, energy: 350), meals: [meal(800)])
        XCTAssertEqual(result.eatenKilocalories.value, 800)
        XCTAssertEqual(result.burnedKilocalories.value, 350)
        XCTAssertEqual(result.steps.value, 1234)
        XCTAssertEqual(result.burnedKilocalories.asOf, now.addingTimeInterval(-60))
        XCTAssertTrue(result.isValid)
    }

    func testNoHealthDataIsNotZeroAndDisconnectedIsNotDenied() {
        let empty = snapshot(health: health(steps: nil, energy: nil))
        XCTAssertEqual(empty.steps.state, .noData)
        XCTAssertNil(empty.burnedKilocalories.value)
        let disconnected = snapshot(health: health(steps: 300, energy: 60), healthStatus: .notConnected)
        XCTAssertEqual(disconnected.steps.state, .needsConnection)
        XCTAssertEqual(disconnected.burnedKilocalories.state, .needsConnection)
        XCTAssertNil(disconnected.burnedKilocalories.value)
        XCTAssertEqual(disconnected.eatenKilocalories.value, 0, "An available, empty meal log is a real zero.")
    }

    func testNewestQueryWinsWithoutRevivingAnOlderCountWhenNoDataIsReturned() {
        let latest = StepsDayReading(readAt: now, dayStart: calendar.startOfDay(for: now), totalSteps: nil, distanceMeters: nil, hours: [])
        let result = snapshot(health: health(steps: 900, energy: 70), steps: latest, stepsStatus: .connected)
        XCTAssertEqual(result.steps.state, .noData)
        XCTAssertNil(result.steps.value)
        XCTAssertEqual(result.burnedKilocalories.value, 70)
    }

    func testStaleHealthKeepsItsOwnReadTimeAndFlag() {
        let result = snapshot(health: health(steps: 900, energy: 70), stale: true)
        XCTAssertTrue(result.steps.isStale)
        XCTAssertTrue(result.burnedKilocalories.isStale)
        XCTAssertEqual(result.steps.asOf, now.addingTimeInterval(-60))
    }

    func testYesterdayAndDifferentTimezoneBoundaryNeverBecomeToday() {
        let yesterday = health(steps: 900, energy: 70, dayStart: calendar.startOfDay(for: now).addingTimeInterval(-86_400))
        let result = snapshot(health: yesterday)
        XCTAssertEqual(result.steps.state, .needsRefresh)
        XCTAssertNil(result.burnedKilocalories.value)
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertFalse(result.isCurrent(on: now, calendar: tokyo))
        XCTAssertFalse(result.isCurrent(on: now.addingTimeInterval(86_400), calendar: calendar))
        XCTAssertFalse(result.isCurrent(on: now.addingTimeInterval(-1), calendar: calendar))
    }

    func testUnavailableLocalStoresDoNotExposeTheirRetainedValues() {
        let result = snapshot(meals: [meal(500)], nutritionAvailable: false, hydrationAvailable: false)
        XCTAssertEqual(result.eatenKilocalories.state, .unavailable)
        XCTAssertNil(result.eatenKilocalories.value)
        XCTAssertNil(result.waterMilliliters.value)
        XCTAssertNil(result.waterGoalMilliliters)
    }

    func testMealsAreFilteredToCurrentDayAndInvalidTotalsDoNotOverflow() {
        XCTAssertEqual(snapshot(meals: [meal(700), meal(900, at: now.addingTimeInterval(-86_400))]).eatenKilocalories.value, 700)
        XCTAssertEqual(snapshot(meals: [meal(Int.max), meal(1)]).eatenKilocalories.state, .unavailable)
        XCTAssertEqual(snapshot(meals: [meal(-1)]).eatenKilocalories.state, .unavailable)
    }

    func testInvalidHealthNumbersAreOmitted() {
        let result = snapshot(health: health(steps: .infinity, energy: -.infinity))
        XCTAssertNil(result.steps.value)
        XCTAssertNil(result.burnedKilocalories.value)
        XCTAssertTrue(result.isValid)
        let negativeFraction = snapshot(health: health(steps: -0.2, energy: -0.2))
        XCTAssertEqual(negativeFraction.steps.state, .noData)
        XCTAssertNil(negativeFraction.steps.value, "Validate before rounding, never convert a negative fraction into zero steps.")
        XCTAssertNil(negativeFraction.burnedKilocalories.value)
    }

    func testProjectionRoundTripContainsOnlyDisplayTotals() throws {
        let original = snapshot(health: health(steps: 1200, energy: 350), meals: [meal(800)])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DailyWidgetSnapshot.self, from: data), original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "generatedAt", "dayStart", "steps", "eatenKilocalories", "burnedKilocalories", "waterMilliliters", "waterGoalMilliliters", "accentPreference"])
    }

    func testLegacyAndFutureWidgetAccentsKeepTheRecordedTotals() throws {
        let original = snapshot(health: health(steps: 1200, energy: 350), meals: [meal(800)], accent: .pink)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let rawValues: [String?] = [nil, "future-accent"]
        for raw in rawValues {
            json["accentPreference"] = raw
            let decoded = try JSONDecoder().decode(DailyWidgetSnapshot.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertTrue(decoded.isValid)
            XCTAssertEqual(decoded.accent, .yellow)
            var expected = original
            expected.accentPreference = raw
            XCTAssertEqual(decoded, expected)
        }
    }

    func testAccentOnlyChangePublishesAndSurvivesFreshFileStoreRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDailyWidgetSnapshotStore(directory: directory)
        var reloads = 0
        let publisher = DailyWidgetPublisher(store: store, reload: { reloads += 1 })
        let yellow = snapshot()
        let pink = snapshot(accent: .pink)
        XCTAssertTrue(publisher.publish(yellow))
        XCTAssertTrue(publisher.publish(pink))
        XCTAssertTrue(publisher.publish(pink))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(try FileDailyWidgetSnapshotStore(directory: directory).load(), pink)
    }

    func testWaterOverlaysAndDayExpiryRetainAccentWithoutRevivingExpiredTotals() throws {
        let base = snapshot(health: health(steps: 1200, energy: 350), accent: .pink)
        let transaction = HydrationTransactionState(state: .init(date: now,
            currentMilliliters: 750, goalMilliliters: 2500, dayStart: calendar.startOfDay(for: now)))
        let nextDay = now.addingTimeInterval(86_400)
        let water = try XCTUnwrap(DailyWidgetWaterState(transaction: transaction, at: nextDay, calendar: calendar))
        let current = water.displaySnapshot(base: base, at: now, calendar: calendar)
        XCTAssertEqual(current.accent, .pink)
        XCTAssertEqual(current.steps, base.steps)
        XCTAssertEqual(current.waterMilliliters.value, 750)
        let expired = water.displaySnapshot(base: base, at: nextDay, calendar: calendar)
        XCTAssertEqual(expired.accent, .pink)
        XCTAssertNil(expired.steps.value)
        XCTAssertNil(expired.burnedKilocalories.value)
        XCTAssertEqual(expired.waterMilliliters.value, 0)
        let unavailable = DailyWidgetWaterState.unavailableSnapshot(base: base, at: nextDay, calendar: calendar)
        XCTAssertEqual(unavailable.accent, .pink)
        XCTAssertNil(unavailable.steps.value)
        XCTAssertNil(unavailable.waterMilliliters.value)
    }

    func testPublisherReloadsOnlyAfterVerifiedWriteAndDoesNotRepeatIdenticalSnapshot() {
        let store = SnapshotMemoryStore()
        var reloads = 0
        let publisher = DailyWidgetPublisher(store: store, reload: { reloads += 1 })
        let value = snapshot()
        store.dropsWrites = true
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(reloads, 0)
        store.dropsWrites = false
        XCTAssertTrue(publisher.publish(value))
        XCTAssertTrue(publisher.publish(value))
        XCTAssertEqual(reloads, 1)
        store.isAvailable = false
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(reloads, 1)
    }

    func testFileStoreFailsClosedWithoutAnAppGroupAndRejectsUnknownSchema() throws {
        let unavailable = FileDailyWidgetSnapshotStore(directory: nil)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertThrowsError(try unavailable.save(snapshot()))
        XCTAssertThrowsError(try unavailable.load())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        json["version"] = 999
        let future = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(future.isValid)
        XCTAssertFalse(future.isCurrent(on: now, calendar: calendar))
    }

    func testPublisherCanReplaceACorruptDerivedCacheWithVerifiedFreshData() {
        let store = SnapshotMemoryStore()
        store.corrupt = true
        var reloads = 0
        let publisher = DailyWidgetPublisher(store: store, reload: { reloads += 1 })
        XCTAssertTrue(publisher.publish(snapshot()))
        XCTAssertEqual(reloads, 1)
        XCTAssertNil(publisher.lastError)
    }

    private func meal(_ calories: Int, at date: Date? = nil) -> NutritionEntry {
        NutritionEntry(id: UUID(), title: "Test meal", calories: calories, proteinGrams: nil,
                       carbohydrateGrams: nil, fatGrams: nil, loggedAt: date ?? now)
    }

    private func health(steps: Double?, energy: Double?, dayStart: Date? = nil) -> HealthContext {
        HealthContext(todaySteps: steps, todayActiveEnergyKilocalories: energy, mostRecentWorkout: nil,
                      lastNightSleepDurationSeconds: nil, refreshedAt: now.addingTimeInterval(-60),
                      dayStart: dayStart ?? calendar.startOfDay(for: now))
    }

    private func snapshot(health: HealthContext? = nil, healthStatus: HealthConnectionStatus = .connected,
                          steps: StepsDayReading? = nil, stepsStatus: HealthConnectionStatus = .notConnected,
                          stale: Bool = false, meals: [NutritionEntry] = [], nutritionAvailable: Bool = true,
                          hydrationAvailable: Bool = true, accent: AccentPreference = .yellow) -> DailyWidgetSnapshot {
        DailyWidgetProjection.make(at: now, calendar: calendar, steps: steps, stepsStatus: stepsStatus,
                                   stepsFailed: false, health: health, healthStatus: healthStatus, healthIsStale: stale,
                                   meals: meals, nutritionAvailable: nutritionAvailable,
                                   water: HydrationState(currentMilliliters: 500),
                                   waterDayStart: calendar.startOfDay(for: now), hydrationAvailable: hydrationAvailable, accent: accent)
    }
}

private final class SnapshotMemoryStore: DailyWidgetSnapshotPersisting {
    var isAvailable = true
    var dropsWrites = false
    var corrupt = false
    private var snapshot: DailyWidgetSnapshot?
    func load() throws -> DailyWidgetSnapshot? {
        if corrupt { throw DailyWidgetSnapshotError.invalidSnapshot }
        return snapshot
    }
    func save(_ snapshot: DailyWidgetSnapshot) throws {
        if !dropsWrites { self.snapshot = snapshot; corrupt = false }
    }
}
