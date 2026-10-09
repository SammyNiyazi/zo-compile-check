import Foundation

enum WorkoutWarmUpStatus: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case partial
    case skipped
}

enum WorkoutWarmUpLength: String, CaseIterable, Codable, Hashable, Sendable {
    case full
    case short
    case none
}

struct WorkoutWarmUp: Codable, Equatable, Sendable {
    let estimatedMinutes: Int
    let steps: [String]
    let timedStepSeconds: [Int?]
    let length: WorkoutWarmUpLength
    private(set) var status: WorkoutWarmUpStatus = .pending
    private(set) var resolvedAt: Date?
    private(set) var checkedStepIndices: Set<Int> = []

    private enum CodingKeys: String, CodingKey {
        case estimatedMinutes, steps, timedStepSeconds, length, status, resolvedAt, checkedStepIndices
    }

    init(
        estimatedMinutes: Int,
        steps: [String],
        timedStepSeconds: [Int?] = [],
        length: WorkoutWarmUpLength = .full
    ) {
        self.estimatedMinutes = estimatedMinutes
        self.steps = steps
        self.timedStepSeconds = steps.indices.map { index in
            guard timedStepSeconds.indices.contains(index), let seconds = timedStepSeconds[index],
                  seconds > 0 else { return nil }
            return seconds
        }
        self.length = length
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        estimatedMinutes = try container.decode(Int.self, forKey: .estimatedMinutes)
        steps = try container.decode([String].self, forKey: .steps)
        let savedTimers = try container.decodeIfPresent([Int?].self, forKey: .timedStepSeconds) ?? []
        timedStepSeconds = steps.indices.map { index in
            guard savedTimers.indices.contains(index), let seconds = savedTimers[index],
                  seconds > 0 else { return nil }
            return seconds
        }
        length = try container.decodeIfPresent(WorkoutWarmUpLength.self, forKey: .length) ?? .full
        status = try container.decodeIfPresent(WorkoutWarmUpStatus.self, forKey: .status) ?? .pending
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        let savedIndices = try container.decodeIfPresent([Int].self, forKey: .checkedStepIndices) ?? []
        checkedStepIndices = Set(savedIndices.filter { steps.indices.contains($0) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encode(steps, forKey: .steps)
        if timedStepSeconds.contains(where: { $0 != nil }) {
            try container.encode(timedStepSeconds, forKey: .timedStepSeconds)
        }
        try container.encode(length, forKey: .length)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encode(checkedStepIndices.sorted(), forKey: .checkedStepIndices)
    }

    var statusWhenStartingWorkingSets: WorkoutWarmUpStatus {
        if checkedStepIndices.isEmpty { return .skipped }
        return checkedStepIndices.count == steps.count ? .completed : .partial
    }

    func timerSeconds(forStepAt index: Int) -> Int? {
        guard timedStepSeconds.indices.contains(index) else { return nil }
        return timedStepSeconds[index]
    }

    mutating func toggleStep(at index: Int) {
        guard status == .pending, steps.indices.contains(index) else { return }
        if !checkedStepIndices.insert(index).inserted {
            checkedStepIndices.remove(index)
        }
    }

    mutating func resolve(as status: WorkoutWarmUpStatus, at date: Date) {
        guard self.status == .pending, status != .pending else { return }
        self.status = status
        resolvedAt = date
    }

    func configured(for length: WorkoutWarmUpLength, at date: Date) -> WorkoutWarmUp {
        guard status == .pending else { return self }
        switch length {
        case .full:
            return self
        case .short:
            return WorkoutWarmUp(
                estimatedMinutes: max(2, estimatedMinutes - 2),
                steps: Array(steps.suffix(2)),
                timedStepSeconds: Array(timedStepSeconds.suffix(2)),
                length: .short
            )
        case .none:
            var skipped = WorkoutWarmUp(estimatedMinutes: 0, steps: [], length: .none)
            skipped.resolve(as: .skipped, at: date)
            return skipped
        }
    }
}

struct WorkoutSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let programmeID: WorkoutProgrammeID?
    let programmeProvenance: WorkoutProgrammeProvenance?
    // Nil for authored programmes. An explicit ID identifies user-built sessions
    // without relaxing recovery checks for older malformed snapshots.
    let customWorkoutID: UUID?
    let targetDurationMinutes: Int?
    let isAdapted: Bool
    private(set) var warmUp: WorkoutWarmUp?
    private(set) var exercises: [WorkoutExercise]
    private(set) var currentExerciseIndex: Int
    private(set) var restEndsAt: Date?
    private(set) var activeRestDuration: TimeInterval?
    private(set) var completedAt: Date?
    // Explicit final review, not inferred from reaching the last set or relaunch.
    private(set) var executionCompletionConfirmedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        programmeID: WorkoutProgrammeID? = nil,
        programmeProvenance: WorkoutProgrammeProvenance? = nil,
        customWorkoutID: UUID? = nil,
        targetDurationMinutes: Int? = nil,
        isAdapted: Bool = false,
        warmUp: WorkoutWarmUp? = nil,
        exercises: [WorkoutExercise],
        currentExerciseIndex: Int = 0,
        restEndsAt: Date? = nil,
        activeRestDuration: TimeInterval? = nil,
        completedAt: Date? = nil,
        executionCompletionConfirmedAt: Date? = nil
    ) {
        precondition(!exercises.isEmpty, "A workout session needs at least one exercise.")
        precondition(exercises.indices.contains(currentExerciseIndex), "Current exercise index is out of bounds.")

        self.id = id
        self.title = title
        self.programmeID = programmeID
        self.programmeProvenance = programmeProvenance
        self.customWorkoutID = customWorkoutID
        self.targetDurationMinutes = targetDurationMinutes
        self.isAdapted = isAdapted
        self.warmUp = warmUp
        self.exercises = exercises
        self.currentExerciseIndex = currentExerciseIndex
        self.restEndsAt = restEndsAt
        self.activeRestDuration = activeRestDuration
        self.completedAt = completedAt
        self.executionCompletionConfirmedAt = executionCompletionConfirmedAt
    }

