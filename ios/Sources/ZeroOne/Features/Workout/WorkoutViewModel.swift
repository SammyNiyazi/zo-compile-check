import Foundation
import Observation

@MainActor
@Observable
final class WorkoutViewModel {
    private(set) var session: WorkoutSession {
        willSet { shareRevocationRegistration?.revokeBeforeChange() }
        didSet { if oldValue.id != session.id { invalidateElapsedEvidence() } }
    }
    private(set) var completionError: WorkoutCompletionError?
    private(set) var pendingAdaptation: WorkoutAdaptationProposal?
    private(set) var adaptationError: WorkoutAdaptationError?
    private(set) var pendingDemandAdaptation: WorkoutDemandAdaptationProposal?
    private(set) var demandAdaptationError: WorkoutDemandAdaptationError?
    private(set) var lastSetGuidance: SetEffortGuidance?
    private(set) var isPaused = false
    private(set) var persistenceErrorMessage: String? {
        willSet { shareRevocationRegistration?.revokeBeforeChange() }
    }
    private(set) var inputErrorMessage: String?
    private(set) var isCompletionSaved = false {
        willSet { shareRevocationRegistration?.revokeBeforeChange() }
    }
    /// Set only after both History and active-snapshot cleanup acknowledge completion.
    private(set) var lastCompletionRecordResult: WorkoutHistoryRecordResult?
    private(set) var completionFeedbackCount = 0
    private(set) var awaitingFinalSetConfirmation = false
    private(set) var awaitingNextSetAcknowledgement = false
    private(set) var persistedActivity: WorkoutActivityProjection?
    // Only the exact acknowledged snapshot may publish elapsed evidence.
    private(set) var confirmedElapsedEvidence: WorkoutElapsedEvidence?
    private var elapsedEvidence: WorkoutElapsedEvidence?
    private var elapsedEvidenceInvalidated = false
    @ObservationIgnored private let elapsedClock: WorkoutElapsedClock
    private(set) var progressionOfferSelections: [UUID: WorkoutLoadChoiceSelection]
    private(set) var progressionOfferPreparedExerciseIDs: Set<UUID>
    private(set) var progressionOfferConsumedExerciseIDs: Set<UUID>
    /// Shown only after an Undo has been persisted. Cleared by the next logged set.
    private(set) var undoNotice: String?
    // Recomputed from current recovery/fuelling evidence by the app owner.
    // It controls advice, never rewrites performed sets or the person's drafts.
    var progressionRecommendationsAllowed = true
    var enteredLoadValue: Double {
        didSet { persistSnapshot() }
    }
    var enteredReps: Int {
        didSet { persistSnapshot() }
    }
    var durationDraft: String {
        didSet { persistSnapshot() }
    }
    var isTimedSet: Bool { session.currentExercise?.plan.isTimed == true }

    var enteredRIR: Int? {
        didSet { persistSnapshot() }
    }
    var loadDraft: String {
        didSet {
            if let value = Self.parsedLoad(loadDraft), value != enteredLoadValue {
                enteredLoadValue = value
            }
        }
    }
    var repsDraft: String {
        didSet {
            if let value = Self.parsedReps(repsDraft), value != enteredReps {
                enteredReps = value
            }
        }
    }

    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private let workoutAdapter: DeterministicWorkoutAdapter
    private let effortGuidance: DeterministicSetEffortGuidance
    private let onSessionCompleted: (WorkoutSession) throws -> WorkoutHistoryRecordResult
    private let onSnapshotChanged: (ActiveWorkoutSnapshot?, UUID) throws -> Void
    private let progressionValidator: @MainActor (ExercisePlan, WorkoutProgressionOpportunity) -> Bool
    private let restoredCompletedSnapshot: ActiveWorkoutSnapshot?
    private let requiresFinalSetReview: Bool
    private var sessionBeforeAdaptation: WorkoutSession?
    private var pausedRemainingRestSeconds: Int?
    private var pendingCompletionPresentation = false
    private var acknowledgementFieldWasAbsent = false
    private var warmUpDecisionPendingSave = false
    private var isBatchingInputChanges = false

