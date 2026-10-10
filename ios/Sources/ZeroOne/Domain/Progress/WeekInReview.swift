import Foundation

/// Proof 43 "Week in review": the Monday-to-Sunday week told from saved History.
/// Bars, never a body. "Your plan" is what the selected plan schedules for a muscle
/// group in a week (direct sets to direct plus helper sets), not a target.
struct WeekInReview: Equatable {
    enum Area: String, CaseIterable, Identifiable {
        case legs, chest, back, shoulders, arms, core
        var id: String { rawValue }
        /// Localization keys; "Back" and "Core" alone already mean other things in the app.
        var title: String {
            switch self {
            case .back: "Back (muscle group)"
            case .core: "Core (muscle group)"
            default: rawValue.capitalized
            }
        }

        init?(_ region: WorkoutMuscleRegion) {
            switch region {
            case .glutes, .quadriceps, .hamstrings, .calves, .adductors, .hipFlexors: self = .legs
            case .chest: self = .chest
            case .back, .traps, .lowerBack: self = .back
            case .shoulders, .serratus: self = .shoulders
            case .biceps, .triceps, .forearms: self = .arms
            case .core: self = .core
            }
        }

        /// Each set counts once per group, however many of its muscles sit in that group.
        static func groups(_ names: [String]) -> Set<Area> {
            Set(names.compactMap { name in
                (WorkoutMuscleRegion.fromSeedMuscle(name) ?? WorkoutMuscleRegion.fromLicensedMuscle(name)).flatMap(Area.init)
            })
        }
    }

    struct Day: Equatable, Identifiable {
        let date: Date
        let trained: Bool
        let isToday: Bool
        let isFuture: Bool
        var id: Date { date }
    }

    struct Row: Equatable, Identifiable {
        let group: Area
        let done: Int
        /// Weekly sets the plan schedules: direct sets ... direct plus helper sets.
        let plan: ClosedRange<Double>?
        var id: Area { group }
    }

    let start: Date
    let end: Date
    let days: [Day]
    let workouts: Int
    let plannedDays: Int?
    let previousWeekFull: Bool
    let rows: [Row]
    let wentUp: [String]
    let isWeekEnding: Bool

    var isFull: Bool { plannedDays.map { $0 > 0 && workouts >= $0 } ?? false }

    /// The group furthest under the plan's direct sets, by two sets or more.
    var shortfall: (group: Area, sets: Int)? {
        let gaps = rows.compactMap { row -> (Area, Int)? in
            guard let plan = row.plan else { return nil }
            let gap = Int(plan.lowerBound.rounded()) - row.done
            return gap >= 2 ? (row.group, gap) : nil
        }
        guard let best = gaps.max(by: { $0.1 < $1.1 }) else { return nil }
        return (best.0, best.1)
    }

    var fewest: Area? {
        let worked = rows.filter { $0.plan != nil }
        guard worked.contains(where: { $0.done > 0 }) else { return nil }
        return worked.min { $0.done < $1.done }?.group
    }

