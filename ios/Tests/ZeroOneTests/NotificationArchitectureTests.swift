import Foundation
import XCTest
@testable import ZeroOne

final class NotificationArchitectureTests: XCTestCase {
    func testLocalSelectorChoosesHighestPriorityRelevantNotification() throws {
        let date = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 8, day: 28, hour: 15)
            )
        )
        let selector = LocalZeroOneNotificationSelector()

        let notification = selector.bestNotification(
            for: ZeroOneNotificationContext(
                date: date,
                workoutStatus: .ready,
                hydrationProgress: 0.2,
                readiness: .normal,
                hasScheduleGap: true,
                isProgressReviewDue: true,
                availability: ReportedWorkoutAvailability(minutes: 40, reportedAt: date),
                estimatedUpperMinutes: 35
            )
        )

        XCTAssertEqual(notification?.category, .workout)
        XCTAssertEqual(notification?.event, .workoutWindowOpened)
        XCTAssertEqual(notification?.action, .openWorkout)
    }

    func testDeferredSchedulerDoesNotPretendToDeliverNotification() async {
        let scheduler = DeferredZeroOneNotificationScheduler()
        let notification = ZeroOneNotification(
            id: "test",
            category: .hydration,
            event: .hydrationBehindGoal,
            priority: .normal,
            title: "Hydration check",
            body: "Water is behind.",
            action: .openHydration
        )

        let outcome = await scheduler.schedule(
            ZeroOneNotificationScheduleRequest(notification: notification, deliveryDate: .now)
        )

        XCTAssertEqual(outcome, .deferred(reason: "Notification delivery is not configured."))
    }
}
