import SwiftUI
import WidgetKit

struct DailyWidgetPalette {
    let dark: Bool
    var accent: AccentPreference = .yellow
    var increasedContrast = false
    var designTheme: ZOTheme = .core

    private var themed: ZOPalette? { designTheme.palette(dark: dark) }
    var background: Color { themed?.canvas ?? ZOColor.resolved(ZOColor.canvas, in: dark ? .dark : .light) }
    var ink: Color { themed?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: dark ? .dark : .light) }
    var secondary: Color { increasedContrast ? ink : (themed?.inkSecondary ?? ZOColor.resolved(ZOColor.inkSecondary, in: dark ? .dark : .light)) }
    var track: Color {
        if let themed { return increasedContrast ? themed.separatorStrong : themed.surface3 }
        return ZOColor.resolved(increasedContrast ? ZOColor.separatorStrong : ZOColor.surface3, in: dark ? .dark : .light)
    }
    var action: Color { themed?.accent ?? accent.fill }
    var accentForeground: Color { themed?.inkPrimary ?? accent.foreground(in: dark ? .dark : .light) }
    var onAccent: Color { themed?.onAccent ?? accent.swatch.on }
}

/// One visual component for actual widgets and Profile previews. Actions are supplied by the host.
struct DailyWidgetFace<WaterActions: View, WalkAction: View>: View {
    let kind: DailyWidgetSnapshot.Kind
    let size: DailyWidgetSize
    let options: DailyWidgetOptions
    let snapshot: DailyWidgetSnapshot?
    var waterHasUndo = false
    var accent: AccentPreference? = nil
    var language: AppLanguage? = nil
    var designTheme: ZOTheme = .core
    @ViewBuilder let waterActions: WaterActions
    @ViewBuilder let walkAction: WalkAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var environmentLocale
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: DailyWidgetPalette { .init(dark: colorScheme == .dark, accent: accent ?? snapshot?.accent ?? .yellow, increasedContrast: contrast == .increased, designTheme: designTheme) }
    private var localization: AppLocalization {
        AppLocalization(language: language ?? snapshot?.displayLanguage
            ?? AppLanguage.supportedLanguage(identifier: environmentLocale.identifier) ?? .english)
    }
    private var display: SharedSurfaceLocalization { .init(language: localization.language) }


