import Foundation

/// Presentation only. Takes typed performance, never parses localized text back
/// into workout state or treats an exercise/workout title as a catalog key.
struct WorkoutLocalization {
    let localization: AppLocalization

    /// Describe the actual proposal, including a restored older proposal,
    /// rather than replaying an obsolete fixed-rest/time claim from its text.
    func adaptationChanges(for proposal: WorkoutAdaptationProposal) -> [String] {
        let original = proposal.originalSession
        let adapted = proposal.adaptedSession
        let restRetained = adapted.exercises.allSatisfy { exercise in
            original.exercises.first(where: { $0.id == exercise.id })?.plan.restSeconds == exercise.plan.restSeconds
        }
        var changes = [
            localization.format("%1$lld to %2$lld working sets", .integer(original.totalPlannedSetCount), .integer(adapted.totalPlannedSetCount)),
            localization.string(restRetained ? "Prescribed rest retained" : "Rest adjusted")
        ]
        if let estimate = WorkoutTimeEstimator().estimate(for: adapted) {
            changes.append(localization.format("Estimated up to %1$lld minutes", .integer(estimate.maximumMinutes)))
        } else { changes.append(localization.string("Time varies")) }
        let removed = original.exercises.count - adapted.exercises.count
        if removed > 0 {
            changes.append(localization.format(removed == 1 ? "%1$lld later exercise removed" : "%1$lld later exercises removed", .integer(removed)))
        }
        return changes
    }

    enum Quantity {
        case sets, exercises, reps, seconds, minutes, sessions, weeks, days
        var keys: (one: String, other: String) {
            switch self {
            case .sets: ("%1$lld set", "%1$lld sets")
            case .exercises: ("%1$lld exercise", "%1$lld exercises")
            case .reps: ("%1$lld rep", "%1$lld reps")
            case .seconds: ("%1$lld second", "%1$lld seconds")
            case .minutes: ("%1$lld minute", "%1$lld minutes")
            case .sessions: ("%1$lld session", "%1$lld sessions")
            case .weeks: ("%1$lld week", "%1$lld weeks")
            case .days: ("%1$lld day", "%1$lld days")
            }
        }
    }

    func quantity(_ count: Int, _ kind: Quantity) -> String {
        let keys = kind.keys
        return localization.format(count == 1 ? keys.one : keys.other, .integer(count))
    }

    func performance(_ set: CompletedSet) -> String {
        let work = set.durationSeconds.map { quantity($0, .seconds) } ?? quantity(set.reps, .reps)
        return set.isPerSide == true ? localization.format("%1$@ per side", .text(work)) : work
    }

    func prescription(_ prescription: WorkingSetPrescription) -> String {
        let kind: Quantity = prescription.unit == .seconds ? .seconds : .reps
        let work = prescription.lowerBound == prescription.upperBound
            ? quantity(prescription.lowerBound, kind)
            : localization.format(prescription.unit == .seconds ? "%1$lld–%2$lld seconds" : "%1$lld–%2$lld reps",
                .integer(prescription.lowerBound), .integer(prescription.upperBound))
        return prescription.perSide ? localization.format("%1$@ per side", .text(work)) : work
    }

    /// Double's shortest round-trippable decimal preserves the actual value.
    /// Units remain the recorded kg/lb; a locale changes only the decimal glyph.
    func load(_ load: Load) -> String {
        var number = String(load.value)
        if number.hasSuffix(".0") { number.removeLast(2) }
        number = number.replacingOccurrences(of: ".", with: localization.locale.decimalSeparator ?? ".")
        return "\(number) \(load.unit.rawValue)"
    }