    /// Pre-change invalidation only. Missing registration never proves export readiness.
    /// Replace/remove before changing the retained model's presentation owner.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    var requiresWarmUpGate: Bool {
        session.requiresWarmUp || warmUpDecisionPendingSave
    }

    func canShowProgressionOffer(for exercise: WorkoutExercise) -> Bool {
        progressionRecommendationsAllowed && exercise.completedSets.isEmpty
            && !progressionOfferConsumedExerciseIDs.contains(exercise.plan.id)
    }

    /// The working set remains in the in-memory session after a failed snapshot
    /// write, but must not be presented as saved until persistence confirms it.
    var unconfirmedWorkingSet: (exerciseName: String, number: Int, set: CompletedSet)? {
        guard persistenceErrorMessage != nil, !isCompletionSaved,
              session.completedSetCount > (persistedActivity?.state.completedSets ?? 0),
              let exercise = session.exercises.last(where: { !$0.completedSets.isEmpty }),
              let set = exercise.completedSets.last else { return nil }
        return (exercise.plan.name, exercise.completedSets.count, set)
    }

    /// A held working set names itself; any other interrupted write stays generic.
    var persistenceFailureTitle: String {
        guard !session.isComplete, let pending = unconfirmedWorkingSet else {
            return "Your workout is still here."
        }
        return "Set \(pending.number) was not saved."
    }

    var retryActionTitle: String {
        guard !session.isComplete, let pending = unconfirmedWorkingSet else { return "Retry Save" }
        return "Try again: log set \(pending.number)"
    }

    /// The role of the single primary action at the bottom of the workout.
    var dockRole: WorkoutDockRole {
        if session.isComplete {
            if isCompletionSaved { return .finished }
            return awaitingFinalSetConfirmation && persistenceErrorMessage == nil ? .finalReview : .retry
        }
        if persistenceErrorMessage != nil { return .retry }
        if requiresWarmUpGate { return .warmUp }
        if isPaused { return .paused }
        guard let setNumber = session.currentSetNumber else { return .retry }
        if session.restEndsAt != nil || awaitingNextSetAcknowledgement {
            return .rest(exerciseIndex: session.currentExerciseIndex, nextSetNumber: setNumber)
        }
        return .logSet(exerciseIndex: session.currentExerciseIndex, setNumber: setNumber)
    }

    func primaryAction(at date: Date) -> WorkoutPrimaryAction? {
        switch dockRole {
        case let .logSet(_, setNumber):
            return .logSet(number: setNumber)
        case let .rest(_, setNumber):
            // A same-exercise timed rest stays a drained line until the model
            // advances it, so the dock never offers a Start that auto-advance
            // would replace within the same second.
            if let deadline = session.restEndsAt,
               remainingRestSeconds(at: date) > 0 || restAdvancesAutomatically {
                return .rest(deadline: deadline, duration: session.activeRestDuration ?? 0)
            }
            return .startSet(number: setNumber, exerciseName: session.currentExercise?.plan.name ?? "exercise")
        default:
            return nil
        }
    }

    var canSubstituteCurrentExercise: Bool {
        !session.isComplete && !requiresWarmUpGate && !isPaused
            && !awaitingNextSetAcknowledgement && persistenceErrorMessage == nil
            && session.currentExercise?.completedSets.isEmpty == true
    }

    var substitutionInput: WorkoutSubstitutionInput {
        .init(loadDraft: loadDraft, repsDraft: repsDraft, durationDraft: durationDraft,
            load: enteredLoadValue, reps: enteredReps, rir: enteredRIR)
    }

    @discardableResult
    func substituteCurrentExercise(with id: ExerciseID, load: Load, review: ExerciseSubstitutionReview,
                                   context: ExerciseSubstitutionContext, confirmedAt: Date?,
                                   at now: Date = .now, calendar: Calendar = .current,
                                   availableVideoIDs: Set<String> = MoveKitExercise.availableVideoIDs) throws -> Bool {
        guard canSubstituteCurrentExercise else { throw ExerciseSubstitutionSelectionError.activeState }
        _ = try ExerciseSubstitutionSelector().revalidated(review, selected: id, session: session,
            input: substitutionInput, context: context, availableVideoIDs: availableVideoIDs,
            confirmedAt: confirmedAt, at: now, calendar: calendar)
        let beforeInput = substitutionInput
        var updated = session
        var updatedBeforeAdaptation = sessionBeforeAdaptation
        do {
            try updated.substituteCurrentExercise(with: id, load: load, input: beforeInput)
            if var original = updatedBeforeAdaptation {
                try original.substituteCurrentExercise(with: id, load: load, input: beforeInput)
                updatedBeforeAdaptation = original
            }
        } catch {
            return false
        }

        session = updated
        sessionBeforeAdaptation = updatedBeforeAdaptation
        pendingAdaptation = nil
        isBatchingInputChanges = true
        prepareInputsForCurrentSet()
        isBatchingInputChanges = false
        persistSnapshot()
        return persistenceErrorMessage == nil
    }

    @discardableResult
    func undoCurrentSubstitution() -> Bool {
        guard canSubstituteCurrentExercise else { return false }
        let originalInput = session.currentExercise?.substitutionInput
        var updated = session
        guard updated.undoCurrentSubstitution() else { return false }
        var updatedBeforeAdaptation = sessionBeforeAdaptation
        if var original = updatedBeforeAdaptation {
            guard original.undoCurrentSubstitution() else { return false }
            updatedBeforeAdaptation = original
        }

        session = updated
        sessionBeforeAdaptation = updatedBeforeAdaptation
        pendingAdaptation = nil
        isBatchingInputChanges = true
        prepareInputsForCurrentSet()
        if let originalInput {
            enteredLoadValue = originalInput.load
            enteredReps = originalInput.reps
            enteredRIR = originalInput.rir
            durationDraft = originalInput.durationDraft
            loadDraft = originalInput.loadDraft
            repsDraft = originalInput.repsDraft
        }
        isBatchingInputChanges = false
        persistSnapshot()
        return persistenceErrorMessage == nil
    }

    init(
        session: WorkoutSession,
        workoutAdapter: DeterministicWorkoutAdapter = DeterministicWorkoutAdapter(),
        effortGuidance: DeterministicSetEffortGuidance = DeterministicSetEffortGuidance(),
        restoredSnapshot: ActiveWorkoutSnapshot? = nil,
        observationDate: Date = .now,
        persistInitialSnapshot: Bool = true,
        requiresFinalSetReview: Bool = false,
        acceptedStart: WorkoutElapsedClockReading? = nil,
        elapsedClock: WorkoutElapsedClock = .continuous,
        onSnapshotChanged: @escaping (ActiveWorkoutSnapshot?, UUID) throws -> Void = { _, _ in },
        onSessionCompleted: @escaping (WorkoutSession) throws -> WorkoutHistoryRecordResult = { _ in .inserted },
        progressionValidator: @escaping @MainActor (ExercisePlan, WorkoutProgressionOpportunity) -> Bool = { _, _ in false },
        shareRevocationRegistration: ZeroOneShareRevocationRegistration? = nil
    ) {
        shareRevocationRegistration?.revokeBeforeChange()
        self.shareRevocationRegistration = shareRevocationRegistration
        let hasRestoredSnapshot = restoredSnapshot != nil
        self.elapsedClock = elapsedClock
        let restoredSnapshot = restoredSnapshot?.isCompatible == true ? restoredSnapshot : nil
        let initialSession = restoredSnapshot?.session ?? session
        self.session = initialSession
        self.workoutAdapter = workoutAdapter
        self.effortGuidance = effortGuidance
        self.onSnapshotChanged = onSnapshotChanged
        self.onSessionCompleted = onSessionCompleted
        self.progressionValidator = progressionValidator
        // A completed recovery record is already the write-ahead payload. Keep
        // its exact optional fields until History acknowledges it, including
        // when an older snapshot predates progression or final-review fields.
        self.restoredCompletedSnapshot = restoredSnapshot?.session.isComplete == true
            && restoredSnapshot?.awaitingFinalSetConfirmation != true ? restoredSnapshot : nil
        self.requiresFinalSetReview = requiresFinalSetReview
        let initialLoad = restoredSnapshot?.enteredLoadValue
            ?? initialSession.currentExercise?.plan.targetLoad.value
            ?? 0
        let initialReps = restoredSnapshot?.enteredReps
            ?? initialSession.currentExercise?.plan.previousPerformance.last?.reps
            ?? initialSession.currentExercise?.plan.targetReps.lowerBound
            ?? 1
        enteredLoadValue = initialLoad
        enteredReps = initialReps
        enteredRIR = restoredSnapshot?.enteredRIR
        durationDraft = restoredSnapshot?.durationDraft ?? ""
        awaitingNextSetAcknowledgement = restoredSnapshot?.awaitingNextSetAcknowledgement == true
        acknowledgementFieldWasAbsent = restoredSnapshot != nil
            && restoredSnapshot?.awaitingNextSetAcknowledgement == nil
        loadDraft = Self.loadDraftValue(initialLoad, for: initialSession.currentExercise)
        repsDraft = String(initialReps)
        isPaused = restoredSnapshot?.isPaused ?? false
        pausedRemainingRestSeconds = restoredSnapshot?.pausedRemainingRestSeconds
        pendingAdaptation = restoredSnapshot?.pendingAdaptation
        sessionBeforeAdaptation = restoredSnapshot?.sessionBeforeAdaptation
        lastSetGuidance = restoredSnapshot?.lastSetGuidance
        awaitingFinalSetConfirmation = restoredSnapshot?.awaitingFinalSetConfirmation == true
        progressionOfferSelections = restoredSnapshot?.progressionOfferSelections ?? [:]
        progressionOfferPreparedExerciseIDs = restoredSnapshot?.progressionOfferPreparedExerciseIDs ?? []
        progressionOfferConsumedExerciseIDs = restoredSnapshot?.progressionOfferConsumedExerciseIDs
            ?? Set((restoredSnapshot?.session.exercises ?? [])
                .filter { !$0.completedSets.isEmpty }.map { $0.plan.id })
        // Even a same-process disk snapshot can predate a failed pause write. Never resume its clock.
        elapsedEvidenceInvalidated = hasRestoredSnapshot
        if !hasRestoredSnapshot, !initialSession.isComplete, initialSession.completedSetCount == 0,
           let acceptedStart {
            elapsedEvidence = WorkoutElapsedEvidence.started(sessionID: initialSession.id, at: acceptedStart)
            if elapsedEvidence?.elapsed(at: elapsedClock.read()) == nil { invalidateElapsedEvidence() }
        }
        if restoredSnapshot != nil, !self.session.isComplete {
            self.session.markRestObservationRecovered(at: observationDate)
        }
        if persistInitialSnapshot {
            if self.session.isComplete {
                if awaitingFinalSetConfirmation {
                    persistFinalSetForReview()
                } else {
                    retryPersistence()
                }
            } else {
                persistSnapshot()
            }
        }
    }

    func completeCurrentSet(at date: Date = .now) {
        guard !requiresWarmUpGate, !isPaused, !awaitingNextSetAcknowledgement,
              session.restEndsAt == nil,
              persistenceErrorMessage == nil,
              let exercise = session.currentExercise else { return }
        guard commitDrafts(persistChanges: false) else { return }

        do {
            let isFirstSet = exercise.completedSets.isEmpty
            let result = try session.completeCurrentSet(
                load: Load(enteredLoadValue, unit: exercise.plan.targetLoad.unit),
                reps: exercise.plan.isTimed ? 0 : enteredReps,
                rir: exercise.plan.isTimed ? nil : enteredRIR,
                durationSeconds: exercise.plan.isTimed ? Self.parsedDuration(durationDraft) : nil,
                at: date
            )
            let targetRIR = ExerciseLibrary.exercise(id: exercise.plan.exerciseID)?.defaultRIRRange
                ?? RIRRange(2, 3)
            if let enteredRIR, !exercise.plan.isTimed {
                lastSetGuidance = effortGuidance.guidance(
                    rir: enteredRIR,
                    reps: enteredReps,
                    plan: exercise.plan,
                    targetRIR: targetRIR
                )
            } else {
                lastSetGuidance = nil
            }
            completionError = nil
            undoNotice = nil
            if isFirstSet { progressionOfferConsumedExerciseIDs.insert(exercise.plan.id) }
            sessionBeforeAdaptation = nil
            awaitingNextSetAcknowledgement = result != .workoutCompleted && exercise.plan.restSeconds == 0
            prepareInputsForCurrentSet()

            if result == .workoutCompleted {
                recordElapsedTransition(to: .stopped)
                if requiresFinalSetReview {
                    awaitingFinalSetConfirmation = true
                    persistFinalSetForReview()
                } else {
                    retryPersistence()
                }
            } else {
                persistSnapshot()
            }
        } catch let error as WorkoutCompletionError {
            completionError = error
        } catch {
            assertionFailure("Unexpected workout completion error: \(error)")
        }
    }

    func remainingRestSeconds(at date: Date) -> Int {
        if isPaused, let pausedRemainingRestSeconds {
            return pausedRemainingRestSeconds
        }
        return session.remainingRestSeconds(at: date)
    }

    func isResting(at date: Date) -> Bool {
        remainingRestSeconds(at: date) > 0
    }

    var activeRestDurationSeconds: Int {
        max(0, Int(session.activeRestDuration ?? 0))
    }

    /// The session cursor advances when a set is recorded. Presentation keeps
    /// the finished exercise on screen until the user accepts the handoff.
    var restingCompletedExercise: WorkoutExercise? {
        guard !session.isComplete,
              session.restEndsAt != nil || awaitingNextSetAcknowledgement,
              session.currentExerciseIndex > 0,
              session.currentExercise?.completedSets.isEmpty == true else { return nil }
        let finished = session.exercises[session.currentExerciseIndex - 1]
        guard finished.completedSets.count >= finished.plan.plannedSetCount else { return nil }
        return finished
    }

    var nextExercisePreview: WorkoutNextExercisePreview? {
        guard !session.isComplete,
              session.restEndsAt != nil || awaitingNextSetAcknowledgement else { return nil }
        if restingCompletedExercise != nil, let next = session.currentExercise {
            return WorkoutNextExercisePreview(exercise: next, setsBeforeHandoff: 0)
        }
        let nextIndex = session.currentExerciseIndex + 1
        guard session.exercises.indices.contains(nextIndex),
              let current = session.currentExercise else { return nil }
        return WorkoutNextExercisePreview(
            exercise: session.exercises[nextIndex],
            setsBeforeHandoff: max(0, current.plan.plannedSetCount - current.completedSets.count)
        )
    }

    /// Timed rest within one exercise resolves without an extra tap. A new
    /// exercise and zero-rest sessions keep their explicit acknowledgement.
    /// The caller drives this only while foregrounded or reconciling recovery.
    @discardableResult
    func advanceElapsedRest(at date: Date) -> Bool {
        guard restAdvancesAutomatically,
              let deadline = session.restEndsAt, deadline <= date else { return false }
        skipRest(at: date, automaticallyExpired: true)
        return persistenceErrorMessage == nil
    }

    /// The current rest is timed, within one exercise, and resolves by itself.
    /// Recovery may mark such a rest acknowledged-pending; it still resolves.
    private var restAdvancesAutomatically: Bool {
        !isPaused && !requiresWarmUpGate && persistenceErrorMessage == nil
            && !session.isComplete
            && activeRestDurationSeconds > 0 && session.restEndsAt != nil
            && restingCompletedExercise == nil
            && session.currentExercise?.completedSets.isEmpty == false
    }

    func skipRest(at date: Date = .now, automaticallyExpired: Bool = false) {
        guard persistenceErrorMessage == nil else { return }
        if awaitingNextSetAcknowledgement && !automaticallyExpired {
            acknowledgeNextSet(at: date)
            return
        }
        // Skipping rest does not silently resume an intentionally paused workout.
        // Keep a valid zero-duration pause for snapshot recovery.
        pausedRemainingRestSeconds = isPaused ? 0 : nil
        session.skipRest(at: date)
        awaitingNextSetAcknowledgement = false
        acknowledgementFieldWasAbsent = false
        persistSnapshot()
    }

    func resolveWarmUp(as status: WorkoutWarmUpStatus, at date: Date = .now) {
        guard session.requiresWarmUp, status != .pending, persistenceErrorMessage == nil else { return }
        session.resolveWarmUp(as: status, at: date)
        warmUpDecisionPendingSave = true
        persistSnapshot()
    }

    func toggleWarmUpStep(at index: Int) {
        guard session.requiresWarmUp, persistenceErrorMessage == nil,
              session.warmUp?.steps.indices.contains(index) == true else { return }
        session.toggleWarmUpStep(at: index)
        persistSnapshot()
    }

    func acknowledgeNextSet(at date: Date = .now) {
        guard awaitingNextSetAcknowledgement, !isPaused else { return }
        // Do not make the next Log available until the acknowledgement itself
        // is recoverable. On failure the saved/Next state stays visible.
        guard persistenceErrorMessage == nil else { return }
        session.skipRest(at: date, handoffAcknowledged: true)
        awaitingNextSetAcknowledgement = false
        acknowledgementFieldWasAbsent = false
        do {
            shareRevocationRegistration?.revokeBeforeChange()
            let saved = captureSnapshotForPersistence()
            try onSnapshotChanged(saved, session.id)
            persistedActivity = WorkoutActivityProjector.project(saved)
            publishElapsedEvidence(from: saved)
        } catch {
            confirmedElapsedEvidence = nil
            awaitingNextSetAcknowledgement = true
            persistenceErrorMessage = "Could not save the next-set transition. Retry saving before continuing."
        }
    }

    var canUndoLastSet: Bool {
        !session.isComplete && session.completedSetCount > 0
            && !isPaused && persistenceErrorMessage == nil
    }

    var canUndoFinalSet: Bool {
        awaitingFinalSetConfirmation && session.isComplete
            && persistenceErrorMessage == nil
            && persistedActivity?.sessionID == session.id
            && persistedActivity?.state.completedSets == session.completedSetCount
    }

    func undoFinalSet() {
        guard canUndoFinalSet,
              let finalSetID = session.exercises.last?.completedSets.last?.id,
              let removed = session.undoLastSet(
                  expectedSetID: finalSetID, reopeningFinalSet: true
              ) else { return }
        invalidateElapsedEvidence()
        awaitingFinalSetConfirmation = false
        isBatchingInputChanges = true
        enteredLoadValue = removed.load.value
        enteredReps = removed.reps
        enteredRIR = removed.rir
        loadDraft = String(removed.load.value)
        repsDraft = String(max(1, removed.reps))
        enteredReps = max(1, removed.reps)
        durationDraft = removed.durationSeconds.map(String.init) ?? ""
        isBatchingInputChanges = false
        awaitingNextSetAcknowledgement = false
        acknowledgementFieldWasAbsent = false
        lastSetGuidance = nil
        completionError = nil
        inputErrorMessage = nil
        persistSnapshot()
        recordUndoNotice()
    }

    func confirmFinalSetAndFinish(at date: Date = .now) {
        guard canUndoFinalSet, session.confirmCompletedExecution(at: date) else { return }
        awaitingFinalSetConfirmation = false
        retryPersistence(at: date)
    }

    func undoLastSet(expectedSetID: UUID? = nil) {
        guard canUndoLastSet,
              let removed = session.undoLastSet(expectedSetID: expectedSetID) else { return }
        isBatchingInputChanges = true
        enteredLoadValue = removed.load.value
        enteredReps = removed.reps
        enteredRIR = removed.rir
        loadDraft = String(removed.load.value)
        repsDraft = String(max(1, removed.reps))
        enteredReps = max(1, removed.reps)
        durationDraft = removed.durationSeconds.map(String.init) ?? ""
        isBatchingInputChanges = false
        awaitingNextSetAcknowledgement = false
        acknowledgementFieldWasAbsent = false
        lastSetGuidance = nil
        completionError = nil
        inputErrorMessage = nil
        persistSnapshot()
        recordUndoNotice()
    }

    /// Undo is reported only once the removal is the recoverable state.
    private func recordUndoNotice() {
        guard persistenceErrorMessage == nil, let setNumber = session.currentSetNumber else {
            undoNotice = nil
            return
        }
        undoNotice = "Set \(setNumber) removed. Its numbers are back below."
    }

    func addRestSeconds(_ seconds: Int = 15, at date: Date = .now) {
        guard seconds > 0, !session.isComplete, persistenceErrorMessage == nil else { return }
        if isPaused, let pausedRemainingRestSeconds {
            guard seconds <= 604_800, pausedRemainingRestSeconds <= 604_800 - seconds else { return }
            self.pausedRemainingRestSeconds = pausedRemainingRestSeconds + seconds
            session.extendPausedRest(by: TimeInterval(seconds), at: date)
        } else if session.isResting(at: date) {
            session.extendRest(by: TimeInterval(seconds), at: date)
        } else {
            return
        }
        persistSnapshot()
    }

    func shortenRestSeconds(_ seconds: Int = 15, at date: Date = .now) {
        guard seconds > 0, !isPaused, persistenceErrorMessage == nil,
              session.isResting(at: date) else { return }
        session.shortenRest(by: TimeInterval(seconds), at: date)
        persistSnapshot()
    }

    func togglePause(at date: Date = .now) {
        guard !session.isComplete, persistenceErrorMessage == nil else { return }
        recordElapsedTransition(to: isPaused ? .running : .paused)
        if isPaused {
            let restFinishedBeforePause = pausedRemainingRestSeconds == 0
                && session.restEndsAt != nil && session.completedSetCount > 0
            let needsExerciseHandoff = restingCompletedExercise != nil
            session.resumeRest(remainingSeconds: pausedRemainingRestSeconds ?? 0, at: date)
            if restFinishedBeforePause && needsExerciseHandoff {
                awaitingNextSetAcknowledgement = true
            }
            pausedRemainingRestSeconds = nil
            isPaused = false
        } else {
            pausedRemainingRestSeconds = session.remainingRestSeconds(at: date)
            session.pauseRest(at: date)
            isPaused = true
        }
        persistSnapshot()
    }

    func proposeThirtyMinuteAdaptation() {
        guard persistenceErrorMessage == nil else { return }
        pendingDemandAdaptation = nil
        do {
            pendingAdaptation = try workoutAdapter.proposal(for: session)
            adaptationError = nil
            persistSnapshot()
        } catch let error as WorkoutAdaptationError {
            pendingAdaptation = nil
            adaptationError = error
        } catch {
            assertionFailure("Unexpected workout adaptation error: \(error)")
        }
    }

    func applyPendingAdaptation() {
        guard persistenceErrorMessage == nil, let pendingAdaptation else { return }
        guard session == pendingAdaptation.originalSession,
              let checked = try? workoutAdapter.proposal(for: session, targetMinutes: pendingAdaptation.targetMinutes),
              checked.adaptedSession == pendingAdaptation.adaptedSession else {
            self.pendingAdaptation = nil
            adaptationError = .staleProposal
            persistSnapshot()
            return
        }
        sessionBeforeAdaptation = pendingAdaptation.originalSession
        session = pendingAdaptation.adaptedSession
        self.pendingAdaptation = nil
        lastSetGuidance = nil
        prepareInputsForCurrentSet()
        persistSnapshot()
    }

    func dismissPendingAdaptation() {
        pendingAdaptation = nil
        persistSnapshot()
    }

    var canReviewDemandAdaptation: Bool {
        persistenceErrorMessage == nil && !isPaused && !session.isComplete
            && session.completedSetCount == 0 && !session.isAdapted && pendingAdaptation == nil
            && session.currentExerciseIndex == 0 && session.restEndsAt == nil
    }

    func proposeDemandAdaptation(_ change: WorkoutDemandChange, assessment: WellbeingAssessment?,
                                at now: Date = .now, calendar: Calendar = .current) {
        guard canReviewDemandAdaptation else {
            demandAdaptationError = session.isAdapted ? .alreadyAdapted : .workoutStarted
            pendingDemandAdaptation = nil
            return
        }
        do {
            pendingDemandAdaptation = try WorkoutDemandAdapter().proposal(
                for: session, change: change, assessment: assessment, at: now, calendar: calendar)
            demandAdaptationError = nil
        } catch let error as WorkoutDemandAdaptationError {
            pendingDemandAdaptation = nil
            demandAdaptationError = error
        } catch {
            pendingDemandAdaptation = nil
            demandAdaptationError = .contextUnavailable
        }
    }

    @discardableResult
    func applyPendingDemandAdaptation(assessment: WellbeingAssessment?, at now: Date = .now,
                                     calendar: Calendar = .current) -> Bool {
        guard canReviewDemandAdaptation, let pendingDemandAdaptation else {
            demandAdaptationError = .workoutStarted
            return false
        }
        do {
            let fresh = try WorkoutDemandAdapter().revalidated(pendingDemandAdaptation, current: session,
                assessment: assessment, at: now, calendar: calendar)
            sessionBeforeAdaptation = fresh.originalSession
            session = fresh.adaptedSession
            self.pendingDemandAdaptation = nil
            demandAdaptationError = nil
            lastSetGuidance = nil
            // Neither option changes load, rep/timed/side targets or occurrence
            // identity. Keep manual input drafts and effort exactly as entered.
            persistSnapshot()
            return persistenceErrorMessage == nil
        } catch let error as WorkoutDemandAdaptationError {
            demandAdaptationError = error
            return false
        } catch {
            demandAdaptationError = .contextUnavailable
            return false
        }
    }

    func dismissPendingDemandAdaptation() {
        pendingDemandAdaptation = nil
        demandAdaptationError = nil
    }

    func clearDemandAdaptationError() { demandAdaptationError = nil }

    var canUndoAdaptation: Bool {
        persistenceErrorMessage == nil
            && sessionBeforeAdaptation != nil && session.completedSetCount == 0
    }

    func undoAdaptation() {
        guard canUndoAdaptation, let sessionBeforeAdaptation else { return }
        let priorPlan = session.currentExercise?.plan
        session = sessionBeforeAdaptation
        self.sessionBeforeAdaptation = nil
        pendingDemandAdaptation = nil
        lastSetGuidance = nil
        if priorPlan?.id != session.currentExercise?.plan.id
            || priorPlan?.targetPrescription != session.currentExercise?.plan.targetPrescription
            || priorPlan?.targetReps != session.currentExercise?.plan.targetReps
            || priorPlan?.targetLoad.unit != session.currentExercise?.plan.targetLoad.unit {
            prepareInputsForCurrentSet()
        }
        persistSnapshot()
    }

    func clearAdaptationError() {
        adaptationError = nil
    }

    func adjustLoad(by amount: Double) {
        if loadDraft.isEmpty && enteredLoadValue == 0 && amount > 0 {
            enteredLoadValue = amount
            loadDraft = String(amount)
            inputErrorMessage = nil
            return
        }
        if let error = commitLoad(loadDraft) {
            inputErrorMessage = error
            return
        }
        enteredLoadValue = max(0, enteredLoadValue + amount)
        loadDraft = Self.loadDraftValue(enteredLoadValue, for: session.currentExercise)
        inputErrorMessage = nil
    }

    func selectLoad(_ load: Load) {
        guard load.unit == session.currentExercise?.plan.targetLoad.unit else { return }
        loadDraft = String(load.value)
        inputErrorMessage = nil
    }

    func selectProgressionOffer(
        _ selection: WorkoutLoadChoiceSelection,
        opportunity: WorkoutProgressionOpportunity
    ) {
        guard !isPaused, persistenceErrorMessage == nil,
              let exercise = session.currentExercise,
              canShowProgressionOffer(for: exercise),
              progressionValidator(exercise.plan, opportunity) else { return }
        let load = selection == .tryNext ? opportunity.suggestedLoad : opportunity.previousLoad
        guard load.unit == exercise.plan.targetLoad.unit else { return }
        progressionOfferSelections[exercise.plan.id] = selection
        isBatchingInputChanges = true
        enteredLoadValue = load.value
        loadDraft = String(load.value)
        isBatchingInputChanges = false
        inputErrorMessage = nil
        persistSnapshot()
    }

    func prepareProgressionOffer(_ opportunity: WorkoutProgressionOpportunity) {
        guard !isPaused, persistenceErrorMessage == nil,
              let exercise = session.currentExercise,
              canShowProgressionOffer(for: exercise),
              !progressionOfferPreparedExerciseIDs.contains(exercise.plan.id) else { return }
        progressionOfferPreparedExerciseIDs.insert(exercise.plan.id)
        // Rendering a card cannot reset a draft, including a manual value that
        // happens to equal the suggestion. The planner starts from repeat work
        // unless an exact durable choice was already confirmed.
        persistSnapshot()
    }

    /// A draft is committed only when it is a valid value, never while empty mid-edit.
    func commitLoad(_ draft: String) -> String? {
        guard let value = Self.parsedLoad(draft), isAllowedLoad(value) else {
            return loadErrorMessage
        }
        enteredLoadValue = value
        return nil
    }

    func adjustReps(by amount: Int) {
        if isTimedSet {
            guard let value = Self.parsedDuration(durationDraft) else {
                inputErrorMessage = "Enter your actual duration before adjusting it."
                return
            }
            durationDraft = String(max(1, min(86_400, value + amount)))
            inputErrorMessage = nil
            return
        }
        if let error = commitReps(repsDraft) {
            inputErrorMessage = error
            return
        }
        enteredReps = max(1, min(50, enteredReps + amount))
        repsDraft = String(enteredReps)
        inputErrorMessage = nil
    }

    func commitReps(_ draft: String) -> String? {
        guard let value = Self.parsedReps(draft) else {
            return "Enter 1 to 50 whole repetitions."
        }
        enteredReps = value
        return nil
    }

    @discardableResult
    func commitDrafts(persistChanges: Bool = true) -> Bool {
        guard let load = Self.parsedLoad(loadDraft), isAllowedLoad(load) else {
            inputErrorMessage = loadErrorMessage
            return false
        }
        if isTimedSet && Self.parsedDuration(durationDraft) == nil {
            inputErrorMessage = "Enter the actual completed duration in whole seconds (1 to 86400)."
            return false
        }
        guard let reps = Self.parsedReps(repsDraft) else {
            inputErrorMessage = "Enter 1 to 50 whole repetitions."
            return false
        }
        let changed = load != enteredLoadValue || reps != enteredReps
        let wasBatchingInputChanges = isBatchingInputChanges
        isBatchingInputChanges = true
        enteredLoadValue = load
        enteredReps = reps
        isBatchingInputChanges = wasBatchingInputChanges
        inputErrorMessage = nil
        if changed && persistChanges { persistSnapshot() }
        return true
    }

    func adjustRIR(by amount: Int) {
        guard let enteredRIR else { return }
        self.enteredRIR = max(0, min(5, enteredRIR + amount))
    }

    func startTrackingRIR() {
        enteredRIR = 2
    }

    func clearRIR() {
        enteredRIR = nil
    }

    /// Returns false if there is no completed work or an unresolved save/review gate.
    @discardableResult
    func finishEarly(at date: Date = .now) -> Bool {
        guard persistenceErrorMessage == nil, !awaitingFinalSetConfirmation else { return false }
        guard session.finishEarly(at: date) else { return false }
        recordElapsedTransition(to: .stopped)
        isPaused = false
        pausedRemainingRestSeconds = nil
        awaitingNextSetAcknowledgement = false
        retryPersistence()
        return true
    }

    func progressionRecommendation(for exercise: WorkoutExercise) -> String {
        let plan = exercise.plan
        if plan.isTimed {
            return "Target: \(plan.prescriptionDisplayText). Enter how long you actually completed. The target is not a recorded result."
        }
        guard plan.targetLoad.value > 0 else {
            return "Starting target: \(plan.targetReps.displayText). Set a comfortable load."
        }
        // The history surface separately shows verified prior sets. A plan fixture alone
        // must never be presented as proof that the user lifted this load before.
        return "Suggested: \(plan.targetLoad.displayText) × \(plan.targetReps.displayText). Adjust to form."
    }

    func clearCompletionError() {
        completionError = nil
    }

    func retryPersistence(at date: Date = .now) {
        guard !isCompletionSaved else { return }
        if awaitingFinalSetConfirmation {
            persistFinalSetForReview()
            return
        }
        guard session.isComplete else {
            // A failed set write must not spend the user's rest time before the
            // set is confirmed. Preserve the entered set and start the full
            // rest interval on the successful retry instead.
            if unconfirmedWorkingSet != nil, session.restEndsAt != nil,
               activeRestDurationSeconds > 0 {
                session.resumeRest(remainingSeconds: activeRestDurationSeconds, at: date, afterFailedSave: true)
            }
            persistSnapshot(forceRetry: true)
            return
        }
        do {
            // Write-ahead recovery record includes the final set before touching History.
            let recoveryRecord = restoredCompletedSnapshot ?? captureSnapshotForPersistence()
            shareRevocationRegistration?.revokeBeforeChange()
            try onSnapshotChanged(recoveryRecord, session.id)
            persistedActivity = WorkoutActivityProjector.project(recoveryRecord, phase: .saving)
            publishElapsedEvidence(from: recoveryRecord)
            shareRevocationRegistration?.revokeBeforeChange()
            let result = try onSessionCompleted(session)
            shareRevocationRegistration?.revokeBeforeChange()
            try onSnapshotChanged(nil, session.id)
            persistedActivity = nil
            invalidateElapsedEvidence()
            lastCompletionRecordResult = result
            isCompletionSaved = true
            persistenceErrorMessage = nil
            // Reconciliation and retries of a persisted session never replay completion feedback.
            if result == .inserted {
                completionFeedbackCount += 1
                pendingCompletionPresentation = true
            }
        } catch {
            confirmedElapsedEvidence = nil
            persistenceErrorMessage = "Workout not fully saved. Your session is still here. Keep 01 open and retry saving before leaving this workout."
        }
    }

    func consumeCompletionPresentation() -> Bool {
        let shouldPresent = pendingCompletionPresentation
        pendingCompletionPresentation = false
        return shouldPresent
    }

    /// Read without consuming, so the summary's first render can decide whether
    /// the rail may travel into it. Recovery and reconciliation never set it.
    var hasPendingCompletionPresentation: Bool {
        pendingCompletionPresentation
    }

    func clearSnapshotForExit() -> Bool {
        guard !session.isComplete else { return isCompletionSaved }
        // Exiting without a History record is only safe before any working set.
        // Keep even a confirmed partial workout recoverable until Finish & Save.
        guard session.completedSetCount == 0 else { return false }
        do {
            shareRevocationRegistration?.revokeBeforeChange()
            try onSnapshotChanged(nil, session.id)
            persistedActivity = nil
            invalidateElapsedEvidence()
            persistenceErrorMessage = nil
            return true
        } catch {
            confirmedElapsedEvidence = nil
            persistenceErrorMessage = "Could not close this workout safely. Your session is still here. Retry saving before trying again."
            return false
        }
    }

    private func prepareInputsForCurrentSet() {
        guard let exercise = session.currentExercise else { return }
        // Preparing the next draft is one transition. Do not publish a snapshot
        // with a newly completed set and only some of its next-set fields reset.
        let wasBatchingInputChanges = isBatchingInputChanges
        isBatchingInputChanges = true
        defer { isBatchingInputChanges = wasBatchingInputChanges }
        if let previous = exercise.completedSets.last,
           previous.load.unit == exercise.plan.targetLoad.unit {
            enteredLoadValue = previous.load.value
            enteredReps = max(1, previous.reps)
        } else {
            enteredLoadValue = exercise.plan.targetLoad.value
            enteredReps = exercise.plan.previousPerformance.last?.reps
                ?? exercise.plan.targetReps.lowerBound
        }
        enteredRIR = nil
        // Every hold needs its own actual result. Never copy the target or prior hold.
        durationDraft = ""
        loadDraft = Self.loadDraftValue(enteredLoadValue, for: exercise)
        repsDraft = String(enteredReps)
        inputErrorMessage = nil
    }

    private func persistSnapshot(forceRetry: Bool = false) {
        guard !session.isComplete, !isBatchingInputChanges else { return }
        // A failed write is resolved only by the explicit Retry Save path.
        // Draft observers and app backgrounding must not silently acknowledge
        // an unconfirmed working set or spend its rest interval.
        guard forceRetry || persistenceErrorMessage == nil else { return }
        do {
            shareRevocationRegistration?.revokeBeforeChange()
            let saved = captureSnapshotForPersistence()
            try onSnapshotChanged(saved, session.id)
            persistedActivity = WorkoutActivityProjector.project(saved)
            publishElapsedEvidence(from: saved)
            persistenceErrorMessage = nil
            warmUpDecisionPendingSave = false
        } catch {
            confirmedElapsedEvidence = nil
            persistenceErrorMessage = "Could not save your latest workout changes. Keep 01 open and retry saving."
        }
    }

    private func persistFinalSetForReview() {
        guard session.isComplete, awaitingFinalSetConfirmation else { return }
        do {
            shareRevocationRegistration?.revokeBeforeChange()
            let saved = captureSnapshotForPersistence()
            try onSnapshotChanged(saved, session.id)
            persistedActivity = WorkoutActivityProjector.project(saved, phase: .readyToFinish)
            publishElapsedEvidence(from: saved)
            persistenceErrorMessage = nil
        } catch {
            confirmedElapsedEvidence = nil
            persistenceErrorMessage = "Final set not confirmed saved. Your session is still here. Retry before finishing or undoing it."
        }
    }

    private static func parsedDuration(_ draft: String) -> Int? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1 ... 86_400).contains(value) else { return nil }
        return value
    }

    private static func parsedLoad(_ draft: String) -> Double? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func isAllowedLoad(_ value: Double) -> Bool {
        value > 0 || session.currentExercise?.plan.allowsZeroLoad == true
    }

    private var loadErrorMessage: String {
        session.currentExercise?.plan.allowsZeroLoad == true
            ? "Enter 0 for bodyweight, or a positive external load."
            : "Enter a positive load for this exercise."
    }

    private static func loadDraftValue(_ value: Double, for exercise: WorkoutExercise?) -> String {
        guard value == 0, let exercise, !exercise.plan.allowsZeroLoad else { return String(value) }
        return ""
    }

    private static func parsedReps(_ draft: String) -> Int? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = Int(text), (1 ... 50).contains(value) else { return nil }
        return value
    }

    /// Permanently withdraw this owner's timing before replacement, final Undo or lost continuity.
    func invalidateElapsedEvidence() {
        elapsedEvidenceInvalidated = true
        elapsedEvidence = nil
        confirmedElapsedEvidence = nil
    }

    /// Call only on the retained current VM. No elapsed value is inferred from an old activity.
    func confirmedElapsedSeconds() -> TimeInterval? {
        guard !elapsedEvidenceInvalidated, persistenceErrorMessage == nil,
              let confirmedElapsedEvidence, confirmedElapsedEvidence == elapsedEvidence,
              confirmedElapsedEvidence.matches(sessionID: session.id, isPaused: isPaused,
                  isComplete: session.isComplete) else { return nil }
        guard let seconds = confirmedElapsedEvidence.elapsed(at: elapsedClock.read()) else {
            invalidateElapsedEvidence()
            return nil
        }
        return seconds
    }

    private func recordElapsedTransition(to state: WorkoutElapsedEvidence.State) {
        guard !elapsedEvidenceInvalidated, let elapsedEvidence else { return }
        guard let updated = elapsedEvidence.transitioning(to: state, at: elapsedClock.read()) else {
            invalidateElapsedEvidence()
            return
        }
        self.elapsedEvidence = updated
    }

    private func captureSnapshotForPersistence() -> ActiveWorkoutSnapshot {
        if let elapsedEvidence,
           !elapsedEvidence.matches(sessionID: session.id, isPaused: isPaused, isComplete: session.isComplete)
            || elapsedEvidence.elapsed(at: elapsedClock.read()) == nil {
            invalidateElapsedEvidence()
        }
        return snapshot
    }

    private func publishElapsedEvidence(from saved: ActiveWorkoutSnapshot) {
        // A callback may revoke/replace this owner synchronously. Its late success cannot revive timing.
        guard !elapsedEvidenceInvalidated, let evidence = saved.elapsedEvidence,
              evidence == elapsedEvidence,
              evidence.matches(sessionID: session.id, isPaused: isPaused, isComplete: session.isComplete)
        else { confirmedElapsedEvidence = nil; return }
        confirmedElapsedEvidence = evidence
    }

    private var snapshot: ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(
            session: session,
            enteredLoadValue: enteredLoadValue,
            enteredReps: enteredReps,
            enteredRIR: enteredRIR,
            durationDraft: durationDraft,
            awaitingNextSetAcknowledgement: awaitingNextSetAcknowledgement
                ? true : (acknowledgementFieldWasAbsent ? nil : false),
            isPaused: isPaused,
            pausedRemainingRestSeconds: pausedRemainingRestSeconds,
            pendingAdaptation: pendingAdaptation,
            sessionBeforeAdaptation: sessionBeforeAdaptation,
            lastSetGuidance: lastSetGuidance,
            awaitingFinalSetConfirmation: awaitingFinalSetConfirmation,
            progressionOfferSelections: progressionOfferSelections,
            progressionOfferPreparedExerciseIDs: progressionOfferPreparedExerciseIDs,
            progressionOfferConsumedExerciseIDs: progressionOfferConsumedExerciseIDs,
            elapsedEvidence: elapsedEvidence
        )
    }
}

