import Foundation

/// Presentation facts only. The caller supplies storage-acknowledged sets;
/// drafts, a plan's previousPerformance fixture and inferred legacy facts are
/// never results. This does not change progression or training policy.
struct WorkoutComparisonPresentation: Equatable {
    /// Timed sets carry seconds in their result field and are not repetitions.
    /// An invalid or overflowing count remains unavailable in the finish UI.
    static func recordedRepetitions(in sets: [CompletedSet]) -> Int? {
        let repetitions = sets.filter { !$0.isTimed }
        guard !repetitions.isEmpty else { return nil }
        var total = 0
        for set in repetitions {
            guard set.reps > 0 else { return nil }
            let sum = total.addingReportingOverflow(set.reps)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    enum History: Equatable {
        case unavailable
        case none(hasUnknownDetails: Bool)
        case recorded(at: Date, hasNewerUnknownDetails: Bool)
    }

    enum Unit: Equatable {
        case repetitions
        case seconds
    }

    /// How a heading may name the earlier session without overstating it.
    /// "Last Thursday" is only true within the past six days.
    enum Recency: Equatable {
        case today
        case weekday
        case date
    }

    struct Bar: Equatable {
        let previous: Int?
        let today: Int?
        let unit: Unit
    }

    struct Row: Identifiable, Equatable {
        // Number is stable within the exercise occurrence, including Undo.
        let id: Int
        let previous: CompletedSet?
        let today: CompletedSet?
        let isCurrent: Bool
        let bar: Bar?
    }

    let history: History
    let rows: [Row]
    /// A repetitions-only gain across every acknowledged paired set, with
    /// unchanged load and explicit matching side semantics. Never a PR claim.
    let gainedReps: Int?

    init(state: PreviousExercisePerformanceState, confirmedSets: [CompletedSet],
         currentSet: Int, plannedSetCount: Int, prescription: WorkingSetPrescription) {
        let previous: [CompletedSet]
        let hasUnknownBarrier: Bool
        switch state {
        case .unavailable:
            history = .unavailable
            previous = []
            hasUnknownBarrier = true
        case let .noRecordedSets(unknown):
            history = .none(hasUnknownDetails: unknown)
            previous = []
            hasUnknownBarrier = unknown
        case let .recorded(performance):
            history = .recorded(at: performance.completedAt,
                                hasNewerUnknownDetails: performance.hasNewerUnknownDetails)
            // Matches the existing lookup's most recent nonempty occurrence.
            // Repeated occurrences never flatten into one numbered set list.
            previous = Self.previousSets(in: state)
            hasUnknownBarrier = performance.hasNewerUnknownDetails
        }
        let count = max(1, plannedSetCount, confirmedSets.count, previous.count)
        rows = (1 ... count).map { number in
            let before = previous.indices.contains(number - 1) ? previous[number - 1] : nil
            let today = confirmedSets.indices.contains(number - 1) ? confirmedSets[number - 1] : nil
            return Row(id: number, previous: before, today: today,
                       isCurrent: today == nil && number == currentSet,
                       bar: Self.bar(previous: before, today: today,
                                     prescription: prescription, hasUnknownBarrier: hasUnknownBarrier))
        }
        let savedRows = rows.filter { $0.today != nil }
        if !savedRows.isEmpty, savedRows.allSatisfy({ row in
            row.bar?.unit == .repetitions && row.bar?.previous != nil && row.bar?.today != nil
        }) {
            // Double bounds the display calculation even for malformed fixture
            // values. It cannot overflow an Int before deciding to show a badge.
            let gain = savedRows.reduce(0.0) { total, row in
                total + Double(row.bar!.today!) - Double(row.bar!.previous!)
            }
            gainedReps = gain > 0 && gain < Double(Int.max) ? Int(gain) : nil
        } else {
            gainedReps = nil
        }
    }

    /// No earlier sets are known and none was hidden by missing details.
    var isFirstEver: Bool { history == .none(hasUnknownDetails: false) }

    var hasTodaySets: Bool { rows.contains { $0.today != nil } }

    /// A saved set had an earlier set at the same number, but the two cannot
    /// share a bar (load, unit, side or timing differ, or details are unknown).
    var hasUncomparedPairs: Bool {
        rows.contains { $0.today != nil && $0.previous != nil && $0.bar == nil }
    }

    /// Keep the proof's 14-rep scale until recorded values require more room.
    /// Seconds have their own scale and never share a reps denominator.
    func maximum(for unit: Unit) -> Double {
        let values = rows.compactMap(\.bar).filter { $0.unit == unit }
            .flatMap { [$0.previous, $0.today].compactMap { $0 }.map(Double.init) }
        let floor = unit == .repetitions ? 14.0 : 1.0
        return max(floor, (values.max() ?? 0) * (unit == .seconds ? 1.1 : 1))
    }

    /// Calendar days, not elapsed hours: a session late last night is
    /// "yesterday's weekday", never "earlier today". A future date (clock
    /// change) is named by its date.
    static func recency(of date: Date, now: Date, calendar: Calendar) -> Recency {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day
        switch days {
        case 0?: return .today
        case let .some(value) where (1 ... 6).contains(value): return .weekday
        default: return .date
        }
    }

    /// The history kind alone, for lines that need no rows.
    static func history(for state: PreviousExercisePerformanceState) -> History {
        switch state {
        case .unavailable: return .unavailable
        case let .noRecordedSets(unknown): return .none(hasUnknownDetails: unknown)
        case let .recorded(performance):
            return .recorded(at: performance.completedAt, hasNewerUnknownDetails: performance.hasNewerUnknownDetails)
        }
    }

    /// The latest nonempty occurrence's sets, for display; the bar rules decide
    /// whether any of them may be compared.
    static func previousSets(in state: PreviousExercisePerformanceState) -> [CompletedSet] {
        guard case let .recorded(performance) = state else { return [] }
        return performance.occurrences.last(where: { !$0.completedSets.isEmpty })?.completedSets ?? []
    }

    /// Qualify display claims without changing the paused comparison authority.
    /// Legacy nil side conventions stay visible as facts, never as gains.
    static func canCompareRepetitions(_ before: CompletedSet, _ now: CompletedSet) -> Bool {
        !before.isTimed && !now.isTimed
            && before.isPerSide != nil && before.isPerSide == now.isPerSide
            && before.load.unit == now.load.unit
            && before.load.value.isFinite && now.load.value.isFinite
            && before.load.value >= 0 && now.load.value >= 0
            && before.reps > 0 && now.reps > 0
    }

    static func exerciseComparison(savedSets: [CompletedSet],
                                   previousPerformance: PreviousExercisePerformanceState) -> WorkoutExerciseComparison? {
        guard case let .recorded(performance) = previousPerformance,
              !performance.hasNewerUnknownDetails else { return nil }
        let pairs = Array(zip(savedSets, previousSets(in: previousPerformance)))
        guard !pairs.isEmpty, pairs.allSatisfy({ canCompareRepetitions($0.1, $0.0) }),
              let unit = pairs.first?.0.load.unit,
              pairs.allSatisfy({ $0.0.load.unit == unit }) else { return nil }
        var todayTotal = 0, previousTotal = 0
        for (today, previous) in pairs {
            let (nextToday, todayOverflow) = todayTotal.addingReportingOverflow(today.reps)
            let (nextPrevious, previousOverflow) = previousTotal.addingReportingOverflow(previous.reps)
            guard !todayOverflow, !previousOverflow else { return nil }
            todayTotal = nextToday
            previousTotal = nextPrevious
        }
        return WorkoutExerciseComparison.evaluate(savedSets: savedSets, previousPerformance: previousPerformance)
    }

    private static func bar(previous: CompletedSet?, today: CompletedSet?,
                            prescription: WorkingSetPrescription, hasUnknownBarrier: Bool) -> Bar? {
        switch (previous, today) {
        case let (.some(before), .some(now)):
            guard !hasUnknownBarrier, before.load == now.load,
                  let beforeSide = before.isPerSide, let nowSide = now.isPerSide,
                  beforeSide == nowSide, before.isTimed == now.isTimed,
                  let last = quantity(before), let current = quantity(now) else { return nil }
            return Bar(previous: last, today: current, unit: now.isTimed ? .seconds : .repetitions)
        case let (.some(before), .none):
            guard !hasUnknownBarrier, before.isPerSide == prescription.perSide,
                  before.isTimed == (prescription.unit == .seconds),
                  let last = quantity(before) else { return nil }
            return Bar(previous: last, today: nil, unit: before.isTimed ? .seconds : .repetitions)
        case let (.none, .some(now)):
            guard let current = quantity(now) else { return nil }
            return Bar(previous: nil, today: current, unit: now.isTimed ? .seconds : .repetitions)
        case (.none, .none):
            return nil
        }
    }

    private static func quantity(_ set: CompletedSet) -> Int? {
        guard set.load.value.isFinite, set.load.value >= 0 else { return nil }
        if let seconds = set.durationSeconds {
            return (1 ... 86_400).contains(seconds) && set.reps == 0 ? seconds : nil
        }
        return set.reps > 0 ? set.reps : nil
    }
}

/// The outlined "last time" rail drawn under the session rail. It mirrors
/// `WorkoutSetRail` segment for segment; a segment is outlined only where the
/// latest detailed occurrence of that exercise recorded a set at that number.
/// Unknown or unavailable history outlines nothing; it is never filled in.
struct WorkoutPreviousRail: Equatable {
    struct Segment: Identifiable, Equatable {
        let exerciseID: UUID
        let setNumber: Int
        let hasPrevious: Bool

        var id: String { "\(exerciseID.uuidString)-\(setNumber)" }
    }

    enum Label: Equatable {
        /// Every outlined segment comes from one earlier session.
        case session(Date)
        /// Exercises were last done in different sessions.
        case mixed
    }

    let segments: [Segment]
    let label: Label

    /// Nil when no segment would be outlined, so first-ever and unavailable
    /// history draw no ghost rail at all.
    init?(exercises: [WorkoutExercise], previous: (ExerciseID) -> PreviousExercisePerformanceState) {
        var segments: [Segment] = []
        var sources: [UUID: Date] = [:]
        for exercise in exercises {
            let state = previous(exercise.plan.exerciseID)
            var recordedCount = 0
            if case let .recorded(performance) = state, !performance.hasNewerUnknownDetails {
                recordedCount = WorkoutComparisonPresentation.previousSets(in: state).count
                if recordedCount > 0 { sources[performance.sessionID] = performance.completedAt }
            }
            let planned = max(exercise.plan.plannedSetCount, exercise.completedSets.count)
            for offset in 0 ..< planned {
                segments.append(Segment(exerciseID: exercise.id, setNumber: offset + 1,
                                        hasPrevious: offset < recordedCount))
            }
        }
        guard segments.contains(where: \.hasPrevious) else { return nil }
        self.segments = segments
        label = sources.count == 1 ? .session(sources.values.first!) : .mixed
    }
}

/// Proof 37's finish card: one row per exercise occurrence, with today's
/// paired repetitions against last time's only where the existing comparison
/// confirms every paired set kept its load. Nothing here is a best or a PR.
struct WorkoutFinishComparison: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let savedSetCount: Int
        let plannedSetCount: Int
        let comparison: WorkoutExerciseComparison?
        /// Paired repetitions today and last time, when loads matched.
        let pairedReps: (today: Int, previous: Int)?
        /// All saved repetitions, when every saved set counts repetitions.
        let savedReps: Int?

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.savedSetCount == rhs.savedSetCount
                && lhs.plannedSetCount == rhs.plannedSetCount && lhs.comparison == rhs.comparison
                && lhs.pairedReps?.today == rhs.pairedReps?.today
                && lhs.pairedReps?.previous == rhs.pairedReps?.previous
                && lhs.savedReps == rhs.savedReps
        }

