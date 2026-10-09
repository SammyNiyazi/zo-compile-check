import Foundation

/// What the library may say about the person's confirmed training days.
/// Unavailable is not the same as none: the stored schedule could not be read
/// (the coordinator keeps its last value after a failed reload), so neither
/// planned days nor their absence is presented as current.
enum WorkoutScheduleAvailability: Equatable {
    case noSchedule
    case confirmed(WorkoutProgrammeSchedule)
    case unavailable

    init(schedule: WorkoutProgrammeSchedule?, isAvailable: Bool) {
        if !isAvailable {
            self = .unavailable
        } else if let schedule {
            self = .confirmed(schedule)
        } else {
            self = .noSchedule
        }
    }

    /// The schedule the library may present as current, or nil.
    var currentSchedule: WorkoutProgrammeSchedule? {
        if case let .confirmed(schedule) = self { return schedule }
        return nil
    }

    var isUnavailable: Bool { self == .unavailable }

    /// The confirmed schedule's programme, used for "Your plan" badges.
    func isCurrentPlan(_ programmeID: WorkoutProgrammeID) -> Bool {
        currentSchedule?.programmeID == programmeID
    }
}

/// Proof 38's "Your week": seven days in the person's calendar order. Done
/// days come from saved History (a workout with at least one saved set),
/// planned days from the confirmed schedule, and today is marked. Nothing is
/// inferred: unreadable History marks no day done, and without a readable
/// schedule no day is planned.
struct WorkoutWeekPresentation: Equatable {
    struct Day: Identifiable, Equatable {
        /// Start of the day in the given calendar.
        let date: Date
        let weekday: Int
        let dayOfMonth: Int
        let isDone: Bool
        let isPlanned: Bool
        let isToday: Bool

        var id: Date { date }
    }

    enum Count: Equatable {
        /// "1 of 3 planned days done": planned days this week that have a
        /// saved workout, against the schedule's days. Workouts on days
        /// outside the plan are counted apart, never as planned sessions.
        case planned(done: Int, of: Int, otherDays: Int)
        /// No schedule: only what was done.
        case unplanned(done: Int)
        /// History could not be read, so nothing is counted.
        case historyUnavailable
    }

    let days: [Day]
    let count: Count
    /// The first planned day from today that is not already done, within a
    /// week. Nil without a readable schedule.
    let nextPlannedDay: Date?
    /// The saved schedule could not be read: nothing is planned, and the view
    /// says so rather than implying there is no plan.
    let scheduleIsUnavailable: Bool

    /// A schedule passed directly is taken as readable.
    init(schedule: WorkoutProgrammeSchedule?, entries: [WorkoutHistoryEntry]?,
         now: Date, calendar: Calendar) {
        self.init(schedule: WorkoutScheduleAvailability(schedule: schedule, isAvailable: true),
                  entries: entries, now: now, calendar: calendar)
    }

    /// - Parameter entries: saved History, or nil when it cannot be read.
    init(schedule availability: WorkoutScheduleAvailability, entries: [WorkoutHistoryEntry]?,
         now: Date, calendar: Calendar) {
        let schedule = availability.currentSchedule
        scheduleIsUnavailable = availability.isUnavailable
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)
            .map { calendar.startOfDay(for: $0.start) } ?? today
        let doneDays = Set((entries ?? []).filter { $0.completedSetCount > 0 }
            .map { calendar.startOfDay(for: $0.completedAt) })

        days = (0 ..< 7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return Day(date: date, weekday: weekday, dayOfMonth: calendar.component(.day, from: date),
                       isDone: doneDays.contains(date), isPlanned: schedule?.weekdays.contains(weekday) == true,
                       isToday: date == today)
        }

        let done = days.filter(\.isDone).count
        if entries == nil {
            count = .historyUnavailable
        } else if let schedule {
            let plannedDone = days.filter { $0.isDone && $0.isPlanned }.count
            count = .planned(done: plannedDone, of: schedule.weekdays.count, otherDays: done - plannedDone)
        } else {
            count = .unplanned(done: done)
        }

        if let schedule {
            nextPlannedDay = (0 ... 7).lazy.compactMap { offset -> Date? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                      schedule.weekdays.contains(calendar.component(.weekday, from: date)),
                      !doneDays.contains(date) else { return nil }
                return date
            }.first
        } else {
            nextPlannedDay = nil
        }
    }
}

