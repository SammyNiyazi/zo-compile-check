import Foundation
import Observation

enum WorkoutProgrammeID: String, CaseIterable, Codable, Hashable, Identifiable {
    case zeroOneStart = "PRG-SLICK-START-3"
    case zeroOneBuild = "PRG-SLICK-BUILD-4"
    case zeroOneConsistency = "PRG-SLICK-CONSIST-3"
    case arms = "PRG-01-ARMS-4"
    case biceps = "PRG-01-BICEPS-4"

    var id: String { rawValue }

    // Compatibility aliases keep existing local routes and test fixtures source-compatible.
    static let upperBodyA: WorkoutProgrammeID = .zeroOneBuild
    static let lowerBodyA: WorkoutProgrammeID = .zeroOneConsistency
    static let fullBodyA: WorkoutProgrammeID = .zeroOneStart
}

struct WorkoutProgrammeSession: Identifiable, Equatable {
    let id: String
    let title: String
    let exercisePlans: [ExercisePlan]
}

struct WorkoutProgramme: Identifiable, Equatable {
    let id: WorkoutProgrammeID
    let title: String
    let summary: String
    let durationMinutes: Int
    let equipmentContext: String
    let experienceBand: String
    let goalSupport: [String]
    let schedule: String
    let durationWeeks: Int
    let rules: TrainingProgrammeRules
    let evidenceReferenceKeys: [String]
    let sessions: [WorkoutProgrammeSession]
    // Carried only by an effective copy, never inferred from historical titles.
    var authoredSourceFingerprint: String? = nil

    var exercisePlans: [ExercisePlan] {
        sessions.first?.exercisePlans ?? []
    }

    var totalSetCount: Int {
        exercisePlans.reduce(0) { $0 + $1.plannedSetCount }
    }

    func makeSession(
        sessionID: String? = nil,
        previousHistory: [WorkoutHistoryEntry] = [],
        loadChoices: [WorkoutLoadChoice] = [],
        progressionAllowed: Bool = true,
        progressionReviews: [WorkoutProgressionReview] = [],
        asOf: Date = .now
    ) -> WorkoutSession {
        let selectedSession = sessionID
            .flatMap { requestedID in sessions.first { $0.id == requestedID } }
            ?? nextSession(after: previousHistory)
        let progression = WorkoutProgressionEngine(reviews: progressionReviews, asOf: asOf)
        let progressedPlans = selectedSession.exercisePlans.map { plan in
            let progressed = progression.plan(plan, using: previousHistory, allowIncrease: progressionAllowed)
            guard progressionAllowed else { return progressed }
            return WorkoutLoadChoiceResolver().apply(
                to: progressed, choices: loadChoices, history: previousHistory, engine: progression
            )
        }

        return WorkoutSession(
            title: selectedSession.title,
            programmeID: id,
            programmeProvenance: try? WorkoutProgrammeProvenance.capture(programme: self, selected: selectedSession, startedPlans: progressedPlans),
            targetDurationMinutes: durationMinutes,
            warmUp: Self.warmUp(for: progressedPlans, programmeID: id),
            exercises: progressedPlans.map { WorkoutExercise(plan: $0) }
        )
    }

    private static func warmUp(
        for plans: [ExercisePlan],
        programmeID: WorkoutProgrammeID
    ) -> WorkoutWarmUp {
        let first = plans[0]
        switch programmeID {
        case .arms:
            return WorkoutWarmUp(estimatedMinutes: 4, steps: [
                "Make easy arm circles for 30 seconds. Keep the range comfortable.",
                "Practice light dumbbell curls, then light cable rope pressdowns. Use a comfortable range and leave the working load for later.",
                "Build toward your working load with 1 or 2 lighter sets. Begin when both movements feel controlled; stop or change a movement if it causes pain."
            ], timedStepSeconds: [30])
        case .biceps:
            return WorkoutWarmUp(estimatedMinutes: 4, steps: [
                "Make easy arm circles for 30 seconds. Keep the range comfortable.",
                "Practice light dumbbell curls and a few easy hammer curls before the working sets.",
                "Build toward your working load with 1 or 2 lighter sets. Start when the movement feels controlled; stop or change it if it causes pain."
            ], timedStepSeconds: [30])
        default:
            break
        }
        let practice = first.targetLoad.value > 0
            ? "Practice \(first.name) for 1 or 2 lighter sets, building toward your working load."
            : "Practice \(first.name) for 1 or 2 short sets at an easy effort."
        return WorkoutWarmUp(estimatedMinutes: 5, steps: [
            "Move easily for 3 to 5 minutes, gradually increasing your pace.",
            practice,
            "Begin your working sets when the movement feels comfortable. Adjust if needed."
        ])
    }

