import SwiftUI
import UIKit

enum ThemeFamily: String, CaseIterable, Identifiable {
    case liquidMidnight
    case iridescentAura
    case atelier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidMidnight: "Liquid Midnight"
        case .iridescentAura: "Iridescent Aura"
        case .atelier: "Atelier"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "slick.appearancePreference"

    static func storedValue(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func resolvedColorScheme(systemColorScheme: ColorScheme) -> ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }
}

// Backward-compatible name retained for existing persisted theme values and feature bindings.
typealias ZeroOneThemeID = ThemeFamily

struct ZeroOneMaterialTokens {
    let functionalGlassTint: Color
    let contentOverlay: Color
    let elevatedShadow: Color
    let ambientAura: Color
}

struct ZeroOneThemeTokens {
    let id: ZeroOneThemeID
    let colorScheme: ColorScheme
    let accentPreference: AccentPreference
    let backgroundPrimary: Color
    let surfacePrimary: Color
    let surfaceSecondary: Color
    var surfaceTertiary: Color { palette?.surface3 ?? ZOColor.resolved(ZOColor.surface3, in: colorScheme) }
    var focus: Color { palette?.focus ?? ZOColor.resolved(ZOColor.focus, in: colorScheme) }
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let strokeSubtle: Color
    let brandGradientColors: [Color]
    let successPrimary: Color
    let successGlow: Color
    let warningPrimary: Color
    let destructivePrimary: Color
    let materials: ZeroOneMaterialTokens

    // Presentation metadata only. Legacy memberwise callers keep their core default.
    // This is never inferred from, or written over, the persisted legacy family id.
    // Always reconstruct through resolve when the theme changes; do not mutate this field.
    // A defaulted var retains the compatible synthesized memberwise initializer argument.
    var designTheme: ZOTheme = .core
    private var palette: ZOPalette? { designTheme.palette(dark: colorScheme == .dark) }
    var separatorStrong: Color { palette?.separatorStrong ?? ZOColor.resolved(ZOColor.separatorStrong, in: colorScheme) }
    var displayFont: String? { palette?.displayFont }

    // Legacy UI alias follows a final theme to prevent core-yellow leakage.
    // Fixed identity assets still use their approved colourways, independently of this adapter.
    var signalYellow: Color { palette?.accent ?? ZOColor.Swatch.yellow.fill }
    var accentFill: Color { palette?.accent ?? accentPreference.fill }
    var onAccent: Color { palette?.onAccent ?? accentPreference.swatch.on }
    var accentForeground: Color { textPrimary }
    // Accent belongs to the next-action fill. Navigation and data remain ink.
    var navigationAccent: Color { textPrimary }
    var chartAccent: Color { accentForeground }
    var disabledAccentFill: Color { surfaceTertiary }
    var disabledAccentForeground: Color { textTertiary }
    var specularWhite: Color { textPrimary }

    var spectralViolet: Color {
        accentForeground
    }

    var microSuccessPrimary: Color {
        successPrimary
    }

    // These states are not emitted by ZOPalette. Values mirror tokens.json themes.list.*.accent.
    var accentPressed: Color {
        switch designTheme {
        case .core: accentPreference.swatch.pressed
        case .retro: Color(zoHex: colorScheme == .dark ? 0xF0B932 : 0xF29F18)
        case .freak: Color(zoHex: colorScheme == .dark ? 0xC3C8CF : 0x2B2F35)
        case .princess: Color(zoHex: 0xF28AC8)
        }
    }

    var accentEdge: Color {
        guard designTheme != .core else { return accentPreference.swatch.edge(in: colorScheme) }
        guard colorScheme == .light else { return .clear }
        switch designTheme {
        case .core: return .clear
        case .retro: return Color(zoHex: 0x2A0E1E, alpha: 0.16)
        case .freak: return Color(zoHex: 0x050506, alpha: 0.30)
        case .princess: return Color(zoHex: 0x35122B, alpha: 0.14)
        }
    }

    /// Final themes-fx.css button backgrounds. Theme gradients remain in place when pressed;
    /// the opaque gradient overrides the pressed base colour in the reference cascade.
    func primaryActionBackground(pressed: Bool) -> AnyShapeStyle {
        switch designTheme {
        case .core, .princess:
            return AnyShapeStyle(pressed ? accentPressed : accentFill)
        case .retro, .freak:
            return AnyShapeStyle(LinearGradient(stops: primaryActionGradientStops,
                startPoint: .top, endPoint: .bottom))
        }
    }

