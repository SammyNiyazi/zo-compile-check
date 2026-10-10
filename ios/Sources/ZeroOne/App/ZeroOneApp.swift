import Foundation
import SwiftUI
import UserNotifications
import UIKit
import os

@main
struct ZeroOneApp: App {
    private let launchProcessState = ZeroOneLaunchProcessState()

    init() {
        ZeroOneFontRegistrar.registerBundledFonts()
        WhatsNewPolicy.captureLaunchState()
    }

    var body: some Scene {
        WindowGroup {
            ZeroOneLaunchRootView(processState: launchProcessState)
                .zeroOneLanguage()
        }
    }
}

final class ZeroOneLaunchProcessState {
    private(set) var hasPresented = false

    func markPresented() {
        hasPresented = true
    }
}

@MainActor
private struct ZeroOneLaunchRootView: View {
    #if DEBUG
    private static let launchLogger = Logger(subsystem: "app.the01.ios", category: "Launch")
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let launchRevealState: ZeroOneLaunchRevealState
    private let launchPresentation: ZeroOneLaunchPresentation
    private let processState: ZeroOneLaunchProcessState
    @State private var isShowingLaunchExperience: Bool
    @StateObject private var sharingLifetime: ZeroOneShareParentLifetime
    private var userProfile: ZeroOneUserProfileRepository { sharingLifetime.profile }
    private var account: ZeroOneAccountStore { sharingLifetime.account }
    @Environment(\.scenePhase) private var scenePhase

    init(
        processState: ZeroOneLaunchProcessState,
        launchRevealStore: any ZeroOneLaunchRevealPersisting = UserDefaultsZeroOneLaunchRevealStore(),
        userProfileStore: any ZeroOneUserProfilePersisting = UserDefaultsZeroOneUserProfileStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let launchRevealState = ZeroOneLaunchRevealState(store: launchRevealStore)

        #if DEBUG
        if ZeroOneLaunchDebugOptions.shouldResetFirstReveal(environment: environment) {
            launchRevealState.reset()
        }
        #endif

        self.launchRevealState = launchRevealState
        self.processState = processState
        launchPresentation = launchRevealState.presentation
        #if DEBUG
        _isShowingLaunchExperience = State(
            initialValue: !processState.hasPresented && environment["ZERO_ONE_REVIEW_SKIP_LAUNCH"] != "1"
        )
        #else
        _isShowingLaunchExperience = State(initialValue: !processState.hasPresented)
        #endif
        // StateObject evaluates this wrappedValue autoclosure only for the
        // mounted identity. Reconstruction must not reload/quarantine a second
        // profile or create a discarded account before choosing retained state.
        _sharingLifetime = StateObject(wrappedValue: Self.makeSharingLifetime(
            userProfileStore: userProfileStore, environment: environment
        ))
    }

    private static func makeSharingLifetime(
        userProfileStore: any ZeroOneUserProfilePersisting,
        environment: [String: String]
    ) -> ZeroOneShareParentLifetime {
        let userProfile = ZeroOneUserProfileRepository(store: userProfileStore)
        let lifetime = ZeroOneShareParentLifetime(
            account: ZeroOneAccountStore.live(), profile: userProfile,
            hasAuditedProfileStore: userProfileStore is UserDefaultsZeroOneUserProfileStore
        )
        #if DEBUG
        if environment["ZERO_ONE_REVIEW_PROFILE_COMPLETE"] == "1",
           userProfile.rootRoute != .appShell {
            userProfile.update {
                $0.trainingGoal = .buildStrength
                $0.trainingGoals = [.buildStrength]
                $0.trainingExperience = .someExperience
                $0.weeklyAvailability = .threeDays
                $0.equipmentAccess = .fullGym
                $0.trainingConstraint = .variableSchedule
            }
            userProfile.completeOnboarding()
        }
        #endif
        return lifetime
    }

