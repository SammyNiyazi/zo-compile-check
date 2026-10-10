import Foundation
import Observation

struct StepsHour: Identifiable, Equatable, Sendable {
    let startedAt: Date
    let count: Int?
    var id: Date { startedAt }
}

struct StepsDayReading: Equatable, Sendable {
    let readAt: Date
    let dayStart: Date
    let totalSteps: Int?
    let distanceMeters: Double?
    let hours: [StepsHour]

    init(readAt: Date, dayStart: Date? = nil, totalSteps: Double?, distanceMeters: Double?, hours: [(Date, Double?)]) {
        self.readAt = readAt
        self.dayStart = dayStart ?? Calendar.current.startOfDay(for: readAt)
        self.totalSteps = Self.validStepCount(totalSteps)
        self.distanceMeters = distanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        var seen: Set<Date> = []
        self.hours = hours.sorted { $0.0 < $1.0 }.compactMap { start, value in
            guard start <= readAt, seen.insert(start).inserted else { return nil }
            return StepsHour(startedAt: start, count: Self.validStepCount(value))
        }
    }

    private static func validStepCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0,
              value.rounded() < Double(Int.max) else { return nil }
        return Int(value.rounded())
    }
}

@MainActor
protocol StepsHealthServicing {
    var isStepsAvailable: Bool { get }
    /// Requests only step count and walking/running distance, with no write types.
    func requestStepsAccess() async -> HealthAuthorizationOutcome
    func readStepsDay(at date: Date) async throws -> StepsDayReading
}

@MainActor
@Observable
final class StepsDayRepository {
    private(set) var status: HealthConnectionStatus
    private(set) var reading: StepsDayReading?
    private(set) var issue: HealthConnectionIssue?
    private(set) var isRefreshing = false

    private let service: any StepsHealthServicing
    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private var operationInFlight = false

    init(
        service: any StepsHealthServicing,
        defaults: UserDefaults = .standard,
        key: String = "01.steps.readAccessRequested",
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.defaults = defaults
        self.key = key
        self.now = now
        status = !service.isStepsAvailable ? .unavailable
            : defaults.bool(forKey: key) ? .connected : .notConnected
    }

    /// A completed permission sheet is not proof that read access was granted.
    func connect() async {
        guard status == .notConnected, !operationInFlight else { return }
        guard service.isStepsAvailable else { status = .unavailable; return }
        operationInFlight = true
        defer { operationInFlight = false }
        status = .connecting
        issue = nil
        switch await service.requestStepsAccess() {
        case .completed:
            defaults.set(true, forKey: key)
            status = .connected
            await read()
        case .denied:
            status = .notConnected
            issue = .denied
        case .cancelled:
            status = .notConnected
            issue = .cancelled
        case .unavailable:
            status = .unavailable
        case .failed:
            status = .notConnected
            issue = .requestFailed
        }
    }

    func refresh() async {
        guard status == .connected, !operationInFlight else { return }
        guard service.isStepsAvailable else { status = .unavailable; return }
        operationInFlight = true
        defer { operationInFlight = false }
        await read()
    }

    func currentReading(on date: Date, calendar: Calendar = .current) -> StepsDayReading? {
        guard let reading,
              reading.dayStart == calendar.startOfDay(for: date),
              calendar.isDate(reading.readAt, inSameDayAs: date) else { return nil }
        return reading
    }

    private func read() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            reading = try await service.readStepsDay(at: now())
            issue = nil
        } catch {
            // Keep prior evidence, but the view labels it stale and never carries it into tomorrow.
            issue = .readFailed
        }
    }
}
