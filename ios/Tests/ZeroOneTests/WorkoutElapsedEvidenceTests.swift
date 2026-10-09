import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutElapsedEvidenceTests: XCTestCase {
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

    private enum Failure: Error { case write, history }

    @MainActor private final class Rig {
        let clock = Clock()
        var attempts: [ActiveWorkoutSnapshot?] = []
        var saved: ActiveWorkoutSnapshot?
        var fail = false
        var failHistory = false

        func make(_ session: WorkoutSession, restored: ActiveWorkoutSnapshot? = nil,
                  seed: Bool = true, finalReview: Bool = true) -> WorkoutViewModel {
            WorkoutViewModel(session: session, restoredSnapshot: restored,
                requiresFinalSetReview: finalReview,
                acceptedStart: seed ? clock.reading : nil, elapsedClock: clock.capability,
                onSnapshotChanged: { value, _ in
                    if let value { XCTAssertTrue(value.isCompatible) }
                    self.attempts.append(value)
                    if self.fail { throw Failure.write }
                    self.saved = value
                }, onSessionCompleted: { _ in
                    if self.failHistory { throw Failure.history }
                    return .inserted
                })
        }
    }

    private func session(sets: Int = 2, rest: TimeInterval = 60) -> WorkoutSession {
        WorkoutSession(title: "Elapsed fixture", customWorkoutID: UUID(), exercises: [
            WorkoutExercise(plan: ExercisePlan(exerciseID: ExerciseIDs.dumbbellCurl,
                name: "Curl", targetLoad: Load(10), targetReps: RepRange(8, 12),
                plannedSetCount: sets, restSeconds: rest, previousPerformance: []))
        ])
    }

    private func snapshot(_ session: WorkoutSession, version: Int = ActiveWorkoutSnapshot.currentVersion,
                          evidence: WorkoutElapsedEvidence? = nil, paused: Bool = false) -> ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(version: version, session: session, enteredLoadValue: 10,
            enteredReps: 8, enteredRIR: 3, isPaused: paused,
            pausedRemainingRestSeconds: paused ? 0 : nil, pendingAdaptation: nil,
            sessionBeforeAdaptation: nil, lastSetGuidance: nil, elapsedEvidence: evidence)
    }

    func testContinuousCapabilityRetainsItsExactOriginAcrossInstances() {
        let first = WorkoutElapsedClock.continuous.read()
        let second = WorkoutElapsedClock.continuous.read()
        XCTAssertEqual(first.continuityID, second.continuityID)
        XCTAssertGreaterThanOrEqual(second.seconds, first.seconds)
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(second.isValid)
    }

    func testRunningAndMultipleIntentionalPausesUseMonotonicTime() throws {
        let clock = Clock()
        var evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: UUID(), at: clock.reading))
        clock.move(130)
        XCTAssertEqual(evidence.elapsed(at: clock.reading), 120)
        evidence = try XCTUnwrap(evidence.transitioning(to: .paused, at: clock.reading))
        clock.move(160)
        XCTAssertEqual(evidence.elapsed(at: clock.reading), 120)
        evidence = try XCTUnwrap(evidence.transitioning(to: .running, at: clock.reading))
        clock.move(170)
        evidence = try XCTUnwrap(evidence.transitioning(to: .paused, at: clock.reading))
        clock.move(180)
        evidence = try XCTUnwrap(evidence.transitioning(to: .running, at: clock.reading))
        clock.move(200)
        XCTAssertEqual(evidence.accumulatedPauseSeconds, 40)
        XCTAssertEqual(evidence.elapsed(at: clock.reading), 150)
    }

    func testWallClockJumpsAreMetadataOnly() throws {
        let clock = Clock()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: UUID(), at: clock.reading))
        clock.seconds = 20
        clock.wall = Date(timeIntervalSince1970: -1_000_000)
        let paused = try XCTUnwrap(evidence.transitioning(to: .paused, at: clock.reading))
        XCTAssertEqual(paused.lastTransition.observedAt, clock.wall)
        XCTAssertEqual(paused.acceptedStart.observedAt, Date(timeIntervalSince1970: 1_000))
        clock.seconds = 60
        clock.wall = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(paused.elapsed(at: clock.reading), 10)
        let resumed = try XCTUnwrap(paused.transitioning(to: .running, at: clock.reading))
        clock.seconds = 90
        XCTAssertEqual(resumed.elapsed(at: clock.reading), 40)
    }

    func testInvalidContinuityAndValuesAreUnavailableWithoutClamping() throws {
        let clock = Clock()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: UUID(), at: clock.reading))
        let readings = [
            WorkoutElapsedClockReading(continuityID: UUID(), seconds: 20, observedAt: clock.wall),
            .init(continuityID: clock.id, seconds: 9, observedAt: clock.wall),
            .init(continuityID: clock.id, seconds: .infinity, observedAt: clock.wall),
            .init(continuityID: clock.id, seconds: .nan, observedAt: clock.wall),
            .init(continuityID: clock.id, seconds: 20, observedAt: Date(timeIntervalSince1970: .infinity))
        ]
        for reading in readings {
            XCTAssertNil(evidence.elapsed(at: reading))
            XCTAssertNil(evidence.transitioning(to: .paused, at: reading))
        }
        XCTAssertNil(WorkoutElapsedEvidence.started(sessionID: UUID(), at:
            .init(continuityID: clock.id, seconds: -1, observedAt: clock.wall)))
    }

    func testStoppedEvidenceFreezesAndCannotReopenOrDoublePause() throws {
        let clock = Clock()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: UUID(), at: clock.reading))
        clock.move(20)
        let paused = try XCTUnwrap(evidence.transitioning(to: .paused, at: clock.reading))
        XCTAssertNil(paused.transitioning(to: .paused, at: clock.reading))
        clock.move(80)
        let stopped = try XCTUnwrap(paused.transitioning(to: .stopped, at: clock.reading))
        XCTAssertEqual(stopped.accumulatedPauseSeconds, 60)
        clock.move(900)
        XCTAssertEqual(stopped.elapsed(at: clock.reading), 10)
        XCTAssertNil(stopped.transitioning(to: .running, at: clock.reading))
        XCTAssertNil(stopped.transitioning(to: .stopped, at: clock.reading))
    }

    @MainActor func testDefaultAndMockConstructionDoNotCreateTiming() {
        let rig = Rig()
        let vm = rig.make(MockWorkoutFactory.upperBodyA(), seed: false)
        XCTAssertNil(rig.saved?.elapsedEvidence)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        XCTAssertNil(vm.confirmedElapsedSeconds())
        rig.clock.move(100)
        vm.togglePause(at: rig.clock.wall)
        vm.togglePause(at: rig.clock.wall)
        XCTAssertNil(rig.saved?.elapsedEvidence)
    }

    @MainActor func testWarmUpRestAndBackgroundTimeAreIncluded() throws {
        let rig = Rig()
        let source = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .biceps)?.makeSession())
        let vm = rig.make(source)
        XCTAssertTrue(vm.requiresWarmUpGate)
        rig.clock.move(40)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 30)
        vm.resolveWarmUp(as: .skipped, at: rig.clock.wall)
        vm.enteredLoadValue = 10
        vm.loadDraft = "10"
        rig.clock.move(50)
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertEqual(vm.session.completedSetCount, 1)
        rig.clock.move(130)
        // No foreground ticks or set events occurred during this interval.
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 120)
        XCTAssertEqual(rig.saved?.elapsedEvidence?.acceptedStart, vm.confirmedElapsedEvidence?.acceptedStart)
    }

    @MainActor func testInitialSaveFailureRetainsAcceptedStartOnRetry() throws {
        let rig = Rig()
        rig.fail = true
        let vm = rig.make(session())
        let first = try XCTUnwrap(rig.attempts.first ?? nil)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        rig.clock.move(90)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(rig.saved?.elapsedEvidence, first.elapsedEvidence)
        XCTAssertEqual(vm.confirmedElapsedEvidence, rig.saved?.elapsedEvidence)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 80)
    }

    @MainActor func testFailedPauseAndResumeRetryKeepOriginalEventReadings() throws {
        let rig = Rig()
        let vm = rig.make(session())
        rig.clock.move(20)
        rig.fail = true
        vm.togglePause(at: rig.clock.wall)
        let failedPause = try XCTUnwrap((rig.attempts.last ?? nil)?.elapsedEvidence)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        let attemptCount = rig.attempts.count
        vm.togglePause(at: rig.clock.wall)
        XCTAssertEqual(rig.attempts.count, attemptCount)
        rig.clock.move(60)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(rig.saved?.elapsedEvidence, failedPause)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 10)
        rig.clock.move(80)
        rig.fail = true
        vm.togglePause(at: rig.clock.wall)
        let failedResume = try XCTUnwrap((rig.attempts.last ?? nil)?.elapsedEvidence)
        XCTAssertEqual(failedResume.accumulatedPauseSeconds, 60)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        rig.clock.move(100)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(rig.saved?.elapsedEvidence, failedResume)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 30)
    }

    @MainActor func testElapsedPauseDoesNotChangeExistingRestBehavior() throws {
        let rig = Rig()
        let vm = rig.make(session())
        rig.clock.move(20)
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertEqual(vm.session.completedSetCount, 1)
        rig.clock.move(30)
        vm.togglePause(at: rig.clock.wall)
        XCTAssertEqual(vm.remainingRestSeconds(at: rig.clock.wall), 50)
        rig.clock.move(100)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 20)
        vm.togglePause(at: rig.clock.wall)
        XCTAssertEqual(vm.session.restEndsAt, rig.clock.wall.addingTimeInterval(50))
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 20)
        let set = try XCTUnwrap(vm.session.exercises.first?.completedSets.first)
        XCTAssertTrue(try XCTUnwrap(set.restTimerObservation).isValid(for: set.id, completedAt: set.completedAt))
    }

    @MainActor func testFailedSetRetryRestRestartDoesNotResetSessionElapsed() {
        let rig = Rig()
        let vm = rig.make(session())
        rig.clock.move(20)
        rig.fail = true
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        rig.clock.move(100)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(vm.session.restEndsAt, rig.clock.wall.addingTimeInterval(60))
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 90)
    }

    @MainActor func testOrdinaryDraftSavePublishesExactSnapshotEvidence() {
        let rig = Rig()
        let vm = rig.make(session())
        let evidence = rig.saved?.elapsedEvidence
        rig.clock.move(200)
        vm.enteredReps = 9
        XCTAssertEqual(rig.saved?.elapsedEvidence, evidence)
        XCTAssertEqual(vm.confirmedElapsedEvidence, rig.saved?.elapsedEvidence)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 190)
    }

    @MainActor func testSameProcessStaleSnapshotAfterFailedPauseRemainsUnknown() throws {
        let rig = Rig()
        let source = session()
        let old = rig.make(source)
        let stale = try XCTUnwrap(rig.saved)
        rig.clock.move(20)
        rig.fail = true
        old.togglePause(at: rig.clock.wall)
        old.invalidateElapsedEvidence()
        rig.fail = false
        rig.clock.move(90)
        let restored = rig.make(source, restored: stale)
        XCTAssertNil(restored.confirmedElapsedEvidence)
        XCTAssertNil(rig.saved?.elapsedEvidence)
        old.retryPersistence(at: rig.clock.wall)
        XCTAssertNil(old.confirmedElapsedEvidence)
    }

    @MainActor func testPausedRelaunchAndInvalidSnapshotNeverReseedFromSuppliedStart() throws {
        let rig = Rig()
        let source = session()
        let vm = rig.make(source)
        rig.clock.move(20)
        vm.togglePause(at: rig.clock.wall)
        let paused = try XCTUnwrap(rig.saved)
        let replacement = Rig()
        let restored = replacement.make(source, restored: paused)
        XCTAssertTrue(restored.isPaused)
        XCTAssertNil(restored.confirmedElapsedSeconds())
        restored.togglePause(at: replacement.clock.wall)
        XCTAssertNil(replacement.saved?.elapsedEvidence)
        let invalid = snapshot(source, version: 999)
        let invalidVM = replacement.make(source, restored: invalid)
        XCTAssertNil(invalidVM.confirmedElapsedEvidence)
        XCTAssertNil(replacement.saved?.elapsedEvidence)
    }

    @MainActor func testFinalReviewFreezesOriginalTerminalThroughFailureAndUndo() throws {
        let rig = Rig()
        let vm = rig.make(session(sets: 1, rest: 0))
        rig.clock.move(30)
        rig.fail = true
        vm.completeCurrentSet(at: rig.clock.wall)
        let failed = try XCTUnwrap((rig.attempts.last ?? nil)?.elapsedEvidence)
        XCTAssertEqual(failed.state, .stopped)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        rig.clock.move(200)
        rig.fail = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(vm.confirmedElapsedEvidence, failed)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 20)
        XCTAssertTrue(vm.canUndoFinalSet)
        vm.undoFinalSet()
        XCTAssertNil(rig.saved?.elapsedEvidence)
        rig.clock.move(240)
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertNil(vm.confirmedElapsedEvidence)
    }

    @MainActor func testFinishEarlyWhilePausedFreezesAndHistoryRetryDoesNotRecapture() throws {
        let rig = Rig()
        let vm = rig.make(session())
        rig.clock.move(20)
        vm.completeCurrentSet(at: rig.clock.wall)
        rig.clock.move(30)
        vm.togglePause(at: rig.clock.wall)
        rig.clock.move(80)
        rig.failHistory = true
        XCTAssertTrue(vm.finishEarly(at: rig.clock.wall))
        let terminal = try XCTUnwrap(rig.saved?.elapsedEvidence)
        XCTAssertEqual(terminal.state, .stopped)
        XCTAssertEqual(terminal.accumulatedPauseSeconds, 50)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        rig.clock.move(500)
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertEqual(rig.saved?.elapsedEvidence, terminal)
        rig.failHistory = false
        vm.retryPersistence(at: rig.clock.wall)
        XCTAssertNil(rig.saved)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        XCTAssertTrue(vm.isCompletionSaved)
    }

    @MainActor func testNonfinalSetUndoPreservesSessionOrigin() {
        let rig = Rig()
        let vm = rig.make(session())
        let start = rig.saved?.elapsedEvidence?.acceptedStart
        rig.clock.move(20)
        vm.completeCurrentSet(at: rig.clock.wall)
        rig.clock.move(50)
        vm.undoLastSet()
        XCTAssertEqual(vm.session.completedSetCount, 0)
        XCTAssertEqual(rig.saved?.elapsedEvidence?.acceptedStart, start)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 40)
    }

    @MainActor func testSameSessionAdaptationAndUndoPreserveElapsedOrigin() throws {
        let rig = Rig()
        let original = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        let vm = rig.make(original)
        let start = rig.saved?.elapsedEvidence?.acceptedStart
        rig.clock.move(20)
        vm.proposeThirtyMinuteAdaptation()
        XCTAssertNotNil(vm.pendingAdaptation)
        vm.applyPendingAdaptation()
        XCTAssertTrue(vm.session.isAdapted)
        XCTAssertEqual(vm.session.id, original.id)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 10)
        rig.clock.move(50)
        vm.undoAdaptation()
        XCTAssertEqual(vm.session, original)
        XCTAssertEqual(rig.saved?.elapsedEvidence?.acceptedStart, start)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 40)
    }

    @MainActor func testPauseIsExcludedDuringWarmUpAndZeroRestAcknowledgement() throws {
        let rig = Rig()
        let warmUp = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        let warmVM = rig.make(warmUp)
        rig.clock.move(20)
        warmVM.togglePause(at: rig.clock.wall)
        XCTAssertTrue(warmVM.isPaused)
        rig.clock.move(50)
        XCTAssertEqual(warmVM.confirmedElapsedSeconds(), 10)
        warmVM.togglePause(at: rig.clock.wall)
        rig.clock.move(60)
        XCTAssertEqual(warmVM.confirmedElapsedSeconds(), 20)
        warmVM.invalidateElapsedEvidence()
        let vm = rig.make(session(rest: 0))
        rig.clock.move(70)
        vm.completeCurrentSet(at: rig.clock.wall)
        XCTAssertTrue(vm.awaitingNextSetAcknowledgement)
        rig.clock.move(80)
        vm.togglePause(at: rig.clock.wall)
        rig.clock.move(100)
        vm.togglePause(at: rig.clock.wall)
        XCTAssertTrue(vm.awaitingNextSetAcknowledgement)
        vm.acknowledgeNextSet(at: rig.clock.wall)
        XCTAssertFalse(vm.awaitingNextSetAcknowledgement)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 20)
    }

    @MainActor func testExplicitInvalidationAndInvalidClockCannotResurrectOnSave() {
        let rig = Rig()
        let vm = rig.make(session())
        rig.clock.move(9)
        XCTAssertNil(vm.confirmedElapsedSeconds())
        rig.clock.move(100)
        vm.enteredReps = 9
        XCTAssertNil(vm.confirmedElapsedEvidence)
        XCTAssertNil(rig.saved?.elapsedEvidence)
        let second = rig.make(session())
        second.invalidateElapsedEvidence()
        second.enteredReps = 9
        XCTAssertNil(second.confirmedElapsedEvidence)
        XCTAssertNil(rig.saved?.elapsedEvidence)
    }

    @MainActor func testReentrantOwnerInvalidationCannotRepublishLateSuccess() {
        let clock = Clock()
        var vm: WorkoutViewModel?
        vm = WorkoutViewModel(session: session(), acceptedStart: clock.reading,
            elapsedClock: clock.capability, onSnapshotChanged: { _, _ in vm?.invalidateElapsedEvidence() })
        XCTAssertNotNil(vm?.confirmedElapsedEvidence)
        vm?.enteredReps = 9
        XCTAssertNil(vm?.confirmedElapsedEvidence)
        XCTAssertNil(vm?.confirmedElapsedSeconds())
    }

    @MainActor func testClearAndCompletedRecoveryNeverPublishOldTiming() throws {
        let rig = Rig()
        let vm = rig.make(session())
        XCTAssertTrue(vm.clearSnapshotForExit())
        vm.enteredReps = 9
        XCTAssertNil(vm.confirmedElapsedEvidence)
        let finishing = rig.make(session(sets: 1), finalReview: false)
        rig.clock.move(30)
        rig.failHistory = true
        finishing.completeCurrentSet(at: rig.clock.wall)
        let recovery = try XCTUnwrap(rig.saved)
        let other = Rig()
        other.failHistory = true
        let restored = other.make(recovery.session, restored: recovery)
        XCTAssertEqual(other.saved, recovery)
        XCTAssertNil(restored.confirmedElapsedEvidence)
    }

    func testSnapshotIntroductionAndStateIdentityValidation() throws {
        XCTAssertEqual(ActiveWorkoutSnapshot.currentVersion, 8)
        let clock = Clock()
        let source = session()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: source.id, at: clock.reading))
        XCTAssertTrue(snapshot(source, evidence: evidence).isCompatible)
        XCTAssertFalse(snapshot(source, version: 7, evidence: evidence).isCompatible)
        XCTAssertFalse(snapshot(source, version: 999).isCompatible)
        XCTAssertFalse(snapshot(session(), evidence: evidence).isCompatible)
        XCTAssertFalse(snapshot(source, evidence: evidence, paused: true).isCompatible)
        for version in 1...7 {
            let legacy = snapshot(source, version: version)
            let decoded = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(legacy))
            XCTAssertTrue(decoded.isCompatible)
            XCTAssertNil(decoded.elapsedEvidence)
        }
    }

    func testVersionSevenProgrammeProvenanceStillRoundTripsWithoutElapsed() throws {
        let source = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .upperBodyA)?.makeSession())
        XCTAssertNotNil(source.programmeProvenance)
        let legacy = snapshot(source, version: 7)
        let decoded = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertTrue(decoded.isCompatible)
        XCTAssertEqual(decoded.session.programmeProvenance, source.programmeProvenance)
        XCTAssertNil(decoded.elapsedEvidence)
    }

    @MainActor func testActualVMFileStorePauseRetryAndFinalReviewSequence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FileActiveWorkoutStore(directory: directory,
            legacyStore: UserDefaultsActiveWorkoutStore(defaults: defaults, key: "fixture"))
        let clock = Clock()
        var failBeforeWrite = false
        let vm = WorkoutViewModel(session: session(sets: 1, rest: 0), requiresFinalSetReview: true,
            acceptedStart: clock.reading, elapsedClock: clock.capability,
            onSnapshotChanged: { value, id in
                if failBeforeWrite { throw Failure.write }
                if let value { try store.save(value) }
                else { try store.clear(expectedSessionID: id) }
            })
        let start = try XCTUnwrap(store.load()?.elapsedEvidence)
        clock.move(20)
        failBeforeWrite = true
        vm.togglePause(at: clock.wall)
        XCTAssertNil(vm.confirmedElapsedEvidence)
        XCTAssertEqual(try store.load()?.elapsedEvidence, start)
        clock.move(60)
        failBeforeWrite = false
        vm.retryPersistence(at: clock.wall)
        let paused = try XCTUnwrap(store.load()?.elapsedEvidence)
        XCTAssertEqual(paused.lastTransition.seconds, 20)
        XCTAssertEqual(vm.confirmedElapsedEvidence, paused)
        clock.move(80)
        vm.togglePause(at: clock.wall)
        XCTAssertEqual(try store.load()?.elapsedEvidence?.accumulatedPauseSeconds, 60)
        clock.move(100)
        vm.completeCurrentSet(at: clock.wall)
        XCTAssertTrue(vm.awaitingFinalSetConfirmation)
        let stopped = try XCTUnwrap(store.load()?.elapsedEvidence)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(vm.confirmedElapsedEvidence, stopped)
        clock.move(500)
        XCTAssertEqual(vm.confirmedElapsedSeconds(), 30)
    }

    func testStrictEvidenceAndReadingDecodersRejectUnknownAndMalformedFacts() throws {
        let clock = Clock()
        let original = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: UUID(), at: clock.reading))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutElapsedEvidence.self, from: data), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("version", 2 as Any), ("state", "future" as Any),
                             ("accumulatedPauseSeconds", -1 as Any), ("futureFact", true as Any)] {
            var changed = object
            changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(WorkoutElapsedEvidence.self,
                from: JSONSerialization.data(withJSONObject: changed)))
        }
        var changed = object
        var reading = try XCTUnwrap(changed["acceptedStart"] as? [String: Any])
        reading["futureFact"] = true
        changed["acceptedStart"] = reading
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutElapsedEvidence.self,
            from: JSONSerialization.data(withJSONObject: changed)))
    }

    func testActualFileStoreRoundTripDuplicateRejectionAndTombstone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "fixture")
        let source = session()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: source.id, at: Clock().reading))
        let value = snapshot(source, evidence: evidence)
        try legacy.save(snapshot(source, version: 7))
        let store = FileActiveWorkoutStore(directory: directory, legacyStore: legacy)
        XCTAssertNil(try store.load()?.elapsedEvidence)
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        let url = directory.appendingPathComponent("active-workout.json")
        let encoded = try JSONEncoder().encode(value)
        for field in ["\"version\":8,", "\"vers\\u0069on\":8,"] {
            var bytes = Data(("{" + field).utf8)
            bytes.append(encoded.dropFirst())
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.load())
        }
        try encoded.write(to: url)
        try store.clear(expectedSessionID: source.id)
        XCTAssertNil(try store.load())
        XCTAssertNotNil(try legacy.load())
    }

    func testActualDefaultsStoreRejectsDuplicateNestedClockKeysAndFutureSnapshot() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "fixture")
        let source = session()
        let evidence = try XCTUnwrap(WorkoutElapsedEvidence.started(sessionID: source.id, at: Clock().reading))
        let value = snapshot(source, evidence: evidence)
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
        let duplicated = text.replacingOccurrences(of: "\"acceptedStart\":{", with: "\"acceptedStart\":{\"seconds\":10,")
        XCTAssertNotEqual(duplicated, text)
        defaults.set(Data(duplicated.utf8), forKey: "fixture")
        XCTAssertThrowsError(try store.load())
        defaults.set(try encoder.encode(snapshot(source, version: 999)), forKey: "fixture")
        XCTAssertThrowsError(try store.load())
        defaults.set(try encoder.encode(snapshot(source, version: 7, evidence: evidence)), forKey: "fixture")
        XCTAssertThrowsError(try store.load())
    }
}
