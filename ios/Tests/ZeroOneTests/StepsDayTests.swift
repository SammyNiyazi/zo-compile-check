import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class StepsDayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepository(_ service: StepsServiceStub) -> (StepsDayRepository, UserDefaults, String) {
        let suite = "StepsDayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let date = now
        return (StepsDayRepository(service: service, defaults: defaults, now: { date }), defaults, suite)
    }

    func testRefreshNeverRequestsPermissionAndConnectRequestsOnlyOnce() async {
        let service = StepsServiceStub()
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.refresh()
        XCTAssertEqual(service.requests, 0)
        XCTAssertEqual(service.reads, 0)
        await repository.connect()
        await repository.connect()
        XCTAssertEqual(service.requests, 1)
        XCTAssertEqual(service.reads, 1)
        XCTAssertEqual(repository.status, .connected)
        XCTAssertNil(repository.reading?.totalSteps)
        XCTAssertNil(repository.issue, "Empty data must not be presented as a read denial.")
    }

    func testCancelledAccessDoesNotReadOrPromptOnRefresh() async {
        let service = StepsServiceStub()
        service.outcome = .cancelled
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.connect()
        await repository.refresh()
        XCTAssertEqual(service.requests, 1)
        XCTAssertEqual(service.reads, 0)
        XCTAssertEqual(repository.status, .notConnected)
        XCTAssertEqual(repository.issue, .cancelled)
    }

    func testUnavailableDeviceDoesNotAskOrRead() async {
        let service = StepsServiceStub()
        service.isStepsAvailable = false
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.connect()
        await repository.refresh()
        XCTAssertEqual(repository.status, .unavailable)
        XCTAssertEqual(service.requests, 0)
        XCTAssertEqual(service.reads, 0)
    }

    func testFailedRefreshKeepsEvidenceButNeverCarriesYesterdayIntoToday() async {
        let service = StepsServiceStub()
        service.steps = 8120
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.connect()
        service.shouldFail = true
        await repository.refresh()
        XCTAssertEqual(repository.issue, .readFailed)
        XCTAssertEqual(repository.currentReading(on: now)?.totalSteps, 8120)
        XCTAssertNil(repository.currentReading(on: now.addingTimeInterval(86_400)))
    }

    func testRestoredRequestMarkerAllowsRefreshWithoutAnotherPrompt() async {
        let service = StepsServiceStub()
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.connect()
        let date = now
        let restored = StepsDayRepository(service: service, defaults: defaults, now: { date })
        await restored.refresh()
        XCTAssertEqual(service.requests, 1)
        XCTAssertEqual(service.reads, 2)
    }

    func testInvalidMetricsAreNotZerosAndHourIdentityIsStable() {
        let hour = now.addingTimeInterval(-3600)
        let reading = StepsDayReading(
            readAt: now, totalSteps: .infinity, distanceMeters: -1,
            hours: [(hour, .nan), (hour, 100), (now.addingTimeInterval(3600), 20), (now, 0)]
        )
        XCTAssertNil(reading.totalSteps)
        XCTAssertNil(reading.distanceMeters)
        XCTAssertEqual(reading.hours.count, 2)
        XCTAssertEqual(reading.hours[0].id, hour)
        XCTAssertNil(reading.hours[0].count)
        XCTAssertEqual(reading.hours[1].count, 0)
        XCTAssertNil(StepsDayReading(readAt: now, totalSteps: Double(Int.max), distanceMeters: nil, hours: []).totalSteps)
    }

    func testDifferentTimeZoneDayBoundaryRequiresAFreshReading() async {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let service = StepsServiceStub()
        service.steps = 500
        service.dayStart = tokyo.startOfDay(for: now)
        let (repository, defaults, suite) = makeRepository(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        await repository.connect()
        XCTAssertEqual(repository.currentReading(on: now, calendar: tokyo)?.totalSteps, 500)
        XCTAssertNil(repository.currentReading(on: now, calendar: losAngeles))
    }
}

@MainActor
private final class StepsServiceStub: StepsHealthServicing {
    var isStepsAvailable = true
    var outcome: HealthAuthorizationOutcome = .completed
    var shouldFail = false
    var steps: Double?
    var dayStart: Date?
    private(set) var requests = 0
    private(set) var reads = 0

    func requestStepsAccess() async -> HealthAuthorizationOutcome {
        requests += 1
        return outcome
    }

    func readStepsDay(at date: Date) async throws -> StepsDayReading {
        reads += 1
        if shouldFail { throw StepsStubError.readFailed }
        return StepsDayReading(readAt: date, dayStart: dayStart, totalSteps: steps, distanceMeters: nil, hours: [])
    }
}

private enum StepsStubError: Error { case readFailed }