    var currentExercise: WorkoutExercise? {
        guard !isComplete, exercises.indices.contains(currentExerciseIndex) else { return nil }
        return exercises[currentExerciseIndex]
    }

    var currentSetNumber: Int? {
        currentExercise.map { $0.completedSets.count + 1 }
    }

    var totalPlannedSetCount: Int {
        exercises.reduce(0) { $0 + $1.plan.plannedSetCount }
    }

    var completedSetCount: Int {
        exercises.reduce(0) { $0 + $1.completedSets.count }
    }

    /// The saved-set identity to use for confirmation or Undo, even after the
    /// active index has advanced to an exercise with no logged sets yet.
    var latestCompletedSetID: UUID? {
        exercises.last(where: { !$0.completedSets.isEmpty })?.completedSets.last?.id
    }

    var isComplete: Bool {
        completedAt != nil
    }

    var endedEarly: Bool {
        isComplete && completedSetCount < totalPlannedSetCount
    }

    var requiresWarmUp: Bool {
        warmUp?.status == .pending
    }

    mutating func resolveWarmUp(as status: WorkoutWarmUpStatus, at date: Date) {
        guard !isComplete else { return }
        warmUp?.resolve(as: status, at: date)
    }

    mutating func selectWarmUpLength(_ length: WorkoutWarmUpLength, at date: Date) {
        guard !isComplete, completedSetCount == 0,
              let current = warmUp, current.status == .pending,
              current.length == .full, current.checkedStepIndices.isEmpty else { return }
        warmUp = current.configured(for: length, at: date)
    }

    mutating func toggleWarmUpStep(at index: Int) {
        guard !isComplete else { return }
        warmUp?.toggleStep(at: index)
    }