enum WorkoutDockRole: Equatable {
    case warmUp
    case logSet(exerciseIndex: Int, setNumber: Int)
    case rest(exerciseIndex: Int, nextSetNumber: Int)
    case paused
    case retry
    case finalReview
    case finished
}

/// How the stable primary slot moved between two roles. Roles change only
/// after the model accepts a persisted state, so this classifies commits, not
/// taps. Timings are Study 18's; the tap-guard floor holds with Reduce Motion.
enum WorkoutDockTransition: Equatable {
    /// First render, recovery or an unchanged role: nothing replays.
    case steady
    /// Log set to rest or final review, after the save was acknowledged.
    case save
    /// Rest to the next set of the same exercise.
    case restOver
    /// Rest to set 1 of the next exercise.
    case handoff
    /// Back to an earlier set after a persisted Undo.
    case undo
    /// Paused or warm-up to working sets.
    case resume
    /// To the saved summary.
    case finish
    case other

    init(from old: WorkoutDockRole?, to new: WorkoutDockRole) {
        guard let old, old != new else {
            self = .steady
            return
        }
        switch (old, new) {
        case (_, .finished):
            self = .finish
        case (.logSet, .rest), (.logSet, .finalReview):
            self = .save
        case let (.rest(oldIndex, oldSet), .logSet(newIndex, newSet)):
            if newIndex == oldIndex && newSet == oldSet {
                self = newSet == 1 ? .handoff : .restOver
            } else {
                self = .undo
            }
        case let (.logSet(oldIndex, oldSet), .logSet(newIndex, newSet)):
            self = (newIndex, newSet) < (oldIndex, oldSet) ? .undo : .other
        case (.finalReview, .logSet):
            self = .undo
        case (.paused, .logSet), (.paused, .rest), (.warmUp, .logSet):
            self = .resume
        default:
            self = .other
        }
    }

