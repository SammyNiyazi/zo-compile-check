import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class HealthConnectionTests: XCTestCase {
    func testExplicitSetupCanRequestCurrentScopeAfterOlderCompletedSetup() async {
        let service = FakeHealthKitService()
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )
        XCTAssertEqual(repository.status, .connected)
        await repository.connect()
        XCTAssertEqual(service.requestedScopes, [.zeroOneFoundation])
        XCTAssertEqual(repository.status, .connected)
        XCTAssertFalse(repository.status.needsSetup)
    }

    func testConnectRequestsAllSupportedReadTypesTogetherWithoutWrites() async {
        let context = HealthContext(
            todaySteps: 8_120,
            todayActiveEnergyKilocalories: 512,
            mostRecentWorkout: HealthWorkoutContext(
                activityName: "Strength training",
                startedAt: Date(timeIntervalSince1970: 900),
                durationSeconds: 3_000
            ),
            lastNightSleepDurationSeconds: 27_000,
            refreshedAt: Date(timeIntervalSince1970: 1_000)
        )
        let service = FakeHealthKitService(readResult: .success(context))
        let preferenceStore = InMemoryHealthPreferenceStore()
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: preferenceStore,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await repository.connect()

        XCTAssertEqual(service.requestedScopes, [.zeroOneFoundation])
        XCTAssertEqual(service.requestedScopes.first?.readTypes, Set(HealthReadDataType.allCases))
        XCTAssertEqual(service.requestedScopes.first?.readTypes,
                       [.stepCount, .activeEnergy, .workouts, .sleepAnalysis, .bodyMass, .height, .distanceWalkingRunning])
        XCTAssertTrue(service.requestedScopes.first?.writeTypes.isEmpty == true)
        XCTAssertEqual(repository.status, .connected)
        XCTAssertEqual(repository.context, context)
        XCTAssertTrue(preferenceStore.hasCompletedHealthSetup)
    }

    func testConnectedStateRemainsCalmWhenNoSamplesAreAvailable() async {
        let refreshedAt = Date(timeIntervalSince1970: 2_000)
        let service = FakeHealthKitService(readResult: .success(.empty(refreshedAt: refreshedAt)))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore()
        )

        await repository.connect()

        XCTAssertEqual(repository.status, .connected)
        XCTAssertEqual(repository.context, .empty(refreshedAt: refreshedAt))
        XCTAssertNil(repository.issue)
    }

    func testDeniedRequestReturnsToNotConnectedWithoutPersistingSetup() async {
        let service = FakeHealthKitService(authorizationOutcome: .denied)
        let preferenceStore = InMemoryHealthPreferenceStore()
        let repository = HealthConnectionRepository(service: service, preferenceStore: preferenceStore)

        await repository.connect()

        XCTAssertEqual(repository.status, .notConnected)
        XCTAssertEqual(repository.issue, .denied)
        XCTAssertTrue(repository.status.needsSetup)
        XCTAssertFalse(preferenceStore.hasCompletedHealthSetup)
        XCTAssertEqual(service.readCallCount, 0)
    }

    func testCancelledRequestDoesNotPromptAgainAutomatically() async {
        let service = FakeHealthKitService(authorizationOutcome: .cancelled)
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore()
        )

        await repository.connect()
        await repository.refreshIfConnected()

        XCTAssertEqual(repository.status, .notConnected)
        XCTAssertEqual(repository.issue, .cancelled)
        XCTAssertEqual(service.authorizationCallCount, 1)
        XCTAssertEqual(service.readCallCount, 0)
    }

    func testUnavailableHealthKitNeverRequestsAuthorization() async {
        let service = FakeHealthKitService(isAvailable: false)
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore()
        )

        await repository.connect()

        XCTAssertEqual(repository.status, .unavailable)
        XCTAssertEqual(service.authorizationCallCount, 0)
        XCTAssertEqual(service.readCallCount, 0)
    }

    func testConnectedPreferenceRestoresAndRefreshesWithoutAnotherPrompt() async {
        let context = HealthContext.empty(refreshedAt: Date(timeIntervalSince1970: 3_000))
        let service = FakeHealthKitService(readResult: .success(context))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        await repository.refreshIfConnected()

        XCTAssertEqual(repository.status, .connected)
        XCTAssertEqual(repository.context, context)
        XCTAssertEqual(service.authorizationCallCount, 0)
        XCTAssertEqual(service.readCallCount, 1)
    }

    func testReadFailureKeepsConnectionAndReportsRecoverableIssue() async {
        let service = FakeHealthKitService(readResult: .failure(TestHealthError.readFailed))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        await repository.refreshIfConnected()

        XCTAssertEqual(repository.status, .connected)
        XCTAssertNil(repository.context)
        XCTAssertEqual(repository.issue, .readFailed)
        XCTAssertFalse(repository.isContextStale)
    }

    func testAuthorizationRequestFailureIsDistinctFromReadFailure() async {
        let service = FakeHealthKitService(authorizationOutcome: .failed)
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore()
        )

        await repository.connect()

        XCTAssertEqual(repository.status, .notConnected)
        XCTAssertEqual(repository.issue, .requestFailed)
        XCTAssertEqual(service.readCallCount, 0)
    }

    func testFailedRefreshRetainsLastAvailableContextAndItsOriginalRefreshTime() async {
        let original = HealthContext(
            todaySteps: 4_200,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: 25_200,
            refreshedAt: Date(timeIntervalSince1970: 4_000)
        )
        let service = FakeHealthKitService(readResult: .success(original))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        await repository.refresh()
        service.readResult = .failure(TestHealthError.readFailed)
        await repository.refresh()

        XCTAssertEqual(repository.context, original)
        XCTAssertEqual(repository.context?.refreshedAt, original.refreshedAt)
        XCTAssertTrue(repository.isContextStale)
        XCTAssertEqual(repository.issue, .readFailed)
    }

    func testSuccessfulEmptyRefreshReplacesPreviouslyAvailableValues() async {
        let original = HealthContext(
            todaySteps: 4_200,
            todayActiveEnergyKilocalories: 310,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: nil,
            refreshedAt: Date(timeIntervalSince1970: 5_000)
        )
        let empty = HealthContext.empty(refreshedAt: Date(timeIntervalSince1970: 6_000))
        let service = FakeHealthKitService(readResult: .success(original))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        await repository.refresh()
        service.readResult = .success(empty)
        await repository.refresh()

        XCTAssertEqual(repository.context, empty)
        XCTAssertFalse(repository.isContextStale)
        XCTAssertNil(repository.issue)
    }

    func testMixedAvailableAndEmptyMetricsRemainDistinct() async {
        let mixed = HealthContext(
            todaySteps: 2_750,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: HealthWorkoutContext(
                activityName: "Walk",
                startedAt: Date(timeIntervalSince1970: 6_500),
                durationSeconds: 1_800
            ),
            lastNightSleepDurationSeconds: nil,
            refreshedAt: Date(timeIntervalSince1970: 7_000)
        )
        let service = FakeHealthKitService(readResult: .success(mixed))
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        await repository.refresh()

        XCTAssertEqual(repository.context?.todaySteps, 2_750)
        XCTAssertNil(repository.context?.todayActiveEnergyKilocalories)
        XCTAssertEqual(repository.context?.mostRecentWorkout?.activityName, "Walk")
        XCTAssertNil(repository.context?.lastNightSleepDurationSeconds)
    }

    func testOverlappingRefreshIsRejectedWhileFirstReadIsInFlight() async {
        let service = SuspendedHealthKitService()
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore(hasCompletedSetup: true)
        )

        let firstRefresh = Task { await repository.refresh() }
        await service.waitUntilReadStarts()
        await repository.refresh()

        XCTAssertEqual(service.readCallCount, 1)

        let context = HealthContext.empty(refreshedAt: Date(timeIntervalSince1970: 8_000))
        service.completeRead(with: .success(context))
        await firstRefresh.value

        XCTAssertEqual(repository.context, context)
        XCTAssertEqual(service.readCallCount, 1)
    }

    func testConnectAndRefreshAreRejectedWhileAuthorizationRequestIsInFlight() async {
        let service = SuspendedAuthorizationHealthKitService()
        let repository = HealthConnectionRepository(
            service: service,
            preferenceStore: InMemoryHealthPreferenceStore()
        )

        let firstConnect = Task { await repository.connect() }
        await service.waitUntilAuthorizationStarts()
        await repository.connect()
        await repository.refresh()

        XCTAssertEqual(service.authorizationCallCount, 1)
        XCTAssertEqual(service.readCallCount, 0)

        service.completeAuthorization(with: .completed)
        await firstConnect.value

        XCTAssertEqual(service.authorizationCallCount, 1)
        XCTAssertEqual(service.readCallCount, 1)
    }

    func testTodayStepsSnapshotShowsOnlyCurrentLocalDaySamples() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3_600)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23))!

        let oldContext = HealthContext(
            todaySteps: 8_120,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: nil,
            refreshedAt: yesterday
        )
        XCTAssertEqual(
            TodayStepsSnapshot(context: oldContext, isStale: false, on: today, calendar: calendar),
            .needsRefresh
        )

        let currentContext = HealthContext(
            todaySteps: 4_321,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: nil,
            refreshedAt: today
        )
        XCTAssertEqual(
            TodayStepsSnapshot(context: currentContext, isStale: true, on: today, calendar: calendar),
            .count(4_321, refreshedAt: today, isStale: true)
        )
    }

    func testTodayStepsSnapshotDoesNotInventZeroForMissingOrInvalidSamples() {
        let date = Date(timeIntervalSince1970: 8_000)
        let calendar = Calendar(identifier: .gregorian)

        XCTAssertEqual(
            TodayStepsSnapshot(context: nil, isStale: false, on: date, calendar: calendar),
            .needsRefresh
        )

        for steps in [Double.nan, -Double.infinity, -1] {
            let context = HealthContext(
                todaySteps: steps,
                todayActiveEnergyKilocalories: nil,
                mostRecentWorkout: nil,
                lastNightSleepDurationSeconds: nil,
                refreshedAt: date
            )
            XCTAssertEqual(
                TodayStepsSnapshot(context: context, isStale: false, on: date, calendar: calendar),
                .noData
            )
        }

        let empty = HealthContext.empty(refreshedAt: date)
        XCTAssertEqual(
            TodayStepsSnapshot(context: empty, isStale: false, on: date, calendar: calendar),
            .noData
        )

        let zero = HealthContext(
            todaySteps: 0,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: nil,
            refreshedAt: date
        )
        XCTAssertEqual(
            TodayStepsSnapshot(context: zero, isStale: false, on: date, calendar: calendar),
            .count(0, refreshedAt: date, isStale: false)
        )
    }

    func testImportedBodyWeightAcceptsOnlyLocallyStorableReadings() {
        let date = Date(timeIntervalSince1970: 8_100)
        XCTAssertEqual(ImportedBodyWeight(kilograms: 72.4, recordedAt: date)?.recordedAt, date)
        XCTAssertNil(ImportedBodyWeight(kilograms: .nan, recordedAt: date))
        XCTAssertNil(ImportedBodyWeight(kilograms: 0.4, recordedAt: date))
        XCTAssertNil(ImportedBodyWeight(kilograms: 1_001, recordedAt: date))
    }
}

