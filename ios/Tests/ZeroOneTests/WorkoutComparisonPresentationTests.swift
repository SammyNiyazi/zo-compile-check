import XCTest
@testable import ZeroOne

/// Pure facts behind proof 37/42's bars, ghost rail and finish card. Layout,
/// motion and VoiceOver need native acceptance; these rules do not.
final class WorkoutComparisonPresentationTests: XCTestCase {
    private let reps = WorkingSetPrescription(unit: .repetitions, lowerBound: 8, upperBound: 12)
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func set(_ load: Double, _ count: Int, unit: LoadUnit = .kilograms, perSide: Bool? = false,
                     seconds: Int? = nil, at offset: TimeInterval = 0) -> CompletedSet {
        CompletedSet(load: Load(load, unit: unit), reps: seconds == nil ? count : 0,
                     completedAt: base.addingTimeInterval(offset), durationSeconds: seconds, isPerSide: perSide)
    }

    private func plan(_ id: ExerciseID = "goblet-squat", sets: Int = 2, load: Double = 16,
                      prescription: WorkingSetPrescription? = nil) -> ExercisePlan {
        ExercisePlan(exerciseID: id, name: "Goblet squat", targetLoad: Load(load), targetReps: RepRange(8, 12),
                     plannedSetCount: sets, restSeconds: 90, previousPerformance: [],
                     targetPrescription: prescription)
    }

    private func recorded(_ occurrences: [[CompletedSet]], id: ExerciseID = "goblet-squat",
                          session: UUID = UUID(), at date: Date? = nil,
                          newerUnknown: Bool = false) -> PreviousExercisePerformanceState {
        .recorded(RecordedExercisePerformance(
            sessionID: session, sessionTitle: "Full Body A", completedAt: date ?? base.addingTimeInterval(-86_400 * 3),
            occurrences: occurrences.map { WorkoutHistoryExercise(exercise: WorkoutExercise(plan: plan(id), completedSets: $0)) },
            hasNewerUnknownDetails: newerUnknown
        ))
    }

    private func presentation(_ state: PreviousExercisePerformanceState, today: [CompletedSet] = [],
                              current: Int = 1, planned: Int = 2,
                              prescription: WorkingSetPrescription? = nil) -> WorkoutComparisonPresentation {
        WorkoutComparisonPresentation(state: state, confirmedSets: today, currentSet: current,
                                      plannedSetCount: planned, prescription: prescription ?? reps)
    }

    // MARK: History kinds

    func testFirstEverUnknownAndUnavailableHistoryStayDistinctAndDrawNoPreviousMarker() {
        let first = presentation(.noRecordedSets(hasUnknownDetails: false))
        XCTAssertEqual(first.history, .none(hasUnknownDetails: false))
        XCTAssertTrue(first.isFirstEver)

        let unknown = presentation(.noRecordedSets(hasUnknownDetails: true))
        XCTAssertEqual(unknown.history, .none(hasUnknownDetails: true))
        XCTAssertFalse(unknown.isFirstEver, "Missing details are not a first time")

        let unavailable = presentation(.unavailable)
        XCTAssertEqual(unavailable.history, .unavailable)
        XCTAssertFalse(unavailable.isFirstEver)

        for facts in [first, unknown, unavailable] {
            XCTAssertTrue(facts.rows.allSatisfy { $0.previous == nil && $0.bar?.previous == nil })
            XCTAssertNil(facts.gainedReps)
        }
        XCTAssertEqual(WorkoutComparisonPresentation.history(for: .unavailable), .unavailable)
        XCTAssertEqual(WorkoutComparisonPresentation.history(for: .noRecordedSets(hasUnknownDetails: true)),
                       .none(hasUnknownDetails: true))
    }

    func testANewerUnknownBarrierShowsEarlierValuesWithoutBarsOrGain() {
        let facts = presentation(recorded([[set(16, 10), set(16, 10)]], newerUnknown: true),
                                 today: [set(16, 12)], current: 2)
        XCTAssertEqual(facts.rows.first?.previous?.reps, 10, "Earlier values stay visible as text")
        XCTAssertTrue(facts.rows.allSatisfy { $0.bar?.previous == nil })
        XCTAssertNil(facts.gainedReps, "Unknown newer sessions block any gain claim")
        XCTAssertEqual(WorkoutPreviousRail(exercises: [WorkoutExercise(plan: plan())],
                                           previous: { _ in self.recorded([[self.set(16, 10)]], newerUnknown: true) }),
                       nil, "The ghost rail never outlines across unknown sessions")
    }