    private func nextSession(after history: [WorkoutHistoryEntry]) -> WorkoutProgrammeSession {
        guard let latest = history.sorted(by: WorkoutHistoryEntry.newestFirst)
            .first(where: { $0.programmeID == id }) else {
            return sessions[0]
        }
        let index: Int?
        if let provenance = latest.programmeProvenance {
            // A known but unmatched slot is not silently relabelled by title.
            index = provenance.matches(programmeID: latest.programmeID, occurrenceIDs: (latest.exercises ?? []).map(\.id))
                ? sessions.firstIndex(where: { $0.id == provenance.sessionID }) : nil
        } else {
            // Preserve existing legacy navigation only. This does not backfill
            // provenance or qualify those records as planning evidence.
            index = sessions.firstIndex(where: { $0.title == latest.title })
        }
        guard let index else { return sessions[0] }
        return sessions[(index + 1) % sessions.count]
    }
}

/// Conservative, local progression: repeat recorded work until every planned set reaches
/// the top of its rep range at one load without any reported near-limit effort, then
/// make a small next-session load suggestion.
/// Unknown or legacy history never becomes invented evidence for a load increase.
struct WorkoutProgressionOpportunity: Codable, Equatable, Sendable {
    let previousLoad: Load
    let suggestedLoad: Load
    let context: WorkoutProgressionProposalContext?

    init(previousLoad: Load, suggestedLoad: Load, context: WorkoutProgressionProposalContext? = nil) {
        self.previousLoad = previousLoad
        self.suggestedLoad = suggestedLoad
        self.context = context
    }
}

struct WorkoutCompletionUpgrade: Identifiable, Equatable {
    let exerciseID: ExerciseID
    let exerciseName: String
    let opportunity: WorkoutProgressionOpportunity
    let completedSets: [CompletedSet]
    let targetRepUpperBound: Int
    let plan: ExercisePlan?

    init(exerciseID: ExerciseID, exerciseName: String, opportunity: WorkoutProgressionOpportunity,
         completedSets: [CompletedSet], targetRepUpperBound: Int, plan: ExercisePlan? = nil) {
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.opportunity = opportunity
        self.completedSets = completedSets
        self.targetRepUpperBound = targetRepUpperBound
        self.plan = plan
    }

    var id: ExerciseID { exerciseID }

    /// Preview an earned next-session load between exercises, but only after
    /// the active snapshot containing the final set has been saved.
    static func readyDuring(
        session: WorkoutSession,
        persistedCompletedSetCount: Int?
    ) -> Self? {
        guard let persistedCompletedSetCount,
              persistedCompletedSetCount == session.completedSetCount,
              !session.isComplete,
              session.currentExerciseIndex > 0,
              session.currentExercise?.completedSets.isEmpty == true else { return nil }
        let exercise = session.exercises[session.currentExerciseIndex - 1]
        guard let last = exercise.completedSets.last,
              exercise.completedSets.count >= exercise.plan.plannedSetCount else { return nil }
        let performance = RecordedExercisePerformance(
            sessionID: session.id,
            sessionTitle: session.title,
            completedAt: last.completedAt,
            occurrences: [WorkoutHistoryExercise(exercise: exercise)],
            hasNewerUnknownDetails: false
        )
        guard let opportunity = WorkoutProgressionEngine().earnedOpportunity(
            for: exercise.plan,
            performance: performance
        ) else { return nil }
        return Self(
            exerciseID: exercise.plan.exerciseID,
            exerciseName: exercise.plan.name,
            opportunity: opportunity,
            completedSets: exercise.completedSets,
            targetRepUpperBound: exercise.plan.targetReps.upperBound
        )
    }

    /// Only a verified, persisted completion may appear on the saved-session screen.
    /// This previews the existing next-session rule; it does not store a load choice.
    static func readyAfter(
        session: WorkoutSession,
        savedHistory: [WorkoutHistoryEntry],
        progressionReviews: [WorkoutProgressionReview] = [],
        asOf: Date = .now
    ) -> [Self] {
        guard session.isComplete,
              let entry = savedHistory.first(where: { $0.id == session.id }),
              entry.hasSameSummary(as: WorkoutHistoryEntry(session: session)),
              let savedExercises = entry.exercises,
              savedExercises == session.exercises.map(WorkoutHistoryExercise.init) else {
            return []
        }

        let engine = WorkoutProgressionEngine(reviews: progressionReviews, asOf: asOf)
        var seen = Set<ExerciseID>()
        return session.exercises.compactMap { exercise in
            let id = exercise.plan.exerciseID
            let occurrences = savedExercises.filter { $0.exerciseID == id }
            guard seen.insert(id).inserted,
                  !occurrences.isEmpty else { return nil }
            let performance = RecordedExercisePerformance(
                sessionID: entry.id,
                sessionTitle: entry.title,
                completedAt: entry.completedAt,
                occurrences: occurrences,
                hasNewerUnknownDetails: false,
                executionCompleteness: entry.executionCompleteness,
                executionCompletionConfirmedAt: entry.executionCompletionConfirmedAt, sourceEntry: entry
            )
            let nextPlan = engine.plan(exercise.plan, using: [entry])
            guard let opportunity = engine.opportunity(
                for: nextPlan,
                previousPerformance: .recorded(performance)
            ), let evidencedOccurrence = occurrences.first(where: { $0.id == opportunity.context?.occurrenceID }) else {
                return nil
            }
            return Self(
                exerciseID: id,
                exerciseName: exercise.plan.name,
                opportunity: opportunity,
                completedSets: evidencedOccurrence.completedSets,
                targetRepUpperBound: exercise.plan.targetReps.upperBound,
                plan: exercise.plan
            )
        }
    }
}