    var primaryActionGradientStops: [Gradient.Stop] {
        switch designTheme {
        case .core, .princess: return []
        case .retro:
            if colorScheme == .light {
                return [.init(color: accentFill, location: 0),
                    .init(color: Color(zoHex: 0xFF8A3D), location: 0.62),
                    .init(color: Color(zoHex: 0xFF4D6D), location: 1)]
            }
            return [.init(color: Color(zoHex: 0xFFE9A8), location: 0),
                .init(color: accentFill, location: 0.30),
                .init(color: Color(zoHex: 0xFF8A3D), location: 0.72),
                .init(color: Color(zoHex: 0xFF4D6D), location: 1)]
        case .freak:
            if colorScheme == .light {
                return [.init(color: ZOColor.mixedSRGB(0x1E2126, weight: 0.70, with: 0xFFFFFF), location: 0),
                    .init(color: ZOColor.mixedSRGB(0x1E2126, weight: 0.88, with: 0xFFFFFF), location: 0.26),
                    .init(color: accentFill, location: 0.58),
                    .init(color: ZOColor.mixedSRGB(0x1E2126, weight: 0.80, with: 0x000000), location: 1)]
            }
            return [.init(color: Color(zoHex: 0xFFFFFF), location: 0),
                .init(color: Color(zoHex: 0xE9ECEF), location: 0.26),
                .init(color: accentFill, location: 0.58),
                .init(color: ZOColor.mixedSRGB(0xD9DDE2, weight: 0.78, with: 0x8D939B), location: 1)]
        }
    }