    var body: some View {
        Group {
            switch kind {
            case .steps:
                if size == .small { steps }
                else {
                    HStack(spacing: 14) {
                        steps
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label { Text(localization.string("Latest walk")) } icon: { ZOAppIcon("01.jog") }.zoText(.label).labelStyle(ZOIconLabelStyle())
                            if let walk = snapshot?.latestWalk {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(walk.distanceText(using: localization)).zoProofText(.metric, size: 26, lineHeight: 30, weight: 700, width: 85, tabular: true)
                                    Text(walk.durationText(using: localization)).zoText(.caption).foregroundStyle(palette.secondary)
                                    Text(walk.finishedAt, format: .dateTime.month(.abbreviated).day().locale(localization.locale)).zoText(.mini).foregroundStyle(palette.secondary)
                                    if walk.distanceIncomplete {
                                        Text(localization.string("Distance incomplete")).zoText(.mini).foregroundStyle(palette.secondary)
                                    }
                                }.privacySensitive()
                            } else {
                                Text(localization.string("Make room to move.")).zoText(.caption).foregroundStyle(palette.secondary)
                            }
                            Spacer(minLength: 0)
                            if options.showsWalk { walkAction }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .calories:
                calories(compact: size == .small)
            case .water:
                if size == .small {
                    VStack(alignment: .leading, spacing: 6) { water; Spacer(minLength: 0); waterActions }
                } else {
                    HStack(alignment: .bottom, spacing: 14) {
                        water
                        VStack(spacing: 8) { waterActions }.frame(maxWidth: .infinity)
                    }
                }
            case .together:
                if size == .large {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(localization.string("Today")).zoText(.section)
                        ForEach(options.orderedMetrics) { metric in
                            Divider()
                            switch metric {
                            case .steps:
                                HStack { steps; if options.showsWalk { walkAction } }
                            case .calories: calories(compact: false)
                            case .water: HStack(alignment: .bottom) { water; waterActions }
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: typeSize.isAccessibilitySize ? 7 : 12) {
                        ForEach(options.orderedMetrics) { metric in
                            if metric != options.orderedMetrics.first { Divider() }
                            switch metric {
                            case .steps: steps
                            case .calories: calories(compact: true)
                            case .water:
                                VStack(alignment: .leading, spacing: 6) {
                                    water
                                    Spacer(minLength: 0)
                                    waterActions
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.locale, localization.locale)
        .foregroundStyle(palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compact: Bool { kind == .together && size == .medium }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            if size == .small {
                DailyWidgetGoalFace(title: "Steps", symbol: "shoeprints.fill", metric: snapshot?.steps,
                                    target: snapshot?.stepGoal, liters: false, palette: palette, language: localization.language)
            } else {
                DailyWidgetNumber(title: "Steps", symbol: "shoeprints.fill", metric: snapshot?.steps,
                                  unit: "", source: "Apple Health", compact: compact, accent: palette.accent, language: localization.language, designTheme: designTheme)
                targetProgress(metric: snapshot?.steps, target: snapshot?.stepGoal, label: "Step target")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var water: some View {
        VStack(alignment: .leading, spacing: 6) {
            if size == .small && waterHasUndo {
                DailyWidgetNumber(title: "Water", symbol: "drop", metric: snapshot?.waterMilliliters,
                                  unit: "L", source: "Logged in 01", compact: true, liters: true,
                                  showsProvenance: false, accent: palette.accent, language: localization.language, designTheme: designTheme)
            } else if size == .small {
                DailyWidgetGoalFace(title: "Water", symbol: "drop", metric: snapshot?.waterMilliliters,
                                    target: snapshot?.waterGoalMilliliters, liters: true, palette: palette, language: localization.language)
            } else {
                DailyWidgetNumber(title: "Water", symbol: "drop", metric: snapshot?.waterMilliliters,
                                  unit: "L", source: "Logged in 01", compact: compact, liters: true,
                                  accent: palette.accent, language: localization.language, designTheme: designTheme)
                targetProgress(metric: snapshot?.waterMilliliters, target: snapshot?.waterGoalMilliliters, label: "Water goal")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder
    private func calories(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            if options.calories != .burned {
                VStack(alignment: .leading, spacing: 6) {
                    DailyWidgetNumber(title: "Eaten", symbol: "fork.knife", metric: snapshot?.eatenKilocalories,
                                      unit: "kcal", source: "Logged in 01", compact: compact, accent: palette.accent, language: localization.language, designTheme: designTheme)
                    targetProgress(metric: snapshot?.eatenKilocalories, target: snapshot?.foodGoalKilocalories, label: "Food calorie target")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if options.calories == .both { Divider() }
            if options.calories != .eaten {
                DailyWidgetNumber(title: "Burned", symbol: "flame", metric: snapshot?.burnedKilocalories,
                                  unit: "kcal", source: "Apple Health · active only", compact: compact, accent: palette.accent, language: localization.language, designTheme: designTheme)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func targetProgress(metric: DailyWidgetSnapshot.Metric?, target: Int?, label: String) -> some View {
        if let target, let metric, let value = metric.value,
           let progress = WidgetMetricProgress(metric: metric, target: target) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.format("of %1$lld target", .integer(target))).zoText(.mini).foregroundStyle(palette.secondary)
                DailyWidgetProgress(fraction: progress.fraction, palette: palette)
                    .accessibilityLabel(localization.string(label))
                    .accessibilityValue(localization.format("%1$@ of %2$lld", .text(display.number(value)), .integer(target)))
            }.privacySensitive()
        }
    }
}

private struct DailyWidgetNumber: View {
    let title: String
    let symbol: String
    let metric: DailyWidgetSnapshot.Metric?
    let unit: String
    let source: String
    let compact: Bool
    var liters = false
    var showsProvenance = true
    var showsTitle = true
    var accent: AccentPreference = .yellow
    var language: AppLanguage = .english
    var designTheme: ZOTheme = .core
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    private var localization: AppLocalization { AppLocalization(language: language) }

    private var palette: DailyWidgetPalette { .init(dark: colorScheme == .dark, accent: accent, increasedContrast: contrast == .increased, designTheme: designTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if showsTitle {
            Label(localization.string(title), systemImage: symbol)
                .zoText(.caption).labelStyle(ZOIconLabelStyle())
                .foregroundStyle(palette.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(DailyWidgetFormatting.value(metric, liters: liters, localization: localization))
                    .zoProofText(.metric, size: 26, lineHeight: 30, weight: 700, width: 85, tabular: true)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty && !(compact && typeSize.isAccessibilitySize) {
                    Text(localization.string(unit)).zoText(.mini).foregroundStyle(palette.secondary)
                }
            }
            if let state = DailyWidgetFormatting.stateText(metric, localization: localization) {
                Text(state).zoText(.mini).foregroundStyle(palette.secondary).lineLimit(2)
            }
            if showsProvenance && (!compact || !typeSize.isAccessibilitySize) {
                Text(localization.string(source)).zoText(.mini).foregroundStyle(palette.secondary).lineLimit(2)
            }
            if let asOf = metric?.asOf, !compact, showsProvenance {
                Text(localization.format("As of %1$@", .text(asOf.formatted(.dateTime.hour().minute().locale(localization.locale)))))
                    .zoText(.mini).foregroundStyle(palette.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let value = DailyWidgetFormatting.value(metric, liters: liters, localization: localization)
        let status = DailyWidgetFormatting.stateText(metric, localization: localization)
        let time = metric?.asOf.map { localization.format("As of %1$@.", .text($0.formatted(.dateTime.hour().minute().locale(localization.locale)))) }
        return [localization.format("%1$@, %2$@ %3$@.", .text(localization.string(title)), .text(value), .text(localization.string(liters ? "litres" : unit))), localization.string(source), status, time].compactMap { $0 }.joined(separator: " ")
    }
}

struct DailyWidgetActionLabel: View {
    let title: String
    let symbol: String
    var prominent = true
    var accent: AccentPreference = .yellow
    var language: AppLanguage? = nil
    var designTheme: ZOTheme = .core
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = DailyWidgetPalette(dark: colorScheme == .dark, accent: accent, designTheme: designTheme)
        Label {
            Text(AppLocalization(language: language ?? AppLanguage.supportedLanguage(identifier: locale.identifier) ?? .english).string(title))
        } icon: {
            ZOAppIcon(symbol == "figure.walk" ? "01.jog" : symbol)
        }
            .zoProofText(.label, size: 15, lineHeight: 20, weight: 600).labelStyle(ZOIconLabelStyle()).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: ZOSpace.hitTarget)
            .padding(.horizontal, 5)
            .foregroundStyle(prominent ? palette.onAccent : palette.ink)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(prominent ? palette.action : palette.track)
                    .widgetAccentable(prominent)
            }
    }
}

extension DailyWidgetActionLabel {
    /// A typed quick-add label for both actual widgets and in-app previews.
    init(waterAmount: Int, prominent: Bool = true, accent: AccentPreference = .yellow, language: AppLanguage, designTheme: ZOTheme = .core) {
        self.init(title: AppLocalization(language: language).format("+%1$lld ml", .integer(waterAmount)),
                  symbol: "plus", prominent: prominent, accent: accent, language: language, designTheme: designTheme)
    }
}

// Overloads keep display behavior shared with hosted previews without touching
// original freshness/state rules in DailyWidgetPresentation.
extension DailyWidgetFormatting {
    static func value(_ metric: DailyWidgetSnapshot.Metric?, liters: Bool = false, localization: AppLocalization) -> String {
        guard let metric, metric.state == .available, let value = metric.value,
              value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        return SharedSurfaceLocalization(language: localization.language)
            .number(liters ? value / 1_000 : value, fractionDigits: liters ? 0 ... 2 : 0 ... 0)
    }
    static func stateText(_ metric: DailyWidgetSnapshot.Metric?, localization: AppLocalization) -> String? {
        stateText(metric).map { localization.string($0) }
    }
}


/// Presentation only. Missing, stale and invalid readings never become a goal win.
struct WidgetMetricProgress: Equatable {
    let fraction: Double
    let remaining: Double
    let reached: Bool

    init?(metric: DailyWidgetSnapshot.Metric?, target: Int?) {
        guard let target, target > 0, let metric, metric.state == .available,
              let value = metric.value, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        fraction = min(1, value / Double(target))
        remaining = max(0, Double(target) - value)
        reached = !metric.isStale && value >= Double(target)
    }
}

/// Matches Study 30's 4 pt progress geometry in the app preview and extension.
/// The host supplies the same localized label and actual value as before.
private struct DailyWidgetProgress: View {
    let fraction: Double
    let palette: DailyWidgetPalette

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: ZOStroke.progress / 2)
            shape.fill(palette.track)
                .overlay(alignment: .leading) {
                    shape.fill(palette.ink)
                        .frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: ZOStroke.progress)
        .accessibilityElement(children: .ignore)
    }
}

private struct DailyWidgetGoalFace: View {
    let title: String
    let symbol: String
    let metric: DailyWidgetSnapshot.Metric?
    let target: Int?
    let liters: Bool
    let palette: DailyWidgetPalette
    let language: AppLanguage
    private var localization: AppLocalization { AppLocalization(language: language) }
    private var progress: WidgetMetricProgress? { .init(metric: metric, target: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(palette.secondary)
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(palette.track, lineWidth: 6)
                    if let progress {
                        Circle().trim(from: 0, to: progress.fraction)
                            .stroke(palette.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90)).widgetAccentable()
                    }
                    Image(systemName: progress?.reached == true ? "checkmark" : symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(palette.ink)
                }.padding(3).frame(width: 58, height: 58).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    DailyWidgetNumber(title: title, symbol: symbol, metric: metric,
                                      unit: liters ? "L" : "", source: liters ? "Logged in 01" : "Apple Health",
                                      compact: true, liters: liters, showsProvenance: false, showsTitle: false,
                                      accent: palette.accent, language: language, designTheme: palette.designTheme)
                    if let target, progress != nil {
                        Text(liters
                             ? localization.format("of %1$@ L", .text(SharedSurfaceLocalization(language: language).number(Double(target) / 1_000, fractionDigits: 0 ... 2)))
                             : localization.format("of %1$lld target", .integer(target)))
                            .zoText(.caption).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
            }
            if let progress, !liters, metric?.isStale == false {
                Text(progress.reached ? localization.string("Goal reached")
                     : localization.format("%1$@ to go", .text(SharedSurfaceLocalization(language: language).number(progress.remaining))))
                    .zoText(.caption).foregroundStyle(progress.reached ? palette.ink : palette.secondary).lineLimit(1)
            }
        }.privacySensitive()
    }
}


