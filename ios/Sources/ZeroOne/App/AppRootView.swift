import SwiftUI
import os

@MainActor
struct AppRootView: View {
    @StateObject private var assembly: ZeroOneMountedRootAssembly

    init(
        userProfileRepository: ZeroOneUserProfileRepository? = nil,
        initialTab: AppTab? = nil,
        demoStateStore: any ZeroOneDemoStatePersisting = UserDefaultsZeroOneDemoStateStore(),
        programmeSelectionStore: any WorkoutProgrammeSelectionPersisting = UserDefaultsWorkoutProgrammeSelectionStore(),
        programmeScheduleStore: any WorkoutProgrammeSchedulePersisting = UserDefaultsWorkoutProgrammeScheduleStore(),
        programmeVolumeStore: any ProgrammeVolumePersisting = UserDefaultsProgrammeVolumeStore(),
        workoutHistoryStore: (any WorkoutHistoryPersisting)? = nil,
        workoutLoadChoiceStore: any WorkoutLoadChoicePersisting = UserDefaultsWorkoutLoadChoiceStore(),
        workoutProgressionReviewStore: any WorkoutProgressionReviewPersisting = UserDefaultsWorkoutProgressionReviewStore(),
        customWorkoutStore: any CustomWorkoutPersisting = UserDefaultsCustomWorkoutStore(),
        activeWorkoutStore: (any ActiveWorkoutPersisting)? = nil,
        hydrationStore: (any HydrationPersisting)? = nil,
        nutritionStore: any NutritionPersisting = UserDefaultsNutritionStore(),
        dietTrackerStore: any DietTrackerPersisting = FileDietTrackerStore(),
        progressPhotoStore: (any ProgressPhotoPersisting)? = nil,
        healthKitService: (any HealthKitServicing)? = nil,
        healthPreferenceStore: (any HealthConnectionPreferencePersisting)? = nil,
        bodyWeightStore: any BodyWeightPersisting = LocalBodyWeightStore(),
        stepsHealthService: (any StepsHealthServicing)? = nil,
        shareParent: ZeroOneShareParentLifetime? = nil
    ) {
        _assembly = StateObject(wrappedValue: ZeroOneMountedRootAssembly(parent: shareParent) { coordinator in
            ZeroOneMountedRootContent(
                userProfileRepository: userProfileRepository,
                initialTab: initialTab,
                demoStateStore: demoStateStore,
                programmeSelectionStore: programmeSelectionStore,
                programmeScheduleStore: programmeScheduleStore,
                programmeVolumeStore: programmeVolumeStore,
                workoutHistoryStore: workoutHistoryStore,
                workoutLoadChoiceStore: workoutLoadChoiceStore,
                workoutProgressionReviewStore: workoutProgressionReviewStore,
                customWorkoutStore: customWorkoutStore,
                activeWorkoutStore: activeWorkoutStore,
                hydrationStore: hydrationStore ?? HydrationStoreFactory.makeAppStore(),
                nutritionStore: nutritionStore,
                dietTrackerStore: dietTrackerStore,
                progressPhotoStore: progressPhotoStore,
                healthKitService: healthKitService,
                healthPreferenceStore: healthPreferenceStore,
                bodyWeightStore: bodyWeightStore,
                stepsHealthService: stepsHealthService,
                shareCoordinator: coordinator
            )
        })
    }

    var body: some View {
        assembly.content
            .environment(\.zeroOneRootShareCoordinator, assembly.coordinator)
    }

    // Preserve the existing test/review caller without creating an assembly.
    static func completedReviewSession(
        from source: WorkoutSession,
        startingAt: Date = .now.addingTimeInterval(-300),
        upgradeFirstExercise: Bool = false,
        stopAfterFirstExercise: Bool = false
    ) -> WorkoutSession {
        ZeroOneMountedRootContent.completedReviewSession(from: source,
            startingAt: startingAt, upgradeFirstExercise: upgradeFirstExercise,
            stopAfterFirstExercise: stopAfterFirstExercise)
    }
}

/// This initializer is itself evaluated only within StateObject's deferred
/// wrappedValue autoclosure. No discarded view reconstruction creates models.
@MainActor
private final class ZeroOneMountedRootAssembly: ObservableObject {
    let coordinator: ZeroOneRootShareCoordinator
    let content: ZeroOneMountedRootContent
    private let rootGate: ZeroOneShareRootGate?
    private let rootID: UUID

    init(parent: ZeroOneShareParentLifetime?,
         makeContent: (ZeroOneRootShareCoordinator) -> ZeroOneMountedRootContent) {
        let coordinator = ZeroOneRootShareCoordinator(parent: parent)
        self.coordinator = coordinator
        rootGate = parent?.rootGate
        rootID = coordinator.rootID
        content = makeContent(coordinator)
    }

    // A retained descendant coordinator cannot extend actual Root ownership.
    deinit { rootGate?.retireIfCurrent(rootID) }
}

@MainActor
private struct ZeroOneMountedRootContent: View {

