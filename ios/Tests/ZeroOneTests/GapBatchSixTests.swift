import XCTest
@testable import ZeroOne

/// Proof 43 "Week in review".
final class GapBatchSixTests: XCTestCase {
    private func review(workouts: Int, planned: Int?, previousFull: Bool = false,
                        rows: [WeekInReview.Row] = [], wentUp: [String] = [], ending: Bool = false) -> WeekInReview {
        WeekInReview(start: .now, end: .now.addingTimeInterval(7 * 86_400), days: [], workouts: workouts,
                     plannedDays: planned, previousWeekFull: previousFull, rows: rows, wentUp: wentUp, isWeekEnding: ending)
    }

    func testTheHeadlineAndCoachSayOnlyWhatWasSaved() {
        let full = review(workouts: 3, planned: 3, previousFull: true, rows: [
            .init(group: .legs, done: 14, plan: 10 ... 14), .init(group: .back, done: 7, plan: 9 ... 12)],
            wentUp: ["Squat", "Bench press"])
        XCTAssertEqual(full.headline(.english), "A full week.")
        XCTAssertEqual(full.coachLines(.english), [
            "3 of 3, the second full week in a row.",
            "Squat and Bench press both went up. Back had the fewest hard sets."])

        XCTAssertEqual(review(workouts: 0, planned: 3).headline(.english), "Nothing saved yet.")
        XCTAssertEqual(review(workouts: 2, planned: 3).headline(.english), "2 of 3 so far.")
        XCTAssertEqual(review(workouts: 1, planned: nil).headline(.english), "1 workout so far.")
        XCTAssertTrue(review(workouts: 1, planned: nil).coachLines(.english).isEmpty)
    }

    func testTheShortfallIsTheGroupFurthestUnderThePlan() {
        let week = review(workouts: 3, planned: 3, rows: [
            .init(group: .chest, done: 11, plan: 9 ... 12), .init(group: .back, done: 7, plan: 9 ... 12),
            .init(group: .arms, done: 3, plan: 4 ... 8)], ending: true)
        XCTAssertEqual(week.shortfall?.group, .back)
        XCTAssertEqual(week.shortfall?.sets, 2)
        XCTAssertNil(review(workouts: 3, planned: 3, rows: [.init(group: .arms, done: 3, plan: 4 ... 8)]).shortfall,
                     "One set under is not worth a note")
    }

    /// Proof 24: the trend articles are complete, sourced and graded, and still drafts.
    func testTrendArticlesShipWithSourcesAndAGrade() {
        let ids = ["diet-glp1", "diet-intermittent-fasting", "diet-peptides"]
        let lessons = DietLearnCatalog.lessons.filter { ids.contains($0.id) }
        XCTAssertEqual(lessons.map(\.id), ids, "None was dropped by the validity filter")
        XCTAssertEqual(lessons.compactMap(\.grade?.level), [.strong, .moderate, .limited])
        XCTAssertFalse(DietLearnCatalog.isReviewed)
    }

    /// Proof 42: off by default, and never out of the iPhone speaker.
    @MainActor
    func testTheSpokenCoachIsOffByDefaultAndNeedsHeadphones() {
        let coach = WorkoutSpokenCoach()
        XCTAssertEqual(WorkoutSpokenCoach.Speed.allCases.map(\.rate), WorkoutSpokenCoach.Speed.allCases.map(\.rate).sorted())
        guard !coach.headphonesConnected else { return }
        coach.say("Last time 16 kg for 10.", language: .english, force: true)
        XCTAssertFalse(coach.isSpeaking, "No headphones, no voice")
    }

    /// Proof 50: abusive lines are held; gym talk passes.
    func testTheWordFilterHoldsAbuseAndLetsTrainingTalkThrough() {
        for clean in ["Killer leg day, brutal last set", "Squat 80 kg × 5, felt strong!", "Pedal to the metal",
                      "Страхотна тренировка днес", "Dick Smith's bench program", ""] {
            XCTAssertTrue(ClubWordFilter.isClean(clean), clean)
        }
        for held in ["Theo you absolute fuuuuck, skip legs again", "f4ggot", "kill yourself", "мамка ти", "ти си курва"] {
            XCTAssertFalse(ClubWordFilter.isClean(held), held)
        }
        XCTAssertEqual(ClubWordFilter.masked("you absolute b1tch, skip legs"), "you absolute ****, skip legs")
    }

    func testMusclesFoldIntoSixGroupsAndUnknownNamesStayOut() {
        XCTAssertEqual(WeekInReview.Area.groups(["quadriceps", "gluteus maximus", "hamstrings"]), [.legs])
        XCTAssertEqual(WeekInReview.Area.groups(["pectoralis major", "triceps", "anterior deltoid"]), [.chest, .arms, .shoulders])
        XCTAssertTrue(WeekInReview.Area.groups(["something new"]).isEmpty)
    }
}
