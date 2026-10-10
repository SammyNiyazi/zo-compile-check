import SwiftUI

/// The owner binds the existing language preference storage. Only translated,
/// supported languages are offered; language selection does not advance setup.
struct ZeroOneSetupLanguageView: View {
    @Binding var selection: AppLanguagePreference
    let preferredLanguages: [String]
    let onContinue: () -> Void
    var carriesLaunchTargets = false
    @Environment(\.zeroOneLaunchCoveringDestination) private var launchCoversDestination
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var cyclingLanguage: AppLanguage?
    @State private var didFinishCycle = false

    private var selectedLanguage: AppLanguage { selection.resolvedLanguage(preferredLanguages: preferredLanguages) }
    private var localization: AppLocalization { AppLocalization(language: selectedLanguage) }

    var body: some View {
        VStack(spacing: 0) {
            Image("ZeroOneSplashLogo")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: theme.colorScheme))
                .accessibilityHidden(true)
                .opacity(carriesLaunchTargets && launchCoversDestination ? 0 : 1)
                .anchorPreference(key: ZeroOneLaunchTargetKey.self, value: .bounds) {
                    carriesLaunchTargets ? ZeroOneLaunchTargets(brand: $0, brandComposition: .mark, brandTheme: theme) : ZeroOneLaunchTargets()
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, minHeight: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: greeting(cyclingLanguage ?? selectedLanguage) + ".")
                            .zoProofText(.display, size: 56, lineHeight: 60, weight: 700, tracking: -1.4)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityLabel(Text(verbatim: greeting(selectedLanguage)))
                        Text(verbatim: AppLanguage.allCases.filter { $0 != selectedLanguage }.map(greeting).joined(separator: " · "))
                            .zoProofText(.title, size: 26, lineHeight: 32, weight: 700, tracking: -0.3)
                            .foregroundStyle(theme.textTertiary.opacity(0.55))
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 2) {
                        ForEach(AppLanguage.allCases) { language in
                            languageRow(language)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, 22)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(theme.textPrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ZOSpace.s) {
                Button(action: onContinue) { Text(verbatim: localization.string("Continue")) }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .opacity(carriesLaunchTargets && launchCoversDestination ? 0 : 1)
                    .anchorPreference(key: ZeroOneLaunchTargetKey.self, value: .bounds) {
                        carriesLaunchTargets ? ZeroOneLaunchTargets(action: $0, actionCopy: .continueSetup, actionTheme: theme, actionLocalization: localization) : ZeroOneLaunchTargets()
                    }
                Text(verbatim: localization.string("You can change it any time in Settings."))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
        .task(id: launchCoversDestination) {
            guard !carriesLaunchTargets || !launchCoversDestination else { return }
            guard !didFinishCycle, !reduceMotion, !voiceOverEnabled else { didFinishCycle = true; return }
            let startingLanguage = selectedLanguage
            for language in AppLanguage.allCases {
                guard !Task.isCancelled, !didFinishCycle, selectedLanguage == startingLanguage else { return }
                cyclingLanguage = language
                try? await Task.sleep(for: .seconds(ZOMotion.micro))
            }
            guard !Task.isCancelled else { return }
            cyclingLanguage = nil
            didFinishCycle = true
        }
        .onChange(of: selectedLanguage) { _, _ in
            cyclingLanguage = nil
            didFinishCycle = true
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { cyclingLanguage = nil; didFinishCycle = true }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { cyclingLanguage = nil; didFinishCycle = true }
        }
        .onDisappear {
            cyclingLanguage = nil
            didFinishCycle = true
        }
    }

    private func greeting(_ language: AppLanguage) -> String {
        language == .bulgarian ? "Здравей" : "Hello"
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let selected = selectedLanguage == language
        let deviceLanguage = AppLanguagePreference.system.resolvedLanguage(preferredLanguages: preferredLanguages)
        return Button {
            didFinishCycle = true
            cyclingLanguage = nil
            selection = language == .bulgarian ? .bulgarian : .english
        } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ZOSpace.m))
            layout {
                Text(verbatim: greeting(language))
                    .zoProofText(.display, size: 34, lineHeight: 40, weight: 700, tracking: -0.6)
                    .foregroundStyle(selected ? theme.textPrimary : theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                    HStack(spacing: 6) {
                        if selected { Image(systemName: "checkmark").zoIcon(ZOIcon.inline).accessibilityHidden(true) }
                        Text(verbatim: language.nativeName)
                    }
                    .zoProofText(.caption, size: 13, lineHeight: 18, weight: 500)
                    if language == deviceLanguage {
                        Text(verbatim: localization.string("Your iPhone")).zoText(.caption).opacity(0.8)
                    }
                }
                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
            }
            .padding(.vertical, 6)
            .frame(minHeight: ZOSpace.hitTarget)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { theme.strokeSubtle.frame(height: ZOStroke.hairline) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: language.nativeName))
        .accessibilityHint(Text(verbatim: language == deviceLanguage ? localization.string("Your iPhone") : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Reusable proof-2 chrome. The caller retains focus, persistence notices,
/// content identity, navigation validation and the actual number of pages.
struct ZeroOneSetupStepView<Content: View, Dock: View>: View {
    let progress: ZeroOneSetupProgress?
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey?
    let onBack: (() -> Void)?
    @ViewBuilder let content: Content
    @ViewBuilder let dock: Dock
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(spacing: 0) {
            ZeroOneSetupProgressHeader(progress: progress, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.titleToContent) {
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(title).zoThemeHeading(.display, context: .directScrollDisplay).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        if let prompt { Text(prompt).zoText(.body).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, 28)
                .padding(.bottom, ZOSpace.l)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            dock.padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m).background(theme.backgroundPrimary)
        }
    }
}

/// Shared actual setup progress, including Welcome and permission screens.
struct ZeroOneSetupProgressHeader: View {
    let progress: ZeroOneSetupProgress?
    let onBack: (() -> Void)?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZOSpace.m) {
                if let onBack {
                    Button(action: onBack) { Image(systemName: "chevron.left").zoIcon(ZOIcon.bar) }
                        .buttonStyle(ZOButtonStyle(.round)).accessibilityLabel("Back")
                } else { Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget).accessibilityHidden(true) }
                if let progress {
                    Text(verbatim: localization.format("Step %1$lld of %2$lld", .integer(progress.current), .integer(progress.total)))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                } else { Spacer(minLength: 0) }
                Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget).accessibilityHidden(true)
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 4)
            .frame(minHeight: 52)
            if let progress {
                HStack(spacing: 3) {
                    ForEach(progress.segments) { segment in
                        RoundedRectangle(cornerRadius: theme.designTheme == .freak ? 0 : theme.designTheme == .princess ? 4 : 2)
                            .fill(segment.mark == .completed ? theme.textPrimary : segment.mark == .current ? theme.textPrimary.opacity(0.45) : theme.surfaceTertiary)
                    }
                }
                .frame(height: ZOStroke.progress)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, 6)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Selection comes from the current profile. This row never writes a profile.
struct ZeroOneSetupOptionRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    let onSelect: () -> Void
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).zoText(.section)
                    if let detail { Text(verbatim: detail).zoText(.caption).foregroundStyle(theme.textSecondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Circle().fill(selected ? theme.textPrimary : .clear)
                    .overlay { Circle().strokeBorder(selected ? .clear : theme.textTertiary, lineWidth: ZOStroke.control) }
                    .overlay { if selected { Image(systemName: "checkmark").zoIcon(ZOIcon.inline).foregroundStyle(theme.backgroundPrimary) } }
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, ZOSpace.cardPadding)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? theme.textPrimary : .clear, lineWidth: ZOStroke.control) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Full scroll-and-dock surface below the owner's optional step chrome.
/// First-run settings use the owner's existing AppStorage-backed bindings.
/// Optional routes are supplied only when they actually exist.
struct ZeroOneSetupWelcomeView<SupplementaryContent: View>: View {
    @Binding var appearance: AppearancePreference
    @Binding var accent: AccentPreference
    let languageName: String
    let onLanguage: () -> Void
    let onContinue: () -> Void
    var onCode: (() -> Void)?
    let carriesLaunchTargets: Bool
    let isBusy: Bool
    private let supplementaryContent: SupplementaryContent
    @Environment(\.zeroOneLaunchCoveringDestination) private var launchCoversDestination
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // The original constructor remains available without supplementary content.
    // Anchors and busy gating are opt-in additions with safe compatibility defaults.
    init(
        appearance: Binding<AppearancePreference>,
        accent: Binding<AccentPreference>,
        languageName: String,
        onLanguage: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onCode: (() -> Void)? = nil,
        carriesLaunchTargets: Bool = false,
        isBusy: Bool = false
    ) where SupplementaryContent == EmptyView {
        self.init(appearance: appearance, accent: accent, languageName: languageName,
            onLanguage: onLanguage, onContinue: onContinue, onCode: onCode,
            carriesLaunchTargets: carriesLaunchTargets, isBusy: isBusy) { EmptyView() }
    }