    var body: some View {
        ZStack {
            switch userProfile.rootRoute {
            case .onboarding:
                ZeroOneOnboardingView(profileRepository: userProfile)
                    .environment(
                        \.zeroOneLaunchCoveringDestination,
                        isShowingLaunchExperience && launchPresentation == .firstReveal
                    )
                    .accessibilityHidden(isShowingLaunchExperience)
                    .allowsHitTesting(!isShowingLaunchExperience)
            case .appShell:
                AppRootView(userProfileRepository: userProfile, shareParent: sharingLifetime)
                    .accessibilityHidden(isShowingLaunchExperience)
                    .allowsHitTesting(!isShowingLaunchExperience)
            }
        }
        .overlayPreferenceValue(ZeroOneLaunchTargetKey.self) { targets in
            GeometryReader { geometry in
                if isShowingLaunchExperience {
                    ZeroOneLaunchExperienceView(
                        presentation: launchPresentation,
                        usesReducedMotion: reduceMotion,
                        containerSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets,
                        brandTarget: targets.brand.map { geometry[$0] },
                        actionTarget: targets.action.map { geometry[$0] },
                        brandComposition: targets.brandComposition,
                        actionCopy: targets.actionCopy,
                        destinationTheme: targets.actionTheme ?? targets.brandTheme,
                        destinationLocalization: targets.actionLocalization,
                        onFinished: finishLaunchExperience
                    )
                    .transition(.opacity)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(account)
        .task {
            sharingLifetime.registry.revokeAll()
            await account.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            sharingLifetime.registry.revokeAll()
            if phase == .active { Task { await account.restore() } }
        }
        .statusBarHidden(isShowingLaunchExperience)
        .onAppear {
            #if DEBUG
            if isShowingLaunchExperience {
                Self.launchLogger.notice("Launch overlay presented")
            } else {
                Self.launchLogger.notice("Launch overlay skipped")
            }
            #endif
            processState.markPresented()
        }
    }

    private func finishLaunchExperience() {
        let dissolveDuration = launchPresentation == .coldLaunch && !reduceMotion ? 0.18 : 0.12
        withAnimation(.easeOut(duration: dissolveDuration)) {
            isShowingLaunchExperience = false
        }
        Task {
            try? await Task.sleep(
                for: launchPresentation == .coldLaunch && !reduceMotion
                    ? .milliseconds(180)
                    : .milliseconds(120)
            )
            guard !Task.isCancelled else { return }
            // A killed app must replay the first reveal if Welcome never became interactive.
            launchRevealState.recordCompletedPresentation(launchPresentation)
        }
    }
}

enum ZeroOneOnboardingMode {
    case firstRun
    case editing
}

struct ZeroOneOnboardingView: View {
    private static var bundledMovementIDs: Set<String> { MoveKitExercise.availableVideoIDs }
    @Bindable var profileRepository: ZeroOneUserProfileRepository
    var mode: ZeroOneOnboardingMode = .firstRun

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.zeroOneLaunchCoveringDestination) private var launchCoversDestination
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.zeroOneTheme) private var inheritedTheme
    @Environment(\.zeroOneLocalization) private var localization
    @AppStorage(AppearancePreference.storageKey) private var selectedAppearanceRawValue = AppearancePreference.system.rawValue
    @AppStorage(AccentPreference.storageKey) private var selectedAccentRawValue = AccentPreference.yellow.rawValue
    @AppStorage(AppLanguagePreference.storageKey) private var selectedLanguageRawValue = AppLanguagePreference.system.rawValue
    @AppStorage(DesignThemePreference.storageKey) private var selectedDesignThemeRawValue = DesignThemePreference.core.rawValue
    @State private var step: Int
    @State private var showsMissingAnswer = false
    @State private var bodyHeightInput: String
    @State private var bodyHeightInputRevision = 0
    // Imperial entry fields. bodyHeightInput stays the single draft (decimal feet).
    @State private var heightFeetInput: String
    @State private var heightInchesInput: String
    @State private var didAttemptBodyFill = false
    @State private var bodyWeightInput: String
    @State private var bodyWeightInputRevision = 0
    @State private var bodyWeightError: String? = nil
    @State private var importedBodyWeight: ImportedBodyWeight? = nil
    @State private var healthWeightMessage: String? = nil
    @State private var isImportingBodyWeight = false
    @State private var setupHealth: HealthConnectionRepository?
    @State private var setupNotes: SmartNoteCenter?
    @State private var setupDailyGoals: DailyGoalsRepository?
    @State private var setupHydration: HydrationViewModel?
    @State private var showsSetupNotifications = false
    @State private var showsSetupHealth = false
    @State private var showsLogin = false
    @State private var showsSetupLanguage = false
    @State private var setupPermissionBusy = false
    @State private var didRequestSetupHealth = false
    @State private var customWorkouts: CustomWorkoutRepository
    @State private var bodyWeight: BodyWeightRepository
    @State private var planAlternative = 0
    @State private var planSaveError: String?
    @State private var welcomeError: String?
    @State private var isSavingPlan = false
    @State private var returnsToPlanAfterEdit = false
    @State private var navigationDirection = 1

    private let progressStore: any ZeroOneOnboardingProgressPersisting

    private let stepCount = 5

    init(
        profileRepository: ZeroOneUserProfileRepository,
        mode: ZeroOneOnboardingMode = .firstRun,
        progressStore: any ZeroOneOnboardingProgressPersisting = UserDefaultsZeroOneOnboardingProgressStore(),
        customWorkoutStore: any CustomWorkoutPersisting = UserDefaultsCustomWorkoutStore(),
        customWorkoutRepository: CustomWorkoutRepository? = nil,
        bodyWeightRepository: BodyWeightRepository? = nil
    ) {
        self.profileRepository = profileRepository
        self.mode = mode
        self.progressStore = progressStore
        let initialStep = mode == .firstRun ? (progressStore.loadStep() ?? -2) : 0
        _bodyWeightInput = State(initialValue: profileRepository.profile.startingBodyWeight.map { String($0) } ?? "")
        _bodyHeightInput = State(initialValue: profileRepository.profile.bodyHeight?.displayValue(
            imperial: (profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()) == .pounds) ?? "")
        let savedHeightParts = profileRepository.profile.bodyHeight?.feetAndInches
        _heightFeetInput = State(initialValue: savedHeightParts.map { String($0.feet) } ?? "")
        _heightInchesInput = State(initialValue: savedHeightParts.map { String($0.inches) } ?? "")
        // First run owns these repositories. Profile editing shares the app's
        // existing instances, so acknowledged saves reach Today/Library/Progress.
        _customWorkouts = State(initialValue: customWorkoutRepository
            ?? CustomWorkoutRepository(store: customWorkoutStore))
        _bodyWeight = State(initialValue: bodyWeightRepository ?? BodyWeightRepository())
        #if DEBUG
        let reviewStep = Int(ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_ONBOARDING_STEP"] ?? "")
        _step = State(initialValue: min(mode == .firstRun ? 9 : 6, max(mode == .firstRun ? -2 : 0, reviewStep ?? initialStep)))
        #else
        _step = State(initialValue: initialStep)
        #endif
    }

    var body: some View {
        Group {
            if step == -2 && mode == .firstRun {
                initialLanguage
            } else if step == -1 && mode == .firstRun {
                welcome
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ZeroOneSetupProgressHeader(progress: ZeroOneOnboardingFlow.progress(for: -1), onBack: nil)
                    }
            } else if mode == .firstRun && step == 7 {
                setupHealthStep
            } else if mode == .firstRun && step == 8 {
                setupDailyGoalsStep
            } else if mode == .firstRun && step == 9 {
                setupRemindersStep
            } else if step == 5 {
                ZeroOneOnboardingWalkthroughView(
                    movementName: practiceMovementName,
                    onBack: goBack,
                    onContinue: { move(to: 6) }
                )
            } else if step == 6 {
                ZeroOneOnboardingPlanView(
                    plan: recommendedPlan,
                    canChooseAlternative: hasAnotherPlan,
                    isSaving: isSavingPlan,
                    error: planSaveError ?? profileRepository.saveError,
                    currentBodyWeight: currentBodyWeightSummary,
                    healthWeightMessage: healthWeightMessage,
                    isImportingBodyWeight: isImportingBodyWeight,
                    onBack: goBack,
                    onChange: changePlanAnswer,
                    onEditBodyWeight: { move(to: 4) },
                    onFillBodyWeight: { Task { await fillBodyWeightFromAppleHealth() } },
                    onAlternative: {
                        if let nextAlternativeIndex { planAlternative = nextAlternativeIndex }
                    },
                    onSave: saveFirstWeekPlan,
                    onReloadSavedData: reloadSetupData,
                    needsHealthSetup: mode == .firstRun && !didRequestSetupHealth,
                    recommendation: firstWeekRecommendation
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    if mode == .firstRun {
                        ZeroOneSetupProgressHeader(progress: ZeroOneOnboardingFlow.progress(for: 6), onBack: goBack)
                            .disabled(isSavingPlan || isImportingBodyWeight || setupPermissionBusy)
                    }
                }
            } else {
                questions
            }
        }
        .modifier(ZOThemeScreenSurface(theme: theme))
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .zeroOneTheme(theme)
        .preferredColorScheme(mode == .firstRun ? selectedAppearance.preferredColorScheme : nil)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsLogin) {
            Group {
                NavigationStack {
                    ZeroOneLoginView()
                }
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsSetupHealth) {
            NavigationStack {
                if let health = setupHealth {
                    ZeroOneSetupHealthView(
                        presentation: ZeroOneSetupHealthPresentation(
                            scope: .zeroOneFoundation, status: health.status, issue: health.issue
                        ),
                        onConnect: { Task { await connectSetupHealth() } },
                        onContinue: closeSetupHealth,
                        onNotNow: closeSetupHealth
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", action: closeSetupHealth)
                                .disabled(setupPermissionBusy || isImportingBodyWeight)
                        }
                    }
                }
            }
            .modifier(ZOThemeScreenSurface(theme: theme))
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
            .interactiveDismissDisabled(setupPermissionBusy || isImportingBodyWeight)
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsSetupLanguage) {
            NavigationStack {
                ZeroOneSetupLanguageView(
                    selection: Binding(
                        get: { AppLanguagePreference.storedValue(selectedLanguageRawValue) },
                        set: {
                            guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                            selectedLanguageRawValue = $0.rawValue
                        }
                    ),
                    preferredLanguages: Locale.preferredLanguages,
                    onContinue: {
                        guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                        showsSetupLanguage = false
                    }
                )
                .disabled(isSavingPlan || isImportingBodyWeight || setupPermissionBusy)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                            showsSetupLanguage = false
                        }
                        .disabled(isSavingPlan || isImportingBodyWeight || setupPermissionBusy)
                    }
                }
            }
            .modifier(ZOThemeScreenSurface(theme: theme))
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
            .interactiveDismissDisabled(isSavingPlan || isImportingBodyWeight || setupPermissionBusy)
            .zoSheet(theme)
        }
        .sheet(isPresented: $showsSetupNotifications) {
            Group {
                if let notes = setupNotes {
                    NavigationStack {
                        SmartNotificationsView(notes: notes)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showsSetupNotifications = false }
                                }
                            }
                    }
                    .zeroOneTheme(theme)
                    .preferredColorScheme(theme.colorScheme)
                }
            }
            .zoSheet(theme)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { gesture in
                    guard gesture.startLocation.x <= 32,
                          gesture.translation.width >= 72,
                          abs(gesture.translation.height) < gesture.translation.width * 0.65 else { return }
                    goBack()
                }
        )
    }

    private var questions: some View {
        ZeroOneSetupStepView(
            progress: mode == .firstRun ? ZeroOneOnboardingFlow.progress(for: step) : ZeroOneSetupProgress(current: step + 1, total: stepCount),
            title: LocalizedStringKey(title),
            prompt: LocalizedStringKey(prompt),
            onBack: questionBackAction
        ) {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                if mode == .editing {
                    HStack {
                        Text("TRAINING BASELINE").zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Button("Close") { dismiss() }
                            .buttonStyle(.plain)
                            .accessibilityHint("Closes Training Baseline and keeps your current selections.")
                    }
                    Text("Changes apply as you select them.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsMissingAnswer {
                    Text(verbatim: localization.string(mode == .firstRun
                         ? "Choose an answer to continue, or tap Skip."
                         : "Choose an answer to continue."))
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                ProfilePersistenceNotice(repository: profileRepository) {
                    restoreSavedAnswerDraft()
                }
                .disabled(isImportingBodyWeight || setupPermissionBusy)
                options
            }
            .id(step)
            .transition(questionTransition)
        } dock: {
            controls
        }
    }

    private var questionBackAction: (() -> Void)? {
        guard step > 0 || mode == .firstRun else { return nil }
        return {
            guard !setupPermissionBusy, !isImportingBodyWeight else { return }
            goBack()
        }
    }

    private var setupHealthStep: some View {
        Group {
            if let health = setupHealth {
                ZeroOneSetupHealthView(
                    presentation: .init(scope: .zeroOneFoundation, status: health.status, issue: health.issue),
                    onConnect: { Task { await connectSetupHealth() } },
                    onContinue: { move(to: 4) }, onNotNow: { move(to: 4) }
                )
            } else { ProgressView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZeroOneSetupProgressHeader(progress: ZeroOneOnboardingFlow.progress(for: 7), onBack: goBack)
                .disabled(setupPermissionBusy || isImportingBodyWeight)
        }
        .task {
            // Reading existing authorization state does not request permission.
            let repository = setupHealth ?? HealthConnectionRepository(service: AppleHealthKitService())
            setupHealth = repository
            didRequestSetupHealth = repository.hasCompletedHealthSetup
        }
    }

    private var setupDailyGoalsStep: some View {
        ZeroOneSetupStepView(progress: ZeroOneOnboardingFlow.progress(for: 8),
            title: "Daily goals", prompt: nil, onBack: goBack) {
            if let repository = setupDailyGoals, let hydration = setupHydration {
                ZeroOneSetupDailyGoalsView(goals: repository, hydration: hydration,
                    bodyKilograms: startingBodyKilograms, onContinue: { move(to: 9) })
            }
        } dock: {
            Button("Skip for now") { move(to: 9) }.buttonStyle(ZOButtonStyle(.quiet))
        }
        .task {
            if setupDailyGoals == nil { setupDailyGoals = DailyGoalsRepository() }
            if setupHydration == nil { setupHydration = HydrationViewModel(store: HydrationStoreFactory.makeAppStore()) }
            setupHydration?.refreshForCurrentDay()
        }
    }

    private var setupRemindersStep: some View {
        Group {
            if let notes = setupNotes { SmartNotificationsView(notes: notes) }
            else { ProgressView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZeroOneSetupProgressHeader(progress: ZeroOneOnboardingFlow.progress(for: 9), onBack: goBack)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("See my plan") { move(to: 6) }.buttonStyle(ZOButtonStyle(.primary))
                .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
        .task { if setupNotes == nil { setupNotes = SmartNoteCenter() } }
    }

    private var initialLanguage: some View {
        ZeroOneSetupLanguageView(
            selection: Binding(
                get: { AppLanguagePreference.storedValue(selectedLanguageRawValue) },
                set: { selectedLanguageRawValue = $0.rawValue }
            ),
            preferredLanguages: Locale.preferredLanguages,
            onContinue: { move(to: -1) },
            carriesLaunchTargets: true
        )
    }

    private var welcome: some View {
        ZeroOneSetupWelcomeView(
            appearance: Binding(
                get: { selectedAppearance },
                set: { selectedAppearanceRawValue = $0.rawValue }
            ),
            accent: Binding(
                get: { AccentPreference.storedValue(selectedAccentRawValue) },
                set: { selectedAccentRawValue = $0.rawValue }
            ),
            languageName: AppLanguagePreference.storedValue(selectedLanguageRawValue)
                .resolvedLanguage(preferredLanguages: Locale.preferredLanguages).nativeName,
            onLanguage: {
                guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                showsSetupLanguage = true
            },
            onContinue: {
                guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                move(to: 0)
            },
            onCode: nil,
            carriesLaunchTargets: true,
            isBusy: isSavingPlan || isImportingBodyWeight || setupPermissionBusy
        ) {
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                Text("Set your training, daily goals and reminders, then review your first week. Change any answer later.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Skip setup", action: skipFirstRun)
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .accessibilityHint("Opens 01 with a starter workout. You can finish setup later.")
                Button("Already have an account? Sign in") {
                    guard !isSavingPlan, !isImportingBodyWeight, !setupPermissionBusy else { return }
                    showsLogin = true
                }
                    .buttonStyle(ZOButtonStyle(.quiet))
                if let error = welcomeError ?? profileRepository.saveError {
                    Text(verbatim: localization.string(error))
                        .zoText(.body)
                        .foregroundStyle(theme.destructivePrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                    Button("Reload saved data", action: reloadSetupData)
                        .buttonStyle(ZOButtonStyle(.secondary))
                        .accessibilityHint("Reloads saved answers and workouts. Does not skip setup or activate a plan.")
                }
            }
            .disabled(isSavingPlan || isImportingBodyWeight || setupPermissionBusy)
        }
    }

    private struct WelcomeQuestion: Identifiable {
        let number: String
        let title: String
        let detail: String

        var id: String { number }
    }

    private var welcomeQuestions: [WelcomeQuestion] {
        [
            WelcomeQuestion(number: "1", title: "Goal", detail: "What you are training for"),
            WelcomeQuestion(number: "2", title: "Level", detail: "How long you have trained"),
            WelcomeQuestion(number: "3", title: "Kit", detail: "What you can use"),
            WelcomeQuestion(number: "4", title: "Days", detail: "When you can train"),
            WelcomeQuestion(number: "5", title: "Units", detail: "kg or lb, body weight optional")
        ]
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

    private var theme: ZeroOneThemeTokens {
        guard mode == .firstRun else { return inheritedTheme }
        return ZeroOneThemeTokens.resolve(
            appearance: selectedAppearance,
            systemColorScheme: systemColorScheme,
            designTheme: DesignThemePreference.storedValue(selectedDesignThemeRawValue).designTheme,
            accent: AccentPreference.storedValue(selectedAccentRawValue)
        )
    }

    @ViewBuilder
    private var options: some View {
        switch step {
        case 0:
            ForEach(ZeroOneTrainingGoal.allCases.filter { $0 != .notSure || profileRepository.profile.trainingGoal == .notSure }) { value in
                optionButton(
                    value == .buildStrength ? "Get stronger" : value == .generalFitness ? "Get fitter" : value.title,
                    detail: profileRepository.profile.trainingGoal == value
                        ? localization.format("Primary · %1$@", .text(localization.string(goalDetail(value) ?? "")))
                        : goalDetail(value).map { localization.string($0) },
                    selected: profileRepository.profile.selectedTrainingGoals.contains(value)
                ) {
                    profileRepository.update {
                        $0.toggleTrainingGoal(value)
                    }
                }
                if value == .sportPerformance && profileRepository.profile.selectedTrainingGoals.contains(.sportPerformance) {
                    Text("Which sport? Optional")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    ForEach(ZeroOneTrainingSport.allCases) { sport in
                        optionButton(sport.title, selected: profileRepository.profile.trainingSport == sport) {
                            profileRepository.update { $0.trainingSport = sport }
                        }
                    }
                }
            }
        case 1:
            ForEach(ZeroOneTrainingExperience.allCases.filter { value in
                (value != .someExperience && value != .notSure) || profileRepository.profile.trainingExperience == value
            }) { value in
                optionButton(
                    value == .startingOut ? "New to this" : value.title,
                    detail: experienceDetail(value).map { localization.string($0) },
                    selected: profileRepository.profile.trainingExperience == value
                ) {
                    profileRepository.update { $0.trainingExperience = value }
                }
            }
        case 2:
            equipmentOptions
        case 3:
            daysOptions
        default:
            unitsOptions
        }
    }

    private var equipmentOptions: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("QUICK PICKS")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 130), spacing: ZOSpace.s)], spacing: ZOSpace.s) {
                equipmentPreset("Full gym", items: ZeroOneEquipmentItem.fullGym)
                equipmentPreset("Home kit", items: ZeroOneEquipmentItem.homeKit)
                equipmentPreset("Nothing", items: [.none])
            }
            Text("ADJUST YOUR KIT")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .padding(.top, ZOSpace.m)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 190), spacing: ZOSpace.s)], spacing: ZOSpace.s) {
                ForEach(ZeroOneEquipmentItem.allCases) { item in
                    optionButton(item.title, symbol: item.symbol, selected: (profileRepository.profile.availableEquipment ?? []).contains(item)) {
                        profileRepository.update { profile in
                            let updated = ZeroOneEquipmentItem.toggling(item, in: profile.availableEquipment ?? [])
                            profile.availableEquipment = updated.isEmpty ? nil : updated
                            profile.equipmentAccess = updated.isEmpty ? nil : ZeroOneEquipmentItem.legacyAccess(for: updated)
                        }
                    }
                }
            }
            Text(equipmentSummary)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            starterSelectionOptions
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func equipmentPreset(_ title: String, items: Set<ZeroOneEquipmentItem>) -> some View {
        let selected = profileRepository.profile.availableEquipment == items
        return optionButton(title, selected: selected, compact: true) {
            profileRepository.update { profile in
                profile.availableEquipment = items
                profile.equipmentAccess = ZeroOneEquipmentItem.legacyAccess(for: items)
            }
        }
    }

    private var equipmentSummary: String {
        guard let items = profileRepository.profile.availableEquipment, !items.isEmpty else {
            return "Choose the equipment you can reliably use."
        }
        return items == [.none] ? "Bodyweight exercises only." : "\(items.count) equipment types selected."
    }

    private var starterSelectionOptions: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            DisclosureGroup("Confirm specific equipment") {
                Text("Only confirm equipment and supports you can use for the shown exercise.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                ForEach(StarterEquipmentRequirement.allCases.filter {
                    let equipment = profileRepository.profile.availableEquipment ?? []
                    return !equipment.contains(.none) && equipment.contains($0.equipment)
                }, id: \.self) { requirement in
                    Toggle(isOn: Binding(
                        get: { profileRepository.profile.starterSelectionPreferences?.confirmedEquipment.contains(requirement) == true },
                        set: { enabled in
                            profileRepository.update { profile in
                                var preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
                                if enabled { preferences.confirmedEquipment.insert(requirement) }
                                else { preferences.confirmedEquipment.remove(requirement) }
                                profile.starterSelectionPreferences = preferences
                            }
                        }
                    )) { Text(LocalizedStringKey(requirement.titleKey)) }
                }
            }
            DisclosureGroup("Movement exclusions") {
                Toggle("Some movements need care", isOn: Binding(
                    get: { profileRepository.profile.trainingConstraint == .movementSensitivity },
                    set: { enabled in
                        profileRepository.update { profile in
                            profile.trainingConstraint = enabled ? .movementSensitivity : ZeroOneTrainingConstraint.none
                            if !enabled {
                                var preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
                                preferences.blockedGroups = []
                                preferences.blockedExerciseIDs = []
                                profile.starterSelectionPreferences = preferences
                            }
                        }
                    }
                ))
                if profileRepository.profile.trainingConstraint == .movementSensitivity {
                    Text("Exclude the movements you need to avoid. This does not assess an injury.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                    ForEach(StarterMovementGroup.allCases, id: \.self) { group in
                        Toggle(isOn: Binding(
                            get: { profileRepository.profile.starterSelectionPreferences?.blockedGroups.contains(group) == true },
                            set: { enabled in
                                profileRepository.update { profile in
                                    var preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
                                    if enabled { preferences.blockedGroups.insert(group) }
                                    else { preferences.blockedGroups.remove(group) }
                                    profile.starterSelectionPreferences = preferences
                                }
                            }
                        )) { Text(LocalizedStringKey(group.titleKey)) }
                    }
                }
            }
        }
        .zoText(.body)
    }

    private var daysOptions: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 160 : 88), spacing: ZOSpace.s)], spacing: ZOSpace.s) {
                ForEach(ZeroOneTrainingDay.allCases) { day in
                    optionButton(day.shortTitle, selected: (profileRepository.profile.preferredTrainingDays ?? []).contains(day), compact: true) {
                        profileRepository.update { profile in
                            var days = profile.preferredTrainingDays ?? []
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                            profile.preferredTrainingDays = days.isEmpty ? nil : days
                            profile.weeklyAvailability = days.isEmpty ? nil : ZeroOneTrainingDay.legacyAvailability(for: days)
                        }
                    }
                    .accessibilityLabel(day.title)
                }
            }
            if let days = profileRepository.profile.preferredTrainingDays, !days.isEmpty {
                Text(daysSummary)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text("SESSION LENGTH")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .padding(.top, ZOSpace.m)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 105), spacing: ZOSpace.s)], spacing: ZOSpace.s) {
                ForEach([30, 45, 60, 75], id: \.self) { minutes in
                    optionButton(minutes == 75 ? localization.string("75+ min") : localization.format("%1$lld min", .integer(minutes)), selected: (profileRepository.profile.preferredSessionMinutes ?? 45) == minutes, compact: true) {
                        profileRepository.update { $0.preferredSessionMinutes = minutes }
                    }
                }
            }
            Text("01 never moves a planned session without asking. Reminders can be set later, when they are useful.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var daysSummary: String {
        guard let days = profileRepository.profile.preferredTrainingDays, !days.isEmpty else {
            return "Choose the days you can usually train."
        }
        return "\(days.count) day\(days.count == 1 ? "" : "s") a week: \(days.sorted { $0.rawValue < $1.rawValue }.map(\.shortTitle).joined(separator: ", "))."
    }

    private var setupConnections: some View {
        Button {
            setupNotes = setupNotes ?? SmartNoteCenter()
            showsSetupNotifications = true
        } label: {
            Label("See how workout notifications help", systemImage: "bell")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .zoText(.section)
        .foregroundStyle(theme.textPrimary)
        .disabled(setupPermissionBusy || isImportingBodyWeight)
        .accessibilityHint("Opens examples and notification choices. Does not request permission.")
    }

    private func openSetupHealth() {
        guard mode == .firstRun, !setupPermissionBusy, !isImportingBodyWeight else { return }
        // Opening a presentation reads the saved setup state, never requests it.
        let repository = setupHealth ?? HealthConnectionRepository(service: AppleHealthKitService())
        setupHealth = repository
        didRequestSetupHealth = repository.hasCompletedHealthSetup
        showsSetupHealth = true
    }

    private func closeSetupHealth() {
        guard !setupPermissionBusy, !isImportingBodyWeight else { return }
        showsSetupHealth = false
    }

    private func connectSetupHealth() async {
        guard mode == .firstRun, !setupPermissionBusy else { return }
        setupPermissionBusy = true
        defer { setupPermissionBusy = false }
        let repository = setupHealth ?? HealthConnectionRepository(service: AppleHealthKitService())
        setupHealth = repository
        await repository.connect()
        didRequestSetupHealth = repository.hasCompletedHealthSetup
    }

    private var unitsOptions: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(spacing: 0) {
                if bodyUsesImperial {
                    imperialHeightRow
                } else {
                    bodyMeasurementRow("Height", text: Binding(get: { bodyHeightInput }, set: setBodyHeightInput),
                        unit: "cm", source: heightHealthSource)
                }
                Divider().overlay(theme.strokeSubtle)
                bodyMeasurementRow("Weight", text: Binding(get: { bodyWeightInput }, set: setBodyWeightInput),
                    unit: bodyUsesImperial ? "lb" : "kg", source: importedBodyWeight?.recordedAt)
            }
            .zoThemeCardSurface()
            ZOSegmentedControl("Units", selection: Binding(
                get: { profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight() },
                set: selectWeightUnit
            ), options: [
                ZOSegment(value: ZeroOneWeightPreference.kilograms, label: Text(verbatim: "kg, cm")),
                ZOSegment(value: ZeroOneWeightPreference.pounds, label: Text(verbatim: "lb, ft"))
            ])
            Button {
                Task { await fillBodyWeightFromAppleHealth() }
            } label: {
                Text(verbatim: localization.string(isImportingBodyWeight ? "Checking Apple Health…" : "Fill from Apple Health"))
            }
            .buttonStyle(ZOButtonStyle(.quiet))
            .disabled(isImportingBodyWeight || setupPermissionBusy)
            if let healthWeightMessage {
                Text(verbatim: ZeroOneOnboardingWeightMessagePresentation.message(
                    healthWeightMessage, importedBodyWeight: importedBodyWeight, localization: localization
                ))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !bodyHeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               BodyHeightMeasurement.centimeters(from: bodyHeightInput, imperial: bodyUsesImperial) == nil {
                Text("Enter a valid height, or clear this optional field.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            if let bodyWeightError {
                Text(verbatim: localization.string(bodyWeightError))
                    .zoText(.body).foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onAppear(perform: syncImperialHeightFields)
        .onChange(of: bodyHeightInput) { _, _ in syncImperialHeightFields() }
        .task {
            guard !didAttemptBodyFill else { return }
            didAttemptBodyFill = true
            // The previous Health page owns authorization. Resuming this page never prompts.
            if UserDefaultsHealthConnectionPreferenceStore().hasCompletedHealthSetup {
                await fillBodyWeightFromAppleHealth(requestSetup: false, onlyMissing: true)
            }
        }
    }

    /// Step 7's saved weight in kilograms, for step 8's water suggestion.
    private var startingBodyKilograms: Double? {
        guard let weight = profileRepository.profile.startingBodyWeight, weight.isFinite else { return nil }
        return bodyUsesImperial ? Measurement(value: weight, unit: UnitMass.pounds).converted(to: .kilograms).value : weight
    }

    private var bodyUsesImperial: Bool {
        (profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()) == .pounds
    }

    private func bodyMeasurementRow(_ title: LocalizedStringKey, text: Binding<String>, unit: String, source: Date?) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(title).zoText(.caption).foregroundStyle(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                TextField("Optional", text: text).keyboardType(.decimalPad)
                    .zoText(.metric).accessibilityLabel(Text(title))
                Text(verbatim: unit).zoText(.label).foregroundStyle(theme.textSecondary)
                if !text.wrappedValue.isEmpty {
                    Button("Clear") { text.wrappedValue = "" }
                        .zoText(.caption).frame(minWidth: 44, minHeight: 44)
                }
            }
            if let source {
                Label(localization.format("From Apple Health, %1$@", .text(source.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(localization.locale)))), systemImage: "heart")
                    .labelStyle(ZOIconLabelStyle()).zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(ZOSpace.cardPadding)
    }

    /// Proof 2 "Your body" in lb, ft: feet and inches side by side, never decimal feet.
    private var imperialHeightRow: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("Height").zoText(.caption).foregroundStyle(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                TextField(String("0"), text: Binding(get: { heightFeetInput },
                                              set: { setImperialHeight(feet: $0, inches: heightInchesInput) }))
                    .keyboardType(.numberPad).zoText(.metric).fixedSize()
                    .accessibilityLabel(Text("Height in feet"))
                Text(verbatim: "ft").zoText(.label).foregroundStyle(theme.textSecondary)
                TextField(String("0"), text: Binding(get: { heightInchesInput },
                                              set: { setImperialHeight(feet: heightFeetInput, inches: $0) }))
                    .keyboardType(.decimalPad).zoText(.metric).fixedSize()
                    .accessibilityLabel(Text("Height in inches"))
                Text(verbatim: "in").zoText(.label).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if !heightFeetInput.isEmpty || !heightInchesInput.isEmpty {
                    Button("Clear") { setImperialHeight(feet: "", inches: "") }
                        .zoText(.caption).frame(minWidth: 44, minHeight: 44)
                }
            }
            if let source = heightHealthSource {
                Label(localization.format("From Apple Health, %1$@", .text(source.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(localization.locale)))), systemImage: "heart")
                    .labelStyle(ZOIconLabelStyle()).zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(ZOSpace.cardPadding)
    }

    /// The two imperial fields write one draft. An unreadable pair (say 13 in)
    /// is kept as typed so the validation line shows and Continue waits.
    private func setImperialHeight(feet: String, inches: String) {
        heightFeetInput = feet
        heightInchesInput = inches
        if feet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setBodyHeightInput("")
        } else if let centimeters = BodyHeightMeasurement.centimeters(feet: feet, inches: inches) {
            setBodyHeightInput(String(format: "%.4f", centimeters / 30.48))
        } else {
            setBodyHeightInput(feet + "′" + inches)
        }
    }

    /// Health fills, unit switches and restored drafts change bodyHeightInput;
    /// the feet and inches follow, unless they already show that height.
    private func syncImperialHeightFields() {
        guard bodyUsesImperial else { return }
        let fieldsEmpty = heightFeetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && heightInchesInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if bodyHeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !fieldsEmpty { heightFeetInput = ""; heightInchesInput = "" }
            return
        }
        // An unreadable draft is the person's own typing; leave it alone.
        guard let current = BodyHeightMeasurement.centimeters(from: bodyHeightInput, imperial: true) else { return }
        if let shown = BodyHeightMeasurement.centimeters(feet: heightFeetInput, inches: heightInchesInput),
           abs(shown - current) < 0.5 { return }
        let parts = BodyHeightMeasurement(centimeters: current, recordedAt: .now, source: .manual).feetAndInches
        heightFeetInput = String(parts.feet)
        heightInchesInput = String(parts.inches)
    }

    private var heightHealthSource: Date? {
        guard let stored = profileRepository.profile.bodyHeight, stored.source == .appleHealth,
              let displayed = BodyHeightMeasurement.centimeters(from: bodyHeightInput, imperial: bodyUsesImperial),
              abs(displayed - stored.centimeters) < 0.06 else { return nil }
        return stored.recordedAt
    }

    private func setBodyHeightInput(_ value: String) {
        bodyHeightInputRevision += 1
        bodyHeightInput = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileRepository.update { $0.bodyHeight = nil }
        } else if let centimeters = BodyHeightMeasurement.centimeters(from: value, imperial: bodyUsesImperial) {
            profileRepository.update {
                $0.bodyHeight = BodyHeightMeasurement(centimeters: centimeters, recordedAt: .now, source: .manual)
            }
        }
    }

    private func optionButton(
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        selected: Bool,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Symbols/compact grouping remain call-site inputs; proof 2 uses the
        // supplied label and 22-point selection indicator for every option.
        ZeroOneSetupOptionRow(
            title: localization.string(title),
            detail: detail,
            selected: selected,
            onSelect: action
        )
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: ZOSpace.s) {
            if mode == .firstRun && step < stepCount {
                Button(LocalizedStringKey(step == 4 ? "Skip for now" : "Skip this question")) { skipCurrentQuestion() }
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: ZOSpace.m) {
                Button { advance() } label: {
                    Text(verbatim: localization.string(continueTitle))
                }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .opacity(hasSelection ? 1 : 0.42)
                    .accessibilityHint(Text(verbatim: localization.string(hasSelection ? "" : mode == .firstRun
                        ? "Choose an answer to continue, or tap Skip this question."
                        : "Choose an answer to continue.")))
            }
        }
        .disabled(setupPermissionBusy || isImportingBodyWeight)
    }

    private func advance(allowMissing: Bool = false) {
        guard !setupPermissionBusy, profileRepository.isAvailable, profileRepository.saveError == nil else { return }
        guard hasSelection || allowMissing else {
            showsMissingAnswer = true
            return
        }
        if step == 4 && !allowMissing {
            guard bodyHeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || BodyHeightMeasurement.centimeters(from: bodyHeightInput, imperial: bodyUsesImperial) != nil else { return }
            guard commitStartingBodyWeight() else { return }
        }
        if returnsToPlanAfterEdit {
            returnsToPlanAfterEdit = false
            move(to: 6)
            return
        }
        if mode == .firstRun, let next = ZeroOneOnboardingFlow.next(after: step) {
            move(to: next)
            return
        }
        if step < stepCount - 1 {
            move(to: step + 1)
            return
        }
        if mode == .firstRun {
            move(to: 5)
        } else {
            move(to: 6)
        }
    }

    private func skipCurrentQuestion() {
        if step == 4 { restoreSavedAnswerDraft() }
        guard profileRepository.update({ profile in
            switch step {
            case 0:
                profile.trainingGoal = .notSure
                profile.trainingGoals = [.notSure]
                profile.trainingSport = nil
            case 1: profile.trainingExperience = .notSure
            case 2:
                profile.availableEquipment = nil
                profile.equipmentAccess = .notSure
            case 3:
                profile.preferredTrainingDays = nil
                profile.weeklyAvailability = .notSure
            default: break
            }
        }) else { return }
        advance(allowMissing: true)
    }

    private func move(to nextStep: Int) {
        guard !setupPermissionBusy, !isImportingBodyWeight, !isSavingPlan else { return }
        guard (-2...9).contains(nextStep) else { return }
        showsMissingAnswer = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.32)) {
            navigationDirection = nextStep >= step ? 1 : -1
            step = nextStep
        }
        if mode == .firstRun { progressStore.saveStep(nextStep) }
    }

    private var questionTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance = CGFloat(navigationDirection) * 28
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity),
            removal: .offset(x: -distance).combined(with: .opacity)
        )
    }

    private func goBack() {
        guard step >= 0 else { return }
        if returnsToPlanAfterEdit && step < stepCount {
            returnsToPlanAfterEdit = false
            move(to: 6)
        } else if mode == .firstRun, let previous = ZeroOneOnboardingFlow.previous(before: step) {
            move(to: previous)
        } else if step == 6 {
            move(to: 4)
        } else if step == 5 {
            move(to: 4)
        } else if step > 0 || mode == .firstRun {
            move(to: step - 1)
        }
    }

    private func skipFirstRun() {
        guard !isSavingPlan, !setupPermissionBusy, !isImportingBodyWeight else { return }
        let recommendation = ZeroOneFirstWeekPlanner.assess(
            for: profileRepository.profile,
            availableVideoIDs: Self.bundledMovementIDs
        )
        guard let starter = recommendation.plan else {
            welcomeError = localization.string(recommendation.messageKey)
            return
        }
        welcomeError = nil
        if !persistFirstWeekPlan(starter, skippedSetup: true) {
            welcomeError = planSaveError
        }
    }

    private var recommendedPlan: ZeroOneFirstWeekPlan? {
        firstWeekRecommendation.plan
    }

    private var firstWeekRecommendation: ZeroOneFirstWeekRecommendation {
        ZeroOneFirstWeekPlanner.assess(
            for: profileRepository.profile,
            availableVideoIDs: Self.bundledMovementIDs,
            alternative: planAlternative
        )
    }

    private var hasAnotherPlan: Bool {
        nextAlternativeIndex != nil
    }

    private var nextAlternativeIndex: Int? {
        let current = recommendedPlan?.sessions
        for offset in 1...7 {
            let candidate = ZeroOneFirstWeekPlanner.recommend(
                for: profileRepository.profile,
                availableVideoIDs: Self.bundledMovementIDs,
                alternative: planAlternative + offset
            )
            if let candidate, candidate.sessions != current {
                return planAlternative + offset
            }
        }
        return nil
    }

    private var practiceMovementName: String {
        guard let videoID = recommendedPlan?.sessions.first?.videoIDs.first else { return "First movement" }
        return MoveKitExerciseCatalog.exercise(for: videoID)?.name ?? "First movement"
    }

    private var currentBodyWeightSummary: String? {
        guard let number = BodyWeightInput.number(bodyWeightInput) else { return nil }
        let value = NSDecimalNumber(decimal: number).doubleValue
        let unit = profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()
        let kilograms = unit == .kilograms
            ? value
            : Measurement(value: value, unit: UnitMass.pounds).converted(to: .kilograms).value
        guard (0.5 ... 1_000).contains(kilograms) else { return nil }
        return "\(String(format: "%.1f", value)) \(unit.rawValue)"
    }

    private func changePlanAnswer(_ kind: ZeroOneFirstWeekReasonKind) {
        returnsToPlanAfterEdit = true
        let page: Int
        switch kind {
        case .goal: page = 0
        case .experience: page = 1
        case .equipment: page = 2
        case .limitations: page = 2
        case .days, .sessionLength: page = 3
        }
        move(to: page)
    }

    private func saveFirstWeekPlan() {
        guard !isSavingPlan, !setupPermissionBusy, !isImportingBodyWeight, let plan = recommendedPlan else { return }
        planSaveError = nil
        isSavingPlan = true
        defer { isSavingPlan = false }
        guard commitStartingBodyWeight() else {
            planSaveError = bodyWeightError
            return
        }

        guard persistFirstWeekPlan(plan, skippedSetup: false) else { return }
        if mode == .editing { dismiss() }
    }

    private func restoreSavedAnswerDraft() {
        bodyWeightInputRevision += 1
        bodyWeightInput = profileRepository.profile.startingBodyWeight.map { String($0) } ?? ""
        bodyHeightInputRevision += 1
        bodyHeightInput = profileRepository.profile.bodyHeight?.displayValue(imperial: bodyUsesImperial) ?? ""
        importedBodyWeight = nil
        healthWeightMessage = nil
        bodyWeightError = nil
    }

    /// Recovery is a read-only action, separate from the user's next Save.
    /// Keep the screen in review even when both stores become available again.
    private func reloadSetupData() {
        guard !isSavingPlan, !setupPermissionBusy, !isImportingBodyWeight else { return }
        let profileRecovered = profileRepository.reload()
        let workoutsRecovered = customWorkouts.reload()
        bodyWeight.reload()
        if profileRecovered { restoreSavedAnswerDraft() }
        let error: String?
        if !profileRecovered {
            error = profileRepository.saveError
        } else if !workoutsRecovered {
            error = "Saved workouts are still unavailable. Existing data has been kept. Try reloading again."
        } else if !bodyWeight.isAvailable && !bodyWeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Saved body weights are still unavailable. Try reloading again, or leave the optional starting weight blank. Existing readings have been kept."
        } else {
            error = nil
        }
        planSaveError = error
        welcomeError = error
    }

    @discardableResult
    private func persistFirstWeekPlan(_ plan: ZeroOneFirstWeekPlan, skippedSetup: Bool) -> Bool {
        guard !isImportingBodyWeight, !setupPermissionBusy else {
            planSaveError = "Wait for Apple Health to finish before saving this plan."
            return false
        }
        do {
            try ZeroOneFirstWeekPlanCommitter.save(plan, profile: profileRepository,
                workouts: customWorkouts, completesOnboarding: mode == .firstRun,
                skippedSetup: skippedSetup)
        } catch {
            planSaveError = error.localizedDescription
            return false
        }
        if mode == .firstRun { progressStore.clear() }
        planSaveError = nil
        return true
    }

    private var hasSelection: Bool {
        switch step {
        case 0: profileRepository.profile.trainingGoal != nil
        case 1: profileRepository.profile.trainingExperience != nil
        case 2: !(profileRepository.profile.availableEquipment ?? []).isEmpty
        case 3: !(profileRepository.profile.preferredTrainingDays ?? []).isEmpty
        default: true
        }
    }

    private var continueTitle: String {
        guard step == stepCount - 1 else { return "Continue" }
        if mode == .editing { return "Review plan" }
        return "Continue"
    }

    private var eyebrow: String {
        ["GOAL", "EXPERIENCE", "EQUIPMENT", "DAYS", "UNITS"][step]
    }

    private var title: String {
        ["What are you training for?", "How much have you trained with weights?", "What can you train with?", "Which days suit you?", "Your body"][step]
    }

    private var prompt: String {
        ["Choose all that matter. The goal marked Primary guides your starter plan.", "This sets your first-week volume. Your starting loads remain yours to choose.", "Pick a starting point, then adjust. 01 only plans exercises you can do.", "Pick the days you can usually train. 01 plans around them and never moves a session without asking.", "Height and weight are optional. Review your Health readings or enter your own."][step]
    }

    private func goalDetail(_ goal: ZeroOneTrainingGoal) -> String? {
        switch goal {
        case .buildStrength: "Lift more, with good form"
        case .buildMuscle: "Size and shape through steady volume"
        case .generalFitness: "Stamina, conditioning and energy"
        case .sportPerformance: "Power, speed and resilience"
        case .moveBetter: "Mobility, posture, feeling good"
        case .manageBodyWeight: "Training that supports a weight goal"
        case .notSure: nil
        }
    }

    private func experienceDetail(_ experience: ZeroOneTrainingExperience) -> String? {
        switch experience {
        case .startingOut: "Still learning the main movements"
        case .returning: "Trained before, out of routine now"
        case .trainingRegularly: "Up to three years of steady training"
        case .experienced: "Three years or more; I know my working weights"
        case .someExperience, .notSure: nil
        }
    }

    private func selectWeightUnit(_ unit: ZeroOneWeightPreference) {
        let previous = profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()
        guard previous != unit else { return }
        let height = BodyHeightMeasurement.centimeters(from: bodyHeightInput, imperial: previous == .pounds)
        guard profileRepository.updateVerified({ profile in
            let units = ZeroOneProfileUnitSelection(weight: unit,
                distance: profile.preferredDistanceUnit ?? ZeroOneOnboardingUnitDefaults.distance())
            profile = units.applying(to: profile, previousWeight: previous)
        }) else { return }
        if let height {
            bodyHeightInputRevision += 1
            bodyHeightInput = BodyHeightMeasurement(centimeters: height, recordedAt: .now, source: .manual)
                .displayValue(imperial: unit == .pounds)
        }
        if let number = BodyWeightInput.number(bodyWeightInput) {
            let value = NSDecimalNumber(decimal: number).doubleValue
            let converted = previous == .kilograms
                ? Measurement(value: value, unit: UnitMass.kilograms).converted(to: .pounds).value
                : Measurement(value: value, unit: UnitMass.pounds).converted(to: .kilograms).value
            setBodyWeightInput(String(format: "%.1f", converted))
        }
    }

    /// Only deliberate input changes write the draft. Restoring a saved value
    /// updates presentation without triggering another persistence operation.
    private func setBodyWeightInput(_ value: String) {
        bodyWeightInputRevision += 1
        bodyWeightInput = value
        updateBodyWeightDraft(value)
    }

    private func updateBodyWeightDraft(_ value: String) {
        bodyWeightError = nil
        let parsed = BodyWeightInput.number(value).map { NSDecimalNumber(decimal: $0).doubleValue }
        let weight = parsed?.isFinite == true ? parsed : nil
        let unit = profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()
        let kilograms = weight.map { unit == .kilograms
            ? $0
            : Measurement(value: $0, unit: UnitMass.pounds).converted(to: .kilograms).value
        }
        let isValidWeight = kilograms.map { (0.5 ... 1_000).contains($0) } ?? false
        let matchesImportedReading = importedBodyWeight.map { reading in
            kilograms.map { abs($0 - reading.kilograms) < 0.1 } ?? false
        } ?? false
        let changedImportedReading = importedBodyWeight != nil && !matchesImportedReading
        if !matchesImportedReading {
            importedBodyWeight = nil
            healthWeightMessage = nil
        }
        let importedDate = matchesImportedReading ? importedBodyWeight?.recordedAt : nil
        profileRepository.update {
            $0.startingBodyWeight = isValidWeight ? weight : nil
            if let importedDate {
                $0.startingBodyWeightRecordedAt = importedDate
            } else if changedImportedReading || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                $0.startingBodyWeightRecordedAt = nil
            }
        }
    }

    @MainActor
    private func fillBodyWeightFromAppleHealth(requestSetup: Bool = true, onlyMissing: Bool = false) async {
        guard !isImportingBodyWeight, !setupPermissionBusy else { return }
        let readWeight = !onlyMissing || bodyWeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let readHeight = !onlyMissing || bodyHeightInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard readWeight || readHeight else { return }
        isImportingBodyWeight = true
        let weightRevision = bodyWeightInputRevision
        let heightRevision = bodyHeightInputRevision
        defer { isImportingBodyWeight = false }
        healthWeightMessage = nil

        if requestSetup {
            // One shared request, including height and weight. The subsequent reads do not prompt.
            if mode == .firstRun {
                if !didRequestSetupHealth {
                    await connectSetupHealth()
                    guard didRequestSetupHealth else {
                        healthWeightMessage = "Health setup did not complete. You can enter your measurements or leave them blank."
                        return
                    }
                }
            } else {
                let repository = setupHealth ?? HealthConnectionRepository(service: AppleHealthKitService())
                setupHealth = repository
                await repository.connect()
                guard repository.hasCompletedHealthSetup else { return }
            }
        }

        let service = AppleHealthKitService()
        var filled = false
        var failed = false
        if readWeight {
            do {
                if let reading = try await service.latestBodyWeightReading(),
                   !Task.isCancelled, weightRevision == bodyWeightInputRevision {
                    let displayed = bodyUsesImperial
                        ? Measurement(value: reading.kilograms, unit: UnitMass.kilograms).converted(to: .pounds).value
                        : reading.kilograms
                    importedBodyWeight = reading
                    setBodyWeightInput(String(format: "%.1f", displayed))
                    filled = true
                }
            } catch { failed = true }
        }
        guard !Task.isCancelled else { return }
        if readHeight {
            do {
                if let reading = try await service.latestHeightReading(),
                   !Task.isCancelled, heightRevision == bodyHeightInputRevision {
                    if profileRepository.updateVerified({ $0.bodyHeight = reading }) {
                        bodyHeightInputRevision += 1
                        bodyHeightInput = reading.displayValue(imperial: bodyUsesImperial)
                        filled = true
                    }
                }
            } catch { failed = true }
        }
        guard !Task.isCancelled else { return }
        if failed {
            healthWeightMessage = "Some Health readings could not be loaded. Review the values shown or enter them manually."
        } else if !filled {
            healthWeightMessage = "No new Health measurements were filled. Your entries have been kept."
        }
    }

    private func commitStartingBodyWeight() -> Bool {
        guard profileRepository.update({
            if $0.preferredSessionMinutes == nil { $0.preferredSessionMinutes = 45 }
            if $0.preferredWeightUnit == nil { $0.preferredWeightUnit = ZeroOneOnboardingUnitDefaults.weight() }
            if $0.preferredDistanceUnit == nil { $0.preferredDistanceUnit = ZeroOneOnboardingUnitDefaults.distance() }
        }) else {
            bodyWeightError = profileRepository.saveError
            return false
        }
        let input = bodyWeightInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return true }
        guard let number = BodyWeightInput.number(input) else {
            bodyWeightError = "Enter a valid number, or clear the optional body weight."
            return false
        }
        let value = NSDecimalNumber(decimal: number).doubleValue
        let unit = profileRepository.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()
        let massUnit: BodyWeightUnit = unit == .kilograms ? .kilograms : .pounds
        let kilograms = massUnit.kilograms(from: number)
        let normalizedKilograms = NSDecimalNumber(decimal: kilograms).doubleValue
        guard normalizedKilograms.isFinite, (0.5 ... 1_000).contains(normalizedKilograms) else {
            bodyWeightError = "Enter a realistic body weight, or clear this optional field."
            return false
        }
        let id = profileRepository.profile.startingBodyWeightEntryID ?? UUID()
        let recordedAt = profileRepository.profile.startingBodyWeightRecordedAt ?? Date()
        guard profileRepository.update({
            $0.startingBodyWeight = value
            $0.startingBodyWeightEntryID = id
            $0.startingBodyWeightRecordedAt = recordedAt
            $0.preferredWeightUnit = unit
        }) else {
            bodyWeightError = profileRepository.saveError
            return false
        }
        let entry = BodyWeightEntry(id: id, recordedAt: recordedAt, kilograms: kilograms)
        do {
            if let previous = bodyWeight.entries.first(where: { $0.id == id }) {
                try bodyWeight.replace(previous, with: entry)
            } else {
                try bodyWeight.save(entry)
            }
            bodyWeightError = nil
            return true
        } catch {
            bodyWeightError = "Couldn't save your starting weight. Try again or clear it to continue."
            return false
        }
    }

    private func contentMargin(for width: CGFloat) -> CGFloat {
        ZOSpace.screenMargin
    }
}