    /// Time before the dock accepts a tap in its new role: 360 ms, and longer
    /// only for a genuine handoff while its carried title is still landing.
    func inputDelay(motionEnabled: Bool) -> TimeInterval {
        motionEnabled && self == .handoff ? 0.6 : WorkoutDockTapGuard.interval
    }

    /// The whole move from commit to stillness.
    func totalDuration(motionEnabled: Bool) -> TimeInterval {
        guard motionEnabled else { return self == .handoff ? 0.24 : 0.18 }
        switch self {
        case .steady, .other: return 0.36
        case .save: return 0.6
        case .restOver, .resume: return 0.48
        case .undo: return 0.42
        case .handoff: return 0.72
        case .finish: return 0.96
        }
    }
}

/// Study 18's session rail: one segment per planned working set, in plan order.
/// A segment reads saved only inside the persisted prefix, so a held,
/// unconfirmed set never looks saved.
struct WorkoutSetRail: Equatable {
    enum Mark: Equatable {
        case saved
        case current
        case open
    }

    struct Segment: Identifiable, Equatable {
        let exerciseID: UUID
        let setNumber: Int
        let mark: Mark

        var id: String { "\(exerciseID.uuidString)-\(setNumber)" }
    }

    let segments: [Segment]

    var savedCount: Int { segments.filter { $0.mark == .saved }.count }

