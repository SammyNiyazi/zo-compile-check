import Foundation
import Observation

@MainActor
@Observable
final class DailyAssistantContextStore {
    private(set) var availableWorkoutMinutes: Int?
    private(set) var availableWorkoutMinutesReportedAt: Date?
    private(set) var profile = UserContextProfile()

    func setAvailableWorkoutMinutes(_ minutes: Int, at date: Date = .now) {
        guard (10 ... 240).contains(minutes), date.timeIntervalSinceReferenceDate.isFinite else { return }
        availableWorkoutMinutes = minutes
        availableWorkoutMinutesReportedAt = date
    }

    func currentAvailableWorkoutMinutes(at date: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let reportedAt = availableWorkoutMinutesReportedAt, reportedAt <= date,
              date.timeIntervalSince(reportedAt) <= 6 * 3_600,
              calendar.isDate(reportedAt, inSameDayAs: date) else { return nil }
        return availableWorkoutMinutes
    }

    func record(_ fact: UserContextFact) {
        profile.record(facts: [fact])
    }
}

@MainActor
final class LocalAssistantActionExecutor: AssistantActionExecuting {
    private let hydrationViewModel: HydrationViewModel
    private let dailyContext: DailyAssistantContextStore

    init(
        hydrationViewModel: HydrationViewModel,
        dailyContext: DailyAssistantContextStore
    ) {
        self.hydrationViewModel = hydrationViewModel
        self.dailyContext = dailyContext
    }

    func execute(_ action: AssistantAction) -> AssistantConfirmation {
        switch action {
        case let .addHydration(milliliters, _):
            guard hydrationViewModel.addWaterFromQuickAction(milliliters: milliliters) != nil else {
                return .error(hydrationViewModel.persistenceErrorMessage ?? "Water wasn't saved. Open Water and try again.")
            }
            return .success("+\(formattedLiters(milliliters)) L")
        case let .setHydration(milliliters, _):
            guard hydrationViewModel.setWater(milliliters: milliliters) else {
                return .error(hydrationViewModel.persistenceErrorMessage ?? "Water wasn't saved. Open Water and try again.")
            }
            return .success("\(formattedLiters(milliliters)) L today")
        case let .updateAvailableTime(minutes):
            guard (10 ... 240).contains(minutes) else { return .error("Use 10 to 240 minutes.") }
            dailyContext.setAvailableWorkoutMinutes(minutes)
            return .success("\(minutes) min available")
        case let .reportSleep(hours, date):
            dailyContext.record(
                UserContextFact(
                    kind: .sleepRoutine,
                    value: .number(hours, unit: "hours"),
                    learnedAt: date,
                    source: "voice"
                )
            )
            return .success("\(hours.formatted(.number.precision(.fractionLength(0 ... 1)))) h sleep")
        case let .reportSoreness(area, severity, date):
            let areaText = area ?? "unspecified area"
            dailyContext.record(
                UserContextFact(
                    kind: .limitationNote,
                    value: .text("\(severity.rawValue) soreness: \(areaText)"),
                    learnedAt: date,
                    source: "voice"
                )
            )
            return .success("Noted for today")
        case .logWorkoutSet:
            return .error("Log that from the active set for now.")
        case .skipWorkout, .startWorkout, .nextExercise, .adjustLoad,
             .extendRest, .skipExercise, .completeWorkout, .reportEnergy,
             .updateDailyContext, .askAssistant:
            return .error("That voice action isn’t active yet.")
        }
    }

    private func formattedLiters(_ milliliters: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(milliliters) / 1_000)) ?? "0.0"
    }
}
