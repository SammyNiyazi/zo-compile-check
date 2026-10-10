import SwiftUI

struct WarmUpStepTimer: Equatable {
    let stepIndex: Int
    let durationSeconds: Int
    let endsAt: Date

    func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(endsAt.timeIntervalSince(date))))
    }
}

struct WorkoutView: View {
    @Bindable var viewModel: WorkoutViewModel
    let music: WorkoutMusicStore
    @Bindable var progressPhotos: ProgressPhotoRepository
    @Bindable var workoutHistory: WorkoutHistoryRepository
    let workoutLoadChoices: WorkoutLoadChoiceRepository
    let onFinish: () -> Void
    let onViewSession: () -> Void
    let onExit: () -> Void
    let onOpenAssistant: () -> Void
    var musicNamespace: Namespace.ID? = nil
    var onShare: (() -> Void)? = nil
    var shareIsBusy = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneWorkoutProgression) private var progression
    @Environment(\.zeroOneWellbeingAssessment) private var wellbeingAssessment
    @Environment(\.zeroOneWorkoutDemandAuthority) private var demandAuthority
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var showsExitConfirmation = false
    @State private var showsAdaptationProposal = false
    @State private var showsDemandProposal = false
    @State private var isCheckingDemand = false
    @State private var exerciseGuidePlan: ExercisePlan?
    @State private var substitutionSource: ExercisePlan?
    @State private var isEditingSet = false
    @State private var stepUpMoment: WorkoutSetProgressMoment?
    @State private var celebratedExerciseIDs: Set<UUID> = []
    @State private var warmUpStepTimer: WarmUpStepTimer?
    @State private var warmUpTimerCompletionEpoch = 0
    @State private var dockGuard = WorkoutDockTapGuard()
    @State private var nextSetFeedback = 0
    @State private var nextExerciseFeedback = 0
    @State private var handoffRestFeedback = 0
    @State private var lastForegroundRestTick: Date?
    @State private var observesForegroundRest = false
    /// The role last rendered. It still holds the previous role while the body
    /// renders a new one, so one render can classify the commit it animates.
    @State private var renderedDockRole: WorkoutDockRole? = nil
    /// Increments only for acknowledged saves made in the foreground.
    @State private var dockConfirmationTrigger = 0
    /// The exercise whose headline arrives from the next-exercise card.
    @State private var handoffCarrierExerciseID: UUID? = nil
    @Namespace private var exerciseHandoff
    @Namespace private var railCarrier
    @AccessibilityFocusState private var firstWorkingSetFocused: Bool

    /// The exercise holding the most recent saved set. After an exercise's last
    /// set the session already points at the next exercise.
    private var latestSavedExercise: WorkoutExercise? {
        viewModel.session.exercises.last(where: { !$0.completedSets.isEmpty })
    }

    private var endCopy: WorkoutEndConfirmationCopy {
        WorkoutEndConfirmationCopy(session: viewModel.session)
    }

    private var localCanvas: Color {
        TrainingCompanionPalette.canvas(for: colorScheme)
    }

    private var localInk: Color {
        TrainingCompanionPalette.ink(for: colorScheme)
    }

    private var allowsSpatialMotion: Bool {
        !reduceMotion && !voiceOverEnabled && !dynamicTypeSize.isAccessibilitySize
    }

    private var workoutMusicContext: WorkoutMusicContext {
        WorkoutMusicContext(session: viewModel.session, stage: .active,
            isPaused: viewModel.isPaused, awaitingNextSet: viewModel.awaitingNextSetAcknowledgement,
            awaitingFinalSetConfirmation: viewModel.awaitingFinalSetConfirmation)
    }

    private var dockTransition: AnyTransition {
        allowsSpatialMotion ? .opacity.combined(with: .offset(y: 14)) : .opacity
    }

    /// The commit being rendered right now; `.steady` once it has settled.
    private var liveDockTransition: WorkoutDockTransition {
        WorkoutDockTransition(from: renderedDockRole, to: viewModel.dockRole)
    }

    /// Study 18 timing for the commit being rendered. Background, recovery and
    /// reconciliation render without animation.
    private var dockAnimation: Animation? {
        guard scenePhase == .active else { return nil }
        let transition = liveDockTransition
        guard allowsSpatialMotion else {
            return .easeOut(duration: transition.totalDuration(motionEnabled: false))
        }
        switch transition {
        case .save:
            // The entry leaves at once; the rest panel staggers its own parts.
            return WorkoutMotion.land(0.36)
        case .restOver, .undo:
            return WorkoutMotion.land(0.3).delay(0.12)
        case .handoff:
            // Poster and title travel from 120 ms for 480 ms.
            return WorkoutMotion.carry(0.48).delay(0.12)
        case .finish:
            return WorkoutMotion.carry(0.48)
        case .resume:
            return WorkoutMotion.land(0.42).delay(0.06)
        case .steady, .other:
            return WorkoutMotion.land(0.36)
        }
    }

    /// Finish: the workout recedes to 98% and fades while its rail travels into
    /// the saved grid. It uses the transaction's timing, so a failed save,
    /// which is never animated, still replaces the workout at once.
    private var recedeTransition: AnyTransition {
        allowsSpatialMotion ? .opacity.combined(with: .scale(scale: 0.98)) : .opacity
    }

    private var finishAnimation: Animation {
        allowsSpatialMotion ? WorkoutMotion.carry(0.48) : .easeOut(duration: 0.18)
    }

    /// Only a save made in the foreground with motion staggers the rest panel.
    private var staggersRestEntrance: Bool {
        allowsSpatialMotion && scenePhase == .active && liveDockTransition == .save
    }

    // Music is opt-in. The cue becomes true only when the final working set is
    // genuinely ready; redraws cannot restart it because the store guards ID.
    private var finalSetMusicCue: Bool {
        let session = viewModel.session
        guard !session.isComplete, !viewModel.isPaused,
              !viewModel.requiresWarmUpGate,
              viewModel.persistenceErrorMessage == nil,
              session.restEndsAt == nil,
              !viewModel.awaitingNextSetAcknowledgement,
              session.currentExerciseIndex == session.exercises.count - 1,
              let exercise = session.currentExercise,
              let currentSet = session.currentSetNumber else { return false }
        return currentSet == exercise.plan.plannedSetCount
    }

    private func plannedLoadSummary(for exercise: WorkoutExercise) -> String {
        let load = viewModel.enteredLoadValue
        if load > 0 {
            return "\(load.formatted()) \(exercise.plan.targetLoad.unit.rawValue)"
        }
        if exercise.plan.allowsZeroLoad {
            return localization.string("Bodyweight")
        }
        return localization.string("Choose load")
    }

    var body: some View {
        workoutPresentations(workoutSessionEvents(workoutLifecycle(workoutLayout)))
    }

    private var workoutLayout: some View {
        GeometryReader { proxy in
            let contentMargin = ZOSpace.screenMargin

            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    localCanvas
                        .ignoresSafeArea()

                    ScrollView {
                        // Overlaid, not stacked: a leaving branch must never
                        // push the arriving one down during a transition.
                        ZStack(alignment: .top) {
                        if viewModel.session.isComplete && viewModel.isCompletionSaved {
                            WorkoutCompletionView(
                                sessionTitle: viewModel.session.title,
                                completedSetCount: viewModel.session.completedSetCount,
                                totalSetCount: viewModel.session.totalPlannedSetCount,
                                exercises: viewModel.session.exercises,
                                endedEarly: viewModel.session.endedEarly,
                                totalReps: WorkoutComparisonPresentation.recordedRepetitions(
                                    in: viewModel.session.exercises.flatMap(\.completedSets)),
                                completedAt: viewModel.session.completedAt,
                                historyState: workoutHistory.surfaceState,
                                upgrades: viewModel.progressionRecommendationsAllowed ? WorkoutCompletionUpgrade.readyAfter(
                                    session: viewModel.session,
                                    savedHistory: workoutHistory.entries,
                                    progressionReviews: progression?.reviews.isAvailable == true ? progression?.reviews.snapshot.reviews ?? [] : []
                                ) : [],
                                sourceSessionID: viewModel.session.id,
                                loadChoices: workoutLoadChoices,
                                previousPerformance: { exerciseID in
                                    workoutHistory.previousPerformance(
                                        for: exerciseID, excluding: viewModel.session.id
                                    )
                                },
                                rail: WorkoutSetRail(
                                    session: viewModel.session,
                                    confirmedSetCount: viewModel.session.completedSetCount,
                                    showsCurrent: false
                                ),
                                railNamespace: railCarrier,
                                presentsLive: viewModel.hasPendingCompletionPresentation
                                    && scenePhase == .active,
                                carriesRail: viewModel.hasPendingCompletionPresentation
                                    && scenePhase == .active && allowsSpatialMotion,
                                progressPhotos: progressPhotos,
                                shouldAnimate: viewModel.consumeCompletionPresentation,
                                onViewSession: onViewSession,
                                onFinish: onFinish,
                                onShare: onShare,
                                shareIsBusy: shareIsBusy,
                                personalRecord: WorkoutPersonalRecord.isEarned(
                                    exercises: viewModel.session.exercises, sessionID: viewModel.session.id,
                                    completedAt: viewModel.session.completedAt, history: workoutHistory.entries,
                                    historyAvailable: workoutHistory.availability == .available)
                            )
                            .frame(minHeight: proxy.size.height, alignment: .top)
                            .transition(.opacity.animation(.easeOut(duration: allowsSpatialMotion ? 0.24 : 0.18)))
                        } else if viewModel.session.isComplete,
                                  viewModel.awaitingFinalSetConfirmation,
                                  viewModel.persistenceErrorMessage == nil {
                            allSetsDoneContent
                                .padding(.horizontal, contentMargin)
                                .frame(minHeight: proxy.size.height, alignment: .top)
                                .transition(.asymmetric(insertion: .opacity, removal: recedeTransition))
                        } else if viewModel.session.isComplete {
                            VStack(spacing: ZOSpace.m) {
                                Text(localization.string(viewModel.awaitingFinalSetConfirmation
                                     ? "Final set not confirmed yet"
                                     : "Workout not fully saved yet"))
                                    .zoText(.title)
                                persistenceRetry
                            }
                            .padding(.horizontal, contentMargin)
                            .frame(minHeight: proxy.size.height)
                        } else if viewModel.persistenceErrorMessage != nil {
                            VStack(alignment: .leading, spacing: ZOSpace.m) {
                                Text("SAVE INTERRUPTED")
                                    .zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                                Text((viewModel.session.isComplete ? nil : viewModel.unconfirmedWorkingSet).map { localization.format("Set %1$lld was not saved.", .integer($0.number)) } ?? localization.string("Your workout is still here."))
                                    .zoText(.display)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                Text(localization.string(viewModel.unconfirmedWorkingSet != nil
                                     ? "Your numbers are kept on this iPhone. Try again before continuing; nothing after this set is available until it saves."
                                     : "Confirm the save below before continuing. The latest change is not confirmed saved."))
                                    .zoText(.body)
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                persistenceRecoveryDetails
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, contentMargin)
                            .padding(.top, ZOSpace.x4)
                            .frame(minHeight: proxy.size.height, alignment: .top)
                        } else if viewModel.requiresWarmUpGate,
                                  let warmUp = viewModel.session.warmUp {
                            warmUpContent(warmUp, date: context.date)
                                .padding(.horizontal, contentMargin)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .offset(y: -12)))
                                .onChange(of: context.date) { _, date in
                                    completeWarmUpStepTimerIfNeeded(at: date)
                                }
                        } else if let exercise = viewModel.session.currentExercise,
                                  let currentSet = viewModel.session.currentSetNumber {
                            activeWorkoutContent(
                                exercise: exercise,
                                currentSet: currentSet,
                                date: context.date,
                                contentMargin: contentMargin,
                                artworkHeight: min(198, max(148, proxy.size.height * 0.235)),
                                availableWidth: proxy.size.width - 2 * contentMargin
                            )
                            .transition(.asymmetric(
                                insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14)),
                                removal: recedeTransition
                            ))
                            .onChange(of: context.date) { _, date in
                                handleForegroundRestTick(at: date)
                            }
                        }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                        if viewModel.session.isComplete,
                           viewModel.awaitingFinalSetConfirmation,
                           viewModel.persistenceErrorMessage == nil {
                            allSetsDoneActions
                                .padding(.horizontal, contentMargin)
                        }
                        if !viewModel.session.isComplete, viewModel.persistenceErrorMessage != nil {
                            persistenceRetryAction
                                .padding(.horizontal, contentMargin)
                                .padding(.vertical, ZOSpace.s)
                                .background(localCanvas)
                        }
                        if !viewModel.session.isComplete, viewModel.requiresWarmUpGate,
                           viewModel.persistenceErrorMessage == nil,
                           viewModel.session.warmUp?.status == .pending {
                            warmUpActionPanel
                        }
                        if let action = viewModel.primaryAction(at: context.date) {
                            WorkoutPrimaryDock(
                                action: action,
                                savedSetNumber: latestSavedExercise?.completedSets.count,
                                confirmationTrigger: dockConfirmationTrigger,
                                commit: liveDockTransition,
                                motionEnabled: allowsSpatialMotion,
                                logSummary: logSummary,
                                onActivate: {
                                    guard dockGuard.allowsTap(at: .now) else { return }
                                    // Re-read the current role at tap time. A stale
                                    // rendered label can never bypass a save/rest gate.
                                    guard let currentAction = viewModel.primaryAction(at: .now) else { return }
                                    switch currentAction {
                                    case .logSet:
                                        viewModel.completeCurrentSet(at: .now)
                                    case .startSet:
                                        advanceToNextSet()
                                    default:
                                        break
                                    }
                                }
                            )
                            .padding(.horizontal, contentMargin)
                            .padding(.bottom, ZOSpace.s)
                            .background(localCanvas)
                        }
                        // Proof 37's "Skip rest": quiet, under the rest line.
                        // The clock and details now sit in the scroll.
                        if isShowingRest,
                           let exercise = viewModel.session.currentExercise,
                           let currentSet = viewModel.session.currentSetNumber {
                            restPanel(.startNow, exercise: exercise, currentSet: currentSet, date: context.date)
                                .padding(.horizontal, contentMargin)
                                .padding(.bottom, ZOSpace.s)
                                .background(localCanvas)
                                .transition(dockTransition)
                        }
                        }
                    }
                    .animation(dockAnimation, value: viewModel.dockRole)

                    if let stepUpMoment, !reduceMotion,
                       !voiceOverEnabled, !dynamicTypeSize.isAccessibilitySize {
                        WorkoutStepUpBand(
                            moment: stepUpMoment,
                            setNumber: latestSavedExercise?.completedSets.count ?? 1,
                            canUndo: viewModel.canUndoLastSet || viewModel.canUndoFinalSet,
                            onUndo: { setID in
                                guard viewModel.session.latestCompletedSetID == setID else { return }
                                if viewModel.canUndoFinalSet {
                                    viewModel.undoFinalSet()
                                } else {
                                    viewModel.undoLastSet(expectedSetID: setID)
                                }
                                withTransaction(Transaction(animation: nil)) { self.stepUpMoment = nil }
                            },
                            onDismiss: {
                                withTransaction(Transaction(animation: nil)) { self.stepUpMoment = nil }
                            }
                        )
                        .padding(.horizontal, contentMargin)
                        .padding(.bottom, ZOSpace.s)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
    }

    /// Haptics, lifecycle and the guide/substitution sheets on the workout layout.
    private func workoutLifecycle(_ content: some View) -> some View {
        content
        .sensoryFeedback(.success, trigger: savedSetFeedbackCount) { oldValue, newValue in
            newValue > oldValue
        }
        // Only foreground events increment these. Recovery never replays haptics.
        .sensoryFeedback(.impact(weight: .light), trigger: nextSetFeedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: nextExerciseFeedback)
        .sensoryFeedback(.success, trigger: handoffRestFeedback)
        .onChange(of: viewModel.dockRole) { oldRole, role in
            // 360 ms normally, 600 ms only for a genuine handoff. The floor
            // also holds with Reduce Motion.
            dockGuard.roleChanged(
                at: .now,
                inputDelay: WorkoutDockTransition(from: oldRole, to: role)
                    .inputDelay(motionEnabled: allowsSpatialMotion)
            )
            renderedDockRole = role
            // Keep the carrier while its headline may still be landing.
            if case .logSet(_, 1) = role,
               handoffCarrierExerciseID == viewModel.session.currentExercise?.id { return }
            handoffCarrierExerciseID = nil
        }
        .onChange(of: viewModel.unconfirmedWorkingSet?.set.id) { _, heldSetID in
            guard voiceOverEnabled, heldSetID != nil,
                  let pending = viewModel.unconfirmedWorkingSet else { return }
            AccessibilityNotification.Announcement(
                localization.format("Set %1$lld was not saved. Your numbers are kept. Try again.", .integer(pending.number))
            ).post()
        }
        .onChange(of: viewModel.undoNotice) { _, notice in
            guard voiceOverEnabled, notice != nil,
                  let setNumber = viewModel.session.currentSetNumber else { return }
            AccessibilityNotification.Announcement(
                localization.format("Set %1$lld removed.", .integer(setNumber))
            ).post()
        }
        .sheet(item: $exerciseGuidePlan) { plan in
            Group {
                NavigationStack {
                    ScrollView {
                        if let match = MoveKitExerciseCatalog.match(for: plan.exerciseID) {
                            MoveKitExerciseGuide(match: match, plan: plan)
                                .padding(.horizontal, ZOSpace.l)
                                .padding(.vertical, ZOSpace.m)
                        } else {
                            VStack(alignment: .leading, spacing: ZOSpace.m) {
                                Text(plan.name)
                                    .zoText(.title)
                                Text("Video unavailable for this exercise")
                                    .zoText(.section)
                                if let cue = plan.coachingCue {
                                    Text(cue).foregroundStyle(theme.textSecondary)
                                }
                                Text("Logging remains available offline.")
                                    .zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, ZOSpace.l)
                            .padding(.vertical, ZOSpace.m)
                        }
                    }
                    .background(localCanvas)
                    .navigationTitle("Exercise guide")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet()
        }
        .sheet(item: $substitutionSource) { plan in
            Group {
                WorkoutSubstitutionSheet(viewModel: viewModel, sourcePlan: plan)
                .zeroOneTheme(theme)
            }
            .zoSheet(theme)
        }
        .toolbar(.hidden, for: .navigationBar)
        .foregroundStyle(localInk)
        .sensoryFeedback(.success, trigger: viewModel.completionFeedbackCount)
    }

    /// Appearance, scene and session changes, split from workoutLifecycle for the type checker.
    private func workoutSessionEvents(_ content: some View) -> some View {
        content
        .onAppear {
            showsAdaptationProposal = viewModel.pendingAdaptation != nil
            music.prepareForWorkout(sessionID: viewModel.session.id)
            reconcileWorkoutPresentation()
            renderedDockRole = viewModel.dockRole
            // The tap that opened or resumed the workout cannot also log a set.
            dockGuard.roleChanged(
                at: .now,
                inputDelay: WorkoutDockTransition.resume.inputDelay(motionEnabled: allowsSpatialMotion)
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                completeWarmUpStepTimerIfNeeded(at: .now)
                reconcileWorkoutPresentation()
            }
            if phase != .active {
                observesForegroundRest = false
                lastForegroundRestTick = nil
                if viewModel.persistenceErrorMessage == nil {
                    _ = viewModel.commitDrafts()
                }
                stepUpMoment = nil
            }
        }
        .onChange(of: viewModel.session.id) { _, _ in
            warmUpStepTimer = nil
            music.prepareForWorkout(sessionID: viewModel.session.id)
        }
        .onChange(of: viewModel.session.isComplete) { _, complete in
            if complete { music.finishWorkout() }
        }
        .task(id: "\(viewModel.session.id)-\(finalSetMusicCue)-\(String(describing: music.lastSetSong?.id))") {
            if finalSetMusicCue { await music.beginFinalSet(sessionID: viewModel.session.id) }
        }
        .onChange(of: savedSetFeedbackCount) { oldCount, newCount in
            guard newCount > oldCount else {
                stepUpMoment = nil
                return
            }
            guard scenePhase == .active else {
                stepUpMoment = nil
                return
            }
            if !viewModel.session.isComplete {
                dockConfirmationTrigger += 1
            }
            if voiceOverEnabled,
               let exercise = viewModel.session.exercises.last(where: { !$0.completedSets.isEmpty }),
               let saved = exercise.completedSets.last {
                AccessibilityNotification.Announcement(
                    workoutCopy.savedAnnouncement(
                        setNumber: exercise.completedSets.count,
                        set: saved,
                        restSeconds: viewModel.session.restEndsAt == nil
                            ? 0 : viewModel.activeRestDurationSeconds
                    )
                ).post()
            }
            stepUpMoment = nil
            guard let exercise = viewModel.session.exercises.last(where: { !$0.completedSets.isEmpty }),
                  !celebratedExerciseIDs.contains(exercise.plan.id),
                  let moment = confirmedStepUpMoment else { return }
            celebratedExerciseIDs.insert(exercise.plan.id)
            guard !reduceMotion, !voiceOverEnabled,
                  !dynamicTypeSize.isAccessibilitySize else { return }
            stepUpMoment = moment
        }
        .onChange(of: viewModel.pendingAdaptation) { _, proposal in
            showsAdaptationProposal = proposal != nil
        }
        .onChange(of: viewModel.dockRole) { _, role in
            guard case let .logSet(_, setNumber) = role, setNumber == 1,
                  viewModel.persistenceErrorMessage == nil else { return }
            Task { @MainActor in
                await Task.yield()
                if viewModel.dockRole == role {
                    firstWorkingSetFocused = true
                }
            }
        }
    }

    /// Sheets and alerts, split from body so the type checker can finish (9 Oct compile check).
    private func workoutPresentations(_ content: some View) -> some View {
        content
        .sheet(isPresented: $showsAdaptationProposal, onDismiss: viewModel.dismissPendingAdaptation) {
            Group {
                if let proposal = viewModel.pendingAdaptation {
                    WorkoutAdaptationProposalView(
                        proposal: proposal,
                        onApply: {
                            withAnimation(reduceMotion ? nil : ZeroOneMotion.standard) {
                                viewModel.applyPendingAdaptation()
                                showsAdaptationProposal = false
                            }
                        },
                        onKeepOriginal: {
                            viewModel.dismissPendingAdaptation()
                            showsAdaptationProposal = false
                        }
                    )
                    .zeroOneTheme(theme)
                }
            }
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsDemandProposal, onDismiss: viewModel.dismissPendingDemandAdaptation) {
            Group {
                if let proposal = viewModel.pendingDemandAdaptation {
                    WorkoutDemandProposalView(proposal: proposal, isChecking: isCheckingDemand,
                        error: viewModel.demandAdaptationError, onApply: applyDemandProposal,
                        onKeepOriginal: { showsDemandProposal = false })
                        .zeroOneTheme(theme)
                }
            }
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsExitConfirmation) {
            Group {
                WorkoutEndSheet(
                    copy: endCopy,
                    localizedMessage: workoutCopy.endMessage(saved: viewModel.session.completedSetCount, exercises: viewModel.session.exercises.filter { !$0.completedSets.isEmpty }.count, planned: viewModel.session.totalPlannedSetCount),
                    savedSetCount: confirmedTotalSetCount,
                    plannedSetCount: viewModel.session.totalPlannedSetCount,
                    canFinish: viewModel.persistenceErrorMessage == nil,
                    onConfirm: {
                        showsExitConfirmation = false
                        if viewModel.session.completedSetCount > 0 {
                            // The summary replaces the workout only after History
                            // acknowledges it; the rail carries into its grid.
                            withAnimation(finishAnimation) { _ = viewModel.finishEarly() }
                        } else {
                            onExit()
                        }
                    },
                    onCancel: { showsExitConfirmation = false }
                )
                .zeroOneTheme(theme)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .zoSheet(theme)
        }
        .alert("Set not completed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                viewModel.clearCompletionError()
            }
        } message: {
            Text(localization.string(errorMessage))
        }
        .alert("Workout cannot be shortened", isPresented: adaptationErrorBinding) {
            Button("OK", role: .cancel) {
                viewModel.clearAdaptationError()
            }
        } message: {
            Text(localization.string(adaptationErrorMessage))
        }
        .alert("Workout adjustment unavailable", isPresented: demandErrorBinding) {
            Button("OK", role: .cancel, action: viewModel.clearDemandAdaptationError)
        } message: {
            if let error = viewModel.demandAdaptationError { Text(localization.string(error.messageKey)) }
        }
    }

    private var persistenceRetry: some View {
        VStack(spacing: ZOSpace.m) {
            persistenceRecoveryDetails
            persistenceRetryAction
        }
    }

    private var persistenceRecoveryDetails: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let pending = viewModel.unconfirmedWorkingSet {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("SET HELD · SAVE NOT CONFIRMED")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(localization.format("%1$@ · Set %2$lld", .text(pending.exerciseName), .integer(pending.number)))
                        .zoText(.section)
                    Text("\(workoutCopy.load(pending.set.load)) · \(workoutCopy.performance(pending.set))")
                        .zoText(.section)
                    Text("Your entry is held in this session. Retry before continuing.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if !viewModel.requiresWarmUpGate,
                      let exercise = viewModel.session.currentExercise,
                      let setNumber = viewModel.session.currentSetNumber {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("CURRENT SET · SAVE NOT CONFIRMED")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(localization.format("%1$@ · Set %2$lld", .text(exercise.plan.name), .integer(setNumber)))
                        .zoText(.section)
                    Text(localization.format("%1$@ %2$@ · %3$@", .text(viewModel.loadDraft), .text(exercise.plan.targetLoad.unit.rawValue), .text(workoutCopy.draftPerformance(exercise.plan.isTimed ? viewModel.durationDraft : viewModel.repsDraft, isTimed: exercise.plan.isTimed, perSide: exercise.plan.prescription.perSide))))
                        .zoText(.section)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your entered values are still here, but this change is not saved. Retry before continuing.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(localization.string(viewModel.persistenceErrorMessage ?? "Saving your workout..."))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.m)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.card)
        )
    }

    private var persistenceRetryAction: some View {
        Button((viewModel.session.isComplete ? nil : viewModel.unconfirmedWorkingSet).map { localization.format("Try again: log set %1$lld", .integer($0.number)) } ?? localization.string("Retry Save")) { viewModel.retryPersistence() }
            .buttonStyle(ZOButtonStyle(.primary))
            .accessibilityHint("Confirms the held workout change before you can continue.")
            .accessibilityIdentifier("workout.retrySave")
    }

    /// The persisted prefix of the session. `showsCurrent` only while a set
    /// can actually be logged.
    private var sessionRail: WorkoutSetRail {
        WorkoutSetRail(
            session: viewModel.session,
            confirmedSetCount: confirmedTotalSetCount,
            showsCurrent: {
                if case .logSet = viewModel.dockRole { return true }
                return false
            }()
        )
    }

    private func sessionRailView() -> some View {
        WorkoutSessionRail(
            rail: sessionRail,
            style: .rail,
            namespace: railCarrier,
            carriesSegments: allowsSpatialMotion,
            motionEnabled: allowsSpatialMotion
        )
        // The header states the same saved count in words.
        .accessibilityHidden(true)
    }

    private var allSetsDoneContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            sessionRailView()
                .padding(.top, ZOSpace.s)
            Text("ALL SETS DONE")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            Text("The work is in.")
                .zoText(.display)
            Text(localization.format("Confirmed %1$@ on this iPhone. Review the final set, then finish your workout.", .text(workoutCopy.quantity(viewModel.session.completedSetCount, .sets))))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if let exercise = viewModel.session.exercises.last,
               let finalSet = exercise.completedSets.last {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("FINAL SET SAVED")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(exercise.plan.name)
                        .zoText(.section)
                    Text("\(workoutCopy.load(finalSet.load)) · \(workoutCopy.performance(finalSet))")
                        .zoText(.metric)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ZOSpace.l)
                .background(
                    TrainingCompanionPalette.surface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: ZORadius.card)
                )
                .accessibilityElement(children: .combine)
            }
            Text("Undo restores the final set to its editable fields. History is recorded after Finish & Save.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ZOSpace.x4)
    }

    private var allSetsDoneActions: some View {
        VStack(spacing: ZOSpace.s) {
            Button("Finish & Save") {
                withAnimation(finishAnimation) { viewModel.confirmFinalSetAndFinish() }
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .disabled(!viewModel.canUndoFinalSet)
            .accessibilityIdentifier("workout.confirmFinalSet")
            Button("Undo final set", systemImage: "arrow.uturn.backward") {
                viewModel.undoFinalSet()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!viewModel.canUndoFinalSet)
            .accessibilityIdentifier("workout.undoFinalSet")
        }
        .padding(.top, ZOSpace.s)
        .padding(.bottom, ZOSpace.s)
        .background(localCanvas)
    }

    private func warmUpContent(_ warmUp: WorkoutWarmUp, date: Date) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            HStack(spacing: ZOSpace.s) {
                Button("End") { showsExitConfirmation = true }
                    .frame(minWidth: 52, minHeight: 44, alignment: .leading)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(viewModel.session.title)
                        .zoText(.section)
                        .lineLimit(1)
                    Text(localization.string(warmUp.length == .short ? "Short warm-up" : "Warm-up"))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                Text(workoutCopy.quantity(warmUp.estimatedMinutes, .minutes))
                    .zoText(.caption)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .buttonStyle(.plain)

            WorkoutMusicLane(music: music, context: workoutMusicContext, musicNamespace: musicNamespace)

            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("Before working sets")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(localization.string(warmUp.length == .short ? "Short warm-up" : "Warm up"))
                    .zoText(.display)
                    .accessibilityAddTraits(.isHeader)
                Text(localization.format("About %1$@. These preparation steps are separate from your working sets.", .text(workoutCopy.quantity(warmUp.estimatedMinutes, .minutes))))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: ZOSpace.s) {
                ForEach(0 ..< warmUp.steps.count, id: \.self) { index in
                    Capsule()
                        .fill(warmUp.checkedStepIndices.contains(index) ? localInk : theme.surfaceSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 5)
                        .accessibilityHidden(true)
                }
                Text(localization.format("%1$lld of %2$lld", .integer(warmUp.checkedStepIndices.count), .integer(warmUp.steps.count)))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel(localization.format("%1$lld of %2$lld warm-up steps checked", .integer(warmUp.checkedStepIndices.count), .integer(warmUp.steps.count)))

            VStack(spacing: 0) {
                ForEach(0 ..< warmUp.steps.count, id: \.self) { index in
                    HStack(spacing: ZOSpace.s) {
                        Button {
                            if warmUpStepTimer?.stepIndex == index { warmUpStepTimer = nil }
                            viewModel.toggleWarmUpStep(at: index)
                        } label: {
                            HStack(alignment: .center, spacing: ZOSpace.m) {
                                Image(systemName: warmUp.checkedStepIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .zoIcon(ZOIcon.row)
                                    .foregroundStyle(warmUp.checkedStepIndices.contains(index) ? localInk : theme.textSecondary)
                                Text(warmUp.steps[index])
                                    .zoText(.section)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                            .padding(.leading, ZOSpace.m)
                            .padding(.vertical, ZOSpace.s)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localization.format("Step %1$lld, %2$@", .integer(index + 1), .text(warmUp.steps[index])))
                        .accessibilityValue(localization.string(warmUp.checkedStepIndices.contains(index) ? "Checked" : "Not checked"))
                        .accessibilityAddTraits(warmUp.checkedStepIndices.contains(index) ? .isSelected : [])
                        .disabled(viewModel.persistenceErrorMessage != nil)

                        if let seconds = warmUp.timerSeconds(forStepAt: index) {
                            warmUpTimerButton(stepIndex: index, seconds: seconds, date: date)
                                .padding(.trailing, ZOSpace.m)
                        }
                    }
                    if index < warmUp.steps.count - 1 {
                        Rectangle().fill(theme.strokeSubtle.opacity(0.32)).frame(height: 1)
                    }
                }
            }
            .background(
                TrainingCompanionPalette.surface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: ZORadius.card)
            )
            .sensoryFeedback(.success, trigger: warmUpTimerCompletionEpoch)

            Text("Check the steps you do. Warm-up is encouraged, but you can start working sets whenever you are ready.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)

            if let firstExercise = viewModel.session.currentExercise {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("SET 1 IS NEXT")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(firstExercise.plan.name)
                        .zoText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(plannedLoadSummary(for: firstExercise)) · \(workoutCopy.prescription(firstExercise.plan.prescription))")
                        .zoText(.section)
                    Text("Adjust the load and enter your actual result before logging.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(ZOSpace.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    TrainingCompanionPalette.surface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: ZORadius.card)
                )
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("TODAY")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                ForEach(viewModel.session.exercises) { exercise in
                    HStack(alignment: .firstTextBaseline) {
                        Text(exercise.plan.name)
                        Spacer(minLength: ZOSpace.s)
                        Text("\(exercise.plan.plannedSetCount) × \(workoutCopy.prescription(exercise.plan.prescription))")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .zoText(.label)
                    .padding(.vertical, ZOSpace.xs)
                }
            }
        }
        .padding(.top, ZOSpace.l)
        .padding(.bottom, ZOSpace.x4)
    }

    private func warmUpTimerButton(stepIndex: Int, seconds: Int, date: Date) -> some View {
        let activeTimer = warmUpStepTimer?.stepIndex == stepIndex ? warmUpStepTimer : nil
        let remaining = activeTimer?.remainingSeconds(at: date) ?? seconds
        let elapsed = (activeTimer?.durationSeconds ?? seconds) - remaining
        return Button {
            if activeTimer != nil {
                warmUpStepTimer = nil
            } else {
                warmUpStepTimer = WarmUpStepTimer(
                    stepIndex: stepIndex,
                    durationSeconds: seconds,
                    endsAt: .now.addingTimeInterval(TimeInterval(seconds))
                )
            }
        } label: {
            VStack(spacing: 3) {
                Text(localization.string(activeTimer == nil ? "Start" : "Stop"))
                    .zoText(.caption)
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .zoText(.section)
                    .monospacedDigit()
                ProgressView(value: Double(elapsed), total: Double(seconds))
                    .tint(theme.accentForeground)
                    .frame(width: 48)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 62, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.small)
                .stroke(localInk.opacity(0.4), lineWidth: 1)
        }
        .accessibilityLabel(activeTimer == nil ? localization.format("Start %1$@ warm-up timer", .text(workoutCopy.quantity(seconds, .seconds))) : localization.string("Stop warm-up timer"))
        .accessibilityValue(localization.format("%1$@ remaining", .text(workoutCopy.quantity(remaining, .seconds))))
        .accessibilityHint("Finishing the timer checks this warm-up step. You can start working sets at any time.")
        .accessibilityIdentifier("workout.warmUpTimer.\(stepIndex)")
        .disabled(viewModel.persistenceErrorMessage != nil)
    }

    private func completeWarmUpStepTimerIfNeeded(at date: Date) {
        guard let timer = warmUpStepTimer, timer.remainingSeconds(at: date) == 0,
              viewModel.session.warmUp?.status == .pending,
              viewModel.persistenceErrorMessage == nil else { return }
        warmUpStepTimer = nil
        if viewModel.session.warmUp?.checkedStepIndices.contains(timer.stepIndex) == false {
            viewModel.toggleWarmUpStep(at: timer.stepIndex)
        }
        if viewModel.persistenceErrorMessage == nil {
            warmUpTimerCompletionEpoch += 1
        }
    }

    private var warmUpActionPanel: some View {
        VStack(spacing: ZOSpace.s) {
            Text(warmUpProgressMessage)
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Button("Start working sets") { beginWorkingSets() }
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityIdentifier("workout.warmUpComplete")
                .disabled(viewModel.persistenceErrorMessage != nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZOSpace.l)
        .padding(.top, ZOSpace.m)
        .background(TrainingCompanionPalette.surface(for: colorScheme))
    }

    private var warmUpProgressMessage: String {
        guard let warmUp = viewModel.session.warmUp else { return localization.string("Start set 1 when ready.") }
        let checked = warmUp.checkedStepIndices.count
        if checked == warmUp.steps.count { return localization.string("Preparation checked. Set 1 is ready.") }
        if checked == 0 { return localization.string("A short warm-up is recommended. Start when you are ready.") }
        return localization.format("%1$lld of %2$lld preparation steps checked. Start when you are ready.", .integer(checked), .integer(warmUp.steps.count))
    }

    private func beginWorkingSets() {
        guard dockGuard.allowsTap(at: .now),
              let warmUp = viewModel.session.warmUp, warmUp.status == .pending else { return }
        warmUpStepTimer = nil
        let animation = reduceMotion
            ? Animation.easeOut(duration: 0.18)
            : Animation.timingCurve(0.35, 0, 0.1, 1, duration: 0.48)
        withAnimation(animation) {
            viewModel.resolveWarmUp(as: warmUp.statusWhenStartingWorkingSets)
        }
        guard !viewModel.requiresWarmUpGate, viewModel.persistenceErrorMessage == nil else { return }
        Task { @MainActor in
            await Task.yield()
            firstWorkingSetFocused = true
        }
    }

    private func activeWorkoutContent(
        exercise: WorkoutExercise,
        currentSet: Int,
        date: Date,
        contentMargin: CGFloat,
        artworkHeight: CGFloat,
        availableWidth: CGFloat
    ) -> some View {
        let presentedExercise = viewModel.restingCompletedExercise ?? exercise
        let presentedSet = viewModel.restingCompletedExercise != nil
            ? presentedExercise.completedSets.count : currentSet

        let isResting = viewModel.session.restEndsAt != nil || viewModel.awaitingNextSetAcknowledgement

        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            workoutControlBar(exercise: presentedExercise, currentSet: presentedSet, date: date)

            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                sessionRailView()
                previousRailView()
            }

            WorkoutMusicLane(music: music, context: workoutMusicContext, musicNamespace: musicNamespace)

            if !viewModel.isPaused, viewModel.progressionRecommendationsAllowed,
               let upgrade = WorkoutCompletionUpgrade.readyDuring(
                   session: viewModel.session,
                   persistedCompletedSetCount: confirmedActiveSetCount
               ) {
                WorkoutCompletionUpgradeCard(
                    upgrade: upgrade,
                    selectedChoice: workoutLoadChoices.choice(
                        for: upgrade, sourceSessionID: viewModel.session.id
                    ),
                    motionEnabled: !reduceMotion,
                    workoutFullySaved: false,
                    canChoose: workoutLoadChoices.isAvailable,
                    onChoose: {
                        workoutLoadChoices.choose(
                            $0, for: upgrade, sourceSessionID: viewModel.session.id
                        )
                    }
                )
                .accessibilityIdentifier("workout.inSessionUpgrade")
            }

            if viewModel.canUndoLastSet && viewModel.session.restEndsAt == nil
                && !viewModel.awaitingNextSetAcknowledgement {
                Button("Undo last set", systemImage: "arrow.uturn.backward") {
                    viewModel.undoLastSet()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .frame(minHeight: 44)
                .accessibilityHint("Removes the most recently logged set and restores its load and repetitions.")
                .accessibilityIdentifier("workout.undoLastSet")
            }

            if viewModel.isPaused {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    Text("Paused").zoText(.title)
                    Text(localization.format("%1$@ · %2$@ recorded", .text(exercise.plan.name), .text(workoutCopy.quantity(viewModel.session.completedSetCount, .sets))))
                    Button("Resume workout") { viewModel.togglePause(at: date) }
                        .buttonStyle(ZOButtonStyle(.primary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Proof 37: the set shows the exercise and its poster; rest
                // shows only the line, the clock and the bars, and the next
                // exercise brings its own poster, which carries into this
                // header when it starts.
                if !isResting {
                    workoutHeader(
                        exercise: presentedExercise,
                        currentSet: presentedSet,
                        artworkHeight: artworkHeight
                    )
                    if isFirstWorkout {
                        firstWorkoutInlineTips(movementName: presentedExercise.plan.name)
                    }
                }

                Group {
                    if isResting {
                        restingContent(exercise: presentedExercise, presentedSet: presentedSet,
                                       current: exercise, currentSet: currentSet, date: date)
                            .transition(
                                allowsSpatialMotion ? .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 12)),
                                    // Gone before a carried poster is large enough to overlap it.
                                    removal: .opacity.animation(WorkoutMotion.leave(0.18))
                                ) : .opacity
                            )
                    } else {
                        setEditor(exercise: exercise, currentSet: currentSet)
                            .transition(
                                allowsSpatialMotion ? .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 12)),
                                    removal: .opacity.combined(with: .offset(y: -8))
                                ) : .opacity
                            )
                        if !viewModel.session.isComplete, !viewModel.requiresWarmUpGate,
                           viewModel.remainingRestSeconds(at: date) == 0,
                           viewModel.persistenceErrorMessage == nil {
                            trainingSetConsole(exercise: exercise, currentSet: currentSet,
                                               availableWidth: availableWidth)
                                .transition(dockTransition)
                        }
                    }
                }
            }
            Button("Finish workout") { showsExitConfirmation = true }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, contentMargin)
        .padding(.top, ZOSpace.l)
        .padding(.bottom, ZOSpace.x4)
        .animation(dockAnimation, value: viewModel.dockRole)
    }

    private func workoutControlBar(
        exercise: WorkoutExercise,
        currentSet: Int,
        date: Date
    ) -> some View {
        HStack(alignment: .center, spacing: ZOSpace.s) {
            Button("End") { showsExitConfirmation = true }
                .frame(minWidth: 52, minHeight: 44, alignment: .leading)
                .accessibilityHint("Asks before ending this workout.")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(viewModel.session.title)
                    .zoText(.section)
                    .lineLimit(1)
                Text(localization.format("Exercise %1$lld of %2$lld", .integer((viewModel.session.exercises.firstIndex(where: { $0.id == exercise.id }) ?? viewModel.session.currentExerciseIndex) + 1), .integer(viewModel.session.exercises.count)))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Ask 01", systemImage: "sparkles", action: onOpenAssistant)
                Button("Exercise guide", systemImage: "play.rectangle") { exerciseGuidePlan = exercise.plan }
                if viewModel.canSubstituteCurrentExercise,
                   exercise.id == viewModel.session.currentExercise?.id {
                    if exercise.originalPlan != nil {
                        Button("Undo exercise swap", systemImage: "arrow.uturn.backward") {
                            _ = viewModel.undoCurrentSubstitution()
                        }
                    } else if !MoveKitExerciseCatalog.substitutes(for: exercise.plan).isEmpty {
                        Button("Swap exercise", systemImage: "arrow.triangle.2.circlepath") {
                            substitutionSource = exercise.plan
                        }
                    }
                }
                Button(localization.string(viewModel.isPaused ? "Resume workout" : "Pause workout"),
                       systemImage: viewModel.isPaused ? "play.fill" : "pause.fill") {
                    viewModel.togglePause(at: date)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .zoIcon(ZOIcon.row)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Workout options")
        }
        .zoText(.section)
        .foregroundStyle(localInk)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private func workoutHeader(
        exercise: WorkoutExercise,
        currentSet: Int,
        artworkHeight: CGFloat
    ) -> some View {
        let exerciseArtwork = artwork(for: exercise, level: .card)
        let confirmedSets = confirmedCurrentExerciseSetCount(for: exercise)
        // Title and set share a baseline; at accessibility sizes they stack.
        let titleRow = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ZOSpace.s))

        return VStack(alignment: .leading, spacing: 10) {
            // Proof 42: only when local History is readable and holds no
            // workout but this one. Unavailable History never claims it.
            if isFirstWorkout {
                ZOBadge(text: localization.string("Your first workout"), isInk: true)
                    .id(exercise.id)
                    .transition(handoffTransition(for: exercise, arrival: .landing(0.36)))
            }

            // Proof 37: the exercise as a title, "Set 1 of 2" beside it.
            titleRow {
                Text(exercise.plan.name)
                    .zoText(.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($firstWorkingSetFocused)
                    .modifier(WorkoutExerciseCarrier(
                        exerciseID: exercise.id, part: .title, site: .header,
                        namespace: exerciseHandoff, enabled: allowsSpatialMotion
                    ))
                    .id(exercise.id)
                    .transition(handoffTransition(for: exercise, arrival: .carriedTitle))

                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }

                // The set line belongs to its exercise; at a handoff it lands at 420 ms.
                Text(confirmedSets == exercise.plan.plannedSetCount ? workoutCopy.savedProgress(confirmedSets, of: exercise.plan.plannedSetCount) : workoutCopy.setPosition(currentSet, of: exercise.plan.plannedSetCount))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                    .accessibilityLabel(
                        localization.format("Set %1$lld of %2$lld, %3$lld saved in this exercise", .integer(currentSet), .integer(exercise.plan.plannedSetCount), .integer(confirmedSets))
                    )
                    .id(exercise.id)
                    .transition(handoffTransition(for: exercise, arrival: .landing(0.42)))
            }

            if exercise.originalPlan != nil {
                HStack(spacing: ZOSpace.m) {
                    Text("SWAPPED FOR TODAY")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    if viewModel.canSubstituteCurrentExercise,
                       exercise.id == viewModel.session.currentExercise?.id {
                        Button("Undo swap") { _ = viewModel.undoCurrentSubstitution() }
                            .zoText(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accentForeground)
                            .frame(minHeight: 44)
                            .accessibilityHint("Restores the planned exercise before its first working set.")
                    }
                }
            }

            if let video = MoveKitExerciseCatalog.match(for: exercise.plan.exerciseID) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    // Identity follows the exercise: a new player per exercise,
                    // the same player across its sets and rests.
                    MoveKitVideoPlayer(
                        exercise: video.exercise,
                        playbackAllowed: exerciseGuidePlan == nil && substitutionSource == nil
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: artworkHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.card))
                    .modifier(WorkoutExerciseCarrier(
                        exerciseID: exercise.id, site: .header, namespace: exerciseHandoff,
                        enabled: allowsSpatialMotion
                    ))
                    .id(exercise.id)
                    .transition(handoffTransition(for: exercise, arrival: .carriedMedia))
                    Text(video.relationship.label.uppercased())
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)
                        .id(exercise.id)
                        .transition(handoffTransition(for: exercise, arrival: .landing(0.36)))
                }
            } else {
                ZeroOneActiveExerciseStage(
                    artwork: exerciseArtwork,
                    height: artworkHeight
                )
                .id(exercise.id)
                .transition(handoffTransition(for: exercise, arrival: .landing(0.12)))
            }
        }
    }

    /// Keeps the first-workout orientation available at the moment it matters,
    /// without creating a second session or changing any workout authority.
    /// The copy is shared with the onboarding walkthrough and is intentionally
    /// display-only: the primary dock remains the only way to log a set.
    private func firstWorkoutInlineTips(movementName: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                inlineTip(
                    title: "Open your plan",
                    detail: localization.string("Choose a saved workout and review its warm-up. Recording begins when you start."),
                    number: 1,
                    identifier: "workout.firstWorkoutTips.step1"
                )
                Divider().overlay(theme.strokeSubtle)
                inlineTip(
                    title: "Log what you actually did",
                    detail: localization.format("For movements such as %1$@, enter your actual load and reps after each set. Undo last set corrects a mistake.", .text(movementName)),
                    number: 2,
                    identifier: "workout.firstWorkoutTips.step2"
                )
                Divider().overlay(theme.strokeSubtle)
                inlineTip(
                    title: "Rest, then keep going",
                    detail: localization.string("Rest starts after a saved set. Start the next set when ready. Finish saves your completed work to History, even if you end early."),
                    number: 3,
                    identifier: "workout.firstWorkoutTips.step3"
                )
            }
            .padding(.top, ZOSpace.s)
        } label: {
            Label("Know what happens next.", systemImage: "info.circle")
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
        }
        .tint(theme.textPrimary)
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .accessibilityIdentifier("workout.firstWorkoutTips")
    }

    private func inlineTip(title: LocalizedStringKey, detail: String, number: Int, identifier: String) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Text(number.formatted())
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
                .frame(width: ZOSpace.xxl, alignment: .leading)
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(title).zoText(.section)
                Text(verbatim: detail)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, ZOSpace.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// True only when local History is readable and holds no workout other
    /// than this session. A recorded-unknown or unreadable History is not a
    /// first workout.
    private var isFirstWorkout: Bool {
        workoutHistory.availability == .available
            && workoutHistory.entries.allSatisfy { $0.id == viewModel.session.id }
    }

    private enum HandoffArrival {
        /// The card title travels by position; both titles are 24 pt.
        case carriedTitle
        /// The card poster becomes the player through the shared carrier.
        case carriedMedia
        /// Lands after the carried parts, at the given delay.
        case landing(Double)
    }

    /// Only a live handoff moves the header. The finished exercise lifts 36 pt
    /// and fades from 60 to 240 ms, gone before the poster is large; the next
    /// one arrives carried or lands. Other identity changes crossfade.
    private func handoffTransition(for exercise: WorkoutExercise, arrival: HandoffArrival) -> AnyTransition {
        guard allowsSpatialMotion else { return .opacity }
        let removal: AnyTransition = exercise.id == viewModel.restingCompletedExercise?.id
            ? .opacity.combined(with: .offset(y: -36)).animation(WorkoutMotion.leave(0.18).delay(0.06))
            : .opacity
        guard exercise.id == handoffCarrierExerciseID else {
            return .asymmetric(insertion: .opacity, removal: removal)
        }
        let insertion: AnyTransition
        switch arrival {
        case .carriedTitle:
            insertion = .scale(scale: WorkoutHandoffTitle.cardToHeadlineScale, anchor: .topLeading)
        case .carriedMedia:
            insertion = .identity
        case let .landing(delay):
            insertion = .opacity.combined(with: .offset(y: 10))
                .animation(WorkoutMotion.land(0.24).delay(delay))
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }

    @ViewBuilder
    private func exerciseGuidance(for plan: ExercisePlan) -> some View {
        if plan.coachingCue != nil || preferredAlternativeName(for: plan) != nil {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("COACHING CUE")
                    .zoText(.caption)

                    .foregroundStyle(theme.accentForeground)

                if let cue = plan.coachingCue {
                    Text(cue)
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                }

                if let alternativeName = preferredAlternativeName(for: plan) {
                    HStack(spacing: ZOSpace.s) {
                        Image(systemName: "arrow.triangle.swap")
                        Text(localization.format("Equipment option: %1$@", .text(alternativeName)))
                    }
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.vertical, ZOSpace.s)
        }
    }

    private func preferredAlternativeName(for plan: ExercisePlan) -> String? {
        if let alternativeID = plan.alternativeExerciseIDs.first {
            return ExerciseLibrary.exercise(id: alternativeID)?.name
        }
        return plan.unresolvedAlternativeNames.first
    }

    @ViewBuilder
    private var adaptationControl: some View {
        if viewModel.session.isAdapted {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZOSpace.s) {
                    adaptationActiveLabel
                    Spacer()
                    undoAdaptationButton
                }

                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    adaptationActiveLabel
                    if viewModel.canUndoAdaptation {
                        undoAdaptationButton
                    }
                }
            }
            .padding(.vertical, ZOSpace.s)
            .frame(minHeight: 48)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.strokeSubtle).frame(height: 1)
            }
        } else {
            Button {
                viewModel.proposeThirtyMinuteAdaptation()
                showsAdaptationProposal = viewModel.pendingAdaptation != nil
            } label: {
                HStack(spacing: ZOSpace.s) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    Text("Shorten to 30 minutes")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .zoIcon(ZOIcon.row)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .zoText(.section)
            .foregroundStyle(theme.textPrimary)
            .frame(minHeight: 48)
            .padding(.vertical, ZOSpace.s)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.strokeSubtle).frame(height: 1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows a deterministic shorter workout proposal before applying it.")
        }
    }

    private var adaptationActiveLabel: some View {
        HStack(spacing: ZOSpace.s) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(theme.accentForeground)

            Text("Adjusted workout active")
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var undoAdaptationButton: some View {
        if viewModel.canUndoAdaptation {
            Button("Undo") {
                withAnimation(reduceMotion ? nil : ZeroOneMotion.standard) {
                    viewModel.undoAdaptation()
                }
            }
            .zoText(.section)
            .foregroundStyle(theme.textPrimary)
            .frame(minHeight: 44)
        }
    }

    private func artwork(for exercise: WorkoutExercise, level: ExerciseVisualLevel) -> ExerciseArtwork {
        ExerciseArtwork(
            exerciseID: exercise.plan.exerciseID,
            exerciseName: exercise.plan.name,
            level: level
        )
    }

    /// Rest is on screen: the same conditions the single rest panel had.
    private var isShowingRest: Bool {
        !viewModel.session.isComplete && !viewModel.requiresWarmUpGate && !viewModel.isPaused
            && viewModel.persistenceErrorMessage == nil
            && (viewModel.session.restEndsAt != nil || viewModel.awaitingNextSetAcknowledgement)
    }

    /// One part of the rest panel, built from the same facts as before. Only
    /// `.full` reads `availableHeight`, and the workout no longer draws it.
    private func restPanel(_ part: RestTimerPanel.Part, exercise: WorkoutExercise,
                           currentSet: Int, date: Date) -> RestTimerPanel {
        RestTimerPanel(
            availableHeight: 0,
            remainingSeconds: viewModel.remainingRestSeconds(at: date),
            totalSeconds: viewModel.activeRestDurationSeconds,
            nextSetSummary: localization.format("%1$@ · %2$@ × %3$@", .text(workoutCopy.setPosition(currentSet, of: exercise.plan.plannedSetCount)), .text(plannedLoadSummary(for: exercise)), .text(workoutCopy.draftPerformance(exercise.plan.isTimed ? viewModel.durationDraft : viewModel.repsDraft, isTimed: exercise.plan.isTimed, perSide: exercise.plan.prescription.perSide))),
            nextExerciseName: exercise.plan.name,
            savedSet: (viewModel.persistedActivity?.sessionID == viewModel.session.id
                && viewModel.persistedActivity?.state.completedSets
                    == viewModel.session.completedSetCount)
                ? viewModel.session.exercises.flatMap(\.completedSets).last
                : nil,
            savedSetNumber: latestSavedExercise?.completedSets.count,
            targetReps: latestSavedExercise?.plan.targetReps ?? exercise.plan.targetReps,
            response: confirmedSetResponse,
            guidance: viewModel.lastSetGuidance,
            selectedNextLoad: Load(
                viewModel.enteredLoadValue, unit: exercise.plan.targetLoad.unit
            ),
            canChooseNextLoad: currentSet > 1
                && exercise.completedSets.last?.id == confirmedSetResponse?.id,
            nextActionTitle: workoutCopy.primaryTitle(.startSet(number: currentSet, exerciseName: exercise.plan.name)),
            canAdvance: viewModel.persistenceErrorMessage == nil,
            staggerEntrance: staggersRestEntrance,
            coachLineShown: viewModel.restingCompletedExercise == nil && restResponseLine != nil,
            part: part,
            onAddTime: { viewModel.addRestSeconds(at: date) },
            onSubtractTime: { viewModel.shortenRestSeconds(at: date) },
            onUndo: { viewModel.undoLastSet(expectedSetID: $0) },
            onSkip: advanceToNextSet,
            onSelectNextLoad: viewModel.selectLoad
        )
    }

    private func setEditor(exercise: WorkoutExercise, currentSet: Int) -> some View {
        let state = previousState(for: exercise)
        let confirmed = confirmedSets(of: exercise)
        let comparison = WorkoutComparisonPresentation(
            state: state, confirmedSets: confirmed, currentSet: currentSet,
            plannedSetCount: exercise.plan.plannedSetCount, prescription: exercise.plan.prescription
        )
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            PreviousPerformanceSection(
                state: state,
                confirmedSets: confirmed,
                currentSet: currentSet,
                plannedSetCount: exercise.plan.plannedSetCount,
                prescription: exercise.plan.prescription
            )
            // Display only. The steppers below are the one way to change a number.
            WorkoutCoachLineView(lines: [coachLines.target(
                plan: exercise.plan, isSwappedIn: exercise.originalPlan != nil,
                setNumber: currentSet, comparison: comparison
            )])
            exerciseGuidance(for: exercise.plan)
            demandAdaptationControl
            adaptationControl
        }
    }

    /// Rest and the next-exercise moment, in proof 37's order. Lines and bars
    /// use only sets inside the persisted prefix; a held, unconfirmed set never
    /// appears. `exercise` is the one just worked (the finished one at a
    /// handoff); `current` is the session's current exercise, whose next set
    /// the rest panel's facts and actions describe, exactly as before.
    private func restingContent(exercise: WorkoutExercise, presentedSet: Int,
                                current: WorkoutExercise, currentSet: Int, date: Date) -> some View {
        let state = previousState(for: exercise)
        let confirmed = confirmedSets(of: exercise)
        let isHandoff = viewModel.restingCompletedExercise?.id == exercise.id
        let next = viewModel.nextExercisePreview
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            if isHandoff {
                // "Goblet squat, done", its bars, then one line.
                PreviousPerformanceSection(
                    state: state, confirmedSets: confirmed, currentSet: presentedSet,
                    plannedSetCount: exercise.plan.plannedSetCount,
                    prescription: exercise.plan.prescription,
                    heading: localization.format("%1$@, done", .text(exercise.plan.name))
                )
                WorkoutCoachLineView(lines: [coachLines.handoff(
                    exerciseName: exercise.plan.name, savedSetCount: confirmed.count,
                    comparison: WorkoutComparisonPresentation.exerciseComparison(savedSets: confirmed, previousPerformance: state)
                )])
            } else if let line = restResponseLine {
                WorkoutCoachLineView(lines: [line])
            }

            restPanel(.clock, exercise: current, currentSet: currentSet, date: date)

            if !isHandoff {
                PreviousPerformanceSection(
                    state: state, confirmedSets: confirmed, currentSet: presentedSet,
                    plannedSetCount: exercise.plan.plannedSetCount,
                    prescription: exercise.plan.prescription
                )
            }

            if let next, next.canStart {
                // Proof 37's next exercise: its poster and name, then the
                // ghost to beat (last time only, never a target).
                upNext(next)
                restPanel(.details, exercise: current, currentSet: currentSet, date: date)
            } else {
                restPanel(.details, exercise: current, currentSet: currentSet, date: date)
                if let next {
                    upNext(next)
                }
            }
        }
    }

    @ViewBuilder
    private func upNext(_ next: WorkoutNextExercisePreview) -> some View {
        WorkoutNextExerciseCard(
            preview: next,
            namespace: exerciseHandoff,
            motionEnabled: allowsSpatialMotion,
            onStart: advanceToNextSet
        )
        if next.canStart {
            PreviousPerformanceSection(
                state: previousState(for: next.exercise), confirmedSets: [], currentSet: 0,
                plannedSetCount: next.exercise.plan.plannedSetCount,
                prescription: next.exercise.plan.prescription,
                showsToday: false
            )
        }
    }

    @ViewBuilder
    private func previousRailView() -> some View {
        if let rail = WorkoutPreviousRail(exercises: viewModel.session.exercises, previous: { id in
            workoutHistory.previousPerformance(for: id, excluding: viewModel.session.id)
        }) {
            WorkoutPreviousRailView(rail: rail)
        }
    }

    private var coachLines: WorkoutCoachLines { WorkoutCoachLines(localization: localization) }

    private func previousState(for exercise: WorkoutExercise) -> PreviousExercisePerformanceState {
        workoutHistory.previousPerformance(for: exercise.plan.exerciseID, excluding: viewModel.session.id)
    }

    /// This occurrence's sets inside the persisted prefix only.
    private func confirmedSets(of exercise: WorkoutExercise) -> [CompletedSet] {
        Array(exercise.completedSets.prefix(confirmedCurrentExerciseSetCount(for: exercise)))
    }

    /// The reply to the latest set, only once storage acknowledged it.
    private var restResponseLine: WorkoutCoachLine? {
        guard viewModel.persistenceErrorMessage == nil,
              confirmedTotalSetCount == viewModel.session.completedSetCount,
              let exercise = latestSavedExercise,
              let saved = exercise.completedSets.last else { return nil }
        return coachLines.response(
            savedSet: saved, setNumber: exercise.completedSets.count,
            targetReps: exercise.plan.targetReps, response: confirmedSetResponse,
            history: WorkoutComparisonPresentation.history(for: previousState(for: exercise))
        )
    }

    /// Proof 37's "Log 16 kg × 11": shown only while both drafts parse to the
    /// exact values Log will commit, for untimed, two-sided repetition sets.
    private var logSummary: String? {
        guard case .logSet = viewModel.dockRole,
              let exercise = viewModel.session.currentExercise,
              !exercise.plan.isTimed, !exercise.plan.prescription.perSide else { return nil }
        let loadText = viewModel.loadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let load = Double(loadText), load.isFinite, load > 0, load == viewModel.enteredLoadValue,
              let reps = Int(viewModel.repsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1 ... 50).contains(reps), reps == viewModel.enteredReps else { return nil }
        return localization.format("%1$@ × %2$@",
            .text(workoutCopy.load(Load(load, unit: exercise.plan.targetLoad.unit))), .text(String(reps)))
    }

    @ViewBuilder
    private var demandAdaptationControl: some View {
        if demandAuthority != nil, viewModel.canReviewDemandAdaptation,
           let assessment = wellbeingAssessment, assessment.isCurrent(at: .now),
           assessment.hasCurrentRecoveryReport,
           !assessment.recommendations.contains(where: { $0.demand == .pauseForSymptoms }),
           assessment.recommendations.contains(where: {
               $0.demand == .easeTraining && ($0.kind == .recovery || $0.kind == .fuelling)
           }) {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("Review today's demands").zoText(.section)
                Text("Your check-in suggests considering lighter work or rest.")
                    .zoText(.caption).foregroundStyle(.secondary)
                ForEach(WorkoutDemandChange.allCases, id: \.self) { change in
                    Button(localization.string(change.titleKey)) { prepareDemandProposal(change) }
                        .buttonStyle(ZOButtonStyle(.secondary)).disabled(isCheckingDemand)
                }
                if isCheckingDemand { ProgressView("Checking current records") }
            }
        }
    }

    private func prepareDemandProposal(_ change: WorkoutDemandChange) {
        guard !isCheckingDemand else { return }
        isCheckingDemand = true
        Task { @MainActor in
            let assessment = await demandAuthority?.assessment(at: .now)
            // Read the clock again after awaiting the host's store reads.
            viewModel.proposeDemandAdaptation(change, assessment: assessment, at: .now)
            isCheckingDemand = false
            showsDemandProposal = viewModel.pendingDemandAdaptation != nil
        }
    }

    private func applyDemandProposal() {
        guard !isCheckingDemand else { return }
        isCheckingDemand = true
        Task { @MainActor in
            let assessment = await demandAuthority?.assessment(at: .now)
            let saved = viewModel.applyPendingDemandAdaptation(assessment: assessment, at: .now)
            isCheckingDemand = false
            // A failed save holds the accepted prescription in the existing
            // workout Retry flow. Never label that in-memory state as saved.
            if saved || viewModel.pendingDemandAdaptation == nil { showsDemandProposal = false }
        }
    }

    /// Study 09 places the offer in the console, directly above the load it changes.
    @ViewBuilder
    private func progressionOffer(
        exercise: WorkoutExercise,
        previousPerformance: PreviousExercisePerformanceState
    ) -> some View {
        if let opportunity = (progression?.engine ?? WorkoutProgressionEngine()).availableOpportunity(
            for: exercise.plan, previousPerformance: previousPerformance
        ), viewModel.canShowProgressionOffer(for: exercise) {
            WorkoutProgressionOpportunitySection(
                opportunity: opportunity,
                reason: workoutCopy.progressionReason(
                    for: opportunity,
                    previousPerformance: previousPerformance,
                    targetReps: exercise.plan.targetReps
                ),
                selectedLoadValue: viewModel.enteredLoadValue,
                selection: viewModel.progressionOfferSelections[exercise.plan.id],
                canChoose: viewModel.persistenceErrorMessage == nil,
                onPrepare: { viewModel.prepareProgressionOffer(opportunity) },
                onTry: { viewModel.selectProgressionOffer(.tryNext, opportunity: opportunity) },
                onRepeat: { viewModel.selectProgressionOffer(.repeatPrevious, opportunity: opportunity) }
            )
        }
    }

    private var confirmedTotalSetCount: Int {
        guard viewModel.persistedActivity?.sessionID == viewModel.session.id else { return 0 }
        return viewModel.persistedActivity?.state.completedSets ?? 0
    }

    private var confirmedActiveSetCount: Int? {
        guard viewModel.persistenceErrorMessage == nil,
              let activity = viewModel.persistedActivity,
              activity.sessionID == viewModel.session.id else { return nil }
        return activity.state.completedSets
    }

    private var savedSetFeedbackCount: Int {
        viewModel.session.isComplete && viewModel.isCompletionSaved
            ? viewModel.session.completedSetCount : confirmedTotalSetCount
    }

    private var confirmedStepUpMoment: WorkoutSetProgressMoment? {
        guard viewModel.persistenceErrorMessage == nil,
              savedSetFeedbackCount == viewModel.session.completedSetCount,
              let exercise = viewModel.session.exercises.last(where: { !$0.completedSets.isEmpty }),
              let savedSet = exercise.completedSets.last else { return nil }
        let previous = workoutHistory.previousPerformance(
            for: exercise.plan.exerciseID, excluding: viewModel.session.id
        )
        // Earlier confirmed progress in the same exercise already earned its
        // one animated moment. This also survives recovery of a saved session.
        let earlierSets = exercise.completedSets.dropLast()
        guard !earlierSets.enumerated().contains(where: { index, set in
            WorkoutSetProgressMoment.evaluate(
                savedSet: set, setNumber: index + 1, previousPerformance: previous
            ) != nil
        }) else { return nil }
        return WorkoutSetProgressMoment.evaluate(
            savedSet: savedSet,
            setNumber: exercise.completedSets.count,
            previousPerformance: previous
        )
    }

    private var confirmedSetResponse: WorkoutSetResponse? {
        guard viewModel.persistenceErrorMessage == nil,
              confirmedTotalSetCount == viewModel.session.completedSetCount,
              let exercise = viewModel.session.exercises.last(where: { !$0.completedSets.isEmpty }),
              let savedSet = exercise.completedSets.last else { return nil }
        return WorkoutSetResponse.evaluate(
            savedSet: savedSet,
            setNumber: exercise.completedSets.count,
            targetReps: exercise.plan.targetReps,
            previousPerformance: workoutHistory.previousPerformance(
                for: exercise.plan.exerciseID, excluding: viewModel.session.id
            )
        )
    }

    private func confirmedCurrentExerciseSetCount(for exercise: WorkoutExercise) -> Int {
        guard let index = viewModel.session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return 0 }
        let earlierSets = viewModel.session.exercises
            .prefix(index)
            .reduce(0) { $0 + $1.completedSets.count }
        return min(exercise.completedSets.count, max(0, confirmedTotalSetCount - earlierSets))
    }

    private func advanceToNextSet() {
        guard !viewModel.isPaused, viewModel.persistenceErrorMessage == nil,
              viewModel.session.restEndsAt != nil || viewModel.awaitingNextSetAcknowledgement else { return }
        let isHandoff = viewModel.restingCompletedExercise != nil
        // The role change's own implicit animation carries the timing; this
        // transaction only names the arriving exercise for its carriers.
        if isHandoff, allowsSpatialMotion {
            handoffCarrierExerciseID = viewModel.session.currentExercise?.id
        }
        withAnimation(allowsSpatialMotion
                      ? WorkoutMotion.carry(isHandoff ? 0.48 : 0.3).delay(0.12)
                      : .easeOut(duration: isHandoff ? 0.24 : 0.18)) {
            viewModel.skipRest()
        }
        guard viewModel.persistenceErrorMessage == nil else {
            handoffCarrierExerciseID = nil
            return
        }
        if isHandoff { nextExerciseFeedback += 1 }
        else { nextSetFeedback += 1 }
    }

    private func reconcileWorkoutPresentation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            stepUpMoment = nil
            viewModel.advanceElapsedRest(at: .now)
        }
        lastForegroundRestTick = .now
        observesForegroundRest = scenePhase == .active
    }

    private func handleForegroundRestTick(at date: Date) {
        guard scenePhase == .active, observesForegroundRest else { return }
        let previousTick = lastForegroundRestTick
        lastForegroundRestTick = date
        if viewModel.advanceElapsedRest(at: date) {
            nextSetFeedback += 1
            if voiceOverEnabled, let nextSet = viewModel.session.currentSetNumber {
                AccessibilityNotification.Announcement("Rest done. Set \(nextSet) is ready.").post()
            }
            return
        }
        guard !viewModel.isPaused, viewModel.persistenceErrorMessage == nil,
              viewModel.activeRestDurationSeconds > 0,
              viewModel.restingCompletedExercise != nil,
              let deadline = viewModel.session.restEndsAt,
              let previousTick, previousTick < deadline, date >= deadline else { return }
        // The rest line has just become "Start <next exercise>" under the
        // user's finger; the role did not change, so arm the guard here.
        dockGuard.roleChanged(at: date)
        handoffRestFeedback += 1
        if voiceOverEnabled {
            AccessibilityNotification.Announcement("Rest done. Start the next exercise when ready.").post()
        }
    }

    private func trainingSetConsole(
        exercise: WorkoutExercise,
        currentSet: Int,
        availableWidth: CGFloat
    ) -> some View {
        let previous = workoutHistory.previousPerformance(
            for: exercise.plan.exerciseID, excluding: viewModel.session.id
        )
        let matchingSet: CompletedSet? = {
            guard case let .recorded(performance) = previous,
                  let occurrence = performance.occurrences.last(where: { !$0.completedSets.isEmpty }),
                  occurrence.completedSets.indices.contains(currentSet - 1) else { return nil }
            return occurrence.completedSets[currentSet - 1]
        }()
        let progressionStep = WorkoutProgressionEngine().loadIncrement(for: exercise.plan)
        let loadStep = progressionStep > 0
            ? progressionStep
            : (exercise.plan.targetLoad.unit == .pounds ? 5.0 : 2.5)

        let inputs = WorkoutSetInputGroup(
                loadDraft: $viewModel.loadDraft,
                loadUnit: exercise.plan.targetLoad.unit.rawValue,
                availableWidth: availableWidth,
                isTimed: exercise.plan.isTimed,
                perSide: exercise.plan.prescription.perSide,
                repsDraft: exercise.plan.isTimed ? $viewModel.durationDraft : $viewModel.repsDraft,
                isEditing: $isEditingSet,
                rir: viewModel.enteredRIR,
                previousSetSummary: matchingSet.map { localization.format("Last time, set %1$lld: %2$@", .integer(currentSet), .text(workoutCopy.setSummary($0))) } ?? localization.string("No matching set recorded"),
                targetSummary: localization.format("Target %1$@", .text(workoutCopy.prescription(exercise.plan.prescription))),
                progressionCue: workoutCopy.progressionGuidance(exercise.plan),
                inputError: viewModel.inputErrorMessage,
                onCommit: { viewModel.commitDrafts() },
                decrementLoad: { viewModel.adjustLoad(by: -loadStep) },
                incrementLoad: { viewModel.adjustLoad(by: loadStep) },
                decrementReps: { viewModel.adjustReps(by: -1) },
                incrementReps: { viewModel.adjustReps(by: 1) },
                decrementRIR: { viewModel.adjustRIR(by: -1) },
                incrementRIR: { viewModel.adjustRIR(by: 1) },
                startRIR: viewModel.startTrackingRIR,
                clearRIR: viewModel.clearRIR
        )

        let consoleContent = VStack(alignment: .leading, spacing: ZOSpace.s) {
            progressionOffer(exercise: exercise, previousPerformance: previous)
            if let undoNotice = viewModel.undoNotice {
                Label(undoNotice, systemImage: "arrow.uturn.backward")
                    .zoText(.caption).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("workout.undoNotice")
            }
            inputs
        }

        // The workout's main scroll owns these inputs at every text size.
        // The Log action alone stays docked, as in final proof 37.
        return consoleContent
        .id("\(exercise.id)-\(currentSet)")
        .padding(ZOSpace.cardPadding)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
        .accessibilityIdentifier("workout.scrollableSetInputs")
    }

    private var adaptationErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.adaptationError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearAdaptationError()
                }
            }
        )
    }

    private var demandErrorBinding: Binding<Bool> {
        Binding(get: { !showsDemandProposal && viewModel.demandAdaptationError != nil },
                set: { if !$0 { viewModel.clearDemandAdaptationError() } })
    }

    private var adaptationErrorMessage: String {
        switch viewModel.adaptationError {
        case .workoutAlreadyStarted:
            return "A set is already logged. 01 will not rebuild this session or risk losing your work. Finish or exit the current session first."
        case .workoutCompleted:
            return "This workout is already complete."
        case .invalidTimeWindow:
            return "Choose a workout window between 5 and 180 minutes."
        case .invalidPrescription:
            return "Check this workout's sets, timing and rest before shortening it."
        case .cannotFitTimeWindow:
            return "This workout cannot fit that window while keeping its warm-up and prescribed rest."
        case .staleProposal:
            return "This workout or its time policy changed. Prepare a new proposal before applying it."
        case nil:
            return "The current workout cannot be changed safely."
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.completionError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearCompletionError()
                }
            }
        )
    }

    private var errorMessage: String {
        switch viewModel.completionError {
        case .workoutCompleted:
            return "This workout has already been completed."
        case .warmUpPending:
            return "Complete or skip the warm-up before logging a working set."
        case .restInProgress:
            return "Wait for the rest timer to finish before completing the next set."
        case .noCurrentExercise:
            return "There is no active exercise to complete."
        case .invalidLoad:
            return "Enter a positive load for this exercise."
        case .invalidReps:
            return "A completed set must include at least one rep."
        case .invalidDuration:
            return "Enter the actual completed duration in whole seconds."
        case .invalidRIR:
            return "Clean reps left must be between zero and five."
        case nil:
            return "An unexpected workout state prevented completion."
        }
    }
}

