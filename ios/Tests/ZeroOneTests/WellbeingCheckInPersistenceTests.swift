import XCTest
@testable import ZeroOne

@MainActor
final class WellbeingCheckInPersistenceTests: XCTestCase {
    func testUnacknowledgedWriteAndStaleFormCannotPublishEvidence() throws {
        let store = CheckInStore()
        let repository = WellbeingCheckInRepository(store: store)
        let baseline = repository.snapshot
        let now = Date.now
        let record = report(at: now)
        store.rejectWrites = true
        XCTAssertThrowsError(try repository.save(recovery: record, nutrition: nil, replacing: baseline, at: now, calendar: .current))
        XCTAssertEqual(repository.snapshot, baseline)
        XCTAssertTrue(repository.isAvailable)
        store.rejectWrites = false
        try repository.save(recovery: record, nutrition: nil, replacing: baseline, at: now, calendar: .current)
        XCTAssertEqual(repository.snapshot.recovery, [record])
        XCTAssertThrowsError(try repository.save(recovery: report(at: now), nutrition: nil,
            replacing: baseline, at: now, calendar: .current)) { XCTAssertEqual($0 as? WellbeingCheckInError, .changed) }
        XCTAssertEqual(store.value.recovery, [record])
    }

    func testUnreadableOrFutureVersionStoreIsNotOverwritten() {
        let store = CheckInStore()
        store.value = WellbeingCheckInSnapshot(version: WellbeingCheckInSnapshot.currentVersion + 1)
        let repository = WellbeingCheckInRepository(store: store)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertThrowsError(try repository.save(recovery: report(at: .now), nutrition: nil,
            replacing: repository.snapshot, at: .now, calendar: .current))
        XCTAssertEqual(store.value.version, WellbeingCheckInSnapshot.currentVersion + 1)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testSavedReportSurvivesRelaunchAndCanBeExplicitlyDeleted() throws {
        let name = "01.checkInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWellbeingCheckInStore(defaults: defaults)
        let first = WellbeingCheckInRepository(store: store)
        let now = Date.now
        try first.save(recovery: report(at: now), nutrition: nil, replacing: first.snapshot, at: now, calendar: .current)
        let second = WellbeingCheckInRepository(store: store)
        XCTAssertEqual(second.snapshot, first.snapshot)
        try second.deleteAll(replacing: second.snapshot)
        XCTAssertEqual(try store.load(), WellbeingCheckInSnapshot())
    }

    func testLegacyFoodReviewLoadsUnknownAndExplicitDayGoalSurvivesRelaunch() throws {
        let name = "01.foodReviewGoalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_024_000)
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let fingerprint = try XCTUnwrap(NutritionDayReview.fingerprint(entries: [], on: day, calendar: calendar))
        let legacyReview = NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier,
            reviewedAt: now, coverage: .complete, mealFingerprint: fingerprint, reviewedFoodGroups: [])
        let legacy = WellbeingCheckInSnapshot(nutrition: [legacyReview], version: 1)
        let encodedLegacy = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encodedLegacy, as: UTF8.self).contains("reportedCalorieGoal"))
        defaults.set(encodedLegacy, forKey: "01.wellbeingCheckIns.v1")
        let store = UserDefaultsWellbeingCheckInStore(defaults: defaults)
        let repository = WellbeingCheckInRepository(store: store)
        XCTAssertTrue(repository.isAvailable)
        XCTAssertNil(repository.snapshot.nutrition.first?.reportedCalorieGoal)
        let reviewed = NutritionDayReview(id: legacyReview.id, day: day, timeZoneID: calendar.timeZone.identifier,
            reviewedAt: now, coverage: .complete, mealFingerprint: fingerprint, reviewedFoodGroups: [],
            reportedCalorieGoal: 2_400)
        try repository.save(recovery: nil, nutrition: reviewed, replacing: legacy, at: now, calendar: calendar)
        let restored = WellbeingCheckInRepository(store: store)
        XCTAssertEqual(restored.snapshot.version, WellbeingCheckInSnapshot.currentVersion)
        XCTAssertEqual(restored.snapshot.nutrition, [reviewed])
        let exported = try JSONEncoder().encode(restored.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: exported), restored.snapshot)
        try restored.deleteAll(replacing: restored.snapshot)
        XCTAssertEqual(try store.load(), WellbeingCheckInSnapshot())
        // The original export and legacy evidence are not rewritten by deletion.
        XCTAssertEqual(try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: encodedLegacy), legacy)
    }

    func testVersionOneCannotClaimNewComparisonContextOrBeOverwritten() throws {
        let now = Date.now
        let review = NutritionDayReview(id: UUID(), day: Calendar.current.startOfDay(for: now.addingTimeInterval(-86_400)),
            timeZoneID: Calendar.current.timeZone.identifier, reviewedAt: now,
            coverage: .complete, mealFingerprint: String(repeating: "a", count: 64), reviewedFoodGroups: nil,
            reportedCalorieGoal: 2_400)
        let store = CheckInStore()
        store.value = WellbeingCheckInSnapshot(nutrition: [review], version: 1)
        let repository = WellbeingCheckInRepository(store: store)
        XCTAssertFalse(repository.isAvailable)
        XCTAssertThrowsError(try repository.save(recovery: nil, nutrition: review,
            replacing: repository.snapshot, at: now, calendar: .current))
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(store.value.nutrition, [review])
    }

    private func report(at date: Date) -> RecoveryCheckIn {
        RecoveryCheckIn(id: UUID(), day: Calendar.current.startOfDay(for: date), timeZoneID: Calendar.current.timeZone.identifier,
            reportedAt: date, energy: .low, soreness: .moderate, sleepHours: nil,
            hasNewOrWorseningPain: nil, feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: nil)
    }

    private final class CheckInStore: WellbeingCheckInPersisting {
        var value = WellbeingCheckInSnapshot()
        var rejectWrites = false
        var writeCount = 0
        func load() throws -> WellbeingCheckInSnapshot { value }
        func save(_ value: WellbeingCheckInSnapshot) throws { writeCount += 1; if !rejectWrites { self.value = value } }
    }
}