    #if DEBUG
    private static let launchLogger = Logger(subsystem: "app.the01.ios", category: "Launch")
    #endif
    @AppStorage("slick.visualTheme") private var selectedThemeRawValue = ZeroOneThemeID.liquidMidnight.rawValue
    @AppStorage(DesignThemePreference.storageKey) private var selectedDesignThemeRawValue = DesignThemePreference.core.rawValue
    @AppStorage(AppearancePreference.storageKey) private var selectedAppearanceRawValue = AppearancePreference.system.rawValue
    @AppStorage(AccentPreference.storageKey) private var selectedAccentRawValue = AccentPreference.yellow.rawValue
    @Environment(\.dynamicTypeSize) private var inheritedDynamicTypeSize
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var shareScenePhase: ScenePhase = .inactive
    @Environment(\.zeroOneLocalization) private var localization
    @Namespace private var workoutMusicJoin
    @State private var selectedTabStorage: AppTab = .today
    private var selectedTab: AppTab {
        get { selectedTabStorage }
        nonmutating set {
            invalidateRootShareRoutes()
            selectedTabStorage = newValue
        }
    }
    private var selectedTabBinding: Binding<AppTab> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 })
    }
    @State private var workoutViewModel: WorkoutViewModel
    @State private var hydrationViewModel: HydrationViewModel
    @State private var nutritionRepository: NutritionRepository
    @State private var dietTrackerFeature: DietTrackerFeatureModel
    @State private var dailyContext: DailyAssistantContextStore
    @State private var demoState: ZeroOneDemoStateModel
    @State private var programmeCoordinator: WorkoutProgrammeCoordinator
    @State private var programmeVolume: ProgrammeVolumeRepository
    @State private var workoutHistory: WorkoutHistoryRepository
    @State private var workoutHistoryImport: WorkoutHistoryImportCoordinator?
    @State private var mealRecordImport: FoodBodyWeightImportCoordinator?
    @State private var bodyWeightRecordImport: FoodBodyWeightImportCoordinator?
    @State private var outdoorHistoryTransfer: OutdoorHistoryTransferCoordinator?
    @State private var workoutLoadChoices: WorkoutLoadChoiceRepository
    @State private var workoutProgression: WorkoutProgressionAuthority
    @State private var customWorkouts: CustomWorkoutRepository
    @State private var workoutAppointments: WorkoutAppointmentRepository
    @State private var appointmentCalendar: AppointmentCalendarCoordinator
    @State private var pendingScheduledReview: WorkoutAppointment?
    @State private var scheduledReviewStorage: WorkoutAppointment?
    @State private var scheduledReviewPresentationEpoch = UUID()
    private var scheduledReview: WorkoutAppointment? {
        get { scheduledReviewStorage }
        nonmutating set {
            guard newValue != scheduledReviewStorage else { return }
            invalidateRootShareRoutes()
            if newValue != nil { scheduledReviewPresentationEpoch = UUID() }
            scheduledReviewStorage = newValue
        }
    }
    private func scheduledReviewBinding(expectedEpoch: UUID) -> Binding<WorkoutAppointment?> {
        Binding(get: { scheduledReview }, set: { replacement in
            guard canHandleRootDomainCallback, scheduledReviewPresentationEpoch == expectedEpoch, replacement != scheduledReview else { return }
            scheduledReview = replacement
        })
    }
    @State private var pendingScheduledStart: WorkoutAppointment?
    @State private var scheduledStartWarmUp = WorkoutWarmUpLength.full
    @State private var scheduledWorkoutMessage: String?
    @State private var orphanScheduledLaunch: WorkoutAppointment?
    @State private var progressPhotos: ProgressPhotoRepository
    @State private var photoShareAuthority: PhotoComparisonShareHostAuthority
    @State private var bodyWeight: BodyWeightRepository
    @State private var learnRepository = LearnRepository()
    @State private var workoutMusic: WorkoutMusicStore
    @State private var smartNotes = SmartNoteCenter()
    @State private var membership = StoreKitMembershipStore(configuration: .current)
    @State private var trialMoments = TrialMomentStore()
    @State private var showsTrialRecap = false
    @State private var userProfile: ZeroOneUserProfileRepository
    @State private var healthConnection: HealthConnectionRepository
    @State private var stepsDay: StepsDayRepository
    @State private var dailyWidgetPublisher = DailyWidgetPublisher()
    @State private var dailyGoals = DailyGoalsRepository()
    @State private var wellbeing = WellbeingCheckInRepository()
    @State private var showsWellbeingReviewPresentationEpoch = UUID()
    @State private var showsWellbeingReviewStorage: Bool = false
    private var showsWellbeingReview: Bool {
        get { showsWellbeingReviewStorage }
        nonmutating set {
            guard newValue != showsWellbeingReviewStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsWellbeingReviewPresentationEpoch = UUID() }
            showsWellbeingReviewStorage = newValue
        }
    }
    private func showsWellbeingReviewBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsWellbeingReview }, set: { replacement in
            guard canHandleRootDomainCallback, showsWellbeingReviewPresentationEpoch == expectedEpoch, replacement != showsWellbeingReview else { return }
            showsWellbeingReview = replacement
        })
    }
    @State private var wellbeingOutdoorEvidence = WellbeingOutdoorEvidence()
    @State private var workoutDemand = WorkoutDemandAuthority()
    @State private var exerciseSubstitution = ExerciseSubstitutionAuthority()
    @State private var voiceAssistant: VoiceAssistantCoordinator?
    @State private var savedHistoryShareAuthority: SavedWorkoutHistoryShareAuthority
    @State private var savedWorkoutShare: SavedWorkoutShareRoute?
    @State private var savedWorkoutSharePresentationEpoch = UUID()
    @State private var savedSharePreparationGeneration = UUID()
    @State private var isPreparingSavedShare = false
    @State private var showsSavedShareUnavailable = false
    @State private var showsProfilePresentationEpoch = UUID()
    @State private var showsProfileStorage: Bool = false
    private var showsProfile: Bool {
        get { showsProfileStorage }
        nonmutating set {
            guard newValue != showsProfileStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsProfilePresentationEpoch = UUID() }
            showsProfileStorage = newValue
        }
    }
    private func showsProfileBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsProfile }, set: { replacement in
            guard canHandleRootDomainCallback, showsProfilePresentationEpoch == expectedEpoch, replacement != showsProfile else { return }
            if !replacement, isCurrentShareRoot { photoShareAuthority.revokeAll(before: .hostDismissal) }
            showsProfile = replacement
        })
    }
    @State private var profileDestination: ProfileDestination? = nil
    @State private var showsAssistantActionsPresentationEpoch = UUID()
    @State private var showsAssistantActionsStorage: Bool = false
    private var showsAssistantActions: Bool {
        get { showsAssistantActionsStorage }
        nonmutating set {
            guard newValue != showsAssistantActionsStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsAssistantActionsPresentationEpoch = UUID() }
            showsAssistantActionsStorage = newValue
        }
    }
    private func showsAssistantActionsBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsAssistantActions }, set: { replacement in
            guard canHandleRootDomainCallback, showsAssistantActionsPresentationEpoch == expectedEpoch, replacement != showsAssistantActions else { return }
            showsAssistantActions = replacement
        })
    }
    @State private var showsRootVoiceDockStorage = false
    private var showsRootVoiceDock: Bool {
        get { showsRootVoiceDockStorage }
        nonmutating set {
            guard newValue != showsRootVoiceDockStorage else { return }
            invalidateRootShareRoutes()
            showsRootVoiceDockStorage = newValue
        }
    }
    @State private var confirmedSpeechRequest: String?
    @State private var assistantSheetOpenedFromDock = false
    @State private var rootVoiceAccessTask: Task<Void, Never>?
    @State private var rootVoiceHold = ContinuousVoiceHold()
    @State private var rootVoiceControlBounds = CGRect.zero
    @State private var rootVoicePhysicalBounds = CGRect.zero
    @State private var showsMainActionsPresentationEpoch = UUID()
    @State private var showsMainActionsStorage: Bool = false
    private var showsMainActions: Bool {
        get { showsMainActionsStorage }
        nonmutating set {
            guard newValue != showsMainActionsStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsMainActionsPresentationEpoch = UUID() }
            showsMainActionsStorage = newValue
        }
    }
    private func showsMainActionsBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsMainActions }, set: { replacement in
            guard canHandleRootDomainCallback, showsMainActionsPresentationEpoch == expectedEpoch, replacement != showsMainActions else { return }
            showsMainActions = replacement
        })
    }
    @State private var mainActionStore: MainActionStore
    @State private var showsWorkoutMusicPresentationEpoch = UUID()
    @State private var showsWorkoutMusicStorage: Bool = false
    private var showsWorkoutMusic: Bool {
        get { showsWorkoutMusicStorage }
        nonmutating set {
            guard newValue != showsWorkoutMusicStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsWorkoutMusicPresentationEpoch = UUID() }
            showsWorkoutMusicStorage = newValue
        }
    }
    private func showsWorkoutMusicBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsWorkoutMusic }, set: { replacement in
            guard canHandleRootDomainCallback, showsWorkoutMusicPresentationEpoch == expectedEpoch, replacement != showsWorkoutMusic else { return }
            showsWorkoutMusic = replacement
        })
    }
    @State private var showsStepsPresentationEpoch = UUID()
    @State private var showsStepsStorage: Bool = false
    private var showsSteps: Bool {
        get { showsStepsStorage }
        nonmutating set {
            guard newValue != showsStepsStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsStepsPresentationEpoch = UUID() }
            showsStepsStorage = newValue
        }
    }
    private func showsStepsBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsSteps }, set: { replacement in
            guard canHandleRootDomainCallback, showsStepsPresentationEpoch == expectedEpoch, replacement != showsSteps else { return }
            showsSteps = replacement
        })
    }
    @State private var pendingWidgetRoute: DailyWidgetRoute?
    @State private var showsOutdoorKindChoicePresentationEpoch = UUID()
    @State private var showsOutdoorKindChoiceStorage: Bool = false
    private var showsOutdoorKindChoice: Bool {
        get { showsOutdoorKindChoiceStorage }
        nonmutating set {
            guard newValue != showsOutdoorKindChoiceStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsOutdoorKindChoicePresentationEpoch = UUID() }
            showsOutdoorKindChoiceStorage = newValue
        }
    }
    private func showsOutdoorKindChoiceBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsOutdoorKindChoice }, set: { replacement in
            guard canHandleRootDomainCallback, showsOutdoorKindChoicePresentationEpoch == expectedEpoch, replacement != showsOutdoorKindChoice else { return }
            showsOutdoorKindChoice = replacement
        })
    }
    @State private var pendingOutdoorKind: OutdoorActivityKind?
    @State private var focusHydrationInDiets = false
    @State private var openFoodLogInDiets = false
    @State private var whatsNew: WhatsNewPresentation?
    @State private var assistantFeedback: AssistantActionFeedback?
    @State private var assistantFeedbackTask: Task<Void, Never>?
    @State private var quickWaterToast: QuickWaterToast?
    @State private var quickWaterToastTask: Task<Void, Never>?
    @State private var showsWorkoutRecoveryError = false
    @State private var showsProgrammeVolumeError = false
    @State private var showsUnavailableVolumeReview = false
    @State private var liveActivityCoordinator = WorkoutLiveActivityCoordinator()
    @State private var walkActivityCoordinator = WalkLiveActivityCoordinator()
    @State private var outdoorActivity: OutdoorActivityViewModel
    @State private var outdoorActivityRepository: OutdoorActivityRepository
    @State private var showsOutdoorActivityPresentationEpoch = UUID()
    @State private var showsOutdoorActivityStorage: Bool = false
    private var showsOutdoorActivity: Bool {
        get { showsOutdoorActivityStorage }
        nonmutating set {
            guard newValue != showsOutdoorActivityStorage else { return }
            invalidateRootShareRoutes()
            if newValue { showsOutdoorActivityPresentationEpoch = UUID() }
            showsOutdoorActivityStorage = newValue
        }
    }
    private func showsOutdoorActivityBinding(expectedEpoch: UUID) -> Binding<Bool> {
        Binding(get: { showsOutdoorActivity }, set: { replacement in
            guard canHandleRootDomainCallback, showsOutdoorActivityPresentationEpoch == expectedEpoch, replacement != showsOutdoorActivity else { return }
            showsOutdoorActivity = replacement
        })
    }
    @State private var showsOutdoorConflict = false
    @State private var outdoorConflictIsStrength = false

    // Context closures capture this value, which holds the coordinator weakly.
    // Domain owners retain unconditional revocation registrations independently.
    private weak var shareCoordinator: ZeroOneRootShareCoordinator?
    private let ownsAuditedShareStores: Bool
    private let assistantActionPolicy = AssistantActionPolicy()
    private let activeWorkoutStore: any ActiveWorkoutPersisting
    private let workoutHistoryImportStore: any WorkoutHistoryPersisting
    private let localDataExport: LocalDataExport

    init(
        userProfileRepository: ZeroOneUserProfileRepository? = nil,
        initialTab: AppTab? = nil,
        demoStateStore: any ZeroOneDemoStatePersisting = UserDefaultsZeroOneDemoStateStore(),
        programmeSelectionStore: any WorkoutProgrammeSelectionPersisting = UserDefaultsWorkoutProgrammeSelectionStore(),
        programmeScheduleStore: any WorkoutProgrammeSchedulePersisting = UserDefaultsWorkoutProgrammeScheduleStore(),
        programmeVolumeStore: any ProgrammeVolumePersisting = UserDefaultsProgrammeVolumeStore(),
        workoutHistoryStore: (any WorkoutHistoryPersisting)? = nil,
        workoutLoadChoiceStore: any WorkoutLoadChoicePersisting = UserDefaultsWorkoutLoadChoiceStore(),
        workoutProgressionReviewStore: any WorkoutProgressionReviewPersisting = UserDefaultsWorkoutProgressionReviewStore(),
        customWorkoutStore: any CustomWorkoutPersisting = UserDefaultsCustomWorkoutStore(),
        activeWorkoutStore: (any ActiveWorkoutPersisting)? = nil,
        hydrationStore: any HydrationPersisting = HydrationStoreFactory.makeAppStore(),
        nutritionStore: any NutritionPersisting = UserDefaultsNutritionStore(),
        dietTrackerStore: any DietTrackerPersisting = FileDietTrackerStore(),
        progressPhotoStore: (any ProgressPhotoPersisting)? = nil,
        healthKitService: (any HealthKitServicing)? = nil,
        healthPreferenceStore: (any HealthConnectionPreferencePersisting)? = nil,
        bodyWeightStore: any BodyWeightPersisting = LocalBodyWeightStore(),
        stepsHealthService: (any StepsHealthServicing)? = nil,
        shareCoordinator: ZeroOneRootShareCoordinator
    ) {
        #if DEBUG
        Self.launchLogger.notice("AppRootView initialization began")
        #endif
        self.shareCoordinator = shareCoordinator
        let registration = shareCoordinator.registration
        let suppliedActiveStore = activeWorkoutStore
        let suppliedHistoryStore = workoutHistoryStore
        let activeWorkoutStore: any ActiveWorkoutPersisting = suppliedActiveStore
            ?? FileActiveWorkoutStore(
                legacyStore: UserDefaultsActiveWorkoutStore(shareRevocationRegistration: registration),
                shareRevocationRegistration: registration
            )
        let workoutHistoryStore: any WorkoutHistoryPersisting = suppliedHistoryStore ?? FileWorkoutHistoryStore()
        self.activeWorkoutStore = activeWorkoutStore
        _programmeVolume = State(initialValue: ProgrammeVolumeRepository(store: programmeVolumeStore))
        let resolvedHistoryStore = Self.resolvedWorkoutHistoryStore(defaultStore: workoutHistoryStore)
        self.workoutHistoryImportStore = resolvedHistoryStore
        self.localDataExport = LocalDataExport(
            historyStore: workoutHistoryStore,
            bodyWeightStore: bodyWeightStore,
            nutritionStore: nutritionStore,
            hydrationStore: hydrationStore
        )
        _userProfile = State(
            initialValue: userProfileRepository ?? shareCoordinator.parent?.profile ?? ZeroOneUserProfileRepository()
        )
        _selectedTabStorage = State(initialValue: initialTab ?? Self.reviewTab)
        let workoutHistory = WorkoutHistoryRepository(
            store: resolvedHistoryStore
        )
        workoutHistory.installShareRevocationRegistration(registration)
        let savedAuthority = SavedWorkoutHistoryShareAuthority()
        savedAuthority.installShareRevocationRegistration(registration)
        _savedHistoryShareAuthority = State(initialValue: savedAuthority)
        let progressionReviews = WorkoutProgressionReviewRepository(store: workoutProgressionReviewStore)
        let workoutProgression = WorkoutProgressionAuthority(history: workoutHistory, reviews: progressionReviews)
        _workoutProgression = State(initialValue: workoutProgression)
        let appointments = WorkoutAppointmentRepository(store: LocalWorkoutAppointmentStore())
        _workoutAppointments = State(initialValue: appointments)
        _appointmentCalendar = State(initialValue: AppointmentCalendarCoordinator(
            repository: appointments, writer: AppleAppointmentCalendarWriter()
        ))
        #if DEBUG
        if Self.reviewHistoryState == "completed",
           !workoutHistory.entries.contains(where: { Calendar.current.isDateInToday($0.completedAt) }),
           let source = WorkoutProgrammeLibrary.programme(id: WorkoutProgrammeLibrary.recommendedID)?.makeSession() {
            do {
                try workoutHistory.record(Self.completedReviewSession(from: source, startingAt: .now))
            } catch {
                Self.launchLogger.error("Review history fixture could not be recorded: \(String(describing: error), privacy: .public)")
            }
        }
        #endif
        let programmeCoordinator = WorkoutProgrammeCoordinator(
            selectionStore: programmeSelectionStore, scheduleStore: programmeScheduleStore
        )
        Self.prepareReviewActiveWorkoutSnapshot(in: activeWorkoutStore)
        var restoredSnapshot: ActiveWorkoutSnapshot?
        var recoveryFailed = false
        do {
            restoredSnapshot = try activeWorkoutStore.load()
        } catch {
            recoveryFailed = true
        }
        restoredSnapshot?.resolveElapsedRest(at: .now)
        if let snapshot = restoredSnapshot,
           let programmeID = snapshot.session.programmeID,
           WorkoutProgrammeLibrary.programme(id: programmeID) != nil {
            programmeCoordinator.restoreActiveProgramme(programmeID)
        } else if let customID = restoredSnapshot?.session.customWorkoutID {
            programmeCoordinator.restoreActiveCustomWorkout(customID)
        } else if restoredSnapshot != nil {
            recoveryFailed = true
            restoredSnapshot = nil
        }
        _showsWorkoutRecoveryError = State(initialValue: recoveryFailed)
        var workoutViewModel = WorkoutViewModel(
            session: restoredSnapshot?.session ?? MockWorkoutFactory.upperBodyA(),
            restoredSnapshot: restoredSnapshot,
            // The fallback only satisfies view state; it is not a workout the user started.
            persistInitialSnapshot: restoredSnapshot != nil,
            requiresFinalSetReview: true,
            onSnapshotChanged: { snapshot, sessionID in
                if let snapshot {
                    try activeWorkoutStore.save(snapshot)
                } else {
                    try activeWorkoutStore.clear(expectedSessionID: sessionID)
                }
            },
            onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
            shareRevocationRegistration: registration
        )

        if Self.reviewTab == .workout {
            switch Self.reviewWorkoutRoute {
            case "detail":
                programmeCoordinator.showDetail(for: Self.reviewWorkoutProgrammeID)
            case "active" where restoredSnapshot == nil:
                // An explicit restoration fixture must remain the source of this capture.
                programmeCoordinator.showDetail(for: Self.reviewWorkoutProgrammeID)
                if let session = programmeCoordinator.startSelectedProgramme() {
                    let reviewSession = (Self.reviewWorkoutState == "complete"
                        || Self.reviewWorkoutState == "upgrade"
                        || Self.reviewWorkoutState == "upgrade-between")
                        ? Self.completedReviewSession(
                            from: session,
                            upgradeFirstExercise: Self.reviewWorkoutState == "upgrade"
                                || Self.reviewWorkoutState == "upgrade-between",
                            stopAfterFirstExercise: Self.reviewWorkoutState == "upgrade-between"
                        )
                        : session
                    workoutViewModel = WorkoutViewModel(
                        session: reviewSession,
                        requiresFinalSetReview: Self.reviewWorkoutState == "final-review",
                        onSnapshotChanged: { _, _ in },
                        onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
                        shareRevocationRegistration: registration
                    )
                    Self.prepareReviewWorkoutState(workoutViewModel)
                }
            default:
                break
            }
        }
        let mainActionStore = MainActionStore()
        _mainActionStore = State(initialValue: mainActionStore)
        _workoutMusic = State(initialValue: WorkoutMusicStore(
            onOpenedControls: { mainActionStore.recordUse(.music) }
        ))
        let outdoorActivityRepository = OutdoorActivityRepository()
        _outdoorActivityRepository = State(initialValue: outdoorActivityRepository)
        _outdoorActivity = State(initialValue: OutdoorActivityViewModel(
            repository: outdoorActivityRepository,
            onConfirmedStartOrResume: { mainActionStore.recordUse(.walk) }
        ))
        let hydrationViewModel = HydrationViewModel(
            state: HydrationState(
                currentMilliliters: Self.reviewHydrationMilliliters,
                goalMilliliters: 2_500,
                recentHistory: Self.reviewDietsState != nil || Self.reviewAssistantState != nil
                    ? HydrationState.previewHistory()
                    : []
            ),
            store: Self.resolvedHydrationStore(defaultStore: hydrationStore),
            onConfirmedAddition: { mainActionStore.recordConfirmedWaterUse($0) },
            onConfirmedUndo: { mainActionStore.undoConfirmedWaterUse($0) }
        )
        let nutritionRepository = NutritionRepository(
            store: Self.resolvedNutritionStore(defaultStore: nutritionStore),
            onConfirmedAddition: { mainActionStore.recordConfirmedMealUse($0) },
            onConfirmedRemoval: { mainActionStore.undoUse($0) }
        )
        let progressPhotos: ProgressPhotoRepository
        let retainedPhotoStore: (any ProgressPhotoPersisting)?
        if let progressPhotoStore {
            retainedPhotoStore = progressPhotoStore
            progressPhotos = ProgressPhotoRepository(store: progressPhotoStore)
        } else {
            #if DEBUG
            // Preserve the existing private fixture repository. Its unavailable
            // external store identity deliberately supplies no sharing authority.
            retainedPhotoStore = nil
            progressPhotos = ProgressPhotoReviewFixtures.repository(
                state: Self.reviewProgressPhotoState
            )
            #else
            let actualStore = LocalProgressPhotoStore()
            retainedPhotoStore = actualStore
            progressPhotos = ProgressPhotoRepository(store: actualStore)
            #endif
        }
        progressPhotos.installShareRevocationRegistration(registration)
        ownsAuditedShareStores = suppliedActiveStore == nil && suppliedHistoryStore == nil
            && progressPhotoStore == nil && retainedPhotoStore is LocalProgressPhotoStore
            && resolvedHistoryStore is FileWorkoutHistoryStore
            && (userProfileRepository == nil || userProfileRepository === shareCoordinator.parent?.profile)
        let dailyContext = DailyAssistantContextStore()

        _workoutViewModel = State(initialValue: workoutViewModel)
        _hydrationViewModel = State(initialValue: hydrationViewModel)
        _nutritionRepository = State(initialValue: nutritionRepository)
        _dietTrackerFeature = State(initialValue: DietTrackerFeatureModel(
            repository: DietTrackerRepository(store: dietTrackerStore),
            reminders: DietTrackerReminderScheduler()
        ))
        _dailyContext = State(initialValue: dailyContext)
        _demoState = State(initialValue: ZeroOneDemoStateModel(store: demoStateStore))
        _programmeCoordinator = State(initialValue: programmeCoordinator)
        _workoutHistory = State(initialValue: workoutHistory)
        _workoutLoadChoices = State(initialValue: WorkoutLoadChoiceRepository(store: workoutLoadChoiceStore))
        _customWorkouts = State(initialValue: CustomWorkoutRepository(store: customWorkoutStore))
        _progressPhotos = State(initialValue: progressPhotos)
        _photoShareAuthority = State(initialValue: PhotoComparisonShareHostAuthority(store: retainedPhotoStore))
        _bodyWeight = State(initialValue: BodyWeightRepository(store: bodyWeightStore))
        _stepsDay = State(initialValue: StepsDayRepository(service: stepsHealthService ?? AppleHealthKitService()))
        _healthConnection = State(
            initialValue: Self.makeHealthConnectionRepository(
                service: healthKitService,
                preferenceStore: healthPreferenceStore
            )
        )
        #if DEBUG
        let needsReviewVoice = Self.reviewAssistantState == "open"
            || ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_STATE"] != nil
        if needsReviewVoice {
            let voiceAssistant = Self.makeVoiceAssistant()
            Self.prepareReviewVoiceState(voiceAssistant)
            _voiceAssistant = State(initialValue: voiceAssistant)
        } else {
            _voiceAssistant = State(initialValue: nil)
        }
        #else
        _voiceAssistant = State(initialValue: nil)
        #endif
        _showsProfileStorage = State(initialValue: Self.reviewProfileRoute != nil)
        _showsAssistantActionsStorage = State(initialValue: Self.reviewAssistantState == "open")
        _showsMainActionsStorage = State(initialValue: Self.reviewMainActionState == "open")
        _assistantFeedback = State(initialValue: Self.reviewAssistantFeedback)
        #if DEBUG
        Self.launchLogger.notice("AppRootView initialization finished")
        #endif
    }

    private var isCurrentShareRoot: Bool {
        guard let coordinator = shareCoordinator, let parent = coordinator.parent else { return false }
        return parent.rootGate.isCurrent(coordinator.rootID)
    }

    private var canHandleRootDomainCallback: Bool {
        guard let coordinator = shareCoordinator else { return false }
        // Standalone previews retain routing, without audited share cleanup.
        return coordinator.parent == nil || isCurrentShareRoot
    }

    private func invalidateRootShareRoutes() {
        shareCoordinator?.revokeBeforeRouteChange()
        savedSharePreparationGeneration = UUID()
        isPreparingSavedShare = false
        savedWorkoutShare?.presentation.invalidate()
    }

    private func showWorkoutLibrary() {
        invalidateRootShareRoutes()
        programmeCoordinator.showLibrary()
    }

    private func showWorkoutDetail(_ id: WorkoutProgrammeID) {
        invalidateRootShareRoutes()
        programmeCoordinator.showDetail(for: id)
    }

    private func rootShareContext() -> ZeroOneRootShareContext? {
        guard isCurrentShareRoot, let historyImport = workoutHistoryImport,
              let outdoorTransfer = outdoorHistoryTransfer else { return nil }
        return ZeroOneRootShareContext(
            facts: ZeroOneRootShareFacts(selectedTab: selectedTab, showsProfile: showsProfile,
                showsOutdoor: showsOutdoorActivity, hasActiveWorkoutRoute: programmeCoordinator.route.isActive,
                recoveryFailed: showsWorkoutRecoveryError, scenePhase: shareScenePhase),
            workout: workoutViewModel, history: workoutHistory, historyImport: historyImport,
            savedHistoryAuthority: savedHistoryShareAuthority, photos: progressPhotos,
            photoHost: photoShareAuthority, outdoor: outdoorActivity,
            outdoorRepository: outdoorActivityRepository, outdoorTransfer: outdoorTransfer,
            activeStore: activeWorkoutStore, ownsAuditedStores: ownsAuditedShareStores
        )
    }

    private func savedWorkoutShareBinding(expected: SavedWorkoutShareRoute?) -> Binding<SavedWorkoutShareRoute?> {
        let capturedID = expected?.id
        return Binding(get: { savedWorkoutShare }, set: { replacement in
            guard canHandleRootDomainCallback, savedWorkoutShare?.id == capturedID else { return }
            if savedWorkoutShare?.id != replacement?.id {
                savedWorkoutShare?.presentation.invalidate()
            }
            savedWorkoutShare = replacement
        })
    }

    private func closeSavedWorkoutShareIfCurrent(_ route: SavedWorkoutShareRoute) {
        // Always retire this captured token; an obsolete callback cannot remove
        // a newer route or revoke its generation through the registry root gate.
        route.presentation.invalidate()
        guard savedWorkoutShare?.id == route.id else { return }
        savedWorkoutShare = nil
    }

    private static var reviewTab: AppTab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_TAB"]?.lowercased() {
        case "workout": .workout
        case "social": .social
        case "diets": .diets
        default: .today
        }
        #else
        .today
        #endif
    }

    private static var reviewHydrationMilliliters: Int {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_SUCCESS_STATE"] == "hydration"
            || reviewAssistantState == "confirmed-water" {
            return 1_000
        }
        return reviewDietsState != nil || reviewAssistantState != nil ? 750 : 0
        #else
        0
        #endif
    }

    private static var reviewWorkoutRoute: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_ROUTE"]?.lowercased()
        #else
        nil
        #endif
    }

    private static var reviewWorkoutState: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_STATE"]?.lowercased()
        #else
        nil
        #endif
    }

    private static func prepareReviewActiveWorkoutSnapshot(
        in store: any ActiveWorkoutPersisting
    ) {
        #if DEBUG
        guard let state = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_RESTORE_STATE"]?.lowercased() else {
            return
        }
        if state == "exit-cleared" {
            if let snapshot = try? store.load() {
                try? store.clear(expectedSessionID: snapshot.session.id)
            }
            return
        }
        guard var session = WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)?.makeSession(),
              let exercise = session.currentExercise else { return }

        let now = Date.now
        let completionDate = state == "elapsed-rest"
            ? now.addingTimeInterval(-1_000)
            : now.addingTimeInterval(-10)
        session.resolveWarmUp(as: .completed, at: completionDate)
        _ = try? session.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: exercise.plan.targetReps.upperBound,
            rir: 2,
            at: completionDate
        )

        let isPaused = state == "paused"
        let pausedSeconds = isPaused ? session.remainingRestSeconds(at: now) : nil
        if state == "active" {
            session.skipRest()
        }
        try? store.save(
            ActiveWorkoutSnapshot(
                session: session,
                enteredLoadValue: exercise.plan.targetLoad.value,
                enteredReps: exercise.plan.targetReps.upperBound,
                enteredRIR: 2,
                isPaused: isPaused,
                pausedRemainingRestSeconds: pausedSeconds,
                pendingAdaptation: nil,
                sessionBeforeAdaptation: nil,
                lastSetGuidance: nil
            )
        )
        #endif
    }

    private static var reviewWorkoutProgrammeID: WorkoutProgrammeID {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_WORKOUT_PROGRAMME"]?.lowercased() {
        case "arms": .arms
        case "biceps": .biceps
        case "zeroone-build": .zeroOneBuild
        case "zeroone-consistency": .zeroOneConsistency
        default: WorkoutProgrammeLibrary.recommendedID
        }
        #else
        WorkoutProgrammeLibrary.recommendedID
        #endif
    }

    private static var reviewHistoryState: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_HISTORY_STATE"]?.lowercased()
        #else
        nil
        #endif
    }

    private static func resolvedWorkoutHistoryStore(
        defaultStore: any WorkoutHistoryPersisting
    ) -> any WorkoutHistoryPersisting {
        #if DEBUG
        if reviewHistoryState == "unavailable" {
            return ReviewUnavailableWorkoutHistoryStore()
        }
        if reviewHistoryState == "empty" {
            return ReviewEmptyWorkoutHistoryStore()
        }
        #endif

        return defaultStore
    }

    private static var reviewDietsState: String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_DIETS_STATE"]?.lowercased()
        return value?.isEmpty == false ? value : nil
        #else
        nil
        #endif
    }

    private static func resolvedHydrationStore(defaultStore: any HydrationPersisting) -> any HydrationPersisting {
        #if DEBUG
        if let reviewState = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_HYDRATION_STATE"],
           !reviewState.isEmpty {
            if reviewState == "unavailable" { return ReviewUnavailableHydrationStore() }
            let store = UserDefaultsHydrationStore(key: "slick.review.hydrationDailyState")
            let date = Date.now
            store.save(HydrationStoredState(
                date: date, currentMilliliters: reviewState == "empty" ? 0 : reviewHydrationMilliliters,
                goalMilliliters: 2_500, dayStart: Calendar.autoupdatingCurrent.startOfDay(for: date)
            ))
            return store
        }
        #endif
        return defaultStore
    }

    private static var reviewAssistantState: String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_ASSISTANT_STATE"]?.lowercased()
        return value?.isEmpty == false ? value : nil
        #else
        nil
        #endif
    }

    private static var reviewAssistantFeedback: AssistantActionFeedback? {
        guard reviewAssistantState == "confirmed-water" else { return nil }
        return AssistantActionFeedback(
            message: "+250 ml added to hydration.",
            kind: .success
        )
    }

    private static var reviewNutritionDraft: NutritionEntryDraft? {
        guard reviewDietsState == "manual" else { return nil }
        var draft = NutritionEntryDraft()
        draft.title = "Greek yogurt bowl"
        draft.calories = "360"
        draft.proteinGrams = "28"
        draft.carbohydrateGrams = "42"
        draft.fatGrams = "8"
        return draft
    }

    private static func resolvedNutritionStore(
        defaultStore: any NutritionPersisting
    ) -> any NutritionPersisting {
        #if DEBUG
        guard let reviewDietsState else { return defaultStore }
        let entries: [NutritionEntry]
        switch reviewDietsState {
        case "populated":
            entries = reviewNutritionEntries
        case "unavailable":
            return ReviewUnavailableNutritionStore()
        default:
            entries = []
        }
        return ReviewNutritionStore(entries: entries)
        #else
        return defaultStore
        #endif
    }

    private static var reviewNutritionEntries: [NutritionEntry] {
        [
            NutritionEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                title: "Chicken rice bowl",
                calories: 640,
                proteinGrams: 46,
                carbohydrateGrams: 72,
                fatGrams: 18,
                loggedAt: .now
            ),
            NutritionEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                title: "Greek yogurt and berries",
                calories: 310,
                proteinGrams: 27,
                carbohydrateGrams: 38,
                fatGrams: 6,
                loggedAt: .now.addingTimeInterval(-3_600)
            )
        ]
    }

    private static var reviewProfileRoute: String? {
        #if DEBUG
        guard let route = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_PROFILE_ROUTE"]?.lowercased(),
              !route.isEmpty else { return nil }
        return route
        #else
        nil
        #endif
    }

    private static var reviewProgressPhotoState: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_PROGRESS_PHOTO_STATE"]?.lowercased()
        #else
        nil
        #endif
    }

    private static func makeHealthConnectionRepository(
        service: (any HealthKitServicing)?,
        preferenceStore: (any HealthConnectionPreferencePersisting)?
    ) -> HealthConnectionRepository {
        #if DEBUG
        if let state = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_HEALTH_STATE"]?.lowercased() {
            let isAvailable = state != "unavailable"
            return HealthConnectionRepository(
                service: ReviewHealthKitService(isAvailable: isAvailable),
                preferenceStore: ReviewHealthPreferenceStore(hasCompletedSetup: state == "connected"),
                now: { .now }
            )
        }
        #endif

        return HealthConnectionRepository(
            service: service ?? AppleHealthKitService(),
            preferenceStore: preferenceStore ?? UserDefaultsHealthConnectionPreferenceStore()
        )
    }

    private static func prepareReviewWorkoutState(_ viewModel: WorkoutViewModel) {
        #if DEBUG
        switch reviewWorkoutState {
        case "proposal":
            viewModel.proposeThirtyMinuteAdaptation()
        case "adapted":
            viewModel.proposeThirtyMinuteAdaptation()
            viewModel.applyPendingAdaptation()
        case "working":
            viewModel.resolveWarmUp(as: .completed)
        case "rest":
            viewModel.resolveWarmUp(as: .completed)
            viewModel.proposeThirtyMinuteAdaptation()
            viewModel.applyPendingAdaptation()
            viewModel.completeCurrentSet(at: .now)
        case "rest-limit":
            viewModel.resolveWarmUp(as: .completed)
            viewModel.enteredRIR = 0
            viewModel.completeCurrentSet(at: .now)
        case "final-review":
            viewModel.resolveWarmUp(as: .completed)
            for _ in 0..<viewModel.session.totalPlannedSetCount {
                viewModel.skipRest()
                viewModel.completeCurrentSet(at: .now)
            }
        default:
            break
        }
        #endif
    }

    private static func prepareReviewVoiceState(_ coordinator: VoiceAssistantCoordinator) {
        #if DEBUG
        guard let state = ProcessInfo.processInfo.environment["ZERO_ONE_VOICE_REVIEW_STATE"]?.lowercased() else {
            return
        }
        Task { @MainActor in
            switch state {
            case "listening":
                coordinator.pressBegan()
            case "confirmation", "unsupported":
                coordinator.pressBegan()
                try? await Task.sleep(for: .milliseconds(900))
                coordinator.pressEnded()
                try? await Task.sleep(for: .milliseconds(250))
                if state == "unsupported" {
                    _ = coordinator.confirmTranscript()
                }
            default:
                break
            }
        }
        #endif
    }

    private static var reviewMainActionState: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_MAIN_ACTION_STATE"]?.lowercased()
        #else
        nil
        #endif
    }

    private static func makeVoiceAssistant() -> VoiceAssistantCoordinator {
        VoiceAssistantCoordinator(
            transcriptionService: SpeechTranscriptionServiceFactory.makeDefault()
        )
    }

    private func openAssistant() {
        guard scenePhase == .active, rootVoiceAccessTask == nil,
              !showsAssistantActions, !showsRootVoiceDock, !rootVoiceHasCompetingPresentation else { return }
        if voiceAssistant == nil {
            voiceAssistant = Self.makeVoiceAssistant()
        }
        // Re-read actual authorization on each explicit opening, including a grant
        // whose old consent callback was correctly ignored after release/reset.
        voiceAssistant?.reset()
        confirmedSpeechRequest = nil
        if !showsTabBar {
            // Active-workout Ask 01 has no center gesture host. Retain the original
            // Assistant sheet and its embedded real voice/touch action controls.
            assistantSheetOpenedFromDock = false
            showsAssistantActions = true
            mainActionStore.recordUse(.assistant)
            return
        }
        showsRootVoiceDock = true
        mainActionStore.recordUse(.assistant)
    }

    private func closeRootVoiceDock() {
        guard showsRootVoiceDock else { return }
        rootVoiceAccessTask?.cancel()
        rootVoiceHold.invalidate()
        voiceAssistant?.reset()
        showsRootVoiceDock = false
    }

    private func requestRootVoiceAccess() {
        guard showsRootVoiceDock, rootVoiceAccessTask == nil, let voiceAssistant else { return }
        // Retain the cancelled task until system permission callbacks finish. A reopened
        // dock cannot begin capture or launch a second permission request in that interval.
        let heldID = rootVoiceHold.id
        rootVoiceAccessTask = Task { @MainActor in
            await voiceAssistant.requestAccess()
            rootVoiceAccessTask = nil
            guard !Task.isCancelled, canHandleRootDomainCallback,
                  rootVoiceHold.canContinue(heldID, isSceneActive: shareScenePhase == .active,
                                            isDockPresented: showsRootVoiceDock),
                  voiceAssistant.phase == .ready else { return }
            voiceAssistant.pressBegan()
        }
    }

    private func presentAssistantActions(confirmedTranscript: String? = nil) {
        guard showsRootVoiceDock, rootVoiceAccessTask == nil else { return }
        // Proof 26: a clear request acts as soon as the hold ends; anything else gets the options.
        if let confirmedTranscript, let quick = VoiceQuickIntent.match(confirmedTranscript) {
            closeRootVoiceDock()
            runVoiceQuickIntent(quick)
            return
        }
        // Capture the real confirmTranscript() result before disappearance resets voice.
        confirmedSpeechRequest = confirmedTranscript
        assistantSheetOpenedFromDock = true
        closeRootVoiceDock()
        showsAssistantActions = true
    }

    private func runVoiceQuickIntent(_ intent: VoiceQuickIntent) {
        invalidateRootShareRoutes()
        switch intent {
        case let .addWater(milliliters):
            if let receipt = hydrationViewModel.addWaterFromQuickAction(milliliters: milliliters) {
                showQuickWaterToast(HydrationQuickLogGroup(receipt))
            } else {
                presentQuickWaterToast(QuickWaterToast(message: "Water wasn't saved", undoUnconfirmed: true),
                    announcement: "Water wasn't saved. Review your water total.")
            }
        case .startWorkout:
            openRecommendedProgramme()
        case let .open(destination):
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                switch destination {
                case .diets: selectedTab = .diets
                case .logFood:
                    openFoodLogInDiets = true
                    selectedTab = .diets
                case .workoutLibrary: applyAssistantRoute(.workoutLibrary)
                case .steps: showsSteps = true
                case .history:
                    profileDestination = .history
                    showsProfile = true
                case .music: showsWorkoutMusic = true
                case .walk:
                    await outdoorActivity.load()
                    if outdoorActivity.hasUnfinishedSession {
                        openOutdoorActivity(outdoorActivity.selectedKind)
                    } else {
                        showsOutdoorKindChoice = true
                    }
                }
            }
        }
    }

    private var rootVoiceHasCompetingPresentation: Bool {
        showsProfile || showsAssistantActions || showsMainActions || showsWellbeingReview || showsSteps
            || showsWorkoutMusic || showsOutdoorActivity || showsOutdoorKindChoice
            || savedWorkoutShare != nil || scheduledReview != nil || showsUnavailableVolumeReview
            || showsOutdoorConflict || showsWorkoutRecoveryError || showsProgrammeVolumeError
            || showsSavedShareUnavailable || scheduledWorkoutMessage != nil || orphanScheduledLaunch != nil
    }

    private var rootVoiceIsHolding: Bool {
        showsRootVoiceDock && (voiceAssistant?.phase == .preparing || voiceAssistant?.phase == .listening)
    }

    @ViewBuilder
    private var rootVoiceDock: some View {
        if showsRootVoiceDock, let voiceAssistant {
            RootVoiceDock(
                coordinator: voiceAssistant,
                isAccessRequestPending: rootVoiceAccessTask != nil,
                isOverCancel: rootVoiceHold.isCancelled,
                onCancel: closeRootVoiceDock,
                onRequestAccess: requestRootVoiceAccess,
                onConfirm: { presentAssistantActions(confirmedTranscript: $0) },
                onOpenActions: { presentAssistantActions() },
                onClose: closeRootVoiceDock
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func handleRootVoiceHold(_ event: MainActionHoldEvent) {
        switch event {
        case let .began(id):
            guard scenePhase == .active, !showsAssistantActions, !rootVoiceHasCompetingPresentation,
                  rootVoiceAccessTask == nil else { return }
            if !showsRootVoiceDock { openAssistant() }
            guard showsRootVoiceDock, let voiceAssistant else { return }
            rootVoiceHold.begin(id, controlBounds: rootVoiceControlBounds,
                                physicalRootBounds: rootVoicePhysicalBounds)
            if voiceAssistant.phase == .ready { voiceAssistant.pressBegan() }
        case let .moved(id, location):
            rootVoiceHold.move(id, to: location)
        case let .ended(id, location):
            guard let cancelled = rootVoiceHold.end(id, at: location) else { return }
            if cancelled { closeRootVoiceDock() }
            else { voiceAssistant?.pressEnded() }
        case let .cancelled(id):
            guard rootVoiceHold.contains(id) else { return }
            if rootVoiceAccessTask != nil {
                // System permission UI can interrupt the touch. Retire only that
                // touch; preserve the explicit speech + microphone consent choice.
                rootVoiceHold.invalidate()
            } else { closeRootVoiceDock() }
        }
    }

    private func updateRootVoiceGeometry(_ geometry: GeometryProxy) {
        let safeBounds = geometry.frame(in: .global)
        // This reader is noninteractive and leaves destination layout/safe areas intact.
        let physicalBounds = CGRect(x: safeBounds.minX, y: safeBounds.minY,
                                    width: safeBounds.width,
                                    height: safeBounds.height + geometry.safeAreaInsets.bottom)
        if !rootVoicePhysicalBounds.isEmpty, rootVoicePhysicalBounds != physicalBounds,
           rootVoiceHold.id != nil {
            // Rotation/resizing invalidates frozen touch ownership. Preserve an
            // explicitly chosen permission request, but never continue that old hold.
            rootVoiceHold.invalidate()
            if rootVoiceAccessTask == nil { voiceAssistant?.reset() }
        }
        rootVoicePhysicalBounds = physicalBounds
    }

    private var rootVoiceVisualOffset: CGFloat {
        ContinuousVoiceHold.visualOffset(controlBounds: rootVoiceControlBounds,
                                         physicalRootBounds: rootVoicePhysicalBounds)
    }

    private var rootVoiceAccessibilityValue: String {
        guard let phase = voiceAssistant?.phase else { return localization.string("Voice request is not recording") }
        return switch phase {
        case .ready: localization.string("Ready to record")
        case .preparing: localization.string("Starting on-device speech")
        case .listening: localization.string("Listening while held")
        case .finalizing: localization.string("Finishing transcript")
        case .transcriptConfirmation: localization.string("Transcript ready for review")
        case .requestingAccess: localization.string("Opening system permissions")
        case .needsConsent: localization.string("Voice access requires your choice")
        default: localization.string("Voice request is not recording")
        }
    }

    private func openRootVoiceForAccessibility() {
        if !showsRootVoiceDock { openAssistant() }
        guard showsRootVoiceDock, rootVoiceAccessTask == nil, scenePhase == .active else { return }
        voiceAssistant?.toggleForAccessibility()
    }

    private var mainActionAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.2, 0.9, 0.25, 1, duration: 0.32)
    }

    private var outdoorProfileInitial: String {
        guard let first = userProfile.profile.displayName?.first else { return "01" }
        return String(first).uppercased()
    }

    private var mainActionAssistantNote: MainActionAssistantNote? {
        guard programmeCoordinator.route.isActive,
              workoutViewModel.isPaused,
              workoutViewModel.persistenceErrorMessage == nil,
              let proposal = workoutViewModel.pendingAdaptation else { return nil }
        return MainActionAssistantNote(
            sessionID: workoutViewModel.session.id,
            title: "Your shorter session is ready to review",
            detail: "A \(proposal.targetMinutes)-minute option. Nothing changes until you choose.",
            actionTitle: "Review",
            onReview: {
                dismissMainActions()
                selectedTab = .workout
            }
        )
    }

    private func dismissMainActions() {
        let dismissalAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.15)
            : .timingCurve(0.4, 0, 1, 1, duration: 0.2)
        withAnimation(dismissalAnimation) {
            showsMainActions = false
        }
    }

    static func completedReviewSession(
        from source: WorkoutSession,
        startingAt: Date = .now.addingTimeInterval(-300),
        upgradeFirstExercise: Bool = false,
        stopAfterFirstExercise: Bool = false
    ) -> WorkoutSession {
        #if DEBUG
        var session = source
        var completionDate = startingAt
        session.resolveWarmUp(as: .completed, at: startingAt)

        while !session.isComplete, let exercise = session.currentExercise {
            // Programme templates intentionally have no chosen load. Review data
            // supplies an explicit sample, then uses the normal set validation.
            let plannedLoad = exercise.plan.targetLoad
            let hasValidPlannedLoad = plannedLoad.value.isFinite &&
                (plannedLoad.value > 0 || (plannedLoad.value == 0 && exercise.plan.allowsZeroLoad))
            let reviewLoad = (upgradeFirstExercise && session.currentExerciseIndex == 0) || !hasValidPlannedLoad
                ? Load(10, unit: exercise.plan.targetLoad.unit)
                : plannedLoad
            guard (try? session.completeCurrentSet(
                load: reviewLoad,
                reps: exercise.plan.targetReps.upperBound,
                rir: 2,
                at: completionDate
            )) != nil else {
                launchLogger.error("Review session could not advance; stopping fixture generation")
                break
            }
            session.skipRest()
            completionDate = completionDate.addingTimeInterval(1)
            if stopAfterFirstExercise && session.currentExerciseIndex > 0 { break }
        }
        return session
        #else
        return source
        #endif
    }

    private var reviewDynamicTypeSize: DynamicTypeSize {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_LARGE_TEXT"] == "1" { return .accessibility1 }
        #endif
        return inheritedDynamicTypeSize
    }

    // The root view is split into three chained stages. As one ~390-line modifier chain it
    // exceeded the Swift type-checker's time limit (Codemagic build 6ab9852d). Order is unchanged.
    private var rootChrome: some View {
        VStack(spacing: 0) {
            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(showsMainActions || showsRootVoiceDock)
                .allowsHitTesting(!showsRootVoiceDock)
                .overlay(alignment: .topTrailing) {
                    if selectedTab == .social {
                        profileAccess
                            .accessibilityHidden(showsMainActions)
                    }
                }
                .overlay(alignment: .bottom) {
                    quickWaterToastContent
                        .padding(.horizontal, ZOSpace.screenMargin)
                        .padding(.bottom, ZOSpace.m)
                }

            if showsTabBar {
                ZeroOneTabBar(
                    selection: selectedTabBinding,
                    onOpenMainActions: {
                        withAnimation(mainActionAnimation) {
                            showsMainActions = true
                        }
                    },
                    hasActivity: notificationWorkoutActive,
                    onHoldAssistant: openAssistant,
                    actionStore: mainActionStore,
                    isVoiceDockPresented: showsRootVoiceDock,
                    isVoiceHolding: rootVoiceIsHolding,
                    onContinuousHold: handleRootVoiceHold,
                    onHoldBoundsChange: { rootVoiceControlBounds = $0 },
                    onVoiceAccessibilityToggle: openRootVoiceForAccessibility,
                    voiceAccessibilityValue: rootVoiceAccessibilityValue,
                    voiceVisualOffset: rootVoiceVisualOffset,
                    voiceIsListening: voiceAssistant?.phase == .listening,
                    voiceIsOverCancel: rootVoiceHold.isCancelled
                )
                .accessibilityHidden(showsMainActions)
                #if DEBUG
                .modifier(TodayReviewFrameDiagnostics(name: "dock"))
                #endif
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateRootVoiceGeometry(geometry) }
                    .onChange(of: geometry.frame(in: .global)) { _, _ in updateRootVoiceGeometry(geometry) }
                    .onChange(of: geometry.safeAreaInsets.bottom) { _, _ in updateRootVoiceGeometry(geometry) }
            }
            .allowsHitTesting(false)
        }
        .coordinateSpace(.named("rootVoiceHold"))
        .environment(\.dynamicTypeSize, reviewDynamicTypeSize)
        .overlay { mainActionOverlay }
        .overlay(alignment: .bottom) { rootVoiceDock }
        .onChange(of: selectedTab) { _, _ in closeRootVoiceDock() }
        .onChange(of: showsTabBar) { _, shown in
            if !shown { closeRootVoiceDock() }
        }
        .onChange(of: rootVoiceHasCompetingPresentation) { _, presented in
            if presented { closeRootVoiceDock() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { closeRootVoiceDock() }
            else if phase == .inactive {
                rootVoiceHold.invalidate()
                if rootVoiceAccessTask == nil,
                   voiceAssistant?.phase == .preparing || voiceAssistant?.phase == .listening
                    || voiceAssistant?.phase == .finalizing {
                    voiceAssistant?.reset()
                }
            }
        }
        .onDisappear { closeRootVoiceDock() }
        .overlay(alignment: .top) {
            if showsWorkoutRecoveryError {
                VStack(spacing: ZOSpace.s) {
                    Text("Saved workout could not be restored. Recovery data has been kept. Retry recovery before starting another workout.")
                    Button("Retry Recovery", action: retryWorkoutRecovery)
                        .accessibilityIdentifier("workout.retryRecovery")
                }
                .padding()
                .background(activeTheme.backgroundPrimary)
            } else if let assistantFeedback {
                AssistantFeedbackBanner(feedback: assistantFeedback)
                    .padding(.horizontal, ZOSpace.xl)
                    .padding(.top, ZOSpace.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .tint(activeTheme.textPrimary)
        .alert("Programme sets unavailable", isPresented: $showsProgrammeVolumeError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The saved programme sets could not be verified. Open the programme to retry or review its adjustment before starting.")
        }
        .modifier(ZOThemeScreenSurface(theme: activeTheme))
        .background(activeTheme.backgroundPrimary.ignoresSafeArea())
        .zeroOneTheme(activeTheme)
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
    }

    @ViewBuilder
    private var mainActionOverlay: some View {
            if showsMainActions && showsTabBar {
                MainActionSurfaceView(
                    workoutTitle: workoutViewModel.session.title,
                    workoutInProgress: programmeCoordinator.route.isActive,
                    workoutIsReady: isTodayWorkoutReady,
                    waterTotalMilliliters: hydrationViewModel.state.currentMilliliters,
                    canLogWater: hydrationViewModel.canConfirmQuickWaterSave,
                    onPrimaryWorkout: {
                        dismissMainActions()
                        openTodayWorkout()
                    },
                    onWorkoutLibrary: {
                        dismissMainActions()
                        if programmeCoordinator.route.isActive {
                            openTodayWorkout()
                        } else {
                            showWorkoutLibrary()
                            selectedTab = .workout
                        }
                    },
                    onAddWater: { hydrationViewModel.addWaterFromQuickAction(milliliters: $0) },
                    onUndoWater: { hydrationViewModel.undoQuickWaterLog($0) },
                    onOpenWater: {
                        dismissMainActions()
                        focusHydrationInDiets = true
                        selectedTab = .diets
                    },
                    onOpenDiets: {
                        dismissMainActions()
                        focusHydrationInDiets = false
                        openFoodLogInDiets = true
                        selectedTab = .diets
                    },
                    onOpenHistory: {
                        dismissMainActions()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            profileDestination = .history
                            showsProfile = true
                        }
                    },
                    onOpenAssistant: {
                        dismissMainActions()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            openAssistant()
                        }
                    },
                    onDismiss: dismissMainActions,
                    onConfirmedWater: showQuickWaterToast,
                    onOpenWalkOrRun: {
                        dismissMainActions()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            _ = await shareCoordinator?.installOutdoorOwners()
            // Sharing installation failure never suppresses normal recovery/load.
            await outdoorActivity.load()
                            if outdoorActivity.hasUnfinishedSession {
                                openOutdoorActivity(outdoorActivity.selectedKind)
                            } else {
                                showsOutdoorKindChoice = true
                            }
                        }
                    },
                    onOpenSteps: {
                        dismissMainActions()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            showsSteps = true
                            mainActionStore.recordUse(.steps)
                        }
                    },
                    onOpenMusic: {
                        dismissMainActions()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            showsWorkoutMusic = true
                            workoutMusic.recordControlsOpened()
                        }
                    },
                    activeAction: outdoorActivity.hasUnfinishedSession ? .walk
                        : (programmeCoordinator.route.isActive ? .workout : nil),
                    supportsHoldAssistant: true,
                    assistantNote: mainActionAssistantNote,
                    actionStore: mainActionStore
                )
                .zeroOneTheme(activeTheme)
            }
    }

    private var rootPresentations: some View {
        let profileEpoch = showsProfilePresentationEpoch
        let outdoorEpoch = showsOutdoorActivityPresentationEpoch
        let assistantEpoch = showsAssistantActionsPresentationEpoch
        let musicEpoch = showsWorkoutMusicPresentationEpoch
        let stepsEpoch = showsStepsPresentationEpoch
        let outdoorChoiceEpoch = showsOutdoorKindChoicePresentationEpoch
        let directShareEpoch = savedWorkoutSharePresentationEpoch
        let scheduledEpoch = scheduledReviewPresentationEpoch
        return rootChrome
        .sheet(isPresented: showsProfileBinding(expectedEpoch: profileEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsProfilePresentationEpoch == profileEpoch else { return }
            profileDestination = nil
            completePendingWidgetRoute()
            if let appointment = pendingScheduledReview {
                pendingScheduledReview = nil
                scheduledStartWarmUp = .full
                scheduledReview = appointment
            }
        }) {
            ProfileAccountView(
                selectedAppearance: selectedAppearanceBinding,
                demoState: demoState,
                userProfile: userProfile,
                healthConnection: healthConnection,
                progressPhotos: progressPhotos,
                bodyWeight: bodyWeight,
                customWorkouts: customWorkouts,
                smartNotes: smartNotes,
                membership: membership,
                session: workoutViewModel.session,
                historyState: workoutHistory.surfaceState,
                loadChoices: workoutLoadChoices,
                makeLocalDataJSON: { selection in
                    let records = selection.outdoorActivities
                        ? try await outdoorActivity.savedRecordsForExport() : nil
                    try Task.checkCancellation()
                    let settings: LocalSettingsExport?
                    if selection.goalsAndPreferences {
                        settings = try LocalSettingsExport(profile: userProfile.profileForExport(),
                            dailyGoals: dailyGoals.valueForExport(), appearancePreference: selectedAppearance.rawValue,
                            accentPreference: AccentPreference.storedValue(selectedAccentRawValue).rawValue)
                    } else { settings = nil }
                    return try localDataExport.createJSON(selection: selection, outdoorRecords: records, settings: settings)
                },
                widgetInputs: dailyWidgetInputs,
                dailyGoals: dailyGoals,
                hydration: hydrationViewModel,
                workoutAppointments: workoutAppointments,
                appointmentCalendar: appointmentCalendar,
                programmes: programmeCoordinator.programmes,
                onOpenScheduledWorkout: openScheduledWorkout,
                workoutHistoryImport: workoutHistoryImport,
                onImportedWorkoutHistory: refreshImportedWorkoutHistory,
                mealRecordImport: mealRecordImport,
                bodyWeightRecordImport: bodyWeightRecordImport,
                outdoorHistoryTransfer: outdoorHistoryTransfer,
                initialDestination: profileDestination ?? reviewInitialProfileDestination
            )
            .environment(\.savedWorkoutHistoryShareAuthority, savedHistoryShareAuthority)
            .onAppear {
                guard isCurrentShareRoot, showsProfile, showsProfilePresentationEpoch == profileEpoch else { return }
                shareCoordinator?.installContext { [self] in rootShareContext() }
                savedHistoryShareAuthority.install(
                    resolve: resolveSavedHistoryShare,
                    canExport: { snapshot in
                        guard showsProfile else { return false }
                        let allowed = await canExportSavedWorkout(
                            snapshot.entry, acknowledgedHistory: snapshot.acknowledgedHistory)
                        return !Task.isCancelled && showsProfile && allowed
                    }
                )
            }
            .environment(\.dynamicTypeSize, reviewDynamicTypeSize)
            .zoSheet()
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .sheet(item: savedWorkoutShareBinding(expected: savedWorkoutShare), onDismiss: {
            guard canHandleRootDomainCallback, savedWorkoutSharePresentationEpoch == directShareEpoch else { return }
            completePendingWidgetRoute()
        }) { route in
            ZOShareComposer(
                source: .workout(route.entry, acknowledgedHistory: route.acknowledgedHistory),
                localization: localization,
                canExport: {
                    guard savedWorkoutShare?.id == route.id, let coordinator = shareCoordinator,
                          await coordinator.authorize(route.presentation) else { return false }
                    guard savedWorkoutShare?.id == route.id,
                          await canExportSavedWorkout(route.entry, acknowledgedHistory: route.acknowledgedHistory),
                          savedWorkoutShare?.id == route.id else { return false }
                    return await coordinator.authorize(route.presentation)
                        && savedWorkoutShare?.id == route.id
                },
                sourceVersion: route.id,
                exportLifetime: route.presentation.lifetime
            )
            .onDisappear { closeSavedWorkoutShareIfCurrent(route) }
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .alert("Sharing unavailable", isPresented: $showsSavedShareUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your saved workout could not be verified. Try again when your activity has finished saving.")
        }
        .sheet(item: scheduledReviewBinding(expectedEpoch: scheduledEpoch), onDismiss: {
            guard canHandleRootDomainCallback, scheduledReviewPresentationEpoch == scheduledEpoch else { return }
            guard let appointment = pendingScheduledStart else { return }
            pendingScheduledStart = nil
            startScheduledWorkout(appointment, warmUpLength: scheduledStartWarmUp)
        }) { appointment in
            WorkoutAppointmentStartView(appointment: appointment,
                session: scheduledSession(for: appointment.reference), warmUp: $scheduledStartWarmUp,
                onStart: {
                    guard canHandleRootDomainCallback, scheduledReviewPresentationEpoch == scheduledEpoch, scheduledReview?.id == appointment.id else { return }
                    pendingScheduledStart = appointment
                    scheduledReview = nil
                }, onClose: {
                    guard canHandleRootDomainCallback, scheduledReviewPresentationEpoch == scheduledEpoch, scheduledReview?.id == appointment.id else { return }
                    scheduledReview = nil
                })
            .zoSheet()
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .alert("Workout schedule", isPresented: Binding(
            get: { scheduledWorkoutMessage != nil }, set: { if !$0 { scheduledWorkoutMessage = nil } }
        )) { Button("OK") { scheduledWorkoutMessage = nil } } message: { Text(scheduledWorkoutMessage ?? "") }
        .confirmationDialog("Clear the pending workout start?", isPresented: Binding(
            get: { orphanScheduledLaunch != nil }, set: { if !$0 { orphanScheduledLaunch = nil } }
        ), titleVisibility: .visible) {
            Button("Clear pending start") { clearOrphanScheduledLaunch() }
        } message: {
            Text("No matching saved workout was found. Clearing this appointment's pending start lets you start it again. History is unchanged.")
        }
        .sheet(isPresented: showsAssistantActionsBinding(expectedEpoch: assistantEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsAssistantActionsPresentationEpoch == assistantEpoch else { return }
            assistantSheetOpenedFromDock = false
            confirmedSpeechRequest = nil
            completePendingWidgetRoute()
        }) {
            if let voiceAssistant {
                AssistantActionSurfaceView(
                    context: assistantContext,
                    options: assistantActionPolicy.options(for: assistantActionContext),
                    voiceCoordinator: voiceAssistant,
                    initialRequest: assistantSheetOpenedFromDock ? confirmedSpeechRequest : Self.reviewAssistantRequest,
                    initialRequestCameFromConfirmedSpeech: assistantSheetOpenedFromDock
                        ? confirmedSpeechRequest != nil : Self.reviewAssistantRequestSource == "speech",
                    onSelect: handleAssistantAction,
                    onDismiss: {
                        guard canHandleRootDomainCallback, showsAssistantActionsPresentationEpoch == assistantEpoch else { return }
                        voiceAssistant.reset()
                        showsAssistantActions = false
                    }
                )
                .zoSheet()
                .zeroOneTheme(activeTheme)
                .preferredColorScheme(selectedAppearance.preferredColorScheme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(activeTheme.surfacePrimary)
            }
        }
        .sheet(isPresented: showsWellbeingReviewBinding(expectedEpoch: showsWellbeingReviewPresentationEpoch)) {
            WellbeingReviewView(repository: wellbeing, nutrition: nutritionRepository, assessment: wellbeingAssessment)
                .zoSheet()
                .zeroOneTheme(activeTheme)
                .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .sheet(isPresented: showsStepsBinding(expectedEpoch: stepsEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsStepsPresentationEpoch == stepsEpoch else { return }
            completePendingWidgetRoute()
        }) {
            StepsDayView(
                repository: stepsDay,
                distanceUnit: userProfile.profile.preferredDistanceUnit
                    ?? ZeroOneOnboardingUnitDefaults.distance(for: .current),
                dailyGoal: dailyGoals.isAvailable ? dailyGoals.value.steps : nil
            )
            .zoSheet()
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: showsWorkoutMusicBinding(expectedEpoch: musicEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsWorkoutMusicPresentationEpoch == musicEpoch else { return }
            completePendingWidgetRoute()
        }) {
            NavigationStack {
                WorkoutMusicView(music: workoutMusic, context: currentWorkoutMusicContext)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                guard canHandleRootDomainCallback, showsWorkoutMusicPresentationEpoch == musicEpoch else { return }
                                showsWorkoutMusic = false
                            }
                        }
                    }
            }
            .zoSheet()
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .fullScreenCover(isPresented: showsOutdoorActivityBinding(expectedEpoch: outdoorEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsOutdoorActivityPresentationEpoch == outdoorEpoch else { return }
            completePendingWidgetRoute()
        }) {
            OutdoorActivityView(
                model: outdoorActivity,
                profileInitial: outdoorProfileInitial,
                canExportSavedRecord: { record in await canExportSavedOutdoor(record) }
            )
                .onAppear {
                    guard isCurrentShareRoot, showsOutdoorActivity, showsOutdoorActivityPresentationEpoch == outdoorEpoch else { return }
                    shareCoordinator?.installContext { [self] in rootShareContext() }
                }
                .zoSheet()
                .zeroOneTheme(activeTheme)
                .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .sheet(isPresented: showsOutdoorKindChoiceBinding(expectedEpoch: outdoorChoiceEpoch), onDismiss: {
            guard canHandleRootDomainCallback, showsOutdoorKindChoicePresentationEpoch == outdoorChoiceEpoch else { return }
            if pendingWidgetRoute != nil {
                pendingOutdoorKind = nil
                completePendingWidgetRoute()
                return
            }
            guard let kind = pendingOutdoorKind else { return }
            pendingOutdoorKind = nil
            openOutdoorActivity(kind)
        }) {
            Group {
                outdoorKindChooser
            }
            .zoSheet()
        }
        .alert("One activity at a time", isPresented: $showsOutdoorConflict) {
            if outdoorConflictIsStrength {
                Button("View gym workout") { selectedTab = .workout }
            } else {
                Button("View outdoor activity") { showsOutdoorActivity = true }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Finish or recover the current activity before starting another. Your saved work stays intact.")
        }
    }

    private var rootLifecycle: some View {
        rootPresentations
        .environment(\.photoComparisonShareHostAuthority, photoShareAuthority)
        .environment(\.zeroOneOutdoorRepository, outdoorActivityRepository)
        .onDisappear {
            if isCurrentShareRoot && !showsProfile && !showsOutdoorActivity && savedWorkoutShare == nil {
                invalidateRootShareRoutes()
                photoShareAuthority.revokeAll(before: .hostDismissal)
                savedHistoryShareAuthority.revoke()
                shareCoordinator?.suspend()
            }
            assistantFeedbackTask?.cancel()
            quickWaterToastTask?.cancel()
            quickWaterToast = nil
        }
        .onAppear {
            if shareScenePhase != scenePhase { invalidateRootShareRoutes() }
            shareScenePhase = scenePhase
            configureLocalImportsIfNeeded()
            shareCoordinator?.installContext { [self] in rootShareContext() }
            reconcileWorkoutAppointments()
            #if DEBUG
            Self.launchLogger.notice(
                "AppRootView appeared tab=\(selectedTab.rawValue, privacy: .public) state=\(destinationState(for: selectedTab).rawValue, privacy: .public) scene=\(String(describing: scenePhase), privacy: .public)"
            )
            #endif
        }
        .task {
            #if DEBUG
            guard Self.reviewMainActionState == "animate-cycle" else { return }
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            Self.launchLogger.notice("Review main-action opening")
            withAnimation(mainActionAnimation) {
                showsMainActions = true
            }
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            Self.launchLogger.notice("Review main-action closing")
            dismissMainActions()
            #endif
        }
        .task(id: liveActivityProjection) {
            await liveActivityCoordinator.sync(liveActivityProjection)
        }
        .task(id: walkActivityProjection) {
            await walkActivityCoordinator.sync(walkActivityProjection)
        }
        .task {
            // Screen 51: once per version after an update, after the root has settled.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, whatsNew == nil, let pending = WhatsNewPolicy().pending() else { return }
            whatsNew = WhatsNewPresentation(version: pending.version, items: pending.items)
        }
        .task {
            // Proof 53: the trial's last days need Apple's verified trial state.
            await membership.start()
            refreshTrialMoments()
        }
        .onChange(of: membership.access) { _, _ in refreshTrialMoments() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .today { refreshTrialMoments() }
        }
        .sheet(isPresented: $showsTrialRecap) { trialRecapSheet }
        .sheet(item: $whatsNew) { presentation in
            WhatsNewView(version: presentation.version, items: presentation.items) {
                WhatsNewPolicy().markSeen()
                whatsNew = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(false)
            .onDisappear { WhatsNewPolicy().markSeen() }
            .zeroOneTheme(activeTheme)
            .preferredColorScheme(activeTheme.colorScheme)
        }
        .onChange(of: dailyWidgetInputs, initial: true) { _, inputs in
            publishDailyWidgetSnapshot(inputs)
        }
        .onChange(of: progressionAdviceAllowed, initial: true) { _, allowed in
            workoutViewModel.progressionRecommendationsAllowed = allowed
            Task {
                await smartNotes.updateProgressionAllowed(progressionAdviceAllowed)
                await reconcileProgressNoteCandidates()
            }
        }
        .onChange(of: workoutViewModel.session.id) { _, _ in
            workoutViewModel.progressionRecommendationsAllowed = progressionAdviceAllowed
        }
        .onOpenURL { url in
            guard let route = DailyWidgetRoute(url: url) else { return }
            openWidgetDestination(route)
        }
        .task {
            hydrationViewModel.refreshForCurrentDay()
            _ = await shareCoordinator?.installOutdoorOwners()
            // Sharing installation failure never suppresses normal recovery/load.
            await outdoorActivity.load()
            // Study 36: Pause and Resume from the walk's Live Activity, for this exact session.
            WalkActivityControl.handler = { [outdoorActivity] command, sessionID in
                guard outdoorActivity.checkpoint?.id == sessionID else { return }
                switch command {
                case .pause: await outdoorActivity.pause()
                case .resume: await outdoorActivity.startWithRoute()
                }
            }
            await refreshWellbeingOutdoorHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            hydrationViewModel.refreshForCurrentDay()
            publishDailyWidgetSnapshot(dailyWidgetInputs)
        }
        .onReceive(NotificationCenter.default.publisher(for: .outdoorHistoryDidChange).receive(on: RunLoop.main)) { _ in
            Task { await outdoorActivity.refreshLatestWalk(clearCached: true) }
            Task { await refreshWellbeingOutdoorHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in
            hydrationViewModel.refreshForCurrentDay()
            publishDailyWidgetSnapshot(dailyWidgetInputs)
        }
        .task {
            let progressionPolicy: @MainActor () -> Bool = {
                [workoutHistory, wellbeing, nutritionRepository, dailyGoals, hydrationViewModel,
                 healthConnection, wellbeingOutdoorEvidence, outdoorActivityRepository] in
                WellbeingAssessmentSource.permitsAutomaticProgression(history: workoutHistory, recovery: wellbeing,
                    nutrition: nutritionRepository, goals: dailyGoals, water: hydrationViewModel,
                    health: healthConnection, outdoor: wellbeingOutdoorEvidence,
                    outdoorRepository: outdoorActivityRepository)
            }
            workoutDemand.install { [workoutHistory, wellbeing, nutritionRepository, dailyGoals,
                hydrationViewModel, healthConnection, wellbeingOutdoorEvidence, outdoorActivityRepository] now, calendar in
                await wellbeingOutdoorEvidence.refresh(using: outdoorActivityRepository)
                wellbeing.reload()
                dailyGoals.reload()
                hydrationViewModel.refreshForCurrentDay()
                guard (try? workoutHistory.confirmedEntries()) != nil,
                      wellbeing.isAvailable, dailyGoals.isAvailable,
                      (try? nutritionRepository.readForImport()) != nil,
                      wellbeingOutdoorEvidence.records != nil else { return nil }
                return WellbeingAssessmentSource.assess(history: workoutHistory, recovery: wellbeing,
                    nutrition: nutritionRepository, goals: dailyGoals, water: hydrationViewModel,
                    health: healthConnection, outdoor: wellbeingOutdoorEvidence, at: now, calendar: calendar)
            }
            exerciseSubstitution.install { [userProfile, workoutDemand, outdoorActivity, activeWorkoutStore] session in
                guard let assessment = await workoutDemand.assessment(at: .now),
                      outdoorActivity.isLoaded, !outdoorActivity.hasUnfinishedSession,
                      let stored = try activeWorkoutStore.load(), stored.session == session,
                      let profile = try userProfile.profileForExport() else {
                    throw ExerciseSubstitutionSelectionError.unavailable
                }
                return .init(profile: profile, assessment: assessment)
            }
            workoutLoadChoices.setProgressionPolicy(progressionPolicy)
            workoutProgression.install(currentPlans: { [customWorkouts, programmeVolume] source in
                if let id = source.programmeID {
                    guard let base = WorkoutProgrammeLibrary.programme(id: id),
                          let effective = try? programmeVolume.effective(base) else { return nil }
                    return effective.sessions.flatMap(\.exercisePlans)
                }
                guard customWorkouts.isAvailable else { return nil }
                return customWorkouts.workouts.compactMap { $0.makeSession() }.flatMap { $0.exercises.map(\.plan) }
            }, refreshCurrentPlans: { [customWorkouts, programmeVolume] source in
                source.programmeID != nil ? programmeVolume.reload() : customWorkouts.reload()
            }, increaseAllowed: progressionPolicy)
            workoutLoadChoices.setProgressionValidator { [workoutProgression] upgrade, sourceID in
                workoutProgression.validate(upgrade, sourceSessionID: sourceID, requireIncrease: false)
            }
            await smartNotes.install(workoutActive: notificationWorkoutActive,
                progressionAllowed: progressionAdviceAllowed,
                progressChoice: { [workoutHistory, workoutLoadChoices, workoutProgression, programmeCoordinator, outdoorActivity, activeWorkoutStore, progressionPolicy] note, selection in
                    let hasSavedWorkout: Bool
                    do { hasSavedWorkout = try activeWorkoutStore.load() != nil }
                    catch { return .unavailable }
                    return SmartNoteProgressAction.apply(selection, to: note, history: workoutHistory,
                        choices: workoutLoadChoices, programmeID: programmeCoordinator.selectedProgrammeID, now: .now,
                        workoutActive: programmeCoordinator.route.isActive || hasSavedWorkout || outdoorActivity.hasUnfinishedSession,
                        progressionAllowed: progressionPolicy(),
                        progressionReviews: workoutProgression.reviews.reload() ? workoutProgression.reviews.snapshot.reviews : [])
                }, progressUndo: { [workoutHistory, workoutLoadChoices, programmeCoordinator, outdoorActivity, activeWorkoutStore] receipt in
                    let hasSavedWorkout: Bool
                    do { hasSavedWorkout = try activeWorkoutStore.load() != nil }
                    catch { return false }
                    return SmartNoteProgressAction.undo(receipt, history: workoutHistory, choices: workoutLoadChoices,
                        workoutActive: programmeCoordinator.route.isActive || hasSavedWorkout || outdoorActivity.hasUnfinishedSession)
                })
            if let latest = workoutHistory.entries.first,
               Calendar.current.isDateInToday(latest.completedAt) {
                await smartNotes.trainingCompleted(at: latest.completedAt)
            }
            await reconcileProgressNoteCandidates()
            await reconcileTrainingDayReminders()
        }
    }

    var body: some View {
        rootLifecycle
        .environment(\.zeroOneWorkoutDemandAuthority, workoutDemand)
        .environment(\.zeroOneExerciseSubstitutionAuthority, exerciseSubstitution)
        .environment(\.zeroOneWorkoutProgression, workoutProgression)
        .environment(\.zeroOneWellbeingAssessment, wellbeingAssessment)
        .environment(\.zeroOneProgressionAllowed, progressionAdviceAllowed)
        .onChange(of: notificationWorkoutActive) { _, active in
            Task { await smartNotes.foreground(workoutActive: active,
                progressionAllowed: progressionAdviceAllowed) }
        }
        .onChange(of: scenePhase) { _, phase in
            invalidateRootShareRoutes()
            shareScenePhase = phase
            #if DEBUG
            Self.launchLogger.notice("AppRootView scene changed to \(String(describing: phase), privacy: .public)")
            #endif
            if phase == .active {
                programmeCoordinator.reloadSchedule()
                programmeVolume.reload()
                reconcileWorkoutAppointments()
                dailyGoals.reload()
                wellbeing.reload()
                workoutProgression.reviews.reload()
                refreshTrialMoments()
                hydrationViewModel.refreshForCurrentDay()
                Task { await outdoorActivity.refreshLatestWalk() }
                Task { await refreshWellbeingOutdoorHistory() }
                publishDailyWidgetSnapshot(dailyWidgetInputs)
                Task {
                    await smartNotes.foreground(workoutActive: notificationWorkoutActive,
                        progressionAllowed: progressionAdviceAllowed)
                    await reconcileTrainingDayReminders()
                }
            }
        }
        .onChange(of: workoutViewModel.isCompletionSaved) { _, saved in
            guard saved, let completedAt = workoutViewModel.session.completedAt else { return }
            let session = workoutViewModel.session
            _ = workoutAppointments.associateAcknowledgedCompletionForSession(sessionID: session.id)
            let candidate = SmartNoteCandidates.progressAfterAcknowledgedSave(
                session: session,
                recordResult: workoutViewModel.lastCompletionRecordResult ?? .alreadyRecorded,
                origin: .liveWorkout,
                currentProgrammeID: programmeCoordinator.selectedProgrammeID,
                savedHistory: workoutHistory.availability == .available ? workoutHistory.entries : nil,
                loadChoices: workoutLoadChoices.isAvailable ? workoutLoadChoices.choices : nil,
                records: smartNotes.snapshot.records,
                now: .now,
                calendar: .current,
                progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : []
            )
            Task {
                await smartNotes.trainingCompleted(at: completedAt)
                let otherKinds = smartNotes.snapshot.candidates.filter { $0.kind != .progress }
                // `candidate` is optional and Optional has no `filter`; keep it only while still current.
                var stillCurrent: [SmartNoteCandidate] = []
                if let note = candidate,
                   !wellbeingAssessment.holdsAutomaticProgression,
                   note.programmeID == programmeCoordinator.selectedProgrammeID?.rawValue,
                   workoutHistory.entries.first?.id == session.id,
                   !workoutLoadChoices.choices.contains(where: { $0.sourceSessionID.uuidString == note.sessionID }) {
                    stillCurrent = [note]
                }
                await smartNotes.replaceCandidates(
                    otherKinds + stillCurrent,
                    workoutActive: notificationWorkoutActive
                )
            }
        }
        .onChange(of: workoutLoadChoices.choices) { _, _ in
            Task { await reconcileProgressNoteCandidates() }
        }
        .onChange(of: programmeCoordinator.selectedProgrammeID) { _, _ in
            Task {
                await reconcileProgressNoteCandidates()
                await reconcileTrainingDayReminders()
            }
        }
        .onChange(of: programmeCoordinator.activeSchedule) { _, _ in
            Task { await reconcileTrainingDayReminders() }
        }
        .onChange(of: smartNotes.preferences.trainingReminderMinute) { _, _ in
            Task { await reconcileTrainingDayReminders() }
        }
        .onChange(of: smartNotes.opensSettings) { _, open in
            guard open else { return }
            smartNotes.opensSettings = false
            profileDestination = .notifications
            showsProfile = true
        }
        .onChange(of: smartNotes.routeCandidateID) { _, id in
            guard let id else { return }
            defer { smartNotes.routeCandidateID = nil }
            guard let candidate = smartNotes.snapshot.candidates.first(where: { $0.id == id }),
                  let rawProgrammeID = candidate.programmeID,
                  let programmeID = WorkoutProgrammeID(rawValue: rawProgrammeID) else { return }
            if candidate.kind == .progress {
                profileDestination = .progress
                showsProfile = true
                return
            }
            guard let programme = WorkoutProgrammeLibrary.programme(id: programmeID),
                  let sessionID = candidate.sessionID,
                  programme.sessions.contains(where: { $0.id == sessionID }) else { return }
            showWorkoutDetail( programmeID)
            selectedTab = .workout
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        let state = destinationState(for: selectedTab)

        if state != .initial {
            NavigationStack {
                ZeroOneDestinationStateView(
                    destination: selectedTab,
                    state: state,
                    onShowInitial: { demoState.set(.initial, for: selectedTab) }
                )
            }
        } else {
            switch selectedTab {
            case .today:
                NavigationStack {
                    TodayView(
                        session: todayDisplaySession,
                        workoutState: todayWorkoutState,
                        historyState: workoutHistory.surfaceState,
                        learnRepository: learnRepository,
                        hydration: hydrationViewModel.state,
                        healthConnection: healthConnection,
                        availableWorkoutMinutes: dailyContext.currentAvailableWorkoutMinutes(),
                        planRationale: userProfile.profile.savedFirstWeekPlan?.plan.reasons.map(\.explanation) ?? [],
                        isWorkoutInProgress: programmeCoordinator.route.isActive,
                        offersFinishSetup: userProfile.profile.onboardingWasSkipped == true,
                        onOpenProfile: { showsProfile = true },
                        onFinishSetup: {
                            profileDestination = .baseline
                            showsProfile = true
                        },
                        onOpenAppleHealth: {
                            profileDestination = .appleHealth
                            showsProfile = true
                        },
                        onOpenWorkout: openTodayWorkout,
                        onOpenHistory: {
                            if case let .completed(item) = todayWorkoutState {
                                profileDestination = .session(item.id)
                            } else {
                                profileDestination = .history
                            }
                            showsProfile = true
                        },
                        onOpenProgress: {
                            profileDestination = .progress
                            showsProfile = true
                        },
                        canLogWater: hydrationViewModel.canConfirmQuickWaterSave,
                        onAddWater: { hydrationViewModel.addWaterFromQuickAction(milliliters: $0) },
                        onUndoWater: { hydrationViewModel.undoQuickWaterLog($0) },
                        wellbeingAssessment: wellbeingAssessment,
                        onReviewWellbeing: { showsWellbeingReview = true },
                        programmeVolumeUnavailable: todayProgrammeVolumeUnavailable,
                        dailyStepGoal: dailyGoals.isAvailable ? dailyGoals.value.steps : nil,
                        missedPlanCard: todayTopCardsView
                    )
                }
            case .workout:
                NavigationStack {
                    workoutDestination
                }
            case .social:
                NavigationStack {
                    SocialHomeView(
                        history: workoutHistory,
                        isWorkoutActive: programmeCoordinator.route.isActive,
                        workoutStateAvailable: !showsWorkoutRecoveryError
                    )
                }
            case .diets:
                NavigationStack {
                    DietsWorldView(
                        focusHydration: $focusHydrationInDiets,
                        onOpenProfile: { showsProfile = true },
                        today: { isActive, openTrackers in
                            DietsHomeView(
                                nutrition: nutritionRepository,
                                hydration: hydrationViewModel,
                                reviewDraft: Self.reviewNutritionDraft,
                                focusHydration: $focusHydrationInDiets,
                                onOpenProfile: { showsProfile = true },
                                showsHeader: false,
                                onOpenTrackers: openTrackers,
                                isActive: isActive,
                                trackerSummary: { AnyView(DietTrackerChecklistView(model: dietTrackerFeature)) },
                                openFoodLog: $openFoodLogInDiets
                            )
                        },
                        trackers: { DietTrackersView(model: dietTrackerFeature) },
                        learn: { DietsLearnEmptyView() }
                    )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let message = hydrationViewModel.persistenceErrorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).zoText(.body)
                                Button("Dismiss") { hydrationViewModel.dismissPersistenceError() }
                                    .frame(minHeight: 44)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(activeTheme.surfacePrimary)
                            .foregroundStyle(activeTheme.textPrimary)
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .alert("Meal wasn't removed", isPresented: Binding(
                        get: { nutritionRepository.removalFailureMessage != nil },
                        set: { if !$0 { nutritionRepository.dismissRemovalFailure() } }
                    )) {
                        Button("OK", role: .cancel) { nutritionRepository.dismissRemovalFailure() }
                    } message: {
                        Text(nutritionRepository.removalFailureMessage ?? "Your meal has been kept. Try again.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workoutDestination: some View {
        switch programmeCoordinator.route {
        case .library:
            WorkoutLibraryView(
                programmes: programmeCoordinator.programmes,
                selectedProgrammeID: programmeCoordinator.selectedProgrammeID,
                activeSchedule: programmeCoordinator.activeSchedule,
                scheduleIsAvailable: programmeCoordinator.scheduleIsAvailable,
                workoutHistory: workoutHistory,
                customWorkouts: customWorkouts,
                onOpenProfile: { showsProfile = true },
                onSelect: { showWorkoutDetail( $0) },
                onStartCustom: { startCustomWorkout($0, warmUpLength: $1) },
                outdoorActivityInProgress: outdoorActivity.hasUnfinishedSession,
                onOpenOutdoor: openOutdoorActivity,
                music: workoutMusic,
                musicNamespace: workoutMusicJoin,
                onOpenSchedule: { profileDestination = .schedule; showsProfile = true },
                onOpenHistory: { profileDestination = .history; showsProfile = true }
            )
        case .detail:
            if let baseProgramme = programmeCoordinator.selectedProgramme,
               let programme = try? programmeVolume.effective(baseProgramme) {
                ProgrammeDetailView(
                    programme: programme,
                    previewSession: programme.makeSession(
                        previousHistory: progressionHistory,
                        loadChoices: workoutLoadChoices.choices,
                        progressionAllowed: progressionAdviceAllowed,
                        progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : []
                    ),
                    activeSchedule: programmeCoordinator.activeSchedule,
                    scheduleIsAvailable: programmeCoordinator.scheduleIsAvailable,
                    onBack: showWorkoutLibrary,
                    onStart: { startSelectedProgramme(warmUpLength: $0) },
                    onConfirmSchedule: { days, reviewed in
                        try programmeCoordinator.confirmSchedule(for: programme.id, weekdays: days, replacing: reviewed)
                    },
                    customWorkouts: customWorkouts,
                    onStartCustom: { startCustomWorkout($0, warmUpLength: $1) },
                    music: workoutMusic,
                    onPrepareVolumePlan: { change in
                        let context = try await programmeVolumeContext(for: programme.id)
                        return try ProgrammeVolumePlanner().proposal(change: change, context: context, at: .now)
                    },
                    onApplyVolumePlan: { proposal in
                        let context = try await programmeVolumeContext(for: programme.id)
                        try programmeVolume.accept(proposal, context: context, at: .now)
                    },
                    volumeChangeIsActive: (try? programmeVolume.revision(for: programme.id)) != nil,
                    volumeIsAvailable: (try? programmeVolume.effective(baseProgramme)) != nil,
                    onValidateVolume: {
                        guard programmeVolume.reload(),
                              let current = try? programmeVolume.effective(baseProgramme),
                              try ProgrammeVolumeSource.fingerprint(current) == ProgrammeVolumeSource.fingerprint(programme) else {
                            throw ProgrammeVolumeError.stale
                        }
                    },
                    onPrepareWeeklyPlan: { change, availability in
                        let context = try await weeklyTrainingContext(for: programme.id)
                        return try WeeklyTrainingPlanner().proposal(change: change, availability: availability,
                            context: context, at: .now)
                    },
                    onApplyWeeklyPlan: { proposal in
                        let context = try await weeklyTrainingContext(for: programme.id)
                        let now = Date.now
                        let checked = try WeeklyTrainingPlanner().revalidated(proposal, context: context, at: now)
                        do {
                            try programmeCoordinator.confirmSchedule(for: programme.id, weekdays: checked.proposedWeekdays,
                                replacing: checked.originalSchedule, at: now)
                        } catch WorkoutProgrammeScheduleError.staleSchedule { throw WeeklyTrainingPlanningError.stale }
                        catch { throw WeeklyTrainingPlanningError.unavailable }
                        guard let saved = programmeCoordinator.activeSchedule else { throw WeeklyTrainingPlanningError.unavailable }
                        return saved
                    },
                    musicNamespace: workoutMusicJoin
                )
            } else if let programme = programmeCoordinator.selectedProgramme {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Button("Back", action: showWorkoutLibrary)
                    Text(programme.title).zoText(.display)
                    Text("The saved programme sets could not be verified. Open the programme to retry or review its adjustment before starting.")
                    Button("Retry programme records") { programmeVolume.reload() }
                    Button("Review future programme sets") { showsUnavailableVolumeReview = true }
                }
                .padding(ZOSpace.xl)
                .sheet(isPresented: $showsUnavailableVolumeReview) {
                    Group {
                        ProgrammeVolumeReviewView(initialChange: .discardObsolete, onPrepare: { change in
                            let context = try await programmeVolumeContext(for: programme.id)
                            return try ProgrammeVolumePlanner().proposal(change: change, context: context, at: .now)
                        }, onApply: { proposal in
                            let context = try await programmeVolumeContext(for: programme.id)
                            try programmeVolume.accept(proposal, context: context, at: .now)
                        }).zeroOneTheme(activeTheme)
                    }
                    .zoSheet(activeTheme)
                }
            } else {
                WorkoutLibraryView(
                    programmes: programmeCoordinator.programmes,
                    selectedProgrammeID: nil,
                    activeSchedule: programmeCoordinator.activeSchedule,
                    scheduleIsAvailable: programmeCoordinator.scheduleIsAvailable,
                    workoutHistory: workoutHistory,
                    customWorkouts: customWorkouts,
                    onOpenProfile: { showsProfile = true },
                    onSelect: { showWorkoutDetail( $0) },
                    onStartCustom: { startCustomWorkout($0, warmUpLength: $1) },
                    outdoorActivityInProgress: outdoorActivity.hasUnfinishedSession,
                    onOpenOutdoor: openOutdoorActivity,
                    music: workoutMusic,
                    musicNamespace: workoutMusicJoin,
                    onOpenSchedule: { profileDestination = .schedule; showsProfile = true },
                    onOpenHistory: { profileDestination = .history; showsProfile = true }
                )
            }
        case .active, .customActive:
            WorkoutView(
                viewModel: workoutViewModel,
                music: workoutMusic,
                progressPhotos: progressPhotos,
                workoutHistory: workoutHistory,
                workoutLoadChoices: workoutLoadChoices,
                onFinish: finishActiveWorkout,
                onViewSession: {
                    finishActiveWorkout()
                    profileDestination = .session(workoutViewModel.session.id)
                    showsProfile = true
                },
                onExit: exitActiveWorkout,
                onOpenAssistant: openAssistant,
                musicNamespace: workoutMusicJoin,
                onShare: {
                    let sessionID = workoutViewModel.session.id
                    Task { await openSavedWorkoutShare(sessionID) }
                },
                shareIsBusy: isPreparingSavedShare
            )
        }
    }

    private func openRecommendedProgramme() {
        if resumePendingCompletion() { return }
        if nextSavedPlanWorkout != nil {
            openTodayWorkout()
            return
        }
        showWorkoutDetail(
             programmeCoordinator.activeSchedule?.programmeID ?? WorkoutProgrammeLibrary.recommendedID
        )
        selectedTab = .workout
    }

    private var currentWorkoutMusicContext: WorkoutMusicContext? {
        if programmeCoordinator.route.isActive {
            return WorkoutMusicContext(session: workoutViewModel.session, stage: .active,
                isPaused: workoutViewModel.isPaused,
                awaitingNextSet: workoutViewModel.awaitingNextSetAcknowledgement,
                awaitingFinalSetConfirmation: workoutViewModel.awaitingFinalSetConfirmation)
        }
        if let checkpoint = outdoorActivity.checkpoint {
            return WorkoutMusicContext(outdoor: checkpoint,
                needsExplicitResume: outdoorActivity.surface != .recording)
        }
        if case .detail = programmeCoordinator.route,
           let base = programmeCoordinator.selectedProgramme,
           let programme = try? programmeVolume.effective(base) {
            return WorkoutMusicContext(session: programme.makeSession(), stage: .ready)
        }
        return nil
    }

    private func openTodayWorkout() {
        if todayProgrammeVolumeUnavailable {
            showWorkoutDetail( programmeCoordinator.activeSchedule?.programmeID ?? WorkoutProgrammeLibrary.recommendedID)
            selectedTab = .workout
            return
        }
        if programmeCoordinator.route.isActive {
            if selectedTab != .workout, workoutViewModel.persistenceErrorMessage == nil {
                mainActionStore.recordUse(.workout)
            }
            selectedTab = .workout
            return
        }

        switch todayWorkoutState {
        case .ready:
            if let planned = nextSavedPlanWorkout {
                _ = startCustomWorkout(planned, warmUpLength: planned.warmUpLength ?? .full)
                return
            }
            showWorkoutDetail(
                 programmeCoordinator.activeSchedule?.programmeID ?? WorkoutProgrammeLibrary.recommendedID
            )
            startSelectedProgramme()
        case .completed, .unavailable:
            showWorkoutLibrary()
            selectedTab = .workout
        }
    }

    /// User-triggered weekly review uses fresh host-owned inputs. Preferred
    /// weekdays never consume/reorder sessions or move dated appointments.
    @MainActor
    private func weeklyTrainingContext(for id: WorkoutProgrammeID) async throws -> WeeklyTrainingContext {
        let assessment = await workoutDemand.assessment(at: .now)
        let now = Date.now
        guard programmeCoordinator.selectedProgrammeID == id,
              programmeCoordinator.route == .detail(id),
              outdoorActivity.isLoaded,
              programmeCoordinator.reloadSchedule(at: now),
              let programme = programmeCoordinator.selectedProgramme,
              let schedule = programmeCoordinator.activeSchedule, schedule.programmeID == id,
              programmeVolume.reload(at: now),
              let effective = try? programmeVolume.effective(programme),
              let assessment else { throw WeeklyTrainingPlanningError.unavailable }
        let hasSavedWorkout: Bool
        do { hasSavedWorkout = try activeWorkoutStore.load() != nil }
        catch { throw WeeklyTrainingPlanningError.unavailable }
        workoutAppointments.reload()
        guard workoutAppointments.isAvailable else { throw WeeklyTrainingPlanningError.unavailable }
        return .init(programme: effective, schedule: schedule, assessment: assessment,
            hasUnfinishedWorkout: hasSavedWorkout || programmeCoordinator.route.isActive || outdoorActivity.hasUnfinishedSession,
            appointments: workoutAppointments.appointments)
    }

    @MainActor private func programmeVolumeContext(for id: WorkoutProgrammeID) async throws -> ProgrammeVolumeContext {
        let assessment = await workoutDemand.assessment(at: .now)
        let now = Date.now
        guard programmeCoordinator.selectedProgrammeID == id, programmeCoordinator.route == .detail(id),
              outdoorActivity.isLoaded, programmeVolume.reload(at: now),
              wellbeing.isAvailable, let programme = programmeCoordinator.selectedProgramme,
              let assessment else { throw ProgrammeVolumeError.unavailable }
        let calendarEvidence = programmeCoordinator.programmeVolumeCalendarEvidence(at: now)
        let active = try activeWorkoutStore.load() != nil
        let report = wellbeing.snapshot.recovery.filter { $0.isCurrent(at: now, calendar: .current) }
            .sorted { $0.reportedAt > $1.reportedAt }.first
        let revision = try programmeVolume.revision(for: id)
        let hasUnfinished = active || programmeCoordinator.route.isActive || outdoorActivity.hasUnfinishedSession
        let observedProgramme: WorkoutProgramme
        do { observedProgramme = try ProgrammeVolumeSource.effective(programme, revision: revision, at: now) }
        catch ProgrammeVolumeError.sourceChanged {
            // Explicit obsolete-adjustment removal observes the current authored
            // candidate. The old revision stays separately bound in the review.
            observedProgramme = programme
        }
        let planning = try ProgrammePlanningObservation.capture(programme: observedProgramme,
            history: try workoutHistory.confirmedEntries(), sessionsPerWeek: calendarEvidence.weeklyDays(for: programme, at: now),
            hasActiveSession: hasUnfinished,
            constraints: .init(safety: report?.hasNewOrWorseningPain == true || report?.feelsUnwell == true ? .limitationReported : .unknown,
                availableEquipmentIDs: nil, blockedExerciseIDs: [], allowedSessionIDs: nil, maximumSessionsPerWeek: nil), at: now)
        return .init(programme: programme, revision: revision, calendarEvidence: calendarEvidence,
            assessment: assessment, recovery: report,
            hasUnfinishedWorkout: hasUnfinished, planningObservation: planning)
    }

    private func startSelectedProgramme(warmUpLength: WorkoutWarmUpLength = .full) {
        invalidateRootShareRoutes()
        guard outdoorActivity.isLoaded, !outdoorActivity.hasUnfinishedSession else {
            outdoorConflictIsStrength = false
            showsOutdoorConflict = true
            return
        }
        if resumePendingCompletion() { return }
        do {
            if try restoreExistingWorkout() {
                if workoutViewModel.persistenceErrorMessage == nil { mainActionStore.recordUse(.workout) }
                return
            }
            showsWorkoutRecoveryError = false
        } catch {
            showsWorkoutRecoveryError = true
            return
        }
        refreshProgressionForStart()
        guard programmeVolume.reload(), let base = programmeCoordinator.selectedProgramme,
              let programme = try? programmeVolume.effective(base) else {
            showsProgrammeVolumeError = true; return
        }
        guard var session = programmeCoordinator.startSelectedProgramme(
            effectiveProgramme: programme,
            previousHistory: progressionHistory,
            loadChoices: workoutLoadChoices.choices,
            progressionAllowed: progressionAdviceAllowed,
            progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : []
        ) else { return }
        session.selectWarmUpLength(warmUpLength, at: .now)
        workoutViewModel.invalidateElapsedEvidence()
        workoutViewModel = WorkoutViewModel(
            session: session,
            requiresFinalSetReview: true,
            acceptedStart: WorkoutElapsedClock.continuous.read(),
            onSnapshotChanged: { snapshot, sessionID in
                if let snapshot {
                    try activeWorkoutStore.save(snapshot)
                } else {
                    try activeWorkoutStore.clear(expectedSessionID: sessionID)
                }
            },
            onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
            shareRevocationRegistration: shareCoordinator?.registration
        )
        if workoutViewModel.persistenceErrorMessage == nil {
            workoutMusic.prepareForWorkout(sessionID: session.id, preservingReadySelection: true)
            mainActionStore.recordUse(.workout)
        }
        selectedTab = .workout
    }

    @discardableResult
    private func startCustomWorkout(
        _ workout: CustomWorkout,
        warmUpLength: WorkoutWarmUpLength
    ) -> Bool {
        invalidateRootShareRoutes()
        guard outdoorActivity.isLoaded, !outdoorActivity.hasUnfinishedSession else {
            outdoorConflictIsStrength = false
            showsOutdoorConflict = true
            return false
        }
        if resumePendingCompletion() { return true }
        do {
            if try restoreExistingWorkout() {
                if workoutViewModel.persistenceErrorMessage == nil { mainActionStore.recordUse(.workout) }
                return true
            }
            showsWorkoutRecoveryError = false
        } catch {
            showsWorkoutRecoveryError = true
            return false
        }
        refreshProgressionForStart()
        guard var session = workout.makeSession(previousHistory: progressionHistory,
                                                warmUpLengthOverride: warmUpLength,
                                                loadChoices: workoutLoadChoices.choices,
                                                progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : [],
                                                progressionAllowed: progressionAdviceAllowed) else { return false }
        session.selectWarmUpLength(warmUpLength, at: .now)
        programmeCoordinator.restoreActiveCustomWorkout(workout.id)
        workoutViewModel.invalidateElapsedEvidence()
        workoutViewModel = WorkoutViewModel(
            session: session,
            requiresFinalSetReview: true,
            acceptedStart: WorkoutElapsedClock.continuous.read(),
            onSnapshotChanged: { snapshot, sessionID in
                if let snapshot { try activeWorkoutStore.save(snapshot) }
                else { try activeWorkoutStore.clear(expectedSessionID: sessionID) }
            },
            onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
            shareRevocationRegistration: shareCoordinator?.registration
        )
        if workoutViewModel.persistenceErrorMessage == nil {
            workoutMusic.prepareForWorkout(sessionID: session.id, preservingReadySelection: true)
            mainActionStore.recordUse(.workout)
        }
        selectedTab = .workout
        return true
    }

    private func resumePendingCompletion() -> Bool {
        invalidateRootShareRoutes()
        guard workoutViewModel.session.isComplete, !workoutViewModel.isCompletionSaved else { return false }
        if let programmeID = workoutViewModel.session.programmeID {
            programmeCoordinator.restoreActiveProgramme(programmeID)
        } else if let customID = workoutViewModel.session.customWorkoutID {
            programmeCoordinator.restoreActiveCustomWorkout(customID)
        } else {
            return false
        }
        selectedTab = .workout
        return true
    }

    private func retryWorkoutRecovery() {
        invalidateRootShareRoutes()
        do {
            _ = try restoreExistingWorkout()
            showsWorkoutRecoveryError = false
        } catch {
            showsWorkoutRecoveryError = true
        }
    }

    private func restoreExistingWorkout() throws -> Bool {
        invalidateRootShareRoutes()
        guard var snapshot = try activeWorkoutStore.load() else { return false }
        if let programmeID = snapshot.session.programmeID {
            guard WorkoutProgrammeLibrary.programme(id: programmeID) != nil else {
                throw WorkoutPersistenceError.invalidSnapshot
            }
        } else if snapshot.session.customWorkoutID == nil {
            throw WorkoutPersistenceError.invalidSnapshot
        }
        // Do not replace newer in-memory values after a failed snapshot write.
        if workoutViewModel.session.id != snapshot.session.id {
            snapshot.resolveElapsedRest(at: .now)
            workoutViewModel.invalidateElapsedEvidence()
            workoutViewModel = WorkoutViewModel(
                session: snapshot.session, restoredSnapshot: snapshot,
                requiresFinalSetReview: true,
                onSnapshotChanged: { snapshot, sessionID in
                    if let snapshot { try activeWorkoutStore.save(snapshot) }
                    else { try activeWorkoutStore.clear(expectedSessionID: sessionID) }
                },
                onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
                shareRevocationRegistration: shareCoordinator?.registration
            )
        }
        if let programmeID = snapshot.session.programmeID {
            programmeCoordinator.restoreActiveProgramme(programmeID)
        } else if let customID = snapshot.session.customWorkoutID {
            programmeCoordinator.restoreActiveCustomWorkout(customID)
        }
        selectedTab = .workout
        return true
    }

    private func finishActiveWorkout() {
        invalidateRootShareRoutes()
        guard workoutViewModel.isCompletionSaved else { return }
        showWorkoutLibrary()
        selectedTab = .today
    }

    /// Proof 41: Do it today moves the plan to now and opens it; Move keeps the time tomorrow; Skip cancels.
    private var todayTopCardsView: AnyView? {
        let trial = trialEndingCardView
        let missed = missedPlanCardView
        guard trial != nil || missed != nil else { return nil }
        return AnyView(VStack(spacing: ZOSpace.m) {
            if let trial { trial }
            if let missed { missed }
        })
    }

    private var trialHistory: [WorkoutHistoryEntry]? {
        workoutHistory.availability == .available ? workoutHistory.entries : nil
    }

    private func trialRenewal(_ window: TrialWindow) -> MembershipRecapRenewal {
        if let renewal = membership.trialRenewal, renewal.trialEnds == window.end { return renewal }
        return MembershipRecapRenewal(trialEnds: window.end, continuation: trialMoments.continuation,
                                      verifiedPrice: nil, verifiedPeriod: nil)
    }

    /// Proof 53: day 13 and 14 of the trial, while Apple still reports the trial.
    private var trialEndingCardView: AnyView? {
        guard case .trial = membership.access, let window = trialMoments.window, !trialMoments.cardDismissed,
              window.showsTodayCard(now: .now, calendar: .current) else { return nil }
        return AnyView(TrialEndingCard(window: window, renewal: trialRenewal(window),
            progress: TrialProgress.make(window: window, history: trialHistory, calendar: .current),
            onGotIt: { trialMoments.dismissCard() }))
    }

    @ViewBuilder private var trialRecapSheet: some View {
        if let window = trialMoments.window {
            let history = trialHistory
            let progress = TrialProgress.make(window: window, history: history, calendar: .current)
            TrialRecapHost(
                recap: history.flatMap { progress?.recap(window: window, history: $0, calendar: .current) },
                renewal: trialRenewal(window), shareFacts: progress?.share,
                onClose: { showsTrialRecap = false })
                .zeroOneTheme(activeTheme)
                .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
    }

    /// Records Apple's trial state, rebuilds the two trial notifications, and opens
    /// "Your 14 days" once on the last evening when Today is in front.
    private func refreshTrialMoments() {
        if let renewal = membership.trialRenewal { trialMoments.record(renewal) }
        guard let window = trialMoments.window, membership.access != .checking else { return }
        var continued = false
        if case .member = membership.access { continued = true }
        let progress = TrialProgress.make(window: window, history: trialHistory, calendar: .current)
        TrialNotificationScheduler.reconcile(!MembershipNotificationPreference.membershipOn ? [] : TrialNotificationScheduler.plan(
            window: window, continuation: trialMoments.continuation, continued: continued,
            renewal: membership.trialRenewal, progress: progress, now: .now, calendar: .current,
            localization: localization))
        guard window.recapIsDue(now: .now, calendar: .current), !trialMoments.recapShown,
              selectedTab == .today, scenePhase == .active, !showsTrialRecap,
              !rootVoiceHasCompetingPresentation, whatsNew == nil else { return }
        trialMoments.markRecapShown()
        showsTrialRecap = true
    }

    private var missedPlanCardView: AnyView? {
        guard !programmeCoordinator.route.isActive,
              let missed = MissedPlan.latest(workoutAppointments.appointments) else { return nil }
        return AnyView(MissedPlanCard(appointment: missed, onDoToday: {
            var moved = missed
            moved.startsAt = Date.now.addingTimeInterval(60)
            guard workoutAppointments.save(moved, expectedRevision: missed.revision) else { return }
            reconcileWorkoutAppointments()
            openScheduledWorkout(missed.reference, missed.id)
        }, onMoveToTomorrow: {
            guard let tomorrow = MissedPlan.tomorrow(at: missed.startsAt) else { return }
            var moved = missed
            moved.startsAt = tomorrow
            if workoutAppointments.save(moved, expectedRevision: missed.revision) { reconcileWorkoutAppointments() }
        }, onSkip: {
            if workoutAppointments.cancel(id: missed.id, expectedRevision: missed.revision) { reconcileWorkoutAppointments() }
        }))
    }

    private func openScheduledWorkout(_ reference: ScheduledWorkoutReference, _ id: UUID) {
        invalidateRootShareRoutes()
        guard let appointment = workoutAppointments.appointment(id: id),
              appointment.status == .scheduled, appointment.reference == reference else { return }
        pendingScheduledReview = appointment
        photoShareAuthority.revokeAll(before: .hostDismissal)
        showsProfile = false
    }

    private func scheduledSession(for reference: ScheduledWorkoutReference,
                                  warmUpLengthOverride: WorkoutWarmUpLength? = nil) -> WorkoutSession? {
        switch reference {
        case let .programme(id, sessionID):
            guard let base = programmeCoordinator.programmes.first(where: { $0.id == id }),
                  let programme = try? programmeVolume.effective(base),
                  programme.sessions.contains(where: { $0.id == sessionID }) else { return nil }
            return programme.makeSession(sessionID: sessionID, previousHistory: progressionHistory,
                                         loadChoices: workoutLoadChoices.choices,
                                         progressionAllowed: progressionAdviceAllowed,
                                         progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : [])
        case let .custom(id):
            guard customWorkouts.isAvailable,
                  let workout = customWorkouts.workouts.first(where: { $0.id == id }) else { return nil }
            return workout.makeSession(previousHistory: progressionHistory,
                                       warmUpLengthOverride: warmUpLengthOverride,
                                       loadChoices: workoutLoadChoices.choices,
                                       progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : [],
                                       progressionAllowed: progressionAdviceAllowed)
        }
    }

    /// Final planning uses fresh acknowledgements. An unreadable source removes
    /// automatic increases; it does not fabricate replacement history.
    @discardableResult private func refreshProgressionForStart() -> Bool {
        let historyAvailable = (try? workoutHistory.confirmedEntries()) != nil
        let reviewsAvailable = workoutProgression.reviews.reload()
        let choicesAvailable = workoutLoadChoices.reload()
        programmeVolume.reload()
        wellbeing.reload()
        dailyGoals.reload()
        hydrationViewModel.refreshForCurrentDay()
        let foodAvailable = (try? nutritionRepository.readForImport()) != nil
        let outdoorAvailable = wellbeingOutdoorEvidence.confirmsCurrentRecords(using: outdoorActivityRepository)
        return outdoorAvailable && historyAvailable && reviewsAvailable && choicesAvailable && wellbeing.isAvailable
            && dailyGoals.isAvailable && foodAvailable
    }

    private var progressionHistory: [WorkoutHistoryEntry] {
        workoutHistory.availability == .available ? workoutHistory.entries : []
    }

    private var progressionInputsAvailable: Bool {
        workoutHistory.availability == .available && workoutProgression.reviews.isAvailable
            && workoutLoadChoices.isAvailable && wellbeing.isAvailable && dailyGoals.isAvailable
            && nutritionRepository.availability == .available && wellbeingOutdoorEvidence.records != nil
    }

    private var progressionAdviceAllowed: Bool {
        progressionInputsAvailable && !wellbeingAssessment.holdsAutomaticProgression
    }

    private func startScheduledWorkout(_ reviewed: WorkoutAppointment, warmUpLength: WorkoutWarmUpLength) {
        invalidateRootShareRoutes()
        guard outdoorActivity.isLoaded, !outdoorActivity.hasUnfinishedSession else {
            scheduledWorkoutMessage = "Finish or resume your outdoor activity before starting this workout."
            return
        }
        if resumePendingCompletion() { return }
        do {
            if try restoreExistingWorkout() {
                reconcileWorkoutAppointments()
                scheduledWorkoutMessage = "Your saved workout has been reopened. Finish or exit it before starting another."
                return
            }
        } catch {
            showsWorkoutRecoveryError = true
            return
        }
        guard !programmeCoordinator.route.isActive, !showsWorkoutRecoveryError else {
            scheduledWorkoutMessage = "Finish or exit your current workout first."
            return
        }
        workoutAppointments.reload()
        guard workoutAppointments.isAvailable,
              let current = workoutAppointments.appointment(id: reviewed.id),
              current.status == .scheduled, current.revision == reviewed.revision,
              current.reference == reviewed.reference else {
            scheduledWorkoutMessage = "The appointment changed. Review it in your schedule before starting."
            return
        }
        if current.preparedSessionID != nil || current.startedSessionID != nil {
            orphanScheduledLaunch = current
            return
        }
        refreshProgressionForStart()
        if case .programme = current.reference, !programmeVolume.isAvailable {
            scheduledWorkoutMessage = "The saved programme sets could not be verified. Open the programme to retry or review its adjustment before starting."
            return
        }
        guard var session = scheduledSession(for: current.reference, warmUpLengthOverride: warmUpLength) else {
            scheduledWorkoutMessage = "This exact workout is no longer available. Edit the appointment to choose another."
            return
        }
        session.selectWarmUpLength(warmUpLength, at: .now)
        guard workoutAppointments.prepareSessionLaunch(appointmentID: current.id,
            reference: current.reference, sessionID: session.id) else {
            scheduledWorkoutMessage = "The scheduled start wasn't saved. Retry schedule recovery before starting."
            return
        }
        if let programmeID = session.programmeID { programmeCoordinator.restoreActiveProgramme(programmeID) }
        else if let customID = session.customWorkoutID { programmeCoordinator.restoreActiveCustomWorkout(customID) }
        workoutViewModel.invalidateElapsedEvidence()
        workoutViewModel = WorkoutViewModel(session: session, requiresFinalSetReview: true,
            acceptedStart: WorkoutElapsedClock.continuous.read(),
            onSnapshotChanged: { snapshot, sessionID in
                if let snapshot { try activeWorkoutStore.save(snapshot) }
                else { try activeWorkoutStore.clear(expectedSessionID: sessionID) }
            }, onSessionCompleted: workoutHistory.record,
            progressionValidator: { [workoutProgression] plan, opportunity in
                workoutProgression.validate(plan: plan, opportunity: opportunity)
            },
            shareRevocationRegistration: shareCoordinator?.registration
        )
        selectedTab = .workout
        if workoutViewModel.persistenceErrorMessage == nil {
            workoutMusic.prepareForWorkout(sessionID: session.id, preservingReadySelection: true)
            _ = workoutAppointments.bindStartedSession(appointmentID: current.id,
                reference: current.reference, sessionID: session.id)
            mainActionStore.recordUse(.workout)
        }
    }

    private func configureLocalImportsIfNeeded() {
        // Install once after State is mounted. The callback reads current app state
        // and the persisted recovery store again on every review and confirmation.
        if workoutHistoryImport == nil {
            let coordinator = WorkoutHistoryImportCoordinator(store: workoutHistoryImportStore) { [self] in
                try canImportLocalRecords()
            }
            coordinator.installShareRevocationRegistration(shareCoordinator?.registration)
            workoutHistoryImport = coordinator
        }
        if mealRecordImport == nil {
            mealRecordImport = FoodBodyWeightImportCoordinator(category: .meals,
                nutrition: nutritionRepository, bodyWeight: bodyWeight) { [self] in
                try canImportLocalRecords()
            }
        }
        if bodyWeightRecordImport == nil {
            bodyWeightRecordImport = FoodBodyWeightImportCoordinator(category: .bodyWeight,
                nutrition: nutritionRepository, bodyWeight: bodyWeight) { [self] in
                try canImportLocalRecords()
            }
        }
        if outdoorHistoryTransfer == nil {
            let coordinator = OutdoorHistoryTransferCoordinator(repository: outdoorActivityRepository) { [self] in
                try canImportLocalRecords()
            }
            coordinator.installShareRevocationRegistration(shareCoordinator?.registration)
            outdoorHistoryTransfer = coordinator
        }
    }

    private struct SavedWorkoutShareRoute: Identifiable {
        let presentation: ZeroOneRootSharePresentation
        var id: UUID { presentation.id }
        let entry: WorkoutHistoryEntry
        let acknowledgedHistory: [WorkoutHistoryEntry]
    }

    /// Bind the visible saved finish to fresh persistence before presenting.
    /// A dismissed finish or newly started workout cannot open a stale sheet.
    private func openSavedWorkoutShare(_ sessionID: UUID) async {
        guard !isPreparingSavedShare, savedWorkoutShare == nil, selectedTab == .workout,
              programmeCoordinator.route.isActive,
              workoutViewModel.session.id == sessionID,
              workoutViewModel.isCompletionSaved else { return }
        guard let coordinator = shareCoordinator, let request = coordinator.beginRequest() else { return }
        let preparationID = UUID()
        savedSharePreparationGeneration = preparationID
        isPreparingSavedShare = true
        defer {
            if savedSharePreparationGeneration == preparationID { isPreparingSavedShare = false }
        }
        let generation = savedSharePreparationGeneration
        let acknowledgedHistory: [WorkoutHistoryEntry]
        do {
            acknowledgedHistory = try workoutHistory.confirmedEntries()
        } catch {
            showsSavedShareUnavailable = true
            return
        }
        let matches = acknowledgedHistory.filter { $0.id == sessionID }
        guard matches.count == 1, let entry = matches.first else {
            showsSavedShareUnavailable = true
            return
        }
        let allowed = await canExportSavedWorkout(entry, acknowledgedHistory: acknowledgedHistory)
        guard coordinator.isCurrent(request), !Task.isCancelled, generation == savedSharePreparationGeneration,
              selectedTab == .workout, programmeCoordinator.route.isActive,
              workoutViewModel.session.id == sessionID,
              workoutViewModel.isCompletionSaved else { return }
        guard allowed else {
            showsSavedShareUnavailable = true
            return
        }
        guard coordinator.isCurrent(request),
              let presentation = await coordinator.prepareWorkout(entry,
                acknowledgedHistory: acknowledgedHistory, request: request) else {
            if coordinator.isCurrent(request) { showsSavedShareUnavailable = true }
            return
        }
        guard coordinator.isCurrent(request), !Task.isCancelled,
              generation == savedSharePreparationGeneration, selectedTab == .workout,
              programmeCoordinator.route.isActive, workoutViewModel.session.id == sessionID,
              workoutViewModel.isCompletionSaved, savedWorkoutShare == nil else {
            coordinator.close(presentation)
            return
        }
        savedWorkoutSharePresentationEpoch = presentation.id
        savedWorkoutShare = SavedWorkoutShareRoute(presentation: presentation,
            entry: entry, acknowledgedHistory: acknowledgedHistory)
    }

    /// Resolve the exact visible History record, never a replacement with the same ID.
    /// Full acknowledged history remains bound through preparation and every export.
    private func resolveSavedHistoryShare(
        _ expected: WorkoutHistoryEntry, authorityGeneration: UUID
    ) async -> SavedWorkoutHistoryShareSnapshot? {
        guard showsProfile, !Task.isCancelled, let coordinator = shareCoordinator,
              let request = coordinator.beginRequest() else { return nil }
        let acknowledgedHistory: [WorkoutHistoryEntry]
        do { acknowledgedHistory = try workoutHistory.confirmedEntries() }
        catch { return nil }
        guard acknowledgedHistory.filter({ $0.id == expected.id }) == [expected] else { return nil }
        let allowed = await canExportSavedWorkout(expected, acknowledgedHistory: acknowledgedHistory)
        guard allowed, coordinator.isCurrent(request), !Task.isCancelled, showsProfile else { return nil }
        return SavedWorkoutHistoryShareSnapshot(entry: expected, acknowledgedHistory: acknowledgedHistory,
                                             authorityGeneration: authorityGeneration)
    }

    /// A finished, acknowledged workout may open its sharing sheet before
    /// leaving the finish screen. Unfinished or unreadable recovery stays held.
    private func canExportSavedRecords() throws -> Bool {
        guard outdoorActivity.canShareSavedRecords,
              !showsWorkoutRecoveryError,
              workoutViewModel.persistenceErrorMessage == nil,
              workoutHistoryImport?.needsReconciliation != true,
              outdoorHistoryTransfer?.isBusy != true,
              outdoorHistoryTransfer?.needsReconciliation != true else { return false }
        if programmeCoordinator.route.isActive && !workoutViewModel.isCompletionSaved { return false }
        return try activeWorkoutStore.load() == nil
    }

    private func canExportSavedWorkout(
        _ expected: WorkoutHistoryEntry, acknowledgedHistory: [WorkoutHistoryEntry]
    ) async -> Bool {
        guard acknowledgedHistory.filter({ $0.id == expected.id }) == [expected],
              let coordinator = shareCoordinator, let request = coordinator.beginRequest(),
              let generation = coordinator.parent?.registry.currentGeneration else { return false }
        let stillCurrent: @MainActor () -> Bool = {
            coordinator.isCurrent(request) && coordinator.parent?.registry.currentGeneration == generation
        }
        let allowed = await SavedShareExportAuthority.verify(expected: acknowledgedHistory,
            readCurrentRecords: {
                guard stillCurrent(), try await outdoorActivityRepository.loadCheckpoint() == nil,
                      stillCurrent() else { throw WorkoutPersistenceError.conflictingSession }
                let current = try workoutHistory.confirmedEntries()
                guard stillCurrent() else { throw WorkoutPersistenceError.conflictingSession }
                return current
            }, isReady: {
                guard stillCurrent(), try canExportSavedRecords() else { return false }
                let matches = try workoutHistory.confirmedEntries() == acknowledgedHistory
                return matches && stillCurrent()
            })
        return allowed && stillCurrent()
    }

    private func canExportSavedOutdoor(_ expected: OutdoorActivityRecord) async -> Bool {
        guard let coordinator = shareCoordinator, let request = coordinator.beginRequest(),
              let generation = coordinator.parent?.registry.currentGeneration else { return false }
        let stillCurrent: @MainActor () -> Bool = {
            coordinator.isCurrent(request) && coordinator.parent?.registry.currentGeneration == generation
        }
        var observedSource: OutdoorRecommendationObservation.Source?
        let allowed = await SavedShareExportAuthority.verify(expected: [expected], readCurrentRecords: {
            guard stillCurrent(), try await outdoorActivityRepository.loadCheckpoint() == nil,
                  stillCurrent() else { throw OutdoorActivityPersistenceError.invalidCheckpoint }
            let observation = try await outdoorActivityRepository.loadRecommendationObservation()
            guard stillCurrent() else { throw OutdoorActivityPersistenceError.invalidCheckpoint }
            observedSource = observation.source
            return observation.records.filter { $0.id == expected.id }
        }, isReady: {
            guard stillCurrent(), try canExportSavedRecords() else { return false }
            // Strict saved bytes must still match after the actor read.
            return (observedSource.map(outdoorActivityRepository.confirmsRecommendationSource) ?? false)
                && stillCurrent()
        })
        return allowed && stillCurrent()
    }

    private func canImportLocalRecords() throws -> Bool {
        guard outdoorActivity.isLoaded, !outdoorActivity.hasUnfinishedSession,
              !showsWorkoutRecoveryError,
              !(workoutViewModel.session.isComplete && !workoutViewModel.isCompletionSaved) else { return false }
        switch programmeCoordinator.route {
        case .active, .customActive: return false
        case .library, .detail: break
        }
        return try activeWorkoutStore.load() == nil
    }

    private func refreshImportedWorkoutHistory(_ confirmed: [WorkoutHistoryEntry]) throws {
        guard try workoutHistory.confirmedEntries() == confirmed else {
            throw WorkoutHistoryImportError.historyChanged
        }
        reconcileWorkoutAppointments()
    }

    private func reconcileWorkoutAppointments() {
        workoutAppointments.reload()
        guard workoutAppointments.isAvailable else { return }
        do {
            if let snapshot = try activeWorkoutStore.load() {
                _ = workoutAppointments.acknowledgePreparedSessionIfActive(sessionID: snapshot.session.id)
            }
            for entry in try workoutHistory.confirmedEntries() {
                _ = workoutAppointments.associateAcknowledgedCompletionForSession(sessionID: entry.id)
            }
        } catch { /* Unreadable records never establish appointment completion or abandonment. */ }
    }

    private func clearOrphanScheduledLaunch() {
        invalidateRootShareRoutes()
        defer { orphanScheduledLaunch = nil }
        guard let appointment = orphanScheduledLaunch,
              let sessionID = appointment.preparedSessionID ?? appointment.startedSessionID else { return }
        do {
            let acknowledgedHistory = try workoutHistory.confirmedEntries()
            guard try activeWorkoutStore.load()?.session.id != sessionID,
                  !acknowledgedHistory.contains(where: { $0.id == sessionID }) else {
                reconcileWorkoutAppointments()
                return
            }
            workoutAppointments.reload()
            if appointment.preparedSessionID != nil {
                _ = workoutAppointments.clearPreparedSession(appointmentID: appointment.id, sessionID: sessionID)
            } else {
                _ = workoutAppointments.releaseAcknowledgedAbandonedSession(sessionID: sessionID)
            }
        } catch {
            scheduledWorkoutMessage = "Recovery couldn't confirm your saved records. The pending start was preserved."
        }
    }

    private func exitActiveWorkout() {
        invalidateRootShareRoutes()
        guard workoutViewModel.clearSnapshotForExit() else { return }
        if !workoutHistory.entries.contains(where: { $0.id == workoutViewModel.session.id }) {
            _ = workoutAppointments.releaseAcknowledgedAbandonedSession(sessionID: workoutViewModel.session.id)
        }
        if let programmeID = workoutViewModel.session.programmeID {
            showWorkoutDetail( programmeID)
        } else {
            showWorkoutLibrary()
        }
    }

    private var profileAccess: some View {
        ZeroOneProfileButton {
            showsProfile = true
        }
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.top, 4)
    }

    private var activeTheme: ZeroOneThemeTokens {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_DESIGN_THEME"],
           let preference = DesignThemePreference(rawValue: raw) {
            return ZeroOneThemeTokens.resolve(appearance: selectedAppearance, systemColorScheme: systemColorScheme,
                designTheme: preference.designTheme, accent: AccentPreference.storedValue(selectedAccentRawValue))
        }
        if let reviewThemeRawValue = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_THEME"],
           let reviewTheme = ZeroOneThemeID(rawValue: reviewThemeRawValue) {
            return ZeroOneThemeTokens.resolve(
                reviewTheme,
                appearance: selectedAppearance,
                systemColorScheme: systemColorScheme, accent: AccentPreference.storedValue(selectedAccentRawValue)
            )
        }
        #endif

        return ZeroOneThemeTokens.resolve(
            appearance: selectedAppearance,
            systemColorScheme: systemColorScheme,
            designTheme: DesignThemePreference.storedValue(selectedDesignThemeRawValue).designTheme,
            accent: AccentPreference.storedValue(selectedAccentRawValue)
        )
    }

    private var showsTabBar: Bool {
        selectedTab != .workout || !programmeCoordinator.route.isActive
    }

    private func openWidgetDestination(_ route: DailyWidgetRoute) {
        invalidateRootShareRoutes()
        savedSharePreparationGeneration = UUID()
        let awaitsDismissal = showsProfile || showsAssistantActions || showsSteps
            || showsWorkoutMusic || showsOutdoorActivity || showsOutdoorKindChoice || savedWorkoutShare != nil
        pendingWidgetRoute = route
        savedWorkoutShare?.presentation.invalidate()
        savedWorkoutShare = nil
        showsMainActions = false
        pendingOutdoorKind = nil
        showsOutdoorKindChoice = false
        showsOutdoorConflict = false
        if showsAssistantActions { voiceAssistant?.reset() }
        photoShareAuthority.revokeAll(before: .hostDismissal)
        showsProfile = false
        showsAssistantActions = false
        showsSteps = false
        showsWorkoutMusic = false
        showsOutdoorActivity = false
        // Modal destinations must wait for the existing presentation to finish
        // dismissing. No arbitrary delay, and no workout/recording is ended here.
        if !awaitsDismissal { completePendingWidgetRoute() }
    }

    private func completePendingWidgetRoute() {
        guard let route = pendingWidgetRoute else { return }
        pendingWidgetRoute = nil
        // Open only. A URL cannot save water or request location/start recording.
        switch route {
        case .today: selectedTab = .today
        case .steps: showsSteps = true
        case .calories: selectedTab = .diets
        case .water:
            focusHydrationInDiets = true
            selectedTab = .diets
        case .walk: openOutdoorActivity(.walk)
        }
    }

    private var outdoorKindChooser: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose an activity. Recording starts on the next screen.")
                        .foregroundStyle(activeTheme.textSecondary)
                    ForEach([OutdoorActivityKind.walk, .run], id: \.rawValue) { kind in
                        Button(kind == .walk ? "Walk" : "Run") {
                            pendingOutdoorKind = kind
                            showsOutdoorKindChoice = false
                        }
                        .buttonStyle(ZOButtonStyle(.primary))
                    }
                }
                .padding(24)
            }
            .background(activeTheme.surfacePrimary)
            .navigationTitle("Walk or run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsOutdoorKindChoice = false }
                }
            }
            .toolbarBackground(activeTheme.surfacePrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(activeTheme.colorScheme, for: .navigationBar)
        }
        .zoSheet()
        .zeroOneTheme(activeTheme)
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
        .presentationBackground(activeTheme.surfacePrimary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func openOutdoorActivity(_ kind: OutdoorActivityKind) {
        invalidateRootShareRoutes()
        guard !programmeCoordinator.route.isActive, !showsWorkoutRecoveryError else {
            outdoorConflictIsStrength = true
            showsOutdoorConflict = true
            return
        }
        outdoorActivity.open(kind)
        showsOutdoorActivity = true
    }

    private var liveActivityProjection: WorkoutActivityProjection? {
        guard !showsWorkoutRecoveryError, programmeCoordinator.route.isActive else { return nil }
        return workoutViewModel.persistedActivity?
            .usingConfirmedElapsed(from: workoutViewModel)
            .usingAccent(AccentPreference.storedValue(selectedAccentRawValue))
            .usingLanguage(localization.language)
            .usingDesignTheme(DesignThemePreference.storedValue(selectedDesignThemeRawValue).designTheme)
    }

    private var walkActivityProjection: WalkActivityProjection? {
        WalkActivityProjection.make(surface: outdoorActivity.surface, checkpoint: outdoorActivity.checkpoint,
            withoutGPS: outdoorActivity.isRecordingWithoutGPS,
            accent: AccentPreference.storedValue(selectedAccentRawValue), language: localization.language,
            theme: DesignThemePreference.storedValue(selectedDesignThemeRawValue).designTheme)
    }

    private var notificationWorkoutActive: Bool {
        programmeCoordinator.route.isActive || showsWorkoutRecoveryError
            || outdoorActivity.hasUnfinishedSession
    }

    private func reconcileProgressNoteCandidates() async {
        let now = Date()
        let programmeID = programmeCoordinator.selectedProgrammeID?.rawValue
        let retained = smartNotes.snapshot.candidates.filter { note in
            guard note.kind == .progress else { return true }
            guard !wellbeingAssessment.holdsAutomaticProgression else { return false }
            guard note.isCurrent, note.expiresAt > now,
                  note.programmeID == programmeID,
                  let rawSessionID = note.sessionID,
                  let sessionID = UUID(uuidString: rawSessionID) else { return false }
            return !workoutLoadChoices.choices.contains { $0.sourceSessionID == sessionID }
        }
        guard retained.count != smartNotes.snapshot.candidates.count else { return }
        await smartNotes.replaceCandidates(retained, workoutActive: notificationWorkoutActive)
    }

    /// Training-day reminders from the confirmed schedule and the programme's
    /// next session. Only this generator's candidates are replaced; an unreadable
    /// History or schedule builds none rather than guessing.
    private func reconcileTrainingDayReminders() async {
        let now = Date()
        var fresh: [SmartNoteCandidate] = []
        if let programme = programmeCoordinator.selectedProgramme,
           let schedule = programmeCoordinator.activeSchedule, schedule.isValid(for: programme),
           programmeCoordinator.scheduleIsAvailable,
           workoutHistory.availability == .available {
            let session = programme.makeSession(previousHistory: workoutHistory.entries, progressionAllowed: false)
            fresh = TrainingDayReminders.candidates(
                trainingWeekdays: schedule.weekdays,
                programmeID: programme.id.rawValue,
                sessionTitle: session.title,
                estimatedMinutes: WorkoutTimeEstimator().estimate(for: session)?.maximumMinutes,
                reminderMinute: smartNotes.preferences.trainingReminderMinute,
                lastCompletedAt: workoutHistory.entries.first?.completedAt,
                now: now, calendar: .current)
        }
        let merged = TrainingDayReminders.merged(smartNotes.snapshot.candidates, with: fresh)
        guard merged != smartNotes.snapshot.candidates else { return }
        await smartNotes.replaceCandidates(merged, workoutActive: notificationWorkoutActive)
    }

    private var todayWorkoutState: TodayWorkoutState {
        return TodayWorkoutStateDeriver().state(
            for: workoutViewModel.session,
            history: workoutHistory,
            activeSession: programmeCoordinator.route.isActive
        )
    }

    private var assistantActionContext: AssistantActionContext {
        AssistantActionContext(
            workout: assistantWorkoutContext,
            hydrationIsAvailable: hydrationViewModel.isPersistenceAvailable
        )
    }

    private var assistantContext: AssistantContext {
        let profile = userProfile.profile
        let workout: AssistantWorkoutState
        if programmeCoordinator.route.isActive {
            workout = .inProgress(
                title: workoutViewModel.session.title,
                canAdaptToThirtyMinutes: assistantWorkoutContext == .activeEligible
            )
        } else {
            workout = .none
        }

        let today: AssistantTodayState
        switch todayWorkoutState {
        case .ready:
            today = todayProgrammeVolumeUnavailable ? .noWorkoutReady : .ready(
                workoutTitle: nextSavedPlanWorkout?.name
                    ?? programmeCoordinator.scheduledProgramme?.title
                    ?? WorkoutProgrammeLibrary.programme(id: WorkoutProgrammeLibrary.recommendedID)?.title
                    ?? workoutViewModel.session.title
            )
        case let .completed(item):
            today = .completed(workoutTitle: item.title)
        case .unavailable:
            today = .noWorkoutReady
        }

        return AssistantContext(
            profile: AssistantProfileContext(
                trainingGoal: profile.selectedTrainingGoals.isEmpty ? nil : profile.selectedTrainingGoals.map(\.title).joined(separator: ", "),
                trainingExperience: profile.trainingExperience?.title,
                weeklyAvailability: profile.trainingDaysDescription,
                equipmentAccess: profile.equipmentDescription,
                trainingConstraint: profile.trainingConstraint?.title
            ),
            workout: workout,
            today: today,
            hydration: AssistantHydrationContext(
                consumedMilliliters: hydrationViewModel.state.currentMilliliters,
                goalMilliliters: hydrationViewModel.state.goalMilliliters,
                isAvailable: hydrationViewModel.isPersistenceAvailable
            ),
            nutrition: AssistantNutritionContext(
                entryCountToday: nutritionRepository.entries().count,
                isAvailable: nutritionRepository.availability == .available
            ),
            health: AssistantHealthContextAvailability(
                isConnected: healthConnection.status == .connected,
                hasLocalContext: healthConnection.context != nil
            ),
            wellbeing: wellbeingAssessment
        )
    }

    private var wellbeingAssessment: WellbeingAssessment {
        WellbeingAssessmentSource.assess(history: workoutHistory, recovery: wellbeing,
            nutrition: nutritionRepository, goals: dailyGoals, water: hydrationViewModel,
            health: healthConnection, outdoor: wellbeingOutdoorEvidence)
    }

    @MainActor
    private func refreshWellbeingOutdoorHistory() async {
        await wellbeingOutdoorEvidence.refresh(using: outdoorActivityRepository)
    }

    private var assistantWorkoutContext: AssistantWorkoutContext {
        guard selectedTab == .workout, programmeCoordinator.route.isActive else {
            return .inactive
        }
        if workoutViewModel.session.isComplete {
            return .activeIneligible("This workout is already complete. Choose another session when ready.")
        }
        if workoutViewModel.pendingAdaptation != nil {
            return .activeIneligible("A 30-minute proposal is already ready to review.")
        }
        if workoutViewModel.session.isAdapted {
            return .activeIneligible("The 30-minute version is already active.")
        }
        if workoutViewModel.session.completedSetCount > 0 {
            return .activeIneligible("This workout has started, so its structure cannot be shortened now.")
        }
        return .activeEligible
    }

    private func handleAssistantAction(_ action: AssistantActionID) {
        if action == .shortenWorkout { dailyContext.setAvailableWorkoutMinutes(30) }
        if action == .reviewWellbeing {
            voiceAssistant?.reset()
            showsAssistantActions = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(240))
                showsWellbeingReview = true
            }
            return
        }
        let resolution = assistantActionPolicy.resolution(
            for: action,
            context: assistantActionContext
        )
        voiceAssistant?.reset()
        showsAssistantActions = false

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            executeAssistantResolution(resolution)
        }
    }

    private func publishDailyWidgetSnapshot(_ inputs: DailyWidgetInputs) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              !environment.keys.contains(where: { $0.hasPrefix("ZERO_ONE_") && $0.contains("REVIEW") }) else { return }
        #endif
        dailyWidgetPublisher.publish(inputs.snapshot(at: .now))
    }

    private var dailyWidgetInputs: DailyWidgetInputs {
        DailyWidgetInputs(
            steps: stepsDay.reading, stepsStatus: stepsDay.status, stepsFailed: stepsDay.issue != nil,
            health: healthConnection.context, healthStatus: healthConnection.status,
            healthIsStale: healthConnection.isContextStale,
            meals: nutritionRepository.entries, nutritionAvailable: nutritionRepository.availability == .available,
            water: hydrationViewModel.state, waterDayStart: hydrationViewModel.stateDayStart,
            hydrationAvailable: hydrationViewModel.isPersistenceAvailable,
            latestWalk: outdoorActivity.latestSavedWalk?.usingMiles(
                (userProfile.profile.preferredDistanceUnit ?? ZeroOneOnboardingUnitDefaults.distance(for: .current)) == .miles
            ),
            goals: dailyGoals.isAvailable ? dailyGoals.value : nil,
            accent: AccentPreference.storedValue(selectedAccentRawValue),
            designTheme: DesignThemePreference.storedValue(selectedDesignThemeRawValue).designTheme
        ).usingLanguage(localization.language)
    }

    private func executeAssistantResolution(_ resolution: AssistantActionResolution) {
        switch resolution {
        case let .proposeThirtyMinuteWorkout(feedback):
            workoutViewModel.proposeThirtyMinuteAdaptation()
            presentAssistantFeedback(feedback)
        case let .addWater(milliliters, feedback):
            if hydrationViewModel.addWaterFromQuickAction(milliliters: milliliters) != nil {
                presentAssistantFeedback(feedback)
            } else {
                let message = "Water wasn't saved. Please try again."
                presentAssistantFeedback(AssistantActionFeedback(
                    message: message,
                    kind: .unavailable,
                    accessibilityAnnouncement: message
                ))
            }
        case let .route(route, feedback):
            applyAssistantRoute(route)
            presentAssistantFeedback(feedback)
        case let .unsupported(feedback, usefulRoute):
            if let usefulRoute {
                applyAssistantRoute(usefulRoute)
            }
            presentAssistantFeedback(feedback)
        }
    }

    private func applyAssistantRoute(_ route: AssistantActionRoute) {
        invalidateRootShareRoutes()
        switch route {
        case .workoutLibrary:
            if resumePendingCompletion() { return }
            showWorkoutLibrary()
            selectedTab = .workout
        case .recommendedWorkout:
            openRecommendedProgramme()
        case .nutrition:
            selectedTab = .diets
        case .currentWorkout:
            break
        }
    }

    private struct QuickWaterToast {
        let id = UUID()
        let message: String
        var group: HydrationQuickLogGroup? = nil
        var undoUnconfirmed = false
    }

    @ViewBuilder
    private var quickWaterToastContent: some View {
        if let toast = quickWaterToast, !showsMainActions, showsTabBar {
            if let group = toast.group {
                ZOToast(message: toast.message, actionTitle: "Undo") { undoQuickWaterToast(group, id: toast.id) }
                    .transition(quickWaterToastTransition)
            } else if toast.undoUnconfirmed {
                ZOToast(message: toast.message, actionTitle: "Review") {
                    quickWaterToastTask?.cancel()
                    quickWaterToast = nil
                    focusHydrationInDiets = true
                    selectedTab = .diets
                }
                .transition(quickWaterToastTransition)
            } else {
                ZOToast(message: toast.message)
                    .transition(quickWaterToastTransition)
            }
        }
    }

    private var quickWaterToastTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }

    private func showQuickWaterToast(_ group: HydrationQuickLogGroup) {
        var combined = quickWaterToast?.group
        for receipt in group.receipts {
            combined = combined?.appending(receipt) ?? HydrationQuickLogGroup(receipt)
        }
        guard let combined else { return }
        presentQuickWaterToast(QuickWaterToast(message: "Water added", group: combined),
            announcement: "\(combined.addedMilliliters) milliliters of water added. Undo is available.")
    }

    private func undoQuickWaterToast(_ group: HydrationQuickLogGroup, id: UUID) {
        guard quickWaterToast?.id == id, quickWaterToast?.group == group else { return }
        quickWaterToastTask?.cancel()
        quickWaterToast = nil
        if hydrationViewModel.undoQuickWaterLog(group) {
            presentQuickWaterToast(QuickWaterToast(message: "Water undone"),
                announcement: "\(group.addedMilliliters) milliliters of water undone.")
        } else {
            presentQuickWaterToast(QuickWaterToast(message: "Undo unconfirmed", undoUnconfirmed: true),
                announcement: "Undo could not be confirmed. Review your water total.")
        }
    }

    private func presentQuickWaterToast(_ toast: QuickWaterToast, announcement: String) {
        quickWaterToastTask?.cancel()
        withAnimation(reduceMotion ? nil : ZOMotion.land(ZOMotion.quick)) {
            quickWaterToast = toast
        }
        AccessibilityNotification.Announcement(announcement).post()
        quickWaterToastTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, quickWaterToast?.id == toast.id else { return }
            withAnimation(reduceMotion ? nil : ZOMotion.leave(ZOMotion.quick)) {
                quickWaterToast = nil
            }
        }
    }

    private func presentAssistantFeedback(_ feedback: AssistantActionFeedback) {
        assistantFeedbackTask?.cancel()
        withAnimation(ZeroOneMotion.fast) {
            assistantFeedback = feedback
        }
        if let announcement = feedback.accessibilityAnnouncement {
            AccessibilityNotification.Announcement(announcement).post()
        }
        assistantFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(ZeroOneMotion.fast) {
                assistantFeedback = nil
            }
        }
    }

    private func destinationState(for destination: AppTab) -> ZeroOneDestinationState {
        #if DEBUG
        if destination == Self.reviewTab,
           let rawValue = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_DESTINATION_STATE"],
           let reviewState = ZeroOneDestinationState(rawValue: rawValue.lowercased()) {
            return reviewState
        }
        #endif

        return demoState.state(for: destination)
    }

    private var selectedAppearance: AppearancePreference {
        #if DEBUG
        if let reviewAppearance = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_APPEARANCE"],
           let preference = AppearancePreference(rawValue: reviewAppearance) {
            return preference
        }
        #endif
        return AppearancePreference.storedValue(selectedAppearanceRawValue)
    }

    private var isTodayWorkoutReady: Bool {
        guard !todayProgrammeVolumeUnavailable else { return false }
        if case .ready = todayWorkoutState { return true }
        return false
    }

    private var reviewInitialProfileDestination: ProfileDestination? {
        switch Self.reviewProfileRoute {
        case "history": return .history
        case "session": return workoutHistory.entries.first.map { .session($0.id) }
        case "baseline": return .baseline
        case "progress": return .progress
        case "body-weight": return .bodyWeight
        case "health": return .appleHealth
        case "account": return .account
        case "notifications": return .notifications
        case "progress-photos": return .progressPhotos
        default: return nil
        }
    }

    private var todayDisplaySession: WorkoutSession {
        if programmeCoordinator.route.isActive ||
            (workoutViewModel.session.isComplete &&
             workoutViewModel.session.completedAt.map { Calendar.current.isDateInToday($0) } == true) {
            return workoutViewModel.session
        }
        if let session = nextSavedPlanWorkout?.makeSession(previousHistory: progressionHistory,
            loadChoices: workoutLoadChoices.choices,
            progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : [],
            progressionAllowed: progressionAdviceAllowed) {
            return session
        }
        let programme = programmeCoordinator.scheduledProgramme
            ?? WorkoutProgrammeLibrary.programme(id: WorkoutProgrammeLibrary.recommendedID)
        return programme.flatMap { try? programmeVolume.effective($0) }?.makeSession(
            previousHistory: progressionHistory,
            loadChoices: workoutLoadChoices.choices,
            progressionAllowed: progressionAdviceAllowed,
            progressionReviews: workoutProgression.reviews.isAvailable ? workoutProgression.reviews.snapshot.reviews : []
        )
            ?? workoutViewModel.session
    }

    private var todayProgrammeVolumeUnavailable: Bool {
        guard !programmeCoordinator.route.isActive, nextSavedPlanWorkout == nil else { return false }
        guard let base = programmeCoordinator.scheduledProgramme
                ?? WorkoutProgrammeLibrary.programme(id: WorkoutProgrammeLibrary.recommendedID) else { return true }
        return (try? programmeVolume.effective(base)) == nil
    }

    private var nextSavedPlanWorkout: CustomWorkout? {
        guard let id = userProfile.profile.savedFirstWeekPlan?.nextWorkoutID(on: .now) else { return nil }
        return customWorkouts.workouts.first { $0.id == id }
    }

    private var nextSavedPlanTrainingLabel: String? {
        guard nextSavedPlanWorkout != nil,
              let day = userProfile.profile.savedFirstWeekPlan?.nextTrainingDay(on: .now) else { return nil }
        let weekday = (Calendar.current.component(.weekday, from: .now) + 5) % 7
        return weekday == day.rawValue ? "TODAY" : "NEXT \(day.shortTitle.uppercased())"
    }

    private var selectedAppearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { selectedAppearance },
            set: { selectedAppearanceRawValue = $0.rawValue }
        )
    }

    private static var reviewAssistantRequest: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_ASSISTANT_REQUEST"]
        #else
        nil
        #endif
    }


    private static var reviewAssistantRequestSource: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_ASSISTANT_REQUEST_SOURCE"]?.lowercased()
        #else
        nil
        #endif
    }

}

