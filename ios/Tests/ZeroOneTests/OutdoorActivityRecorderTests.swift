import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorActivityRecorderTests: XCTestCase {
    private let policy = OutdoorRouteAcceptancePolicy(
        maximumHorizontalAccuracyMeters: 35,
        maximumGapSeconds: 30,
        maximumPlausibleSpeedMetersPerSecond: 15,
        maximumFutureSeconds: 5
    )

    func testTimeOnlyWalkPersistsTimeWithoutRouteOrDistance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let start = Date(timeIntervalSince1970: 900)
        let clock = ContinuousClock.now

        let begun = try await recorder.start(
            kind: .walk, trackingMode: .timerOnly, at: start, monotonic: clock
        )
        XCTAssertEqual(begun.trackingMode, .timerOnly)
        let result = try await recorder.finish(
            at: start.addingTimeInterval(60), monotonic: clock.advanced(by: .seconds(60))
        )
        guard case let .saved(record) = result else { return XCTFail("Expected saved time-only walk") }
        XCTAssertEqual(record.trackingMode, .timerOnly)
        XCTAssertEqual(record.confirmedActiveSeconds, 60)
        XCTAssertNil(record.recordedDistanceMeters)
        XCTAssertTrue(record.route?.segments.isEmpty == true)
        let savedRecords = try await repository.loadRecords()
        XCTAssertEqual(savedRecords, [record])
    }

    func testStepsUseDisjointActiveIntervalsAndPersistPartialCoverage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let start = Date(timeIntervalSince1970: 700)
        let clock = ContinuousClock.now
        let first = try await recorder.start(
            kind: .walk, trackingMode: .timerOnly, at: start, monotonic: clock
        )
        let firstID = try XCTUnwrap(first.steps.activeInterval?.id)
        let firstLive = try await recorder.ingestSteps(
            stepSample(firstID, start: start, end: start + 10, count: 7),
            at: start + 10, monotonic: clock.advanced(by: .seconds(10))
        )
        XCTAssertTrue(firstLive)
        let replacement = try await recorder.ingestSteps(
            stepSample(firstID, start: start, end: start + 20, count: 12),
            at: start + 20, monotonic: clock.advanced(by: .seconds(20))
        )
        XCTAssertTrue(replacement)
        let paused = try await recorder.pause(
            at: start + 30, monotonic: clock.advanced(by: .seconds(30))
        )
        let reconciled = try await recorder.ingestSteps(
            stepSample(firstID, start: start, end: start + 30, count: 13, final: true),
            at: start + 31
        )
        XCTAssertTrue(reconciled)
        let lateLive = try await recorder.ingestSteps(
            stepSample(firstID, start: start, end: start + 30, count: 20),
            at: start + 32
        )
        XCTAssertFalse(lateLive)
        XCTAssertEqual(paused.confirmedActiveSeconds, 30)

        let second = try await recorder.resume(
            at: start + 100, monotonic: clock.advanced(by: .seconds(100))
        )
        let secondID = try XCTUnwrap(second.steps.activeInterval?.id)
        XCTAssertNotEqual(firstID, secondID)
        let secondLive = try await recorder.ingestSteps(
            stepSample(secondID, start: start + 100, end: start + 110, count: 5),
            at: start + 110, monotonic: clock.advanced(by: .seconds(110))
        )
        XCTAssertTrue(secondLive)
        let result = try await recorder.finish(
            at: start + 120, monotonic: clock.advanced(by: .seconds(120))
        )
        guard case let .saved(record) = result else { return XCTFail("Expected saved walk") }
        XCTAssertEqual(record.confirmedActiveSeconds, 50)
        XCTAssertEqual(record.recordedSteps, 18)
        XCTAssertTrue(record.hasIncompleteStepCoverage)
        let persisted = try await repository.loadRecords()
        XCTAssertEqual(persisted, [record])
        do {
            _ = try await recorder.ingestSteps(
                stepSample(secondID, start: start + 100, end: start + 120, count: 100, final: true),
                at: start + 130
            )
            XCTFail("A late query cannot change a finished activity")
        } catch {
            XCTAssertEqual(error as? OutdoorRecorderError, .noActivity)
        }
        let afterLateResult = try await repository.loadRecords()
        XCTAssertEqual(afterLateResult, [record])
    }

    func testPauseResumeAndFinishCountContinuousTimeNotWallClockChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 1_000)

        _ = try await recorder.start(kind: .walk, at: wall, monotonic: t0)
        let paused = try await recorder.pause(
            at: wall.addingTimeInterval(-3_600), monotonic: t0.advanced(by: .seconds(20))
        )
        XCTAssertEqual(paused.confirmedActiveSeconds, 20)
        XCTAssertEqual(paused.phase, .paused)

        let resumed = try await recorder.resume(
            at: wall.addingTimeInterval(200), monotonic: t0.advanced(by: .seconds(200))
        )
        XCTAssertEqual(resumed.confirmedActiveSeconds, 20)
        let finished = try await recorder.finish(
            at: wall.addingTimeInterval(10), monotonic: t0.advanced(by: .seconds(210))
        )
        guard case let .saved(record) = finished else { return XCTFail("Expected saved activity") }
        XCTAssertEqual(record.confirmedActiveSeconds, 30)
        let state = await recorder.state()
        XCTAssertEqual(state, .idle)
        let records = try await repository.loadRecords()
        XCTAssertEqual(records, [record])
    }

    func testInterruptedRecordingRequiresResumeAndStartsANewRouteSegment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let firstRecorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 2_000)
        _ = try await firstRecorder.start(kind: .run, at: wall, monotonic: t0)
        _ = try await firstRecorder.ingestLocation(
            fix(0, at: wall), receivedAt: wall, monotonic: t0, policy: policy
        )
        _ = try await firstRecorder.ingestLocation(
            fix(0.001, at: wall.addingTimeInterval(20)),
            receivedAt: wall.addingTimeInterval(20),
            monotonic: t0.advanced(by: .seconds(20)), policy: policy
        )

        let restoredRecorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let restored = try await restoredRecorder.restore()
        guard case let .interrupted(checkpoint) = restored else {
            return XCTFail("An interrupted recorder must not resume itself")
        }
        XCTAssertEqual(checkpoint.confirmedActiveSeconds, 20)
        let priorDistance = checkpoint.route.recordedDistanceMeters

        _ = try await restoredRecorder.resume(
            at: wall.addingTimeInterval(300), monotonic: t0.advanced(by: .seconds(300))
        )
        let outcome = try await restoredRecorder.ingestLocation(
            fix(0.01, at: wall.addingTimeInterval(310)),
            receivedAt: wall.addingTimeInterval(310),
            monotonic: t0.advanced(by: .seconds(310)), policy: policy
        )
        XCTAssertEqual(outcome, .startedSegment)
        let current = await restoredRecorder.state()
        guard case let .recording(afterResume) = current else { return XCTFail("Expected recording") }
        XCTAssertEqual(afterResume.route.segments.count, 2)
        XCTAssertEqual(afterResume.route.recordedDistanceMeters, priorDistance)
        XCTAssertTrue(afterResume.route.hasMissingLocationCoverage)
        XCTAssertEqual(afterResume.confirmedActiveSeconds, 30)
    }

    func testInterruptedRecordingCanFinishWithoutInventingMissingTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let firstRecorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 2_500)
        _ = try await firstRecorder.start(kind: .walk, at: wall, monotonic: t0)
        _ = try await firstRecorder.heartbeat(at: wall.addingTimeInterval(12),
                                              monotonic: t0.advanced(by: .seconds(12)))

        let recovered = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        _ = try await recovered.restore()
        let outcome = try await recovered.finish(at: wall.addingTimeInterval(500),
                                                  monotonic: t0.advanced(by: .seconds(500)))
        guard case let .saved(record) = outcome else { return XCTFail("Expected saved recovery") }
        XCTAssertEqual(record.confirmedActiveSeconds, 12)
        XCTAssertTrue(record.hasMissingLocationCoverage)
        XCTAssertNil(record.recordedSteps)
        XCTAssertTrue(record.hasIncompleteStepCoverage)
    }

    func testStorageFailureStopsRecordingAndRetryRestoresPausedState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 3_000)
        _ = try await recorder.start(kind: .walk, at: wall, monotonic: t0)
        let activeURL = directory.appendingPathComponent("active-outdoor.json")
        let acknowledged = try Data(contentsOf: activeURL)
        try Data("broken".utf8).write(to: activeURL)

        do {
            _ = try await recorder.heartbeat(at: wall.addingTimeInterval(10),
                                             monotonic: t0.advanced(by: .seconds(10)))
            XCTFail("Corrupt active state must stop recording")
        } catch {
            XCTAssertNotNil(error)
        }
        guard case let .storageBlocked(pending) = await recorder.state() else {
            return XCTFail("Expected storage-blocked state")
        }
        XCTAssertEqual(pending.confirmedActiveSeconds, 10)
        try acknowledged.write(to: activeURL)

        let recovered = try await recorder.retryStorage(at: wall.addingTimeInterval(100))
        guard case let .paused(saved) = recovered else { return XCTFail("Retry must not auto-resume") }
        XCTAssertEqual(saved.confirmedActiveSeconds, 10)
        XCTAssertTrue(saved.route.hasMissingLocationCoverage)
        let durable = try await repository.loadCheckpoint()
        XCTAssertEqual(durable, saved)
    }

    func testFailedFinishCanRetryWithoutCountingTheWaitOrDuplicatingHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 4_000)
        _ = try await recorder.start(kind: .run, at: wall, monotonic: t0)
        let historyURL = directory.appendingPathComponent("outdoor-history.json")
        try Data("broken".utf8).write(to: historyURL)

        do {
            _ = try await recorder.finish(at: wall.addingTimeInterval(15),
                                          monotonic: t0.advanced(by: .seconds(15)))
            XCTFail("A failed history read cannot report saved")
        } catch {
            XCTAssertNotNil(error)
        }
        guard case let .storageBlocked(pending) = await recorder.state() else {
            return XCTFail("Expected pending finish")
        }
        XCTAssertEqual(pending.confirmedActiveSeconds, 15)
        XCTAssertEqual(pending.phase, .readyToSave)
        try FileManager.default.removeItem(at: historyURL)

        let afterRetry = try await recorder.retryStorage(at: wall.addingTimeInterval(300))
        XCTAssertEqual(afterRetry, .idle)
        let records = try await repository.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.confirmedActiveSeconds, 15)
    }

    func testCannotIngestWhilePaused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 5_000)
        _ = try await recorder.start(kind: .walk, at: wall, monotonic: t0)
        _ = try await recorder.pause(at: wall.addingTimeInterval(5),
                                     monotonic: t0.advanced(by: .seconds(5)))
        do {
            _ = try await recorder.ingestLocation(
                fix(0, at: wall.addingTimeInterval(10)),
                receivedAt: wall.addingTimeInterval(10),
                monotonic: t0.advanced(by: .seconds(10)), policy: policy
            )
            XCTFail("Paused activities cannot accept route points")
        } catch {
            XCTAssertEqual(error as? OutdoorRecorderError, .notRecording)
        }
        let saved = try await repository.loadCheckpoint()
        XCTAssertEqual(saved?.confirmedActiveSeconds, 5)
        XCTAssertTrue(saved?.route.segments.isEmpty ?? false)
    }

    func testRegressedContinuousInstantCannotChangeAcknowledgedTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let t0 = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 6_000)
        let first = try await recorder.start(kind: .walk, at: wall, monotonic: t0)

        do {
            _ = try await recorder.heartbeat(at: wall.addingTimeInterval(1),
                                             monotonic: t0.advanced(by: .seconds(-1)))
            XCTFail("A regressed continuous timestamp must be rejected")
        } catch {
            XCTAssertEqual(error as? OutdoorRecorderError, .clockRegression)
        }
        let persisted = try await repository.loadCheckpoint()
        XCTAssertEqual(persisted, first)
    }

    func testPausedTravelAndDelayedPreResumeFixCannotConsumeResumeBreak() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let start = Date(timeIntervalSince1970: 8_000)
        let clock = ContinuousClock.now
        _ = try await recorder.start(kind: .walk, at: start, monotonic: clock)
        _ = try await recorder.ingestLocation(fix(0, at: start), receivedAt: start, monotonic: clock, policy: policy)
        _ = try await recorder.ingestLocation(fix(0.001, at: start + 20), receivedAt: start + 20,
                                             monotonic: clock.advanced(by: .seconds(20)), policy: policy)
        let paused = try await recorder.pause(at: start + 30, monotonic: clock.advanced(by: .seconds(30)))
        _ = try await recorder.resume(at: start + 200, monotonic: clock.advanced(by: .seconds(200)))
        let stale = try await recorder.ingestLocation(fix(0.05, at: start + 100), receivedAt: start + 201,
                                                     monotonic: clock.advanced(by: .seconds(201)), policy: policy)
        XCTAssertEqual(stale, .rejected(.outsideActiveInterval))
        let firstResumed = try await recorder.ingestLocation(fix(0.1, at: start + 202), receivedAt: start + 202,
                                                            monotonic: clock.advanced(by: .seconds(202)), policy: policy)
        XCTAssertEqual(firstResumed, .startedSegment)
        guard case let .recording(current) = await recorder.state() else { return XCTFail("Expected resumed session") }
        XCTAssertEqual(current.route.recordedDistanceMeters, paused.route.recordedDistanceMeters)
        XCTAssertEqual(current.route.segments.count, 2)
        XCTAssertEqual(current.route.segments[0].endsAtUserPause, true)
        XCTAssertEqual(current.route.segments[1].points.map(\.timestamp), [start + 202])
        XCTAssertFalse(current.route.hasMissingLocationCoverage)
        let durable = try await repository.loadCheckpoint()
        XCTAssertEqual(durable, current)
    }

    func testConcurrentCumulativeStepsAreSerializedAndNewestCountIsDurable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let recorder = OutdoorActivityRecorder(repository: repository)
        let start = Date(timeIntervalSince1970: 9_000)
        let clock = ContinuousClock.now
        let initial = try await recorder.start(kind: .walk, trackingMode: .timerOnly, at: start, monotonic: clock)
        let intervalID = try XCTUnwrap(initial.steps.activeInterval?.id)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for count in 1...20 {
                let snapshot = OutdoorStepSnapshot(intervalID: intervalID, sampleStartedAt: start,
                                                   sampleEndedAt: start + Double(count), cumulativeSteps: count, isFinal: false)
                group.addTask {
                    _ = try await recorder.ingestSteps(snapshot, at: start + 20, monotonic: clock.advanced(by: .seconds(20)))
                }
            }
            try await group.waitForAll()
        }
        guard case let .recording(current) = await recorder.state() else { return XCTFail("Expected active session") }
        XCTAssertEqual(current.steps.recordedSteps, 20)
        XCTAssertEqual(current.confirmedActiveSeconds, 20)
        let durable = try await repository.loadCheckpoint()
        XCTAssertEqual(durable, current)
    }

    private func fix(_ longitude: Double, at time: Date) -> OutdoorRouteFix {
        OutdoorRouteFix(latitude: 0, longitude: longitude, timestamp: time, horizontalAccuracyMeters: 5)
    }

    private func stepSample(
        _ id: UUID, start: Date, end: Date, count: Int, final: Bool = false
    ) -> OutdoorStepSnapshot {
        OutdoorStepSnapshot(
            intervalID: id,
            sampleStartedAt: start,
            sampleEndedAt: end,
            cumulativeSteps: count,
            isFinal: final
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
