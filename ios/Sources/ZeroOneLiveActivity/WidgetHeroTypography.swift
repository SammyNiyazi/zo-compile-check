import SwiftUI

/// Study36 s36.css:128,176-182 contextual rest/paused hero. This supplies CSS
/// values to the shared verified font/glyph renderer, never a second font engine.
/// Instrument metric Dynamic Type style/cap are retained from the prior caller.
enum ZOWidgetHeroTypography {
    static func timerSpec(for theme: ZOTheme) -> ZOThemeTextSpec {
        var spec = ZOThemeTypography.spec(for: .core, role: .metric)
        spec.size = 44; spec.lineHeight = 44
        spec.weight = 700; spec.width = 75; spec.tracking = -0.5
        switch theme {
        case .core, .princess: break
        case .retro:
            spec.resource = .monoton; spec.size = 36
            spec.weight = 400; spec.width = 100; spec.tracking = 1
        case .freak:
            spec.resource = .anton; spec.size = 42
            spec.weight = 400; spec.width = 100; spec.tracking = 0.3
        }
        return spec
    }

    static func timerEffects(for theme: ZOTheme, scheme: ColorScheme,
                             island: Bool) -> ZOThemeTextEffects {
        let ink = theme.palette(dark: scheme == .dark)?.inkPrimary
            ?? ZOColor.resolved(ZOColor.inkPrimary, in: scheme)
        if theme == .retro {
            if scheme == .dark || island {
                return .init(foreground: AnyShapeStyle(Color(zoHex: 0xFFE9A8)), shadows: [
                    .init(color: Color(zoHex: 0xFF8A3D).opacity(0.6), cssBlur: 8, x: 0, y: 0)])
            }
            return .init(foreground: AnyShapeStyle(ink), shadows: [
                .init(color: Color(zoHex: 0xFF4D6D), cssBlur: 0, x: 2, y: 2)])
        }
        if theme == .freak, scheme == .dark, !island {
            // Exact contextual chrome1/chrome2@55%/chrome3; the global app
            // timerHero's six-stop chrome is a different CSS selector.
            let stops: [Gradient.Stop] = [
                .init(color: Color(zoHex: 0xFFFFFF), location: 0),
                .init(color: Color(zoHex: 0x8D939B), location: 0.55),
                .init(color: Color(zoHex: 0xE9ECEF), location: 1)]
            return .init(foreground: AnyShapeStyle(LinearGradient(stops: stops,
                startPoint: .top, endPoint: .bottom)), shadows: [], gradientStops: stops)
        }
        return .init(foreground: nil, shadows: [])
    }
}