    func setSummary(_ set: CompletedSet) -> String { "\(load(set.load)) · \(performance(set))" }
    func setPosition(_ number: Int, of total: Int) -> String {
        localization.format("Set %1$lld of %2$lld", .integer(number), .integer(total))
    }
    func savedProgress(_ saved: Int, of planned: Int, working: Bool = false) -> String {
        localization.format(working ? "%1$lld of %2$lld working sets saved" : "%1$lld of %2$lld sets saved",
            .integer(saved), .integer(planned))
    }
    func savedSet(_ number: Int?) -> String {
        number.map { localization.format("Set %1$lld saved", .integer($0)) } ?? localization.string("Set saved")
    }
    func primaryTitle(_ action: WorkoutPrimaryAction) -> String {
        switch action {
        case let .logSet(number): localization.format("Log set %1$lld", .integer(number))
        case .rest: localization.string("Rest")
        case let .startSet(number, name): number == 1
            ? localization.format("Start %1$@", .text(name))
            : localization.format("Start set %1$lld", .integer(number))
        }
    }
    func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return quantity(remainder, .seconds) }
        if remainder == 0 { return quantity(minutes, .minutes) }
        return localization.format("%1$@, %2$@", .text(quantity(minutes, .minutes)), .text(quantity(remainder, .seconds)))
    }
    func difficulty(_ rawValue: String) -> String {
        switch rawValue.lowercased().replacingOccurrences(of: "_", with: " ") {
        case "beginner": localization.string("Beginner")
        case "intermediate": localization.string("Intermediate")
        case "advanced": localization.string("Advanced")
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    func endMessage(saved: Int, exercises: Int, planned: Int) -> String {
        guard saved > 0 else { return localization.string("Nothing is logged yet, so ending now leaves no record for today.") }
        let unlogged = max(0, planned - saved)
        let base = localization.format("Saved %1$@ across %2$@. Everything saved stays saved.",
            .text(quantity(saved, .sets)), .text(quantity(exercises, .exercises)))
        return unlogged == 0 ? base : localization.format("%1$@ Planned sets left unlogged: %2$lld.", .text(base), .integer(unlogged))
    }
    func draftPerformance(_ draft: String, isTimed: Bool, perSide: Bool) -> String {
        let work = localization.format(isTimed ? "%1$@ seconds" : "%1$@ reps", .text(draft))
        return perSide ? localization.format("%1$@ per side", .text(work)) : work
    }
    func progressionGuidance(_ plan: ExercisePlan) -> String {
        if plan.isTimed {
            return localization.format("Target: %1$@. Enter how long you actually completed. The target is not a recorded result.", .text(prescription(plan.prescription)))
        }
        let target = prescription(plan.prescription)
        return plan.targetLoad.value <= 0
            ? localization.format("Starting target: %1$@. Set a comfortable load.", .text(target))
            : localization.format("Suggested: %1$@ × %2$@. Adjust to form.", .text(load(plan.targetLoad)), .text(target))
    }
    func effortInstruction(_ guidance: SetEffortGuidance, savedReps: Int?, target: RepRange) -> String {
        if guidance.kind == .capacityAvailable, let savedReps, savedReps < target.upperBound {
            return localization.format("Keep the load. Work toward %1$@ cleanly.", .text(quantity(target.upperBound, .reps)))
        }
        return localization.string(guidance.instruction)
    }
    func savedAnnouncement(setNumber: Int, set: CompletedSet, restSeconds: Int) -> String {
        let spokenUnit = localization.string(set.load.unit == .kilograms ? "kilograms" : "pounds")
        let number = load(set.load).dropLast(set.load.unit.rawValue.count + 1)
        let work = set.durationSeconds.map { duration($0) } ?? quantity(set.reps, .reps)
        let performance = set.isPerSide == true ? localization.format("%1$@ per side", .text(work)) : work
        let base = localization.format("Set %1$lld saved. %2$@ %3$@, %4$@.", .integer(setNumber), .text(String(number)), .text(spokenUnit), .text(performance))
        return restSeconds > 0 ? localization.format("%1$@ Rest %2$@.", .text(base), .text(duration(restSeconds))) : base
    }
    func historyAnnouncement(savedSetCount: Int, plannedSetCount: Int) -> String {
        savedSetCount >= plannedSetCount
            ? localization.format("Workout saved to History. Complete, all %1$@.", .text(quantity(plannedSetCount, .sets)))
            : localization.format("Workout saved to History. Partial, %1$lld of %2$lld sets.", .integer(savedSetCount), .integer(plannedSetCount))
    }
    func gainChip(_ response: WorkoutSetResponse) -> String? {
        switch response.kind {
        case .up: "+" + load(Load(response.savedSet.load.value - response.previousSet.load.value, unit: response.savedSet.load.unit))
        case .upReps: "+" + quantity(response.savedSet.reps - response.previousSet.reps, .reps)
        default: nil
        }
    }
    func responseNote(for response: WorkoutSetResponse, targetReps: RepRange, offersNextLoadChoice: Bool) -> String {
        let saved = response.savedSet, previous = response.previousSet
        let range = prescription(WorkingSetPrescription(unit: .repetitions, lowerBound: targetReps.lowerBound, upperBound: targetReps.upperBound))
        let prior = localization.format("%1$@ × %2$@", .text(load(previous.load)), .text(performance(previous)))
        let note: String
        switch response.kind {
        case .up: note = localization.format("Up from %1$@ last time.", .text(prior))
        case .upReps: note = localization.format("%1$@ more than last time at %2$@.", .text(quantity(saved.reps - previous.reps, .reps)), .text(load(previous.load)))
        case .same: note = localization.format("Same as last time: %1$@. Solid, repeatable work.", .text(prior))
        case .heavierIn: note = localization.format("%1$@ at %2$@, inside your target of %3$@. Reps often dip for a session or two after a load step.", .text(performance(saved)), .text(load(saved.load)), .text(range))
        case .heavierBelow: note = localization.format("%1$@ at %2$@, under your target of %3$@. It's saved and it counts.", .text(performance(saved)), .text(load(saved.load)), .text(range))
        case .fewer: note = localization.format("%1$@, %2$@ fewer than last time at %3$@. Saved and counted; day-to-day variation is normal.", .text(performance(saved)), .text(quantity(previous.reps - saved.reps, .reps)), .text(load(saved.load)))
        case .lighter: note = localization.format("Lighter than last time's %1$@. Saved and counted.", .text(load(previous.load)))
        }
        return offersNextLoadChoice && response.offersNextSetLoadChoice ? localization.format("%1$@ For the next set:", .text(note)) : note
    }
    func comparisonChip(_ comparison: WorkoutExerciseComparison) -> String {
        switch comparison.kind {
        case .load: "+" + load(Load(comparison.topLoadNow.value - comparison.topLoadBefore.value, unit: comparison.topLoadNow.unit))
        case .reps: "+" + quantity(comparison.repsNow - comparison.repsBefore, .reps)
        case .under: localization.format("%1$@ under", .text(quantity(comparison.repsBefore - comparison.repsNow, .reps)))
        case .same: localization.string("Matched")
        case .lighter: localization.string("Lighter")
        case .mixed: localization.string("Mixed sets")
        }
    }
    func momentHeadline(_ moment: WorkoutSetProgressMoment) -> String {
        switch moment.kind {
        case .load: "+" + load(Load(moment.savedSet.load.value - moment.previousSet.load.value, unit: moment.savedSet.load.unit))
        case .repetitions: "+" + quantity(moment.savedSet.reps - moment.previousSet.reps, .reps)
        }
    }
    func highlight(_ items: [(exercise: WorkoutExercise, comparison: WorkoutExerciseComparison?)]) -> WorkoutSessionHighlight? {
        let compared = items.compactMap { item in item.comparison.map { (exercise: item.exercise, comparison: $0) } }
        if let up = compared.first(where: { $0.comparison.kind == .load }) {
            return WorkoutSessionHighlight(title: localization.format("%1$@ on %2$@", .text(comparisonChip(up.comparison)), .text(up.exercise.plan.name)), body: localization.format("Your heaviest compared set reached %1$@, up from %2$@. Compared: %3$@.", .text(load(up.comparison.topLoadNow)), .text(load(up.comparison.topLoadBefore)), .text(quantity(up.comparison.comparedSetCount, .sets))))
        }
        if let up = compared.first(where: { $0.comparison.kind == .reps }) {
            return WorkoutSessionHighlight(title: localization.format("%1$@ on %2$@", .text(comparisonChip(up.comparison)), .text(up.exercise.plan.name)), body: localization.format("More reps across %1$@ compared, with each set's load unchanged.", .text(quantity(up.comparison.comparedSetCount, .sets))))
        }
        if let lower = compared.first(where: { $0.comparison.kind == .under || $0.comparison.kind == .lighter }) {
            let detail = lower.comparison.kind == .under
                ? localization.format("%1$@ came in %2$@ last time across %3$@ compared.", .text(lower.exercise.plan.name), .text(comparisonChip(lower.comparison)), .text(quantity(lower.comparison.comparedSetCount, .sets)))
                : localization.format("%1$@ was lighter than last time.", .text(lower.exercise.plan.name))
            return WorkoutSessionHighlight(title: localization.string("Saved as logged"), body: localization.format("%1$@ One session isn't a trend, and nothing resets.", .text(detail)))
        }
        guard !compared.isEmpty else { return nil }
        return WorkoutSessionHighlight(title: localization.string(compared.contains { $0.comparison.kind == .mixed } ? "Saved as logged" : "Matched last time"), body: localization.string(compared.contains { $0.comparison.kind == .mixed } ? "Your sets varied from last time. The set-by-set results are below; nothing resets." : "Every compared set equals last time. That consistency is what the next step is built on."))
    }

    func progressionReason(for opportunity: WorkoutProgressionOpportunity, previousPerformance: PreviousExercisePerformanceState, targetReps: RepRange) -> String? {
        // The existing copy rule remains the authority for whether evidence exists.
        guard WorkoutProgressionOfferCopy.reason(for: opportunity, previousPerformance: previousPerformance, targetReps: targetReps) != nil,
              case let .recorded(performance) = previousPerformance,
              let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty }) else { return nil }
        let range = prescription(WorkingSetPrescription(unit: .repetitions, lowerBound: targetReps.lowerBound, upperBound: targetReps.upperBound))
        return localization.format("Last time you reached %1$@ on all %2$@ at %3$@, the top of your target of %4$@.", .text(quantity(targetReps.upperBound, .reps)), .text(quantity(occurrence.completedSets.count, .sets)), .text(load(opportunity.previousLoad)), .text(range))
    }

}
