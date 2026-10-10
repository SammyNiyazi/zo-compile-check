import Foundation

/// One short, display-only coach sentence. Emphasis marks the numbers the
/// proof sets in bold; it is styling, never an input or a tap target.
struct WorkoutCoachLine: Equatable {
    enum Part: Equatable {
        case text(String)
        case emphasis(String)
    }

    let parts: [Part]

    /// The sentence VoiceOver reads as one informational element.
    var plainText: String {
        parts.map { part -> String in
            switch part {
            case let .text(value), let .emphasis(value): return value
            }
        }.joined()
    }
}

/// Pure, local templates over acknowledged facts and existing authorities
/// (saved sets, `WorkoutSetResponse`, `WorkoutExerciseComparison`,
/// `WorkoutCompletionUpgrade`, the plan's own target). No server, no AI, and no
/// new training policy: there is no invented target, best, deload, next load or
/// "one more". Unknown, incompatible or unavailable history gets neutral copy.
struct WorkoutCoachLines {
    let localization: AppLocalization

    private var copy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    // MARK: Before a set

    /// The line under the comparison card while a set can be logged.
    func target(plan: ExercisePlan, isSwappedIn: Bool, setNumber: Int,
                comparison: WorkoutComparisonPresentation) -> WorkoutCoachLine {
        switch comparison.history {
        case .unavailable:
            return line("No history to compare right now. Log what you do today.")
        case let .none(hasUnknownDetails):
            if hasUnknownDetails {
                return line("Earlier sessions have no set details to compare.")
            }
            guard setNumber == 1, !comparison.hasTodaySets else {
                return line("No last time yet. Today sets the bar.")
            }
            return firstTime(plan: plan, isSwappedIn: isSwappedIn)
        case let .recorded(_, hasNewerUnknownDetails):
            if hasNewerUnknownDetails {
                return line("Newer sessions have no set details, so today isn't compared.")
            }
            guard let row = comparison.rows.first(where: { $0.id == setNumber }),
                  let previous = row.previous else {
                return line("Last time had no set %1$lld. Today sets the bar.", .integer(setNumber))
            }
            guard row.bar != nil else {
                return line("Last time %1$@. It isn't compared with today's target.",
                            .text(emphasis(copy.setSummary(previous))))
            }
            let target = emphasis(copy.prescription(plan.prescription))
            if previous.load.value > 0 {
                return line("Last time %1$@ × %2$@. Target today: %3$@.",
                            .text(emphasis(copy.load(previous.load))),
                            .text(emphasis(copy.performance(previous))), .text(target))
            }
            return line("Last time %1$@. Target today: %2$@.",
                        .text(emphasis(copy.performance(previous))), .text(target))
        }
    }

    /// First time ever (or a swap without history): the plan's own starting
    /// load and target, which the builder or plan already authored.
    private func firstTime(plan: ExercisePlan, isSwappedIn: Bool) -> WorkoutCoachLine {
        let load = plan.targetLoad
        guard load.value > 0, load.value.isFinite else {
            return line(isSwappedIn ? "New one for you, so start easy." : "First time with this one. Start light.")
        }
        return line(isSwappedIn ? "New one for you, so start easy: %1$@ × %2$@."
                                : "First time with this one. Start light: %1$@ × %2$@.",
                    .text(emphasis(copy.load(load))),
                    .text(emphasis(copy.prescription(plan.prescription))))
    }

    // MARK: After a confirmed save

    /// The reply after an acknowledged set. `response` is the existing factual
    /// comparison; without one the line only restates what was saved.
    func response(savedSet: CompletedSet, setNumber: Int, targetReps: RepRange,
                  response: WorkoutSetResponse?,
                  history: WorkoutComparisonPresentation.History) -> WorkoutCoachLine {
        let work = emphasis(copy.performance(savedSet))
        let load = emphasis(copy.load(savedSet.load))
        let hasLoad = savedSet.load.value > 0 && savedSet.load.value.isFinite
        guard let response, response.savedSet == savedSet,
              WorkoutComparisonPresentation.canCompareRepetitions(response.previousSet, savedSet),
              case .recorded(_, false) = history else {
            let first = setNumber == 1 && history == .none(hasUnknownDetails: false)
            if hasLoad {
                return line(first ? "%1$@ × %2$@. Your first set with this one is saved." : "%1$@ × %2$@ saved.",
                            .text(load), .text(work))
            }
            return line(first ? "%1$@. Your first set with this one is saved." : "%1$@ saved.", .text(work))
        }
        let previous = response.previousSet
        switch response.kind {
        case .upReps:
            let gain = max(0, savedSet.reps - previous.reps)
            return line("%1$@. %2$@ more than last time.", .text(work),
                        .text(emphasis(copy.quantity(gain, .reps))))
        case .up:
            return line("%1$@ × %2$@. Up from %3$@ last time.", .text(load), .text(work),
                        .text(emphasis(copy.setSummary(previous))))
        case .same:
            return hasLoad
                ? line("%1$@ × %2$@. Same as last time.", .text(load), .text(work))
                : line("%1$@. Same as last time.", .text(work))
        case .heavierIn:
            return line("%1$@ at %2$@. Heavier than last time and inside your target.",
                        .text(work), .text(load))
        case .heavierBelow:
            return line("%1$@ at %2$@. Heavier than last time. It all counts.", .text(work), .text(load))
        case .fewer:
            // Proof 42's short-of-target reply. No extra rest is added here.
            if savedSet.reps < targetReps.lowerBound - 2 {
                return line("%1$@. Some days are like that. It all counts.", .text(work))
            }
            return line("%1$@, %2$@ fewer than last time. It all counts.", .text(work),
                        .text(emphasis(copy.quantity(max(0, previous.reps - savedSet.reps), .reps))))
        case .lighter:
            return line("%1$@ × %2$@. Lighter than last time. It all counts.", .text(load), .text(work))
        }
    }

