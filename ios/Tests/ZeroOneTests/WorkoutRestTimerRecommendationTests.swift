import XCTest
@testable import ZeroOne

final class WorkoutRestTimerRecommendationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private enum Pattern: Equatable { case legacy, skip, pause, extend, recovered, restarted, clock, omitted, late, open, overlapping, future }

    func testRelativeIncomingSignatureIgnoresSessionDatesAndSetIdentities() throws {
        let a = history(days: -1, reps: 8)
        let b = history(days: -8, reps: 10)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.exercises?.first?.completedSets.first?.id, b.exercises?.first?.completedSets.first?.id)
        XCTAssertEqual(try contexts(a), try contexts(b))
        XCTAssertEqual(try contexts(a).first, .sessionStart)
        XCTAssertTrue(try assess([a, b, history(days: -15, reps: 12)]).hasRepeatedComparableDecline)
    }

    func testKnownAndUnknownIntervalsCannotBeComparedAtTheSamePosition() throws {
        let records = [history(days: -1, reps: 8), history(days: -8, reps: 10, pattern: .legacy),
                       history(days: -15, reps: 12, pattern: .legacy)]
        let value = try assess(records)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 2)
    }

    func testChangedSkipPauseAndExtensionContextsBlockADeclineComparison() throws {
        for pattern in [Pattern.pause, .extend] {
            let value = try assess([history(days: -1, reps: 8, pattern: pattern),
                                   history(days: -8, reps: 10), history(days: -15, reps: 12)])
            XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
        }
        let shorter = history(days: -1, reps: 8, skipAt: 30)
        XCTAssertFalse(try assess([shorter, history(days: -8, reps: 10), history(days: -15, reps: 12)]).hasRepeatedComparableDecline)
    }

    func testEveryGapAndUnclosedJournalIsUnavailableRatherThanLegacyUnknown() throws {
        for pattern in [Pattern.recovered, .restarted, .clock, .omitted, .late, .open] {
            let record = history(days: -1, reps: 8, pattern: pattern)
            XCTAssertEqual(try contexts(record).last, .unavailable)
            XCTAssertFalse(try assess([record, history(days: -8, reps: 10), history(days: -15, reps: 12)]).hasRepeatedComparableDecline)
        }
    }

    func testCrossExerciseHandoffUsesPreviousOccurrencesOutgoingJournal() throws {
        var a = session(days: -1, reps: 8)
        var b = session(days: -8, reps: 10, skipAt: 30)
        let nextPlan = plan(exerciseID: ExerciseIDs.gobletSquat, sets: 1)
        for index in 0..<2 {
            var value = index == 0 ? a : b
            let first = value.exercises[0].completedSets[0]
            let next = CompletedSet(load: Load(40), reps: 8, rir: 2, completedAt: first.completedAt.addingTimeInterval(180),
                isPerSide: false, executionTarget: WorkingSetExecutionTarget(plan: nextPlan))
            value = WorkoutSession(title: value.title, programmeID: value.programmeID,
                exercises: [WorkoutExercise(plan: value.exercises[0].plan, completedSets: [first]),
                            WorkoutExercise(plan: nextPlan, completedSets: [next])], completedAt: next.completedAt)
            if index == 0 { a = value } else { b = value }
        }
        let ca = try XCTUnwrap(WorkoutRestTimerEvidence.incomingContexts(in: WorkoutHistoryEntry(session: a), occurrenceID: nextPlan.id))
        let cb = try XCTUnwrap(WorkoutRestTimerEvidence.incomingContexts(in: WorkoutHistoryEntry(session: b), occurrenceID: nextPlan.id))
        XCTAssertEqual(ca.count, 1)
        XCTAssertNotEqual(ca, cb)
        XCTAssertNotEqual(ca.first, .sessionStart)
    }

    func testFinalOutgoingJournalIsNotAnIncomingCauseOfItsOwnPerformance() throws {
        let value = session(days: -1, reps: 8)
        let baseline = try contexts(WorkoutHistoryEntry(session: value))
        var exercises = value.exercises
        exercises[0].completedSets[1].restTimerObservation = nil
        let changed = WorkoutSession(title: value.title, programmeID: value.programmeID, exercises: exercises, completedAt: value.completedAt)
        XCTAssertEqual(try contexts(WorkoutHistoryEntry(session: changed)), baseline)
    }

    func testLegacyComparisonRetainsExplicitUnknownQualification() throws {
        let value = try assess([history(days: -1, reps: 8, pattern: .legacy),
                               history(days: -8, reps: 10, pattern: .legacy), history(days: -15, reps: 12, pattern: .legacy)])
        let trend = try XCTUnwrap(value.comparableStrengthTrends.first)
        XCTAssertTrue(trend.hasRepeatedDecline)
        XCTAssertTrue(trend.hasUnknownIncomingTimerContext)
        XCTAssertEqual(trend.incomingTimerContexts, [.sessionStart, .unknown])
    }

    func testAggregationKeepsUnknownNotScheduledCompleteAndPartialSeparate() throws {
        let value = try assess([history(days: -1, reps: 8), history(days: -2, reps: 8, pattern: .legacy),
                               history(days: -3, reps: 8, pattern: .recovered)])
        let coverage = try XCTUnwrap(value.currentStrength?.restTimers)
        XCTAssertEqual(coverage.unknownSetCount, 2)
        XCTAssertEqual(coverage.notScheduledSetCount, 2)
        XCTAssertEqual(coverage.completeObservationCount, 1)
        XCTAssertEqual(coverage.partialObservationCount, 1)
        XCTAssertEqual(value.currentStrength?.recordedSetCount, 6)
    }

    func testSummaryOnlyRecordsKeepUnknownTimerCounts() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history(days: -1, reps: 8))) as? [String: Any])
        object.removeValue(forKey: "exercises")
        object.removeValue(forKey: "executionCompletionConfirmedAt")
        let summary = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        let value = try assess([summary])
        XCTAssertEqual(value.currentStrength?.restTimers.unknownSetCount, 2)
        XCTAssertEqual(value.currentStrength?.restTimers.completeObservationCount, 0)
    }

    func testOverlapAndFutureObservationCannotQualifyTheLatestExposure() throws {
        let overlapping = history(days: -1, reps: 8, pattern: .overlapping)
        XCTAssertEqual(try contexts(overlapping).last, .unavailable)
        XCTAssertEqual(try assess([overlapping]).currentStrength?.recordedSetCount, 2)
        XCTAssertEqual(try assess([overlapping]).currentStrength?.restTimers.partialObservationCount, 1)
        XCTAssertEqual(try assess([overlapping]).currentStrength?.restTimers.completeObservationCount, 0)
        let future = history(days: -1, reps: 8, pattern: .future)
        XCTAssertEqual(try assess([future]).excludedStrengthRecordCount, 1)
        XCTAssertFalse(WorkoutRestTimerEvidence.validStoredObservation(for: try XCTUnwrap(future.exercises?.first?.completedSets.first), finishedAt: future.completedAt))
    }

    func testChangedNewestContextCannotFallBackToThreeOlderMatchingExposures() throws {
        let value = try assess([history(days: -1, reps: 6, pattern: .pause), history(days: -4, reps: 8),
                               history(days: -11, reps: 10), history(days: -18, reps: 12)])
        XCTAssertFalse(value.hasRepeatedComparableDecline)
        XCTAssertTrue(value.comparableStrengthTrends.isEmpty)
    }

    func testActualWellbeingHoldUsesQualifiedTimerComparisonAndKeepsSymptomsIndependent() {
        let older = [history(days: -8, reps: 10), history(days: -15, reps: 12)]
        let comparable = wellbeing([history(days: -1, reps: 8)] + older)
        XCTAssertTrue(comparable.holdsAutomaticProgression)
        let changed = wellbeing([history(days: -1, reps: 8, pattern: .pause)] + older)
        XCTAssertFalse(changed.holdsAutomaticProgression)
        XCTAssertFalse(changed.recommendations.flatMap(\.evidence).contains(.repeatedComparablePerformanceDecline))
        XCTAssertTrue(wellbeing([history(days: -1, reps: 8, pattern: .pause)] + older, soreness: .severe).holdsAutomaticProgression)
        XCTAssertEqual(wellbeing([history(days: -1, reps: 8, pattern: .pause)] + older, pain: true).recommendations.first?.demand, .pauseForSymptoms)
    }

    private func plan(exerciseID: ExerciseID = ExerciseIDs.barbellBenchPress, sets: Int = 2) -> ExercisePlan {
        ExercisePlan(exerciseID: exerciseID, name: "Synthetic", targetLoad: Load(40), targetReps: RepRange(8, 12),
            plannedSetCount: sets, restSeconds: 120, previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 12))
    }

    private func session(days: Int, reps: Int, pattern: Pattern = .skip, skipAt: TimeInterval = 60) -> WorkoutSession {
        let start = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!.addingTimeInterval(3_600)
        let p = plan()
        var first = CompletedSet(load: Load(40), reps: reps, rir: 2, completedAt: start, isPerSide: false, executionTarget: WorkingSetExecutionTarget(plan: p))
        let deadline = start.addingTimeInterval(120)
        var observation = WorkoutRestTimerObservation(afterSetID: first.id, at: start, deadline: deadline)
        var currentDeadline = deadline
        switch pattern {
        case .pause:
            observation.record(.paused, at: start.addingTimeInterval(10), deadline: deadline, remainingSeconds: 110)
            currentDeadline = start.addingTimeInterval(140)
            observation.record(.resumed, at: start.addingTimeInterval(30), deadline: currentDeadline, remainingSeconds: 110)
        case .extend:
            currentDeadline = start.addingTimeInterval(150)
            observation.record(.extended, at: start.addingTimeInterval(20), deadline: currentDeadline, remainingSeconds: 130)
        case .recovered:
            observation.record(.recovered, at: start.addingTimeInterval(10), deadline: deadline, remainingSeconds: 110)
        case .restarted:
            currentDeadline = start.addingTimeInterval(130)
            observation.record(.restartedAfterSaveFailure, at: start.addingTimeInterval(10), deadline: currentDeadline, remainingSeconds: 120)
        case .clock:
            observation.record(.recovered, at: start.addingTimeInterval(-1), deadline: deadline, remainingSeconds: 121)
        case .omitted:
            for index in 1...600 { observation.record(.recovered, at: start.addingTimeInterval(Double(index) / 20), deadline: deadline) }
        default: break
        }
        if pattern == .late { observation.record(.expired, at: start.addingTimeInterval(130), deadline: deadline) }
        else if pattern != .open {
            let closedAt: TimeInterval = pattern == .future ? 240 : pattern == .overlapping ? 200 : skipAt
            observation.record(.skipped, at: start.addingTimeInterval(closedAt), deadline: currentDeadline)
        }
        if pattern != .legacy { first.restTimerObservation = observation }
        var second = CompletedSet(load: Load(40), reps: reps, rir: 2, completedAt: start.addingTimeInterval(180), isPerSide: false, executionTarget: WorkingSetExecutionTarget(plan: p))
        if pattern != .legacy { second.restTimerObservation = .init(afterSetID: second.id, at: second.completedAt, deadline: nil) }
        // Give overlapping journals a valid finished-session bound while keeping
        // their closure later than the following set's recorded completion.
        let finished = start.addingTimeInterval(pattern == .overlapping ? 210 : 180)
        var value = WorkoutSession(title: "Timer-qualified comparison", programmeID: .zeroOneBuild,
            exercises: [WorkoutExercise(plan: p, completedSets: [first, second])], completedAt: finished)
        XCTAssertTrue(value.confirmCompletedExecution(at: finished.addingTimeInterval(30)))
        return value
    }

    private func history(days: Int, reps: Int, pattern: Pattern = .skip, skipAt: TimeInterval = 60) -> WorkoutHistoryEntry {
        WorkoutHistoryEntry(session: session(days: days, reps: reps, pattern: pattern, skipAt: skipAt))
    }
    private func contexts(_ entry: WorkoutHistoryEntry) throws -> [WorkoutIncomingTimerContext] {
        let occurrence = try XCTUnwrap(entry.exercises?.first)
        return try XCTUnwrap(WorkoutRestTimerEvidence.incomingContexts(in: entry, occurrenceID: occurrence.id))
    }
    private func assess(_ history: [WorkoutHistoryEntry]) throws -> TrainingWorkloadAssessment {
        try XCTUnwrap(TrainingWorkloadEvidence.assess(strength: history, outdoor: [], at: now, calendar: calendar))
    }
    private func wellbeing(_ history: [WorkoutHistoryEntry], soreness: RecoverySoreness = .none, pain: Bool = false) -> WellbeingAssessment {
        let report = RecoveryCheckIn(id: UUID(), day: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier,
            reportedAt: now, energy: .low, soreness: soreness, sleepHours: nil, hasNewOrWorseningPain: pain,
            feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: nil)
        return WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar, strengthHistory: history,
            outdoorHistory: [], recoveryCheckIns: [report], meals: [], nutritionReviews: [], chosenFoodGoal: nil,
            hydration: nil, healthSleep: nil))
    }
}
