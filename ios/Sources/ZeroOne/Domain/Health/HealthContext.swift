import Foundation
import Observation

enum HealthReadDataType: String, CaseIterable, Codable, Hashable, Sendable {
    case stepCount
    case activeEnergy
    case workouts
    case sleepAnalysis
    case bodyMass
    case height
    case distanceWalkingRunning

    var title: String {
        switch self {
        case .stepCount: "Steps"
        case .activeEnergy: "Active energy"
        case .workouts: "Apple Health workouts"
        case .sleepAnalysis: "Sleep analysis"
        case .bodyMass: "Body weight"
        case .height: "Height"
        case .distanceWalkingRunning: "Walking and running distance"
        }
    }

    var benefit: String {
        switch self {
        case .stepCount: "Understand daily movement"
        case .activeEnergy: "Understand activity volume"
        case .workouts: "Keep external activity visible"
        case .sleepAnalysis: "Show available sleep context later"
        case .bodyMass: "Fill body weight only when you choose to import it"
        case .height: "Fill your height during setup"
        case .distanceWalkingRunning: "Show distance alongside your daily steps"
        }
    }
}

struct HealthAuthorizationScope: Equatable, Sendable {
    let readTypes: Set<HealthReadDataType>
    let writeTypes: Set<HealthReadDataType>

    static let zeroOneFoundation = HealthAuthorizationScope(
        readTypes: Set(HealthReadDataType.allCases),
        writeTypes: []
    )
}

struct HealthWorkoutContext: Equatable, Sendable {
    let activityName: String
    let startedAt: Date
    let durationSeconds: TimeInterval
}

struct HealthContext: Equatable, Sendable {
    let todaySteps: Double?
    let todayActiveEnergyKilocalories: Double?
    let mostRecentWorkout: HealthWorkoutContext?
    let lastNightSleepDurationSeconds: TimeInterval?
    let refreshedAt: Date
    let dayStart: Date

    init(todaySteps: Double?, todayActiveEnergyKilocalories: Double?, mostRecentWorkout: HealthWorkoutContext?,
         lastNightSleepDurationSeconds: TimeInterval?, refreshedAt: Date, dayStart: Date? = nil) {
        self.todaySteps = todaySteps
        self.todayActiveEnergyKilocalories = todayActiveEnergyKilocalories
        self.mostRecentWorkout = mostRecentWorkout
        self.lastNightSleepDurationSeconds = lastNightSleepDurationSeconds
        self.refreshedAt = refreshedAt
        self.dayStart = dayStart ?? Calendar.current.startOfDay(for: refreshedAt)
    }

    static func empty(refreshedAt: Date) -> HealthContext {
        HealthContext(
            todaySteps: nil,
            todayActiveEnergyKilocalories: nil,
            mostRecentWorkout: nil,
            lastNightSleepDurationSeconds: nil,
            refreshedAt: refreshedAt
        )
    }
}

enum TodayStepsSnapshot: Equatable, Sendable {
    case needsRefresh
    case noData
    case count(Int, refreshedAt: Date, isStale: Bool)

    init(context: HealthContext?, isStale: Bool, on date: Date, calendar: Calendar) {
        guard let context,
              calendar.isDate(context.refreshedAt, inSameDayAs: date) else {
            self = .needsRefresh
            return
        }

        guard let steps = context.todaySteps,
              steps.isFinite,
              steps >= 0,
              steps < Double(Int.max) else {
            self = .noData
            return
        }

        self = .count(Int(steps.rounded()), refreshedAt: context.refreshedAt, isStale: isStale)
    }
}

enum HealthAuthorizationOutcome: Equatable, Sendable {
    case completed
    case denied
    case cancelled
    case unavailable
    case failed
}

enum HealthConnectionIssue: Equatable, Sendable {
    case denied
    case cancelled
    case requestFailed
    case readFailed

    var message: String {
        switch self {
        case .denied:
            "The Apple Health access request did not complete. You can retry when you are ready."
        case .cancelled:
            "Connection was cancelled. 01 will not ask again unless you choose Connect."
        case .requestFailed:
            "Apple Health access could not be requested. You can retry while workout logging remains available offline."
        case .readFailed:
            "Apple Health data could not be refreshed. Retry when convenient; workout logging remains available offline."
        }
    }
}

