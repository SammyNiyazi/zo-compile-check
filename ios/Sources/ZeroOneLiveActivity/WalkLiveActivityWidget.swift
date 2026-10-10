import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Study 36: the walk or run as its own Live Activity. Time, distance, pace and
/// steps; Pause and Resume in place, End opens 01 (which asks before finishing).
struct WalkLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            WalkActivityLockScreen(state: context.state, attributes: context.attributes)
                .widgetURL(DailyWidgetRoute.walk.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WalkActivityTop(state: context.state, attributes: context.attributes, scheme: .dark)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WalkActivityBody(state: context.state, attributes: context.attributes, scheme: .dark, island: true)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    WalkActivityMark(height: 15)
                    WalkActivityGlyph(state: context.state, size: 15)
                }
                .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
            } compactTrailing: {
                Group {
                    if context.state.isLive {
                        WalkElapsed(state: context.state, compact: true)
                    } else {
                        Image(systemName: context.state.phase == .saved ? "checkmark" : "pause.fill")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            } minimal: {
                Group {
                    if context.state.phase == .paused {
                        Image(systemName: "pause.fill").font(.system(size: 16, weight: .medium))
                    } else {
                        WalkActivityGlyph(state: context.state, size: 16)
                    }
                }
                .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
            }
            .widgetURL(DailyWidgetRoute.walk.url)
            .keylineTint(nil)
        }
    }
}

private struct WalkActivityMark: View {
    let height: CGFloat
    var body: some View {
        Image("01-mark-warm-white-approved-4096").renderingMode(.template).resizable().scaledToFit()
            .frame(width: height * 1.6, height: height)
            .accessibilityHidden(true)
    }
}