    /// Change only the current, unstarted exercise. The caller supplies a new load;
    /// the previous exercise's load and performance must not be inferred for it.
    mutating func substituteCurrentExercise(
        with alternativeID: ExerciseID,
        load: Load,
        input: WorkoutSubstitutionInput? = nil
    ) throws {
        guard !isComplete else { throw WorkoutSubstitutionError.workoutCompleted }
        guard !requiresWarmUp else { throw WorkoutSubstitutionError.warmUpPending }
        guard let current = currentExercise, current.completedSets.isEmpty else {
            throw WorkoutSubstitutionError.exerciseAlreadyStarted
        }
        guard ExerciseSubstitutionCuration.authoredAlternativeIDs(for: current.plan).contains(alternativeID),
              let alternative = ExerciseLibrary.exercise(id: alternativeID),
              let target = ExerciseSubstitutionCuration.target(for: alternative) else {
            throw WorkoutSubstitutionError.unavailableAlternative
        }
        guard input?.isValid ?? true,
              load.unit == current.plan.targetLoad.unit,
              load.value.isFinite,
              load.value >= 0,
              (load.value > 0 || alternative.equipment.contains(.bodyweight)) else {
            throw WorkoutSubstitutionError.invalidLoad
        }

        let original = current.originalPlan ?? current.plan
        let replacement = ExercisePlan(
            id: current.plan.id,
            exerciseID: alternative.id,
            name: alternative.name,
            targetLoad: load,
            targetReps: alternative.defaultRepRange,
            plannedSetCount: current.plan.plannedSetCount,
            restSeconds: current.plan.restSeconds,
            previousPerformance: [],
            coachingCue: alternative.shortCoachingCue,
            painGuardrail: alternative.painGuardrail,
            equipmentIdentifiers: alternative.equipmentIdentifiers,
            alternativeExerciseIDs: alternative.resolvedAlternativeIDs,
            unresolvedAlternativeNames: alternative.unresolvedAlternativeNames,
            targetPrescription: target
        )
        exercises[currentExerciseIndex] = WorkoutExercise(plan: replacement, originalPlan: original,
            substitutionInput: current.substitutionInput ?? input)
    }

    @discardableResult
    mutating func undoCurrentSubstitution() -> Bool {
        guard !isComplete, let current = currentExercise,
              current.completedSets.isEmpty, let original = current.originalPlan else { return false }
        exercises[currentExerciseIndex] = WorkoutExercise(plan: original)
        return true
    }

    /// End an in-progress workout without inventing an unlogged set.
    /// A completed session can be retried with the same identity and set data.
    @discardableResult
    mutating func finishEarly(at date: Date) -> Bool {
        if isComplete { return true }
        guard completedSetCount > 0 else { return false }
        recordRestTransition(.workoutEnded, at: date)
        restEndsAt = nil
        activeRestDuration = nil
        completedAt = date
        executionCompletionConfirmedAt = nil
        return true
    }

    /// Only the person's final review can acknowledge the whole execution.
    /// A retry retains the original confirmation identity and time.
    @discardableResult
    mutating func confirmCompletedExecution(at date: Date) -> Bool {
        guard let completedAt, date.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite, date >= completedAt,
              exercises.allSatisfy({ $0.completedSets.count == $0.plan.plannedSetCount }) else { return false }
        if executionCompletionConfirmedAt == nil { executionCompletionConfirmedAt = date }
        return true
    }

    func remainingRestSeconds(at date: Date) -> Int {
        guard let restEndsAt else { return 0 }
        return max(0, Int(ceil(restEndsAt.timeIntervalSince(date))))
    }

    func isResting(at date: Date) -> Bool {
        remainingRestSeconds(at: date) > 0
    }

    mutating func skipRest(at date: Date = .now, handoffAcknowledged: Bool = false) {
        let expired = !latestRestObservationIsPaused && restEndsAt.map({ $0 <= date }) == true
        recordRestTransition(handoffAcknowledged ? .handoffAcknowledged : (expired ? .expired : .skipped), at: date)
        restEndsAt = nil
        activeRestDuration = nil
    }

    mutating func extendRest(by seconds: TimeInterval, at date: Date = .now) {
        guard seconds.isFinite, seconds > 0, let restEndsAt else { return }
        self.restEndsAt = restEndsAt.addingTimeInterval(seconds)
        activeRestDuration = (activeRestDuration ?? 0) + seconds
        recordRestTransition(.extended, at: date, remainingSeconds: max(0, self.restEndsAt!.timeIntervalSince(date)))
    }

