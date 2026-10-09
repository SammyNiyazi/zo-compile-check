import Foundation
import XCTest
@testable import ZeroOne

final class ProgressHealthPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Europe/Sofia")!
        result.firstWeekday = 2
        result.minimumDaysInFirstWeek = 4
        return result
    }
    private func date(_ day: Int, hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func weight(_ day: Int, value: Decimal, hour: Int = 12) -> BodyWeightEntry {
        BodyWeightEntry(id: UUID(), recordedAt: date(day, hour: hour), kilograms: value)
    }
    private func weightChart(_ entries: [BodyWeightEntry]) -> ProgressWeightChart {
        ProgressWeightChart(entries: entries, interval: DateInterval(start: date(1, hour: 0), end: date(9, hour: 0)),
                            now: date(8, hour: 20), calendar: calendar)
    }
    private func reading(_ day: Int = 8, count: Double? = 0, distance: Double? = 0,
                         hours: [(Date, Double?)] = []) -> StepsDayReading {
        StepsDayReading(readAt: date(day, hour: 18), dayStart: date(day, hour: 0), totalSteps: count,
                        distanceMeters: distance, hours: hours)
    }
    private func steps(_ reading: StepsDayReading?, goal: Int? = 8_000, stale: Bool = false) -> StepsDayPresentation {
        StepsDayPresentation(reading: reading, now: date(8, hour: 20), calendar: calendar, dailyGoal: goal, isStale: stale)
    }
    private func context(day: Int = 8, duration: TimeInterval? = 0, refreshed: Date? = nil) -> HealthContext {
        HealthContext(todaySteps: nil, todayActiveEnergyKilocalories: nil, mostRecentWorkout: nil,
                      lastNightSleepDurationSeconds: duration, refreshedAt: refreshed ?? date(day, hour: 18),
                      dayStart: date(day, hour: 0))
    }
    private func sleep(_ context: HealthContext?, stale: Bool = false,
                       status: HealthConnectionStatus = .connected) -> HealthSleepPresentation {
        HealthSleepPresentation(context: context, status: status, isStale: stale, now: date(8, hour: 20), calendar: calendar)
    }
    private func photo(_ id: Int, day: Int) -> ProgressPhotoRecord {
        ProgressPhotoRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                            createdAt: date(day), label: .progress, imageRelativePath: "owned", thumbnailRelativePath: "thumb")
    }

    func testLatestObservedReadingWinsWithinDay() throws {
        let chart = weightChart([weight(8, value: 80, hour: 8), weight(8, value: 81, hour: 18)])
        let today = try XCTUnwrap(chart.days.last)
        XCTAssertEqual(today.reading, 81)
        XCTAssertEqual(today.sampleCount, 1)
        XCTAssertEqual(chart.recentSampleCount, 1)
    }
    func testMissingDayBreaksAverageSeriesAndRemainsNil() {
        let chart = weightChart([weight(5, value: 80), weight(7, value: 82)])
        let before = chart.days.first { $0.day == date(5, hour: 0) }!
        let gap = chart.days.first { $0.day == date(6, hour: 0) }!
        let after = chart.days.first { $0.day == date(7, hour: 0) }!
        XCTAssertNil(gap.reading)
        XCTAssertNil(gap.average)
        XCTAssertNotEqual(before.series, after.series)
        XCTAssertEqual(after.average, 81)
    }
    func testConsecutiveObservedDaysShareSeries() {
        let chart = weightChart([weight(7, value: 80), weight(8, value: 82)])
        XCTAssertEqual(chart.days[6].series, chart.days[7].series)
    }
    func testFutureWeightAndInvalidValuesDoNotEnterAverage() {
        let chart = weightChart([weight(9, value: 70), weight(8, value: 0), weight(7, value: -2), weight(6, value: .nan)])
        XCTAssertNil(chart.recentAverage)
        XCTAssertNil(chart.domain(unit: .kilograms))
    }
    func testRecentWindowIncludesExactlySevenCalendarDays() {
        let chart = weightChart([weight(1, value: 100), weight(2, value: 70), weight(8, value: 80)])
        XCTAssertEqual(chart.recentSampleCount, 2)
        XCTAssertEqual(chart.recentAverage, 75)
    }
    func testPoundsDomainContainsConvertedObservedWeight() throws {
        let chart = weightChart([weight(8, value: 80)])
        let range = try XCTUnwrap(chart.domain(unit: .pounds))
        XCTAssertTrue(range.contains(BodyWeightUnit.pounds.displayedValue(for: 80)))
        XCTAssertGreaterThanOrEqual(range.upperBound - range.lowerBound, 9)
    }
    func testUnavailableWorkoutHistoryIsNotEmptyHistory() {
        let interval = ProgressChartWindow.month.interval(now: date(8), calendar: calendar)
        let unknown = ProgressWorkoutChart.weeks(completedDates: nil, interval: interval, now: date(8), calendar: calendar)
        let empty = ProgressWorkoutChart.weeks(completedDates: [], interval: interval, now: date(8), calendar: calendar)
        XCTAssertTrue(unknown.allSatisfy { $0.count == nil })
        XCTAssertTrue(empty.allSatisfy { $0.count == 0 })
    }
    func testWorkoutCountsExcludeOutsideWindowAndFutureDates() {
        let interval = DateInterval(start: date(5, hour: 0), end: date(9, hour: 0))
        let weeks = ProgressWorkoutChart.weeks(completedDates: [date(4), date(5), date(8), date(9)],
                                             interval: interval, now: date(8, hour: 20), calendar: calendar)
        XCTAssertEqual(weeks.compactMap(\.count).reduce(0, +), 2)
    }
    func testChartWindowUsesCalendarMonthAndEndOfToday() {
        let interval = ProgressChartWindow.month.interval(now: date(8), calendar: calendar)
        XCTAssertEqual(interval.start, date(1, hour: 0))
        XCTAssertEqual(interval.end, date(9, hour: 0))
    }
    func testObservedZeroStepsRetainsZeroAndZeroProgress() {
        let presentation = steps(reading())
        XCTAssertEqual(presentation.reading?.totalSteps, 0)
        XCTAssertEqual(presentation.progress, 0)
        XCTAssertFalse(presentation.goalReached)
    }
    func testMissingStepTotalDoesNotBecomeZeroOrGoalReached() {
        let presentation = steps(reading(count: nil))
        XCTAssertNil(presentation.reading?.totalSteps)
        XCTAssertNil(presentation.progress)
        XCTAssertFalse(presentation.goalReached)
    }
    func testMissingOrInvalidGoalDoesNotCreateTarget() {
        for goal in [nil, 0, -1] as [Int?] {
            let presentation = steps(reading(count: 9_000), goal: goal)
            XCTAssertNil(presentation.goal)
            XCTAssertNil(presentation.progress)
            XCTAssertFalse(presentation.goalReached)
        }
    }
    func testCurrentGoalCanReachWhileStaleReadingCannotEarnMoment() {
        XCTAssertTrue(steps(reading(count: 8_124)).goalReached)
        XCTAssertFalse(steps(reading(count: 8_124), stale: true).goalReached)
        XCTAssertEqual(steps(reading(count: 8_124), stale: true).progress, 1)
    }
    func testPriorDayAndFutureRefreshDoNotBecomeToday() {
        XCTAssertNil(steps(reading(7)).reading)
        let future = StepsDayReading(readAt: date(8, hour: 21), dayStart: date(8, hour: 0), totalSteps: 10,
                                    distanceMeters: 1, hours: [])
        XCTAssertNil(steps(future).reading)
    }
    func testHoursKeepObservedZeroAndOmitUnreadableOrOtherDay() {
        let presentation = steps(reading(hours: [(date(7), 1), (date(8, hour: 8), 0), (date(8, hour: 9), nil), (date(8, hour: 10), 20)]))
        XCTAssertEqual(presentation.hours.map(\.count), [0, 20])
    }
    func testDSTDayUsesCalendarLengthRatherThanTwentyFourHours() throws {
        let now = date(25, hour: 12)
        let reading = StepsDayReading(readAt: now, dayStart: date(25, hour: 0), totalSteps: 0, distanceMeters: 0, hours: [])
        let presentation = StepsDayPresentation(reading: reading, now: now, calendar: calendar, dailyGoal: nil, isStale: false)
        XCTAssertEqual(try XCTUnwrap(presentation.dayInterval).duration, 25 * 3_600)
    }
    func testSleepZeroIsAnObservedDuration() {
        let presentation = sleep(context(duration: 0))
        XCTAssertEqual(presentation.duration, 0)
        XCTAssertEqual(presentation.periodKey, "Last night")
    }
    func testUnreadableAndInvalidSleepRemainAbsent() {
        for duration in [nil, -1, .infinity, .nan] as [Double?] {
            XCTAssertNil(sleep(context(duration: duration)).duration)
        }
    }
    func testRetainedSleepCurrentLabelRequiresEveryQualification() {
        XCTAssertTrue(sleep(context()).isCurrent)
        XCTAssertEqual(sleep(context(), stale: true).periodKey, "Last available sleep")
        XCTAssertFalse(sleep(context(day: 7)).isCurrent)
        XCTAssertFalse(sleep(context(refreshed: date(8, hour: 21))).isCurrent)
        XCTAssertFalse(sleep(context(), status: .notConnected).isCurrent)
    }
    func testPhotoPairPreservesReversedSelectedIdentityAndTruthfulLabels() throws {
        let older = photo(1, day: 1), newer = photo(2, day: 8)
        let pair = try XCTUnwrap(ProgressPhotoPair.resolve(records: [older, newer], firstID: newer.id, secondID: older.id))
        XCTAssertEqual(pair.first.id, newer.id)
        XCTAssertEqual(pair.second.id, older.id)
        XCTAssertEqual(pair.labelKey(firstSlot: true), "Later photo")
        XCTAssertEqual(pair.labelKey(firstSlot: false), "Earlier photo")
    }
    func testEqualTimestampPhotosRemainDistinctWithNeutralLabels() throws {
        let first = photo(1, day: 8), second = photo(2, day: 8)
        let pair = try XCTUnwrap(ProgressPhotoPair.resolve(records: [second, first], firstID: first.id, secondID: second.id))
        XCTAssertNotEqual(pair.first.id, pair.second.id)
        XCTAssertEqual(pair.labelKey(firstSlot: true), "First photo")
        XCTAssertEqual(pair.labelKey(firstSlot: false), "Second photo")
    }
    func testDeletedPhotoSelectionFallsBackToDistinctSurvivingRecords() throws {
        let first = photo(1, day: 1), second = photo(2, day: 8)
        let pair = try XCTUnwrap(ProgressPhotoPair.resolve(records: [first, second], firstID: UUID(), secondID: first.id))
        XCTAssertNotEqual(pair.first.id, pair.second.id)
        XCTAssertNil(ProgressPhotoPair.resolve(records: [first], firstID: first.id, secondID: first.id))
    }
}