/// A single saved set that surpassed the comparable set in the last known session.
/// Callers must also establish that this set has been acknowledged by persistence.
struct WorkoutSetProgressMoment: Identifiable, Equatable {
    enum Kind: Equatable {
        case load
        case repetitions
    }

    let savedSet: CompletedSet
    let previousSet: CompletedSet
    let kind: Kind

    var id: UUID { savedSet.id }

    static func evaluate(
        savedSet: CompletedSet,
        setNumber: Int,
        previousPerformance: PreviousExercisePerformanceState
    ) -> Self? {
        guard setNumber > 0,
              case let .recorded(performance) = previousPerformance,
              !performance.hasNewerUnknownDetails,
              let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty }),
              occurrence.completedSets.indices.contains(setNumber - 1) else { return nil }

        let previousSet = occurrence.completedSets[setNumber - 1]
        guard !savedSet.isTimed, !previousSet.isTimed,
              savedSet.isPerSide == previousSet.isPerSide,
              savedSet.load.unit == previousSet.load.unit else { return nil }
        if savedSet.load.value > previousSet.load.value,
           savedSet.reps >= previousSet.reps {
            return Self(savedSet: savedSet, previousSet: previousSet, kind: .load)
        }
        if savedSet.load.value == previousSet.load.value,
           savedSet.reps > previousSet.reps {
            return Self(savedSet: savedSet, previousSet: previousSet, kind: .repetitions)
        }
        return nil
    }
}

/// A factual comparison against the same numbered set from the latest detailed
/// session. No comparison is inferred from a plan fixture or unknown history.
struct WorkoutSetResponse: Identifiable, Equatable {
    enum Kind: Equatable {
        case up
        case upReps
        case same
        case heavierIn
        case heavierBelow
        case fewer
        case lighter
    }

    let savedSet: CompletedSet
    let previousSet: CompletedSet
    let kind: Kind

    var id: UUID { savedSet.id }

    var offersNextSetLoadChoice: Bool {
        kind == .heavierIn || kind == .heavierBelow
    }

    static func evaluate(
        savedSet: CompletedSet,
        setNumber: Int,
        targetReps: RepRange,
        previousPerformance: PreviousExercisePerformanceState
    ) -> Self? {
        guard setNumber > 0,
              case let .recorded(performance) = previousPerformance,
              !performance.hasNewerUnknownDetails,
              let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty }),
              occurrence.completedSets.indices.contains(setNumber - 1) else { return nil }

        let previousSet = occurrence.completedSets[setNumber - 1]
        guard !savedSet.isTimed, !previousSet.isTimed,
              savedSet.isPerSide == previousSet.isPerSide,
              savedSet.load.unit == previousSet.load.unit else { return nil }

        let kind: Kind
        if savedSet.load.value > previousSet.load.value {
            if savedSet.reps >= previousSet.reps {
                kind = .up
            } else if savedSet.reps >= targetReps.lowerBound {
                kind = .heavierIn
            } else {
                kind = .heavierBelow
            }
        } else if savedSet.load.value < previousSet.load.value {
            kind = .lighter
        } else if savedSet.reps > previousSet.reps {
            kind = .upReps
        } else if savedSet.reps < previousSet.reps {
            kind = .fewer
        } else {
            kind = .same
        }
        return Self(savedSet: savedSet, previousSet: previousSet, kind: kind)
    }
}

enum WorkoutLoadChoiceSelection: String, Codable, Equatable {
    case tryNext
    case repeatPrevious
}

struct WorkoutLoadChoice: Codable, Equatable {
    // A fresh identity distinguishes a later identical choice from the original edit.
    // Optional for previously saved choices.
    let mutationID: UUID?
    let exerciseID: ExerciseID
    let sourceSessionID: UUID
    // Optional so choices saved before set-level evidence was recorded still decode.
    let sourceFinalSetID: UUID?
    let opportunity: WorkoutProgressionOpportunity
    let selection: WorkoutLoadChoiceSelection

    init(upgrade: WorkoutCompletionUpgrade, sourceSessionID: UUID, selection: WorkoutLoadChoiceSelection) {
        mutationID = UUID()
        exerciseID = upgrade.exerciseID
        self.sourceSessionID = sourceSessionID
        sourceFinalSetID = upgrade.completedSets.last?.id
        opportunity = upgrade.opportunity
        self.selection = selection
    }

