import XCTest
@testable import ZeroOne

final class RecommendationArbiterTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-03T15:00:00Z")! }

    private func concern(_ kind: WellbeingRecommendationKind, _ demand: WellbeingDemand) -> WellbeingRecommendation {
        .init(kind: kind, demand: demand, evidence: [.reportedFatigue],
            policyVersion: WellbeingRecommendationEngine.policyVersion, sourceReferences: [])
    }
    private func assessment(_ recommendations: [WellbeingRecommendation], at date: Date? = nil,
                            zone: String? = nil) -> WellbeingAssessment {
        .init(recommendations: recommendations, recordedTrainingDays: 3, reviewedNutritionDays: 2,
            hasCurrentRecoveryReport: true, hasConflictingSleep: false,
            evaluatedAt: date ?? now, timeZoneID: zone ?? calendar.timeZone.identifier)
    }
    private func focus(_ report: WellbeingAssessment?, workout: PromptWorkoutStatus = .ready,
                       at date: Date? = nil) -> RecommendationFocus {
        RecommendationArbiter().focus(at: date ?? now, calendar: calendar,
            workout: workout, wellbeing: report,
            availability: .init(minutes: 60, reportedAt: now), estimatedUpperMinutes: 40,
            progressReviewDue: true)
    }

    func testSymptomsWinOverFuellingTrainingAndProgressForEveryInputOrder() {
        let symptoms = concern(.symptoms, .pauseForSymptoms)
        let fuel = concern(.fuelling, .easeTraining)
        let recovery = concern(.recovery, .easeTraining)
        for rows in [[symptoms, fuel, recovery], [fuel, recovery, symptoms], [recovery, symptoms, fuel]] {
            XCTAssertEqual(focus(assessment(rows)), .wellbeing(symptoms))
            XCTAssertEqual(focus(assessment(rows), workout: .active), .wellbeing(symptoms))
        }
    }

    func testFuellingConcernPrecedesExercisePressureWithoutChangingRecordedWork() {
        let fuel = concern(.fuelling, .easeTraining)
        let report = assessment([concern(.recovery, .easeTraining), fuel])
        XCTAssertEqual(focus(report), .wellbeing(fuel))
        XCTAssertEqual(report.reviewedNutritionDays, 2)
    }

    func testPassiveWaterAndVarietyReviewsDoNotInterruptAnActiveWorkout() {
        let report = assessment([concern(.hydration, .review), concern(.foodVariety, .review)])
        XCTAssertEqual(focus(report, workout: .active), .continueWorkout)
        XCTAssertEqual(focus(report, workout: .complete), .wellbeing(concern(.hydration, .review)))
    }

    func testRecoveryCheckInPrecedesStartingButDoesNotInterruptAnActiveWorkout() {
        let checkIn = concern(.recovery, .checkIn)
        XCTAssertEqual(focus(assessment([checkIn])), .wellbeing(checkIn))
        XCTAssertEqual(focus(assessment([checkIn]), workout: .active), .continueWorkout)
    }

    func testExpiredFutureAndChangedZoneAssessmentsDoNotGovernCurrentTraining() {
        let report = [concern(.fuelling, .easeTraining)]
        for value in [assessment(report, at: now.addingTimeInterval(-601)),
                      assessment(report, at: now.addingTimeInterval(1)),
                      assessment(report, zone: "Europe/Sofia")] {
            XCTAssertEqual(focus(value), .startWorkout(fitsReportedWindow: true))
        }
        let unknownDate = WellbeingAssessment(recommendations: report, recordedTrainingDays: 0,
            reviewedNutritionDays: 0, hasCurrentRecoveryReport: false, hasConflictingSleep: false)
        XCTAssertEqual(focus(unknownDate), .startWorkout(fitsReportedWindow: true))
        XCTAssertFalse(assessment(report, at: now.addingTimeInterval(-60)).isCurrent(
            at: calendar.startOfDay(for: now.addingTimeInterval(86_400)), calendar: calendar))
    }

    func testAReportedWindowNeedsFreshAvailabilityAndAnEstimateThatFits() {
        let arbiter = RecommendationArbiter()
        let cases: [(ReportedWorkoutAvailability?, Int?)] = [
            (nil, 30), (.init(minutes: 20, reportedAt: now), 30),
            (.init(minutes: 40, reportedAt: now.addingTimeInterval(-6 * 3_600 - 1)), 30),
            (.init(minutes: 40, reportedAt: now.addingTimeInterval(1)), 30),
            (.init(minutes: 40, reportedAt: now), nil), (.init(minutes: 1_000, reportedAt: now), 30),
            (.init(minutes: 40, reportedAt: now), -1)
        ]
        for (availability, estimate) in cases {
            XCTAssertEqual(arbiter.focus(at: now, calendar: calendar, workout: .ready, wellbeing: nil,
                availability: availability, estimatedUpperMinutes: estimate), .startWorkout(fitsReportedWindow: false))
        }
    }

    func testLegacyScalarReadinessLowLogAndScheduleGapDoNotInventEvidence() {
        let context = SmartPromptContext(date: now, workoutStatus: .ready,
            hydrationProgress: 0, readiness: .low, minutesSinceActivity: 1_000, hasScheduleGap: true)
        let prompts = LocalSmartPromptService().prompts(for: context)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.trigger, .nextWorkout)
        XCTAssertEqual(prompts.first?.action, .openWorkout)
        XCTAssertNil(LocalZeroOneNotificationSelector().bestNotification(for: .init(date: now,
            workoutStatus: .ready, hydrationProgress: 0, readiness: .low,
            minutesSinceActivity: 1_000, hasScheduleGap: true)))
    }

    func testGenericCheckInDoesNotDisplaceReadyWorkoutOrGenerateAPush() {
        let report = assessment([concern(.checkIn, .review)])
        XCTAssertEqual(focus(report), .startWorkout(fitsReportedWindow: true))
        XCTAssertNil(LocalZeroOneNotificationSelector().bestNotification(for: .init(date: now,
            workoutStatus: .none, wellbeing: report)))
    }

    func testUnknownPolicyAndInvalidClockDoNotBecomeCurrentAdvice() {
        let unknown = WellbeingRecommendation(kind: .fuelling, demand: .easeTraining,
            evidence: [], policyVersion: "future-policy", sourceReferences: [])
        XCTAssertEqual(focus(assessment([unknown])), .startWorkout(fitsReportedWindow: true))
        XCTAssertEqual(focus(nil, at: Date(timeIntervalSinceReferenceDate: .nan)), .none)
    }
}
