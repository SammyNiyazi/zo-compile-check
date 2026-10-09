import Foundation
import WidgetKit

struct DailyWidgetInputs: Equatable {
    let steps: StepsDayReading?
    let stepsStatus: HealthConnectionStatus
    let stepsFailed: Bool
    let health: HealthContext?
    let healthStatus: HealthConnectionStatus
    let healthIsStale: Bool
    let meals: [NutritionEntry]
    let nutritionAvailable: Bool
    let water: HydrationState
    let waterDayStart: Date
    let hydrationAvailable: Bool
    var latestWalk: DailyWidgetSnapshot.Walk? = nil
    var goals: DailyGoals? = nil
    var accent: AccentPreference = .yellow
    var language: AppLanguage? = nil
    var designTheme: ZOTheme? = nil

    func usingLanguage(_ language: AppLanguage) -> Self {
        var copy = self
        copy.language = language
        return copy
    }

    func snapshot(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> DailyWidgetSnapshot {
        var snapshot = DailyWidgetProjection.make(
            at: date, calendar: calendar, steps: steps, stepsStatus: stepsStatus, stepsFailed: stepsFailed,
            health: health, healthStatus: healthStatus, healthIsStale: healthIsStale,
            meals: meals, nutritionAvailable: nutritionAvailable, water: water,
            waterDayStart: waterDayStart, hydrationAvailable: hydrationAvailable, latestWalk: latestWalk, goals: goals, accent: accent, language: language
        )
        if let designTheme { snapshot = snapshot.usingDesignTheme(designTheme) }
        return snapshot
    }
}

enum DailyWidgetProjection {
    typealias Metric = DailyWidgetSnapshot.Metric

    static func latestSavedWalk(from records: [OutdoorActivityRecord], at date: Date) -> DailyWidgetSnapshot.Walk? {
        guard let record = records.filter({ $0.kind == .walk && $0.isValid && $0.finishedAt <= date && $0.startedAt <= $0.finishedAt })
            .max(by: { $0.finishedAt < $1.finishedAt }) else { return nil }
        let result = DailyWidgetSnapshot.Walk(finishedAt: record.finishedAt, activeSeconds: record.confirmedActiveSeconds,
            distanceMeters: record.recordedDistanceMeters, distanceIncomplete: record.hasMissingLocationCoverage)
        return result.isValid(at: date) ? result : nil
    }

    static func make(
        at date: Date, calendar: Calendar = .autoupdatingCurrent,
        steps: StepsDayReading?, stepsStatus: HealthConnectionStatus, stepsFailed: Bool,
        health: HealthContext?, healthStatus: HealthConnectionStatus, healthIsStale: Bool,
        meals: [NutritionEntry], nutritionAvailable: Bool,
        water: HydrationState, waterDayStart: Date, hydrationAvailable: Bool,
        latestWalk: DailyWidgetSnapshot.Walk? = nil, goals: DailyGoals? = nil, accent: AccentPreference = .yellow,
        language: AppLanguage? = nil
    ) -> DailyWidgetSnapshot {
        let start = calendar.startOfDay(for: date)
        let healthIsCurrent = health.map {
            $0.dayStart == start && $0.refreshedAt >= start && $0.refreshedAt <= date
        } ?? false
        let healthMissing = missingHealth(status: healthStatus)
        let burned: Metric
        if healthStatus == .connected, healthIsCurrent, let health {
            burned = .reading(health.todayActiveEnergyKilocalories, at: health.refreshedAt, isStale: healthIsStale)
        } else {
            burned = healthMissing
        }

        // Prefer the freshest real query. A Steps permission request is not proof of readable data.
        var stepCandidates: [(Date, Metric)] = []
        if stepsStatus == .connected, let steps, steps.dayStart == start,
           steps.readAt >= start, steps.readAt <= date {
            stepCandidates.append((steps.readAt, .reading(steps.totalSteps.map(Double.init), at: steps.readAt, isStale: stepsFailed)))
        }
        if healthStatus == .connected, healthIsCurrent, let health {
            let count = health.todaySteps.flatMap { raw in
                raw.isFinite && raw >= 0 && raw < Double(Int.max) ? raw.rounded() : nil
            }
            stepCandidates.append((health.refreshedAt, .reading(count, at: health.refreshedAt, isStale: healthIsStale)))
        }
        let stepMetric = stepCandidates.max(by: { $0.0 < $1.0 })?.1
            ?? missingHealth(status: stepsStatus == .connected ? stepsStatus : healthStatus)

        let todaysMeals = meals.filter { calendar.isDate($0.loggedAt, inSameDayAs: date) }
        let eaten: Metric
        if nutritionAvailable {
            var total = 0
            var valid = true
            for entry in todaysMeals {
                let sum = total.addingReportingOverflow(entry.calories)
                guard entry.calories >= 0, !sum.overflow else { valid = false; break }
                total = sum.partialValue
            }
            eaten = valid ? .reading(Double(total), at: date) : .missing(.unavailable)
        } else {
            eaten = .missing(.unavailable)
        }
        let waterMetric: Metric = !hydrationAvailable ? .missing(.unavailable)
            : waterDayStart == start ? .reading(Double(water.currentMilliliters), at: date)
            : .missing(.needsRefresh)

        var snapshot = DailyWidgetSnapshot(
            generatedAt: date, dayStart: start, steps: stepMetric,
            eatenKilocalories: eaten, burnedKilocalories: burned, waterMilliliters: waterMetric,
            waterGoalMilliliters: hydrationAvailable ? water.goalMilliliters : nil,
            latestWalk: latestWalk.flatMap { $0.isValid(at: date) ? $0 : nil },
            stepGoal: goals?.isValid == true ? goals?.steps : nil,
            foodGoalKilocalories: goals?.isValid == true ? goals?.foodKilocalories : nil,
            accent: accent
        )
        if let language { snapshot = snapshot.usingLanguage(language) }
        return snapshot
    }

    private static func missingHealth(status: HealthConnectionStatus) -> Metric {
        switch status {
        case .notConnected, .connecting: .missing(.needsConnection)
        case .connected: .missing(.needsRefresh)
        case .unavailable: .missing(.unavailable)
        }
    }
}

/// Publishing never prompts for permissions and never changes canonical user data.
@MainActor
final class DailyWidgetPublisher {
    private let store: any DailyWidgetSnapshotPersisting
    private let reload: () -> Void
    private(set) var lastError: Error?

    init(store: any DailyWidgetSnapshotPersisting = FileDailyWidgetSnapshotStore(), reload: @escaping () -> Void = {
        for kind in DailyWidgetSnapshot.Kind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue) }
    }) {
        self.store = store
        self.reload = reload
    }

    @discardableResult
    func publish(_ snapshot: DailyWidgetSnapshot) -> Bool {
        guard store.isAvailable else {
            lastError = DailyWidgetSnapshotError.sharedContainerUnavailable
            return false
        }
        do {
            // This cache is rebuildable. Corrupt cache bytes must not prevent a
            // new verified projection from replacing them; canonical stores are untouched.
            if (try? store.load()) == snapshot { lastError = nil; return true }
            try store.save(snapshot)
            guard try store.load() == snapshot else { throw DailyWidgetSnapshotError.verificationFailed }
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error
            return false
        }
    }
}
