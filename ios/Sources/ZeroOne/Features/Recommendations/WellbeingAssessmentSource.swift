import Foundation
import Observation

/// App-owned observation cache, with unknown coverage while a read is in flight.
@MainActor @Observable
final class WellbeingOutdoorEvidence {
    private var observation: OutdoorRecommendationObservation?
    var records: [OutdoorActivityRecord]? { observation?.records }
    @ObservationIgnored private var refreshID = UUID()

    func refresh(using repository: any OutdoorRecommendationLoading) async {
        let requestID = UUID()
        refreshID = requestID
        observation = nil
        let loaded = try? await repository.loadRecommendationObservation()
        guard refreshID == requestID else { return }
        observation = loaded
    }

    /// A missing/in-flight observation cannot remove a recovery hold. A changed
    /// file requires a fresh async observation before an increase is considered.
    func confirmsCurrentRecords(using repository: OutdoorActivityRepository) -> Bool {
        guard let observation else { return false }
        guard repository.confirmsRecommendationSource(observation.source) else {
            self.observation = nil
            return false
        }
        return true
    }
}

/// The UI and write-boundary policy read the same live, acknowledged sources.
/// No captured SwiftUI view or yesterday's assessment becomes authority.
@MainActor
enum WellbeingAssessmentSource {
    /// Shared synchronous increase authority. A rendered assessment is never
    /// permission. Every required local source is freshly verified here.
    static func permitsAutomaticProgression(history: WorkoutHistoryRepository, recovery: WellbeingCheckInRepository,
                       nutrition: NutritionRepository, goals: DailyGoalsRepository,
                       water: HydrationViewModel, health: HealthConnectionRepository,
                       outdoor: WellbeingOutdoorEvidence, outdoorRepository: OutdoorActivityRepository,
                       at now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        recovery.reload()
        goals.reload()
        water.refreshForCurrentDay()
        guard (try? history.confirmedEntries()) != nil, recovery.isAvailable, goals.isAvailable,
              (try? nutrition.readForImport()) != nil,
              outdoor.confirmsCurrentRecords(using: outdoorRepository) else { return false }
        return !assess(history: history, recovery: recovery, nutrition: nutrition, goals: goals,
            water: water, health: health, outdoor: outdoor, at: now, calendar: calendar).holdsAutomaticProgression
    }

    static func assess(history: WorkoutHistoryRepository, recovery: WellbeingCheckInRepository,
                       nutrition: NutritionRepository, goals: DailyGoalsRepository,
                       water: HydrationViewModel, health: HealthConnectionRepository,
                       outdoor: WellbeingOutdoorEvidence,
                       at now: Date = .now, calendar: Calendar = .current) -> WellbeingAssessment {
        let sleep: RecoverySleepObservation?
        if health.status == .connected, !health.isContextStale,
           let context = health.context, let seconds = context.lastNightSleepDurationSeconds {
            sleep = .init(hours: seconds / 3_600, refreshedAt: context.refreshedAt, day: context.dayStart)
        } else { sleep = nil }
        return WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: history.availability == .available ? history.entries : nil,
            outdoorHistory: outdoor.records,
            recoveryCheckIns: recovery.isAvailable ? recovery.snapshot.recovery : [],
            meals: nutrition.availability == .available ? nutrition.entries : nil,
            nutritionReviews: recovery.isAvailable ? recovery.snapshot.nutrition : [],
            chosenFoodGoal: goals.isAvailable ? goals.value.foodKilocalories : nil,
            hydration: water.isPersistenceAvailable ? .init(loggedMilliliters: water.state.currentMilliliters,
                storedGoalMilliliters: water.state.goalMilliliters, day: water.stateDayStart) : nil,
            healthSleep: sleep, nutritionGuidance: recovery.isAvailable ? recovery.snapshot.guidanceContext : nil,
            recoverySourceAvailable: recovery.isAvailable))
    }
}