    mutating func shortenRest(by seconds: TimeInterval, at date: Date) {
        guard seconds > 0, let restEndsAt, restEndsAt > date else { return }
        let newEnd = max(date, restEndsAt.addingTimeInterval(-seconds))
        self.restEndsAt = newEnd
        activeRestDuration = max(0, (activeRestDuration ?? 0) - restEndsAt.timeIntervalSince(newEnd))
        recordRestTransition(.shortened, at: date, remainingSeconds: newEnd.timeIntervalSince(date))
    }

    mutating func pauseRest(at date: Date) {
        guard let restEndsAt else { return }
        if restEndsAt <= date {
            recordRestTransition(.expired, at: date)
        } else {
            recordRestTransition(.paused, at: date, remainingSeconds: restEndsAt.timeIntervalSince(date))
        }
    }

    mutating func extendPausedRest(by seconds: TimeInterval, at date: Date) {
        guard seconds.isFinite, seconds > 0 else { return }
        if let remaining = latestRestObservation?.precisePausedRemainingSeconds {
            recordRestTransition(.extendedWhilePaused, at: date, remainingSeconds: remaining + seconds)
        } else if latestRestObservation?.isClosed == true {
            restEndsAt = nil
            recordRestTransition(.restartedWhilePaused, at: date, remainingSeconds: seconds)
        }
    }

    mutating func resumeRest(remainingSeconds: Int, at date: Date, afterFailedSave: Bool = false) {
        let exactRemaining = afterFailedSave ? TimeInterval(remainingSeconds)
            : (latestRestObservation?.precisePausedRemainingSeconds ?? TimeInterval(remainingSeconds))
        guard exactRemaining > 0 else {
            skipRest(at: date)
            return
        }

        restEndsAt = date.addingTimeInterval(exactRemaining)
        activeRestDuration = max(activeRestDuration ?? 0, exactRemaining)
        recordRestTransition(afterFailedSave ? .restartedAfterSaveFailure : .resumed,
            at: date, remainingSeconds: exactRemaining)
    }

    private var latestRestObservation: WorkoutRestTimerObservation? {
        exercises.last(where: { !$0.completedSets.isEmpty })?.completedSets.last?.restTimerObservation
    }
    private var latestRestObservationIsPaused: Bool { latestRestObservation?.isPaused == true }

    mutating func markRestObservationRecovered(at date: Date) {
        recordRestTransition(.recovered, at: date)
    }

    private mutating func recordRestTransition(_ kind: WorkoutRestTimerEvent.Kind, at date: Date,
                                               remainingSeconds: TimeInterval? = nil) {
        guard let exerciseIndex = exercises.lastIndex(where: { !$0.completedSets.isEmpty }),
              let setIndex = exercises[exerciseIndex].completedSets.indices.last else { return }
        // Missing legacy evidence cannot be reconstructed from countdown fields.
        exercises[exerciseIndex].completedSets[setIndex].restTimerObservation?.record(kind,
            at: date, deadline: restEndsAt, remainingSeconds: remainingSeconds)
    }

