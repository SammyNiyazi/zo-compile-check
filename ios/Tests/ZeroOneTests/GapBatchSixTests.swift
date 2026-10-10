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

    func testMusclesFoldIntoSixGroupsAndUnknownNamesStayOut() {
        XCTAssertEqual(WeekInReview.Area.groups(["quadriceps", "gluteus maximus", "hamstrings"]), [.legs])
        XCTAssertEqual(WeekInReview.Area.groups(["pectoralis major", "triceps", "anterior deltoid"]), [.chest, .arms, .shoulders])
        XCTAssertTrue(WeekInReview.Area.groups(["something new"]).isEmpty)
    }
}