// Internal so tests can read the route state (9 Oct compile check).
extension WorkoutProgrammeRoute {
    var isActive: Bool {
        if case .active = self { return true }
        if case .customActive = self { return true }
        return false
    }
}

#if DEBUG
private struct ReviewUnavailableHydrationStore: HydrationPersisting {
    let isAvailable = false
    func load() -> HydrationStoredState? { nil }
    func save(_ state: HydrationStoredState) {}
}

private struct ReviewEmptyWorkoutHistoryStore: WorkoutHistoryPersisting {
    func load() -> [WorkoutHistoryEntry] { [] }
    func save(_ entries: [WorkoutHistoryEntry]) {}
}

private struct ReviewUnavailableWorkoutHistoryStore: WorkoutHistoryPersisting {
    let isAvailable = false

    func load() -> [WorkoutHistoryEntry] { [] }
    func save(_ entries: [WorkoutHistoryEntry]) {}
}

private final class ReviewNutritionStore: NutritionPersisting {
    private var entries: [NutritionEntry]

    init(entries: [NutritionEntry]) {
        self.entries = entries
    }

    func load() -> [NutritionEntry] {
        entries
    }

    func save(_ entries: [NutritionEntry]) {
        self.entries = entries
    }
}

private struct ReviewUnavailableNutritionStore: NutritionPersisting {
    let isAvailable = false