    mutating func completeCurrentSet(
        load: Load,
        reps: Int,
        rir: Int? = nil,
        durationSeconds: Int? = nil,
        at date: Date
    ) throws -> SetCompletionResult {
        guard !isComplete else { throw WorkoutCompletionError.workoutCompleted }
        guard !requiresWarmUp else { throw WorkoutCompletionError.warmUpPending }
        guard !isResting(at: date) else { throw WorkoutCompletionError.restInProgress }
        guard !latestRestObservationIsPaused else { throw WorkoutCompletionError.restInProgress }
        guard load.value.isFinite, load.value >= 0 else { throw WorkoutCompletionError.invalidLoad }
        guard exercises.indices.contains(currentExerciseIndex) else { throw WorkoutCompletionError.noCurrentExercise }
        let currentPlan = exercises[currentExerciseIndex].plan
        guard load.value > 0 || currentPlan.allowsZeroLoad else {
            throw WorkoutCompletionError.invalidLoad
        }
        if currentPlan.isTimed {
            guard let durationSeconds, (1 ... 86_400).contains(durationSeconds), reps == 0, rir == nil else {
                throw WorkoutCompletionError.invalidDuration
            }
        } else {
            guard reps > 0, durationSeconds == nil else { throw WorkoutCompletionError.invalidReps }
        }
        guard rir.map({ 0 ... 5 ~= $0 }) ?? true else { throw WorkoutCompletionError.invalidRIR }

        if restEndsAt != nil { skipRest(at: date) }
        let setID = UUID()
        let hasFollowingSet = exercises[currentExerciseIndex].completedSets.count + 1 < currentPlan.plannedSetCount
            || exercises.indices.contains(currentExerciseIndex + 1)
        let timerDeadline = hasFollowingSet && currentPlan.restSeconds > 0
            ? date.addingTimeInterval(currentPlan.restSeconds) : nil

        exercises[currentExerciseIndex].completedSets.append(
            CompletedSet(id: setID, load: load, reps: reps, rir: rir, completedAt: date,
                         durationSeconds: durationSeconds, isPerSide: currentPlan.targetPrescription?.perSide,
                         executionTarget: WorkingSetExecutionTarget(plan: currentPlan),
                         restTimerObservation: WorkoutRestTimerObservation(afterSetID: setID, at: date, deadline: timerDeadline))
        )

        let completedExercise = exercises[currentExerciseIndex]
        let hasAnotherSetInExercise = completedExercise.completedSets.count < completedExercise.plan.plannedSetCount
        if hasAnotherSetInExercise {
            restEndsAt = date.addingTimeInterval(completedExercise.plan.restSeconds)
            activeRestDuration = completedExercise.plan.restSeconds
            return .advancedToNextSet
        }

        let nextExerciseIndex = currentExerciseIndex + 1
        if exercises.indices.contains(nextExerciseIndex) {
            currentExerciseIndex = nextExerciseIndex
            restEndsAt = date.addingTimeInterval(completedExercise.plan.restSeconds)
            activeRestDuration = completedExercise.plan.restSeconds
            return .advancedToNextExercise
        }

        restEndsAt = nil
        activeRestDuration = nil
        completedAt = date
        return .workoutCompleted
    }

    /// Reopen the most recently logged set before the workout is finalized.
    /// The active exercise may already point at the next exercise.
    @discardableResult
    mutating func undoLastSet(
        expectedSetID: UUID? = nil,
        reopeningFinalSet: Bool = false
    ) -> CompletedSet? {
        guard (!isComplete || reopeningFinalSet), completedSetCount > 0 else { return nil }
        let index = exercises[currentExerciseIndex].completedSets.isEmpty
            ? currentExerciseIndex - 1 : currentExerciseIndex
        guard exercises.indices.contains(index),
              let latest = exercises[index].completedSets.last,
              expectedSetID.map({ $0 == latest.id }) ?? true else { return nil }
        if isComplete { completedAt = nil }
        executionCompletionConfirmedAt = nil
        let removed = exercises[index].completedSets.removeLast()
        currentExerciseIndex = index
        // The removed set owned this interval. Never alter the preceding set's
        // already closed observation while removing the latest set.
        restEndsAt = nil
        activeRestDuration = nil
        return removed
    }
}

struct ActiveWorkoutSnapshot: Codable, Equatable, Sendable {
    // Version7 introduces programme provenance;6 introduced rest observations.
    // Older snapshots retain unknown source facts without reconstructing them.
    static let currentVersion = 8

    let version: Int
    var session: WorkoutSession
    let enteredLoadValue: Double
    let enteredReps: Int
    // Version 1 encoded an Int. Optional decoding retains that value while new
    // sessions can explicitly represent effort that was never reported.
    let enteredRIR: Int?
    let durationDraft: String?
    // Optional for v1/v2 snapshots. A new zero-rest transition writes true.
    var awaitingNextSetAcknowledgement: Bool?
    let isPaused: Bool
    let pausedRemainingRestSeconds: Int?
    let pendingAdaptation: WorkoutAdaptationProposal?
    let sessionBeforeAdaptation: WorkoutSession?
    let lastSetGuidance: SetEffortGuidance?
    // A completed final set can be reviewed and undone before History commits.
    // Nil means older snapshots using the established automatic reconciliation.
    let awaitingFinalSetConfirmation: Bool?
    let progressionOfferSelections: [UUID: WorkoutLoadChoiceSelection]?
    let progressionOfferPreparedExerciseIDs: Set<UUID>?
    // Optional for existing recovery snapshots. An offered progression cannot
    // return after its first working set is saved and then undone.
    let progressionOfferConsumedExerciseIDs: Set<UUID>?
    // Version 8: optional observed session time, never inferred for older sessions.
    let elapsedEvidence: WorkoutElapsedEvidence?

