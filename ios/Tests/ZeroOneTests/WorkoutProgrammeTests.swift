import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutProgrammeTests: XCTestCase {
    func testGymLibraryContainsOriginalAndTwoArmProgrammes() {
        XCTAssertEqual(
            WorkoutProgrammeLibrary.all.map(\.id),
            [.zeroOneStart, .zeroOneBuild, .zeroOneConsistency, .arms, .biceps]
        )
    }

    func testWorkoutActivityCountsCalendarMonthsWithoutResettingForRestDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        calendar.firstWeekday = 2
        func date(_ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
        }

        let entries = try [
            activityItem(at: date(9, 25)),
            activityItem(at: date(9, 2), plannedSetCount: 2),
            activityItem(at: date(8, 31))
        ]
        let summary = WorkoutActivitySummary(entries: entries, now: try date(9, 26), calendar: calendar)

        XCTAssertEqual(summary.thisWeekCount, 1)
        XCTAssertEqual(summary.thisMonthCount, 2)
        XCTAssertEqual(summary.thisMonthSetCount, 2)
        XCTAssertEqual(summary.months.count, 6)
        XCTAssertEqual(summary.months.suffix(2).map(\.workoutCount), [1, 2])
        XCTAssertEqual(summary.months.prefix(4).map(\.workoutCount), [0, 0, 0, 0])
        XCTAssertEqual(summary.leadingWeekdayCount, 1) // September 1, 2026 is Tuesday.
        XCTAssertEqual(summary.monthDays.count, 30)
        XCTAssertEqual(summary.monthDays[1].workoutCount, 1)
        XCTAssertEqual(summary.monthDays[1].partialWorkoutCount, 1)
        XCTAssertEqual(summary.monthDays[24].workoutCount, 1)
        XCTAssertEqual(summary.monthDays[24].partialWorkoutCount, 0)
        XCTAssertTrue(summary.monthDays[25].isToday)
        XCTAssertTrue(summary.monthDays[26].isFuture)
    }

    func testWorkoutActivityEmptyHistoryKeepsSixZeroMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26)))

        let summary = WorkoutActivitySummary(entries: [], now: now, calendar: calendar)

        XCTAssertEqual(summary.thisWeekCount, 0)
        XCTAssertEqual(summary.thisMonthCount, 0)
        XCTAssertEqual(summary.thisMonthSetCount, 0)
        XCTAssertEqual(summary.months.map(\.workoutCount), Array(repeating: 0, count: 6))
        XCTAssertEqual(summary.monthDays.count, 30)
        XCTAssertTrue(summary.monthDays.allSatisfy { $0.workoutCount == 0 })
    }

    func testWorkoutActivityExcludesZeroSetRecordsButCountsPartialSessions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 12
        )))
        let partial = try activityItem(at: now, plannedSetCount: 2)
        let emptyPlan = ExercisePlan(
            name: "Dumbbell curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
            plannedSetCount: 2, restSeconds: 60, previousPerformance: []
        )
        let zeroSet = WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: WorkoutSession(
            title: "No work recorded", programmeID: .arms,
            exercises: [WorkoutExercise(plan: emptyPlan)], completedAt: now
        )))

        let summary = WorkoutActivitySummary(
            entries: [partial, zeroSet], now: now, calendar: calendar
        )
        XCTAssertEqual(summary.thisMonthCount, 1)
        XCTAssertEqual(summary.thisMonthSetCount, 1)
        XCTAssertEqual(summary.monthDays[25].workoutCount, 1)
        XCTAssertEqual(summary.monthDays[25].partialWorkoutCount, 1)
    }

    func testWeeklyMuscleLoadUsesSavedSetsAndDeduplicatesSeedNames() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        func date(_ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12)))
        }
        let bench = try activityItem(at: date(25), name: "Barbell Bench Press")
        let hammer = try activityItem(at: date(26), name: "Dumbbell Hammer Curl")
        let previousWeek = try activityItem(at: date(20), name: "Barbell Bench Press")
        let week = WorkoutMuscleWeek(
            entries: [bench, hammer, previousWeek], now: try date(26), calendar: calendar
        )
        func load(_ region: WorkoutMuscleRegion) throws -> WorkoutMuscleRegionLoad {
            try XCTUnwrap(week.regions.first { $0.region == region })
        }

        XCTAssertEqual(week.start, try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21))))
        XCTAssertEqual(try load(.chest).directSets, 1)
        XCTAssertEqual(try load(.triceps).directSets, 1)
        XCTAssertEqual(try load(.shoulders).directSets, 1)
        XCTAssertEqual(try load(.serratus).helperSets, 1)
        XCTAssertEqual(try load(.biceps).directSets, 1) // Brachialis and biceps are one visible area.
        XCTAssertEqual(try load(.forearms).helperSets, 1)
        XCTAssertEqual(try load(.forearms).score, 0.5)
        XCTAssertEqual(try load(.chest).sessionIDs, [bench.id])
        let chest = try XCTUnwrap(week.contributions.first { $0.region == .chest })
        XCTAssertEqual(week.contributions.filter { $0.region == .chest }.count, 1)
        XCTAssertEqual(chest.sessionID, bench.id)
        XCTAssertEqual(chest.exerciseName, "Barbell Bench Press")
        XCTAssertTrue(chest.isDirect)
        XCTAssertEqual(chest.completedSets.map(\.id), bench.exercises?.first?.completedSets.map(\.id))
        let forearms = try XCTUnwrap(week.contributions.first { $0.region == .forearms })
        XCTAssertEqual(forearms.sessionID, hammer.id)
        XCTAssertFalse(forearms.isDirect)
        XCTAssertFalse(week.contributions.contains { $0.sessionID == previousWeek.id })
        XCTAssertEqual(week.setsWithoutMuscleMapping, 0)
    }

    func testMuscleSheetCanOpenExactExerciseHistoryBeyondCurrentWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        func date(_ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12)))
        }
        let olderBench = try activityItem(at: date(12), name: "Barbell Bench Press")
        let currentBench = try activityItem(at: date(26), plannedSetCount: 3, name: "Barbell Bench Press")
        let unrelated = try activityItem(at: date(25), name: "Dumbbell Curl")
        let entries = [olderBench, unrelated, currentBench]
        let week = WorkoutMuscleWeek(entries: entries, now: try date(26), calendar: calendar)
        let chest = try XCTUnwrap(week.contributions.first { $0.region == .chest })

        XCTAssertEqual(chest.exerciseID, ExerciseIDs.barbellBenchPress)
        let history = WorkoutExerciseHistory(exerciseID: chest.exerciseID, entries: entries)
        XCTAssertEqual(history.items.map(\.sessionID), [currentBench.id, olderBench.id])
        XCTAssertEqual(history.items.map(\.completedSets.count), [1, 1])
        XCTAssertTrue(history.items.first?.endedEarly == true)
        XCTAssertFalse(history.items.last?.endedEarly == true)
        XCTAssertTrue(WorkoutExerciseHistory(exerciseID: chest.exerciseID, entries: [unrelated]).items.isEmpty)
    }

    func testExerciseHistoryKeepsDistinctRowsWhenProgrammeReusesPlanIdentity() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell Bench Press", targetLoad: Load(40),
            targetReps: RepRange(6, 8), plannedSetCount: 1,
            restSeconds: 0, previousPerformance: []
        )
        func saved(at date: Date) throws -> WorkoutHistoryDisplayItem {
            var session = WorkoutSession(title: "Bench day", exercises: [WorkoutExercise(plan: plan)])
            _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: date)
            return WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: session))
        }
        let earlier = try saved(at: Date(timeIntervalSince1970: 1_000))
        let later = try saved(at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(earlier.exercises?.first?.id, later.exercises?.first?.id)

        let history = WorkoutExerciseHistory(exerciseID: plan.exerciseID, entries: [earlier, later])
        XCTAssertEqual(history.items.map(\.sessionID), [later.id, earlier.id])
        XCTAssertEqual(Set(history.items.map(\.id)).count, 2)
    }

    func testWeeklyMuscleLoadDoesNotGuessUnknownExerciseAnatomy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12)))
        let unknown = try activityItem(at: now, name: "Unmapped movement")
        let week = WorkoutMuscleWeek(entries: [unknown], now: now, calendar: calendar)

        XCTAssertFalse(week.hasMappedSets)
        XCTAssertTrue(week.contributions.isEmpty)
        XCTAssertEqual(week.setsWithoutMuscleMapping, 1)
        XCTAssertEqual(week.regions.map(\.score), Array(repeating: 0.0, count: WorkoutMuscleRegion.allCases.count))
        XCTAssertTrue(ExerciseLibrary.all.flatMap { $0.primaryMuscleNames + $0.secondaryMuscleNames }
            .allSatisfy { WorkoutMuscleRegion.fromSeedMuscle($0) != nil })
    }

    func testWeeklyMuscleLoadWithNoHistoryHasNoImpliedTraining() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12)))
        let week = WorkoutMuscleWeek(entries: [], now: now, calendar: calendar)

        XCTAssertFalse(week.hasMappedSets)
        XCTAssertTrue(week.contributions.isEmpty)
        XCTAssertEqual(week.sessionsWithoutExerciseDetails, 0)
        XCTAssertEqual(week.setsWithoutMuscleMapping, 0)
        XCTAssertTrue(week.regions.allSatisfy { $0.score == 0 && $0.sessionIDs.isEmpty })
    }

    func testArmsAndBicepsSessionsAreDistinctAndGymReady() throws {
        let arms = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .arms))
        let biceps = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps))

        XCTAssertEqual(arms.makeSession().title, "Arms: Biceps + Triceps")
        XCTAssertEqual(arms.exercisePlans.map(\.exerciseID), [
            ExerciseIDs.dumbbellCurl, ExerciseIDs.cableTricepsPressdown,
            ExerciseIDs.dumbbellHammerCurl, ExerciseIDs.dumbbellOverheadTricepsExtension
        ])
        XCTAssertEqual(arms.totalSetCount, 10)
        XCTAssertEqual(biceps.makeSession().title, "Biceps Focus")
        XCTAssertEqual(biceps.exercisePlans.map(\.exerciseID), [
            ExerciseIDs.dumbbellCurl, ExerciseIDs.dumbbellInclineCurl,
            ExerciseIDs.dumbbellHammerCurl
        ])
        XCTAssertEqual(biceps.totalSetCount, 7)
    }

    func testArmWarmUpsPrepareTheMovementsWithoutCountingWorkingSets() throws {
        let arms = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .arms))
        let biceps = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps))
        let armsSession = arms.makeSession()
        let bicepsSession = biceps.makeSession()

        XCTAssertEqual(armsSession.warmUp?.status, .pending)
        XCTAssertEqual(bicepsSession.warmUp?.status, .pending)
        XCTAssertTrue(armsSession.warmUp?.steps.contains(where: { $0.contains("pressdowns") }) == true)
        XCTAssertTrue(bicepsSession.warmUp?.steps.contains(where: { $0.contains("hammer curls") }) == true)
        XCTAssertEqual(armsSession.warmUp?.estimatedMinutes, 4)
        XCTAssertEqual(bicepsSession.warmUp?.estimatedMinutes, 4)
        XCTAssertEqual(armsSession.warmUp?.timerSeconds(forStepAt: 0), 30)
        XCTAssertEqual(bicepsSession.warmUp?.timerSeconds(forStepAt: 0), 30)
        XCTAssertNil(armsSession.warmUp?.timerSeconds(forStepAt: 1))
        XCTAssertEqual(armsSession.completedSetCount, 0)
        XCTAssertEqual(bicepsSession.completedSetCount, 0)
    }

    func testWarmUpUsesProgressedWorkingLoadFromHistory() throws {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let first = try XCTUnwrap(programme.exercisePlans.first)
        let recordedPlan = ExercisePlan(
            exerciseID: first.exerciseID,
            name: first.name,
            targetLoad: Load(20),
            targetReps: first.targetReps,
            plannedSetCount: first.plannedSetCount,
            restSeconds: first.restSeconds,
            previousPerformance: [],
            targetPrescription: first.targetPrescription
        )
        let recordedReps = Array(repeating: first.targetReps.lowerBound, count: first.plannedSetCount)
        let history = try completedHistory(plan: recordedPlan, reps: recordedReps)

        // History repeats only within 42 days, so evaluate next to the recorded workout.
        let next = programme.makeSession(previousHistory: [history], asOf: history.completedAt.addingTimeInterval(60))

        XCTAssertEqual(next.currentExercise?.plan.targetLoad, Load(20))
        XCTAssertTrue(next.warmUp?.steps.contains(where: { $0.contains("lighter sets") }) == true)
    }

    func testLibraryRoutesThroughDetailIntoSelectedActiveWorkout() throws {
        let store = InMemoryProgrammeSelectionStore()
        let coordinator = WorkoutProgrammeCoordinator(
            selectionStore: store, scheduleStore: InMemoryProgrammeScheduleStore()
        )

        coordinator.showDetail(for: .zeroOneConsistency)

        XCTAssertEqual(coordinator.route, .detail(.zeroOneConsistency))
        XCTAssertEqual(coordinator.selectedProgrammeID, .zeroOneConsistency)

        let session = try XCTUnwrap(coordinator.startSelectedProgramme())

        XCTAssertEqual(coordinator.route, .active(.zeroOneConsistency))
        XCTAssertEqual(session.title, "Strength A")
        XCTAssertEqual(session.currentExercise?.plan.exerciseID, ExerciseIDs.legPress)
        XCTAssertEqual(session.completedSetCount, 0)
    }

    func testSelectedProgrammePersistsAcrossCoordinatorInstances() {
        let store = InMemoryProgrammeSelectionStore()
        let schedules = InMemoryProgrammeScheduleStore()
        let firstCoordinator = WorkoutProgrammeCoordinator(selectionStore: store, scheduleStore: schedules)

        firstCoordinator.showDetail(for: .zeroOneStart)

        let restoredCoordinator = WorkoutProgrammeCoordinator(selectionStore: store, scheduleStore: schedules)
        XCTAssertEqual(restoredCoordinator.selectedProgrammeID, .zeroOneStart)
        XCTAssertEqual(restoredCoordinator.route, .library)
    }

    func testWeeklyScheduleValidatesProgrammeSizeAndFindsNextTrainingDay() throws {
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let arms = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .arms))
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertThrowsError(try WorkoutProgrammeSchedule(programme: start, weekdays: [2], confirmedAt: now))
        XCTAssertThrowsError(try WorkoutProgrammeSchedule(programme: start, weekdays: [1, 2, 3, 4], confirmedAt: now))
        XCTAssertThrowsError(try WorkoutProgrammeSchedule(programme: arms, weekdays: [2, 4], confirmedAt: now))
        XCTAssertNoThrow(try WorkoutProgrammeSchedule(programme: arms, weekdays: [4], confirmedAt: now))

        let schedule = try WorkoutProgrammeSchedule(programme: start, weekdays: [2, 4, 6], confirmedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26)))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
        XCTAssertFalse(schedule.includes(saturday, calendar: calendar))
        XCTAssertEqual(schedule.nextDay(onOrAfter: saturday, calendar: calendar), monday)
        XCTAssertEqual(schedule.weekdaysInCalendarOrder(calendar), [2, 4, 6])
    }

    func testWeeklySchedulePersistsWithoutAdvancingMissedSessions() throws {
        let choices = InMemoryProgrammeSelectionStore()
        let schedules = InMemoryProgrammeScheduleStore()
        let first = WorkoutProgrammeCoordinator(selectionStore: choices, scheduleStore: schedules)
        try first.confirmSchedule(for: .zeroOneStart, weekdays: [2, 4, 6])
        XCTAssertEqual(first.activeSchedule?.weekdays, [2, 4, 6])

        let restored = WorkoutProgrammeCoordinator(selectionStore: choices, scheduleStore: schedules)
        XCTAssertEqual(restored.scheduledProgramme?.id, .zeroOneStart)
        restored.showDetail(for: .zeroOneStart)
        XCTAssertEqual(restored.startSelectedProgramme()?.title, "Full Body A")
        // A calendar day passing cannot consume a workout. Only saved History advances A to B.
        let anotherLaunch = WorkoutProgrammeCoordinator(selectionStore: choices, scheduleStore: schedules)
        anotherLaunch.showDetail(for: .zeroOneStart)
        XCTAssertEqual(anotherLaunch.startSelectedProgramme()?.title, "Full Body A")
    }

    func testFailedOrUnreadableScheduleNeverReplacesSavedChoice() throws {
        let schedules = InMemoryProgrammeScheduleStore()
        let coordinator = WorkoutProgrammeCoordinator(
            selectionStore: InMemoryProgrammeSelectionStore(), scheduleStore: schedules
        )
        schedules.failSave = true
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: .zeroOneStart, weekdays: [2, 4, 6]))
        XCTAssertNil(coordinator.activeSchedule)

        schedules.failSave = false
        try coordinator.confirmSchedule(for: .zeroOneStart, weekdays: [2, 4, 6])
        schedules.failLoad = true
        let unreadable = WorkoutProgrammeCoordinator(
            selectionStore: InMemoryProgrammeSelectionStore(), scheduleStore: schedules
        )
        XCTAssertFalse(unreadable.scheduleIsAvailable)
        XCTAssertThrowsError(try unreadable.confirmSchedule(for: .zeroOneBuild, weekdays: [2, 3, 5, 6]))
        XCTAssertEqual(schedules.saved?.programmeID, .zeroOneStart)
    }

    func testUserDefaultsScheduleRoundTripAndUnreadableRecordProtection() throws {
        let suite = "slick.schedule.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "schedule"
        let store = UserDefaultsWorkoutProgrammeScheduleStore(defaults: defaults, key: key)
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let schedule = try WorkoutProgrammeSchedule(
            programme: programme, weekdays: [2, 4, 6], confirmedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertNil(try store.load())
        try store.save(schedule)
        XCTAssertEqual(try store.load(), schedule)

        defaults.set("unreadable schedule", forKey: key)
        XCTAssertThrowsError(try store.load())
        let coordinator = WorkoutProgrammeCoordinator(
            selectionStore: InMemoryProgrammeSelectionStore(), scheduleStore: store
        )
        XCTAssertFalse(coordinator.scheduleIsAvailable)
        XCTAssertThrowsError(try coordinator.confirmSchedule(for: .zeroOneBuild, weekdays: [2, 3, 5, 6]))
        XCTAssertEqual(defaults.string(forKey: key), "unreadable schedule")
    }

    func testAllProgrammeExerciseAndEvidenceReferencesResolve() {
        let seed = TrainingSeedRepository.shared
        let evidenceIDs = Set(seed.evidenceRecords.map(\.id))

        for programme in WorkoutProgrammeLibrary.all {
            XCTAssertFalse(programme.sessions.isEmpty)
            XCTAssertTrue(programme.evidenceReferenceKeys.allSatisfy(evidenceIDs.contains))

            for plan in programme.sessions.flatMap(\.exercisePlans) {
                XCTAssertNotNil(ExerciseLibrary.exercise(id: plan.exerciseID))
                XCTAssertFalse(plan.equipmentIdentifiers.isEmpty)
                XCTAssertNotNil(plan.sourcePrescription)
                XCTAssertNotNil(plan.coachingCue)
                XCTAssertNotNil(plan.painGuardrail)
            }
        }
    }

    func testEveryProgrammeCreatesAnOfflineSessionWithItsDeclaredSequence() {
        for programme in WorkoutProgrammeLibrary.all {
            let session = programme.makeSession()

            XCTAssertEqual(session.title, programme.sessions[0].title)
            XCTAssertEqual(session.exercises.map(\.plan), programme.exercisePlans)
            XCTAssertEqual(session.totalPlannedSetCount, programme.totalSetCount)
        }
    }

    func testLegacyCompletedHistoryRepeatsWithoutExecutionAndReviewEvidence() throws {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench press",
            targetLoad: Load(40), targetReps: RepRange(8, 10), plannedSetCount: 3,
            restSeconds: 0, previousPerformance: [], targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10, perSide: false))
        let history = try completedHistory(plan: plan, reps: [10, 10, 10])
        let next = WorkoutProgressionEngine(asOf: history.completedAt.addingTimeInterval(30)).plan(plan, using: [history])
        XCTAssertEqual(next.targetLoad, Load(40))
        XCTAssertEqual(next.previousPerformance.map(\.reps), [10, 10, 10])
    }

    func testNextLevelCueRequiresMatchingRecordedProgression() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let expected = try XCTUnwrap(fixture.upgrade?.opportunity)
        let next = fixture.engine.plan(fixture.plan, using: [fixture.entry])
        XCTAssertEqual(fixture.engine.opportunity(for: next, previousPerformance: .recorded(fixture.performance)), expected)
        XCTAssertNil(fixture.engine.opportunity(for: fixture.plan, previousPerformance: .recorded(fixture.performance)))
        XCTAssertEqual(fixture.engine.availableOpportunity(for: fixture.plan, previousPerformance: .recorded(fixture.performance)), expected)
        XCTAssertNil(fixture.engine.opportunity(for: next, previousPerformance: .unavailable))
        let unknown = RecordedExercisePerformance(sessionID: fixture.entry.id, sessionTitle: fixture.entry.title,
            completedAt: fixture.entry.completedAt, occurrences: fixture.entry.exercises ?? [], hasNewerUnknownDetails: true)
        XCTAssertNil(fixture.engine.availableOpportunity(for: fixture.plan, previousPerformance: .recorded(unknown)))
    }

    func testNextLevelCueDoesNotAppearBeforeRepGoal() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press",
            targetLoad: Load(40),
            targetReps: RepRange(8, 10),
            plannedSetCount: 3,
            restSeconds: 0,
            previousPerformance: []
        )
        let history = try completedHistory(plan: plan, reps: [10, 9, 10])
        let recorded = RecordedExercisePerformance(
            sessionID: history.id,
            sessionTitle: history.title,
            completedAt: history.completedAt,
            occurrences: try XCTUnwrap(history.exercises),
            hasNewerUnknownDetails: false
        )
        let engine = WorkoutProgressionEngine()
        XCTAssertNil(engine.opportunity(
            for: engine.plan(plan, using: [history]),
            previousPerformance: .recorded(recorded)
        ))
    }

    func testSavedCompletionShowsOnlyVerifiedUpgradeOptions() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        XCTAssertEqual(WorkoutCompletionUpgrade.readyAfter(session: fixture.session, savedHistory: [fixture.entry],
            progressionReviews: [fixture.review], asOf: fixture.now), [upgrade])
        XCTAssertTrue(WorkoutCompletionUpgrade.readyAfter(session: fixture.session, savedHistory: [],
            progressionReviews: [fixture.review], asOf: fixture.now).isEmpty)
        XCTAssertNil(try WorkoutProgressionTestFixture(rirs: [2, 1]).upgrade)
        XCTAssertNil(try WorkoutProgressionTestFixture(confirmed: false).upgrade)
    }

    func testInSessionUpgradeRequiresConfirmedSnapshotAndCurrentExerciseBoundary() throws {
        let first = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell Bench Press",
            targetLoad: Load(40),
            targetReps: RepRange(6, 8),
            plannedSetCount: 3,
            restSeconds: 0,
            previousPerformance: []
        )
        let second = ExercisePlan(
            exerciseID: ExerciseIDs.dumbbellCurl,
            name: "Dumbbell Curl",
            targetLoad: Load(10),
            targetReps: RepRange(8, 10),
            plannedSetCount: 2,
            restSeconds: 0,
            previousPerformance: []
        )
        var session = WorkoutSession(
            title: "In-session upgrade",
            exercises: [WorkoutExercise(plan: first), WorkoutExercise(plan: second)]
        )
        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: 0))

        for index in 0..<3 {
            _ = try session.completeCurrentSet(
                load: Load(40), reps: 8, rir: 2,
                at: Date(timeIntervalSince1970: Double(index + 1))
            )
        }
        XCTAssertEqual(session.currentExerciseIndex, 1)
        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: nil))
        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: 2))
        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: 4))

        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: 3),
            "A saved first exercise is not whole-workout confirmation or a movement/equipment review")

        _ = session.undoLastSet()
        XCTAssertNil(WorkoutCompletionUpgrade.readyDuring(session: session, persistedCompletedSetCount: 2))
    }

    func testUndecidedUpgradeDoesNotSilentlyIncreaseNextSessionLoad() throws {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .arms))
        let seed = try XCTUnwrap(programme.exercisePlans.first)
        let fixture = try WorkoutProgressionTestFixture(rirs: Array(repeating: 3, count: seed.plannedSetCount),
            plan: seed.replacingTargetLoad(Load(40)), programmeID: .arms)
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let undecided = programme.makeSession(sessionID: programme.sessions[0].id, previousHistory: [fixture.entry],
            progressionReviews: [fixture.review], asOf: fixture.now)
        XCTAssertEqual(undecided.exercises.first?.plan.targetLoad, Load(40))
        let choice = WorkoutLoadChoice(upgrade: upgrade, sourceSessionID: fixture.entry.id, selection: .tryNext)
        let accepted = programme.makeSession(sessionID: programme.sessions[0].id, previousHistory: [fixture.entry],
            loadChoices: [choice], progressionReviews: [fixture.review], asOf: fixture.now)
        XCTAssertEqual(accepted.exercises.first?.plan.targetLoad, Load(42.5))
        let held = programme.makeSession(sessionID: programme.sessions[0].id, previousHistory: [fixture.entry],
            loadChoices: [choice], progressionAllowed: false, progressionReviews: [fixture.review], asOf: fixture.now)
        XCTAssertEqual(held.exercises.first?.plan.targetLoad, Load(40))
    }

    func testInSessionLoadChoiceExpiresWhenFinalSetIsUndoneAndReLogged() throws {
        let original = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(original.upgrade)
        let choice = WorkoutLoadChoice(upgrade: upgrade, sourceSessionID: original.entry.id, selection: .tryNext)
        let replacement = try WorkoutProgressionTestFixture(at: original.now.addingTimeInterval(1_000),
            plan: original.plan, sessionID: original.session.id)
        let replacementUpgrade = try XCTUnwrap(replacement.upgrade)
        XCTAssertEqual(replacementUpgrade.opportunity.suggestedLoad, upgrade.opportunity.suggestedLoad)
        XCTAssertNotEqual(replacementUpgrade.opportunity.context, upgrade.opportunity.context)
        XCTAssertFalse(choice.matches(replacementUpgrade, sourceSessionID: replacement.entry.id))
        let proposed = replacement.engine.plan(replacement.plan, using: [replacement.entry])
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: [choice],
            history: [replacement.entry], engine: replacement.engine).targetLoad, Load(40))
        var legacyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) as? [String: Any])
        legacyPayload.removeValue(forKey: "sourceFinalSetID")
        let legacy = try JSONDecoder().decode(WorkoutLoadChoice.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        XCTAssertNil(legacy.sourceFinalSetID)
    }

    func testSavedKeepChoicePrefillsNextLoadButExpiresAfterNewerWork() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let store = InMemoryWorkoutLoadChoiceStore()
        let first = WorkoutLoadChoiceRepository(store: store)
        let authority = WorkoutProgressionAuthority(history: WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry])),
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([fixture.review])))
        authority.install(currentPlans: { _ in [fixture.plan] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { true })
        first.setProgressionValidator { value, id in authority.validate(value, sourceSessionID: id, at: fixture.now) }
        first.setProgressionPolicy { true }
        XCTAssertTrue(first.choose(.repeatPrevious, for: upgrade, sourceSessionID: fixture.entry.id))
        let restored = WorkoutLoadChoiceRepository(store: store)
        XCTAssertEqual(restored.choice(for: upgrade, sourceSessionID: fixture.entry.id), .repeatPrevious)
        let proposed = fixture.engine.plan(fixture.plan, using: [fixture.entry])
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: restored.choices,
            history: [fixture.entry], engine: fixture.engine).targetLoad, Load(40))
        let newer = try WorkoutProgressionTestFixture(rirs: [1, 1], at: fixture.now.addingTimeInterval(1_000), plan: fixture.plan)
        XCTAssertEqual(newer.engine.plan(fixture.plan, using: [newer.entry, fixture.entry]).targetLoad, Load(40))
        XCTAssertTrue(first.choose(.tryNext, for: upgrade, sourceSessionID: fixture.entry.id))
        XCTAssertEqual(WorkoutLoadChoiceResolver().apply(to: proposed, choices: first.choices,
            history: [fixture.entry], engine: fixture.engine).targetLoad, Load(42.5))
        XCTAssertNoThrow(try JSONDecoder().decode([WorkoutLoadChoice].self, from: JSONEncoder().encode(first.choices)))
    }

    func testFailedLoadChoiceSaveDoesNotClaimSelection() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let upgrade = try XCTUnwrap(fixture.upgrade)
        let store = InMemoryWorkoutLoadChoiceStore()
        let choices = WorkoutLoadChoiceRepository(store: store)
        let authority = WorkoutProgressionAuthority(history: WorkoutHistoryRepository(store: ProgressionHistoryTestStore([fixture.entry])),
            reviews: WorkoutProgressionReviewRepository(store: ProgressionReviewTestStore([fixture.review])))
        authority.install(currentPlans: { _ in [fixture.plan] }, refreshCurrentPlans: { _ in true }, increaseAllowed: { true })
        choices.setProgressionValidator { value, id in authority.validate(value, sourceSessionID: id, at: fixture.now) }
        choices.setProgressionPolicy { true }
        store.failSave = true
        XCTAssertFalse(choices.choose(.repeatPrevious, for: upgrade, sourceSessionID: fixture.entry.id))
        XCTAssertNil(choices.choice(for: upgrade, sourceSessionID: fixture.entry.id))
        XCTAssertTrue(choices.choices.isEmpty)
    }

    func testSavedKeepChoiceReachesTheNextProgrammeSession() throws {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .arms))
        let seed = try XCTUnwrap(programme.exercisePlans.first)
        let fixture = try WorkoutProgressionTestFixture(rirs: Array(repeating: 3, count: seed.plannedSetCount),
            plan: seed.replacingTargetLoad(Load(40)), programmeID: .arms)
        let choice = WorkoutLoadChoice(upgrade: try XCTUnwrap(fixture.upgrade), sourceSessionID: fixture.entry.id, selection: .repeatPrevious)
        let next = programme.makeSession(previousHistory: [fixture.entry], loadChoices: [choice],
            progressionReviews: [fixture.review], asOf: fixture.now)
        XCTAssertEqual(next.exercises.first?.plan.targetLoad, Load(40))
        XCTAssertEqual(next.exercises.first?.plan.previousPerformance.count, seed.plannedSetCount)
    }

    func testNextProgrammeSessionRotatesAfterSavedWorkout() throws {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        XCTAssertGreaterThan(programme.sessions.count, 1)
        var first = programme.makeSession()
        XCTAssertTrue(first.requiresWarmUp)
        first.resolveWarmUp(as: .completed, at: Date(timeIntervalSince1970: 0))
        let exercise = try XCTUnwrap(first.currentExercise)
        let chosenLoad = exercise.plan.allowsZeroLoad
            ? exercise.plan.targetLoad
            : Load(10, unit: exercise.plan.targetLoad.unit)
        _ = try first.completeCurrentSet(
            load: chosenLoad,
            reps: exercise.plan.targetReps.lowerBound,
            at: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(first.finishEarly(at: Date(timeIntervalSince1970: 2)))

        let next = programme.makeSession(previousHistory: [WorkoutHistoryEntry(session: first)])

        XCTAssertEqual(next.title, programme.sessions[1].title)

        let selection = InMemoryProgrammeSelectionStore()
        let coordinator = WorkoutProgrammeCoordinator(
            selectionStore: selection, scheduleStore: InMemoryProgrammeScheduleStore()
        )
        coordinator.showDetail(for: programme.id)
        let started = try XCTUnwrap(coordinator.startSelectedProgramme(
            previousHistory: [WorkoutHistoryEntry(session: first)]
        ))
        XCTAssertEqual(started.title, next.title)
        XCTAssertEqual(started.exercises.map(\.plan), next.exercises.map(\.plan))
        XCTAssertEqual(started.warmUp?.steps, next.warmUp?.steps)
    }

    func testProgrammeProgressionRepeatsLoadWhenRepGoalNotMet() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press",
            targetLoad: Load(40),
            targetReps: RepRange(8, 10),
            plannedSetCount: 3,
            restSeconds: 0,
            previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10, perSide: false)
        )
        let history = try completedHistory(plan: plan, reps: [10, 9, 10])

        let next = WorkoutProgressionEngine(asOf: history.completedAt.addingTimeInterval(30)).plan(plan, using: [history])

        XCTAssertEqual(next.targetLoad, Load(40))
        XCTAssertEqual(next.previousPerformance.map(\.reps), [10, 9, 10])
    }

    func testProgrammeProgressionHoldsLoadAfterNearLimitEffort() throws {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press",
            targetLoad: Load(40),
            targetReps: RepRange(8, 10),
            plannedSetCount: 3,
            restSeconds: 0,
            previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10, perSide: false)
        )
        let atLimit = try completedHistory(plan: plan, reps: [10, 10, 10], rirs: [2, 1, 2])
        let engine = WorkoutProgressionEngine(asOf: atLimit.completedAt.addingTimeInterval(30))
        let next = engine.plan(plan, using: [atLimit])

        XCTAssertEqual(next.targetLoad, Load(40))
        let recorded = RecordedExercisePerformance(
            sessionID: atLimit.id,
            sessionTitle: atLimit.title,
            completedAt: atLimit.completedAt,
            occurrences: try XCTUnwrap(atLimit.exercises),
            hasNewerUnknownDetails: false
        )
        let suggested = ExercisePlan(
            exerciseID: plan.exerciseID,
            name: plan.name,
            targetLoad: Load(42.5),
            targetReps: plan.targetReps,
            plannedSetCount: plan.plannedSetCount,
            restSeconds: plan.restSeconds,
            previousPerformance: []
        )
        XCTAssertNil(engine.opportunity(for: suggested, previousPerformance: .recorded(recorded)))
        XCTAssertNil(engine.availableOpportunity(for: plan, previousPerformance: .recorded(recorded)))

        let unknownNewer = RecordedExercisePerformance(
            sessionID: recorded.sessionID,
            sessionTitle: recorded.sessionTitle,
            completedAt: recorded.completedAt,
            occurrences: recorded.occurrences,
            hasNewerUnknownDetails: true
        )
        XCTAssertNil(engine.availableOpportunity(
            for: plan, previousPerformance: .recorded(unknownNewer)
        ))

        let controlled = try completedHistory(plan: plan, reps: [10, 10, 10], rirs: [2, 2, 3])
        // Controlled effort alone no longer earns an increase: that needs confirmed execution
        // and review evidence (testLegacyCompletedHistoryRepeatsWithoutExecutionAndReviewEvidence).
        XCTAssertEqual(engine.plan(plan, using: [controlled]).targetLoad, Load(40))
    }

    func testSetProgressMomentRequiresComparableSavedImprovement() {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press",
            targetLoad: Load(40),
            targetReps: RepRange(6, 10),
            plannedSetCount: 2,
            restSeconds: 60,
            previousPerformance: []
        )
        let before = CompletedSet(load: Load(40), reps: 8, completedAt: Date(timeIntervalSince1970: 10))
        let secondBefore = CompletedSet(load: Load(35), reps: 10, completedAt: Date(timeIntervalSince1970: 11))
        let occurrence = WorkoutHistoryExercise(exercise: WorkoutExercise(
            plan: plan, completedSets: [before, secondBefore]
        ))
        let recorded = RecordedExercisePerformance(
            sessionID: UUID(), sessionTitle: "Previous", completedAt: Date(timeIntervalSince1970: 12),
            occurrences: [occurrence], hasNewerUnknownDetails: false
        )
        func result(_ load: Load, _ reps: Int, set: Int = 1,
                    previous: PreviousExercisePerformanceState? = nil) -> WorkoutSetProgressMoment? {
            WorkoutSetProgressMoment.evaluate(
                savedSet: CompletedSet(load: load, reps: reps, completedAt: Date(timeIntervalSince1970: 20)),
                setNumber: set, previousPerformance: previous ?? .recorded(recorded)
            )
        }

        XCTAssertEqual(result(Load(42.5), 8)?.kind, .load)
        XCTAssertEqual(result(Load(42.5), 9)?.kind, .load)
        XCTAssertEqual(result(Load(40), 9)?.kind, .repetitions)
        XCTAssertEqual(result(Load(37.5), 11, set: 2)?.kind, .load)
        XCTAssertNil(result(Load(42.5), 7))
        XCTAssertNil(result(Load(40), 8))
        XCTAssertNil(result(Load(45, unit: .pounds), 8))
        XCTAssertNil(result(Load(42.5), 8, set: 0))
        XCTAssertNil(result(Load(42.5), 8, set: 3))
        XCTAssertNil(result(Load(42.5), 8, previous: .unavailable))
        let unknownNewer = RecordedExercisePerformance(
            sessionID: recorded.sessionID, sessionTitle: recorded.sessionTitle,
            completedAt: recorded.completedAt, occurrences: recorded.occurrences,
            hasNewerUnknownDetails: true
        )
        XCTAssertNil(result(Load(42.5), 8, previous: .recorded(unknownNewer)))
    }

    func testSetResponseClassifiesAllSevenOutcomesWithoutInventingHistory() {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell bench press", targetLoad: Load(40), targetReps: RepRange(8, 10),
            plannedSetCount: 2, restSeconds: 60, previousPerformance: []
        )
        let previousSet = CompletedSet(
            load: Load(40), reps: 10, completedAt: Date(timeIntervalSince1970: 10)
        )
        let occurrence = WorkoutHistoryExercise(exercise: WorkoutExercise(
            plan: plan, completedSets: [previousSet]
        ))
        let recorded = RecordedExercisePerformance(
            sessionID: UUID(), sessionTitle: "Previous", completedAt: Date(timeIntervalSince1970: 11),
            occurrences: [occurrence], hasNewerUnknownDetails: false
        )
        func response(_ load: Load, _ reps: Int,
                      previous: PreviousExercisePerformanceState? = nil) -> WorkoutSetResponse? {
            WorkoutSetResponse.evaluate(
                savedSet: CompletedSet(
                    load: load, reps: reps, completedAt: Date(timeIntervalSince1970: 20)
                ),
                setNumber: 1, targetReps: plan.targetReps,
                previousPerformance: previous ?? .recorded(recorded)
            )
        }

        XCTAssertEqual(response(Load(42.5), 10)?.kind, .up)
        XCTAssertEqual(response(Load(40), 11)?.kind, .upReps)
        XCTAssertEqual(response(Load(40), 10)?.kind, .same)
        XCTAssertEqual(response(Load(42.5), 8)?.kind, .heavierIn)
        XCTAssertEqual(response(Load(42.5), 7)?.kind, .heavierBelow)
        XCTAssertEqual(response(Load(40), 8)?.kind, .fewer)
        XCTAssertEqual(response(Load(37.5), 12)?.kind, .lighter)
        XCTAssertTrue(response(Load(42.5), 8)?.offersNextSetLoadChoice == true)
        XCTAssertFalse(response(Load(40), 8)?.offersNextSetLoadChoice == true)
        XCTAssertNil(response(Load(45, unit: .pounds), 10))
        XCTAssertNil(response(Load(42.5), 10, previous: .unavailable))
        let unknownNewer = RecordedExercisePerformance(
            sessionID: recorded.sessionID, sessionTitle: recorded.sessionTitle,
            completedAt: recorded.completedAt, occurrences: recorded.occurrences,
            hasNewerUnknownDetails: true
        )
        XCTAssertNil(response(Load(42.5), 10, previous: .recorded(unknownNewer)))
    }

    private func completedHistory(
        plan: ExercisePlan, reps: [Int], rirs: [Int?] = []
    ) throws -> WorkoutHistoryEntry {
        var session = WorkoutSession(title: "Progression test", exercises: [WorkoutExercise(plan: plan)])
        for (index, count) in reps.enumerated() {
            _ = try session.completeCurrentSet(
                load: plan.targetLoad,
                reps: count,
                rir: rirs.indices.contains(index) ? rirs[index] : nil,
                at: Date(timeIntervalSince1970: Double(index + 1))
            )
            session.skipRest()
        }
        return WorkoutHistoryEntry(session: session)
    }

    private func activityItem(
        at date: Date, plannedSetCount: Int = 1, name: String = "Dumbbell Curl"
    ) throws -> WorkoutHistoryDisplayItem {
        let plan = ExercisePlan(
            name: name,
            targetLoad: Load(10),
            targetReps: RepRange(8, 10),
            plannedSetCount: plannedSetCount,
            restSeconds: 60,
            previousPerformance: []
        )
        var session = WorkoutSession(title: "Activity test", exercises: [WorkoutExercise(plan: plan)])
        _ = try session.completeCurrentSet(load: Load(10), reps: 8, at: date)
        if !session.isComplete {
            XCTAssertTrue(session.finishEarly(at: date))
        }
        return WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: session))
    }

    private func completedSession(
        plan: ExercisePlan, reps: [Int], rirs: [Int?],
        startingAt: Date = Date(timeIntervalSince1970: 0)
    ) throws -> WorkoutSession {
        var session = WorkoutSession(title: "Upgrade test", exercises: [WorkoutExercise(plan: plan)])
        for (index, count) in reps.enumerated() {
            _ = try session.completeCurrentSet(
                load: plan.targetLoad,
                reps: count,
                rir: rirs[index],
                at: startingAt.addingTimeInterval(Double(index + 1))
            )
            session.skipRest()
        }
        if !session.isComplete {
            XCTAssertTrue(session.finishEarly(at: startingAt.addingTimeInterval(100)))
        }
        return session
    }
}

private final class InMemoryProgrammeSelectionStore: WorkoutProgrammeSelectionPersisting {
    private var selectedID: WorkoutProgrammeID?

    func loadSelectedID() -> WorkoutProgrammeID? {
        selectedID
    }

    func saveSelectedID(_ id: WorkoutProgrammeID) {
        selectedID = id
    }
}

private final class InMemoryProgrammeScheduleStore: WorkoutProgrammeSchedulePersisting {
    private(set) var saved: WorkoutProgrammeSchedule?
    var failSave = false
    var failLoad = false

    func load() throws -> WorkoutProgrammeSchedule? {
        if failLoad { throw WorkoutPersistenceError.unavailable }
        return saved
    }

    func save(_ schedule: WorkoutProgrammeSchedule) throws {
        if failSave { throw WorkoutPersistenceError.verificationFailed }
        saved = schedule
    }
}

private final class InMemoryWorkoutLoadChoiceStore: WorkoutLoadChoicePersisting {
    private var saved: [WorkoutLoadChoice] = []
    var failSave = false

    func load() -> [WorkoutLoadChoice] { saved }

    func save(_ choices: [WorkoutLoadChoice]) throws {
        if failSave { throw WorkoutPersistenceError.verificationFailed }
        saved = choices
    }
}
