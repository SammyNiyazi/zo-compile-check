import Foundation

struct LocalAssistantActionValidator: AssistantActionValidating {
    func validate(_ action: AssistantAction) -> AssistantActionValidation {
        switch action {
        case let .addHydration(milliliters, _), let .setHydration(milliliters, _):
            guard 1 ... 5_000 ~= milliliters else {
                return .invalid(.error("That water amount looks wrong."))
            }
        case let .logWorkoutSet(load, reps, rir):
            guard 0 ... 1_000 ~= load.value,
                  1 ... 100 ~= reps,
                  rir.map({ 0 ... 5 ~= $0 }) ?? true else {
                return .invalid(.error("Check the set details."))
            }
        case let .updateAvailableTime(minutes):
            guard 10 ... 240 ~= minutes else {
                return .invalid(.error("Use 10 to 240 minutes."))
            }
        case let .adjustLoad(amount, _):
            guard -100 ... 100 ~= amount else {
                return .invalid(.error("That load change looks wrong."))
            }
        case let .extendRest(seconds):
            guard 5 ... 600 ~= seconds else {
                return .invalid(.error("Use 5 seconds to 10 minutes."))
            }
        case let .reportSleep(hours, _):
            guard 0 ... 24 ~= hours else {
                return .invalid(.error("Check the sleep duration."))
            }
        case .updateDailyContext, .skipWorkout, .startWorkout, .nextExercise,
             .skipExercise, .completeWorkout, .reportEnergy, .reportSoreness,
             .askAssistant:
            break
        }

        return .valid
    }
}
