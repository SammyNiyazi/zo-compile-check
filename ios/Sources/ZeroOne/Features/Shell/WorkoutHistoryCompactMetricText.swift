import CoreText
import SwiftUI

/// History proof40 .zo-metric has inline font-size:26px only.
/// Keep the shared metric's inherited line height (36; Freak38), axes,
/// tracking, tabular digits and effects. No data, timing or actions live here.
private struct WorkoutHistoryCompactMetricText: ViewModifier {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var compactSpec: ZOThemeTextSpec {
        var spec = ZOThemeTypography.spec(for: theme.designTheme, role: .metric)
        spec.size = 26
        return spec
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let spec = compactSpec
        if let font = resolvedFont(spec) {
            let face = Font(font)
            let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            let scale = CTFontGetSize(font) / spec.size
            let effects = ZOThemeTextEffects.resolve(designTheme: theme.designTheme,
                role: .metric, colorScheme: theme.colorScheme)
            content
                .font(spec.tabular ? face.monospacedDigit() : face)
                .tracking(spec.tracking)
                .lineSpacing(max(0, spec.lineHeight * scale - natural))
                .textCase(spec.uppercase ? .uppercase : nil)
                .modifier(WorkoutHistoryCompactMetricEffects(effects: effects))
        } else {
            // Readable failure only; the throwing font contract failed.
            // This fallback cannot establish theme-face parity.
            content.zoProofText(.metric, size: 26, lineHeight: spec.lineHeight, width: 85, tabular: true)
        }
    }

    private func resolvedFont(_ spec: ZOThemeTextSpec) -> CTFont? {
        do { return try spec.font(for: dynamicTypeSize) }
        catch {
            assertionFailure("History theme font unavailable; readable fallback is not theme parity: \(error)")
            return nil
        }
    }
}

/// The shared effects renderer is private. Metric resolve has at most one
/// shadow: Retro dark0/0/10glowB55%; Retro light uses ink and no shadow.
/// Reuse its exact values and layer a noninteractive hidden glyph copy.
private struct WorkoutHistoryCompactMetricEffects: ViewModifier {
    let effects: ZOThemeTextEffects

    @ViewBuilder
    private func face(_ content: Content) -> some View {
        if let foreground = effects.foreground { content.foregroundStyle(foreground) }
        else { content }
    }

    func body(content: Content) -> some View {
        face(content).background {
            if let shadow = effects.shadows.first {
                content.foregroundStyle(shadow.color)
                    .blur(radius: shadow.cssBlur)
                    .offset(x: shadow.x, y: shadow.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func zoHistoryCompactMetricText() -> some View {
        modifier(WorkoutHistoryCompactMetricText())
    }
}