/// The steady jogging figure on every surface; no GPS shows the slashed pin.
private struct WalkActivityGlyph: View {
    let state: WalkActivityAttributes.ContentState
    let size: CGFloat
    var body: some View {
        if state.phase == .noGPS {
            Image(systemName: "location.slash").font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(Color.orange)
                .accessibilityLabel(state.localization.string("No GPS"))
        } else {
            Image("01.jog").renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct WalkElapsed: View {
    let state: WalkActivityAttributes.ContentState
    let compact: Bool
    var designTheme: ZOTheme = .core
    var scheme: ColorScheme = .dark
    var island = true

    private var frozen: String? {
        guard let seconds = state.frozenSeconds else { return nil }
        return WorkoutActivityFrozenElapsed(version: 1, seconds: TimeInterval(seconds), observedAt: .now, state: .paused)
            .clockText(language: state.displayLanguage)
    }

    private var text: Text {
        if let frozen { return Text(frozen) }
        return Text(timerInterval: state.elapsedAnchor...state.elapsedAnchor.addingTimeInterval(24 * 3600),
                    countsDown: false, showsHours: true)
    }

    var body: some View {
        Group {
            if compact {
                text.zoProofText(.label, size: 15, lineHeight: 20, weight: 600, width: 85, tabular: true)
                    .frame(width: 39, alignment: .trailing)
            } else {
                text.zoThemeText(.metric, resolvedSpec: ZOWidgetHeroTypography.timerSpec(for: designTheme),
                                 effects: ZOWidgetHeroTypography.timerEffects(for: designTheme, scheme: scheme, island: island),
                                 designTheme: designTheme, colorScheme: scheme)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .environment(\.locale, state.displayLanguage.locale)
        .accessibilityLabel(state.localization.string("Duration"))
    }
}

private struct WalkActivityTop: View {
    let state: WalkActivityAttributes.ContentState
    let attributes: WalkActivityAttributes
    let scheme: ColorScheme
    private var title: String { state.localization.string(attributes.kind == "run" ? "Run" : "Walk") }
    private var gps: String? {
        switch state.phase {
        case .finding: state.localization.string("Finding GPS")
        case .noGPS: state.localization.string("No GPS")
        case .paused: state.localization.string("Paused")
        case .saving: state.localization.string("Saving")
        case .saved: state.localization.string("Saved")
        case .recording: state.distanceIncomplete ? state.localization.string("GPS gaps") : nil
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            WalkActivityMark(height: 15)
            Text(title).zoProofText(.caption, size: 13, lineHeight: 18, weight: 600).lineLimit(1)
            if let gps {
                Text(gps).zoText(.mini).opacity(0.7).lineLimit(1)
            }
        }
        .foregroundStyle(state.displayTheme.palette(dark: scheme == .dark)?.inkPrimary
                         ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme))
    }
}

private struct WalkActivityBody: View {
    let state: WalkActivityAttributes.ContentState
    let attributes: WalkActivityAttributes
    let scheme: ColorScheme
    let island: Bool
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var themed: ZOPalette? { state.displayTheme.palette(dark: scheme == .dark) }
    private var ink: Color { themed?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme) }
    private var secondary: Color { themed?.inkSecondary ?? ZOColor.resolved(ZOColor.inkSecondary, in: scheme) }
    private var buttonFill: Color { themed?.surface3 ?? ZOColor.resolved(ZOColor.surface3, in: scheme) }
    private var locale: Locale { state.displayLanguage.locale }

    private var distance: String {
        guard let metres = state.distanceMetres else { return "–" }
        return (metres / 1000).formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                WalkElapsed(state: state, compact: false, designTheme: state.displayTheme, scheme: scheme, island: island)
                Spacer(minLength: 0)
                if state.isLive {
                    Button(intent: PauseWalkIntent(sessionID: attributes.sessionID)) {
                        Image(systemName: "pause.fill").font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(buttonFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.localization.string("Pause"))
                } else if state.phase == .paused {
                    Button(intent: ResumeWalkIntent(sessionID: attributes.sessionID)) {
                        Text(state.localization.string("Resume")).zoProofText(.label, size: 15, lineHeight: 20, weight: 600)
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(buttonFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Link(destination: DailyWidgetRoute.walk.url) {
                        Text(state.localization.string("End")).zoProofText(.label, size: 15, lineHeight: 20, weight: 600)
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(buttonFill, in: Capsule())
                    }
                }
            }
            .contentTransition(reduceMotion || dimmed ? .opacity : .numericText())
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(distance, unit: "km", label: "Distance", faded: state.distanceMetres == nil || state.distanceIncomplete)
                if let pace = state.paceText { stat(pace, unit: "/km", label: "Pace", faded: state.distanceIncomplete) }
                if let steps = state.steps {
                    stat(steps.formatted(.number.locale(locale)), unit: nil, label: "Steps", faded: false)
                }
            }
        }
        .foregroundStyle(ink)
        .environment(\.locale, locale)
    }

    private func stat(_ value: String, unit: String?, label: String, faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).zoProofText(.label, size: 17, lineHeight: 22, weight: 600, tabular: true)
                if let unit { Text(state.localization.string(unit)).zoText(.mini).foregroundStyle(secondary) }
            }
            .opacity(faded ? 0.45 : 1)
            Text(state.localization.string(label)).zoText(.mini).foregroundStyle(secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WalkActivityLockScreen: View {
    let state: WalkActivityAttributes.ContentState
    let attributes: WalkActivityAttributes
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var dimmed
    private var scheme: ColorScheme { dimmed ? .dark : colorScheme }
    private var themed: ZOPalette? { state.displayTheme.palette(dark: scheme == .dark) }
    private var background: Color {
        if dimmed { return .black }
        if scheme == .dark { return themed?.surface1 ?? ZOColor.resolved(ZOColor.surface1, in: .dark) }
        return themed?.canvas ?? ZOColor.resolved(ZOColor.canvas, in: .light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WalkActivityTop(state: state, attributes: attributes, scheme: scheme)
            WalkActivityBody(state: state, attributes: attributes, scheme: scheme, island: false)
        }
        .padding(14)
        .activityBackgroundTint(background)
        .activitySystemActionForegroundColor(themed?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme))
    }
}