    static func make(entries: [WorkoutHistoryDisplayItem], programme: WorkoutProgramme?, scheduledDays: Int?,
                     now: Date, calendar: Calendar) -> WeekInReview {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        weekCalendar.minimumDaysInFirstWeek = 4
        let start = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? weekCalendar.startOfDay(for: now)
        let end = weekCalendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        let previousStart = weekCalendar.date(byAdding: .day, value: -7, to: start) ?? start
        let inWeek = entries.filter { $0.completedAt >= start && $0.completedAt < end && $0.completedSetCount > 0 }
        let previous = entries.filter { $0.completedAt >= previousStart && $0.completedAt < start && $0.completedSetCount > 0 }
        let today = weekCalendar.startOfDay(for: now)

        let days: [Day] = (0 ..< 7).compactMap { offset in
            guard let day = weekCalendar.date(byAdding: .day, value: offset, to: start),
                  let next = weekCalendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return Day(date: day, trained: inWeek.contains { $0.completedAt >= day && $0.completedAt < next },
                       isToday: day == today, isFuture: day > today)
        }

        var done: [Area: Int] = [:]
        for entry in inWeek {
            for exercise in entry.exercises ?? [] where !exercise.completedSets.isEmpty {
                for group in Area.groups(primaryNames(exercise.exerciseID)) {
                    done[group, default: 0] += exercise.completedSets.count
                }
            }
        }

        let days7 = scheduledDays.flatMap { (1 ... 7).contains($0) ? $0 : nil }
        var plan: [Area: ClosedRange<Double>] = [:]
        if let programme, let days7, !programme.sessions.isEmpty {
            var direct: [Area: Int] = [:]
            var helper: [Area: Int] = [:]
            for item in programme.sessions.flatMap(\.exercisePlans) {
                guard let definition = ExerciseLibrary.exercise(id: item.exerciseID) else { continue }
                let primary = Area.groups(definition.primaryMuscleNames)
                for group in primary { direct[group, default: 0] += item.plannedSetCount }
                for group in Area.groups(definition.secondaryMuscleNames).subtracting(primary) {
                    helper[group, default: 0] += item.plannedSetCount
                }
            }
            let perWeek = Double(days7) / Double(programme.sessions.count)
            for group in Area.allCases where direct[group, default: 0] > 0 {
                let low = Double(direct[group, default: 0]) * perWeek
                plan[group] = low ... low + Double(helper[group, default: 0]) * perWeek
            }
        }
        let rows = Area.allCases.compactMap { group -> Row? in
            let sets = done[group, default: 0]
            guard sets > 0 || plan[group] != nil else { return nil }
            return Row(group: group, done: sets, plan: plan[group])
        }

        // Went up: this week's heaviest saved set beats the last earlier time, same unit.
        var wentUp: [String] = []
        let earlier = entries.filter { $0.completedAt < start }.sorted { $0.completedAt > $1.completedAt }
        var seen = Set<ExerciseID>()
        for entry in inWeek.sorted(by: { $0.completedAt < $1.completedAt }) {
            for exercise in entry.exercises ?? [] where seen.insert(exercise.exerciseID).inserted {
                guard let now = exercise.completedSets.max(by: { $0.load.value < $1.load.value })?.load, now.value > 0,
                      let before = earlier.lazy.compactMap({ old in
                          old.exercises?.first { $0.exerciseID == exercise.exerciseID }?
                              .completedSets.max(by: { $0.load.value < $1.load.value })?.load
                      }).first, before.unit == now.unit, now.value > before.value else { continue }
                wentUp.append(name(exercise.exerciseID))
            }
        }

        let weekday = weekCalendar.component(.weekday, from: now)
        return WeekInReview(start: start, end: end, days: days, workouts: inWeek.count, plannedDays: days7,
                            previousWeekFull: days7.map { previous.count >= $0 } ?? false, rows: rows,
                            wentUp: wentUp, isWeekEnding: weekday == 1 || weekday == 7)
    }

    private static func primaryNames(_ id: ExerciseID) -> [String] {
        if let definition = ExerciseLibrary.exercise(id: id) { return definition.primaryMuscleNames }
        if let clip = MoveKitExerciseCatalog.match(for: id)?.exercise {
            return clip.muscleFocus.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    private static func name(_ id: ExerciseID) -> String {
        ExerciseLibrary.exercise(id: id)?.name ?? MoveKitExerciseCatalog.match(for: id)?.exercise.name ?? id.rawValue
    }

    /// "A full week." / "2 of 3 so far." / "Nothing saved yet."
    func headline(_ localization: AppLocalization) -> String {
        if isFull { return localization.string("A full week.") }
        if workouts == 0 { return localization.string("Nothing saved yet.") }
        if let plannedDays {
            return localization.format("%1$@ of %2$@ so far.", .text(String(workouts)), .text(String(plannedDays)))
        }
        return localization.format(workouts == 1 ? "%1$@ workout so far." : "%1$@ workouts so far.", .text(String(workouts)))
    }

    /// The coach's two lines, from saved facts only.
    func coachLines(_ localization: AppLocalization) -> [String] {
        var lines: [String] = []
        if isFull, let plannedDays {
            lines.append(previousWeekFull
                ? localization.format("%1$@ of %1$@, the second full week in a row.", .text(String(plannedDays)))
                : localization.format("%1$@ of %1$@. Every planned day done.", .text(String(plannedDays))))
        }
        var second: [String] = []
        switch wentUp.count {
        case 0: break
        case 1: second.append(localization.format("%1$@ went up.", .text(wentUp[0])))
        default: second.append(localization.format("%1$@ and %2$@ both went up.", .text(wentUp[0]), .text(wentUp[1])))
        }
        if let fewest {
            second.append(localization.format("%1$@ had the fewest hard sets.", .text(localization.string(fewest.title))))
        }
        if !second.isEmpty { lines.append(second.joined(separator: " ")) }
        return lines
    }
}