    func matches(_ upgrade: WorkoutCompletionUpgrade, sourceSessionID: UUID) -> Bool {
        exerciseID == upgrade.exerciseID
            && self.sourceSessionID == sourceSessionID
            && opportunity == upgrade.opportunity
            && (sourceFinalSetID == nil || sourceFinalSetID == upgrade.completedSets.last?.id)
    }
}

struct WorkoutLoadChoiceUndo: Codable, Equatable {
    let expected: WorkoutLoadChoice
    let previous: WorkoutLoadChoice?
    let createdAt: Date

    var selectedLoad: Load {
        expected.selection == .tryNext ? expected.opportunity.suggestedLoad : expected.opportunity.previousLoad
    }
}

/// An earned increase remains a suggestion until the person explicitly plans it.
/// A saved choice applies only while its source is the latest known performance.
/// Neither path changes the recorded sets.
struct WorkoutLoadChoiceResolver {
    func apply(
        to plan: ExercisePlan,
        choices: [WorkoutLoadChoice],
        history: [WorkoutHistoryEntry],
        engine: WorkoutProgressionEngine = .init()
    ) -> ExercisePlan {
        guard let performance = engine.latestPerformance(for: plan, history: history),
              let qualified = WorkoutProgressionEvidence.qualify(plan: plan, performance: performance,
                  reviews: engine.reviews, at: engine.asOf),
              plan.targetLoad == qualified.opportunity.suggestedLoad else { return plan }
        guard Set(choices.map(\.exerciseID)).count == choices.count,
              let choice = choices.first(where: { $0.exerciseID == plan.exerciseID }),
              choice.sourceSessionID == performance.sessionID,
              choice.opportunity == qualified.opportunity,
              choice.sourceFinalSetID == qualified.occurrence.completedSets.last?.id,
              choice.selection == .tryNext else {
            return plan.replacingTargetLoad(qualified.opportunity.previousLoad)
        }
        return plan
    }
}

extension ExercisePlan {
    func replacingTargetLoad(_ load: Load) -> Self {
        Self(
            id: id,
            exerciseID: exerciseID,
            name: name,
            targetLoad: load,
            targetReps: targetReps,
            plannedSetCount: plannedSetCount,
            restSeconds: restSeconds,
            previousPerformance: previousPerformance,
            sourcePrescription: sourcePrescription,
            coachingCue: coachingCue,
            painGuardrail: painGuardrail,
            equipmentIdentifiers: equipmentIdentifiers,
            alternativeExerciseIDs: alternativeExerciseIDs,
            unresolvedAlternativeNames: unresolvedAlternativeNames,
            targetPrescription: targetPrescription
        )
    }
}

protocol WorkoutLoadChoicePersisting {
    func load() throws -> [WorkoutLoadChoice]
    func save(_ choices: [WorkoutLoadChoice]) throws
}

struct UserDefaultsWorkoutLoadChoiceStore: WorkoutLoadChoicePersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.workoutLoadChoices") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [WorkoutLoadChoice] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data else { throw WorkoutPersistenceError.invalidSnapshot }
        return try JSONDecoder().decode([WorkoutLoadChoice].self, from: data)
    }

    func save(_ choices: [WorkoutLoadChoice]) throws {
        // An unreadable existing payload is not permission to replace it.
        _ = try load()
        let data = try JSONEncoder().encode(choices)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
    }
}

@MainActor
@Observable
final class WorkoutLoadChoiceRepository {
    private(set) var choices: [WorkoutLoadChoice]
    private(set) var isAvailable: Bool
    private let store: any WorkoutLoadChoicePersisting
    @ObservationIgnored private var progressionPolicy: (@MainActor () -> Bool)?
    @ObservationIgnored private var progressionValidator: (@MainActor (WorkoutCompletionUpgrade, UUID) -> Bool)?

    func setProgressionValidator(_ validator: @escaping @MainActor (WorkoutCompletionUpgrade, UUID) -> Bool) {
        progressionValidator = validator
    }

    /// Install the host's live policy once. Recheck at the write boundary so a
    /// previously displayed card cannot bypass changed recovery/food evidence.
    func setProgressionPolicy(_ policy: @escaping @MainActor () -> Bool) {
        progressionPolicy = policy
    }

    init(store: any WorkoutLoadChoicePersisting = UserDefaultsWorkoutLoadChoiceStore()) {
        self.store = store
        do {
            let loaded = try store.load()
            guard Set(loaded.map(\.exerciseID)).count == loaded.count else { throw WorkoutPersistenceError.invalidSnapshot }
            choices = loaded
            isAvailable = true
        } catch {
            choices = []
            isAvailable = false
        }
    }

    func choice(for upgrade: WorkoutCompletionUpgrade, sourceSessionID: UUID) -> WorkoutLoadChoiceSelection? {
        choices.first { $0.matches(upgrade, sourceSessionID: sourceSessionID) }?.selection
    }

