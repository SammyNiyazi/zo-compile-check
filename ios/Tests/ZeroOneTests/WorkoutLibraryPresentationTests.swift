import XCTest
@testable import ZeroOne

/// Pure facts behind proof 38's library and proof 9's programme detail. Layout,
/// posters, motion and VoiceOver need native acceptance; these rules do not.
final class WorkoutLibraryPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func entry(at date: Date, sets: Int = 1) -> WorkoutHistoryEntry {
        let plan = ExercisePlan(exerciseID: "goblet-squat", name: "Goblet squat", targetLoad: Load(16),
                                targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
                                previousPerformance: [])
        let done = (0 ..< sets).map { _ in CompletedSet(load: Load(16), reps: 10, completedAt: date) }
        return WorkoutHistoryEntry(session: WorkoutSession(
            title: "Full Body A", exercises: [WorkoutExercise(plan: plan, completedSets: done)], completedAt: date
        ))
    }

    private func schedule(_ weekdays: Set<Int>) throws -> WorkoutProgrammeSchedule {
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        return try WorkoutProgrammeSchedule(programme: programme, weekdays: weekdays, confirmedAt: date(9, 1))
    }

    // MARK: Your week

    func testWeekFollowsTheCalendarAndMarksDonePlannedAndToday() throws {
        // Proof 38: Monday done, Thursday (today) and Saturday planned.
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5, 7]), entries: [entry(at: date(9, 28, 18))],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertEqual(week.days.map(\.dayOfMonth), [28, 29, 30, 1, 2, 3, 4])
        XCTAssertEqual(week.days.map(\.weekday), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(week.days.map(\.isDone), [true, false, false, false, false, false, false])
        XCTAssertEqual(week.days.map(\.isPlanned), [true, false, false, true, false, true, false])
        XCTAssertEqual(week.days.map(\.isToday), [false, false, false, true, false, false, false])
        XCTAssertEqual(week.count, .planned(done: 1, of: 3, otherDays: 0))
        XCTAssertEqual(week.nextPlannedDay, calendar.startOfDay(for: date(10, 1)))
    }

    func testAPlannedDayAlreadyDoneIsNotTheNextOne() throws {
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5, 7]), entries: [entry(at: date(10, 1, 7))],
                                           now: date(10, 1, 9), calendar: calendar)
        XCTAssertTrue(week.days[3].isDone)
        XCTAssertEqual(week.nextPlannedDay, calendar.startOfDay(for: date(10, 3)))
    }

    func testAWorkoutWithNoSavedSetIsNotDone() throws {
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5]), entries: [entry(at: date(9, 29), sets: 0)],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertFalse(week.days.contains(where: \.isDone))
        XCTAssertEqual(week.count, .planned(done: 0, of: 2, otherDays: 0))
    }

    func testUnreadableHistoryMarksNothingDoneAndCountsNothing() throws {
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5]), entries: nil,
                                           now: date(10, 1), calendar: calendar)
        XCTAssertFalse(week.days.contains(where: \.isDone))
        XCTAssertEqual(week.count, .historyUnavailable)
        XCTAssertEqual(week.days.filter(\.isPlanned).count, 2, "The schedule is still known")
    }

    func testWithoutAScheduleNothingIsPlanned() {
        let week = WorkoutWeekPresentation(schedule: nil, entries: [entry(at: date(9, 30))],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertFalse(week.days.contains(where: \.isPlanned))
        XCTAssertEqual(week.count, .unplanned(done: 1))
        XCTAssertNil(week.nextPlannedDay)
    }

    func testOnlyThisWeeksWorkoutsCount() throws {
        // Sunday 27 September belongs to the previous Monday-first week.
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5]),
                                           entries: [entry(at: date(9, 27, 20)), entry(at: date(10, 5, 8))],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertEqual(week.count, .planned(done: 0, of: 2, otherDays: 0))
    }

    func testTwoWorkoutsOnOneDayAreOneDoneDay() throws {
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5]),
                                           entries: [entry(at: date(9, 28, 7)), entry(at: date(9, 28, 19))],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertEqual(week.count, .planned(done: 1, of: 2, otherDays: 0))
    }

    func testWorkoutsOnUnplannedDaysAreNeverCountedAsPlannedSessions() throws {
        // Planned Monday and Thursday; saved Monday, Tuesday and Wednesday.
        // Not "3 of 2 done": one planned day is done, two other days were too.
        let week = WorkoutWeekPresentation(schedule: try schedule([2, 5]),
                                           entries: [entry(at: date(9, 28)), entry(at: date(9, 29)), entry(at: date(9, 30))],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertEqual(week.count, .planned(done: 1, of: 2, otherDays: 2))
        XCTAssertEqual(week.days.filter(\.isDone).count, 3, "Every saved day is still marked done")
        XCTAssertEqual(week.nextPlannedDay, calendar.startOfDay(for: date(10, 1)))
    }

    func testASundayFirstCalendarStartsOnSunday() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let week = WorkoutWeekPresentation(schedule: nil, entries: [], now: date(10, 1, in: sundayFirst),
                                           calendar: sundayFirst)
        XCTAssertEqual(week.days.map(\.dayOfMonth), [27, 28, 29, 30, 1, 2, 3])
        XCTAssertEqual(week.days.first?.weekday, 1)
    }

    // MARK: My workouts

    func testSavedCardCountsStacksFourAndKeepsTheRailInOrder() throws {
        let workout = CustomWorkout(name: "Push day", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl", sets: 4),
            CustomWorkoutItem(videoID: "band-high-face-pull", sets: 3),
            CustomWorkoutItem(videoID: "dumbbell-concentration-curl", sets: 3),
            CustomWorkoutItem(videoID: "dumbbell-curl", sets: 2),
            CustomWorkoutItem(videoID: "band-high-face-pull", sets: 2)
        ])
        let card = CustomWorkoutCardPresentation(workout: workout)
        XCTAssertEqual(card.exerciseCount, 5)
        XCTAssertEqual(card.setCount, 14)
        XCTAssertEqual(card.stack.map { $0?.id }, ["dumbbell-curl", "band-high-face-pull",
                                                    "dumbbell-concentration-curl", "dumbbell-curl"])
        XCTAssertEqual(card.overflowCount, 1)
        XCTAssertEqual(card.railGroups, [4, 3, 3, 2, 2])
        let expected = try XCTUnwrap(CustomWorkoutBuilderPresentation.estimate(for: workout, warmUp: .full))
        XCTAssertEqual(card.estimatedMinutes, expected.maximumMinutes, "The existing estimator, not a new one")
    }

    func testUnknownMediaAndInvalidWorkoutsClaimNoPictureOrTime() {
        let unknown = CustomWorkoutCardPresentation(workout: CustomWorkout(name: "Odd", items: [
            CustomWorkoutItem(videoID: "not-a-movekit-video")
        ]))
        XCTAssertEqual(unknown.stack.count, 1)
        XCTAssertNil(unknown.stack[0], "No exact media, so the honest no-video surface")
        XCTAssertNil(unknown.estimatedMinutes)

        let unnamed = CustomWorkoutCardPresentation(workout: CustomWorkout(name: " ", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl")
        ]))
        XCTAssertNil(unnamed.estimatedMinutes, "An invalid workout has no estimate")
        XCTAssertEqual(unnamed.overflowCount, 0)
    }

    func testOverflowingSetCountsAreLeftOutRatherThanInvented() {
        let card = CustomWorkoutCardPresentation(workout: CustomWorkout(name: "Old", items: [
            CustomWorkoutItem(videoID: "dumbbell-curl", sets: Int.max),
            CustomWorkoutItem(videoID: "dumbbell-curl", sets: 1)
        ]))
        XCTAssertNil(card.setCount)
        XCTAssertNil(card.estimatedMinutes)
    }

    // MARK: Exercises

    private func exercise(muscle: String, equipment: String) -> MoveKitExercise {
        MoveKitExercise(id: "x", name: "Goblet squat", videoResource: "x", posterResource: "x",
                        equipment: equipment, muscleFocus: muscle, sets: "", reps: "", rest: "")
    }

    func testExerciseCardNamesWhatItTrainsAndWithWhat() {
        XCTAssertEqual(WorkoutExerciseGridPresentation.detailLine(for: exercise(muscle: "Legs", equipment: "Dumbbell")),
                       "Legs · Dumbbell")
    }

    func testNotSuppliedIsNeverShownAsAFact() {
        XCTAssertEqual(WorkoutExerciseGridPresentation.detailLine(for: exercise(muscle: "Not supplied", equipment: "Cable")),
                       "Cable")
        XCTAssertEqual(WorkoutExerciseGridPresentation.detailLine(for: exercise(muscle: "Chest", equipment: " ")),
                       "Chest")
        XCTAssertNil(WorkoutExerciseGridPresentation.detailLine(for: exercise(muscle: "Not supplied", equipment: "Not supplied")))
    }

    func testTheSearchPromptCountsTheRealLibrary() {
        let prompt = AppLocalization(language: .english).format("Search %1$lld exercises", .integer(MoveKitExercise.all.count))
        XCTAssertEqual(prompt, "Search \(MoveKitExercise.all.count) exercises")
        XCTAssertGreaterThan(MoveKitExercise.all.count, 0)
    }

    // MARK: Programme detail

    func testCoverNeverTurnsTheRotationIntoAWeeklyFrequency() throws {
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let cover = ProgrammeCoverPresentation(programme: start, schedule: nil)
        XCTAssertEqual(cover.weeks, start.durationWeeks)
        XCTAssertEqual(cover.rotationLength, start.sessions.count)
        XCTAssertEqual(cover.minutes, start.durationMinutes)
        XCTAssertNil(cover.scheduledDaysPerWeek, "The programme authors no typed weekly frequency")
        XCTAssertEqual(cover.gridWeeks, start.durationWeeks)
        XCTAssertEqual(cover.gridBarsPerWeek, 1, "Weeks only, no implied sessions per week")
    }

    func testScheduledDaysThatDifferFromTheRotationAreTheOnlyWeeklyFact() throws {
        // Three sessions in rotation, trained on two chosen days a week.
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        XCTAssertEqual(start.sessions.count, 3)
        let cover = ProgrammeCoverPresentation(programme: start, schedule: try schedule([2, 5]))
        XCTAssertEqual(cover.rotationLength, 3)
        XCTAssertEqual(cover.scheduledDaysPerWeek, 2)
        XCTAssertEqual(cover.gridBarsPerWeek, 2)
    }

    func testAnotherProgrammesScheduleIsNotThisProgrammesFrequency() throws {
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let build = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneBuild))
        let buildSchedule = try WorkoutProgrammeSchedule(programme: build, weekdays: [2, 3, 5, 6], confirmedAt: date(9, 1))
        let cover = ProgrammeCoverPresentation(programme: start, schedule: buildSchedule)
        XCTAssertNil(cover.scheduledDaysPerWeek)
        XCTAssertEqual(cover.gridBarsPerWeek, 1)
    }

    func testEveryAuthoredProgrammeFitsTheGridWithoutAWeeklyClaim() {
        for programme in WorkoutProgrammeLibrary.all {
            let cover = ProgrammeCoverPresentation(programme: programme, schedule: nil)
            XCTAssertLessThanOrEqual(cover.gridWeeks, ProgrammeCoverPresentation.maximumWeekColumns)
            XCTAssertGreaterThan(cover.weeks, 0, programme.title)
            XCTAssertNil(cover.scheduledDaysPerWeek, programme.title)
            XCTAssertEqual(cover.gridBarsPerWeek, 1, programme.title)
        }
    }

    // MARK: Schedule availability (C7)

    func testScheduleAvailabilityKeepsUnreadableApartFromNone() throws {
        let saved = try schedule([2, 5])
        XCTAssertEqual(WorkoutScheduleAvailability(schedule: saved, isAvailable: true), .confirmed(saved))
        XCTAssertEqual(WorkoutScheduleAvailability(schedule: nil, isAvailable: true), .noSchedule)
        // The coordinator keeps its cached value after a failed reload; it is
        // never presented as current.
        let unreadable = WorkoutScheduleAvailability(schedule: saved, isAvailable: false)
        XCTAssertEqual(unreadable, .unavailable)
        XCTAssertNil(unreadable.currentSchedule)
        XCTAssertFalse(unreadable.isCurrentPlan(.zeroOneStart), "No Your plan badge from a cached schedule")
        XCTAssertTrue(WorkoutScheduleAvailability(schedule: saved, isAvailable: true).isCurrentPlan(.zeroOneStart))
        XCTAssertEqual(WorkoutScheduleAvailability(schedule: nil, isAvailable: false), .unavailable)
    }

    func testAnUnreadableScheduleMarksNoPlannedDayAndCountsOnlyWhatWasDone() throws {
        let week = WorkoutWeekPresentation(
            schedule: WorkoutScheduleAvailability(schedule: try schedule([2, 5]), isAvailable: false),
            entries: [entry(at: date(9, 28)), entry(at: date(9, 29))], now: date(10, 1), calendar: calendar)
        XCTAssertTrue(week.scheduleIsUnavailable)
        XCTAssertFalse(week.days.contains(where: \.isPlanned))
        XCTAssertNil(week.nextPlannedDay, "No next session from an unreadable schedule")
        XCTAssertEqual(week.count, .unplanned(done: 2))
    }

    func testAbsentAndAvailableSchedulesAreNotUnavailable() throws {
        let none = WorkoutWeekPresentation(schedule: WorkoutScheduleAvailability.noSchedule, entries: [],
                                           now: date(10, 1), calendar: calendar)
        XCTAssertFalse(none.scheduleIsUnavailable)
        XCTAssertEqual(none.count, .unplanned(done: 0))
        let available = WorkoutWeekPresentation(
            schedule: WorkoutScheduleAvailability(schedule: try schedule([2, 5]), isAvailable: true),
            entries: [entry(at: date(9, 28))], now: date(10, 1), calendar: calendar)
        XCTAssertFalse(available.scheduleIsUnavailable)
        XCTAssertEqual(available.count, .planned(done: 1, of: 2, otherDays: 0))
    }

    func testAnUnreadableScheduleIsNeverTheCoversWeeklyFact() throws {
        let start = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let cover = ProgrammeCoverPresentation(
            programme: start, schedule: WorkoutScheduleAvailability(schedule: try schedule([2, 5]), isAvailable: false))
        XCTAssertTrue(cover.scheduleIsUnavailable)
        XCTAssertNil(cover.scheduledDaysPerWeek)
        XCTAssertEqual(cover.gridBarsPerWeek, 1)
        XCTAssertEqual(cover.rotationLength, 3, "The rotation is still the programme's own fact")
        let readable = ProgrammeCoverPresentation(
            programme: start, schedule: WorkoutScheduleAvailability(schedule: try schedule([2, 5]), isAvailable: true))
        XCTAssertFalse(readable.scheduleIsUnavailable)
        XCTAssertEqual(readable.scheduledDaysPerWeek, 2)
    }

    // MARK: Exercise detail (C8)

    func testExerciseWordsAreMusclesThenEquipmentNeverPlaceholders() {
        XCTAssertEqual(ExerciseDetailPresentation.tags(muscleFocus: "Glutes and quadriceps", equipment: "Dumbbell"),
                       ["Glutes", "Quadriceps", "Dumbbell"])
        XCTAssertEqual(ExerciseDetailPresentation.tags(muscleFocus: "Chest, shoulders and triceps",
                                                       equipment: "Dumbbells and incline bench"),
                       ["Chest", "Shoulders", "Triceps", "Dumbbells and incline bench"],
                       "The equipment stays one phrase")
        XCTAssertEqual(ExerciseDetailPresentation.tags(muscleFocus: "Not supplied", equipment: "Not supplied"), [])
        XCTAssertEqual(ExerciseDetailPresentation.tags(muscleFocus: "Back and back", equipment: nil), ["Back"])
    }

    private func entry(at date: Date, sets: [CompletedSet]) -> WorkoutHistoryEntry {
        let plan = ExercisePlan(exerciseID: "goblet-squat", name: "Goblet squat", targetLoad: Load(16),
                                targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
                                previousPerformance: [])
        return WorkoutHistoryEntry(session: WorkoutSession(
            title: "Full Body A", exercises: [WorkoutExercise(plan: plan, completedSets: sets)], completedAt: date
        ))
    }

    private func exerciseHistory(_ entries: [WorkoutHistoryEntry]) -> ExerciseHistoryPresentation {
        ExerciseHistoryPresentation(history: WorkoutExerciseHistory(
            exerciseID: "goblet-squat", entries: entries.map { WorkoutHistoryDisplayItem(entry: $0) }))
    }

    func testTheBestSetIsTheFirstHeaviestAndEachSessionIsOnePoint() {
        let firstBest = CompletedSet(load: Load(22), reps: 9, completedAt: date(9, 24), isPerSide: false)
        let history = exerciseHistory([
            entry(at: date(9, 20), sets: [CompletedSet(load: Load(20), reps: 10, completedAt: date(9, 20), isPerSide: false)]),
            entry(at: date(9, 24), sets: [CompletedSet(load: Load(22), reps: 8, completedAt: date(9, 24), isPerSide: false), firstBest]),
            entry(at: date(9, 28), sets: [CompletedSet(load: Load(22), reps: 9, completedAt: date(9, 28), isPerSide: false)])
        ])
        XCTAssertEqual(history.sessionCount, 3)
        XCTAssertEqual(history.best?.setID, firstBest.id, "An equal later set does not replace the mark")
        XCTAssertEqual(history.topSets.map(\.load.value), [20, 22, 22], "Oldest first, one per session")
        XCTAssertEqual(history.recentSessions.map(\.completedAt), [date(9, 28), date(9, 24), date(9, 20)])
        XCTAssertEqual(history.recentSessions[1].sets.count, 2, "Every set of the session is listed")
    }

    func testLoadsAreRankedOnlyInTheNewestUnit() {
        let history = exerciseHistory([
            entry(at: date(9, 20), sets: [CompletedSet(load: Load(100), reps: 5, completedAt: date(9, 20), isPerSide: false)]),
            entry(at: date(9, 28), sets: [CompletedSet(load: Load(45, unit: .pounds), reps: 8, completedAt: date(9, 28), isPerSide: false)])
        ])
        XCTAssertEqual(history.best?.load, Load(45, unit: .pounds), "100 kg is never compared with pounds")
        XCTAssertEqual(history.topSets.count, 1)
        XCTAssertEqual(history.sessionCount, 2)
    }

    func testTimedAndUnloadedSetsAreListedButNeverRanked() {
        let history = exerciseHistory([
            entry(at: date(9, 28), sets: [
                CompletedSet(load: Load(0), reps: 12, completedAt: date(9, 28)),
                CompletedSet(load: Load(10), reps: 0, completedAt: date(9, 28), durationSeconds: 30)
            ])
        ])
        XCTAssertNil(history.best)
        XCTAssertTrue(history.topSets.isEmpty)
        XCTAssertEqual(history.recentSessions.first?.sets.count, 2)
    }

    func testOnlyTheLatestSessionsAndChartPointsAreKept() {
        let entries = (1 ... 9).map { day in
            entry(at: date(9, day), sets: [CompletedSet(load: Load(Double(10 + day)), reps: 8, completedAt: date(9, day), isPerSide: false)])
        }
        let history = exerciseHistory(entries)
        XCTAssertEqual(history.sessionCount, 9)
        XCTAssertEqual(history.recentSessions.count, ExerciseHistoryPresentation.recentLimit)
        XCTAssertEqual(history.topSets.count, ExerciseHistoryPresentation.chartLimit)
        XCTAssertEqual(history.topSets.last?.load.value, 19)
    }

    // MARK: Swap sheet (C9)

    func testSwapReasonsAreFactsFromBothDefinitions() throws {
        let bench = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.barbellBenchPress))
        XCTAssertEqual(ExerciseSwapPresentation.reasons(for: bench, replacing: nil), [],
                       "No source definition, no claimed reason")
        let same = ExerciseSwapPresentation.reasons(for: bench, replacing: bench)
        XCTAssertTrue(same.contains("Same main muscle"))
        XCTAssertTrue(same.contains("Same movement"))
        XCTAssertFalse(same.contains("Easier"))
        XCTAssertFalse(same.contains("No equipment"))

        let pushUp = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.pushUp))
        let reasons = ExerciseSwapPresentation.reasons(for: pushUp, replacing: bench)
        XCTAssertEqual(reasons.contains("No equipment"), pushUp.equipment == [.bodyweight])
        XCTAssertEqual(reasons.contains("Same main muscle"), pushUp.primaryMuscleGroup == bench.primaryMuscleGroup)
    }

    // MARK: Review fixes (C11)

    func testMoreRepsAtTheSameLoadIsTheBestAndNamesItsSession() {
        let older = entry(at: date(9, 20), sets: [CompletedSet(load: Load(22), reps: 8, completedAt: date(9, 20), isPerSide: false)])
        let newer = entry(at: date(9, 28), sets: [CompletedSet(load: Load(22), reps: 10, completedAt: date(9, 28), isPerSide: false)])
        let history = exerciseHistory([older, newer])
        XCTAssertEqual(history.best?.reps, 10)
        XCTAssertEqual(history.best?.sessionID, newer.id, "The chart fills the dot of the best set's session")
        XCTAssertEqual(history.topSets.firstIndex { $0.sessionID == history.best?.sessionID }, 1)
    }

    func testPerSideSetsAreListedButNeverRanked() {
        let history = exerciseHistory([
            entry(at: date(9, 28), sets: [
                CompletedSet(load: Load(30), reps: 8, completedAt: date(9, 28), isPerSide: true),
                CompletedSet(load: Load(20), reps: 8, completedAt: date(9, 28), isPerSide: false)
            ])
        ])
        XCTAssertEqual(history.best?.load, Load(20), "30 kg per side is not compared with both-sided sets")
        XCTAssertEqual(history.recentSessions.first?.sets.count, 2)
    }

    func testUnknownSideSetsStayVisibleButCannotBecomeTheBestOrAChartPoint() {
        let known = CompletedSet(load: Load(20), reps: 8, completedAt: date(9, 20), isPerSide: false)
        let unknown = CompletedSet(load: Load(30), reps: 8, completedAt: date(9, 28))
        let history = exerciseHistory([entry(at: date(9, 20), sets: [known]), entry(at: date(9, 28), sets: [unknown])])
        XCTAssertEqual(history.best?.setID, known.id)
        XCTAssertEqual(history.topSets.map(\.load.value), [20])
        XCTAssertEqual(history.recentSessions.first?.sets, [unknown])
        let onlyUnknown = exerciseHistory([entry(at: date(9, 28), sets: [unknown])])
        XCTAssertNil(onlyUnknown.best)
        XCTAssertTrue(onlyUnknown.topSets.isEmpty)
        XCTAssertEqual(onlyUnknown.sessionCount, 1)
    }
}