/// Proof 38's saved-workout card: counts from the saved items, the time from
/// the existing deterministic estimator, the first four exercise pictures and
/// the set rail. No history is read, so no "last done" is claimed here.
struct CustomWorkoutCardPresentation: Equatable {
    static let stackLimit = 4

    let exerciseCount: Int
    /// Nil when an older, unvalidated workout's sets cannot be summed.
    let setCount: Int?
    /// The estimator's upper minutes, or nil when the workout has no estimate.
    let estimatedMinutes: Int?
    /// Exact MoveKit media for the first four exercises, nil where none exists.
    let stack: [MoveKitExercise?]
    let overflowCount: Int
    /// Planned sets per exercise, in order, for the rail.
    let railGroups: [Int]

    init(workout: CustomWorkout) {
        exerciseCount = workout.items.count
        setCount = CustomWorkoutBuilderPresentation.totalSets(workout.items)
        estimatedMinutes = CustomWorkoutBuilderPresentation
            .estimate(for: workout, warmUp: workout.warmUpLength ?? .full)?.maximumMinutes
        stack = workout.items.prefix(Self.stackLimit).map(\.mediaExercise)
        overflowCount = max(0, workout.items.count - Self.stackLimit)
        railGroups = workout.items.map { max(0, $0.sets) }
    }
}

