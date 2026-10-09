import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutMusicContextTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    func testNoSessionIsNeutralAndDoesNotSuggestAMix() {
        let suggestion = WorkoutMusicContextSuggestion(context: nil)
        XCTAssertEqual(suggestion.title, "Your soundtrack")
        XCTAssertNil(suggestion.energy)
        XCTAssertFalse(suggestion.reason.contains("today"))
    }

    func testReadySuggestionUsesActualTitleAndSelectedWarmUpLength() {
        var session = makeSession(warmUp: true)
        let original = session
        let full = WorkoutMusicContext(session: session, stage: .ready)
        XCTAssertEqual(full.phase, .ready)
        XCTAssertEqual(WorkoutMusicContextSuggestion(context: full).energy, .easy)
        XCTAssertTrue(WorkoutMusicContextSuggestion(context: full).reason.contains(session.title))
        XCTAssertEqual(session, original, "Projecting music context cannot mutate the workout")

        session.selectWarmUpLength(.none, at: date)
        let noWarmUp = WorkoutMusicContext(session: session, stage: .ready)
        XCTAssertFalse(noWarmUp.hasPlannedWarmUp)
        XCTAssertEqual(WorkoutMusicContextSuggestion(context: noWarmUp).energy, .steady)
    }

    func testWarmUpWorkingAndRestFollowActualSessionChanges() throws {
        var session = makeSession(warmUp: true)
        XCTAssertEqual(WorkoutMusicContext(session: session, stage: .active).phase, .warmUp)
        session.resolveWarmUp(as: .partial, at: date)
        XCTAssertEqual(WorkoutMusicContext(session: session, stage: .active).phase, .workingSets)
        _ = try session.completeCurrentSet(load: Load(10), reps: 8, at: date)
        let rest = WorkoutMusicContext(session: session, stage: .active)
        XCTAssertEqual(rest.phase, .resting)
        XCTAssertNil(WorkoutMusicContextSuggestion(context: rest).energy)
        session.skipRest()
        XCTAssertEqual(WorkoutMusicContext(session: session, stage: .active).phase, .workingSets)
    }

    func testAcknowledgementKeepsRestContextAfterTheTimerExpires() {
        let session = makeSession(warmUp: false)
        XCTAssertEqual(WorkoutMusicContext(session: session, stage: .active, awaitingNextSet: true).phase, .resting)
        XCTAssertEqual(WorkoutMusicContext(session: session, stage: .active,
            isPaused: true, awaitingNextSet: true).phase, .paused)
    }

    func testPausedWarmUpDoesNotSuggestStartingOrChangingMusic() {
        let context = WorkoutMusicContext(session: makeSession(warmUp: true), stage: .active, isPaused: true)
        let suggestion = WorkoutMusicContextSuggestion(context: context)
        XCTAssertEqual(context.phase, .paused)
        XCTAssertNil(suggestion.energy)
        XCTAssertTrue(suggestion.reason.contains("paused"))
    }

    func testFinalReviewIsNotAnnouncedAsFinishedAndCompletionOutranksPause() throws {
        var session = makeSession(warmUp: false)
        _ = try session.completeCurrentSet(load: Load(10), reps: 8, at: date)
        session.skipRest()
        _ = try session.completeCurrentSet(load: Load(10), reps: 8, at: date.addingTimeInterval(90))
        let review = WorkoutMusicContext(session: session, stage: .active, awaitingFinalSetConfirmation: true)
        XCTAssertEqual(review.phase, .finalReview)
        XCTAssertFalse(WorkoutMusicContextSuggestion(context: review).reason.contains("finished"))
        let completed = WorkoutMusicContext(session: session, stage: .active, isPaused: true)
        XCTAssertEqual(completed.phase, .complete)
        XCTAssertNil(WorkoutMusicContextSuggestion(context: completed).energy)
    }

    func testSessionTitleDoesNotInferHeavyTopSetsOrMedicalReadiness() {
        let session = makeSession(title: "Heavy top sets after poor sleep", warmUp: false)
        let context = WorkoutMusicContext(session: session, stage: .active)
        XCTAssertEqual(WorkoutMusicContextSuggestion(context: context).energy, .steady)
        XCTAssertEqual(context.sessionTitle, session.title)
    }

    func testBlankTitleDoesNotInventAProgramme() {
        let context = WorkoutMusicContext(session: makeSession(title: "  \n  ", warmUp: false), stage: .ready)
        XCTAssertNil(context.sessionTitle)
        XCTAssertEqual(WorkoutMusicContextSuggestion(context: context).reason,
            "Suggested for your selected workout. Choose whatever you prefer.")
    }

    func testOutdoorContextUsesKindAndNeverPretendsRecoveryIsRecording() {
        for kind in [OutdoorActivityKind.walk, .run] {
            var checkpoint = OutdoorActivityCheckpoint(kind: kind, startedAt: date,
                checkpointedAt: date, confirmedActiveSeconds: 30, phase: .recording)
            let live = WorkoutMusicContext(outdoor: checkpoint)
            XCTAssertEqual(live.activity, kind == .walk ? .walk : .run)
            XCTAssertEqual(live.phase, .recording)
            XCTAssertTrue(WorkoutMusicContextSuggestion(context: live).reason.contains(kind.rawValue))
            XCTAssertEqual(WorkoutMusicContext(outdoor: checkpoint, needsExplicitResume: true).phase, .paused)
            checkpoint.phase = .paused
            XCTAssertNil(WorkoutMusicContextSuggestion(context: WorkoutMusicContext(outdoor: checkpoint)).energy)
            checkpoint.phase = .readyToSave
            XCTAssertEqual(WorkoutMusicContext(outdoor: checkpoint).phase, .complete)
        }
    }

    private func makeSession(title: String = "Upper body A", warmUp: Bool) -> WorkoutSession {
        let plan = ExercisePlan(exerciseID: ExerciseIDs.dumbbellCurl, name: "Dumbbell Curl",
            targetLoad: Load(10), targetReps: RepRange(8, 12), plannedSetCount: 2,
            restSeconds: 60, previousPerformance: [])
        return WorkoutSession(title: title,
            warmUp: warmUp ? WorkoutWarmUp(estimatedMinutes: 4, steps: ["Easy movement", "Practice set"]) : nil,
            exercises: [WorkoutExercise(plan: plan)])
    }
}