    func load() -> [NutritionEntry] { [] }
    func save(_ entries: [NutritionEntry]) {}
}

@MainActor
private final class ReviewHealthKitService: HealthKitServicing {
    let isHealthDataAvailable: Bool

    init(isAvailable: Bool) {
        isHealthDataAvailable = isAvailable
    }

    func requestAuthorization(for scope: HealthAuthorizationScope) async -> HealthAuthorizationOutcome {
        isHealthDataAvailable ? .completed : .unavailable
    }

    func readContext(at date: Date) async throws -> HealthContext {
        HealthContext(
            todaySteps: 7_842,
            todayActiveEnergyKilocalories: 486,
            mostRecentWorkout: HealthWorkoutContext(
                activityName: "Strength training",
                startedAt: date.addingTimeInterval(-7_200),
                durationSeconds: 3_180
            ),
            lastNightSleepDurationSeconds: 27_180,
            refreshedAt: date
        )
    }
}

private final class ReviewHealthPreferenceStore: HealthConnectionPreferencePersisting {
    private var value: Bool

    init(hasCompletedSetup: Bool) {
        value = hasCompletedSetup
    }

    var hasCompletedHealthSetup: Bool { value }

    func setHasCompletedHealthSetup(_ value: Bool) {
        self.value = value
    }
}
#endif

