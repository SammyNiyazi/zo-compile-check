import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutHistoryFactsPresentationTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    func testRecordedLoadRepsRIRAndUnknownSideAreNotAPlanOrBodyweightClaim() {
        let copy = WorkoutHistoryFactsPresentation(localization: .english)
        let actual = set(load: Load(0), reps: 7, side: nil, rir: 0)
        let text = copy.setText(actual)
        XCTAssertTrue(text.contains("0 kg"))
        XCTAssertTrue(text.contains("7 reps"))
        XCTAssertTrue(text.contains("0 reps in reserve"))
        XCTAssertTrue(text.contains("side convention not recorded"))
        XCTAssertFalse(text.contains("Bodyweight"))
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(record([actual])))
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(record([actual])))
    }

    func testTimedRecordUsesActualSecondsAndUnitWithoutRepetitionOrElapsedSessionClaim() {
        let copy = WorkoutHistoryFactsPresentation(localization: .english)
        let actual = set(load: Load(5.125, unit: .pounds), reps: 0, side: true, seconds: 37)
        let text = copy.setText(actual)
        XCTAssertTrue(text.contains("5.125 lb"))
        XCTAssertTrue(text.contains("37 seconds"))
        XCTAssertTrue(text.contains("per side"))
        XCTAssertFalse(text.contains("0 reps"))
        let entry = record([actual], targetMinutes: 180)
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(entry))
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(entry))
        XCTAssertFalse(copy.recordSummary(WorkoutHistoryPresentation(entry: entry)).contains("180"))
    }

    func testPerSideTrueFalseAndNilRemainDifferent() {
        let copy = WorkoutHistoryFactsPresentation(localization: .english)
        let bilateral = set(load: Load(20), reps: 8, side: false)
        let sided = set(load: Load(20), reps: 8, side: true)
        let unknown = set(load: Load(20), reps: 8, side: nil)
        XCTAssertFalse(copy.setText(bilateral).contains("per side"))
        XCTAssertTrue(copy.setText(sided).contains("per side"))
        XCTAssertTrue(copy.setText(unknown).contains("not recorded"))
        XCTAssertEqual(WorkoutHistoryFactsPresentation.totalRepetitions(record([bilateral])), 8)
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(record([sided])))
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(record([unknown])))
    }

    func testQualifiedLoggedVolumeUsesSavedValuesAndMixedUnitsNeverConvert() {
        let kg = record([set(load: Load(12.5), reps: 8, side: false), set(load: Load(15), reps: 6, side: false)])
        XCTAssertEqual(WorkoutHistoryFactsPresentation.loggedVolume(kg), Load(190))
        XCTAssertEqual(WorkoutHistoryFactsPresentation.totalRepetitions(kg), 14)
        let mixed = record([set(load: Load(12.5), reps: 8, side: false),
                            set(load: Load(15, unit: .pounds), reps: 6, side: false)])
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(mixed))
        // Repetitions share a convention even when load units differ; no
        // comparison or unit conversion is claimed by the simple rep count.
        XCTAssertEqual(WorkoutHistoryFactsPresentation.totalRepetitions(mixed), 14)
    }

    func testZeroLoadAndOverflowKeepNullableMetricsHonest() {
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(record([set(load: Load(0), reps: 8, side: false)])))
        let huge = record([set(load: Load(Double.greatestFiniteMagnitude), reps: 8, side: false)])
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(huge))
        let overflowing = record([set(load: Load(1), reps: Int.max, side: false), set(load: Load(1), reps: 1, side: false)])
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(overflowing))
    }

    func testLegacySummaryRetainsActualSourceIdentityAndUnknownDetail() throws {
        let detailed = record([set(load: Load(10), reps: 6, side: false)], planned: 3)
        let legacy = try changingJSON(detailed) { $0.removeValue(forKey: "exercises") }
        let groups = WorkoutHistoryFactsPresentation.weeks([legacy], calendar: calendar)
        XCTAssertEqual(groups.flatMap(\.entries).map(\.sourceEntry.id), [detailed.sourceEntry.id])
        XCTAssertNil(legacy.exercises)
        XCTAssertEqual(WorkoutHistoryPresentation(entry: legacy).detail, .summaryOnly)
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(legacy))
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(legacy))
    }

    func testCountMismatchCannotBecomeQualifiedAggregate() throws {
        let oneSavedSet = record([set(load: Load(10), reps: 6, side: false)])
        let mismatch = try changingJSON(oneSavedSet) { $0["completedSetCount"] = 2 }
        XCTAssertNil(WorkoutHistoryFactsPresentation.totalRepetitions(mismatch))
        XCTAssertNil(WorkoutHistoryFactsPresentation.loggedVolume(mismatch))
    }

    func testCalendarGroupingFailureNeverDropsOrReidentifiesASavedRoute() {
        let first = record([set(load: Load(10), reps: 6, side: false)])
        let second = record([set(load: Load(20), reps: 7, side: false)])
        let groups = WorkoutHistoryFactsPresentation.weeks([second, first], intervalForDate: { _ in nil })
        XCTAssertEqual(Set(groups.flatMap(\.entries).map(\.sourceEntry.id)), Set([first.id, second.id]))
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.interval == nil })
        XCTAssertEqual(groups.flatMap(\.entries).count, 2)
    }

    func testRepeatedOccurrencesAndSetIDsRetainSavedOrder() {
        let actual = [set(load: Load(12), reps: 6, side: false), set(load: Load(9), reps: 11, side: false)]
        let source = record(actual, repeatOccurrence: true)
        let presentation = WorkoutHistoryPresentation(entry: source)
        XCTAssertEqual(presentation.exercises.count, 2)
        XCTAssertEqual(presentation.exercises.flatMap(\.sets).map(\.id), actual.map(\.id))
        XCTAssertEqual(presentation.exercises.map(\.exerciseID), ["saved-test", "saved-test"])
        XCTAssertEqual(presentation.grid.filter(\.startsGroup).count, 2)
    }

    func testMonthSummaryIncludesStartExcludesNextMonthAndCountsOnlySavedFacts() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let inside = record([set(load: Load(10), reps: 5, side: false)], planned: 3, at: start)
        let outside = record([set(load: Load(10), reps: 5, side: false)], at: end)
        let summary = WorkoutHistoryFactsPresentation.monthSummary([inside, outside], now: start, calendar: calendar)
        XCTAssertEqual(summary?.workoutCount, 1)
        XCTAssertEqual(summary?.savedSetCount, 1)
    }

    func testTypedTemplatesKeepPercentBearingMetadataVerbatim() {
        let localization = AppLocalization.english
        let title = "Saved %1$lld workout"
        XCTAssertEqual(localization.format("Set %1$lld: %2$@", .integer(2), .text(title)), "Set 2: Saved %1$lld workout")
    }

    func testSelectedBulgarianCopyDatesAndDecimalWithoutTranslatingMetadata() {
        let copy = WorkoutHistoryFactsPresentation(localization: .init(language: .bulgarian))
        XCTAssertEqual(copy.status(.partial), "Частично")
        let actual = set(load: Load(12.125, unit: .pounds), reps: 9, side: true)
        let text = copy.setText(actual)
        XCTAssertTrue(text.contains("12,125 lb"))
        XCTAssertTrue(text.contains("9 повторения"))
        XCTAssertTrue(text.contains("на страна"))
        let english = WorkoutHistoryFactsPresentation(localization: .english)
        XCTAssertNotEqual(copy.date(savedAt, calendar: calendar, wide: true), english.date(savedAt, calendar: calendar, wide: true))
    }

    private func set(load: Load, reps: Int, side: Bool?, seconds: Int? = nil, rir: Int? = nil) -> CompletedSet {
        CompletedSet(load: load, reps: reps, rir: rir, completedAt: savedAt,
                     durationSeconds: seconds, isPerSide: side)
    }

    private func record(_ sets: [CompletedSet], planned: Int? = nil, targetMinutes: Int? = nil,
                        at: Date? = nil, repeatOccurrence: Bool = false) -> WorkoutHistoryDisplayItem {
        let occurrences = repeatOccurrence ? sets.map { [$0] } : [sets]
        let exercises = occurrences.map { actual in
            WorkoutExercise(plan: ExercisePlan(exerciseID: "saved-test", name: "Verbatim %1$@ name",
                targetLoad: Load(999), targetReps: RepRange(99, 99),
                plannedSetCount: planned ?? max(1, actual.count), restSeconds: 90, previousPerformance: []), completedSets: actual)
        }
        let session = WorkoutSession(title: "Verbatim %1$@ title", targetDurationMinutes: targetMinutes,
            exercises: exercises, completedAt: at ?? savedAt)
        return WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: session))
    }

    private func changingJSON(_ entry: WorkoutHistoryDisplayItem, edit: (inout [String: Any]) -> Void) throws -> WorkoutHistoryDisplayItem {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry.sourceEntry)) as? [String: Any])
        edit(&json)
        let actual = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        return WorkoutHistoryDisplayItem(entry: actual)
    }
}