    init(
        version: Int = currentVersion,
        session: WorkoutSession,
        enteredLoadValue: Double,
        enteredReps: Int,
        enteredRIR: Int?,
        durationDraft: String? = nil,
        awaitingNextSetAcknowledgement: Bool? = nil,
        isPaused: Bool,
        pausedRemainingRestSeconds: Int?,
        pendingAdaptation: WorkoutAdaptationProposal?,
        sessionBeforeAdaptation: WorkoutSession?,
        lastSetGuidance: SetEffortGuidance?,
        awaitingFinalSetConfirmation: Bool? = nil,
        progressionOfferSelections: [UUID: WorkoutLoadChoiceSelection]? = nil,
        progressionOfferPreparedExerciseIDs: Set<UUID>? = nil,
        progressionOfferConsumedExerciseIDs: Set<UUID>? = nil,
        elapsedEvidence: WorkoutElapsedEvidence? = nil
    ) {
        self.version = version
        self.session = session
        self.enteredLoadValue = enteredLoadValue
        self.enteredReps = enteredReps
        self.enteredRIR = enteredRIR
        self.durationDraft = durationDraft
        self.awaitingNextSetAcknowledgement = awaitingNextSetAcknowledgement
        self.isPaused = isPaused
        self.pausedRemainingRestSeconds = pausedRemainingRestSeconds
        self.pendingAdaptation = pendingAdaptation
        self.sessionBeforeAdaptation = sessionBeforeAdaptation
        self.lastSetGuidance = lastSetGuidance
        self.awaitingFinalSetConfirmation = awaitingFinalSetConfirmation
        self.progressionOfferSelections = progressionOfferSelections
        self.progressionOfferPreparedExerciseIDs = progressionOfferPreparedExerciseIDs
        self.progressionOfferConsumedExerciseIDs = progressionOfferConsumedExerciseIDs
        self.elapsedEvidence = elapsedEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case version, session, enteredLoadValue, enteredReps, enteredRIR, durationDraft
        case awaitingNextSetAcknowledgement, isPaused, pausedRemainingRestSeconds
        case pendingAdaptation, sessionBeforeAdaptation, lastSetGuidance
        case awaitingFinalSetConfirmation, progressionOfferSelections
        case progressionOfferPreparedExerciseIDs, progressionOfferConsumedExerciseIDs, elapsedEvidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        session = try values.decode(WorkoutSession.self, forKey: .session)
        enteredLoadValue = try values.decode(Double.self, forKey: .enteredLoadValue)
        enteredReps = try values.decode(Int.self, forKey: .enteredReps)
        durationDraft = try values.decodeIfPresent(String.self, forKey: .durationDraft)
        // Version 1 always wrote a concrete Int. A missing value there is
        // corruption, while version 2+ can faithfully mean "not reported".
        if version == 1 {
            enteredRIR = try values.decode(Int.self, forKey: .enteredRIR)
        } else {
            enteredRIR = try values.decodeIfPresent(Int.self, forKey: .enteredRIR)
        }
        awaitingNextSetAcknowledgement = try values.decodeIfPresent(
            Bool.self, forKey: .awaitingNextSetAcknowledgement
        )
        isPaused = try values.decode(Bool.self, forKey: .isPaused)
        pausedRemainingRestSeconds = try values.decodeIfPresent(Int.self, forKey: .pausedRemainingRestSeconds)
        pendingAdaptation = try values.decodeIfPresent(WorkoutAdaptationProposal.self, forKey: .pendingAdaptation)
        sessionBeforeAdaptation = try values.decodeIfPresent(WorkoutSession.self, forKey: .sessionBeforeAdaptation)
        lastSetGuidance = try values.decodeIfPresent(SetEffortGuidance.self, forKey: .lastSetGuidance)
        awaitingFinalSetConfirmation = try values.decodeIfPresent(
            Bool.self, forKey: .awaitingFinalSetConfirmation
        )
        progressionOfferSelections = try values.decodeIfPresent(
            [UUID: WorkoutLoadChoiceSelection].self, forKey: .progressionOfferSelections
        )
        progressionOfferPreparedExerciseIDs = try values.decodeIfPresent(
            Set<UUID>.self, forKey: .progressionOfferPreparedExerciseIDs
        )
        progressionOfferConsumedExerciseIDs = try values.decodeIfPresent(
            Set<UUID>.self, forKey: .progressionOfferConsumedExerciseIDs
        )
        elapsedEvidence = try values.decodeIfPresent(WorkoutElapsedEvidence.self, forKey: .elapsedEvidence)
    }