    var brandGradientPrimary: LinearGradient {
        return LinearGradient(
            colors: brandGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var brandGradientHorizontal: LinearGradient {
        return LinearGradient(
            colors: brandGradientColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var successGradient: LinearGradient {
        LinearGradient(
            colors: [successPrimary, successGlow],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func resolve(
        _ id: ZeroOneThemeID,
        appearance: AppearancePreference,
        systemColorScheme: ColorScheme,
        accent: AccentPreference = .yellow
    ) -> ZeroOneThemeTokens {
        resolve(id, colorScheme: appearance.resolvedColorScheme(systemColorScheme: systemColorScheme), accent: accent)
    }

    static func resolve(
        _ id: ZeroOneThemeID,
        colorScheme: ColorScheme = .dark,
        accent: AccentPreference = .yellow
    ) -> ZeroOneThemeTokens {
        // Keep legacy family identifiers intact while rendering the current 01 palette.
        let isDark = colorScheme == .dark
        func role(_ color: Color) -> Color { ZOColor.resolved(color, in: colorScheme) }
        return ZeroOneThemeTokens(
            id: id,
            colorScheme: colorScheme,
            accentPreference: accent,
            backgroundPrimary: role(ZOColor.canvas),
            surfacePrimary: role(ZOColor.surface1),
            surfaceSecondary: role(ZOColor.surface2),
            textPrimary: role(ZOColor.inkPrimary),
            textSecondary: role(ZOColor.inkSecondary),
            textTertiary: role(ZOColor.inkTertiary),
            strokeSubtle: role(ZOColor.separator),
            brandGradientColors: Array(repeating: accent.foreground(in: colorScheme), count: 3),
            successPrimary: role(ZOColor.Status.success),
            successGlow: .clear,
            warningPrimary: role(ZOColor.Status.warning),
            destructivePrimary: role(ZOColor.Status.error),
            materials: ZeroOneMaterialTokens(
                functionalGlassTint: role(ZOColor.surface1),
                contentOverlay: role(ZOColor.inkPrimary).opacity(0.035),
                elevatedShadow: Color.black.opacity(isDark ? 0.40 : 0.10),
                ambientAura: .clear
            )
        )
    }

    /// Explicit presentation adapter; selection/storage and cross-process payloads belong to callers.
    static func resolve(
        appearance: AppearancePreference,
        systemColorScheme: ColorScheme,
        designTheme: ZOTheme,
        accent: AccentPreference = .yellow
    ) -> ZeroOneThemeTokens {
        resolve(designTheme: designTheme,
            colorScheme: appearance.resolvedColorScheme(systemColorScheme: systemColorScheme), accent: accent)
    }

    static func resolve(
        designTheme: ZOTheme,
        colorScheme: ColorScheme = .dark,
        accent: AccentPreference = .yellow
    ) -> ZeroOneThemeTokens {
        guard let palette = designTheme.palette(dark: colorScheme == .dark) else {
            return resolve(.liquidMidnight, colorScheme: colorScheme, accent: accent)
        }
        let core = resolve(.liquidMidnight, colorScheme: colorScheme, accent: accent)
        return ZeroOneThemeTokens(
            id: core.id, colorScheme: colorScheme, accentPreference: accent,
            backgroundPrimary: palette.canvas, surfacePrimary: palette.surface1, surfaceSecondary: palette.surface2,
            textPrimary: palette.inkPrimary, textSecondary: palette.inkSecondary, textTertiary: palette.inkTertiary,
            strokeSubtle: palette.separator, brandGradientColors: Array(repeating: palette.inkPrimary, count: 3),
            successPrimary: core.successPrimary, successGlow: core.successGlow,
            warningPrimary: core.warningPrimary, destructivePrimary: core.destructivePrimary,
            materials: ZeroOneMaterialTokens(functionalGlassTint: palette.surface1,
                contentOverlay: palette.inkPrimary.opacity(0.035),
                elevatedShadow: core.materials.elevatedShadow, ambientAura: .clear),
            designTheme: designTheme
        )
    }

    // Compatibility defaults for previews and callers that have no environment yet.
    static let liquidMidnight = resolve(.liquidMidnight)
    static let iridescentAura = resolve(.iridescentAura)
    static let atelier = resolve(.atelier)
}

private struct ZeroOneThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ZeroOneThemeTokens.liquidMidnight
}

extension EnvironmentValues {
    var zeroOneTheme: ZeroOneThemeTokens {
        get { self[ZeroOneThemeEnvironmentKey.self] }
        set { self[ZeroOneThemeEnvironmentKey.self] = newValue }
    }
}

extension View {
    func zeroOneTheme(_ theme: ZeroOneThemeTokens) -> some View {
        environment(\.zeroOneTheme, theme)
            .zoText(.body)
            .foregroundStyle(theme.textPrimary)
            .toggleStyle(ZOToggleStyle())
            .tint(theme.textPrimary)
    }
}

enum ZeroOneTheme {
    // Legacy names remain source-compatible; chromatic accents now use the 01 identity.
    // Foreground aliases adapt independently for older callers outside the theme environment.
    static let deepBlue = ZOColor.inkPrimary
    static let electricBlue = deepBlue
    static let liquidCyan = deepBlue
    static let iceBlue = deepBlue
    static let specularWhite = ZOColor.inkPrimary
    static let spectralViolet = deepBlue

    static let liquidMidnightGradient = LinearGradient(
        stops: [
            .init(color: ZOColor.inkPrimary, location: 0),
            .init(color: ZOColor.inkPrimary, location: 1)
        ],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    static let liquidMidnightSpecular = RadialGradient(
        colors: [.clear, .clear],
        center: UnitPoint(x: 0.68, y: 0.18),
        startRadius: 0,
        endRadius: 94
    )

    static let liquidMidnightInterference = RadialGradient(
        colors: [.clear, .clear],
        center: UnitPoint(x: 0.16, y: 0.84),
        startRadius: 0,
        endRadius: 112
    )
}

enum WaterMaterial {
    static let deepWater = ZOColor.inkPrimary
    static let water = ZOColor.inkPrimary
    static let shallowWater = ZOColor.inkPrimary
    static let waterHighlight = ZOColor.inkPrimary

    static let fill = LinearGradient(
        colors: [deepWater, water, shallowWater],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    static let refraction = LinearGradient(
        colors: [.clear, .clear],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum ZeroOneColors {
    // Compatibility defaults. Theme-aware views should read EnvironmentValues.zeroOneTheme.

    static let signalYellow = ZOColor.Swatch.yellow.fill
    static let backgroundPrimary = ZOColor.canvas
    static let surfacePrimary = ZOColor.surface1
    static let surfaceSecondary = ZOColor.surface2
    static let textPrimary = ZOColor.inkPrimary
    static let textSecondary = ZOColor.inkSecondary
    static let strokeSubtle = ZOColor.separator
    static let brandGradientPrimary = ZeroOneTheme.liquidMidnightGradient
    static let successPrimary = ZOColor.Status.success
    static let successGlow = Color.clear
    static let warningPrimary = ZOColor.Status.warning
    static let destructivePrimary = ZOColor.Status.error

    static let background = backgroundPrimary
    static let raisedBackground = surfacePrimary
    static let graphite = surfaceSecondary
    static let higherSurface = ZOColor.surface3
    static let primaryText = textPrimary
    static let secondaryText = textSecondary
    static let muted = ZOColor.inkTertiary
    static let titanium = ZOColor.inkSecondary

    static let deepIris = ZeroOneTheme.deepBlue
    static let violet = ZeroOneTheme.liquidCyan
    static let softEmber = ZeroOneTheme.iceBlue

    static let primaryAction = primaryText
    static let onPrimaryAction = background
    static let intelligenceAccent = deepIris
    static let intelligenceMuted = deepIris.opacity(0.14)
    static let coolReflection = softEmber

    static let tabBar = raisedBackground
    static let surface = surfacePrimary
    static let elevatedSurface = surfaceSecondary
    static let interactiveSurface = ZOColor.surface2
    static let tertiaryText = muted
    static let brandAccent = deepIris
    static let brandAccentMuted = deepIris.opacity(0.12)
    static let performanceAccent = ZeroOneTheme.electricBlue
    static let performanceAccentMuted = ZeroOneTheme.electricBlue.opacity(0.10)
    static let accent = ZeroOneTheme.electricBlue
    static let accentMuted = ZeroOneTheme.electricBlue.opacity(0.10)
    static let aqua = violet
    static let aquaMuted = violet.opacity(0.12)

    static let onAccent = ZOColor.Swatch.yellow.on
    static let success = successPrimary
    static let warning = warningPrimary
    static let destructive = destructivePrimary
    static let divider = strokeSubtle
    static let overlay = ZOColor.inkPrimary.opacity(0.035)
    static let shadow = Color.clear
}

typealias AppColors = ZeroOneColors