    // MARK: Pairing rules

    func testRepeatedOccurrencesUseTheLatestNonemptyOneAndNeverFlatten() {
        let facts = presentation(recorded([[set(20, 8), set(20, 8), set(20, 8)], [set(16, 10)], []]), planned: 1)
        XCTAssertEqual(facts.rows.count, 1, "Sets from two occurrences are not numbered as one list")
        XCTAssertEqual(facts.rows.first?.previous?.load, Load(16))
    }

    func testOnlyMatchingLoadUnitSideAndTimingShareABar() {
        let previous = recorded([[set(16, 10), set(35, 10, unit: .pounds), set(16, 10, perSide: nil), set(16, 10)]])
        let today = [set(16, 11), set(16, 11), set(16, 11), set(18, 11)]
        let facts = presentation(previous, today: today, current: 5, planned: 4)
        XCTAssertEqual(facts.rows[0].bar, .init(previous: 10, today: 11, unit: .repetitions))
        XCTAssertNil(facts.rows[1].bar, "Different units are never compared")
        XCTAssertNil(facts.rows[2].bar, "Unknown side semantics are never compared")
        XCTAssertNil(facts.rows[3].bar, "A changed load is shown as logged")
        XCTAssertTrue(facts.hasUncomparedPairs)
        XCTAssertNil(facts.gainedReps, "No gain unless every saved set is a comparable pair")
    }

    func testAGainCountsOnlyAcknowledgedComparablePairs() {
        let previous = recorded([[set(16, 10), set(16, 10)]])
        let facts = presentation(previous, today: [set(16, 11)], current: 2)
        XCTAssertEqual(facts.gainedReps, 1)
        XCTAssertEqual(facts.rows[1].bar, .init(previous: 10, today: nil, unit: .repetitions))
        XCTAssertTrue(facts.rows[1].isCurrent)

        let net = presentation(previous, today: [set(16, 9), set(16, 10)], current: 3)
        XCTAssertNil(net.gainedReps, "A lower total is never shown as a gain")
    }

    func testTimedSetsUseSecondsAndNeverBecomeARepGain() {
        let timed = WorkingSetPrescription(unit: .seconds, lowerBound: 30, upperBound: 45)
        let previous = recorded([[set(0, 0, seconds: 30)]])
        let facts = presentation(previous, today: [set(0, 0, seconds: 40)], current: 2, planned: 1, prescription: timed)
        XCTAssertEqual(facts.rows[0].bar, .init(previous: 30, today: 40, unit: .seconds))
        XCTAssertNil(facts.gainedReps)
        XCTAssertGreaterThanOrEqual(facts.maximum(for: .seconds), 40)

        let mixed = presentation(recorded([[set(16, 10)]]), today: [set(0, 0, seconds: 40)], current: 2,
                                 planned: 1, prescription: timed)
        XCTAssertNil(mixed.rows[0].bar, "Reps and seconds never share a bar")
    }

    func testUndoAndARelogKeepTheSameRowNumber() {
        let previous = recorded([[set(16, 10), set(16, 10)]])
        let logged = presentation(previous, today: [set(16, 11), set(16, 12)], current: 3)
        let undone = presentation(previous, today: [set(16, 11)], current: 2)
        XCTAssertEqual(logged.rows.map(\.id), undone.rows.map(\.id))
        XCTAssertNil(undone.rows[1].today)
        XCTAssertTrue(undone.rows[1].isCurrent, "The undone set is the current set again")
        let relogged = presentation(previous, today: [set(16, 11), set(16, 9)], current: 3)
        XCTAssertEqual(relogged.rows[1].bar?.today, 9)
        XCTAssertNil(relogged.gainedReps)
    }

    // MARK: Headings

