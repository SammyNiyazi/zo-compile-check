import XCTest
@testable import ZeroOne

/// The coach line restates acknowledged facts through existing authorities.
/// These tests pin the English copy, the paired Bulgarian copy and the rule
/// that unknown, incompatible or unavailable history never earns a claim.
final class WorkoutCoachLinesTests: XCTestCase {
    private let english = WorkoutCoachLines(localization: AppLocalization(language: .english))
    private let bulgarian = WorkoutCoachLines(localization: AppLocalization(language: .bulgarian))
    private let reps = WorkingSetPrescription(unit: .repetitions, lowerBound: 8, upperBound: 12)
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func set(_ load: Double, _ count: Int, perSide: Bool? = false, seconds: Int? = nil) -> CompletedSet {
        CompletedSet(load: Load(load), reps: seconds == nil ? count : 0, completedAt: base,
                     durationSeconds: seconds, isPerSide: perSide)
    }

    private func plan(load: Double = 16) -> ExercisePlan {
        ExercisePlan(exerciseID: "goblet-squat", name: "Goblet squat", targetLoad: Load(load),
                     targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90, previousPerformance: [])
    }

    private func recorded(_ sets: [CompletedSet], newerUnknown: Bool = false) -> PreviousExercisePerformanceState {
        .recorded(RecordedExercisePerformance(
            sessionID: UUID(), sessionTitle: "Full Body A", completedAt: base.addingTimeInterval(-86_400 * 3),
            occurrences: [WorkoutHistoryExercise(exercise: WorkoutExercise(plan: plan(), completedSets: sets))],
            hasNewerUnknownDetails: newerUnknown
        ))
    }

    private func facts(_ state: PreviousExercisePerformanceState, today: [CompletedSet] = [],
                       current: Int = 1) -> WorkoutComparisonPresentation {
        WorkoutComparisonPresentation(state: state, confirmedSets: today, currentSet: current,
                                      plannedSetCount: 2, prescription: reps)
    }

    private func target(_ coach: WorkoutCoachLines, _ state: PreviousExercisePerformanceState,
                        today: [CompletedSet] = [], setNumber: Int = 1, swapped: Bool = false,
                        load: Double = 16) -> WorkoutCoachLine {
        coach.target(plan: plan(load: load), isSwappedIn: swapped, setNumber: setNumber,
                     comparison: facts(state, today: today, current: setNumber))
    }

    private func assertBulgarian(_ english: WorkoutCoachLine, _ bulgarian: WorkoutCoachLine,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(bulgarian.plainText, english.plainText, "Bulgarian copy is paired, not a fallback",
                          file: file, line: line)
        XCTAssertFalse(bulgarian.plainText.contains("\u{2014}"), file: file, line: line)
        XCTAssertFalse(english.plainText.contains("\u{2014}"), file: file, line: line)
        XCTAssertEqual(bulgarian.parts.filter(\.isEmphasis).count, english.parts.filter(\.isEmphasis).count,
                       "Translations keep every emphasized fact", file: file, line: line)
    }

    func testResponseKeepsUnknownSideFactsNeutralEvenIfLegacyAuthorityReturnedAGain() {
        let saved = set(16, 12, perSide: nil)
        let previous = set(16, 10, perSide: nil)
        let legacy = WorkoutSetResponse(savedSet: saved, previousSet: previous, kind: .upReps)
        let line = english.response(savedSet: saved, setNumber: 1, targetReps: RepRange(8, 12),
                                    response: legacy, history: .recorded(at: base, hasNewerUnknownDetails: false))
        XCTAssertEqual(line.plainText, "16 kg × 12 reps saved.")
        XCTAssertFalse(line.plainText.contains("more than"))
    }

