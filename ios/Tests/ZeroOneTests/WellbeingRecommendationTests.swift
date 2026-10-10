import XCTest
@testable import ZeroOne

final class WellbeingRecommendationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private let now = Date(timeIntervalSince1970: 1_791_024_000) // A fixed instant, never wall-clock evidence.
    private var today: Date { calendar.startOfDay(for: now) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    func testMissingAndPartialFoodLogsCannotEstablishUnderFuelling() throws {
        let meals = [meal(on: day(-1), calories: 300), meal(on: day(-2), calories: 300)]
        let reviews = try [-1, -2].map { try review(day: day($0), meals: meals, coverage: .partial) }
        let result = assess(meals: meals, reviews: reviews, goal: 2_500, report: report(energy: .low), training: [-1, -2])
        XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
        XCTAssertFalse(result.holdsAutomaticProgression)
        XCTAssertEqual(result.reviewedNutritionDays, 0)
        let unavailable = assess(meals: nil, reviews: reviews, goal: 2_500, report: report(energy: .low), training: [-1, -2])
        XCTAssertFalse(unavailable.recommendations.contains { $0.kind == .fuelling })
    }

    func testRepeatedCompleteTrainingDayDiscrepancyWithLowEnergyHoldsIncreases() throws {
        let meals = [meal(on: day(-1), calories: 900), meal(on: day(-2), calories: 1_100)]
        let reviews = try [-1, -2].map { try review(day: day($0), meals: meals, goal: 2_500) }
        let result = assess(meals: meals, reviews: reviews, goal: 2_500, report: report(energy: .low), training: [-1, -2])
        let recommendation = try XCTUnwrap(result.recommendations.first)
        XCTAssertEqual(recommendation.kind, .fuelling)
        XCTAssertTrue(recommendation.evidence.contains(.completeFoodLogsBelowChosenGoal))
        XCTAssertTrue(result.holdsAutomaticProgression)
        XCTAssertEqual(result.reviewedNutritionDays, 2)
        // A manually chosen goal is not a diagnosis of low energy availability.
        XCTAssertEqual(recommendation.sourceReferences, ["FUEL-2023"])
    }

    func testCurrentGoalCannotCreateHistoricalDiscrepancies() throws {
        let meals = [-1, -2].map { meal(on: day($0), calories: 2_000) }
        let reviews = try [-1, -2].map { try review(day: day($0), meals: meals, goal: 2_000) }
        for currentGoal in [nil, 1_000, 2_000, 3_000] as [Int?] {
            let result = assess(meals: meals, reviews: reviews, goal: currentGoal,
                report: report(energy: .low), training: [-1, -2])
            XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
            XCTAssertFalse(result.holdsAutomaticProgression)
        }
    }

    func testChangedOrRemovedCurrentGoalCannotEraseReportedDayComparison() throws {
        let meals = [-1, -2].map { meal(on: day($0), calories: 2_000) }
        let reviews = try [-1, -2].map { try review(day: day($0), meals: meals, goal: 3_000) }
        for currentGoal in [nil, 1_000, 3_000, 5_000] as [Int?] {
            let result = assess(meals: meals, reviews: reviews, goal: currentGoal,
                report: report(energy: .low), training: [-1, -2])
            XCTAssertTrue(result.recommendations.contains { $0.kind == .fuelling })
            XCTAssertTrue(result.holdsAutomaticProgression)
        }
    }

    func testEachCompletedDayUsesItsOwnReportedGoal() throws {
        let meals = [-1, -2].map { meal(on: day($0), calories: 2_000) }
        let reviews = [try review(day: day(-1), meals: meals, goal: 3_000),
                       try review(day: day(-2), meals: meals, goal: 2_000)]
        let result = assess(meals: meals, reviews: reviews, goal: 5_000,
            report: report(energy: .low), training: [-1, -2])
        XCTAssertEqual(result.reviewedNutritionDays, 2)
        XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
    }

    func testUnknownHistoricalGoalNeverUsesTodaysGoalAsAFallback() throws {
        let meals = [-1, -2].map { meal(on: day($0), calories: 900) }
        let reviews = [try review(day: day(-1), meals: meals, goal: 2_500),
                       try review(day: day(-2), meals: meals)]
        let result = assess(meals: meals, reviews: reviews, goal: 2_500,
            report: report(energy: .low), training: [-1, -2])
        XCTAssertEqual(result.reviewedNutritionDays, 2)
        XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
    }

    func testInvalidReportedGoalsAreNotQualifiedEvidence() throws {
        let meals = [-1, -2].map { meal(on: day($0), calories: 900) }
        let reviews = [try review(day: day(-1), meals: meals, goal: 499),
                       try review(day: day(-2), meals: meals, goal: Int.max)]
        XCTAssertFalse(reviews.allSatisfy(\.isStructurallyValid))
        let result = assess(meals: meals, reviews: reviews, goal: 2_500,
            report: report(energy: .low), training: [-1, -2])
        XCTAssertEqual(result.reviewedNutritionDays, 0)
        XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
    }

    func testChangingDeletingOrAddingAMealInvalidatesCompleteDayConfirmation() throws {
        let meal = meal(on: day(-1), calories: 500)
        let review = try review(day: day(-1), meals: [meal])
        XCTAssertTrue(review.isUsable(entries: [meal], at: now, calendar: calendar))
        let edited = NutritionEntry(id: meal.id, title: meal.title, calories: 800,
            proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil, loggedAt: meal.loggedAt)
        XCTAssertFalse(review.isUsable(entries: [edited], at: now, calendar: calendar))
        XCTAssertFalse(review.isUsable(entries: [], at: now, calendar: calendar))
        XCTAssertFalse(review.isUsable(entries: [meal, self.meal(on: day(-1), calories: 100)], at: now, calendar: calendar))
    }

    func testCurrentDayAndFutureReviewsAreExcluded() throws {
        let meals = [meal(on: today, calories: 500)]
        let current = try review(day: today, meals: meals)
        XCTAssertFalse(current.isUsable(entries: meals, at: now, calendar: calendar))
        let future = try review(day: day(-1), meals: [], reviewedAt: now.addingTimeInterval(60))
        XCTAssertFalse(future.isUsable(entries: [], at: now, calendar: calendar))
    }

    func testTrainingDaysAloneAskWithoutDiagnosingOrHoldingProgression() throws {
        let result = assess(training: [-1, -2, -3])
        let recommendation = try XCTUnwrap(result.recommendations.first)
        XCTAssertEqual(recommendation.kind, .recovery)
        XCTAssertEqual(recommendation.demand, .checkIn)
        XCTAssertFalse(result.holdsAutomaticProgression)
        XCTAssertFalse(result.hasCurrentRecoveryReport)
    }

    func testSymptomsOutrankFuellingAndRecoveryAndStaleReportsDoNotHold() throws {
        let current = report(energy: .low, soreness: .severe, pain: true)
        let result = assess(report: current, training: [-1, -2, -3])
        XCTAssertEqual(result.recommendations.first?.kind, .symptoms)
        XCTAssertTrue(result.holdsAutomaticProgression)
        let stale = report(energy: .low, soreness: .severe, pain: true, at: day(-1).addingTimeInterval(3_600))
        let staleResult = assess(report: stale)
        XCTAssertFalse(staleResult.holdsAutomaticProgression)
        let future = report(energy: .low, pain: true, at: now.addingTimeInterval(1))
        XCTAssertFalse(assess(report: future).holdsAutomaticProgression)
    }

    func testConflictingSleepIsExcludedRatherThanAveraged() {
        let result = assess(report: report(sleep: 4), sleep: RecoverySleepObservation(hours: 9, refreshedAt: now, day: today))
        XCTAssertTrue(result.hasConflictingSleep)
        XCTAssertFalse(result.recommendations.flatMap(\.evidence).contains(.shortSleep))
        XCTAssertFalse(result.holdsAutomaticProgression)
    }

    func testLowWaterLogDoesNotDiagnoseDehydrationOrRecommendCatchUpVolume() {
        let result = assess(report: report(), hydration: WellbeingHydrationObservation(
            loggedMilliliters: 0, storedGoalMilliliters: 5_000, day: today))
        XCTAssertFalse(result.recommendations.contains { $0.kind == .hydration })
        let thirsty = assess(report: report(thirst: true))
        XCTAssertEqual(thirsty.recommendations.first?.kind, .hydration)
        XCTAssertFalse(thirsty.holdsAutomaticProgression)
    }

    func testFoodVarietyRequiresExplicitCompletedGroupReviewsNotMacroTotals() throws {
        let meals = [-1, -2, -3].map { meal(on: day($0), calories: 2_000) }
        let unreviewed = try [-1, -2, -3].map { try review(day: day($0), meals: meals) }
        XCTAssertFalse(assess(meals: meals, reviews: unreviewed).recommendations.contains { $0.kind == .foodVariety })
        let reviewed = try [-1, -2, -3].map { try review(day: day($0), meals: meals, groups: [.proteinFoods]) }
        XCTAssertTrue(assess(meals: meals, reviews: reviewed).recommendations.contains { $0.kind == .foodVariety })
        let mixed = try [-1, -2, -3].map { try review(day: day($0), meals: meals, groups: Set(DietFoodGroup.allCases)) }
        XCTAssertFalse(assess(meals: meals, reviews: mixed).recommendations.contains { $0.kind == .foodVariety })
    }

    func testTrainingDayLowWaterLogSuggestsCheckingTheLogAndRejectsYesterdayData() {
        let afternoon = today.addingTimeInterval(18 * 3_600)
        let result = assess(training: [0], hydration: WellbeingHydrationObservation(
            loggedMilliliters: 250, storedGoalMilliliters: 2_500, day: today), at: afternoon)
        XCTAssertEqual(result.recommendations.first?.kind, .hydration)
        XCTAssertEqual(result.recommendations.first?.evidence, [.waterLogBelowStoredGoal])
        XCTAssertFalse(result.holdsAutomaticProgression)
        let yesterday = assess(training: [0], hydration: WellbeingHydrationObservation(
            loggedMilliliters: 0, storedGoalMilliliters: 2_500, day: day(-1)), at: afternoon)
        XCTAssertFalse(yesterday.recommendations.contains { $0.kind == .hydration })
    }

    func testDuplicateRunsCountOnceAndConflictingIdentityIsExcluded() {
        let run = outdoor(on: day(-1), kind: .run)
        let duplicated = assess(outdoor: [run, run])
        XCTAssertEqual(duplicated.recordedTrainingDays, 1)
        let conflicting = outdoor(on: day(-2), kind: .run, id: run.id)
        XCTAssertEqual(assess(outdoor: [run, conflicting]).recordedTrainingDays, 0)
        XCTAssertEqual(assess(outdoor: [outdoor(on: day(-1), kind: .walk)]).recordedTrainingDays, 0)
        XCTAssertEqual(assess(outdoor: [outdoor(on: day(1), kind: .run)]).recordedTrainingDays, 0)
    }

    private func assess(meals: [NutritionEntry]? = [], reviews: [NutritionDayReview] = [], goal: Int? = nil,
                        report: RecoveryCheckIn? = nil, training: [Int] = [], outdoor: [OutdoorActivityRecord]? = [],
                        hydration: WellbeingHydrationObservation? = nil, sleep: RecoverySleepObservation? = nil,
                        at date: Date? = nil) -> WellbeingAssessment {
        WellbeingRecommendationEngine().assess(WellbeingContext(asOf: date ?? now, calendar: calendar,
            strengthHistory: training.map { history(on: day($0)) }, outdoorHistory: outdoor,
            recoveryCheckIns: report.map { [$0] } ?? [], meals: meals, nutritionReviews: reviews,
            chosenFoodGoal: goal, hydration: hydration, healthSleep: sleep,
            nutritionGuidance: .init(reportedAt: date ?? now, isAdult: true, needsTailoredNutrition: false,
                hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)))
    }

    private func report(energy: RecoveryEnergy = .usual, soreness: RecoverySoreness = .none,
                        sleep: Double? = nil, pain: Bool? = nil, thirst: Bool? = nil, at date: Date? = nil) -> RecoveryCheckIn {
        let date = date ?? now
        return RecoveryCheckIn(id: UUID(), day: calendar.startOfDay(for: date), timeZoneID: calendar.timeZone.identifier,
            reportedAt: date, energy: energy, soreness: soreness, sleepHours: sleep,
            hasNewOrWorseningPain: pain, feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: thirst)
    }

    private func meal(on date: Date, calories: Int) -> NutritionEntry {
        NutritionEntry(id: UUID(), title: "Meal", calories: calories, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, loggedAt: date.addingTimeInterval(3_600))
    }

    private func review(day: Date, meals: [NutritionEntry], coverage: NutritionLogCoverage = .complete,
                        groups: Set<DietFoodGroup>? = nil, goal: Int? = nil, reviewedAt: Date? = nil) throws -> NutritionDayReview {
        NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier, reviewedAt: reviewedAt ?? now,
            coverage: coverage, mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: meals, on: day, calendar: calendar)),
            reviewedFoodGroups: groups, reportedCalorieGoal: goal,
            energyTargetContext: goal.map { _ in .init(source: .selfChosen, intent: .performance) })
    }

    private func history(on date: Date) -> WorkoutHistoryEntry {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 120, previousPerformance: [])
        let completed = date.addingTimeInterval(3_600)
        return WorkoutHistoryEntry(session: WorkoutSession(title: "Recorded training",
            exercises: [WorkoutExercise(plan: plan, completedSets: [CompletedSet(load: Load(10), reps: 10, completedAt: completed)])],
            completedAt: completed))
    }

    private func outdoor(on date: Date, kind: OutdoorActivityKind, id: UUID = UUID()) -> OutdoorActivityRecord {
        let finished = date.addingTimeInterval(1_800)
        return OutdoorActivityRecord(checkpoint: OutdoorActivityCheckpoint(id: id, kind: kind, trackingMode: .timerOnly,
            startedAt: date, checkpointedAt: finished, confirmedActiveSeconds: 1_800, phase: .readyToSave,
            finishedAt: finished), finishedAt: finished)
    }
}
