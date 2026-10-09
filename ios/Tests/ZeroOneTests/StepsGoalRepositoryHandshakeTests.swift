import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class StepsGoalRepositoryHandshakeTests: XCTestCase {
    private func fixture() -> (GoalHandshakeCaller, ControlledGoalStepsService, UserDefaults, String) {
        let suite = "StepsGoalRepositoryHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let clock = GoalQueryClock()
        let service = ControlledGoalStepsService()
        let repository = StepsDayRepository(service: service, defaults: defaults, now: { clock.now })
        return (GoalHandshakeCaller(repository: repository, clock: clock), service, defaults, suite)
    }

    private func connectBelow(_ caller: GoalHandshakeCaller, _ service: ControlledGoalStepsService) async {
        let connection = Task { await caller.connectSteps() }
        await service.waitForAccess()
        XCTAssertEqual(caller.repository.status, .connecting)
        caller.statusChanged(caller.repository.status)
        service.completeAccess(.completed)
        await service.waitForRead(1)
        XCTAssertEqual(caller.repository.status, .connected)
        caller.statusChanged(caller.repository.status)
        service.completeRead(steps: 7_999)
        await connection.value
    }

    func testOverlappingRefreshSkippedByActualRepositoryDoesNotStealTicket() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        await connectBelow(caller, service)
        caller.clock.now.addTimeInterval(1)
        let owner = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        XCTAssertTrue(caller.repository.isRefreshing)
        await caller.refreshSteps(allowCelebration: true)
        XCTAssertEqual(service.reads, 2, "The second call must not create another Health query.")
        XCTAssertEqual(caller.repository.reading?.totalSteps, 7_999)
        service.completeRead(steps: 8_000)
        await owner.value
        XCTAssertEqual(caller.attainments.count, 1, "The actual query owner's ticket must survive the skipped caller.")
        XCTAssertEqual(caller.attainments.first?.observedReadAt, caller.clock.now)
        caller.clock.now.addTimeInterval(1)
        let settled = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(3)
        service.completeRead(steps: 8_100)
        await settled.value
        XCTAssertEqual(caller.attainments.count, 1)
    }

    func testExpectedPermissionAndReadTransitionsSeedBelowThenNextQueryCanAttain() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        await connectBelow(caller, service)
        XCTAssertEqual(service.requests, 1)
        XCTAssertTrue(caller.attainments.isEmpty, "Connection is baseline-only.")
        // A delayed connected callback must not erase the post-connect baseline.
        caller.statusChanged(.connected)
        caller.clock.now.addTimeInterval(1)
        let fresh = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        service.completeRead(steps: 8_000)
        await fresh.value
        XCTAssertEqual(caller.attainments.count, 1)
        XCTAssertEqual(service.requests, 1, "Refresh must not request permission again.")
    }

    func testContextInvalidationDuringPermissionCannotSeedCompletionBaseline() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = Task { await caller.connectSteps() }
        await service.waitForAccess()
        caller.statusChanged(.connecting)
        caller.invalidateGoalMoment() // Same production path for scene/day/calendar/goal/disappear.
        service.completeAccess(.completed)
        await service.waitForRead(1)
        caller.statusChanged(.connected)
        service.completeRead(steps: 7_999)
        await connection.value
        caller.clock.now.addTimeInterval(1)
        let next = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        service.completeRead(steps: 8_000)
        await next.value
        XCTAssertTrue(caller.attainments.isEmpty, "A source/context gap must not be bridged by old connect completion.")
    }

    func testCancelledConnectionCannotSeedCompletionBaseline() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = Task { await caller.connectSteps() }
        await service.waitForAccess()
        caller.statusChanged(.connecting)
        service.completeAccess(.completed)
        await service.waitForRead(1)
        caller.statusChanged(.connected)
        connection.cancel()
        service.completeRead(steps: 7_999)
        await connection.value
        caller.clock.now.addTimeInterval(1)
        let next = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        service.completeRead(steps: 8_000)
        await next.value
        XCTAssertTrue(caller.attainments.isEmpty)
    }

    func testContextReplacementDuringConnectedReadCannotSeedCompletionBaseline() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = Task { await caller.connectSteps() }
        await service.waitForAccess()
        caller.statusChanged(.connecting)
        service.completeAccess(.completed)
        await service.waitForRead(1)
        caller.statusChanged(.connected)
        caller.invalidateGoalMoment()
        service.completeRead(steps: 7_999)
        await connection.value
        caller.statusChanged(.connected)
        caller.clock.now.addTimeInterval(1)
        let next = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        service.completeRead(steps: 8_000)
        await next.value
        XCTAssertTrue(caller.attainments.isEmpty)
    }

    func testRefreshFailureAndRecoveredAttainmentCannotBridgeGap() async {
        let (caller, service, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        await connectBelow(caller, service)
        caller.clock.now.addTimeInterval(1)
        let failed = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(2)
        service.failRead()
        await failed.value
        XCTAssertEqual(caller.repository.issue, .readFailed)
        XCTAssertEqual(caller.repository.reading?.totalSteps, 7_999)
        caller.clock.now.addTimeInterval(1)
        let recovered = Task { await caller.refreshSteps(allowCelebration: true) }
        await service.waitForRead(3)
        service.completeRead(steps: 8_000)
        await recovered.value
        XCTAssertNil(caller.repository.issue)
        XCTAssertTrue(caller.attainments.isEmpty)
    }
}