    /// `showsCurrent` marks the next set to log; pass false while resting or
    /// reviewing so the rail never points at a set that cannot be logged yet.
    init(session: WorkoutSession, confirmedSetCount: Int, showsCurrent: Bool) {
        var remaining = max(0, confirmedSetCount)
        var segments: [Segment] = []
        for (index, exercise) in session.exercises.enumerated() {
            let saved = min(exercise.completedSets.count, remaining)
            remaining -= saved
            let planned = max(exercise.plan.plannedSetCount, exercise.completedSets.count)
            for offset in 0 ..< planned {
                let number = offset + 1
                let mark: Mark
                if number <= saved {
                    mark = .saved
                } else if showsCurrent, !session.isComplete,
                          index == session.currentExerciseIndex,
                          number == exercise.completedSets.count + 1 {
                    mark = .current
                } else {
                    mark = .open
                }
                segments.append(Segment(exerciseID: exercise.id, setNumber: number, mark: mark))
            }
        }
        self.segments = segments
    }
}

struct WorkoutNextExercisePreview: Equatable {
    let exercise: WorkoutExercise
    let setsBeforeHandoff: Int

    var canStart: Bool { setsBeforeHandoff == 0 }
    var caption: String {
        canStart ? "Next exercise"
            : "After \(setsBeforeHandoff) more \(setsBeforeHandoff == 1 ? "set" : "sets")"
    }
}