    /// Preserve the exact stored payload while rejecting ambiguous raw keys before decoding.
    static func validateJSON(_ data: Data) throws {
        do {
            var syntax = ImportJSONSyntax(data: data)
            try syntax.validate()
        } catch {
            throw WorkoutPersistenceError.invalidSnapshot
        }
    }

    var isCompatible: Bool {
        (1 ... Self.currentVersion).contains(version)
            && (elapsedEvidence.map {
                version >= 8 && $0.matches(sessionID: session.id, isPaused: isPaused, isComplete: session.isComplete)
            } ?? true)
            && !session.exercises.isEmpty
            && session.exercises.indices.contains(session.currentExerciseIndex)
            && ((session.programmeID != nil) != (session.customWorkoutID != nil))
            && (session.programmeProvenance.map {
                version >= 7 && $0.matches(programmeID: session.programmeID, occurrenceIDs: session.exercises.map(\.id))
            } ?? true)
            && (session.warmUp?.status != .pending || session.completedSetCount == 0)
            && enteredLoadValue.isFinite && enteredLoadValue >= 0
            && (1 ... 50).contains(enteredReps)
            && (enteredRIR.map { (0 ... 5).contains($0) } ?? true)
            && (session.executionCompletionConfirmedAt.map { confirmed in
                confirmed.timeIntervalSinceReferenceDate.isFinite
                    && session.completedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && confirmed >= $0 }) == true
                    && session.exercises.allSatisfy({ $0.completedSets.count == $0.plan.plannedSetCount })
                    && awaitingFinalSetConfirmation != true
            } ?? true)
            && session.exercises.allSatisfy({ exercise in
                (exercise.substitutionInput.map { $0.isValid && exercise.originalPlan != nil } ?? true)
                && exercise.completedSets.allSatisfy { set in
                    (set.restTimerObservation.map {
                        version >= 6 && $0.isValid(for: set.id, completedAt: set.completedAt)
                    } ?? true) && (set.executionTarget.map {
                        $0.matches(set, exerciseID: exercise.plan.exerciseID, occurrenceID: exercise.id)
                    } ?? true)
                }
            })
            && [sessionBeforeAdaptation, pendingAdaptation?.originalSession, pendingAdaptation?.adaptedSession]
                .compactMap({ $0 }).allSatisfy({ saved in
                    (saved.programmeProvenance.map {
                        version >= 7 && $0.matches(programmeID: saved.programmeID, occurrenceIDs: saved.exercises.map(\.id))
                    } ?? true) && saved.exercises.flatMap(\.completedSets).allSatisfy { set in
                        set.restTimerObservation.map {
                            version >= 6 && $0.isValid(for: set.id, completedAt: set.completedAt)
                        } ?? true
                    }
                })
            && (!(awaitingFinalSetConfirmation ?? false)
                || (session.isComplete && session.completedSetCount == session.totalPlannedSetCount))
            && (!(awaitingNextSetAcknowledgement ?? false) || (!session.isComplete && session.completedSetCount > 0))
            && (!isPaused || pausedRemainingRestSeconds != nil)
    }

    mutating func resolveElapsedRest(at date: Date) {
        if version < 3, awaitingNextSetAcknowledgement == nil,
           !session.isComplete, session.completedSetCount > 0,
           session.activeRestDuration == 0 {
            awaitingNextSetAcknowledgement = true
        }
        guard !isPaused, session.remainingRestSeconds(at: date) == 0 else { return }
        // Keep the deadline through decoding. Foreground reconciliation opens
        // the next set in the same exercise; an exercise handoff still waits
        // for an explicit tap. Neither recovery path logs a set.
        if session.restEndsAt != nil, !session.isComplete,
           session.completedSetCount > 0 {
            awaitingNextSetAcknowledgement = true
        } else if awaitingNextSetAcknowledgement != true {
            session.skipRest()
        }
    }
}

