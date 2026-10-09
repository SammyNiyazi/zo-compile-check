import SwiftUI
import UIKit

enum ZeroOneLaunchBrandComposition: Equatable {
    case fullLockup
    case mark
}

enum ZeroOneLaunchActionCopy: String, Equatable {
    case setUpMyTraining = "Set up my training"
    case continueSetup = "Continue"
}

struct ZeroOneLaunchTargets {
    var brand: Anchor<CGRect>?
    var action: Anchor<CGRect>?
    var brandComposition: ZeroOneLaunchBrandComposition = .fullLockup
    var actionCopy: ZeroOneLaunchActionCopy = .setUpMyTraining
    var brandTheme: ZeroOneThemeTokens?
    var actionTheme: ZeroOneThemeTokens?
    var actionLocalization: AppLocalization?
}

struct ZeroOneLaunchTargetKey: PreferenceKey {
    static var defaultValue = ZeroOneLaunchTargets()

    static func reduce(value: inout ZeroOneLaunchTargets, nextValue: () -> ZeroOneLaunchTargets) {
        let next = nextValue()
        if let brand = next.brand {
            value.brand = brand
            value.brandComposition = next.brandComposition
            value.brandTheme = next.brandTheme
        }
        if let action = next.action {
            value.action = action
            value.actionCopy = next.actionCopy
            value.actionTheme = next.actionTheme
            value.actionLocalization = next.actionLocalization
        }
    }
}

private struct ZeroOneLaunchCoveringDestinationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var zeroOneLaunchCoveringDestination: Bool {
        get { self[ZeroOneLaunchCoveringDestinationKey.self] }
        set { self[ZeroOneLaunchCoveringDestinationKey.self] = newValue }
    }
}

enum ZeroOneLaunchExperienceContent: Equatable {
    case counterweight
    case staticFullLockup
    case staticMark
}

enum ZeroOneLaunchExperienceTiming {
    static let firstRevealHold: Duration = .milliseconds(720)
    static let coldLaunchHold: Duration = .milliseconds(120)

    static func holdDuration(presentation: ZeroOneLaunchPresentation) -> Duration {
        presentation == .firstReveal ? firstRevealHold : coldLaunchHold
    }

    static func content(
        presentation: ZeroOneLaunchPresentation,
        usesReducedMotion: Bool,
        hasDestinationAnchors: Bool
    ) -> ZeroOneLaunchExperienceContent {
        guard presentation == .firstReveal else { return .staticMark }
        return !usesReducedMotion && hasDestinationAnchors ? .counterweight : .staticFullLockup
    }
}