enum WorkoutPrimaryAction: Equatable {
    case logSet(number: Int)
    case rest(deadline: Date, duration: TimeInterval)
    case startSet(number: Int, exerciseName: String)

    var isResting: Bool {
        if case .rest = self { return true }
        return false
    }

    var title: String {
        switch self {
        case let .logSet(number): return "Log set \(number)"
        case .rest: return "Rest"
        case let .startSet(number, name): return number == 1 ? "Start \(name)" : "Start set \(number)"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .logSet: return "Records the entered set and starts the rest timer."
        case .rest: return "Rest is running. Use Start now to end it early."
        case .startSet: return "Opens the next set without logging it."
        }
    }

    func remainingFraction(at date: Date) -> Double {
        guard case let .rest(deadline, duration) = self, duration > 0 else { return 1 }
        return min(1, max(0, deadline.timeIntervalSince(date) / duration))
    }
}

/// When the primary button changes role under the same finger (Log set to
/// Start set, Start set to Log set), a quick second tap must not act on the new
/// role. Only the dock is guarded, and the guard is time-based, not motion-based,
/// so it applies with Reduce Motion too.
struct WorkoutDockTapGuard: Equatable {
    static let interval: TimeInterval = 0.36

    private(set) var blockedUntil: Date?

    mutating func roleChanged(at date: Date, inputDelay: TimeInterval = Self.interval) {
        blockedUntil = date.addingTimeInterval(max(Self.interval, inputDelay))
    }