/// Exercises the production wrapper handshake against the actual repository.
/// Its operation bodies are checked against the owned view source in verify.cjs;
/// only the clock, effect sink and SwiftUI lifecycle delivery are test adapters.
@MainActor
private final class GoalHandshakeCaller {
    let repository: StepsDayRepository
    let clock: GoalQueryClock
    var observationGate = StepsGoalObservationGate()
    var goalConnectionContextID = UUID()
    var attainments: [StepsGoalObservationGate.Attainment] = []

    init(repository: StepsDayRepository, clock: GoalQueryClock) {
        self.repository = repository
        self.clock = clock
    }

    private func goalObservation(now: Date) -> StepsGoalObservation? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reading = repository.currentReading(on: now, calendar: calendar)
        return StepsGoalObservation(calendar: calendar, now: now, goal: 8_000,
            readingDayStart: reading?.dayStart, readAt: reading?.readAt, steps: reading?.totalSteps,
            isAvailable: repository.status == .connected && repository.issue == nil)
    }

    func refreshSteps(allowCelebration: Bool) async {
        guard !repository.isRefreshing else { return }
        let ticket = observationGate.begin(goalObservation(now: clock.now), allowCelebration: allowCelebration)
        await repository.refresh()
        guard !Task.isCancelled else { observationGate.invalidate(); return }
        if let attainment = observationGate.complete(ticket, with: goalObservation(now: clock.now)) {
            attainments.append(attainment)
        }
    }

    func connectSteps() async {
        guard repository.status == .notConnected, !repository.isRefreshing else { return }
        invalidateGoalMoment()
        let contextID = goalConnectionContextID
        await repository.connect()
        guard contextID == goalConnectionContextID else { return }
        guard !Task.isCancelled else { invalidateGoalMoment(); return }
        let ticket = observationGate.begin(nil, allowCelebration: false)
        _ = observationGate.complete(ticket, with: goalObservation(now: clock.now))
    }

    func statusChanged(_ status: HealthConnectionStatus) {
        if status == .connecting { invalidateGoalMoment(invalidateConnection: false) }
        else if status != .connected { invalidateGoalMoment() }
    }

    func invalidateGoalMoment(invalidateConnection: Bool = true) {
        if invalidateConnection { goalConnectionContextID = UUID() }
        observationGate.invalidate()
    }
}

@MainActor
private final class GoalQueryClock {
    // Controlled dates remain within one actual UTC calendar day.
    var now = Date(timeIntervalSince1970: 1_800_014_400)
}

@MainActor
private final class ControlledGoalStepsService: StepsHealthServicing {
    var isStepsAvailable = true
    private(set) var requests = 0
    private(set) var reads = 0
    private var access: CheckedContinuation<HealthAuthorizationOutcome, Never>?
    private var accessEntered: CheckedContinuation<Void, Never>?
    private var reading: CheckedContinuation<StepsDayReading, Error>?
    private var readEntered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var queryDate: Date?

    func requestStepsAccess() async -> HealthAuthorizationOutcome {
        requests += 1
        return await withCheckedContinuation { continuation in
            access = continuation
            accessEntered?.resume()
            accessEntered = nil
        }
    }

    func waitForAccess() async {
        if access != nil { return }
        await withCheckedContinuation { accessEntered = $0 }
    }

    func completeAccess(_ outcome: HealthAuthorizationOutcome) {
        guard let continuation = access else { preconditionFailure("No permission request is pending") }
        access = nil
        continuation.resume(returning: outcome)
    }

    func readStepsDay(at date: Date) async throws -> StepsDayReading {
        reads += 1
        let count = reads
        queryDate = date
        return try await withCheckedThrowingContinuation { continuation in
            precondition(reading == nil)
            reading = continuation
            readEntered.removeValue(forKey: count)?.resume()
        }
    }

    func waitForRead(_ count: Int) async {
        if reads >= count { return }
        await withCheckedContinuation { readEntered[count] = $0 }
    }

    func completeRead(steps: Double) {
        guard let continuation = reading, let date = queryDate else { preconditionFailure("No read is pending") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        reading = nil
        queryDate = nil
        continuation.resume(returning: StepsDayReading(readAt: date,
            dayStart: calendar.startOfDay(for: date), totalSteps: steps, distanceMeters: nil, hours: []))
    }

    func failRead() {
        guard let continuation = reading else { preconditionFailure("No read is pending") }
        reading = nil
        queryDate = nil
        continuation.resume(throwing: ControlledGoalReadError.failed)
    }
}

private enum ControlledGoalReadError: Error { case failed }
