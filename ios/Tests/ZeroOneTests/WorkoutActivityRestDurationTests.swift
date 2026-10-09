import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutActivityRestDurationTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testLegacyNilAndMalformedOptionalDurationKeepRequiredFactsStrict() throws {
        let state = content(end: start.addingTimeInterval(90), duration: nil)
        let encoded = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["restTotalSeconds"])
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: encoded), state)
        let invalid: [Any] = [NSNull(), "90", true, [], ["seconds": 90], 0, -1]
        for value in invalid {
            object["restTotalSeconds"] = value
            let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, state)
            XCTAssertNil(decoded.restCountdownInterval)
        }
        object.removeValue(forKey: "exerciseName")
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testNonfiniteOptionalDecoderValuesBecomeUnknown() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(content(end: start, duration: nil))) as? [String: Any])
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "INF", negativeInfinity: "-INF", nan: "NAN")
        for raw in ["INF", "-INF", "NAN"] {
            object["restTotalSeconds"] = raw
            let decoded = try decoder.decode(WorkoutActivityAttributes.ContentState.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.restTotalSeconds)
            XCTAssertNil(decoded.restCountdownInterval)
        }
    }

    func testValidRoundtripAndRootPresentationCopiesPreserveDuration() throws {
        let session = try restingSession()
        let projection = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(10))
        let copied = projection.usingAccent(.pink).usingLanguage(.english).usingDesignTheme(.retro)
        XCTAssertEqual(copied.state.restTotalSeconds, 90)
        XCTAssertEqual(copied.state.restCountdownInterval, start ... start.addingTimeInterval(90))
        XCTAssertEqual(copied.sessionID, projection.sessionID)
        XCTAssertEqual(copied.staleDate, projection.staleDate)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(copied.state)), copied.state)
        var legacy = copied.state
        legacy.restTotalSeconds = nil
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: copied,
            existingSessionID: copied.sessionID, existingState: legacy), .update)
    }

    func testFractionalTargetOriginAndExpiryUseOriginalDeadline() throws {
        let session = try restingSession(duration: 90.25)
        let projected = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(10.5))
        XCTAssertEqual(projected.state.restTotalSeconds, 90.25)
        XCTAssertEqual(projected.state.restCountdownInterval, start ... start.addingTimeInterval(90.25))
        XCTAssertEqual(projected.staleDate, session.restEndsAt)
        let expired = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(90.25))
        XCTAssertNil(expired.state.restTotalSeconds)
        XCTAssertNil(expired.state.restCountdownInterval)
    }

    func testMissingInvalidAndContradictoryDurationsNeverQualify() {
        let durations: [TimeInterval?] = [nil, 0, -1, .infinity, -.infinity, .nan, .leastNonzeroMagnitude, 10]
        for duration in durations {
            let session = sessionWithFields(end: start.addingTimeInterval(90), duration: duration)
            let projected = WorkoutActivityProjector.project(snapshot(session), phase: .rest, at: start)
            XCTAssertNil(projected.state.restTotalSeconds)
            XCTAssertNil(projected.state.restCountdownInterval)
        }
        let beforeOrigin = WorkoutActivityProjector.project(
            snapshot(sessionWithFields(end: start.addingTimeInterval(90), duration: 90)),
            phase: .rest, at: start.addingTimeInterval(-1))
        XCTAssertNil(beforeOrigin.state.restTotalSeconds)
    }

    func testInvalidDatesOverflowAndRoundedEmptyIntervalsAreRejectedByMetadataOnly() {
        // Forced phase bypasses the pre-existing unguarded Int conversion in
        // session.isResting. This patch does not harden that domain resolver.
        for end in [Date(timeIntervalSinceReferenceDate: .infinity),
                    Date(timeIntervalSinceReferenceDate: .nan),
                    Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude)] {
            let duration = TimeInterval.greatestFiniteMagnitude
            XCTAssertNil(content(end: end, duration: duration).restCountdownInterval)
            let value = WorkoutActivityProjector.project(
                snapshot(sessionWithFields(end: end, duration: duration)), phase: .rest, at: start)
            XCTAssertNil(value.state.restTotalSeconds)
        }
        XCTAssertNil(content(end: start, duration: .leastNonzeroMagnitude).restCountdownInterval)
        let projected = WorkoutActivityProjector.project(
            snapshot(sessionWithFields(end: start.addingTimeInterval(90), duration: 90)),
            phase: .rest, at: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertNil(projected.state.restTotalSeconds)
    }

    func testEveryNonRestPhaseKeepsDurationUnknown() throws {
        let session = try restingSession()
        let phases: [WorkoutActivityAttributes.ContentState.Phase] =
            [.warmUp, .active, .paused, .awaitingNextSet, .readyToFinish, .saving]
        for phase in phases {
            let projected = WorkoutActivityProjector.project(snapshot(session), phase: phase, at: start)
            XCTAssertNil(projected.state.restTotalSeconds)
            XCTAssertNil(content(end: session.restEndsAt, duration: 90, phase: phase).restCountdownInterval)
        }
    }

    func testActualExtendShortenAndExerciseHandoffUseCompletedExerciseDuration() throws {
        var session = try restingSession(sets: 1, secondExercise: true)
        XCTAssertEqual(session.currentExercise?.plan.restSeconds, 15)
        session.extendRest(by: 15, at: start.addingTimeInterval(10))
        session.shortenRest(by: 5, at: start.addingTimeInterval(20))
        let projected = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(20))
        XCTAssertEqual(projected.state.restTotalSeconds, 100)
        XCTAssertEqual(projected.state.restCountdownInterval, start ... start.addingTimeInterval(100))
        XCTAssertEqual(projected.state.restTotalSeconds, session.activeRestDuration)
    }

    func testActualPausedExtensionResumeAndSkipPreserveOwnerMaximumRule() throws {
        var session = try restingSession()
        session.pauseRest(at: start.addingTimeInterval(10.25))
        session.extendPausedRest(by: 15, at: start.addingTimeInterval(20))
        let paused = WorkoutActivityProjector.project(snapshot(session, paused: true, remaining: 95), at: start)
        XCTAssertNil(paused.state.restTotalSeconds)
        XCTAssertEqual(paused.state.pausedRestSeconds, 95)
        session.resumeRest(remainingSeconds: 95, at: start.addingTimeInterval(40))
        let resumed = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(40))
        XCTAssertEqual(resumed.state.restTotalSeconds, 94.75)
        XCTAssertEqual(resumed.state.restCountdownInterval,
            start.addingTimeInterval(40) ... start.addingTimeInterval(134.75))
        XCTAssertEqual(session.exercises[0].completedSets[0].completedAt, start)
        session.skipRest(at: start.addingTimeInterval(45))
        XCTAssertNil(WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(45)).state.restTotalSeconds)
    }

    func testResumeRetainsLargerOriginalDurationWithoutClaimingHistoricalStart() throws {
        var session = try restingSession()
        session.pauseRest(at: start.addingTimeInterval(10.25))
        session.resumeRest(remainingSeconds: 80, at: start.addingTimeInterval(60))
        let projected = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(60))
        XCTAssertEqual(projected.state.restTotalSeconds, 90)
        XCTAssertEqual(projected.state.restCountdownInterval?.lowerBound, start.addingTimeInterval(49.75))
        XCTAssertEqual(session.exercises[0].completedSets[0].completedAt, start)
        XCTAssertNotEqual(projected.state.restCountdownInterval?.lowerBound, start)
    }

    func testRestoredAndLegacySnapshotsRetainKnownVersusUnknownDuration() throws {
        var session = try restingSession()
        session.markRestObservationRecovered(at: start.addingTimeInterval(10))
        let restored = try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONEncoder().encode(snapshot(session)))
        XCTAssertEqual(WorkoutActivityProjector.project(restored, at: start.addingTimeInterval(20)).state.restTotalSeconds, 90)
        XCTAssertTrue(try XCTUnwrap(restored.session.exercises[0].completedSets[0].restTimerObservation).hasUnobservedGap)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        var oldSession = try XCTUnwrap(object["session"] as? [String: Any])
        oldSession.removeValue(forKey: "activeRestDuration")
        object["session"] = oldSession
        let legacy = try JSONDecoder().decode(ActiveWorkoutSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(WorkoutActivityProjector.project(legacy, at: start.addingTimeInterval(20)).state.restTotalSeconds)
    }

    func testClosedPausedRestRestartUsesOnlyOwnerCurrentTarget() throws {
        var session = try restingSession()
        session.pauseRest(at: start.addingTimeInterval(10))
        session.skipRest(at: start.addingTimeInterval(20))
        session.extendPausedRest(by: 15, at: start.addingTimeInterval(30))
        session.resumeRest(remainingSeconds: 15, at: start.addingTimeInterval(40))
        let projected = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(40))
        XCTAssertEqual(projected.state.restTotalSeconds, 15)
        XCTAssertEqual(projected.state.restCountdownInterval,
            start.addingTimeInterval(40) ... start.addingTimeInterval(55))
        XCTAssertTrue(try XCTUnwrap(session.exercises[0].completedSets[0].restTimerObservation).hasUnobservedGap)
    }

    func testSmallPausedExtensionPreservesLargerDenominatorAndFinalSetClearsIt() throws {
        var session = try restingSession()
        session.pauseRest(at: start.addingTimeInterval(10.25))
        session.extendPausedRest(by: 5, at: start.addingTimeInterval(20))
        session.resumeRest(remainingSeconds: 85, at: start.addingTimeInterval(60))
        let projected = WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(60))
        XCTAssertEqual(projected.state.restTotalSeconds, 90)
        XCTAssertEqual(projected.state.restCountdownInterval?.lowerBound, start.addingTimeInterval(54.75))
        session.skipRest(at: start.addingTimeInterval(70))
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: start.addingTimeInterval(80))
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.activeRestDuration)
        XCTAssertNil(WorkoutActivityProjector.project(snapshot(session), at: start.addingTimeInterval(80)).state.restTotalSeconds)
    }

    func testActualVMFailedSaveRetainsConfirmedProjectionUntilRetryWritesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActiveWorkoutStore(directory: directory, legacyStore: RestDurationEmptyLegacyStore())
        var reject = false
        let model = WorkoutViewModel(session: makeSession(), onSnapshotChanged: { value, id in
            if reject { throw WorkoutPersistenceError.unavailable }
            if let value { try store.save(value) } else { try store.clear(expectedSessionID: id) }
        })
        let original = try XCTUnwrap(model.persistedActivity)
        reject = true
        model.completeCurrentSet(at: Date().addingTimeInterval(-30))
        XCTAssertNotNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.persistedActivity, original)
        XCTAssertEqual(try store.load()?.session.completedSetCount, 0)
        reject = false
        let retry = Date()
        model.retryPersistence(at: retry)
        let saved = try XCTUnwrap(store.load())
        let published = try XCTUnwrap(model.persistedActivity)
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(published.state.restTotalSeconds, saved.session.activeRestDuration)
        XCTAssertEqual(published.state.restTotalSeconds, 90)
        XCTAssertEqual(published.state.restCountdownInterval?.lowerBound, retry)
        XCTAssertEqual(published.state.restEndsAt, saved.session.restEndsAt)
    }

    private func makeSession(sets: Int = 2, duration: TimeInterval = 90, secondExercise: Bool = false) -> WorkoutSession {
        var exercises = [WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Bench", targetLoad: Load(40), targetReps: RepRange(8, 10), plannedSetCount: sets,
            restSeconds: duration, previousPerformance: []))]
        if secondExercise {
            exercises.append(WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.pushUp,
                name: "Next", targetLoad: Load(0), targetReps: RepRange(8, 10), plannedSetCount: 2,
                restSeconds: 15, previousPerformance: [])))
        }
        return WorkoutSession(title: "Rest transport", programmeID: .zeroOneStart, exercises: exercises)
    }

    private func restingSession(sets: Int = 2, duration: TimeInterval = 90, secondExercise: Bool = false) throws -> WorkoutSession {
        var session = makeSession(sets: sets, duration: duration, secondExercise: secondExercise)
        _ = try session.completeCurrentSet(load: Load(40), reps: 8, at: start)
        return session
    }

    private func sessionWithFields(end: Date?, duration: TimeInterval?) -> WorkoutSession {
        WorkoutSession(title: "Metadata validation", programmeID: .zeroOneStart, exercises: makeSession().exercises,
            restEndsAt: end, activeRestDuration: duration)
    }

    private func snapshot(_ session: WorkoutSession, paused: Bool = false, remaining: Int? = nil) -> ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(session: session, enteredLoadValue: 40, enteredReps: 8, enteredRIR: nil,
            isPaused: paused, pausedRemainingRestSeconds: remaining, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil)
    }

    private func content(end: Date?, duration: TimeInterval?, phase: WorkoutActivityAttributes.ContentState.Phase = .rest) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(exerciseName: "Bench", currentSet: 2,
            plannedSetsForExercise: 2, completedSets: 1, totalSets: 2, phase: phase,
            restEndsAt: end, pausedRestSeconds: nil, restTotalSeconds: duration)
    }
}

private struct RestDurationEmptyLegacyStore: ActiveWorkoutPersisting {
    func load() throws -> ActiveWorkoutSnapshot? { nil }
    func save(_ snapshot: ActiveWorkoutSnapshot) throws {}
    func clear(expectedSessionID: UUID) throws {}
}