    func allowsTap(at date: Date) -> Bool {
        blockedUntil.map { date >= $0 } ?? true
    }
}

/// Spoken confirmations. `saved` is posted only after persistence confirms the set.
enum WorkoutSetAnnouncement {
    static func saved(setNumber: Int, set: CompletedSet, restSeconds: Int) -> String {
        let unit = set.load.unit == .kilograms ? "kilograms" : "pounds"
        let reps = set.durationSeconds.map { spokenDuration($0) + (set.isPerSide == true ? " per side" : "") }
            ?? ((set.reps == 1 ? "1 rep" : "\(set.reps) reps") + (set.isPerSide == true ? " per side" : ""))
        let rest = restSeconds > 0 ? " Rest \(spokenDuration(restSeconds))." : ""
        return "Set \(setNumber) saved. \(set.load.value.formatted()) \(unit), \(reps).\(rest)"
    }

    static func notSaved(setNumber: Int) -> String {
        "Set \(setNumber) was not saved. Your numbers are kept. Try again."
    }

    static func removed(setNumber: Int) -> String {
        "Set \(setNumber) removed."
    }

    /// Posted once, after History acknowledged the workout.
    static func historySaved(savedSetCount: Int, plannedSetCount: Int) -> String {
        savedSetCount >= plannedSetCount
            ? "Workout saved to History. Complete, all \(plannedSetCount) sets."
            : "Workout saved to History. Partial, \(savedSetCount) of \(plannedSetCount) sets."
    }

    static func spokenDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minuteText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let secondText = remainder == 1 ? "1 second" : "\(remainder) seconds"
        if minutes == 0 { return secondText }
        return remainder == 0 ? minuteText : "\(minuteText) \(secondText)"
    }
}

/// Neutral, factual notes for a saved set. Lower results never use warning language.
enum WorkoutSetResponseCopy {
    static func gainChip(for response: WorkoutSetResponse) -> String? {
        switch response.kind {
        case .up:
            let gain = response.savedSet.load.value - response.previousSet.load.value
            return "+\(Load(gain, unit: response.savedSet.load.unit).displayText)"
        case .upReps:
            let gain = response.savedSet.reps - response.previousSet.reps
            return "+\(gain) \(gain == 1 ? "rep" : "reps")"
        case .same, .heavierIn, .heavierBelow, .fewer, .lighter:
            return nil
        }
    }

    static func note(
        for response: WorkoutSetResponse,
        targetReps: RepRange,
        offersNextLoadChoice: Bool
    ) -> String {
        let saved = response.savedSet
        let previous = response.previousSet
        let prior = "\(previous.load.displayText) × \(previous.reps)"
        let range = targetReps.lowerBound == targetReps.upperBound
            ? "\(targetReps.upperBound)-rep target"
            : "\(targetReps.lowerBound)–\(targetReps.upperBound) range"
        let choice = offersNextLoadChoice ? " For the next set:" : ""
        switch response.kind {
        case .up:
            return "Up from \(prior) last time."
        case .upReps:
            let gain = saved.reps - previous.reps
            return "\(gain) more \(gain == 1 ? "rep" : "reps") than last time at \(previous.load.displayText)."
        case .same:
            return "Same as last time: \(prior). Solid, repeatable work."
        case .heavierIn:
            return "\(saved.reps) reps at \(saved.load.displayText), inside your \(range). Reps often dip for a session or two after a load step.\(choice)"
        case .heavierBelow:
            return "\(saved.reps) reps at \(saved.load.displayText), under your \(range). It's saved and it counts.\(choice)"
        case .fewer:
            let drop = previous.reps - saved.reps
            return "\(saved.reps) reps, \(drop) fewer than last time at \(saved.load.displayText). Saved and counted; day-to-day variation is normal."
        case .lighter:
            return "Lighter than last time's \(previous.load.displayText). Saved and counted."
        }
    }
}

