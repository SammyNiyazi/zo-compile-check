import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorActivityRepositoryTests: XCTestCase {
    func testInterruptedRecordingRestoresOnlyAcknowledgedTimeAndNeedsExplicitResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = checkpoint(phase: .recording, activeSeconds: 37)
        try await OutdoorActivityRepository(directory: directory).saveCheckpoint(original)

        let restored = try await OutdoorActivityRepository(directory: directory).loadCheckpoint()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored?.confirmedActiveSeconds, 37)
        XCTAssertEqual(restored?.recoveryState, .needsExplicitResume)
    }

    func testPausedCheckpointSurvivesRelaunchWithoutCountingTheGap() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 20)
        try await repository.saveCheckpoint(first)

        var paused = first
        paused.revision = 2
        paused.phase = .paused
        paused.checkpointedAt = first.checkpointedAt.addingTimeInterval(30)
        paused.route.breakForUserPause()
        try await repository.saveCheckpoint(paused)

        let restored = try await OutdoorActivityRepository(directory: directory).loadCheckpoint()
        XCTAssertEqual(restored?.recoveryState, .paused)
        XCTAssertEqual(restored?.confirmedActiveSeconds, 20)
        XCTAssertEqual(restored?.route, paused.route)
    }

    func testStaleRevisionAndDifferentOwnerCannotReplaceCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 10)
        try await repository.saveCheckpoint(first)
        try await repository.saveCheckpoint(first) // Exact retry is harmless.

        var stale = first
        stale.confirmedActiveSeconds = 11
        do {
            try await repository.saveCheckpoint(stale)
            XCTFail("A conflicting write at the same revision must fail")
        } catch {
            XCTAssertEqual(error as? OutdoorActivityPersistenceError, .staleCheckpoint)
        }

        do {
            try await repository.saveCheckpoint(checkpoint(phase: .recording, activeSeconds: 1))
            XCTFail("Another active activity must not replace the owner")
        } catch {
            XCTAssertEqual(error as? OutdoorActivityPersistenceError, .conflictingActivity)
        }
        let persisted = try await repository.loadCheckpoint()
        XCTAssertEqual(persisted, first)
    }

    func testFinishIsDurableAndRetryDoesNotDuplicateHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 21, route: measuredRoute())
        try await repository.saveCheckpoint(first)
        let final = finished(first)

        guard case let .saved(record) = try await repository.finish(final) else {
            return XCTFail("First finish should save")
        }
        let cleared = try await repository.loadCheckpoint()
        let saved = try await repository.loadRecords()
        XCTAssertNil(cleared)
        XCTAssertEqual(saved, [record])
        XCTAssertNotNil(record.recordedDistanceMeters)

        guard case let .alreadySaved(retried) = try await OutdoorActivityRepository(directory: directory).finish(final) else {
            return XCTFail("Retry after relaunch should recognize the saved activity")
        }
        XCTAssertEqual(retried, record)
        let recordsAfterRetry = try await repository.loadRecords()
        XCTAssertEqual(recordsAfterRetry.count, 1)
    }

    func testFinishRecoversFromCheckpointAndHistoryWriteCrashBoundaries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 18)
        try await repository.saveCheckpoint(first)
        let final = finished(first)

        // Process interruption after the frozen checkpoint, before history write.
        try await repository.saveCheckpoint(final)
        let frozen = try await OutdoorActivityRepository(directory: directory).loadCheckpoint()
        XCTAssertEqual(frozen, final)
        let finishedAt = try XCTUnwrap(final.finishedAt)
        let record = OutdoorActivityRecord(checkpoint: final, finishedAt: finishedAt)

        // Process interruption after history write, before the active tombstone.
        try JSONEncoder().encode([record]).write(
            to: directory.appendingPathComponent("outdoor-history.json"), options: .atomic
        )
        guard case let .alreadySaved(recovered) = try await OutdoorActivityRepository(directory: directory).finish(final) else {
            return XCTFail("Retry should reconcile the existing history record")
        }
        XCTAssertEqual(recovered, record)
        let cleared = try await repository.loadCheckpoint()
        let saved = try await repository.loadRecords()
        XCTAssertNil(cleared)
        XCTAssertEqual(saved.count, 1)
    }

    func testUnreadableHistoryCannotBeOverwrittenOrClaimedSaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 12)
        try await repository.saveCheckpoint(first)
        let historyURL = directory.appendingPathComponent("outdoor-history.json")
        try Data("not valid JSON".utf8).write(to: historyURL)

        do {
            _ = try await repository.finish(finished(first))
            XCTFail("Corrupt history must not be replaced with a new record")
        } catch {
            XCTAssertNotNil(error)
        }
        let persisted = try await repository.loadCheckpoint()
        XCTAssertEqual(persisted, first)
        XCTAssertEqual(try Data(contentsOf: historyURL), Data("not valid JSON".utf8))
    }

    func testDeleteRouteKeepsTotalsButDeleteSessionRemovesTheRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = OutdoorActivityRepository(directory: directory)
        let first = checkpoint(phase: .recording, activeSeconds: 41, route: measuredRoute())
        try await repository.saveCheckpoint(first)
        let final = finished(first)
        _ = try await repository.finish(final)

        let deleted = try await repository.deleteRoute(for: first.id, at: Date(timeIntervalSince1970: 1_200))
        XCTAssertNil(deleted.route)
        XCTAssertNotNil(deleted.routeDeletedAt)
        XCTAssertNotNil(deleted.recordedDistanceMeters)
        XCTAssertEqual(deleted.confirmedActiveSeconds, 41)
        let afterRouteDeletion = try await repository.loadRecords()
        let repeatedRouteDeletion = try await repository.deleteRoute(for: first.id, at: Date())
        XCTAssertEqual(afterRouteDeletion, [deleted])
        XCTAssertEqual(repeatedRouteDeletion, deleted)

        let deletedOnce = try await repository.deleteSession(first.id)
        let deletedTwice = try await repository.deleteSession(first.id)
        let remaining = try await repository.loadRecords()
        XCTAssertTrue(deletedOnce)
        XCTAssertFalse(deletedTwice)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTamperedDistanceIsNotAValidCheckpoint() throws {
        let route = measuredRoute()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any])
        payload["totalRecordedMeters"] = 50_000.0
        let tampered = try JSONDecoder().decode(
            OutdoorRouteAccumulator.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertFalse(tampered.isInternallyConsistent)
    }

    private func checkpoint(
        phase: OutdoorActivityPhase,
        activeSeconds: TimeInterval,
        route: OutdoorRouteAccumulator = OutdoorRouteAccumulator()
    ) -> OutdoorActivityCheckpoint {
        let start = Date(timeIntervalSince1970: 1_000)
        return OutdoorActivityCheckpoint(
            kind: .walk,
            startedAt: start,
            checkpointedAt: start.addingTimeInterval(30),
            confirmedActiveSeconds: activeSeconds,
            phase: phase,
            route: route
        )
    }

    private func finished(_ first: OutdoorActivityCheckpoint) -> OutdoorActivityCheckpoint {
        var final = first
        final.revision += 1
        final.phase = .readyToSave
        final.finishedAt = first.checkpointedAt.addingTimeInterval(12)
        final.checkpointedAt = final.finishedAt ?? first.checkpointedAt
        return final
    }

    private func measuredRoute() -> OutdoorRouteAccumulator {
        let policy = OutdoorRouteAcceptancePolicy(
            maximumHorizontalAccuracyMeters: 35,
            maximumGapSeconds: 30,
            maximumPlausibleSpeedMetersPerSecond: 15,
            maximumFutureSeconds: 5
        )
        let start = Date(timeIntervalSince1970: 1_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(
            OutdoorRouteFix(latitude: 0, longitude: 0, timestamp: start, horizontalAccuracyMeters: 5),
            receivedAt: start, policy: policy
        )
        let next = start.addingTimeInterval(20)
        route.ingest(
            OutdoorRouteFix(latitude: 0, longitude: 0.001, timestamp: next, horizontalAccuracyMeters: 5),
            receivedAt: next, policy: policy
        )
        return route
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-outdoor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