    func testOnlyTheLastSixCalendarDaysAreNamedByWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9)))
        let lateLastNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23)))
        let sixDays = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: now))
        let sevenDays = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: now))
        XCTAssertEqual(WorkoutComparisonPresentation.recency(of: now.addingTimeInterval(-3_600), now: now, calendar: calendar), .today)
        XCTAssertEqual(WorkoutComparisonPresentation.recency(of: lateLastNight, now: now, calendar: calendar), .weekday)
        XCTAssertEqual(WorkoutComparisonPresentation.recency(of: sixDays, now: now, calendar: calendar), .weekday)
        XCTAssertEqual(WorkoutComparisonPresentation.recency(of: sevenDays, now: now, calendar: calendar), .date)
        XCTAssertEqual(WorkoutComparisonPresentation.recency(of: now.addingTimeInterval(86_400 * 2), now: now, calendar: calendar), .date)
    }

    // MARK: Ghost rail

    func testTheGhostRailMirrorsTheSessionRailAndOutlinesOnlyRecordedSets() {
        let squat = WorkoutExercise(plan: plan("goblet-squat", sets: 2))
        let row = WorkoutExercise(plan: plan("dumbbell-row", sets: 3))
        let session = UUID()
        let rail = WorkoutPreviousRail(exercises: [squat, row]) { id in
            id == "goblet-squat" ? self.recorded([[self.set(16, 10)]], session: session)
                                 : .noRecordedSets(hasUnknownDetails: false)
        }
        let sessionRail = WorkoutSetRail(session: WorkoutSession(title: "A", exercises: [squat, row]),
                                         confirmedSetCount: 0, showsCurrent: false)
        XCTAssertEqual(rail?.segments.map(\.id), sessionRail.segments.map(\.id))
        XCTAssertEqual(rail?.segments.map(\.hasPrevious), [true, false, false, false, false])
        if case .session = rail?.label {} else { XCTFail("One source session names its day") }

        let mixed = WorkoutPreviousRail(exercises: [squat, row]) { id in
            self.recorded([[self.set(16, 10)]], id: id, session: UUID())
        }
        XCTAssertEqual(mixed?.label, .mixed, "Different sessions never share one day label")

        XCTAssertNil(WorkoutPreviousRail(exercises: [squat]) { _ in .noRecordedSets(hasUnknownDetails: false) })
        XCTAssertNil(WorkoutPreviousRail(exercises: [squat]) { _ in .unavailable })
    }

    // MARK: Finish card

    func testFinishBarsUseOnlyMatchedLoadsAndKeepPartialExercisesFactual() {
        let squat = WorkoutExercise(plan: plan("goblet-squat", sets: 2), completedSets: [set(16, 12), set(16, 11)])
        let bench = WorkoutExercise(plan: plan("dumbbell-bench-press", sets: 2), completedSets: [set(20, 8)])
        let row = WorkoutExercise(plan: plan("dumbbell-row", sets: 2))
        let finish = WorkoutFinishComparison(exercises: [squat, bench, row]) { id in
            switch id {
            case "goblet-squat": return self.recorded([[self.set(16, 10), self.set(16, 10)]], id: id)
            case "dumbbell-bench-press": return self.recorded([[self.set(18, 8), self.set(18, 8)]], id: id)
            default: return .noRecordedSets(hasUnknownDetails: false)
            }
        }
        XCTAssertEqual(finish.rows.count, 3, "Occurrences stay separate, including unstarted ones")
        XCTAssertEqual(finish.rows[0].pairedReps?.today, 23)
        XCTAssertEqual(finish.rows[0].pairedReps?.previous, 20)
        XCTAssertNil(finish.rows[1].pairedReps, "A heavier load is not drawn as a rep bar")
        XCTAssertEqual(finish.rows[1].comparison?.kind, .load)
        XCTAssertEqual(finish.rows[1].savedSetCount, 1)
        XCTAssertEqual(finish.rows[1].plannedSetCount, 2)
        XCTAssertNil(finish.rows[2].comparison)
        XCTAssertEqual(finish.comparedCount, 2)
        XCTAssertEqual(finish.upCount, 2)
        XCTAssertEqual(finish.volume, Load(16 * 23 + 20 * 8))
    }

    func testVolumeIsLeftOutForMixedUnitsTimedOrUnknownSideSets() {
        let kilos = WorkoutExercise(plan: plan("goblet-squat"), completedSets: [set(16, 10)])
        let pounds = WorkoutExercise(plan: plan("dumbbell-row"), completedSets: [set(35, 10, unit: .pounds)])
        let unknownSide = WorkoutExercise(plan: plan("lunge"), completedSets: [set(10, 10, perSide: nil)])
        let timed = WorkoutExercise(plan: plan("plank"), completedSets: [set(0, 0, seconds: 30)])
        let none: (ExerciseID) -> PreviousExercisePerformanceState = { _ in .noRecordedSets(hasUnknownDetails: false) }
        XCTAssertNil(WorkoutFinishComparison(exercises: [kilos, pounds], previous: none).volume)
        XCTAssertNil(WorkoutFinishComparison(exercises: [kilos, unknownSide], previous: none).volume)
        XCTAssertNil(WorkoutFinishComparison(exercises: [kilos, timed], previous: none).volume)
        XCTAssertNil(WorkoutFinishComparison(exercises: [timed], previous: none).rows[0].savedReps)
        XCTAssertEqual(WorkoutFinishComparison(exercises: [kilos], previous: none).volume, Load(160))
    }

    func testFinishWithoutComparableHistoryClaimsNothing() {
        let squat = WorkoutExercise(plan: plan(), completedSets: [set(16, 10)])
        for state in [PreviousExercisePerformanceState.unavailable, .noRecordedSets(hasUnknownDetails: true),
                      recorded([[set(16, 8)]], newerUnknown: true)] {
            let finish = WorkoutFinishComparison(exercises: [squat]) { _ in state }
            XCTAssertNil(finish.rows[0].comparison)
            XCTAssertNil(finish.rows[0].pairedReps)
            XCTAssertEqual(finish.upCount, 0)
        }
    }

    func testFinishDoesNotCompareUnknownSideConventions() {
        let unknown = WorkoutExercise(plan: plan(), completedSets: [set(16, 12, perSide: nil)])
        let finish = WorkoutFinishComparison(exercises: [unknown]) { _ in
            self.recorded([[self.set(16, 10, perSide: nil)]])
        }
        XCTAssertNil(finish.rows[0].comparison)
        XCTAssertNil(finish.rows[0].pairedReps)
        XCTAssertEqual(finish.upCount, 0)
        XCTAssertEqual(finish.rows[0].savedReps, 12, "Actual saved facts remain visible")

        let known = WorkoutExercise(plan: plan(), completedSets: [set(16, 12, perSide: true)])
        let perSide = WorkoutFinishComparison(exercises: [known]) { _ in
            self.recorded([[self.set(16, 10, perSide: true)]])
        }
        XCTAssertEqual(perSide.rows[0].comparison?.kind, .reps)
        XCTAssertEqual(perSide.rows[0].pairedReps?.today, 12)
    }

    func testExerciseDisplayComparisonRejectsOverflowAndInvalidSavedFacts() {
        let previous = recorded([[set(16, 10), set(16, 10)]])
        XCTAssertNil(WorkoutComparisonPresentation.exerciseComparison(
            savedSets: [set(16, Int.max), set(16, 1)], previousPerformance: previous))
        XCTAssertNil(WorkoutComparisonPresentation.exerciseComparison(
            savedSets: [set(.infinity, 12)], previousPerformance: previous))
        XCTAssertNil(WorkoutComparisonPresentation.exerciseComparison(
            savedSets: [set(16, -1)], previousPerformance: previous))
    }

    func testFinishRepetitionTotalExcludesSecondsAndRejectsOverflow() {
        let timed = set(0, 0, seconds: 30)
        XCTAssertNil(WorkoutComparisonPresentation.recordedRepetitions(in: [timed]))
        XCTAssertEqual(WorkoutComparisonPresentation.recordedRepetitions(in: [set(16, 8), timed, set(16, 10)]), 18)
        XCTAssertNil(WorkoutComparisonPresentation.recordedRepetitions(in: [set(16, Int.max), set(16, 1)]))
        XCTAssertNil(WorkoutComparisonPresentation.recordedRepetitions(in: [set(16, -1)]))
    }

    // MARK: Finish celebration

    func testConfettiOnlyForALiveNewSaveAndNeverReplays() {
        XCTAssertTrue(WorkoutFinishConfetti.celebrates(latched: nil, presentsLive: true, reduceMotion: false))
        // Recovery, reconciliation and relaunch never present live.
        XCTAssertFalse(WorkoutFinishConfetti.celebrates(latched: nil, presentsLive: false, reduceMotion: false))
        // Reduce Motion reaches the same end state with no confetti.
        XCTAssertFalse(WorkoutFinishConfetti.celebrates(latched: nil, presentsLive: true, reduceMotion: true))
        // Decided at first appearance: the live flag is consumed right after,
        // and a later render keeps the first decision either way.
        XCTAssertTrue(WorkoutFinishConfetti.celebrates(latched: true, presentsLive: false, reduceMotion: false))
        XCTAssertFalse(WorkoutFinishConfetti.celebrates(latched: false, presentsLive: true, reduceMotion: false))
    }
}
