import ActivityKit
import SwiftUI
import WidgetKit

private struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityLockScreenSurface(state: context.state, title: context.attributes.workoutTitle, stale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        WorkoutActivityMark(height: 15)
                            .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                        Text(context.isStale && context.state.phase == .rest
                             ? context.state.localization.string("Ready for next set") : context.state.phaseTitle)
                            .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                            .lineLimit(1)
                    }.foregroundStyle(context.state.displayTheme.palette(dark: true)?.inkPrimary
                                      ?? ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.localization.format("%1$lld/%2$lld sets", .integer(context.state.completedSets), .integer(context.state.totalSets)))
                        .zoText(.mini).monospacedDigit()
                        .foregroundStyle(context.state.displayTheme.palette(dark: true)?.inkSecondary
                                         ?? ZOColor.resolved(ZOColor.inkSecondary, in: .dark))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutActivityCard(state: context.state, title: context.attributes.workoutTitle,
                                        stale: context.isStale, island: true)
                }
            } compactLeading: {
                WorkoutActivityMark(height: 15)
                    .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                    .accessibilityLabel(context.state.localization.string("Zero One workout"))
            } compactTrailing: {
                WorkoutActivityCompact(state: context.state, stale: context.isStale)
                    .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            } minimal: {
                if context.state.phase == .paused || context.state.phase == .saving {
                    Image(systemName: context.state.phase == .paused ? "pause.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                        .accessibilityLabel(context.state.phaseTitle)
                } else {
                    WorkoutActivityMark(height: 16)
                        .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
                        .accessibilityLabel(context.state.phaseTitle)
                }
            }
            // Study 36: the system owns the Island outline.
            .keylineTint(nil)
        }
    }
}

/// Resolve the transported presentation theme at the actual Lock Screen host.
private struct WorkoutActivityLockScreenSurface: View {
    let state: WorkoutActivityAttributes.ContentState
    let title: String
    let stale: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var dimmed
    private var scheme: ColorScheme { dimmed ? .dark : colorScheme }
    private var themed: ZOPalette? { state.displayTheme.palette(dark: scheme == .dark) }
    private var background: Color {
        if dimmed { return .black }
        if scheme == .dark { return themed?.surface1 ?? ZOColor.resolved(ZOColor.surface1, in: .dark) }
        return themed?.canvas ?? ZOColor.resolved(ZOColor.canvas, in: .light)
    }

    @ViewBuilder private var card: some View {
        if dimmed {
            // Study36 .aod brightness(.72): multiply the composed card RGB,
            // including hero gradients/shadows, marks, text and the rail.
            WorkoutActivityCard(state: state, title: title, stale: stale, island: false)
                .compositingGroup()
                .colorMultiply(Color(.sRGB, red: 0.72, green: 0.72, blue: 0.72, opacity: 1))
        } else {
            WorkoutActivityCard(state: state, title: title, stale: stale, island: false)
        }
    }

    var body: some View {
        card
            .padding(14)
            .activityBackgroundTint(background)
            .activitySystemActionForegroundColor(themed?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme))
    }
}

/// Uses the approved vector asset; target membership is owned by integration.
private struct WorkoutActivityMark: View {
    let height: CGFloat
    var body: some View {
        Image("01-mark-warm-white-approved-4096").renderingMode(.template).resizable().scaledToFit()
            .frame(width: height * 1.6, height: height)
            .accessibilityHidden(true)
    }
}