    func testResponseRejectsChangedFactsWithTheSameIDAndUnknownHistory() {
        let saved = set(16, 12)
        let changed = CompletedSet(id: saved.id, load: saved.load, reps: 13,
                                   completedAt: saved.completedAt, isPerSide: false)
        let stale = WorkoutSetResponse(savedSet: changed, previousSet: set(16, 10), kind: .upReps)
        XCTAssertEqual(english.response(savedSet: saved, setNumber: 1, targetReps: RepRange(8, 12),
                                       response: stale, history: .recorded(at: base, hasNewerUnknownDetails: false)).plainText,
                       "16 kg × 12 reps saved.")
        let response = WorkoutSetResponse(savedSet: saved, previousSet: set(16, 10), kind: .upReps)
        XCTAssertEqual(english.response(savedSet: saved, setNumber: 1, targetReps: RepRange(8, 12),
                                       response: response, history: .recorded(at: base, hasNewerUnknownDetails: true)).plainText,
                       "16 kg × 12 reps saved.")
    }

    // MARK: Before a set

    func testFirstTimeUsesThePlanTargetAndNeverInventsOne() {
        let first = target(english, .noRecordedSets(hasUnknownDetails: false))
        XCTAssertEqual(first.plainText, "First time with this one. Start light: 16 kg × 8–12 reps.")
        XCTAssertEqual(first.parts.filter(\.isEmphasis).map(\.value), ["16 kg", "8–12 reps"])
        assertBulgarian(first, target(bulgarian, .noRecordedSets(hasUnknownDetails: false)))

        let bodyweight = target(english, .noRecordedSets(hasUnknownDetails: false), load: 0)
        XCTAssertEqual(bodyweight.plainText, "First time with this one. Start light.")

        let swap = target(english, .noRecordedSets(hasUnknownDetails: false), swapped: true)
        XCTAssertEqual(swap.plainText, "New one for you, so start easy: 16 kg × 8–12 reps.")
        assertBulgarian(swap, target(bulgarian, .noRecordedSets(hasUnknownDetails: false), swapped: true))
        XCTAssertEqual(target(english, .noRecordedSets(hasUnknownDetails: false), swapped: true, load: 0).plainText,
                       "New one for you, so start easy.")

        let later = target(english, .noRecordedSets(hasUnknownDetails: false), today: [set(16, 10)], setNumber: 2)
        XCTAssertEqual(later.plainText, "No last time yet. Today sets the bar.")
        assertBulgarian(later, target(bulgarian, .noRecordedSets(hasUnknownDetails: false),
                                      today: [set(16, 10)], setNumber: 2))
    }

    func testUnknownUnavailableAndNewerUnknownHistoryStayNeutral() {
        let unknown = target(english, .noRecordedSets(hasUnknownDetails: true))
        XCTAssertEqual(unknown.plainText, "Earlier sessions have no set details to compare.")
        assertBulgarian(unknown, target(bulgarian, .noRecordedSets(hasUnknownDetails: true)))

        let unavailable = target(english, .unavailable)
        XCTAssertEqual(unavailable.plainText, "No history to compare right now. Log what you do today.")
        assertBulgarian(unavailable, target(bulgarian, .unavailable))

        let barrier = target(english, recorded([set(16, 10)], newerUnknown: true))
        XCTAssertEqual(barrier.plainText, "Newer sessions have no set details, so today isn't compared.")
        assertBulgarian(barrier, target(bulgarian, recorded([set(16, 10)], newerUnknown: true)))

        for line in [unknown, unavailable, barrier] {
            XCTAssertFalse(line.plainText.contains("16"), "No earlier number leaks through a barrier")
            XCTAssertTrue(line.parts.allSatisfy { !$0.isEmphasis })
        }
    }

    func testRecordedTargetQuotesLastTimeAndThePlansOwnTarget() {
        let line = target(english, recorded([set(16, 10), set(16, 9)]))
        XCTAssertEqual(line.plainText, "Last time 16 kg × 10 reps. Target today: 8–12 reps.")
        XCTAssertEqual(line.parts.filter(\.isEmphasis).map(\.value), ["16 kg", "10 reps", "8–12 reps"])
        assertBulgarian(line, target(bulgarian, recorded([set(16, 10), set(16, 9)])))

        let bodyweight = target(english, recorded([set(0, 15)]))
        XCTAssertEqual(bodyweight.plainText, "Last time 15 reps. Target today: 8–12 reps.")

        let missing = target(english, recorded([set(16, 10)]), today: [set(16, 10)], setNumber: 2)
        XCTAssertEqual(missing.plainText, "Last time had no set 2. Today sets the bar.")
        assertBulgarian(missing, target(bulgarian, recorded([set(16, 10)]), today: [set(16, 10)], setNumber: 2))
    }