struct ZeroOneLaunchExperienceView: View {
    let presentation: ZeroOneLaunchPresentation
    let usesReducedMotion: Bool
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let brandTarget: CGRect?
    let actionTarget: CGRect?
    var brandComposition: ZeroOneLaunchBrandComposition = .fullLockup
    var actionCopy: ZeroOneLaunchActionCopy = .setUpMyTraining
    var destinationTheme: ZeroOneThemeTokens? = nil
    var destinationLocalization: AppLocalization? = nil
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.zeroOneTheme) private var inheritedTheme
    @Environment(\.zeroOneLocalization) private var inheritedLocalization
    @Environment(\.locale) private var inheritedLocale

    private var theme: ZeroOneThemeTokens { destinationTheme ?? inheritedTheme }
    private var localization: AppLocalization { destinationLocalization ?? inheritedLocalization }
    @State private var brace: CGFloat = 0
    @State private var fieldProgress: CGFloat = 0
    @State private var fieldTopOvershoot: CGFloat = 0
    @State private var brandProgress: CGFloat = 0
    @State private var brandDip: CGFloat = 0
    @State private var labelOpacity: Double = 0
    @State private var landed = false
    @State private var didFinish = false
    @State private var settledForAccessibility = false

    private var reducedExperience: Bool {
        settledForAccessibility || usesReducedMotion || reduceMotion || voiceOverEnabled
    }

    private struct TaskIdentity: Equatable {
        let hasDestinationAnchors: Bool
        let reducedExperience: Bool
    }

    private var taskIdentity: TaskIdentity {
        TaskIdentity(hasDestinationAnchors: hasDestinationAnchors, reducedExperience: reducedExperience)
    }

    private var hasDestinationAnchors: Bool {
        brandTarget != nil && actionTarget != nil
    }

    private var content: ZeroOneLaunchExperienceContent {
        ZeroOneLaunchExperienceTiming.content(
            presentation: presentation,
            usesReducedMotion: reducedExperience,
            hasDestinationAnchors: hasDestinationAnchors
        )
    }

    var body: some View {
        ZStack {
            switch content {
            case .counterweight:
                counterweight
            case .staticFullLockup:
                theme.accentFill.ignoresSafeArea()
                staticBrand(full: true)
            case .staticMark:
                theme.accentFill.ignoresSafeArea()
                staticBrand(full: false)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .environment(\.zeroOneTheme, theme)
        .environment(\.zeroOneLocalization, localization)
        .environment(\.locale, destinationLocalization?.locale ?? inheritedLocale)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(presentation == .firstReveal ? "01 Fitness and Performance" : "01")))
        .sensoryFeedback(.impact(weight: .medium), trigger: landed)
        .onChange(of: reducedExperience) { _, reduced in
            if reduced { settledForAccessibility = true }
        }
        .task(id: taskIdentity) {
            guard !didFinish else { return }
            if reducedExperience { settledForAccessibility = true }
            // Destination anchors arrive after its first layout pass.
            // A restored onboarding step without Welcome anchors uses the static fallback.
            try? await Task.sleep(for: ZeroOneLaunchExperienceTiming.holdDuration(presentation: presentation))
            guard !Task.isCancelled else { return }
            guard content == .counterweight else {
                finishOnce()
                return
            }

            withAnimation(ZOMotion.brace(ZOMotion.micro)) {
                brace = 1
                brandDip = 4
            }
            try? await Task.sleep(for: .seconds(ZOMotion.micro))
            guard !Task.isCancelled else { return }

            withAnimation(ZOMotion.carry(ZOMotion.beat)) {
                fieldProgress = 1
                fieldTopOvershoot = 6
                brandProgress = 1.02
                brandDip = 0
            }
            try? await Task.sleep(for: .seconds(ZOMotion.beat))
            guard !Task.isCancelled else { return }

            withAnimation(ZOMotion.land(ZOMotion.quick)) {
                fieldTopOvershoot = 0
                brandProgress = 1
                landed = true
            }
            try? await Task.sleep(for: .seconds(ZOMotion.tick))
            guard !Task.isCancelled else { return }
            withAnimation(ZOMotion.crossfade(panel: true)) {
                labelOpacity = 1
            }
            try? await Task.sleep(for: .seconds(ZOMotion.quick))
            guard !Task.isCancelled else { return }
            finishOnce()
        }
    }

    @ViewBuilder
    private var counterweight: some View {
        if let brandTarget, let actionTarget {
            let field = fieldView(actionTarget: actionTarget)
            ZStack {
                brandView(target: brandTarget)
                    .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: theme.colorScheme))
                field
                brandView(target: brandTarget)
                    .foregroundStyle(ZOColor.Swatch.yellow.on)
                    .mask(field)
                actionLabel
                    .foregroundStyle(theme.onAccent)
                    .position(x: actionTarget.midX, y: actionTarget.midY)
                    .opacity(labelOpacity)
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
    }

    @ViewBuilder
    private var actionLabel: some View {
        if actionCopy == .continueSetup {
            Text(verbatim: localization.string(actionCopy.rawValue))
                .zoThemeText(.primaryButton)
        } else {
            Text(verbatim: localization.string(actionCopy.rawValue))
                .zoText(.section)
        }
    }

    private func fieldView(actionTarget: CGRect) -> some View {
        let full = CGRect(
            x: -safeAreaInsets.leading,
            y: -safeAreaInsets.top,
            width: containerSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: containerSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        let braced = full.insetBy(dx: 8 * brace, dy: 8 * brace)
        let bounds = CGRect(
            x: interpolate(braced.minX, actionTarget.minX, fieldProgress),
            y: interpolate(braced.minY, actionTarget.minY, fieldProgress) + fieldTopOvershoot,
            width: interpolate(braced.width, actionTarget.width, fieldProgress),
            height: interpolate(braced.height, actionTarget.height, fieldProgress) - fieldTopOvershoot
        )
        let radius = interpolate(0, ZOThemeComponentShape(theme: theme.designTheme, role: .button, radius: ZORadius.button).resolvedRadius, fieldProgress) + 39 * brace * (1 - fieldProgress)

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.accentFill)
            .frame(width: max(1, bounds.width), height: max(1, bounds.height))
            .position(x: bounds.midX, y: bounds.midY)
            .frame(width: containerSize.width, height: containerSize.height)
    }

    @ViewBuilder
    private func carriedBrand(target: CGRect) -> some View {
        if brandComposition == .mark {
            Image("ZeroOneSplashLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: target.width, height: target.height)
        } else {
            HStack(alignment: .center, spacing: ZOSpace.m) {
                Image("ZeroOneSplashLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                Text("FITNESS\n& PERFORMANCE")
                    .zoText(.caption)
            }
            .fixedSize()
        }
    }

    private func brandView(target: CGRect) -> some View {
        let scale = interpolate(1.42, 1, brandProgress)
        let center = CGPoint(
            x: interpolate(containerSize.width / 2, target.midX, brandProgress),
            y: interpolate(containerSize.height * 0.5, target.midY, brandProgress) + brandDip
        )
        return carriedBrand(target: target)
            .scaleEffect(scale)
            .position(center)
            .frame(width: containerSize.width, height: containerSize.height)
    }

    private func staticBrand(full: Bool) -> some View {
        HStack(alignment: .center, spacing: ZOSpace.m) {
            Image("ZeroOneSplashLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: full ? 58 : 110, height: full ? 58 : 110)
            if full {
                Text("FITNESS\n& PERFORMANCE")
                    .zoText(.caption)

            }
        }
        .fixedSize()
        .scaleEffect(full ? 1.42 : 1)
        .foregroundStyle(ZOColor.Swatch.yellow.on)
        .padding(.horizontal, 28)
    }

    private func finishOnce() {
        guard !didFinish else { return }
        didFinish = true
        onFinished()
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}