private struct ZeroOneTabBar: View {
    @Binding var selection: AppTab
    let onOpenMainActions: () -> Void
    let hasActivity: Bool
    let onHoldAssistant: () -> Void
    let actionStore: MainActionStore
    var isVoiceDockPresented = false
    var isVoiceHolding = false
    var onContinuousHold: ((MainActionHoldEvent) -> Void)? = nil
    var onHoldBoundsChange: ((CGRect) -> Void)? = nil
    var onVoiceAccessibilityToggle: (() -> Void)? = nil
    var voiceAccessibilityValue = ""
    var voiceVisualOffset: CGFloat = 0
    var voiceIsListening = false
    var voiceIsOverCancel = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        navigationContent
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .background(theme.backgroundPrimary)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
            }
    }

    private var navigationContent: some View {
        HStack(spacing: 0) {
            tabButton(.today)
            tabButton(.workout)
            MainActionControl(
                action: onOpenMainActions, size: 60, hasActivity: hasActivity,
                onHoldAssistant: onHoldAssistant, actionStore: actionStore,
                onContinuousHold: onContinuousHold, holdCoordinateSpace: "rootVoiceHold",
                onHoldBoundsChange: onHoldBoundsChange,
                onVoiceAccessibilityToggle: onVoiceAccessibilityToggle,
                voiceAccessibilityValue: voiceAccessibilityValue,
                continuousHoldEnabled: isVoiceDockPresented,
                voiceDockPresented: isVoiceDockPresented, voiceIsListening: voiceIsListening,
                voiceIsCapturing: isVoiceHolding, voiceIsOverCancel: voiceIsOverCancel,
                voiceVisualOffset: voiceVisualOffset
            )
                .frame(width: 64)
            tabButton(.social)
            tabButton(.diets)
        }
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: AppTab) -> some View {
        return Button {
            withAnimation(reduceMotion ? nil : ZeroOneMotion.quick) {
                selection = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .zoIcon(ZOIcon.bar)
                    .foregroundStyle(selection == tab ? theme.textPrimary : theme.textSecondary)
                Text(localization.string(tab.title))
                    .zoText(.mini)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selection == tab ? theme.textPrimary : theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVoiceHolding ? 0.16 : 1)
        .disabled(isVoiceDockPresented)
        .accessibilityHidden(isVoiceDockPresented)
        .accessibilityLabel(localization.string(tab.title))
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
