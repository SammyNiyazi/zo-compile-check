import Foundation

/// Pure saved-record display facts. No persistence, comparison, progression,
/// elapsed-time estimate or share eligibility decision belongs here.
struct WorkoutHistoryFactsPresentation {
    struct Week: Identifiable {
        let id: String
        let interval: DateInterval?
        let entries: [WorkoutHistoryDisplayItem]
    }

    struct MonthSummary {
        let interval: DateInterval
        let workoutCount: Int
        let savedSetCount: Int?
    }

    static func monthSummary(_ entries: [WorkoutHistoryDisplayItem], now: Date, calendar: Calendar) -> MonthSummary? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
        let records = entries.filter { $0.completedAt >= interval.start && $0.completedAt < interval.end }
        var total = 0
        for record in records {
            let result = total.addingReportingOverflow(record.completedSetCount)
            guard record.completedSetCount >= 0, !result.overflow else {
                return MonthSummary(interval: interval, workoutCount: records.count, savedSetCount: nil)
            }
            total = result.partialValue
        }
        return MonthSummary(interval: interval, workoutCount: records.count, savedSetCount: total)
    }

    func monthTitle(_ summary: MonthSummary, calendar: Calendar) -> String {
        summary.interval.start.formatted(Date.FormatStyle(date: .omitted, time: .omitted,
            locale: localization.locale, calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())
    }

    let localization: AppLocalization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    static func weeks(_ entries: [WorkoutHistoryDisplayItem], calendar: Calendar) -> [Week] {
        weeks(entries) { date in
            guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: date)
        }
    }

    /// An unresolvable grouping date still retains the saved record and route.
    /// The resolver also permits deterministic Calendar-failure coverage.
    static func weeks(_ entries: [WorkoutHistoryDisplayItem], intervalForDate: (Date) -> DateInterval?) -> [Week] {
        let sorted = entries.sorted {
            let lhsValid = $0.completedAt.timeIntervalSinceReferenceDate.isFinite
            let rhsValid = $1.completedAt.timeIntervalSinceReferenceDate.isFinite
            if lhsValid != rhsValid { return lhsValid }
            if !lhsValid { return $0.sourceEntry.id.uuidString < $1.sourceEntry.id.uuidString }
            return WorkoutHistoryEntry.newestFirst($0.sourceEntry, $1.sourceEntry)
        }
        var groups: [Week] = []
        for entry in sorted {
            guard let interval = intervalForDate(entry.completedAt) else {
                groups.append(Week(id: "ungrouped-\(entry.sourceEntry.id)", interval: nil, entries: [entry]))
                continue
            }
            let id = "week-\(interval.start.timeIntervalSinceReferenceDate)"
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index] = Week(id: id, interval: interval, entries: groups[index].entries + [entry])
            } else {
                groups.append(Week(id: id, interval: interval, entries: [entry]))
            }
        }
        return groups
    }

    func weekTitle(_ week: Week, now: Date, calendar: Calendar) -> String {
        guard let interval = week.interval else { return localization.string("Saved workout") }
        if calendar.dateInterval(of: .weekOfYear, for: now)?.start == interval.start {
            return localization.string("This week")
        }
        // The end of DateInterval is exclusive. Calendar arithmetic respects DST.
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted,
                                     locale: localization.locale, calendar: calendar, timeZone: calendar.timeZone)
        return localization.format("%1$@ to %2$@", .text(interval.start.formatted(style)), .text(end.formatted(style)))
    }

    func date(_ value: Date, calendar: Calendar, wide: Bool = false) -> String {
        guard value.timeIntervalSinceReferenceDate.isFinite else { return localization.string("Date unavailable") }
        let style = Date.FormatStyle(date: wide ? .complete : .abbreviated, time: .shortened,
                                     locale: localization.locale, calendar: calendar, timeZone: calendar.timeZone)
        return value.formatted(style)
    }

    func status(_ value: WorkoutHistoryPresentation.Status) -> String {
        localization.string(value == .complete ? "Complete" : "Partial")
    }

    func savedCounts(_ presentation: WorkoutHistoryPresentation) -> String {
        workoutCopy.savedProgress(presentation.savedSetCount, of: presentation.plannedSetCount)
    }

    func recordSummary(_ presentation: WorkoutHistoryPresentation) -> String {
        let counts = savedCounts(presentation)
        let key: String
        switch (presentation.status == .partial, presentation.wasAdapted) {
        case (false, false): key = "%1$@."
        case (true, false): key = "%1$@. Ended early; every logged set is kept."
        case (false, true): key = "%1$@. Plan adapted for this session."
        case (true, true): key = "%1$@. Ended early; every logged set is kept. Plan adapted for this session."
        }
        return localization.format(key, .text(counts))
    }

    func rowSummary(_ presentation: WorkoutHistoryPresentation) -> String {
        localization.format(presentation.wasAdapted ? "%1$@ · %2$@ · Adapted" : "%1$@ · %2$@",
                            .text(status(presentation.status)), .text(savedCounts(presentation)))
    }

    func warmUp(_ outcome: WorkoutHistoryPresentation.WarmUpOutcome) -> String {
        let key: String
        switch outcome {
        case .completed: key = "Warm-up completed"
        case .partial: key = "Warm-up partly completed"
        case .skipped: key = "Warm-up skipped"
        case .notRecorded: key = "Warm-up not recorded"
        }
        return localization.string(key)
    }

    func exerciseName(_ id: ExerciseID) -> String {
        // Catalog metadata remains verbatim, even if it resembles a static key.
        ExerciseLibrary.exercise(id: id)?.name
            ?? MoveKitExerciseCatalog.match(for: id)?.exercise.name
            ?? localization.string("Recorded exercise")
    }

    func exerciseCounts(_ exercise: WorkoutHistoryPresentation.ExerciseRow) -> String {
        if let planned = exercise.plannedCount {
            return workoutCopy.savedProgress(exercise.savedCount, of: planned)
        }
        return localization.format("%1$@ saved; planned count not recorded",
                                   .text(workoutCopy.quantity(exercise.savedCount, .sets)))
    }

    func setText(_ set: CompletedSet) -> String {
        // Always state the recorded unit, including timed sets. Zero load is a
        // saved number, not inferred bodyweight. Never round the saved load.
        let fact = localization.format(set.isTimed ? "%1$@ · %2$@" : "%1$@ × %2$@",
            .text(workoutCopy.load(set.load)), .text(workoutCopy.performance(set)))
        let key: String
        switch (set.isPerSide == nil, set.rir != nil) {
        case (false, false): return fact
        case (true, false): return localization.format("%1$@ · side convention not recorded", .text(fact))
        case (false, true): key = "%1$@ · %2$lld reps in reserve"
        case (true, true): key = "%1$@ · %2$lld reps in reserve · side convention not recorded"
        }
        return localization.format(key, .text(fact), .integer(set.rir!))
    }

    func setAccessibility(_ set: CompletedSet, number: Int) -> String {
        localization.format("Set %1$lld: %2$@", .integer(number), .text(setText(set)))
    }

    /// A session-wide repetition metric is known only for a nonempty detailed
    /// record whose saved counts agree and whose sets explicitly use bilateral
    /// repetition semantics. Timed, per-side and legacy unknowns remain nil.
    static func totalRepetitions(_ entry: WorkoutHistoryDisplayItem) -> Int? {
        guard let exercises = entry.exercises else { return nil }
        let sets = exercises.flatMap(\.completedSets)
        guard !sets.isEmpty, sets.count == entry.completedSetCount else { return nil }
        var total = 0
        for set in sets {
            guard !set.isTimed, set.isPerSide == false, set.reps > 0 else { return nil }
            let result = total.addingReportingOverflow(set.reps)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    /// Logged load × repetitions, matching the existing finish definition.
    /// One recorded unit and explicit non-per-side repetitions are required.
    /// This is never elapsed work, a comparison, a best or a progression claim.
    static func loggedVolume(_ entry: WorkoutHistoryDisplayItem) -> Load? {
        guard let exercises = entry.exercises else { return nil }
        let sets = exercises.flatMap(\.completedSets)
        guard !sets.isEmpty, sets.count == entry.completedSetCount,
              let unit = sets.first?.load.unit,
              sets.allSatisfy({ !$0.isTimed && $0.isPerSide == false && $0.load.unit == unit
                  && $0.load.value.isFinite && $0.load.value >= 0 && $0.reps > 0 }) else { return nil }
        let total = sets.reduce(0.0) { $0 + $1.load.value * Double($1.reps) }
        let rounded = (total * 10).rounded() / 10
        return rounded.isFinite && rounded > 0 ? Load(rounded, unit: unit) : nil
    }
}
