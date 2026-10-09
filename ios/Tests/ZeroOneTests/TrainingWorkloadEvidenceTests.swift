import XCTest
@testable import ZeroOne

final class TrainingWorkloadEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!.addingTimeInterval(3_600)
    }

    func testUnavailableAndKnownEmptySourcesRemainDifferent() throws {
        let unknown = try assessment(strength: nil, outdoor: nil)
        XCTAssertNil(unknown.currentStrength)
        XCTAssertNil(unknown.currentOutdoor)
        let empty = try assessment()
        XCTAssertEqual(empty.currentStrength?.recordedSetCount, 0)
        XCTAssertEqual(empty.currentOutdoor?.runs.sessionCount, 0)
        XCTAssertTrue(empty.recordedTrainingDays.isEmpty)
    }

    func testWindowsKeepActualSetsAndEffortSeparateAndCollapseDuplicates() throws {
        let recent = history(at: day(-1), reps: 10, reserve: 1)
        let previous = history(at: day(-8), reps: 10, reserve: nil)
        let value = try assessment(strength: [recent, recent, previous])
        XCTAssertEqual(value.currentStrength?.sessionCount, 1)
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 2)
        XCTAssertEqual(value.currentStrength?.effortReportedSetCount, 2)
        XCTAssertEqual(value.currentStrength?.lowReserveSetCount, 2)
        XCTAssertEqual(value.previousStrength?.recordedSetCount, 2)
        XCTAssertEqual(value.previousStrength?.effortReportedSetCount, 0)
        XCTAssertEqual(value.recordedTrainingDays.count, 1)
    }

    func testSummaryOnlyHistoryHasCountsButNoInventedEffortOrTrend() throws {
        let original = history(at: day(-1), reps: 10)
        let summary = try changed(original, { $0.removeValue(forKey: "exercises"); $0.removeValue(forKey: "executionCompletionConfirmedAt") })
        let value = try assessment(strength: [summary])
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 2)
        XCTAssertEqual(value.currentStrength?.detailedSetCount, 0)
        XCTAssertEqual(value.currentStrength?.summaryOnlySessionCount, 1)
        XCTAssertEqual(value.currentStrength?.effortReportedSetCount, 0)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
    }

    func testConflictingFutureAndCorruptSourcesCannotInflateRecordedWork() throws {
        let original = history(at: day(-1), reps: 10)
        let conflicting = try changed(original) { $0["title"] = "Conflicting title" }
        let corrupt = try changed(history(at: day(-2), reps: 10)) { $0["completedSetCount"] = Int.max }
        let future = history(at: now.addingTimeInterval(60), reps: 10)
        let value = try assessment(strength: [original, conflicting, corrupt, future])
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 0)
        XCTAssertEqual(value.excludedStrengthRecordCount, 3)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
    }

    func testTimedSetsNeverBecomeRepetitionsOrEffortReports() throws {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Synthetic timed work", targetLoad: Load(0),
            targetReps: RepRange(1, 1), plannedSetCount: 1, restSeconds: 120, previousPerformance: [],
            targetPrescription: .init(unit: .seconds, lowerBound: 30, upperBound: 30))
        let set = CompletedSet(load: Load(0), reps: 0, completedAt: day(-1), durationSeconds: 30,
            isPerSide: false, executionTarget: WorkingSetExecutionTarget(plan: plan))
        let entry = WorkoutHistoryEntry(session: WorkoutSession(title: "Timed", exercises: [WorkoutExercise(plan: plan, completedSets: [set])],
            completedAt: day(-1)))
        let value = try assessment(strength: [entry])
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 1)
        XCTAssertEqual(value.currentStrength?.repetitionSetCount, 0)
        XCTAssertEqual(value.currentStrength?.effortReportedSetCount, 0)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
    }

    func testPerformedSetIdentityCannotBeReusedAcrossDifferentSessions() throws {
        let original = history(at: day(-1), reps: 10)
        let reused = try changed(original) { $0["id"] = UUID().uuidString }
        let value = try assessment(strength: [original, reused])
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 0)
        XCTAssertEqual(value.excludedStrengthRecordCount, 2)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
        // An exact repeated record is still one acknowledged session.
        XCTAssertEqual(try assessment(strength: [original, original]).currentStrength?.recordedSetCount, 2)
    }

    func testRunsAndWalksRemainSeparateWithUnknownDistanceCoverage() throws {
        let run = outdoor(at: day(-1), kind: .run, active: 1_800)
        let walk = outdoor(at: day(-2), kind: .walk, active: 900)
        let previous = outdoor(at: day(-8), kind: .run, active: 600)
        let value = try assessment(outdoor: [run, run, walk, previous])
        XCTAssertEqual(value.currentOutdoor?.runs.unpausedSeconds, 1_800)
        XCTAssertEqual(value.currentOutdoor?.walks.unpausedSeconds, 900)
        XCTAssertEqual(value.previousOutdoor?.runs.unpausedSeconds, 600)
        XCTAssertEqual(value.currentOutdoor?.runs.unknownDistanceSessionCount, 1)
        XCTAssertEqual(value.currentOutdoor?.runs.completeDistanceSessionCount, 0)
        XCTAssertEqual(value.recordedTrainingDays.count, 1)
    }

    func testMonotonicTimeSurvivesWallClockDiscrepancyWithoutClaimingATrainingDay() throws {
        let run = outdoor(at: day(-1), kind: .run, active: 1_800, wallSeconds: 10)
        XCTAssertTrue(run.isValid)
        let value = try assessment(outdoor: [run])
        XCTAssertEqual(value.currentOutdoor?.runs.unpausedSeconds, 1_800)
        XCTAssertEqual(value.currentOutdoor?.runs.clockDiscrepancySessionCount, 1)
        XCTAssertTrue(value.recordedTrainingDays.isEmpty)
    }

    func testRepeatedComparableDeclineNeedsThreeFreshConfirmedExposures() throws {
        let value = try assessment(strength: decliningHistory())
        let trend = try XCTUnwrap(value.comparableStrengthTrends.first)
        XCTAssertEqual(trend.recordedRepetitions, [24, 20, 16])
        XCTAssertTrue(trend.hasRepeatedDecline)
        XCTAssertEqual(trend.sourceSessionIDs.count, 3)
        let two = try assessment(strength: Array(decliningHistory().prefix(2)))
        XCTAssertFalse(two.hasRepeatedComparableDecline)
        let stale = try assessment(strength: [history(at: day(-9), reps: 8), history(at: day(-16), reps: 10), history(at: day(-23), reps: 12)])
        XCTAssertFalse(stale.hasRepeatedComparableDecline)
    }

    func testUnknownEffortChangedLoadRestUnitAndTargetPreventComparison() throws {
        let older = [history(at: day(-8), reps: 10), history(at: day(-15), reps: 12)]
        let changedLatest = [
            history(at: day(-1), reps: 8, reserve: nil),
            history(at: day(-1), reps: 8, load: Load(42.5)),
            history(at: day(-1), reps: 8, load: Load(40, unit: .pounds)),
            history(at: day(-1), reps: 8, rest: 180),
            history(at: day(-1), reps: 8, lowerTarget: 6),
            history(at: day(-1), reps: 8, reserve: 1)
        ]
        for latest in changedLatest {
            XCTAssertFalse(try assessment(strength: [latest] + older).hasRepeatedComparableDecline)
        }
    }

    func testNewerUnconfirmedUnknownOrPartialExposureIsABarrier() throws {
        let older = [history(at: day(-8), reps: 10), history(at: day(-15), reps: 12)]
        let unconfirmed = history(at: day(-1), reps: 8, confirmed: false)
        XCTAssertFalse(try assessment(strength: [unconfirmed] + older).hasRepeatedComparableDecline)
        let summary = try changed(unconfirmed) { $0.removeValue(forKey: "exercises") }
        XCTAssertFalse(try assessment(strength: [summary] + older).hasRepeatedComparableDecline)
        let partial = history(at: day(-1), reps: 8, confirmed: false, performedSets: 1)
        XCTAssertEqual(partial.executionCompleteness, .partial)
        XCTAssertFalse(try assessment(strength: [partial] + older).hasRepeatedComparableDecline)
    }

    func testTrendAloneDoesNotHoldButCurrentLowEnergyCanHoldAutomaticIncreases() {
        let history = decliningHistory()
        let trendOnly = wellbeing(history: history)
        XCTAssertEqual(trendOnly.recommendations.first?.demand, .checkIn)
        XCTAssertFalse(trendOnly.holdsAutomaticProgression)
        let low = wellbeing(history: history, energy: .low)
        XCTAssertTrue(low.holdsAutomaticProgression)
        XCTAssertTrue(low.recommendations.flatMap(\.evidence).contains(.repeatedComparablePerformanceDecline))
        XCTAssertTrue(low.recommendations.first?.message.detailKey.contains("does not diagnose") == true)
        let usual = wellbeing(history: history, energy: .usual)
        XCTAssertFalse(usual.holdsAutomaticProgression)
    }

    func testIncompleteFoodLogsCannotTurnWorkloadIntoCalculatedUnderFuelling() {
        let result = wellbeing(history: decliningHistory(), energy: .low)
        XCTAssertFalse(result.recommendations.contains { $0.kind == .fuelling })
        XCTAssertEqual(result.reviewedNutritionDays, 0)
        XCTAssertNotNil(result.workload)
    }

    func testDeclineWithSorenessDoesNotInventLowEnergyInTheMessage() {
        let result = wellbeing(history: decliningHistory(), energy: .usual, soreness: .severe)
        XCTAssertTrue(result.holdsAutomaticProgression)
        XCTAssertFalse(result.recommendations.flatMap(\.evidence).contains(.reportedFatigue))
        XCTAssertFalse(result.recommendations.first?.message.detailKey.contains("low energy") == true)
        XCTAssertTrue(result.recommendations.first?.message.detailKey.contains("current recovery concerns") == true)
    }

    private func assessment(strength: [WorkoutHistoryEntry]? = [], outdoor: [OutdoorActivityRecord]? = []) throws -> TrainingWorkloadAssessment {
        try XCTUnwrap(TrainingWorkloadEvidence.assess(strength: strength, outdoor: outdoor, at: now, calendar: calendar))
    }

    private func decliningHistory() -> [WorkoutHistoryEntry] {
        [history(at: day(-1), reps: 8), history(at: day(-8), reps: 10), history(at: day(-15), reps: 12)]
    }

    private func history(at date: Date, reps: Int, reserve: Int? = 2, load: Load = Load(40),
                         rest: TimeInterval = 120, lowerTarget: Int = 8, confirmed: Bool = true,
                         performedSets: Int = 2) -> WorkoutHistoryEntry {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench", targetLoad: load,
            targetReps: RepRange(lowerTarget, 12), plannedSetCount: 2, restSeconds: rest, previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: lowerTarget, upperBound: 12))
        let sets = (0 ..< performedSets).map { index in
            CompletedSet(load: load, reps: reps, rir: reserve, completedAt: date.addingTimeInterval(Double(index) * 121),
                isPerSide: false, executionTarget: WorkingSetExecutionTarget(plan: plan))
        }
        var session = WorkoutSession(title: "Comparable synthetic training", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: plan, completedSets: sets)], completedAt: sets.last?.completedAt ?? date)
        if confirmed { XCTAssertTrue(session.confirmCompletedExecution(at: date.addingTimeInterval(300))) }
        return WorkoutHistoryEntry(session: session)
    }

    private func outdoor(at date: Date, kind: OutdoorActivityKind, active: TimeInterval, wallSeconds: TimeInterval? = nil) -> OutdoorActivityRecord {
        let finished = date.addingTimeInterval(wallSeconds ?? active)
        return OutdoorActivityRecord(checkpoint: OutdoorActivityCheckpoint(kind: kind, trackingMode: .timerOnly,
            startedAt: date, checkpointedAt: finished, confirmedActiveSeconds: active, phase: .readyToSave,
            finishedAt: finished), finishedAt: finished)
    }

    private func changed(_ entry: WorkoutHistoryEntry, _ edit: (inout [String: Any]) -> Void) throws -> WorkoutHistoryEntry {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func wellbeing(history: [WorkoutHistoryEntry], energy: RecoveryEnergy? = nil,
                           soreness: RecoverySoreness = .none) -> WellbeingAssessment {
        let report = energy.map { RecoveryCheckIn(id: UUID(), day: calendar.startOfDay(for: now),
            timeZoneID: calendar.timeZone.identifier, reportedAt: now, energy: $0, soreness: soreness,
            sleepHours: nil, hasNewOrWorseningPain: nil, feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: nil) }
        return WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar, strengthHistory: history,
            outdoorHistory: [], recoveryCheckIns: report.map { [$0] } ?? [], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
    }
}
