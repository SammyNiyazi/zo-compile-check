import XCTest
@testable import ZeroOne

@MainActor
final class LocalCrewTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "LocalCrewTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testCrewNeedsANameAndAGoalInRange() {
        XCTAssertNil(LocalCrew(name: "   ", weeklyGoal: 3, createdAt: .now))
        XCTAssertNil(LocalCrew(name: String(repeating: "x", count: 41), weeklyGoal: 3, createdAt: .now))
        XCTAssertNil(LocalCrew(name: "Sofia Lifters", weeklyGoal: 0, createdAt: .now))
        XCTAssertNil(LocalCrew(name: "Sofia Lifters", weeklyGoal: 15, createdAt: .now))
        XCTAssertEqual(LocalCrew(name: "  Sofia Lifters ", weeklyGoal: 4, createdAt: .now)?.name, "Sofia Lifters")
    }

    func testStoreSavesReloadsAndLeaves() throws {
        let defaults = defaults()
        let store = LocalCrewStore(defaults: defaults)
        XCTAssertNil(store.crew)
        let crew = try XCTUnwrap(LocalCrew(name: "Sofia Lifters", weeklyGoal: 4, createdAt: Date(timeIntervalSince1970: 1_000)))
        XCTAssertTrue(store.save(crew))
        XCTAssertEqual(LocalCrewStore(defaults: defaults).crew, crew)
        XCTAssertTrue(store.leave())
        XCTAssertNil(LocalCrewStore(defaults: defaults).crew)
    }

    func testUnreadableCrewIsKeptNotOverwritten() throws {
        let defaults = defaults()
        defaults.set(Data("not json".utf8), forKey: LocalCrewStore.storageKey)
        let store = LocalCrewStore(defaults: defaults)
        XCTAssertFalse(store.isAvailable)
        let crew = try XCTUnwrap(LocalCrew(name: "New", weeklyGoal: 2, createdAt: .now))
        XCTAssertFalse(store.save(crew))
        XCTAssertFalse(store.leave())
        XCTAssertEqual(defaults.data(forKey: LocalCrewStore.storageKey), Data("not json".utf8))
    }

    func testWeekCountUsesOnlyThisWeeksSavedWorkouts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        calendar.firstWeekday = 2
        func day(_ d: Int, _ h: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
        }
        // Monday 5 to Sunday 11 October 2026; "now" is Friday 9 at noon.
        let dates = [day(4), day(5), day(7), day(9, 8), day(9, 20), day(12)]
        XCTAssertEqual(LocalCrew.workoutsThisWeek(completedAt: dates, asOf: day(9), calendar: calendar), 3)
    }
}