    init(
        appearance: Binding<AppearancePreference>,
        accent: Binding<AccentPreference>,
        languageName: String,
        onLanguage: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onCode: (() -> Void)? = nil,
        carriesLaunchTargets: Bool = false,
        isBusy: Bool = false,
        @ViewBuilder supplementaryContent: () -> SupplementaryContent
    ) {
        self._appearance = appearance
        self._accent = accent
        self.languageName = languageName
        self.onLanguage = onLanguage
        self.onContinue = onContinue
        self.onCode = onCode
        self.carriesLaunchTargets = carriesLaunchTargets
        self.isBusy = isBusy
        self.supplementaryContent = supplementaryContent()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, 28)
                .padding(.bottom, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ZOSpace.xs) {
                Button("Continue", action: onContinue).buttonStyle(ZOButtonStyle(.primary))
                    .opacity(carriesLaunchTargets && launchCoversDestination ? 0 : 1)
                    .anchorPreference(key: ZeroOneLaunchTargetKey.self, value: .bounds) {
                        carriesLaunchTargets ? ZeroOneLaunchTargets(action: $0, actionCopy: .continueSetup, actionTheme: theme, actionLocalization: localization) : ZeroOneLaunchTargets()
                    }
                if let onCode { Button("I have a code", action: onCode).buttonStyle(ZOButtonStyle(.quiet)) }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
        .foregroundStyle(theme.textPrimary)
        .disabled(isBusy)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ZOSpace.titleToContent) {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Image("ZeroOneSplashLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: theme.colorScheme))
                    .accessibilityHidden(true)
                    .opacity(carriesLaunchTargets && launchCoversDestination ? 0 : 1)
                    .anchorPreference(key: ZeroOneLaunchTargetKey.self, value: .bounds) {
                        carriesLaunchTargets ? ZeroOneLaunchTargets(brand: $0, brandComposition: .mark, brandTheme: theme) : ZeroOneLaunchTargets()
                    }
                    .padding(.bottom, 6)
                Text("Welcome to 01").zoThemeHeading(.display, context: .directScrollDisplay).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text("Set it up your way. All of this lives in Settings too.")
                    .zoText(.body).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Appearance").zoText(.caption).foregroundStyle(theme.textSecondary)
                    ZOSegmentedControl("Appearance", selection: $appearance, options: AppearancePreference.allCases.map {
                        ZOSegment(value: $0, label: Text(LocalizedStringKey($0.title)))
                    })
                }
                .padding(.horizontal, ZOSpace.cardPadding)
                .padding(.vertical, ZOSpace.m)
                Divider().overlay(theme.strokeSubtle)
                accentRow
                Divider().overlay(theme.strokeSubtle)
                Button(action: onLanguage) {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
                        : AnyLayout(HStackLayout(spacing: ZOSpace.m))
                    layout {
                        HStack(spacing: ZOSpace.m) {
                            Image(systemName: "globe").zoIcon(ZOIcon.row).accessibilityHidden(true)
                            Text("Language").zoText(.section)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: ZOSpace.s) {
                            Text(verbatim: languageName).zoText(.label).foregroundStyle(theme.textSecondary)
                            Image(systemName: "chevron.right").zoIcon(ZOIcon.inline)
                                .foregroundStyle(theme.textSecondary).accessibilityHidden(true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ZOSpace.cardPadding)
                    .frame(minHeight: ZOSpace.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .zoThemeCardSurface()
            supplementaryContent
        }
        .foregroundStyle(theme.textPrimary)
    }

    private var accentRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.m))
        return layout {
            Text("Accent").zoText(.section).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(AccentPreference.allCases) { value in
                    Button { accent = value } label: {
                        Circle().fill(value.swatch.fill)
                            .frame(width: 22, height: 22)
                            .overlay { Circle().strokeBorder(value.swatch.edge(in: theme.colorScheme), lineWidth: ZOStroke.hairline) }
                            .overlay {
                                if accent == value {
                                    ZStack {
                                        Circle().strokeBorder(theme.backgroundPrimary, lineWidth: 2)
                                            .frame(width: 26, height: 26)
                                        Circle().strokeBorder(theme.textPrimary, lineWidth: 2)
                                            .frame(width: 30, height: 30)
                                    }
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                }
                            }
                            .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey(value.title)))
                    .accessibilityAddTraits(accent == value ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, ZOSpace.cardPadding)
        .padding(.vertical, ZOSpace.s)
        .frame(minHeight: ZOSpace.rowMinHeight)
    }
}

/// Fixed brand-object roles from proof 27, independent of interface accent and mode.
/// Existing generated primitives preserve the package's Onyx/warm-white/yellow values.
private enum ZeroOneSetupHealthArtwork {
    static let onyx = ZOColor.Swatch.yellow.on
    static let signal = ZOColor.Swatch.yellow.fill
    static let ink = ZOColor.resolved(ZOColor.inkPrimary, in: .dark)
    static let secondaryInk = ZOColor.resolved(ZOColor.inkSecondary, in: .dark)
    static let edge = ZOColor.resolved(ZOColor.surface3, in: .dark)
}

/// Uses the real scope and real request status. No request on appear, no implied
/// grant, no fabricated preview readings, and no promise of workout writes.
struct ZeroOneSetupHealthView: View {
    let presentation: ZeroOneSetupHealthPresentation
    let onConnect: () -> Void
    let onContinue: () -> Void
    let onNotNow: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.l)
                .padding(.bottom, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
        .foregroundStyle(theme.textPrimary)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            permissionCard
            Text("One question for Apple Health").zoThemeText(.title).accessibilityAddTraits(.isHeader)
            Text("Choose what 01 can read. Missing data stays missing.").zoText(.body).foregroundStyle(theme.textSecondary)
            if presentation.writeTypes.isEmpty {
                Text("Nothing is written to Health.").zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                Text("Write access").zoText(.section)
                ForEach(presentation.writeTypes, id: \.self) { kind in Text(LocalizedStringKey(kind.title)).zoText(.label) }
            }
            Text(LocalizedStringKey(presentation.statusKey)).zoText(.body).foregroundStyle(theme.textSecondary).accessibilityAddTraits(.updatesFrequently)
            if let issue = presentation.issue { Text(LocalizedStringKey(issue.message)).zoText(.body).foregroundStyle(theme.textSecondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One arrow points from Health to 01: the supplied foundation scope is read-only.
    /// Chips are scope labels, never permission-grant badges or interactive controls.
    private var permissionCard: some View {
        VStack(spacing: ZOSpace.xl) {
            HStack(spacing: 14) {
                Image("ZeroOneSplashLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(ZeroOneSetupHealthArtwork.onyx)
                    .frame(width: 72, height: 72)
                    .background(ZeroOneSetupHealthArtwork.signal, in: RoundedRectangle(cornerRadius: 18))
                Image(systemName: "arrow.left").zoIcon(ZOIcon.bar).foregroundStyle(ZeroOneSetupHealthArtwork.secondaryInk)
                Image(systemName: "heart").zoIcon(ZOIcon.feature)
                    .foregroundStyle(ZeroOneSetupHealthArtwork.onyx)
                    .frame(width: 72, height: 72)
                    .background(ZeroOneSetupHealthArtwork.ink, in: RoundedRectangle(cornerRadius: 18))
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                      ? [GridItem(.flexible())]
                      : [GridItem(.adaptive(minimum: 92), spacing: ZOSpace.s)], spacing: ZOSpace.s) {
                ForEach(presentation.readTypes, id: \.self) { kind in
                    HStack(spacing: 6) {
                        Image(systemName: scopeSymbol(kind)).zoIcon(ZOIcon.inline)
                            .foregroundStyle(ZeroOneSetupHealthArtwork.signal).accessibilityHidden(true)
                        Text(LocalizedStringKey(scopeLabel(kind)))
                            .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                    }
                    .foregroundStyle(ZeroOneSetupHealthArtwork.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZOSpace.m)
                    .padding(.vertical, ZOSpace.s)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(ZeroOneSetupHealthArtwork.ink.opacity(0.1), in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(LocalizedStringKey(kind.title)))
                }
            }
        }
        .padding(.horizontal, ZOSpace.cardPadding)
        .padding(.top, ZOSpace.xxl)
        .padding(.bottom, ZOSpace.xl)
        .background(ZeroOneSetupHealthArtwork.onyx, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(ZeroOneSetupHealthArtwork.edge, lineWidth: ZOStroke.hairline) }
    }

    private func scopeLabel(_ kind: HealthReadDataType) -> String {
        switch kind {
        case .stepCount: "Steps"
        case .activeEnergy: "Energy"
        case .workouts: "Workouts"
        case .sleepAnalysis: "Sleep"
        case .bodyMass: "Weight"
        case .height: "Height"
        case .distanceWalkingRunning: "Distance"
        }
    }

    private func scopeSymbol(_ kind: HealthReadDataType) -> String {
        switch kind {
        case .stepCount: "shoeprints.fill"
        case .activeEnergy: "flame"
        case .workouts: "heart"
        case .sleepAnalysis: "moon"
        case .bodyMass: "scalemass"
        case .height: "ruler"
        case .distanceWalkingRunning: "ruler"
        }
    }

    private var actions: some View {
            VStack(spacing: ZOSpace.xs) {
                if presentation.status == .connected {
                    Button("Continue", action: onContinue).buttonStyle(ZOButtonStyle(.primary))
                } else if presentation.status != .unavailable {
                    Button(action: onConnect) {
                        Text(LocalizedStringKey(presentation.isRequesting ? "Connecting…" : "Connect Apple Health"))
                    }
                        .buttonStyle(ZOButtonStyle(.primary, isLoading: presentation.isRequesting))
                        .disabled(!presentation.canRequest)
                }
                Button("Not now", action: onNotNow).buttonStyle(ZOButtonStyle(.quiet)).disabled(presentation.isRequesting)
            }
    }
}