    func testIncomparableLastTimeIsShownButNotComparedWithTodaysTarget() {
        let perSide = target(english, recorded([set(16, 10, perSide: true)]))
        XCTAssertEqual(perSide.plainText, "Last time 16 kg · 10 reps per side. It isn't compared with today's target.")
        assertBulgarian(perSide, target(bulgarian, recorded([set(16, 10, perSide: true)])))

        let timed = target(english, recorded([set(0, 0, seconds: 45)]))
        XCTAssertTrue(timed.plainText.hasSuffix("It isn't compared with today's target."))
        XCTAssertFalse(timed.plainText.contains("Target today"))
    }

    // MARK: After a save

    private func response(_ saved: CompletedSet, _ previous: CompletedSet,
                          _ kind: WorkoutSetResponse.Kind) -> WorkoutSetResponse {
        WorkoutSetResponse(savedSet: saved, previousSet: previous, kind: kind)
    }

    private func reply(_ coach: WorkoutCoachLines, _ saved: CompletedSet, _ kind: WorkoutSetResponse.Kind?,
                       previous: CompletedSet? = nil, setNumber: Int = 1,
                       history: WorkoutComparisonPresentation.History = .recorded(at: Date(timeIntervalSince1970: 0),
                                                                                  hasNewerUnknownDetails: false))
        -> WorkoutCoachLine {
        coach.response(savedSet: saved, setNumber: setNumber, targetReps: RepRange(8, 12),
                       response: kind.map { response(saved, previous ?? saved, $0) }, history: history)
    }

    func testEachResponseKindRestatesOnlyTheExistingComparison() {
        let cases: [(CompletedSet, CompletedSet, WorkoutSetResponse.Kind, String)] = [
            (set(16, 12), set(16, 10), .upReps, "12 reps. 2 reps more than last time."),
            (set(18, 10), set(16, 10), .up, "18 kg × 10 reps. Up from 16 kg · 10 reps last time."),
            (set(16, 10), set(16, 10), .same, "16 kg × 10 reps. Same as last time."),
            (set(0, 15), set(0, 15), .same, "15 reps. Same as last time."),
            (set(18, 9), set(16, 10), .heavierIn, "9 reps at 18 kg. Heavier than last time and inside your target."),
            (set(18, 7), set(16, 10), .heavierBelow, "7 reps at 18 kg. Heavier than last time. It all counts."),
            (set(16, 8), set(16, 10), .fewer, "8 reps, 2 reps fewer than last time. It all counts."),
            (set(16, 5), set(16, 10), .fewer, "5 reps. Some days are like that. It all counts."),
            (set(14, 10), set(16, 10), .lighter, "14 kg × 10 reps. Lighter than last time. It all counts.")
        ]
        for (saved, previous, kind, expected) in cases {
            let line = reply(english, saved, kind, previous: previous)
            XCTAssertEqual(line.plainText, expected)
            XCTAssertFalse(line.plainText.localizedCaseInsensitiveContains("best"))
            XCTAssertFalse(line.plainText.localizedCaseInsensitiveContains("one more"))
            assertBulgarian(line, reply(bulgarian, saved, kind, previous: previous))
        }
    }