@MainActor
private final class FakeHealthKitService: HealthKitServicing {
    let isHealthDataAvailable: Bool
    var authorizationOutcome: HealthAuthorizationOutcome
    var readResult: Result<HealthContext, Error>
    private(set) var requestedScopes: [HealthAuthorizationScope] = []
    private(set) var authorizationCallCount = 0
    private(set) var readCallCount = 0

    init(
        isAvailable: Bool = true,
        authorizationOutcome: HealthAuthorizationOutcome = .completed,
        readResult: Result<HealthContext, Error> = .success(.empty(refreshedAt: .distantPast))
    ) {
        isHealthDataAvailable = isAvailable
        self.authorizationOutcome = authorizationOutcome
        self.readResult = readResult
    }

    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome {
        authorizationCallCount += 1
        requestedScopes.append(scope)
        return authorizationOutcome
    }

    func readContext(at date: Date) async throws -> HealthContext {
        readCallCount += 1
        return try readResult.get()
    }
}

private final class InMemoryHealthPreferenceStore: HealthConnectionPreferencePersisting {
    private var value: Bool

    init(hasCompletedSetup: Bool = false) {
        value = hasCompletedSetup
    }

    var hasCompletedHealthSetup: Bool { value }

    func setHasCompletedHealthSetup(_ value: Bool) {
        self.value = value
    }
}

