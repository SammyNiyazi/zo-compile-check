import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorLocationRecorderPumpTests: XCTestCase {
    private let policy = OutdoorRouteAcceptancePolicy(
        maximumHorizontalAccuracyMeters: 35,
        maximumGapSeconds: 30,
        maximumPlausibleSpeedMetersPerSecond: 15,
        maximumFutureSeconds: 5
    )

    func testOrderedFixesReachTheMatchingRecorder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let start = Date()
        let checkpoint = try await recorder.start(kind: .walk, at: start)
        let stream = AsyncStream<OutdoorLocationEvent> { continuation in
            continuation.yield(.fix(fix(0, at: start), receivedAt: start))
            continuation.yield(.fix(
                fix(0.001, at: start.addingTimeInterval(20)),
                receivedAt: start.addingTimeInterval(20)
            ))
            continuation.finish()
        }

        let result = await pump(recorder).run(
            for: checkpoint.id,
            events: stream,
            stopLocation: {},
            takeStopReason: { .requested }
        )
        XCTAssertEqual(result, .stopped)
        guard case let .recording(saved) = await recorder.state() else {
            return XCTFail("Expected active recording")
        }
        XCTAssertEqual(saved.route.segments.count, 1)
        XCTAssertEqual(saved.route.segments[0].points.count, 2)
        XCTAssertNotNil(saved.route.recordedDistanceMeters)
    }

    func testGapBreaksLineWithoutConnectingDistance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let start = Date()
        let checkpoint = try await recorder.start(kind: .run, at: start)
        let stream = AsyncStream<OutdoorLocationEvent> { continuation in
            continuation.yield(.fix(fix(0, at: start), receivedAt: start))
            continuation.yield(.gap)
            continuation.yield(.fix(
                fix(0.01, at: start.addingTimeInterval(20)),
                receivedAt: start.addingTimeInterval(20)
            ))
            continuation.finish()
        }

        let result = await pump(recorder).run(
            for: checkpoint.id, events: stream, stopLocation: {}, takeStopReason: { .requested }
        )
        XCTAssertEqual(result, .stopped)
        guard case let .recording(saved) = await recorder.state() else {
            return XCTFail("Expected active recording")
        }
        XCTAssertEqual(saved.route.segments.count, 2)
        XCTAssertNil(saved.route.recordedDistanceMeters)
        XCTAssertTrue(saved.route.hasMissingLocationCoverage)
    }

    func testLostAuthorizationMarksGapAndPausesTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let checkpoint = try await recorder.start(kind: .walk, at: Date())
        let stream = AsyncStream<OutdoorLocationEvent> { $0.finish() }

        let result = await pump(recorder).run(
            for: checkpoint.id, events: stream, stopLocation: {}, takeStopReason: { .authorizationLost }
        )
        XCTAssertEqual(result, .pausedForLocationLoss(.authorizationLost))
        guard case let .paused(saved) = await recorder.state() else {
            return XCTFail("Expected paused recording")
        }
        XCTAssertTrue(saved.route.hasMissingLocationCoverage)
    }

    func testWrongSessionCannotConsumeFixes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let start = Date()
        let checkpoint = try await recorder.start(kind: .walk, at: start)
        let stopped = StopProbe()
        let stream = AsyncStream<OutdoorLocationEvent> { continuation in
            continuation.yield(.fix(fix(0, at: start), receivedAt: start))
            continuation.finish()
        }

        let result = await pump(recorder).run(
            for: UUID(), events: stream,
            stopLocation: { await stopped.mark() },
            takeStopReason: { .requested }
        )
        XCTAssertEqual(result, .recorderNotActive)
        let didStop = await stopped.value
        XCTAssertTrue(didStop)
        guard case let .recording(saved) = await recorder.state() else {
            return XCTFail("Expected original recording")
        }
        XCTAssertEqual(saved.id, checkpoint.id)
        XCTAssertTrue(saved.route.segments.isEmpty)
    }

    func testFailedJournalWriteStopsLocationProducer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let start = Date()
        let checkpoint = try await recorder.start(kind: .walk, at: start)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("active-outdoor.json"))
        let stopped = StopProbe()
        let stream = AsyncStream<OutdoorLocationEvent> { continuation in
            continuation.yield(.fix(fix(0, at: start), receivedAt: start))
            continuation.finish()
        }

        let result = await pump(recorder).run(
            for: checkpoint.id, events: stream,
            stopLocation: { await stopped.mark() },
            takeStopReason: { .requested }
        )
        XCTAssertEqual(result, .storageBlocked)
        let didStop = await stopped.value
        XCTAssertTrue(didStop)
        guard case .storageBlocked = await recorder.state() else {
            return XCTFail("Expected storage-blocked recorder")
        }
    }

    func testCancelledConsumerDoesNotDrainBufferedPausedTravel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OutdoorActivityRecorder(repository: OutdoorActivityRepository(directory: directory))
        let start = Date()
        let checkpoint = try await recorder.start(kind: .walk, at: start)
        let stopped = StopProbe()
        let stream = AsyncStream<OutdoorLocationEvent> { continuation in
            continuation.yield(.fix(fix(0, at: start), receivedAt: start))
            continuation.yield(.fix(fix(0.1, at: start + 20), receivedAt: start + 20))
            continuation.finish()
        }
        let consumer = pump(recorder)
        let result = await withTaskGroup(of: OutdoorLocationPumpResult.self) { group in
            group.cancelAll()
            // A task added to an already-cancelled group is cancelled before
            // touching the stream, making this independent of scheduling order.
            group.addTask {
                await consumer.run(for: checkpoint.id, events: stream,
                                   stopLocation: { await stopped.mark() }, takeStopReason: { .requested })
            }
            return await group.next()
        }
        XCTAssertEqual(result, .stopped)
        guard case let .recording(current) = await recorder.state() else { return XCTFail("Expected untouched session") }
        XCTAssertTrue(current.route.segments.isEmpty)
        let didStop = await stopped.value
        XCTAssertTrue(didStop)
    }

    private func pump(_ recorder: OutdoorActivityRecorder) -> OutdoorLocationRecorderPump {
        OutdoorLocationRecorderPump(recorder: recorder, policy: policy)
    }

    private func fix(_ longitude: Double, at date: Date) -> OutdoorRouteFix {
        OutdoorRouteFix(latitude: 0, longitude: longitude, timestamp: date, horizontalAccuracyMeters: 5)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-location-pump-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor StopProbe {
    private(set) var value = false
    func mark() { value = true }
}