    @discardableResult func reload() -> Bool {
        do {
            let current = try store.load()
            guard Set(current.map(\.exerciseID)).count == current.count else {
                throw WorkoutPersistenceError.invalidSnapshot
            }
            choices = current
            isAvailable = true
            return true
        } catch {
            isAvailable = false
            return false
        }
    }

    @discardableResult
    func choose(
        _ selection: WorkoutLoadChoiceSelection,
        for upgrade: WorkoutCompletionUpgrade,
        sourceSessionID: UUID
    ) -> Bool {
        guard validates(selection, for: upgrade, sourceSessionID: sourceSessionID) else { return false }
        let choice = WorkoutLoadChoice(
            upgrade: upgrade, sourceSessionID: sourceSessionID, selection: selection
        )
        let updated = choices.filter { $0.exerciseID != upgrade.exerciseID } + [choice]
        return persist(updated)
    }

    /// Idempotent action replies still have to validate current evidence, even
    /// when they will not write a second choice or create another undo receipt.
    func validates(_ selection: WorkoutLoadChoiceSelection, for upgrade: WorkoutCompletionUpgrade,
                   sourceSessionID: UUID) -> Bool {
        isAvailable && progressionValidator?(upgrade, sourceSessionID) == true
            && (selection != .tryNext || progressionPolicy?() == true)
    }

    /// Compare the exact edit identity, not just its load. A later identical
    /// choice is still a newer user decision and must not be undone here.
    @discardableResult func undo(_ receipt: WorkoutLoadChoiceUndo) -> Bool {
        guard receipt.expected.mutationID != nil,
              receipt.previous == nil || receipt.previous?.exerciseID == receipt.expected.exerciseID,
              reload() else { return false }
        let current = choices.first { $0.exerciseID == receipt.expected.exerciseID }
        if current == receipt.previous { return true } // Already restored; no repeat write.
        guard current == receipt.expected else { return false }
        let restored = choices.filter { $0.exerciseID != receipt.expected.exerciseID }
            + (receipt.previous.map { [$0] } ?? [])
        return persist(restored)
    }

    private func persist(_ updated: [WorkoutLoadChoice]) -> Bool {
        do {
            guard try store.load() == choices else {
                _ = reload()
                return false
            }
            try store.save(updated)
            guard reload() else { return false }
            return choices == updated
        } catch {
            // A throw after writing is only success if exact readback confirms it.
            return reload() && choices == updated
        }
    }
}

struct WorkoutProgressionEngine {
    let reviews: [WorkoutProgressionReview]
    let asOf: Date

    init(reviews: [WorkoutProgressionReview] = [], asOf: Date = .now) {
        self.reviews = reviews
        self.asOf = asOf
    }

    func availableOpportunity(for plan: ExercisePlan,
                              previousPerformance: PreviousExercisePerformanceState) -> WorkoutProgressionOpportunity? {
        guard case let .recorded(performance) = previousPerformance else { return nil }
        return earnedOpportunity(for: plan, performance: performance)
    }

    func earnedOpportunity(for plan: ExercisePlan,
                           performance: RecordedExercisePerformance) -> WorkoutProgressionOpportunity? {
        WorkoutProgressionEvidence.qualify(plan: plan, performance: performance, reviews: reviews, at: asOf)?.opportunity
    }

    /// A higher authored target must match the evidence-qualified proposal.
    func opportunity(for plan: ExercisePlan,
                     previousPerformance: PreviousExercisePerformanceState) -> WorkoutProgressionOpportunity? {
        guard let earned = availableOpportunity(for: plan, previousPerformance: previousPerformance),
              plan.targetLoad == earned.suggestedLoad else { return nil }
        return earned
    }

    func plan(_ plan: ExercisePlan, using history: [WorkoutHistoryEntry], allowIncrease: Bool = true) -> ExercisePlan {
        let repeated = WorkoutHistoryDefaults().apply(to: plan, history: history, asOf: asOf)
        guard allowIncrease, let performance = latestPerformance(for: plan, history: history),
              let earned = earnedOpportunity(for: repeated, performance: performance) else { return repeated }
        return repeated.replacingTargetLoad(earned.suggestedLoad)
    }

    /// Stop at the latest attempted occurrence or an unknown summary. Do not
    /// reach past skipped, partial, future or incompatible work to earn more.
    func latestPerformance(for plan: ExercisePlan, history: [WorkoutHistoryEntry]) -> RecordedExercisePerformance? {
        guard asOf.timeIntervalSinceReferenceDate.isFinite, history.count <= 100_000,
              Set(history.map(\.id)).count == history.count,
              history.allSatisfy({ $0.completedAt.timeIntervalSinceReferenceDate.isFinite }) else { return nil }
        for entry in history.sorted(by: WorkoutHistoryEntry.newestFirst) {
            guard let exercises = entry.exercises else { return nil }
            let occurrences = exercises.filter { $0.exerciseID == plan.exerciseID }
            guard !occurrences.isEmpty else { continue }
            return RecordedExercisePerformance(sessionID: entry.id, sessionTitle: entry.title,
                completedAt: entry.completedAt, occurrences: occurrences, hasNewerUnknownDetails: false,
                executionCompleteness: entry.executionCompleteness,
                executionCompletionConfirmedAt: entry.executionCompletionConfirmedAt, sourceEntry: entry)
        }
        return nil
    }