/// The offer's reason is built from the same recorded sets the rule checked.
/// It returns nil rather than describe evidence it cannot see.
enum WorkoutProgressionOfferCopy {
    static func stepText(for opportunity: WorkoutProgressionOpportunity) -> String {
        let step = opportunity.suggestedLoad.value - opportunity.previousLoad.value
        return "+\(Load(step, unit: opportunity.suggestedLoad.unit).displayText)"
    }

    static func reason(
        for opportunity: WorkoutProgressionOpportunity,
        previousPerformance: PreviousExercisePerformanceState,
        targetReps: RepRange
    ) -> String? {
        guard case let .recorded(performance) = previousPerformance,
              !performance.hasNewerUnknownDetails,
              let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty }),
              occurrence.completedSets.allSatisfy({
                  $0.load == opportunity.previousLoad && $0.reps >= targetReps.upperBound
              }) else { return nil }
        let count = occurrence.completedSets.count
        let sets = count == 1 ? "your only set" : "all \(count) sets"
        let range = targetReps.lowerBound == targetReps.upperBound
            ? "your \(targetReps.upperBound)-rep target"
            : "the top of your \(targetReps.lowerBound)–\(targetReps.upperBound) range"
        return "Last time you reached \(targetReps.upperBound) reps on \(sets) at \(opportunity.previousLoad.displayText), \(range)."
    }
}

/// One exercise's saved sets against the same numbered sets last time.
struct WorkoutExerciseComparison: Equatable {
    enum Kind: Equatable {
        case load
        case reps
        case same
        case under
        case lighter
        case mixed
    }

    let kind: Kind
    let topLoadNow: Load
    let topLoadBefore: Load
    let repsNow: Int
    let repsBefore: Int
    let comparedSetCount: Int

    /// Only paired sets in one unit are compared. No history, unknown newer
    /// details or mixed units produce no comparison instead of a guess.
    static func evaluate(
        savedSets: [CompletedSet],
        previousPerformance: PreviousExercisePerformanceState
    ) -> Self? {
        guard case let .recorded(performance) = previousPerformance,
              !performance.hasNewerUnknownDetails,
              let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty })
        else { return nil }
        let pairs = Array(zip(savedSets, occurrence.completedSets))
        guard let unit = pairs.first?.0.load.unit,
              pairs.allSatisfy({ !$0.0.isTimed && !$0.1.isTimed && $0.0.isPerSide == $0.1.isPerSide
                  && $0.0.load.unit == unit && $0.1.load.unit == unit }) else { return nil }
        let topNow = pairs.map { $0.0.load.value }.max() ?? 0
        let topBefore = pairs.map { $0.1.load.value }.max() ?? 0
        let repsNow = pairs.reduce(0) { $0 + $1.0.reps }
        let repsBefore = pairs.reduce(0) { $0 + $1.1.reps }
        let loadsMatch = pairs.allSatisfy { $0.0.load == $0.1.load }
        let setsMatch = loadsMatch && pairs.allSatisfy { $0.0.reps == $0.1.reps }
        let kind: Kind
        if topNow > topBefore {
            kind = .load
        } else if topNow < topBefore {
            kind = .lighter
        } else if loadsMatch && repsNow > repsBefore {
            kind = .reps
        } else if loadsMatch && repsNow < repsBefore {
            kind = .under
        } else if setsMatch {
            kind = .same
        } else {
            // Equal totals or peak loads do not mean the individual sets matched.
            kind = .mixed
        }
        return Self(
            kind: kind,
            topLoadNow: Load(topNow, unit: unit),
            topLoadBefore: Load(topBefore, unit: unit),
            repsNow: repsNow,
            repsBefore: repsBefore,
            comparedSetCount: pairs.count
        )
    }

    var chip: String {
        switch kind {
        case .load:
            return "+\(Load(topLoadNow.value - topLoadBefore.value, unit: topLoadNow.unit).displayText)"
        case .reps:
            let gain = repsNow - repsBefore
            return "+\(gain) \(gain == 1 ? "rep" : "reps")"
        case .same:
            return "Matched"
        case .under:
            let drop = repsBefore - repsNow
            return "\(drop) \(drop == 1 ? "rep" : "reps") under"
        case .lighter:
            return "Lighter"
        case .mixed:
            return "Mixed sets"
        }
    }
}

/// The summary's one headline. Progress first, then a factual lower result,
/// then a match. Without any comparable history there is no headline.
struct WorkoutSessionHighlight: Equatable {
    let title: String
    let body: String

    static func make(
        _ items: [(exercise: WorkoutExercise, comparison: WorkoutExerciseComparison?)]
    ) -> Self? {
        let compared = items.compactMap { item in
            item.comparison.map { (exercise: item.exercise, comparison: $0) }
        }
        if let up = compared.first(where: { $0.comparison.kind == .load }) {
            let count = up.comparison.comparedSetCount
            return Self(
                title: "\(up.comparison.chip) on \(up.exercise.plan.name)",
                body: "Your heaviest compared set reached \(up.comparison.topLoadNow.displayText), up from \(up.comparison.topLoadBefore.displayText). \(count) \(count == 1 ? "set" : "sets") compared."
            )
        }
        if let up = compared.first(where: { $0.comparison.kind == .reps }) {
            return Self(
                title: "\(up.comparison.chip) on \(up.exercise.plan.name)",
                body: "More reps across \(up.comparison.comparedSetCount) compared \(up.comparison.comparedSetCount == 1 ? "set" : "sets"), with each set's load unchanged."
            )
        }
        if let lower = compared.first(where: { $0.comparison.kind == .under || $0.comparison.kind == .lighter }) {
            let detail = lower.comparison.kind == .under
                ? "\(lower.exercise.plan.name) came in \(lower.comparison.chip) last time across \(lower.comparison.comparedSetCount) compared \(lower.comparison.comparedSetCount == 1 ? "set" : "sets")."
                : "\(lower.exercise.plan.name) was lighter than last time."
            return Self(title: "Saved as logged", body: "\(detail) One session isn't a trend, and nothing resets.")
        }
        guard !compared.isEmpty else { return nil }
        if compared.contains(where: { $0.comparison.kind == .mixed }) {
            return Self(
                title: "Saved as logged",
                body: "Your sets varied from last time. The set-by-set results are below; nothing resets."
            )
        }
        return Self(
            title: "Matched last time",
            body: "Every compared set equals last time. That consistency is what the next step is built on."
        )
    }
}

/// The End confirmation states exactly what is saved and what is not.
struct WorkoutEndConfirmationCopy: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String

    init(session: WorkoutSession) {
        let saved = session.completedSetCount
        guard saved > 0 else {
            title = "End this session?"
            message = "Nothing is logged yet, so ending now leaves no record for today."
            confirmTitle = "End without saving"
            cancelTitle = "Keep going"
            return
        }
        let exercises = session.exercises.filter { !$0.completedSets.isEmpty }.count
        let unlogged = max(0, session.totalPlannedSetCount - saved)
        let unloggedText = unlogged == 0 ? ""
            : " \(unlogged) planned \(unlogged == 1 ? "set stays" : "sets stay") unlogged."
        title = "End workout?"
        message = "\(saved) \(saved == 1 ? "set" : "sets") saved across \(exercises) \(exercises == 1 ? "exercise" : "exercises").\(unloggedText) Everything saved stays saved."
        confirmTitle = "End and see summary"
        cancelTitle = "Keep training"
    }
}