/// Proof 38's exercise card facts.
enum WorkoutExerciseGridPresentation {
    /// "Legs · Dumbbell": what it trains, then with what. The catalog's "Not
    /// supplied" placeholder is left out, never shown as a fact.
    static func detailLine(for exercise: MoveKitExercise) -> String? {
        let parts = [exercise.muscleFocus, exercise.equipment]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Not supplied" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Proof 9's programme cover and week grid, from typed facts only: the
/// programme's authored weeks, its session rotation and estimated minutes,
/// and the person's own confirmed training days for this programme when they
/// exist and can be read. A rotation is not a weekly frequency, so no days-a-week or total
/// sessions are derived from it, and free-text schedule prose is never parsed.
/// The proof's photo, finish date and filled progress are sample data.
struct ProgrammeCoverPresentation: Equatable {
    /// The grid stays legible; a longer authored plan is still named in words.
    static let maximumWeekColumns = 12
    static let maximumDaysPerWeek = 7

    let weeks: Int
    /// Distinct sessions in the authored rotation. Not a weekly count.
    let rotationLength: Int
    let minutes: Int
    /// Days a week from the person's confirmed schedule for this programme.
    /// Nil when there is none: the programme authors no typed frequency.
    let scheduledDaysPerWeek: Int?
    let gridWeeks: Int
    /// One bar per scheduled day; a single bar per week when no frequency is
    /// known, so the grid shows the weeks without claiming sessions.
    let gridBarsPerWeek: Int
    /// The saved schedule could not be read, so no days a week are shown.
    let scheduleIsUnavailable: Bool

    /// A schedule passed directly is taken as readable.
    init(programme: WorkoutProgramme, schedule: WorkoutProgrammeSchedule?) {
        self.init(programme: programme,
                  schedule: WorkoutScheduleAvailability(schedule: schedule, isAvailable: true))
    }

    init(programme: WorkoutProgramme, schedule availability: WorkoutScheduleAvailability) {
        let schedule = availability.currentSchedule
        scheduleIsUnavailable = availability.isUnavailable
        weeks = max(0, programme.durationWeeks)
        rotationLength = programme.sessions.count
        minutes = max(0, programme.durationMinutes)
        scheduledDaysPerWeek = schedule.flatMap { schedule in
            schedule.programmeID == programme.id && !schedule.weekdays.isEmpty ? schedule.weekdays.count : nil
        }
        gridWeeks = min(weeks, Self.maximumWeekColumns)
        gridBarsPerWeek = min(scheduledDaysPerWeek ?? 1, Self.maximumDaysPerWeek)
    }
}

/// Proof 39's exercise page words: the muscles as words, then the equipment,
/// never a body figure. "Glutes and quadriceps" becomes "Glutes" and
/// "Quadriceps"; the equipment stays one phrase. The catalog's "Not
/// supplied" placeholder is never a word.
enum ExerciseDetailPresentation {
    static func tags(muscleFocus: String, equipment: String?) -> [String] {
        let muscles = muscleFocus
            .components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isFact)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let gear = [equipment?.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.filter(isFact)
        var seen = Set<String>()
        return (muscles + gear).filter { seen.insert($0.lowercased()).inserted }
    }

    private static func isFact(_ value: String) -> Bool {
        !value.isEmpty && value != "Not supplied"
    }
}

/// Proof 39's "You and this exercise", from saved History only: the best
/// loaded set with its date, the heaviest set of each session as one line,
/// and the most recent sessions with every set. Loads are compared only in
/// the unit of the newest loaded set; timed and unloaded sets are listed but
/// never ranked. Nothing is estimated.
struct ExerciseHistoryPresentation: Equatable {
    static let chartLimit = 7
    static let recentLimit = 3

    struct Best: Equatable {
        let setID: UUID
        let sessionID: UUID
        let load: Load
        let reps: Int
        let completedAt: Date
    }

    struct Point: Equatable {
        let sessionID: UUID
        let completedAt: Date
        let load: Load
        let reps: Int
    }

    struct Session: Identifiable, Equatable {
        let id: UUID
        let completedAt: Date
        let sets: [CompletedSet]
    }

    /// Distinct saved sessions with at least one set of this exercise.
    let sessionCount: Int
    let best: Best?
    /// Oldest first, at most `chartLimit`, in the best set's unit.
    let topSets: [Point]
    /// Newest first, at most `recentLimit`.
    let recentSessions: [Session]

    init(history: WorkoutExerciseHistory) {
        // Items are newest first; one session can hold the exercise twice.
        var sessions: [Session] = []
        for item in history.items {
            if let index = sessions.firstIndex(where: { $0.id == item.sessionID }) {
                sessions[index] = Session(id: item.sessionID, completedAt: sessions[index].completedAt,
                                          sets: sessions[index].sets + item.completedSets)
            } else {
                sessions.append(Session(id: item.sessionID, completedAt: item.completedAt, sets: item.completedSets))
            }
        }
        sessionCount = sessions.count
        recentSessions = Array(sessions.prefix(Self.recentLimit))

        // Per-side and unknown-convention sets remain listed, but are never
        // ranked against explicitly both-sided ones.
        let ranked: (CompletedSet) -> Bool = { set in
            !set.isTimed && set.isPerSide == false && set.reps > 0 && set.load.value.isFinite && set.load.value > 0
        }
        guard let unit = sessions.lazy.flatMap({ $0.sets.reversed() }).first(where: ranked)?.load.unit else {
            best = nil
            topSets = []
            return
        }
        let heavier: (CompletedSet, CompletedSet) -> Bool = { lhs, rhs in
            if lhs.load.value != rhs.load.value { return lhs.load.value < rhs.load.value }
            if lhs.reps != rhs.reps { return lhs.reps < rhs.reps }
            // The earlier of two equal sets is the one that set the mark.
            return lhs.completedAt > rhs.completedAt
        }
        let comparable = { (sets: [CompletedSet]) in sets.filter { ranked($0) && $0.load.unit == unit } }
        best = sessions.flatMap { session in comparable(session.sets).map { (session.id, $0) } }
            .max { heavier($0.1, $1.1) }
            .map { Best(setID: $0.1.id, sessionID: $0.0, load: $0.1.load, reps: $0.1.reps, completedAt: $0.1.completedAt) }
        topSets = Array(sessions.reversed().compactMap { session in
            comparable(session.sets).max(by: heavier).map {
                Point(sessionID: session.id, completedAt: session.completedAt, load: $0.load, reps: $0.reps)
            }
        }.suffix(Self.chartLimit))
    }
}

/// Proof 39's swap rows say why an option fits. Each reason is a fact read
/// from the two exercise definitions, never a ranking the selector did not
/// make: the same main muscle, the same movement, no equipment, or an
/// easier listed difficulty.
enum ExerciseSwapPresentation {
    static func reasons(for candidate: ExerciseDefinition, replacing source: ExerciseDefinition?) -> [String] {
        guard let source else { return [] }
        var reasons: [String] = []
        if candidate.primaryMuscleGroup == source.primaryMuscleGroup { reasons.append("Same main muscle") }
        if candidate.movementPattern == source.movementPattern { reasons.append("Same movement") }
        if candidate.equipment == [.bodyweight], source.equipment != [.bodyweight] { reasons.append("No equipment") }
        if let candidateLevel = ExerciseDifficulty.allCases.firstIndex(of: candidate.difficulty),
           let sourceLevel = ExerciseDifficulty.allCases.firstIndex(of: source.difficulty),
           candidateLevel < sourceLevel {
            reasons.append("Easier")
        }
        return reasons
    }
}