    /// Legacy convenience step for manual +/- controls only. It is not an
    /// equipment fact and is never used to qualify a progression proposal.
    func loadIncrement(for plan: ExercisePlan) -> Double {
        guard !plan.isTimed, let definition = ExerciseLibrary.exercise(id: plan.exerciseID),
              !definition.equipment.contains(.bodyweight) else { return 0 }
        let isLegExercise = definition.category == .legs
        switch plan.targetLoad.unit {
        case .kilograms: return isLegExercise ? 5 : 2.5
        case .pounds: return isLegExercise ? 10 : 5
        }
    }
}
enum WorkoutProgrammeLibrary {
    private static let seed = TrainingSeedRepository.shared

    static let recommendedID: WorkoutProgrammeID = .zeroOneStart

    static let all: [WorkoutProgramme] = seed.programmeTemplates.compactMap(makeProgramme)

    static func programme(id: WorkoutProgrammeID) -> WorkoutProgramme? {
        all.first { $0.id == id }
    }

    private static func makeProgramme(_ record: TrainingProgrammeRecord) -> WorkoutProgramme? {
        guard let id = WorkoutProgrammeID(rawValue: record.id) else { return nil }

        let sessions = record.sessions.map { session in
            WorkoutProgrammeSession(
                id: session.id,
                title: session.name,
                exercisePlans: session.items.compactMap {
                    makePlan(item: $0, rules: record.baseRules)
                }
            )
        }
        guard let firstSession = sessions.first, !firstSession.exercisePlans.isEmpty else { return nil }

        let equipment = firstSession.exercisePlans
            .flatMap(\.equipmentIdentifiers)
            .uniqued()
            .map(formattedIdentifier)
            .joined(separator: ", ")

        return WorkoutProgramme(
            id: id,
            title: record.name,
            summary: record.schedule,
            durationMinutes: estimatedDurationMinutes(
                plans: firstSession.exercisePlans,
                defaultRest: parsedFirstNumber(record.baseRules.restSeconds) ?? 90
            ),
            equipmentContext: equipment,
            experienceBand: record.experienceBand,
            goalSupport: record.goalSupport,
            schedule: record.schedule,
            durationWeeks: record.durationWeeks,
            rules: record.baseRules,
            evidenceReferenceKeys: record.evidenceIDs,
            sessions: sessions
        )
    }

    private static func makePlan(
        item: TrainingProgrammeItemRecord,
        rules: TrainingProgrammeRules
    ) -> ExercisePlan? {
        guard let exercise = ExerciseLibrary.exercise(id: ExerciseID(rawValue: item.exerciseID)) else {
            return nil
        }

        let prescription = WorkingSetPrescription.authored(item.target, fallback: exercise.defaultRepRange)
        let repRange = prescription.unit == .repetitions
            ? RepRange(prescription.lowerBound, prescription.upperBound) : exercise.defaultRepRange
        let plannedSetCount = parsedFirstNumber(item.sets) ?? 1
        let restSeconds = TimeInterval(parsedFirstNumber(rules.restSeconds) ?? 90)

        return ExercisePlan(
            exerciseID: exercise.id,
            name: exercise.name,
            targetLoad: Load(0),
            targetReps: repRange,
            plannedSetCount: plannedSetCount,
            restSeconds: restSeconds,
            previousPerformance: [],
            sourcePrescription: item.sets + " sets · " + item.target,
            coachingCue: exercise.shortCoachingCue,
            painGuardrail: exercise.painGuardrail,
            equipmentIdentifiers: exercise.equipmentIdentifiers,
            alternativeExerciseIDs: exercise.resolvedAlternativeIDs,
            unresolvedAlternativeNames: exercise.unresolvedAlternativeNames,
            targetPrescription: prescription
        )
    }

    private static func parsedFirstNumber(_ value: String) -> Int? {
        numbers(in: value).first
    }

    private static func numbers(in value: String) -> [Int] {
        value
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
    }

    private static func estimatedDurationMinutes(
        plans: [ExercisePlan],
        defaultRest: Int
    ) -> Int {
        let estimatedSeconds = plans.reduce(0) { total, plan in
            let workingSeconds = plan.isTimed
                ? plan.prescription.lowerBound * (plan.prescription.perSide ? 2 : 1) : 45
            return total + plan.plannedSetCount * (workingSeconds + defaultRest)
        }
        let minutes = max(20, Int(ceil(Double(estimatedSeconds) / 60)))
        return Int(ceil(Double(minutes) / 5) * 5)
    }

