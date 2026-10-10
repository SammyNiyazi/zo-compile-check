import Foundation

/// Round 4 phase 9a: the Live Activity's coach line, "last time" foot and gain
/// pill. Same keys and facts as the in-app coach (WorkoutCoachLines.target), so
/// the Lock Screen never says something the workout screen does not. No new
/// training rule: no "one more", only what was saved last time and the plan's target.
enum WorkoutActivityCoach {
    struct Lines: Equatable {
        var coach: String?
        var lastShort: String?
        var gain: String?
    }

    static func lines(session: WorkoutSession, phase: WorkoutActivityAttributes.ContentState.Phase,
                      localization: AppLocalization) -> Lines {
        let copy = WorkoutLocalization(localization: localization)
        var result = Lines()
        if phase != .readyToFinish, phase != .saving,
           let exercise = session.currentExercise,
           let setNumber = session.currentSetNumber {
            let plan = exercise.plan
            if plan.previousPerformance.indices.contains(setNumber - 1) {
                let previous = plan.previousPerformance[setNumber - 1]
                let target = copy.prescription(plan.prescription)
                let reps = copy.quantity(previous.reps, .reps)
                if previous.load.value > 0, previous.load.value.isFinite {
                    result.coach = localization.format("Last time %1$@ × %2$@. Target today: %3$@.",
                        .text(copy.load(previous.load)), .text(reps), .text(target))
                    result.lastShort = localization.format("Last %1$@ × %2$lld",
                        .text(number(previous.load.value, localization: localization)), .integer(previous.reps))
                } else {
                    result.coach = localization.format("Last time %1$@. Target today: %2$@.", .text(reps), .text(target))
                    result.lastShort = localization.format("Last %1$@", .text(reps))
                }
            }
        }
        if phase == .rest || phase == .paused, let gain = lastSavedGain(session: session, copy: copy, localization: localization) {
            result.gain = gain
        }
        return result
    }

    /// "+1 rep" or "+2.5 kg" for the newest saved set against the same set last time.
    static func lastSavedGain(session: WorkoutSession, copy: WorkoutLocalization, localization: AppLocalization) -> String? {
        var newest: (set: CompletedSet, index: Int, plan: ExercisePlan)?
        for exercise in session.exercises {
            for (index, set) in exercise.completedSets.enumerated() where newest == nil || set.completedAt > newest!.set.completedAt {
                newest = (set, index, exercise.plan)
            }
        }
        guard let newest, newest.plan.previousPerformance.indices.contains(newest.index),
              newest.set.durationSeconds == nil else { return nil }
        let previous = newest.plan.previousPerformance[newest.index]
        let saved = newest.set
        guard saved.load.unit == previous.load.unit else { return nil }
        if saved.load.value > previous.load.value, saved.reps >= previous.reps {
            let difference = saved.load.value - previous.load.value
            return "+" + number(difference, localization: localization) + " " + saved.load.unit.rawValue
        }
        if saved.load.value == previous.load.value, saved.reps > previous.reps {
            return "+" + copy.quantity(saved.reps - previous.reps, .reps)
        }
        return nil
    }

    private static func number(_ value: Double, localization: AppLocalization) -> String {
        var text = String((value * 100).rounded() / 100)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text.replacingOccurrences(of: ".", with: localization.locale.decimalSeparator ?? ".")
    }
}