    func testWithoutAMatchingResponseTheLineOnlyRestatesTheSave() {
        let saved = set(16, 10)
        let plain = reply(english, saved, nil)
        XCTAssertEqual(plain.plainText, "16 kg × 10 reps saved.")
        assertBulgarian(plain, reply(bulgarian, saved, nil))
        XCTAssertEqual(reply(english, set(0, 15), nil).plainText, "15 reps saved.")

        let stale = english.response(savedSet: saved, setNumber: 1, targetReps: RepRange(8, 12),
                                     response: response(set(16, 12), set(16, 10), .upReps),
                                     history: .recorded(at: base, hasNewerUnknownDetails: false))
        XCTAssertEqual(stale.plainText, "16 kg × 10 reps saved.", "A response for another set is never shown")

        let first = reply(english, saved, nil, history: .none(hasUnknownDetails: false))
        XCTAssertEqual(first.plainText, "16 kg × 10 reps. Your first set with this one is saved.")
        assertBulgarian(first, reply(bulgarian, saved, nil, history: .none(hasUnknownDetails: false)))
        XCTAssertEqual(reply(english, set(0, 15), nil, history: .none(hasUnknownDetails: false)).plainText,
                       "15 reps. Your first set with this one is saved.")
        XCTAssertEqual(reply(english, saved, nil, setNumber: 2, history: .none(hasUnknownDetails: false)).plainText,
                       "16 kg × 10 reps saved.")
        XCTAssertEqual(reply(english, saved, nil, history: .none(hasUnknownDetails: true)).plainText,
                       "16 kg × 10 reps saved.", "Unknown details are not a first time")
    }

    // MARK: Between exercises

    private func comparison(_ kind: WorkoutExerciseComparison.Kind, now: Double = 16, before: Double = 16,
                            repsNow: Int = 20, repsBefore: Int = 20) -> WorkoutExerciseComparison {
        WorkoutExerciseComparison(kind: kind, topLoadNow: Load(now), topLoadBefore: Load(before),
                                  repsNow: repsNow, repsBefore: repsBefore, comparedSetCount: 2)
    }

    func testHandoffJudgesTheFinishedOccurrenceOnlyThroughTheExistingComparison() {
        let cases: [(WorkoutExerciseComparison?, String)] = [
            (nil, "Goblet squat done: 2 sets saved."),
            (comparison(.reps, repsNow: 23), "Goblet squat done: 3 reps more than last time."),
            (comparison(.load, now: 18), "Goblet squat done: top set 18 kg, up from 16 kg."),
            (comparison(.same), "Goblet squat done: matched last time."),
            (comparison(.under, repsNow: 18), "Goblet squat done: 2 sets saved. It all counts."),
            (comparison(.lighter, now: 14), "Goblet squat done: 2 sets saved. It all counts."),
            (comparison(.mixed), "Goblet squat done: 2 sets saved. It all counts.")
        ]
        for (facts, expected) in cases {
            let line = english.handoff(exerciseName: "Goblet squat", savedSetCount: 2, comparison: facts)
            XCTAssertEqual(line.plainText, expected)
            assertBulgarian(line, bulgarian.handoff(exerciseName: "Goblet squat", savedSetCount: 2, comparison: facts))
        }
    }

    // MARK: Finish

    private func finish(_ sets: [CompletedSet], previous: PreviousExercisePerformanceState) -> WorkoutFinishComparison {
        WorkoutFinishComparison(exercises: [WorkoutExercise(plan: plan(), completedSets: sets)]) { _ in previous }
    }

    private func upgrade() -> WorkoutCompletionUpgrade {
        WorkoutCompletionUpgrade(exerciseID: "goblet-squat", exerciseName: "Goblet squat",
                                 opportunity: WorkoutProgressionOpportunity(previousLoad: Load(16), suggestedLoad: Load(18)),
                                 completedSets: [set(16, 12), set(16, 12)], targetRepUpperBound: 12)
    }

    func testWrapUpCountsSavedWorkAndKeepsPartialSessionsTruthful() {
        let none = finish([set(16, 10), set(16, 10)], previous: .noRecordedSets(hasUnknownDetails: false))
        let full = english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false, finish: none, upgrade: nil)
        XCTAssertEqual(full.map(\.plainText), ["2 of 2 sets. Nothing skipped."])