        var isUp: Bool { comparison?.kind == .load || comparison?.kind == .reps }
        var isLevel: Bool { comparison?.kind == .same }
    }

    let rows: [Row]
    /// Load × reps across every saved set, only when all of them are
    /// repetition sets in one unit with explicit, non-per-side semantics.
    let volume: Load?

    var comparedCount: Int { rows.filter { $0.comparison != nil }.count }
    var upCount: Int { rows.filter(\.isUp).count }
    var levelCount: Int { rows.filter(\.isLevel).count }

    init(exercises: [WorkoutExercise], previous: (ExerciseID) -> PreviousExercisePerformanceState) {
        rows = exercises.map { exercise in
            let comparison = exercise.completedSets.isEmpty ? nil
                : WorkoutComparisonPresentation.exerciseComparison(savedSets: exercise.completedSets,
                                                     previousPerformance: previous(exercise.plan.exerciseID))
            let paired: (today: Int, previous: Int)?
            switch comparison?.kind {
            case .reps?, .same?, .under?:
                // These kinds are only produced when every paired load matched.
                paired = (comparison!.repsNow, comparison!.repsBefore)
            default:
                paired = nil
            }
            let sets = exercise.completedSets
            let reps: Int? = !sets.isEmpty && sets.allSatisfy { !$0.isTimed && $0.reps > 0 }
                ? sets.reduce(0) { total, set in
                    let (sum, overflow) = total.addingReportingOverflow(set.reps)
                    return overflow ? Int.max : sum
                }
                : nil
            return Row(id: exercise.id, name: exercise.plan.name, savedSetCount: sets.count,
                       plannedSetCount: exercise.plan.plannedSetCount, comparison: comparison,
                       pairedReps: paired, savedReps: reps == Int.max ? nil : reps)
        }
        let saved = exercises.flatMap(\.completedSets)
        if let unit = saved.first?.load.unit,
           saved.allSatisfy({ !$0.isTimed && $0.isPerSide == false && $0.load.unit == unit
               && $0.load.value.isFinite && $0.load.value >= 0 && $0.reps > 0 }) {
            let total = saved.reduce(0.0) { $0 + $1.load.value * Double($1.reps) }
            // Display only: a tenth of a unit hides binary noise from decimal loads.
            let rounded = (total * 10).rounded() / 10
            volume = rounded.isFinite && rounded > 0 ? Load(rounded, unit: unit) : nil
        } else {
            volume = nil
        }
    }

    /// The bar scale for paired rows, so one exercise's bar never claims more
    /// than its numbers. Unpaired rows draw no previous marker.
    var maximumPairedReps: Double {
        let values = rows.compactMap(\.pairedReps).flatMap { [$0.today, $0.previous] }
        return max(1, Double(values.max() ?? 1))
    }
}