private struct WorkoutActivityCard: View {
    let state: WorkoutActivityAttributes.ContentState
    let title: String
    let stale: Bool
    let island: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var scheme: ColorScheme { island || dimmed ? .dark : colorScheme }
    private var themed: ZOPalette? { state.displayTheme.palette(dark: scheme == .dark) }
    private var ink: Color { themed?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme) }
    private var secondary: Color {
        let color = themed.map { contrast == .increased ? $0.inkPrimary : $0.inkSecondary }
            ?? ZOColor.resolved(contrast == .increased ? ZOColor.inkPrimary : ZOColor.inkSecondary, in: scheme)
        return color
    }
    private var track: Color {
        if let themed { return island || contrast == .increased ? themed.separatorStrong : themed.surface3 }
        return ZOColor.resolved(island || contrast == .increased ? ZOColor.separatorStrong : ZOColor.surface3, in: scheme)
    }
    private var restAccent: Color { themed?.accent ?? state.accent.fill }
    private var restInsetEdge: Color? {
        guard scheme == .light, !dimmed else { return nil }
        switch state.displayTheme {
        case .core: return state.accent.swatch.edge(in: scheme)
        case .retro: return Color(zoHex: 0x2A0E1E, alpha: 0.16)
        case .freak: return Color(zoHex: 0x050506, alpha: 0.30)
        case .princess: return Color(zoHex: 0x35122B, alpha: 0.14)
        }
    }
    private var phase: String {
        stale && state.phase == .rest ? state.localization.string("Ready for next set") : state.phaseTitle
    }
    /// Island: "Goblet squat · Last 16 × 10" (no room for the full coach line).
    private var exerciseLine: String {
        let name = state.phase == .warmUp
            ? state.localization.format("Next: %1$@", .text(state.exerciseName)) : state.exerciseName
        if island, let last = state.lastTimeShort { return name + " · " + last }
        return name
    }
    /// Lock Screen: "Set 1/2 · Last time 16 kg × 10. Target today: 8–12 reps."
    private var setLine: String {
        let set = state.localization.format("Set %1$lld/%2$lld", .integer(state.currentSet), .integer(state.plannedSetsForExercise))
        if !island, let coach = state.coachLine { return set + " · " + coach }
        return set
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !island {
                HStack(spacing: 6) {
                    WorkoutActivityMark(height: 15)
                        .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: scheme))
                    Text(title).zoProofText(.caption, size: 13, lineHeight: 18, weight: 600).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(state.localization.format("%1$lld/%2$lld sets", .integer(state.completedSets), .integer(state.totalSets)))
                        .zoText(.mini).monospacedDigit().foregroundStyle(secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                if state.phase == .rest, !stale, let end = state.restEndsAt {
                    WorkoutRestCountdown(end: end, language: state.displayLanguage, compact: false,
                                         designTheme: state.displayTheme, scheme: scheme, island: island)
                } else if let elapsed = state.pausedElapsed,
                          let seconds = elapsed.wholeSeconds,
                          let text = elapsed.clockText(language: state.displayLanguage) {
                    let timer = Text(text)
                        .zoThemeText(.metric, resolvedSpec: ZOWidgetHeroTypography.timerSpec(for: state.displayTheme),
                                     effects: ZOWidgetHeroTypography.timerEffects(for: state.displayTheme, scheme: scheme, island: island),
                                     designTheme: state.displayTheme, colorScheme: scheme)
                    Group {
                        if state.displayTheme == .retro {
                            timer.fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: island ? 104 : 110, alignment: .leading)
                        } else {
                            timer.frame(width: island ? 104 : 110, alignment: .leading)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel(state.localization.string("Duration"))
                    .accessibilityValue(SharedSurfaceLocalization(language: state.displayLanguage).seconds(seconds))
                } else if state.phase == .paused, let seconds = state.pausedRestSeconds, seconds > 0 {
                    Text(SharedSurfaceLocalization(language: state.displayLanguage).remainingSeconds(seconds))
                        .zoThemeText(.metric, resolvedSpec: ZOWidgetHeroTypography.timerSpec(for: state.displayTheme),
                                     effects: ZOWidgetHeroTypography.timerEffects(for: state.displayTheme, scheme: scheme, island: island),
                                     designTheme: state.displayTheme, colorScheme: scheme)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(phase).zoProofText(.title, size: 24, lineHeight: 30, weight: 600)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentTransition(reduceMotion || dimmed ? .opacity : .numericText(countsDown: state.phase == .rest))
            .animation(dimmed ? nil : (reduceMotion ? ZOMotion.crossfade() : ZOMotion.carry(0.24)), value: state.phase)
            if !stale, let interval = state.restCountdownInterval {
                WorkoutNativeRestLineExperiment(interval: interval, accent: restAccent,
                    track: track, normalInsetEdge: restInsetEdge, dimmed: dimmed)
            } else {
                WorkoutActivityRail(completed: state.completedSets, total: state.totalSets, ink: ink,
                                    track: track)
            }
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exerciseLine)
                        .zoProofText(.caption, size: 13, lineHeight: 18, weight: 500).lineLimit(1)
                    Text(setLine)
                        .zoText(.mini).monospacedDigit().foregroundStyle(secondary).lineLimit(island ? 1 : 2)
                }
                Text(state.exerciseName).zoText(.mini).lineLimit(1)
            }
            if state.phase == .rest || state.phase == .paused {
                HStack(spacing: 6) {
                    Text(phase).zoText(.mini).foregroundStyle(secondary).lineLimit(1)
                    // Round 4: the ink pill when the saved set beat last time. No room on the Island.
                    if !island, let gain = state.gainText {
                        Text(gain)
                            .zoProofText(.caption, size: 12, lineHeight: 18, weight: 700)
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .foregroundStyle(themed?.canvas ?? ZOColor.resolved(ZOColor.canvas, in: scheme))
                            .background(ink, in: Capsule())
                    }
                }
            }
        }
        .foregroundStyle(ink)
        .environment(\.locale, state.displayLanguage.locale)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutActivityRail: View {
    let completed: Int
    let total: Int
    let ink: Color
    let track: Color
    var body: some View {
        Group {
            if total > 0, total <= 40, completed >= 0, completed <= total {
                HStack(spacing: 2) {
                    ForEach(0..<total, id: \.self) { slot in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(slot < completed ? ink : track)
                    }
                }
            } else if total > 0, completed >= 0, completed <= total {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(ink).frame(width: geometry.size.width * CGFloat(Double(completed) / Double(total)))
                    }
                }
            } else {
                Capsule().fill(track)
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}

private struct WorkoutActivityCompact: View {
    let state: WorkoutActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        Group {
            if state.phase == .rest, !stale, let end = state.restEndsAt {
                WorkoutRestCountdown(end: end, language: state.displayLanguage, compact: true)
            } else if state.phase == .paused || state.phase == .saving {
                Image(systemName: state.phase == .paused ? "pause.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .accessibilityLabel(state.phaseTitle)
            } else {
                Text(state.localization.format("Set %1$lld", .integer(state.currentSet)))
                    .zoProofText(.label, size: 15, lineHeight: 20, weight: 600, width: 85, tabular: true)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: 52)
                    .accessibilityLabel(stale && state.phase == .rest
                        ? state.localization.string("Ready for next set") : state.phaseTitle)
            }
        }
    }
}

