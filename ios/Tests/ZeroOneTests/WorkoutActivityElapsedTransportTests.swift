import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutActivityElapsedTransportTests: XCTestCase {
    private final class Clock {
        let id = UUID()
        var seconds: TimeInterval = 10
        var wall = Date(timeIntervalSince1970: 1_000)
        var reading: WorkoutElapsedClockReading {
            .init(continuityID: id, seconds: seconds, observedAt: wall)
        }
        var capability: WorkoutElapsedClock { .init { self.reading } }
        func move(_ value: TimeInterval) { seconds = value; wall = Date(timeIntervalSince1970: 990 + value) }
    }

    private enum Failure: Error { case write }
    @MainActor private final class Rig {
        let clock = Clock()
        var fail = false
        var saved: ActiveWorkoutSnapshot?
        func make(_ session: WorkoutSession, restored: ActiveWorkoutSnapshot? = nil,
                  seed: Bool = true) -> WorkoutViewModel {
            WorkoutViewModel(session: session, restoredSnapshot: restored, requiresFinalSetReview: true,
                acceptedStart: seed ? clock.reading : nil, elapsedClock: clock.capability,
                onSnapshotChanged: { value, _ in
                    if self.fail { throw Failure.write }
                    self.saved = value
                })
        }
    }

    private func session(sets: Int = 2, rest: TimeInterval = 60) -> WorkoutSession {
        WorkoutSession(title: "Elapsed transport", customWorkoutID: UUID(), exercises: [
            WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.dumbbellCurl,
                name: "Curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
                plannedSetCount: sets, restSeconds: rest, previousPerformance: []))
        ])
    }

    private func frozen(_ seconds: TimeInterval = 75.9,
                        state: WorkoutActivityFrozenElapsed.State = .paused) -> WorkoutActivityFrozenElapsed {
        .init(version: 1, seconds: seconds, observedAt: Date(timeIntervalSince1970: 1_020), state: state)
    }

    @MainActor private func paused(_ rig: Rig) throws -> (WorkoutViewModel, WorkoutActivityProjection) {
        let vm = rig.make(session())
        rig.clock.move(85.9)
        vm.togglePause(at: rig.clock.wall)
        return (vm, try XCTUnwrap(vm.persistedActivity))
    }

    @MainActor func testPausedTransportKeepsOriginalEventAndStableProjectionAcrossWallJumps() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let first = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(first.state.frozenElapsed?.seconds, 75.9)
        XCTAssertEqual(first.state.frozenElapsed?.observedAt, rig.saved?.elapsedEvidence?.lastTransition.observedAt)
        rig.clock.move(9_000)
        rig.clock.wall = Date(timeIntervalSince1970: -8_000_000)
        let later = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(first, later)
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: later,
            existingSessionID: first.sessionID, existingState: first.state), .unchanged)
        XCTAssertEqual(later.state.pausedElapsed?.clockText(language: .english), "1:15")
    }

    @MainActor func testRunningAndResumeNeverExportExtrapolatableElapsed() throws {
        let rig = Rig()
        let vm = rig.make(session())
        var reads = 0
        let counting = WorkoutElapsedClock { reads += 1; return rig.clock.reading }
        XCTAssertNil(try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: counting).state.frozenElapsed)
        XCTAssertEqual(reads, 0)
        rig.clock.move(40)
        vm.togglePause(at: rig.clock.wall)
        let old = try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: counting)
        XCTAssertNotNil(old.state.frozenElapsed)
        XCTAssertEqual(reads, 1)
        rig.clock.move(80)
        vm.togglePause(at: rig.clock.wall)
        XCTAssertNil(old.usingConfirmedElapsed(from: vm, clock: counting).state.frozenElapsed)
        XCTAssertNil(try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: counting).state.frozenElapsed)
        XCTAssertEqual(reads, 1)
    }

    @MainActor func testFailedPauseAndRetryUseOnlyAcknowledgedOriginalTransition() throws {
        let rig = Rig()
        let vm = rig.make(session())
        let running = try XCTUnwrap(vm.persistedActivity)
        rig.clock.move(40)
        rig.fail = true
        vm.togglePause(at: rig.clock.wall)
        XCTAssertNotNil(vm.persistenceErrorMessage)
        XCTAssertNil(running.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        rig.clock.move(300)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        let projection = try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(projection.state.frozenElapsed?.seconds, 30)
        XCTAssertEqual(projection.state.frozenElapsed?.observedAt, Date(timeIntervalSince1970: 1_030))
    }

    @MainActor func testFailedResumeClearsPreviouslyTransportedPausedValueUntilRetry() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let old = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        rig.clock.move(100)
        rig.fail = true
        vm.togglePause(at: rig.clock.wall)
        XCTAssertNil(old.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertNil(try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
    }

    @MainActor func testExplicitInvalidationAndDifferentOwnerRejectCachedMetadata() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let old = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        let other = rig.make(session())
        XCTAssertNil(old.usingConfirmedElapsed(from: other, clock: rig.clock.capability).state.frozenElapsed)
        vm.invalidateElapsedEvidence()
        XCTAssertNil(old.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        XCTAssertNil(vm.confirmedElapsedEvidence)
    }

    @MainActor func testRestoredSameProcessAndUnseededOwnersRemainUnknown() throws {
        let rig = Rig()
        let (vm, _) = try paused(rig)
        let snapshot = try XCTUnwrap(rig.saved)
        let restored = rig.make(vm.session, restored: snapshot)
        XCTAssertTrue(restored.isPaused)
        XCTAssertNil(try XCTUnwrap(restored.persistedActivity).usingConfirmedElapsed(from: restored, clock: rig.clock.capability).state.frozenElapsed)
        let legacy = rig.make(session(), seed: false)
        legacy.togglePause(at: rig.clock.wall)
        XCTAssertNil(try XCTUnwrap(legacy.persistedActivity).usingConfirmedElapsed(from: legacy, clock: rig.clock.capability).state.frozenElapsed)
    }

    @MainActor func testStoppedFinalReviewTransportsFrozenFactAndFinalUndoRevokesIt() throws {
        let rig = Rig()
        let vm = rig.make(session(sets: 1, rest: 0))
        rig.clock.move(50)
        vm.completeCurrentSet(at: rig.clock.wall)
        let base = try XCTUnwrap(vm.persistedActivity)
        rig.clock.move(500)
        let stopped = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(stopped.state.frozenElapsed?.state, .stopped)
        XCTAssertEqual(stopped.state.frozenElapsed?.seconds, 40)
        XCTAssertEqual(stopped.state.phase, .readyToFinish)
        XCTAssertNil(stopped.state.pausedElapsed)
        vm.undoFinalSet()
        XCTAssertNil(stopped.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        rig.clock.move(600)
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertNil(try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
    }

    @MainActor func testInvalidReadWithholdsWithoutMutatingOwner() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let evidence = vm.confirmedElapsedEvidence
        for reading in [
            WorkoutElapsedClockReading(continuityID: UUID(), seconds: 100, observedAt: rig.clock.wall),
            .init(continuityID: rig.clock.id, seconds: 5, observedAt: rig.clock.wall),
            .init(continuityID: rig.clock.id, seconds: .nan, observedAt: rig.clock.wall),
            .init(continuityID: rig.clock.id, seconds: 100, observedAt: Date(timeIntervalSince1970: .infinity))
        ] {
            XCTAssertNil(base.usingConfirmedElapsed(from: vm, clock: .init { reading }).state.frozenElapsed)
            XCTAssertEqual(vm.confirmedElapsedEvidence, evidence)
        }
    }

    @MainActor func testFailedTerminalSaveRetryKeepsOriginalStoppedTimeThenCompletionClearsIt() throws {
        let rig = Rig()
        let vm = rig.make(session(sets: 1, rest: 0))
        let prior = try XCTUnwrap(vm.persistedActivity)
        rig.clock.move(50)
        rig.fail = true
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertNil(prior.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        rig.clock.move(500)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        let stopped = try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(stopped.state.frozenElapsed?.seconds, 40)
        XCTAssertEqual(stopped.state.frozenElapsed?.observedAt, Date(timeIntervalSince1970: 1_040))
        vm.confirmFinalSetAndFinish(at: rig.clock.wall)
        XCTAssertTrue(vm.isCompletionSaved)
        XCTAssertNil(vm.persistedActivity)
        XCTAssertNil(stopped.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
    }

    @MainActor func testWarmUpPauseUsesConfirmedSessionElapsedWithoutChangingGate() throws {
        let rig = Rig()
        let source = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        let vm = rig.make(source)
        XCTAssertTrue(vm.session.requiresWarmUp)
        rig.clock.move(35)
        vm.togglePause(at: rig.clock.wall)
        let projection = try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(projection.state.pausedElapsed?.seconds, 25)
        XCTAssertTrue(vm.session.requiresWarmUp)
        XCTAssertEqual(vm.session.completedSetCount, 0)
    }

    @MainActor func testReentrantClockInvalidationCannotReturnCapturedEvidence() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        var reads = 0
        let clock = WorkoutElapsedClock {
            reads += 1
            vm.invalidateElapsedEvidence()
            return rig.clock.reading
        }
        XCTAssertNil(base.usingConfirmedElapsed(from: vm, clock: clock).state.frozenElapsed)
        XCTAssertEqual(reads, 1)
    }

    @MainActor func testReentrantClockResumeCannotReturnOldPausedState() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        rig.clock.move(100)
        let clock = WorkoutElapsedClock {
            vm.togglePause(at: rig.clock.wall)
            return rig.clock.reading
        }
        XCTAssertNil(base.usingConfirmedElapsed(from: vm, clock: clock).state.frozenElapsed)
        XCTAssertFalse(vm.isPaused)
    }

    @MainActor func testExactProjectionRequiredBeforePresentationOverrides() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let differentTitle = WorkoutActivityProjection(sessionID: base.sessionID,
            workoutTitle: "Changed", state: base.state)
        XCTAssertNil(differentTitle.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        XCTAssertNil(base.usingLanguage(.bulgarian).usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state.frozenElapsed)
        let decorated = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
            .usingAccent(.pink).usingLanguage(.bulgarian).usingDesignTheme(.retro)
        XCTAssertEqual(decorated.state.frozenElapsed?.seconds, 75.9)
        XCTAssertEqual(decorated.state.accent, .pink)
        XCTAssertEqual(decorated.state.displayLanguage, .bulgarian)
        XCTAssertEqual(decorated.state.displayTheme, .retro)
        XCTAssertNil(base.state.frozenElapsed)
    }

    @MainActor func testRestTargetsAndPausedRestRemainDistinctAndUnchanged() throws {
        let rig = Rig()
        let vm = rig.make(session())
        let wall = Date.now
        rig.clock.move(20)
        rig.clock.wall = wall
        vm.completeCurrentSet(at: rig.clock.wall)
        let rest = try XCTUnwrap(vm.persistedActivity)
        let qualified = rest.usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(qualified, rest)
        XCTAssertEqual(qualified.state.restTotalSeconds, 60)
        XCTAssertEqual(qualified.staleDate, rest.state.restEndsAt)
        rig.clock.move(30)
        rig.clock.wall = wall.addingTimeInterval(10)
        vm.togglePause(at: rig.clock.wall)
        let paused = try XCTUnwrap(vm.persistedActivity).usingConfirmedElapsed(from: vm, clock: rig.clock.capability)
        XCTAssertEqual(paused.state.pausedRestSeconds, 50)
        XCTAssertEqual(paused.state.frozenElapsed?.seconds, 20)
        XCTAssertNil(paused.state.restTotalSeconds)
        XCTAssertNil(paused.staleDate)
    }

    func testStaticFormattingSupportsZeroFractionsMinuteAndHourBoundaries() {
        for language in [AppLanguage.english, .bulgarian] {
            for (value, text) in [(0.0,"0:00"),(0.99,"0:00"),(59.99,"0:59"),(60,"1:00"),
                                  (3599,"59:59"),(3600,"1:00:00"),(3661,"1:01:01"),(360000,"100:00:00")] {
                XCTAssertEqual(frozen(value).clockText(language: language), text)
            }
        }
    }

    func testInvalidDisplayNumbersNeverTrapOrInventZero() {
        for value in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            XCTAssertNil(frozen(value).wholeSeconds)
            XCTAssertNil(frozen(value).clockText(language: .english))
        }
        XCTAssertNotNil(frozen(Double(Int.max).nextDown).wholeSeconds)
        XCTAssertNil(WorkoutActivityFrozenElapsed(version: 2, seconds: 1, observedAt: .now, state: .paused).wholeSeconds)
        XCTAssertNil(WorkoutActivityFrozenElapsed(version: 1, seconds: 1,
            observedAt: Date(timeIntervalSince1970: .infinity), state: .paused).wholeSeconds)
    }

    @MainActor func testTransportRoundTripAndMalformedOptionalMetadataPreserveExistingFacts() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        let original = base.usingConfirmedElapsed(from: vm, clock: rig.clock.capability).state
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: data), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let elapsed = try XCTUnwrap(object["frozenElapsed"] as? [String: Any])
        var malformed: [Any] = ["bad", NSNull(), ["version": 1]]
        for (key, value) in [("version", 2 as Any), ("state", "running" as Any), ("state", "stopped" as Any),
                             ("seconds", -1 as Any), ("seconds", Double(Int.max) as Any),
                             ("observedAt", "bad" as Any)] {
            var altered = elapsed
            altered[key] = value
            malformed.append(altered)
        }
        for value in malformed {
            var altered = object
            altered["frozenElapsed"] = value
            let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                from: JSONSerialization.data(withJSONObject: altered))
            XCTAssertEqual(decoded, base.state)
            XCTAssertNil(decoded.pausedElapsed)
        }
        var legacy = object
        legacy.removeValue(forKey: "frozenElapsed")
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: legacy)), base.state)
        var invalidFact = object
        invalidFact["completedSets"] = "bad"
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: invalidFact)))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("continuityID"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("acceptedStart"))
    }

    @MainActor func testPausedAccessorRejectsWrongPhaseAndStoppedMetadata() throws {
        let rig = Rig()
        let (vm, base) = try paused(rig)
        var content = base.state
        content.frozenElapsed = frozen(state: .stopped)
        XCTAssertNil(content.pausedElapsed)
        let running = rig.make(session())
        var active = try XCTUnwrap(running.persistedActivity).state
        active.frozenElapsed = frozen()
        XCTAssertNil(active.pausedElapsed)
        XCTAssertTrue(vm.isPaused)
    }
}