private struct WorkoutAdaptationProposalView: View {
    let proposal: WorkoutAdaptationProposal
    let onApply: () -> Void
    let onKeepOriginal: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("30 MINUTES")
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)

                    Text("Keep the useful work.")
                        .zoText(.display)
                        .foregroundStyle(theme.textPrimary)

                    Text("01 will shorten this session with fixed local rules. Nothing changes until you apply it.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(workoutCopy.adaptationChanges(for: proposal).enumerated()), id: \.offset) { index, change in
                        HStack(alignment: .top, spacing: ZOSpace.m) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.successPrimary)
                                .frame(width: 20)

                            Text(change)
                                .zoText(.section)
                                .foregroundStyle(theme.textPrimary)

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, ZOSpace.m)

                        if index < workoutCopy.adaptationChanges(for: proposal).count - 1 {
                            Rectangle()
                                .fill(theme.strokeSubtle)
                                .frame(height: 1)
                        }
                    }
                }

                Spacer(minLength: ZOSpace.l)

                Button("Use 30-Minute Version", action: onApply)
                    .buttonStyle(ZOButtonStyle(.primary))

                Button("Keep Original", action: onKeepOriginal)
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
            .padding(ZOSpace.xl)
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .preferredColorScheme(theme.colorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct WorkoutSubstitutionSheet: View {
    @Bindable var viewModel: WorkoutViewModel
    let sourcePlan: ExercisePlan

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneExerciseSubstitutionAuthority) private var authority
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var review: ExerciseSubstitutionReview?
    @State private var selectedID: ExerciseID?
    @State private var loadDraft = ""
    @State private var confirmsContext = false
    @State private var confirmedAt: Date?
    @State private var isChecking = false
    @State private var saveError: String?

    private var selectedAlternative: ExerciseSubstitutionCandidate? {
        review?.candidates.first { $0.definition.id == selectedID }
    }

    private var chosenLoad: Load? {
        let text = loadDraft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let selected = selectedAlternative, let value = Double(text), value.isFinite,
              value > 0 || (value == 0 && selected.definition.id == ExerciseIDs.pushUp) else { return nil }
        return Load(value, unit: sourcePlan.targetLoad.unit)
    }

    @FocusState private var loadIsFocused: Bool

    private var sourceDefinition: ExerciseDefinition? { ExerciseLibrary.exercise(id: sourcePlan.exerciseID) }

    /// Proof 39's swap sheet: a round close in the sheet bar, "Make today
    /// work", the qualified options as `.zo-alt` rows with their poster,
    /// target and factual reasons, the pain line, and "Swap to ..." in the
    /// dock. The context confirmation, the new exercise's own load and every
    /// gate are the existing ones; nothing is chosen automatically.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make today work").zoThemeText(.title).foregroundStyle(theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(localization.format("Swap %1$@ using confirmed equipment and exclusions. Sets and rest stay; the replacement has its own target. Only this workout changes.", .text(sourcePlan.name)))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let review {
                        VStack(spacing: ZOSpace.s) {
                            ForEach(review.candidates, id: \.definition.id) { candidate in
                                alternativeRow(candidate)
                            }
                        }
                        if let selected = selectedAlternative {
                            selectedDetail(selected)
                        }
                        contextCard(review)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").zoIcon(ZOIcon.inline).accessibilityHidden(true)
                        Text("A replacement is not a treatment for pain. Stop or skip a movement that causes pain.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    if let saveError {
                        Text(localization.string(saveError)).zoText(.label).foregroundStyle(theme.destructivePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isChecking { ProgressView("Checking current records").tint(theme.textPrimary) }
                    Button("Review alternatives again") { Task { await prepare() } }
                        .buttonStyle(ZOButtonStyle(.quiet))
                        .padding(.leading, -ZOSpace.m)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.xxl)
            }
            .disabled(isChecking)
            .background(theme.surfacePrimary.ignoresSafeArea())
            .toolbarBackground(theme.surfacePrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(localization.format("Change %1$@", .text(sourcePlan.name))).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").zoIcon(ZOIcon.row)
                            .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                            .background {
                                Circle().fill(theme.surfaceSecondary)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                    }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel("Cancel")
                        .disabled(isChecking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(selectedAlternative.map { localization.format("Swap to %1$@", .text($0.definition.name)) }
                       ?? localization.string("Use this exercise")) { Task { await apply() } }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .disabled(isChecking || chosenLoad == nil || confirmedAt == nil || !viewModel.canSubstituteCurrentExercise)
                    .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
                    .background(theme.backgroundPrimary)
            }
        }
        .presentationBackground(theme.surfacePrimary)
        .task { await prepare() }
        .interactiveDismissDisabled(isChecking)
        .preferredColorScheme(theme.colorScheme).presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    /// Proof `.zo-alt`: a 48 pt poster, the name, the target, the reasons as
    /// small chips and a radio; selected is surface 1 inside a 2 pt ink edge.
    private func alternativeRow(_ candidate: ExerciseSubstitutionCandidate) -> some View {
        let alternative = candidate.definition
        let isSelected = selectedID == alternative.id
        let reasons = ExerciseSwapPresentation.reasons(for: alternative, replacing: sourceDefinition)
        return Button {
            selectedID = alternative.id
            loadDraft = ""
            saveError = nil
        } label: {
            HStack(spacing: ZOSpace.m) {
                CustomWorkoutExerciseThumbnail(exercise: MoveKitExerciseCatalog.exercise(for: candidate.videoID),
                                               width: 48, height: 48, cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                                                   role: .control, radius: ZORadius.control).resolvedRadius)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alternative.name).zoText(.section)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(workoutCopy.prescription(candidate.target)).zoText(.caption).foregroundStyle(theme.textSecondary)
                    if !reasons.isEmpty {
                        ExerciseTagFlowLayout(spacing: ZOSpace.xs) {
                            ForEach(reasons, id: \.self) { reason in
                                Text(localization.string(reason))
                                    .zoProofText(.mini, size: 12, lineHeight: 16)
                                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                    .padding(.horizontal, ZOSpace.s)
                                    .frame(minHeight: 22)
                                    .background(isSelected ? theme.surfaceSecondary : theme.surfacePrimary, in: Capsule())
                            }
                        }
                        .padding(.top, ZOSpace.xs)
                    }
                    if !alternative.equipmentIdentifiers.isEmpty {
                        Text(alternative.equipmentIdentifiers.joined(separator: " · ")).zoText(.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().strokeBorder(isSelected ? theme.textPrimary : theme.textTertiary,
                                          lineWidth: isSelected ? 0 : ZOStroke.control)
                    if isSelected {
                        Circle().fill(theme.textPrimary)
                        Image(systemName: "checkmark").zoIcon(16).foregroundStyle(theme.backgroundPrimary)
                    }
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 10).padding(.leading, 10).padding(.trailing, ZOSpace.m)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(isSelected ? theme.surfacePrimary : theme.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                            role: .card).resolvedRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                    role: .card).resolvedRadius, style: .continuous)
                    .strokeBorder(isSelected ? theme.textPrimary : .clear, lineWidth: ZOStroke.focus)
            }
            .contentShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                role: .card).resolvedRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(localization.string(isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The chosen option's loop, its cue and its own load. The old exercise's
    /// weight and history are never copied.
    private func selectedDetail(_ selected: ExerciseSubstitutionCandidate) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            if let match = MoveKitExerciseCatalog.match(for: selected.definition.id) {
                MoveKitVideoPlayer(exercise: match.exercise).id(selected.definition.id)
                    .frame(maxWidth: .infinity).frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                        role: .card).resolvedRadius, style: .continuous))
            }
            Text(selected.definition.shortCoachingCue).zoText(.body).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose this exercise's load").zoText(.section).padding(.top, ZOSpace.xs)
            Text("The old exercise's weight and history are not copied. Enter a load you can use safely today.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(localization.format("Load (%1$@)", .text(sourcePlan.targetLoad.unit.rawValue)), text: $loadDraft)
                .keyboardType(.decimalPad)
                .zoText(.body)
                .focused($loadIsFocused)
                .padding(.horizontal, ZOSpace.l)
                .frame(minHeight: ZOSpace.rowMinHeight)
                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(
                    theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                        role: .control, radius: ZORadius.control).resolvedRadius)
                        .strokeBorder(loadIsFocused ? theme.textPrimary : theme.separatorStrong,
                                      lineWidth: loadIsFocused ? ZOStroke.focus : ZOStroke.control)
                }
                .accessibilityIdentifier("workout.substitutionLoad")
        }
    }

    /// The equipment and movement answers the options were filtered by, and
    /// the confirmation that they still apply today.
    private func contextCard(_ review: ExerciseSubstitutionReview) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("Equipment and movement context").zoText(.section)
            Text(verbatim: (review.context.profile.availableEquipment ?? []).sorted { $0.rawValue < $1.rawValue }
                .map { localization.string($0.title) }.joined(separator: " · "))
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            let preferences = review.context.profile.starterSelectionPreferences ?? StarterSelectionPreferences()
            Group {
                Text(localization.format("Experience: %1$@", .text(localization.string(review.context.profile.trainingExperience?.title ?? "Not sure"))))
                Text(verbatim: localization.string(review.context.profile.trainingConstraint?.title ?? "Not sure"))
                ForEach(preferences.confirmedEquipment.sorted { $0.rawValue < $1.rawValue }, id: \.self) { requirement in
                    Text(verbatim: localization.string(requirement.titleKey))
                }
                ForEach(preferences.blockedExerciseIDs.sorted { $0.rawValue < $1.rawValue }, id: \.self) { id in
                    Text(localization.format("Excluded: %1$@", .text(ExerciseLibrary.exercise(id: id)?.name ?? localization.string("Other excluded exercise"))))
                }
                ForEach(preferences.blockedGroups.sorted { $0.rawValue < $1.rawValue }, id: \.self) { group in
                    Text(localization.format("Excluded: %1$@", .text(localization.string(group.titleKey))))
                }
            }
            .zoText(.caption).foregroundStyle(theme.textSecondary)
            Toggle("These equipment and movement answers still apply today", isOn: $confirmsContext)
                .zoText(.label)
                .tint(theme.textPrimary)
                .onChange(of: confirmsContext) { _, confirmed in confirmedAt = confirmed ? .now : nil }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    @MainActor private func prepare() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        review = nil
        selectedID = nil
        loadDraft = ""
        confirmsContext = false
        confirmedAt = nil
        saveError = nil
        do {
            guard let authority, viewModel.canSubstituteCurrentExercise,
                  viewModel.session.currentExercise?.plan == sourcePlan else { throw ExerciseSubstitutionSelectionError.stale }
            let context = try await authority.context(for: viewModel.session)
            guard viewModel.canSubstituteCurrentExercise, viewModel.session.currentExercise?.plan == sourcePlan else {
                throw ExerciseSubstitutionSelectionError.stale
            }
            review = try ExerciseSubstitutionSelector().review(session: viewModel.session, input: viewModel.substitutionInput,
                context: context, availableVideoIDs: MoveKitExercise.availableVideoIDs, at: .now)
        } catch let error as ExerciseSubstitutionSelectionError { saveError = error.messageKey }
        catch { saveError = ExerciseSubstitutionSelectionError.unavailable.messageKey }
    }

    @MainActor private func apply() async {
        guard !isChecking, let review, let selectedID, let chosenLoad, let authority else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let context = try await authority.context(for: viewModel.session)
            if try viewModel.substituteCurrentExercise(with: selectedID, load: chosenLoad, review: review,
                context: context, confirmedAt: confirmedAt, at: .now) {
                dismiss()
            } else if viewModel.persistenceErrorMessage != nil {
                dismiss() // The existing workout Retry gate retains the accepted change.
            } else { saveError = "This exercise is no longer available to swap. Your workout has not changed." }
        } catch let error as ExerciseSubstitutionSelectionError { saveError = error.messageKey }
        catch { saveError = ExerciseSubstitutionSelectionError.unavailable.messageKey }
    }
}