private struct WorkoutRestCountdown: View {
    let end: Date
    let language: AppLanguage
    let compact: Bool
    var designTheme: ZOTheme = .core
    var scheme: ColorScheme = .dark
    var island = false

    private var timer: Text {
        Text(timerInterval: min(Date.now, end)...end, countsDown: true, showsHours: false)
    }

    @ViewBuilder private var styledTimer: some View {
        if compact {
            // Compact/minimal stay Instrument Sans; no selected-face/effect API.
            timer.zoProofText(.label, size: 15, lineHeight: 20, weight: 600, width: 85, tabular: true)
                .frame(width: 31, alignment: .leading)
        } else if designTheme == .retro {
            hero.fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: island ? 86 : 92, alignment: .leading)
        } else {
            hero.frame(width: island ? 86 : 92, alignment: .leading)
        }
    }

    private var hero: some View {
        timer.zoThemeText(.metric, resolvedSpec: ZOWidgetHeroTypography.timerSpec(for: designTheme),
                         effects: ZOWidgetHeroTypography.timerEffects(for: designTheme, scheme: scheme, island: island),
                         designTheme: designTheme, colorScheme: scheme)
    }

    var body: some View {
        styledTimer.lineLimit(1).minimumScaleFactor(0.7)
            .environment(\.locale, language.locale)
            .accessibilityLabel(AppLocalization(language: language).string("Rest time remaining"))
            .accessibilityValue(Text(timerInterval: min(Date.now, end)...end, countsDown: true, showsHours: false))
    }
}

@main
struct ZeroOneLiveActivityWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivityWidget()
        DailyStepsWidget()
        DailyCaloriesWidget()
        DailyWaterWidget()
        DailyTogetherWidget()
    }
}