protocol ActiveWorkoutPersisting {
    func load() throws -> ActiveWorkoutSnapshot?
    func save(_ snapshot: ActiveWorkoutSnapshot) throws
    func clear(expectedSessionID: UUID) throws
}

struct UserDefaultsActiveWorkoutStore: ActiveWorkoutPersisting {
    private let defaults: UserDefaults
    private let key: String
    private let shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    init(defaults: UserDefaults = .standard, key: String = "slick.activeWorkout",
         shareRevocationRegistration: ZeroOneShareRevocationRegistration? = nil) {
        shareRevocationRegistration?.revokeBeforeChange()
        self.defaults = defaults
        self.key = key
        self.shareRevocationRegistration = shareRevocationRegistration
    }

    /// A value-type store installs its immutable capability at construction.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    func load() throws -> ActiveWorkoutSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        try ActiveWorkoutSnapshot.validateJSON(data)
        let snapshot = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: data)
        guard snapshot.isCompatible else { throw WorkoutPersistenceError.invalidSnapshot }
        return snapshot
    }

    func save(_ snapshot: ActiveWorkoutSnapshot) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard snapshot.isCompatible else { throw WorkoutPersistenceError.invalidSnapshot }
        if let existing = try load(), existing.session.id != snapshot.session.id {
            throw WorkoutPersistenceError.conflictingSession
        }
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
    }

    func clear(expectedSessionID: UUID) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        if let existing = try load(), existing.session.id != expectedSessionID {
            throw WorkoutPersistenceError.conflictingSession
        }
        defaults.removeObject(forKey: key)
    }
}

struct FileActiveWorkoutStore: ActiveWorkoutPersisting {
    let directory: URL?
    let legacyStore: any ActiveWorkoutPersisting
    private let shareRevocationRegistration: ZeroOneShareRevocationRegistration?

    init(directory: URL? = nil, legacyStore: any ActiveWorkoutPersisting = UserDefaultsActiveWorkoutStore(),
         shareRevocationRegistration: ZeroOneShareRevocationRegistration? = nil) {
        shareRevocationRegistration?.revokeBeforeChange()
        self.directory = directory
        self.legacyStore = legacyStore
        self.shareRevocationRegistration = shareRevocationRegistration
    }

    /// Match this exact constructed store; a replacement must be installed by Root.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    func load() throws -> ActiveWorkoutSnapshot? {
        let url = try WorkoutPersistenceFiles.file("active-workout.json", directory: directory)
        guard let data = try WorkoutPersistenceFiles.readIfPresent(url) else { return try legacyStore.load() }
        try ActiveWorkoutSnapshot.validateJSON(data)
        let snapshot = try JSONDecoder().decode(ActiveWorkoutSnapshot?.self, from: data)
        if let snapshot, !snapshot.isCompatible { throw WorkoutPersistenceError.invalidSnapshot }
        return snapshot
    }

    func save(_ snapshot: ActiveWorkoutSnapshot) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        guard snapshot.isCompatible else { throw WorkoutPersistenceError.invalidSnapshot }
        try write(snapshot, expectedSessionID: snapshot.session.id)
    }

    func clear(expectedSessionID: UUID) throws {
        shareRevocationRegistration?.revokeBeforeChange()
        // Persist a tombstone instead of deleting: the untouched legacy snapshot must not resurrect.
        try write(nil, expectedSessionID: expectedSessionID)
    }

    private func write(_ snapshot: ActiveWorkoutSnapshot?, expectedSessionID: UUID) throws {
        // Neither a new session nor a stale view model may replace or clear another session.
        if let existing = try load(), existing.session.id != expectedSessionID {
            throw WorkoutPersistenceError.conflictingSession
        }
        let data = try JSONEncoder().encode(snapshot)
        try WorkoutPersistenceFiles.write(data, to: WorkoutPersistenceFiles.file("active-workout.json", directory: directory))
    }
}
