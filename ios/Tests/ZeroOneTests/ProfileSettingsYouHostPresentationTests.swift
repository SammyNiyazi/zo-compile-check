import XCTest
@testable import ZeroOne

final class ProfileSettingsYouHostPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private var asOf: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))! }

    func testObservedEmptyHistoryDiffersFromUnavailable() throws {
        XCTAssertNil(ProfileSettingsYouHostPresentation.observedMonth(state: .unavailable, asOf: asOf, calendar: calendar))
        let empty = try XCTUnwrap(ProfileSettingsYouHostPresentation.observedMonth(state: .empty, asOf: asOf, calendar: calendar))
        XCTAssertEqual(empty.workouts, 0)
        XCTAssertEqual(empty.scope, .recordedHistory)
        XCTAssertNil(empty.respectsReceived)
        XCTAssertNil(empty.newBests)
        XCTAssertNil(empty.goal)
    }

    func testCompleteObservedSurfaceUsesActualSourceEntriesAndMonth() throws {
        let current = try entry(at: asOf.addingTimeInterval(-60))
        let older = try entry(at: calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!)
        let surface: WorkoutHistorySurfaceState = .entries([.init(entry: current), .init(entry: older)])
        let value = try XCTUnwrap(ProfileSettingsYouHostPresentation.observedMonth(state: surface, asOf: asOf, calendar: calendar))
        XCTAssertEqual(value.workouts, 1)
        XCTAssertEqual(value.asOf, asOf)
        XCTAssertEqual(value.calendar.timeZone, calendar.timeZone)
    }

    func testMalformedObservedSurfaceCannotBecomeAValidMonthCount() throws {
        let current = try entry(at: asOf)
        let duplicate: WorkoutHistorySurfaceState = .entries([.init(entry: current), .init(entry: current)])
        XCTAssertNil(ProfileSettingsYouHostPresentation.observedMonth(state: duplicate, asOf: asOf, calendar: calendar))
        let future: WorkoutHistorySurfaceState = .entries([.init(entry: try entry(at: asOf.addingTimeInterval(1)))])
        XCTAssertNil(ProfileSettingsYouHostPresentation.observedMonth(state: future, asOf: asOf, calendar: calendar))
    }

    func testProfileReplacementAndUnreadableProfileDoNotReuseAnOldNameOrCreateCard() {
        func snapshot(_ name: String, available: Bool) -> ProfileSettingsYouSnapshot {
            ProfileSettingsYouHostPresentation.snapshot(asOf: asOf, calendar: calendar,
                displayName: name, profileAvailable: available, historyState: .empty,
                bodyWeightEntries: nil, bodyWeightUnitRawValue: nil, themeRawValue: nil)
        }
        XCTAssertEqual(snapshot("Mira", available: true).displayName, "Mira")
        XCTAssertEqual(snapshot("Iva", available: true).displayName, "Iva")
        let unreadable = snapshot("Mira", available: false)
        XCTAssertNil(unreadable.displayName)
        XCTAssertNil(unreadable.card)
        XCTAssertNil(unreadable.bodyWeight)
        XCTAssertEqual(unreadable.month?.workouts, 0)
    }

    func testThemeOwnKeyMapsAllFinalFamiliesAndUsesActualUnknownFallback() {
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: DesignThemePreference.core.rawValue), .onyx)
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: DesignThemePreference.retro.rawValue), .neon)
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: DesignThemePreference.freak.rawValue), .chrome)
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: DesignThemePreference.princess.rawValue), .pink)
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: "unrecognized-legacy-choice"), .onyx)
        XCTAssertEqual(ProfileSettingsYouHostPresentation.edition(themeRawValue: nil), .onyx)
    }

    func testLatestApplicableWeightUsesExistingConversionAndSkipsFutureReading() throws {
        let older = weight(65, at: asOf.addingTimeInterval(-120))
        let latest = weight(70, at: asOf.addingTimeInterval(-60))
        let future = weight(80, at: asOf.addingTimeInterval(60))
        let result = try XCTUnwrap(ProfileSettingsYouHostPresentation.observedWeight(
            entries: [future, older, latest], asOf: asOf, unitRawValue: BodyWeightUnit.pounds.rawValue))
        XCTAssertEqual(result.unit, .pounds)
        XCTAssertEqual(result.value, BodyWeightUnit.pounds.displayedValue(for: latest.kilograms), accuracy: 0.0001)
        let fallback = try XCTUnwrap(ProfileSettingsYouHostPresentation.observedWeight(
            entries: [latest], asOf: asOf, unitRawValue: "unknown"))
        XCTAssertEqual(fallback.unit, .kilograms)
        XCTAssertEqual(fallback.value, 70)
    }

    func testUnavailableEmptyDuplicateMalformedAndInvalidClockWeightRemainUnknown() {
        let value = weight(70, at: asOf)
        let cases: [[BodyWeightEntry]?] = [nil, [], [value, value], [weight(0, at: asOf)],
            [weight(70, at: Date(timeIntervalSinceReferenceDate: .nan))], [weight(70, at: asOf.addingTimeInterval(1))]]
        for entries in cases {
            XCTAssertNil(ProfileSettingsYouHostPresentation.observedWeight(entries: entries, asOf: asOf, unitRawValue: "kg"))
        }
        let snapshot = ProfileSettingsYouHostPresentation.snapshot(asOf: Date(timeIntervalSinceReferenceDate: .nan),
            calendar: calendar, displayName: "Mira", profileAvailable: true, historyState: .empty,
            bodyWeightEntries: [value], bodyWeightUnitRawValue: "kg", themeRawValue: "princess")
        XCTAssertNil(snapshot.month)
        XCTAssertNil(snapshot.bodyWeight)
        XCTAssertNil(snapshot.card)
    }

    func testUnavailableCapabilitiesAndBusyAccountRemoveOnlyTheirLocalActions() {
        let ready = ProfileSettingsYouHostPresentation.capabilities(profileAvailable: true,
            weightAvailable: true, photoAvailable: true, accountBusy: false)
        XCTAssertTrue(ready.personalDetails && ready.bodyWeight && ready.photo)
        let mixed = ProfileSettingsYouHostPresentation.capabilities(profileAvailable: false,
            weightAvailable: true, photoAvailable: false, accountBusy: false)
        XCTAssertFalse(mixed.personalDetails)
        XCTAssertTrue(mixed.bodyWeight)
        XCTAssertFalse(mixed.photo)
        let busy = ProfileSettingsYouHostPresentation.capabilities(profileAvailable: true,
            weightAvailable: true, photoAvailable: true, accountBusy: true)
        XCTAssertFalse(busy.personalDetails || busy.bodyWeight || busy.photo)
    }

    func testIntegratedTrainingDayKeysUseTheActualTypedFormatter() {
        XCTAssertEqual(AppLocalization.english.format("%1$lld training day", .integer(1)), "1 training day")
        XCTAssertEqual(AppLocalization.english.format("%1$lld training days", .integer(7)), "7 training days")
    }

    private func weight(_ kilograms: Decimal, at date: Date) -> BodyWeightEntry {
        .init(id: UUID(), recordedAt: date, kilograms: kilograms)
    }
    private func entry(at date: Date) throws -> WorkoutHistoryEntry {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "title": "Recorded session",
            "completedAt": date.timeIntervalSinceReferenceDate, "completedSetCount": 1, "plannedSetCount": 1, "wasAdapted": false])
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: data)
    }
}