    private static func formattedIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_or_", with: " or ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

enum WorkoutProgrammeRoute: Equatable {
    case library
    case detail(WorkoutProgrammeID)
    case active(WorkoutProgrammeID)
    case customActive(UUID)
}

protocol WorkoutProgrammeSelectionPersisting {
    func loadSelectedID() -> WorkoutProgrammeID?
    func saveSelectedID(_ id: WorkoutProgrammeID)
}

struct UserDefaultsWorkoutProgrammeSelectionStore: WorkoutProgrammeSelectionPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.selectedProgramme") {
        self.defaults = defaults
        self.key = key
    }

    func loadSelectedID() -> WorkoutProgrammeID? {
        defaults.string(forKey: key).flatMap(WorkoutProgrammeID.init(rawValue:))
    }

    func saveSelectedID(_ id: WorkoutProgrammeID) {
        defaults.set(id.rawValue, forKey: key)
    }
}

enum WorkoutProgrammeScheduleError: Error, Equatable {
    case invalidDays
    case unavailable
    case staleSchedule
}

/// Calendar weekday values follow Foundation: Sunday = 1 through Saturday = 7.
/// The schedule is a preferred rhythm, not a gate on starting a workout.
struct WorkoutProgrammeSchedule: Codable, Equatable {
    let programmeID: WorkoutProgrammeID
    let weekdays: [Int]
    let confirmedAt: Date

    init(programme: WorkoutProgramme, weekdays: Set<Int>, confirmedAt: Date) throws {
        let minimum = min(2, programme.sessions.count)
        guard weekdays.allSatisfy({ (1 ... 7).contains($0) }),
              confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              weekdays.count >= minimum, weekdays.count <= programme.sessions.count else {
            throw WorkoutProgrammeScheduleError.invalidDays
        }
        programmeID = programme.id
        self.weekdays = weekdays.sorted()
        self.confirmedAt = confirmedAt
    }

    func isValid(for programme: WorkoutProgramme) -> Bool {
        programmeID == programme.id
            && confirmedAt.timeIntervalSinceReferenceDate.isFinite
            && weekdays == Array(Set(weekdays)).sorted()
            && weekdays.allSatisfy { (1 ... 7).contains($0) }
            && weekdays.count >= min(2, programme.sessions.count)
            && weekdays.count <= programme.sessions.count
    }

    func includes(_ date: Date, calendar: Calendar) -> Bool {
        weekdays.contains(calendar.component(.weekday, from: date))
    }

    func weekdaysInCalendarOrder(_ calendar: Calendar) -> [Int] {
        (0 ..< 7)
            .map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            .filter { weekdays.contains($0) }
    }

    func nextDay(onOrAfter date: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0 ... 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            if includes(day, calendar: calendar) { return day }
        }
        return nil
    }
}

protocol WorkoutProgrammeSchedulePersisting {
    func load() throws -> WorkoutProgrammeSchedule?
    func save(_ schedule: WorkoutProgrammeSchedule) throws
}

struct UserDefaultsWorkoutProgrammeScheduleStore: WorkoutProgrammeSchedulePersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.workoutProgrammeSchedule.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> WorkoutProgrammeSchedule? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else { throw WorkoutProgrammeScheduleError.unavailable }
        return try JSONDecoder().decode(WorkoutProgrammeSchedule.self, from: data)
    }

    func save(_ schedule: WorkoutProgrammeSchedule) throws {
        let data = try JSONEncoder().encode(schedule)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
    }
}

@MainActor
@Observable
final class WorkoutProgrammeCoordinator {
    let programmes: [WorkoutProgramme]
    private(set) var selectedProgrammeID: WorkoutProgrammeID?
    private(set) var activeSchedule: WorkoutProgrammeSchedule?
    private(set) var scheduleIsAvailable = true
    private(set) var route: WorkoutProgrammeRoute = .library

    private let selectionStore: any WorkoutProgrammeSelectionPersisting
    private let scheduleStore: any WorkoutProgrammeSchedulePersisting

    init(
        programmes: [WorkoutProgramme] = WorkoutProgrammeLibrary.all,
        selectionStore: any WorkoutProgrammeSelectionPersisting = UserDefaultsWorkoutProgrammeSelectionStore(),
        scheduleStore: any WorkoutProgrammeSchedulePersisting = UserDefaultsWorkoutProgrammeScheduleStore()
    ) {
        precondition(programmes.count == 5, "The gym prototype requires five local programmes.")
        self.programmes = programmes
        self.selectionStore = selectionStore
        self.scheduleStore = scheduleStore

        if let storedID = selectionStore.loadSelectedID(),
           programmes.contains(where: { $0.id == storedID }) {
            selectedProgrammeID = storedID
        }
        do {
            activeSchedule = try verifiedSchedule(at: .now)
        } catch {
            scheduleIsAvailable = false
        }
    }