    // MARK: Between exercises

    /// The finished occurrence, judged only by the existing comparison.
    func handoff(exerciseName: String, savedSetCount: Int,
                 comparison: WorkoutExerciseComparison?) -> WorkoutCoachLine {
        let name = Self.verbatim(exerciseName)
        let sets = emphasis(copy.quantity(savedSetCount, .sets))
        guard let comparison else {
            return line("%1$@ done: %2$@ saved.", .text(name), .text(sets))
        }
        switch comparison.kind {
        case .reps:
            return line("%1$@ done: %2$@ more than last time.", .text(name),
                        .text(emphasis(copy.quantity(max(0, comparison.repsNow - comparison.repsBefore), .reps))))
        case .load:
            return line("%1$@ done: top set %2$@, up from %3$@.", .text(name),
                        .text(emphasis(copy.load(comparison.topLoadNow))),
                        .text(emphasis(copy.load(comparison.topLoadBefore))))
        case .same:
            return line("%1$@ done: matched last time.", .text(name))
        case .under, .lighter, .mixed:
            return line("%1$@ done: %2$@ saved. It all counts.", .text(name), .text(sets))
        }
    }

    // MARK: Finish

    /// At most two lines from the saved session. A next load is mentioned only
    /// when the existing completion upgrade already offers it.
    func wrapUp(completedSetCount: Int, plannedSetCount: Int, endedEarly: Bool,
                finish: WorkoutFinishComparison,
                upgrade: WorkoutCompletionUpgrade?) -> [WorkoutCoachLine] {
        let done = emphasis(String(completedSetCount))
        let planned = emphasis(String(plannedSetCount))
        var lines = [
            !endedEarly && completedSetCount >= plannedSetCount
                ? line("%1$@ of %2$@ sets. Nothing skipped.", .text(done), .text(planned))
                : line("%1$@ of %2$@ sets saved. Unlogged sets stay unlogged.", .text(done), .text(planned))
        ]
        let compared = finish.comparedCount
        if finish.upCount > 0 {
            lines.append(line("Up on %1$@ of %2$@ compared exercises.",
                              .text(emphasis(String(finish.upCount))), .text(emphasis(String(compared)))))
        } else if let upgrade {
            lines.append(line("Next time, %1$@ can step up to %2$@. Your choice is below.",
                              .text(Self.verbatim(upgrade.exerciseName)),
                              .text(emphasis(copy.load(upgrade.opportunity.suggestedLoad)))))
        } else if compared > 0, finish.levelCount == compared {
            lines.append(line("Matched last time on every compared exercise."))
        }
        return lines
    }

    // MARK: Emphasis

    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"

    private func emphasis(_ value: String) -> String {
        String(Self.open) + Self.verbatim(value) + String(Self.close)
    }

    /// Names and catalog text are inserted verbatim, minus the private markers.
    static func verbatim(_ value: String) -> String {
        value.filter { $0 != open && $0 != close }
    }

    private func line(_ key: String, _ arguments: AppLocalization.Argument...) -> WorkoutCoachLine {
        let text: String
        switch arguments.count {
        case 0: text = localization.string(key)
        case 1: text = localization.format(key, arguments[0])
        case 2: text = localization.format(key, arguments[0], arguments[1])
        default: text = localization.format(key, arguments[0], arguments[1], arguments[2])
        }
        return Self.parse(text)
    }

    /// Splits a rendered sentence into plain and emphasized parts. An unpaired
    /// marker (for example a damaged translation) degrades to plain text.
    static func parse(_ text: String) -> WorkoutCoachLine {
        var parts: [WorkoutCoachLine.Part] = []
        var buffer = ""
        var emphasized = false
        for character in text {
            if character == open || character == close {
                if !buffer.isEmpty {
                    parts.append(emphasized ? .emphasis(buffer) : .text(buffer))
                    buffer = ""
                }
                emphasized = character == open
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { parts.append(emphasized ? .emphasis(buffer) : .text(buffer)) }
        return WorkoutCoachLine(parts: parts)
    }
}