enum HealthConnectionStatus: Equatable, Sendable {
    case notConnected
    case connecting
    case connected
    case unavailable

    /// A completed request is not evidence that Apple granted every read permission.
    var needsSetup: Bool {
        self == .notConnected || self == .connecting
    }
}

@MainActor
protocol HealthKitServicing {
    var isHealthDataAvailable: Bool { get }
    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome
    func readContext(at date: Date) async throws -> HealthContext
}

struct ImportedBodyWeight: Equatable, Sendable {
    let kilograms: Double
    let recordedAt: Date

    init?(kilograms: Double, recordedAt: Date) {
        guard kilograms.isFinite, (0.5 ... 1_000).contains(kilograms) else { return nil }
        self.kilograms = kilograms
        self.recordedAt = recordedAt
    }
}

enum BodyWeightImportError: Error {
    case unavailable
    case missingType
    case invalidSample
}

@MainActor
protocol BodyWeightImporting {
    var isAvailable: Bool { get }
    /// Read access can be declined without HealthKit revealing that decision.
    /// Nil means no readable sample; it must not be presented as a denial.
    func latestReadingAfterAuthorization() async throws -> ImportedBodyWeight?
}

protocol HealthConnectionPreferencePersisting {
    var hasCompletedHealthSetup: Bool { get }
    func setHasCompletedHealthSetup(_ value: Bool)
}

struct UserDefaultsHealthConnectionPreferenceStore: HealthConnectionPreferencePersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.health.setupCompleted") {
        self.defaults = defaults
        self.key = key
    }

    var hasCompletedHealthSetup: Bool {
        defaults.bool(forKey: key)
    }

    func setHasCompletedHealthSetup(_ value: Bool) {
        defaults.set(value, forKey: key)
    }
}

@MainActor
@Observable
final class HealthConnectionRepository {
    private let service: any HealthKitServicing
    private let preferenceStore: any HealthConnectionPreferencePersisting
    private let now: () -> Date

    private(set) var status: HealthConnectionStatus
    private(set) var context: HealthContext?
    private(set) var issue: HealthConnectionIssue?
    private(set) var isRefreshing = false
    private(set) var isContextStale = false
    private var isOperationInFlight = false

    init(
        service: any HealthKitServicing,
        preferenceStore: any HealthConnectionPreferencePersisting = UserDefaultsHealthConnectionPreferenceStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.preferenceStore = preferenceStore
        self.now = now

        if !service.isHealthDataAvailable {
            status = .unavailable
        } else if preferenceStore.hasCompletedHealthSetup {
            status = .connected
        } else {
            status = .notConnected
        }
    }

    var hasCompletedHealthSetup: Bool {
        preferenceStore.hasCompletedHealthSetup
    }

    func connect() async {
        guard service.isHealthDataAvailable else {
            status = .unavailable
            return
        }
        // Explicit setup may request the current scope after an older, narrower
        // setup. Completion alone does not identify the types previously asked.
        guard !isOperationInFlight else { return }

        isOperationInFlight = true
        defer { isOperationInFlight = false }
        status = .connecting
        issue = nil
        let outcome = await service.requestAuthorization(for: .zeroOneFoundation)

        switch outcome {
        case .completed:
            preferenceStore.setHasCompletedHealthSetup(true)
            status = .connected
            await performRefresh()
        case .denied:
            preferenceStore.setHasCompletedHealthSetup(false)
            status = .notConnected
            issue = .denied
        case .cancelled:
            preferenceStore.setHasCompletedHealthSetup(false)
            status = .notConnected
            issue = .cancelled
        case .unavailable:
            preferenceStore.setHasCompletedHealthSetup(false)
            status = .unavailable
        case .failed:
            preferenceStore.setHasCompletedHealthSetup(false)
            status = .notConnected
            issue = .requestFailed
        }
    }

    func refreshIfConnected() async {
        guard status == .connected else { return }
        await refresh()
    }

    func refresh() async {
        guard service.isHealthDataAvailable,
              status == .connected,
              !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        await performRefresh()
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            context = try await service.readContext(at: now())
            isContextStale = false
            issue = nil
        } catch {
            isContextStale = context != nil
            issue = .readFailed
        }
    }
}