    var selectedProgramme: WorkoutProgramme? {
        guard let selectedProgrammeID else { return nil }
        return programmes.first { $0.id == selectedProgrammeID }
    }

    var scheduledProgramme: WorkoutProgramme? {
        guard let activeSchedule else { return nil }
        return programmes.first { $0.id == activeSchedule.programmeID }
    }

    func confirmSchedule(for id: WorkoutProgrammeID, weekdays: Set<Int>, at date: Date = .now) throws {
        try confirmSchedule(for: id, weekdays: weekdays, replacing: activeSchedule, at: date)
    }

    /// A form/proposal carries the exact schedule it reviewed. Reread before
    /// writing and publish only an acknowledged readback; a stale screen cannot
    /// replace a newer or newly corrupt source.
    func confirmSchedule(for id: WorkoutProgrammeID, weekdays: Set<Int>,
                         replacing expected: WorkoutProgrammeSchedule?, at date: Date = .now) throws {
        guard let programme = programmes.first(where: { $0.id == id }) else {
            throw WorkoutProgrammeScheduleError.invalidDays
        }
        let current: WorkoutProgrammeSchedule?
        do { current = try verifiedSchedule(at: date) }
        catch { scheduleIsAvailable = false; throw WorkoutProgrammeScheduleError.unavailable }
        guard current == expected else {
            activeSchedule = current
            scheduleIsAvailable = true
            throw WorkoutProgrammeScheduleError.staleSchedule
        }
        let schedule = try WorkoutProgrammeSchedule(programme: programme, weekdays: weekdays, confirmedAt: date)
        do {
            try scheduleStore.save(schedule)
            guard try verifiedSchedule(at: date) == schedule else { throw WorkoutProgrammeScheduleError.unavailable }
        } catch {
            scheduleIsAvailable = false
            throw WorkoutProgrammeScheduleError.unavailable
        }
        activeSchedule = schedule
        scheduleIsAvailable = true
        selectedProgrammeID = id
        selectionStore.saveSelectedID(id)
    }

    @discardableResult
    func reloadSchedule(at date: Date = .now) -> Bool {
        do {
            activeSchedule = try verifiedSchedule(at: date)
            scheduleIsAvailable = true
            return true
        } catch {
            scheduleIsAvailable = false
            return false
        }
    }

    private func verifiedSchedule(at date: Date) throws -> WorkoutProgrammeSchedule? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw WorkoutProgrammeScheduleError.unavailable }
        let stored = try scheduleStore.load()
        if let stored {
            guard let programme = programmes.first(where: { $0.id == stored.programmeID }),
                  stored.isValid(for: programme), stored.confirmedAt <= date else {
                throw WorkoutProgrammeScheduleError.unavailable
            }
        }
        return stored
    }

    /// Set-count review does not require choosing training days. Read the exact
    /// calendar observation without clearing or repairing an invalid record.
    func programmeVolumeCalendarEvidence(at date: Date = .now) -> ProgrammeVolumeCalendarEvidence {
        do {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw WorkoutProgrammeScheduleError.unavailable }
            guard let stored = try scheduleStore.load() else {
                activeSchedule = nil; scheduleIsAvailable = true
                return .absent
            }
            if let programme = programmes.first(where: { $0.id == stored.programmeID }),
               stored.isValid(for: programme), stored.confirmedAt <= date {
                activeSchedule = stored; scheduleIsAvailable = true
            } else {
                scheduleIsAvailable = false
            }
            return .observed(stored)
        } catch {
            scheduleIsAvailable = false
            return .unavailable
        }
    }

    func showLibrary() {
        route = .library
    }

    func showDetail(for id: WorkoutProgrammeID) {
        guard programmes.contains(where: { $0.id == id }) else { return }
        selectedProgrammeID = id
        selectionStore.saveSelectedID(id)
        route = .detail(id)
    }

    func startSelectedProgramme(
        effectiveProgramme: WorkoutProgramme? = nil,
        previousHistory: [WorkoutHistoryEntry] = [],
        loadChoices: [WorkoutLoadChoice] = [],
        progressionAllowed: Bool = true,
        progressionReviews: [WorkoutProgressionReview] = [],
        asOf: Date = .now
    ) -> WorkoutSession? {
        guard let selected = selectedProgramme else { return nil }
        let programme = effectiveProgramme ?? selected
        guard programme.id == selected.id else { return nil }
        route = .active(programme.id)
        return programme.makeSession(previousHistory: previousHistory, loadChoices: loadChoices,
            progressionAllowed: progressionAllowed, progressionReviews: progressionReviews, asOf: asOf)
    }

    func restoreActiveProgramme(_ id: WorkoutProgrammeID) {
        guard programmes.contains(where: { $0.id == id }) else { return }
        selectedProgrammeID = id
        selectionStore.saveSelectedID(id)
        route = .active(id)
    }

    func restoreActiveCustomWorkout(_ id: UUID) {
        route = .customActive(id)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
