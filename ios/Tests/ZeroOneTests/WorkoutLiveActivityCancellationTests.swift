import Foundation
import XCTest
@testable import ZeroOne

/// Exercises the actual coordinator with a controlled ActivityKit boundary.
/// No real Activity, OS delivery, widget container or permission is fabricated.
@MainActor
final class WorkoutLiveActivityCancellationTests: XCTestCase {
    func testAlreadyCancelledSyncReadsNoActivitiesAndIssuesNoOperations() async {
        let client = Client()
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let entry = Suspension("entry")
        let work = Task { @MainActor in
            await entry.wait()
            await coordinator.sync(self.projection())
        }
        defer { work.cancel(); entry.release() }
        await fulfillment(of: [entry.started], timeout: 5)
        work.cancel()
        entry.release()
        await work.value
        XCTAssertEqual(client.activityReads, 0)
        XCTAssertEqual(client.requestAttempts, 0)
    }

    func testCancellationDuringEndStopsFurtherEndAndRequest() async {
        let client = Client()
        let first = Handle(sessionID: UUID(), state: state())
        let second = Handle(sessionID: UUID(), state: state())
        let hold = Suspension("first end")
        first.endHold = hold
        client.handles = [first, second]
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let desired = projection()
        let work = Task { @MainActor in await coordinator.sync(desired) }
        defer { work.cancel(); hold.release() }
        await fulfillment(of: [hold.started], timeout: 5)
        work.cancel()
        hold.release()
        await work.value
        XCTAssertEqual(first.ends, 1, "The already submitted end cannot be recalled.")
        XCTAssertEqual(second.ends, 0)
        XCTAssertEqual(client.requestAttempts, 0)
    }

    func testCancellationDuringForeignEndStopsMatchingUpdate() async {
        let client = Client()
        let desired = projection()
        let matching = Handle(sessionID: desired.sessionID, state: state(completed: 0))
        let foreign = Handle(sessionID: UUID(), state: state())
        let hold = Suspension("foreign end")
        foreign.endHold = hold
        client.handles = [foreign, matching]
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let work = Task { @MainActor in await coordinator.sync(desired) }
        defer { work.cancel(); hold.release() }
        await fulfillment(of: [hold.started], timeout: 5)
        work.cancel()
        hold.release()
        await work.value
        XCTAssertTrue(matching.updates.isEmpty)
        XCTAssertEqual(client.requestAttempts, 0)
    }

    func testNewSyncWhileEndSuspendsPreventsObsoleteRequest() async {
        let client = Client()
        let foreign = Handle(sessionID: UUID(), state: state())
        let hold = Suspension("obsolete end")
        foreign.endHold = hold
        client.handles = [foreign]
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let obsolete = projection(), newest = projection()
        let work = Task { @MainActor in await coordinator.sync(obsolete) }
        defer { work.cancel(); hold.release() }
        await fulfillment(of: [hold.started], timeout: 5)
        // The controlled backend exposes the ended activity's removal while its
        // completion is suspended. No assumption is made about OS ordering.
        client.handles = []
        await coordinator.sync(newest)
        hold.release()
        await work.value
        XCTAssertEqual(client.requests.map(\.sessionID), [newest.sessionID])
    }

    func testAlreadyCancelledInvocationDoesNotStealSuspendedOwnerGeneration() async {
        let client = Client()
        let foreign = Handle(sessionID: UUID(), state: state())
        let hold = Suspension("actual end")
        foreign.endHold = hold
        client.handles = [foreign]
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let actual = projection(), cancelled = projection()
        let owner = Task { @MainActor in await coordinator.sync(actual) }
        defer { owner.cancel(); hold.release() }
        await fulfillment(of: [hold.started], timeout: 5)
        let entry = Suspension("cancelled entry")
        let skipped = Task { @MainActor in
            await entry.wait()
            await coordinator.sync(cancelled)
        }
        defer { skipped.cancel(); entry.release() }
        await fulfillment(of: [entry.started], timeout: 5)
        skipped.cancel()
        entry.release()
        await skipped.value
        hold.release()
        await owner.value
        XCTAssertEqual(client.requests.map(\.sessionID), [actual.sessionID])
    }

    func testCancelledSubmittedUpdateCanFinishAndLaterCurrentSyncStillUpdates() async {
        let client = Client()
        let first = projection()
        let matching = Handle(sessionID: first.sessionID, state: state(completed: 0))
        let hold = Suspension("submitted update")
        matching.updateHold = hold
        client.handles = [matching]
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let work = Task { @MainActor in await coordinator.sync(first) }
        defer { work.cancel(); hold.release() }
        await fulfillment(of: [hold.started], timeout: 5)
        work.cancel()
        hold.release()
        await work.value
        XCTAssertEqual(matching.updates, [first], "Cancellation cannot recall a submitted backend update.")
        matching.updateHold = nil
        let current = projection(sessionID: first.sessionID, completed: 2)
        await coordinator.sync(current)
        XCTAssertEqual(matching.updates, [first, current])
        XCTAssertEqual(client.requestAttempts, 0)
    }

    func testFailedRequestAllowsRetryAndAcceptedSessionStillDeduplicates() async {
        let client = Client()
        let coordinator = WorkoutLiveActivityCoordinator(client: client)
        let desired = projection()
        client.failNextRequest = true
        await coordinator.sync(desired)
        await coordinator.sync(desired)
        await coordinator.sync(desired)
        XCTAssertEqual(client.requestAttempts, 2)
        XCTAssertEqual(client.requests, [desired])
    }

    private func state(completed: Int = 1) -> WorkoutActivityAttributes.ContentState {
        .init(exerciseName: "Synthetic exercise", currentSet: 2, plannedSetsForExercise: 3,
              completedSets: completed, totalSets: 3, phase: .active, restEndsAt: nil,
              pausedRestSeconds: nil)
    }

    private func projection(sessionID: UUID = UUID(), completed: Int = 1) -> WorkoutActivityProjection {
        .init(sessionID: sessionID, workoutTitle: "Synthetic workout", state: state(completed: completed))
    }

    @MainActor private final class Suspension {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(_ name: String) { started = XCTestExpectation(description: name) }
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        func release() {
            guard !released else { return }
            released = true
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume()
        }
    }

    @MainActor private final class Handle: WorkoutLiveActivityHandle {
        let id = UUID().uuidString
        let sessionID: UUID
        var state: WorkoutActivityAttributes.ContentState
        var ends = 0
        var updates: [WorkoutActivityProjection] = []
        var endHold: Suspension?
        var updateHold: Suspension?
        init(sessionID: UUID, state: WorkoutActivityAttributes.ContentState) {
            self.sessionID = sessionID
            self.state = state
        }
        func end() async {
            ends += 1
            if let endHold { await endHold.wait() }
        }
        func update(_ projection: WorkoutActivityProjection) async {
            updates.append(projection)
            if let updateHold { await updateHold.wait() }
            state = projection.state
        }
    }

    @MainActor private final class Client: WorkoutLiveActivityClient {
        enum Failure: Error { case synthetic }
        var handles: [any WorkoutLiveActivityHandle] = []
        var activityReads = 0
        var requestAttempts = 0
        var requests: [WorkoutActivityProjection] = []
        var failNextRequest = false
        var areActivitiesEnabled = true
        var activities: [any WorkoutLiveActivityHandle] {
            activityReads += 1
            return handles
        }
        func request(_ projection: WorkoutActivityProjection) throws {
            requestAttempts += 1
            if failNextRequest { failNextRequest = false; throw Failure.synthetic }
            requests.append(projection)
        }
    }
}
