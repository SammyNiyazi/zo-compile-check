import CoreText
import SwiftUI

struct OutdoorThemeSummaryFacts: View {
    let seconds: TimeInterval
    let meters: Double?
    let steps: Int?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            fact("outdoor.design.time", OutdoorPresentation.duration(seconds), unit: "")
            let distance = OutdoorPresentation.distance(meters, locale: localization.locale)
            fact("outdoor.design.distance", distance, unit: distance == "—" ? "" : "km")
            fact("outdoor.design.steps", OutdoorPresentation.steps(steps, locale: localization.locale), unit: "")
        }
    }

    private func fact(_ key: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localization.string(key)).zoThemeText(.caption)
                .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                OutdoorCompactThemeMetric(value: value)
                if !unit.isEmpty { Text(unit).zoProofText(.body, size: 15, lineHeight: 20, weight: 500).foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary) }
            }
            .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// Component-only adaptation of the shared public metric specification.
// proof.html35 overrides m-facts size/line height; shared fonts, axes, effects,
// scaling policy and failure behavior remain authoritative. No facts are computed here.
private struct OutdoorCompactThemeMetric: View {
    let value: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var specification: ZOThemeTextSpec {
        var result = ZOThemeTypography.spec(for: theme.designTheme, role: .metric)
        result.size = 26
        result.lineHeight = 30
        return result
    }

    @ViewBuilder var body: some View {
        let spec = specification
        let effects = ZOThemeTextEffects.resolve(designTheme: theme.designTheme,
            role: .metric, colorScheme: theme.colorScheme)
        if let font = resolvedFont(spec) {
            face(font: font, spec: spec)
                .foregroundStyle(effects.foreground ?? AnyShapeStyle(theme.textPrimary))
                .background {
                    ZStack {
                        // Independent glyph copies preserve CSS shadow stacking.
                        ForEach(Array(effects.shadows.enumerated().reversed()), id: \.offset) { item in
                            face(font: font, spec: spec)
                                .foregroundStyle(item.element.color)
                                .blur(radius: item.element.cssBlur)
                                .offset(x: item.element.x, y: item.element.y)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
        } else {
            // Readable Core fallback is failure behavior, never theme parity.
            Text(value).zoProofText(.metric, size: 26, lineHeight: 30, tabular: true)
                .foregroundStyle(theme.textPrimary)
        }
    }

    private func face(font: CTFont, spec: ZOThemeTextSpec) -> some View {
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let scale = CTFontGetSize(font) / spec.size
        let resolved = Font(font)
        return Text(value)
            .font(spec.tabular ? resolved.monospacedDigit() : resolved)
            .tracking(spec.tracking)
            .lineSpacing(max(0, spec.lineHeight * scale - natural))
            .textCase(spec.uppercase ? .uppercase : nil)
    }

    private func resolvedFont(_ spec: ZOThemeTextSpec) -> CTFont? {
        do { return try spec.font(for: dynamicTypeSize) }
        catch {
            assertionFailure("Outdoor compact theme font unavailable; Core fallback is not theme parity: \(error)")
            return nil
        }
    }
}