@MainActor
private final class SuspendedHealthKitService: HealthKitServicing {
    let isHealthDataAvailable = true
    private(set) var readCallCount = 0
    private var readContinuation: CheckedContinuation<HealthContext, Error>?
    private var readStartedContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedRead = false

    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome {
        .completed
    }

    func readContext(at date: Date) async throws -> HealthContext {
        readCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
            hasStartedRead = true
            readStartedContinuation?.resume()
            readStartedContinuation = nil
        }
    }

    func waitUntilReadStarts() async {
        guard !hasStartedRead else { return }
        await withCheckedContinuation { continuation in
            readStartedContinuation = continuation
        }
    }

    func completeRead(with result: Result<HealthContext, Error>) {
        let continuation = readContinuation
        readContinuation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class SuspendedAuthorizationHealthKitService: HealthKitServicing {
    let isHealthDataAvailable = true
    private(set) var authorizationCallCount = 0
    private(set) var readCallCount = 0
    private var authorizationContinuation: CheckedContinuation<HealthAuthorizationOutcome, Never>?
    private var authorizationStartedContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedAuthorization = false

    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome {
        authorizationCallCount += 1
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            hasStartedAuthorization = true
            authorizationStartedContinuation?.resume()
            authorizationStartedContinuation = nil
        }
    }

    func waitUntilAuthorizationStarts() async {
        guard !hasStartedAuthorization else { return }
        await withCheckedContinuation { continuation in
            authorizationStartedContinuation = continuation
        }
    }

    func completeAuthorization(with outcome: HealthAuthorizationOutcome) {
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume(returning: outcome)
    }

    func readContext(at date: Date) async throws -> HealthContext {
        readCallCount += 1
        return .empty(refreshedAt: date)
    }
}

private enum TestHealthError: Error {
    case readFailed
}