        let partial = english.wrapUp(completedSetCount: 1, plannedSetCount: 2, endedEarly: true, finish: none, upgrade: nil)
        XCTAssertEqual(partial.map(\.plainText), ["1 of 2 sets saved. Unlogged sets stay unlogged."])
        let partialBG = bulgarian.wrapUp(completedSetCount: 1, plannedSetCount: 2, endedEarly: true, finish: none, upgrade: nil)
        assertBulgarian(partial[0], partialBG[0])
        assertBulgarian(full[0], bulgarian.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false,
                                                  finish: none, upgrade: nil)[0])

        let earlyButFull = english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: true,
                                          finish: none, upgrade: nil)
        XCTAssertEqual(earlyButFull[0].plainText, "2 of 2 sets saved. Unlogged sets stay unlogged.")
    }

    func testWrapUpSecondLineComesOnlyFromComparisonsOrTheExistingUpgrade() {
        let up = finish([set(16, 12), set(16, 11)], previous: recorded([set(16, 10), set(16, 10)]))
        let upLines = english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false, finish: up, upgrade: upgrade())
        XCTAssertEqual(upLines.count, 2)
        XCTAssertEqual(upLines[1].plainText, "Up on 1 of 1 compared exercises.", "A gain outranks the upgrade line")
        assertBulgarian(upLines[1], bulgarian.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false,
                                                     finish: up, upgrade: upgrade())[1])

        let none = finish([set(16, 12), set(16, 12)], previous: .noRecordedSets(hasUnknownDetails: false))
        let offered = english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false, finish: none, upgrade: upgrade())
        XCTAssertEqual(offered[1].plainText, "Next time, Goblet squat can step up to 18 kg. Your choice is below.")
        assertBulgarian(offered[1], bulgarian.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false,
                                                     finish: none, upgrade: upgrade())[1])

        let level = finish([set(16, 10), set(16, 10)], previous: recorded([set(16, 10), set(16, 10)]))
        let matched = english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false, finish: level, upgrade: nil)
        XCTAssertEqual(matched[1].plainText, "Matched last time on every compared exercise.")
        assertBulgarian(matched[1], bulgarian.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false,
                                                     finish: level, upgrade: nil)[1])

        let unknown = finish([set(16, 12)], previous: recorded([set(16, 10)], newerUnknown: true))
        XCTAssertEqual(english.wrapUp(completedSetCount: 1, plannedSetCount: 2, endedEarly: true,
                                      finish: unknown, upgrade: nil).count, 1, "No comparison, no second claim")
        XCTAssertEqual(english.wrapUp(completedSetCount: 2, plannedSetCount: 2, endedEarly: false,
                                      finish: none, upgrade: nil).count, 1)
    }

    // MARK: Emphasis

    func testEmphasisMarkersParseAndNamesAreInsertedVerbatim() {
        let parsed = WorkoutCoachLines.parse("Last time \u{E000}16 kg\u{E001}. Done.")
        XCTAssertEqual(parsed.parts, [.text("Last time "), .emphasis("16 kg"), .text(". Done.")])
        XCTAssertEqual(parsed.plainText, "Last time 16 kg. Done.")

        let damaged = WorkoutCoachLines.parse("\u{E001}16 kg\u{E000}")
        XCTAssertEqual(damaged.plainText, "16 kg", "An unpaired marker degrades to plain text")
        XCTAssertEqual(WorkoutCoachLines.parse("").parts, [])

        XCTAssertEqual(WorkoutCoachLines.verbatim("Squat\u{E000} \u{E001}%1$@"), "Squat %1$@")
        let named = english.handoff(exerciseName: "Squat\u{E000}", savedSetCount: 1, comparison: nil)
        XCTAssertEqual(named.plainText, "Squat done: 1 set saved.")
        XCTAssertEqual(named.parts.first, .text("Squat done: "), "A name never opens an emphasis run")
    }

    func testTakeoverLabelsAreTranslatedNotCopied() {
        let en = AppLocalization(language: .english)
        let bg = AppLocalization(language: .bulgarian)
        XCTAssertEqual(en.string("Up next"), "Up next")
        XCTAssertEqual(bg.string("Up next"), "Следва")
        XCTAssertEqual(en.string("Your first workout"), "Your first workout")
        XCTAssertEqual(bg.string("Your first workout"), "Първата ти тренировка")
    }
}

private extension WorkoutCoachLine.Part {
    var isEmphasis: Bool {
        if case .emphasis = self { return true }
        return false
    }

    var value: String {
        switch self {
        case let .text(value), let .emphasis(value): return value
        }
    }
}
