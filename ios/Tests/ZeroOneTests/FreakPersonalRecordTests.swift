import SwiftUI
import XCTest
@testable import ZeroOne

/// Freak "New PR" slam: evidence, timing and the sigil drawing (study 30 themes.freak.celebration).
final class FreakPersonalRecordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)

    func testBeatingEveryEarlierSetEarnsTheSlam() {
        let earlier = entry(load: 40, reps: 8, at: now.addingTimeInterval(-86_400))
        XCTAssertTrue(earned(current: [(42.5, 8)], history: [earlier]))
        XCTAssertTrue(earned(current: [(40, 9)], history: [earlier]), "More reps at the same load is a record")
    }

    func testMatchingOrLosingToAnEarlierSetIsNotARecord() {
        let best = entry(load: 45, reps: 8, at: now.addingTimeInterval(-2 * 86_400))
        let recent = entry(load: 40, reps: 8, at: now.addingTimeInterval(-86_400))
        XCTAssertFalse(earned(current: [(42.5, 8)], history: [best, recent]), "An older heavier set still stands")
        XCTAssertFalse(earned(current: [(45, 8)], history: [best]), "Matching is not beating")
    }

    func testFirstTimeAndUnknownHistoryNeverClaimARecord() throws {
        XCTAssertFalse(earned(current: [(100, 10)], history: []), "Nothing to beat on the first time")
        let earlier = entry(load: 40, reps: 8, at: now.addingTimeInterval(-86_400))
        XCTAssertFalse(earned(current: [(42.5, 8)], history: [earlier], available: false))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            entry(load: 50, reps: 8, at: now.addingTimeInterval(-3 * 86_400)))) as? [String: Any])
        json.removeValue(forKey: "exercises")
        let summary = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(earned(current: [(42.5, 8)], history: [earlier, summary]),
            "A workout saved without exercise detail could hide a better set")
    }

    func testThisWorkoutAndLaterWorkoutsAreNotEarlierEvidence() {
        let later = entry(load: 60, reps: 8, at: now.addingTimeInterval(60))
        let earlier = entry(load: 40, reps: 8, at: now.addingTimeInterval(-86_400))
        XCTAssertTrue(earned(current: [(42.5, 8)], history: [earlier, later]))
    }

    func testSlamLandsFromOnePointSixOnBraceAndRestsAtMinusSix() {
        let start = ThemeWinTimeline.freakSlam(elapsed: 0, reduceMotion: false)
        XCTAssertEqual(start.scale, 1.6, accuracy: 0.0001)
        XCTAssertEqual(start.opacity, 0, accuracy: 0.0001)
        XCTAssertEqual(start.rotation, -7)
        let rest = ThemeWinTimeline.freakSlam(elapsed: 0.24, reduceMotion: false)
        XCTAssertEqual(rest.scale, 1); XCTAssertEqual(rest.opacity, 1); XCTAssertEqual(rest.rotation, -6)
        let still = ThemeWinTimeline.freakSlam(elapsed: 0, reduceMotion: true)
        XCTAssertEqual(still.scale, 1); XCTAssertEqual(still.opacity, 1)
    }

    func testShakeIsSixPointsOnceAfterQuickMinusTickAndNeverUnderReduceMotion() {
        XCTAssertEqual(ThemeWinTimeline.freakShake(elapsed: 0.1, reduceMotion: false), .zero)
        XCTAssertEqual(ThemeWinTimeline.freakShake(elapsed: 0.18 + 0.24, reduceMotion: false), .zero)
        var widest: CGFloat = 0
        for step in 0...240 {
            let offset = ThemeWinTimeline.freakShake(elapsed: 0.18 + Double(step) / 1_000, reduceMotion: false)
            widest = max(widest, abs(offset.width))
            XCTAssertLessThanOrEqual(abs(offset.height), 3.0001)
        }
        XCTAssertEqual(widest, 6, accuracy: 0.5) // 1 ms samples straddle the keyframe peak
        for step in 0...420 {
            XCTAssertEqual(ThemeWinTimeline.freakShake(elapsed: Double(step) / 1_000, reduceMotion: true), .zero)
        }
    }

    func testSigilWingsAreSymmetricAndFillThe340By68Box() {
        let bounds = FreakSigilWings().path(in: CGRect(x: 0, y: 0, width: 340, height: 68)).boundingRect
        XCTAssertEqual(bounds.midX, 170, accuracy: 0.5)
        XCTAssertGreaterThan(bounds.width, 320)
        XCTAssertLessThanOrEqual(bounds.height, 68.01)
    }

    // MARK: Fixtures

    private func earned(current: [(Double, Int)], history: [WorkoutHistoryEntry], available: Bool = true) -> Bool {
        let plan = Self.plan()
        let sets = current.enumerated().map { index, value in
            CompletedSet(load: Load(value.0), reps: value.1, completedAt: now.addingTimeInterval(Double(index - 10)),
                isPerSide: false)
        }
        return WorkoutPersonalRecord.isEarned(exercises: [WorkoutExercise(plan: plan, completedSets: sets)],
            sessionID: UUID(), completedAt: now, history: history, historyAvailable: available)
    }

    private func entry(load: Double, reps: Int, at date: Date) -> WorkoutHistoryEntry {
        let set = CompletedSet(load: Load(load), reps: reps, completedAt: date.addingTimeInterval(-10), isPerSide: false)
        return WorkoutHistoryEntry(session: WorkoutSession(title: "Earlier", customWorkoutID: UUID(),
            exercises: [WorkoutExercise(plan: Self.plan(), completedSets: [set])], completedAt: date))
    }

    private static func plan() -> ExercisePlan {
        ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress, name: "Bench press", targetLoad: Load(40),
            targetReps: RepRange(8, 10), plannedSetCount: 1, restSeconds: 90, previousPerformance: [],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 10, perSide: false))
    }
}
