import Foundation
import XCTest
@testable import ZeroOne

final class HydrationAndSmartPromptTests: XCTestCase {
    func testHydrationProgressAndRemainingIntake() {
        var hydration = HydrationState(currentMilliliters: 750, goalMilliliters: 2_500)

        hydration.add(500)

        XCTAssertEqual(hydration.currentMilliliters, 1_250)
        XCTAssertEqual(hydration.remainingMilliliters, 1_250)
        XCTAssertEqual(hydration.progress, 0.5, accuracy: 0.001)
    }

    func testHydrationProgressCapsAtOne() {
        var hydration = HydrationState(currentMilliliters: 2_400, goalMilliliters: 2_500)

        hydration.add(500)

        XCTAssertEqual(hydration.currentMilliliters, 2_900)
        XCTAssertEqual(hydration.remainingMilliliters, 0)
        XCTAssertEqual(hydration.progress, 1, accuracy: 0.001)
    }

    func testHydrationTrendUsesLiveCurrentDayIntake() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 28)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        var hydration = HydrationState(
            currentMilliliters: 750,
            recentHistory: [HydrationDailyRecord(date: yesterday, consumedMilliliters: 1_900)]
        )

        hydration.add(250)

        let trend = hydration.recentIntake(endingOn: today, calendar: calendar)
        XCTAssertEqual(trend.count, 2)
        XCTAssertEqual(trend.last?.consumedMilliliters, 1_000)
        XCTAssertTrue(calendar.isDate(trend.last?.date ?? .distantPast, inSameDayAs: today))
    }

    func testSmartPromptsPrioritizeRelevantWorkoutWindow() throws {
        let date = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 8, day: 28, hour: 15)
            )
        )
        let service = LocalSmartPromptService()

        let prompts = service.prompts(
            for: SmartPromptContext(
                date: date,
                workoutStatus: .ready,
                hydrationProgress: 0.2,
                hasScheduleGap: true,
                availability: ReportedWorkoutAvailability(minutes: 40, reportedAt: date),
                estimatedUpperMinutes: 35
            )
        )

        XCTAssertEqual(prompts.first?.trigger, .workoutWindow)
        XCTAssertEqual(prompts.first?.action, .openWorkout)
        XCTAssertFalse(prompts.contains { $0.trigger == .hydrationLow }, "A low log is not a hydration requirement")
    }

    func testSmartPromptsStaySilentWhenNoInputNeedsAction() {
        let service = LocalSmartPromptService()
        let prompts = service.prompts(
            for: SmartPromptContext(
                date: Date(timeIntervalSince1970: 1_000),
                workoutStatus: .complete,
                hydrationProgress: 0.8,
                readiness: .normal,
                minutesSinceActivity: 30
            )
        )

        XCTAssertTrue(prompts.isEmpty)
    }
}
