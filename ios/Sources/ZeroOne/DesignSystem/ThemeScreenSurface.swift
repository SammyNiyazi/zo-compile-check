import SwiftUI

/// Literal .zo-screen CSS geometry; percentages are ellipse radii, not diameters.
struct ZOThemeScreenRadial {
    let color: Color
    let center: UnitPoint
    let radiusX: CGFloat
    let radiusY: CGFloat
    let fade: CGFloat

    func ellipse(in size: CGSize) -> CGRect {
        let x = radiusX * size.width, y = radiusY * size.height
        return CGRect(x: center.x * size.width - x, y: center.y * size.height - y,
            width: 2 * x, height: 2 * y)
    }
}

struct ZOThemeScreenLinear {
    let cssDegrees: Double
    let stops: [Gradient.Stop]
}

struct ZOThemeScreenStripes: Shape {
    enum Axis: Equatable { case horizontal, vertical }
    let axis: Axis
    let period: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0, period > 0, width > 0 else { return Path() }
        var path = Path()
        let length = axis == .horizontal ? rect.height : rect.width
        var offset: CGFloat = 0
        while offset < length {
            let thickness = min(width, length - offset)
            let stripe = axis == .horizontal
                ? CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: thickness)
                : CGRect(x: rect.minX + offset, y: rect.minY, width: thickness, height: rect.height)
            path.addRect(stripe)
            offset += period
        }
        return path
    }
}

struct ZOThemeScreenSpecification {
    let theme: ZeroOneThemeTokens

    // Back-to-front order, matching the reverse order of the CSS background-image list.
    var radials: [ZOThemeScreenRadial] {
        switch theme.designTheme {
        case .core: return []
        case .retro:
            guard theme.colorScheme == .dark else { return [] }
            return [.init(color: Color(zoHex: 0xC04DFF, alpha: 0.16), center: UnitPoint(x: 0.5, y: 1.1),
                radiusX: 1.2, radiusY: 0.6, fade: 0.6)]
        case .freak:
            guard theme.colorScheme == .dark else { return [] }
            return [.init(color: theme.textPrimary.opacity(0.07), center: UnitPoint(x: 0.5, y: 0),
                radiusX: 0.9, radiusY: 0.4, fade: 0.7)]
        case .princess:
            return [.init(color: theme.accentFill.opacity(0.14), center: UnitPoint(x: 0, y: 1),
                    radiusX: 0.8, radiusY: 0.4, fade: 0.7),
                .init(color: Color(zoHex: 0xC9B4FF, alpha: 0.22), center: UnitPoint(x: 0.85, y: 0),
                    radiusX: 0.9, radiusY: 0.5, fade: 0.7)]
        }
    }

    var linear: ZOThemeScreenLinear? {
        guard theme.colorScheme == .light else { return nil }
        switch theme.designTheme {
        case .retro:
            // CSS to top: 14% glowB at the bottom, completely transparent by22%.
            return .init(cssDegrees: 0, stops: [.init(color: Color(zoHex: 0xFF8A3D, alpha: 0.14), location: 0),
                .init(color: Color(zoHex: 0xFF8A3D, alpha: 0), location: 0.22),
                .init(color: Color(zoHex: 0xFF8A3D, alpha: 0), location: 1)])
        case .freak:
            return .init(cssDegrees: 170, stops: [.init(color: theme.surfacePrimary, location: 0),
                .init(color: theme.backgroundPrimary, location: 0.4),
                .init(color: theme.surfaceSecondary, location: 1)])
        case .core, .princess: return nil
        }
    }

    var backgroundStripe: (shape: ZOThemeScreenStripes, color: Color)? {
        guard theme.designTheme == .freak, theme.colorScheme == .light else { return nil }
        return (.init(axis: .vertical, period: 4, width: 1), Color(zoHex: 0xFFFFFF, alpha: 0.30))
    }

    var foregroundStripe: (shape: ZOThemeScreenStripes, color: Color)? {
        guard theme.designTheme == .retro else { return nil }
        let color = theme.colorScheme == .dark
            ? Color(zoHex: 0xFFE9A8, alpha: 0.05) : theme.textPrimary.opacity(0.025)
        return (.init(axis: .horizontal, period: 3, width: 1), color)
    }
}

private struct ZOThemeScreenRadialLayer: View {
    let radial: ZOThemeScreenRadial
    let size: CGSize

    @ViewBuilder
    var body: some View {
        let ellipse = radial.ellipse(in: size)
        if ellipse.width > 0, ellipse.height > 0 {
            // A circular gradient scaled into an ellipse preserves the CSS radial distance.
            RadialGradient(gradient: Gradient(stops: [.init(color: radial.color, location: 0),
                    .init(color: radial.color.opacity(0), location: radial.fade),
                    .init(color: radial.color.opacity(0), location: 1)]),
                center: .center, startRadius: 0, endRadius: ellipse.width / 2)
                .frame(width: ellipse.width, height: ellipse.width)
                .scaleEffect(x: 1, y: ellipse.height / ellipse.width)
                .position(x: ellipse.midX, y: ellipse.midY)
        }
    }
}

/// Opt in once at a screen host; nested zeroOneTheme environment injection does not add it.
/// Owns only static decoration. Host owns safe areas, layout, content and theme selection.
struct ZOThemeScreenSurface: ViewModifier {
    let theme: ZeroOneThemeTokens

    func body(content: Content) -> some View {
        let spec = ZOThemeScreenSpecification(theme: theme)
        content
            .background {
                GeometryReader { geometry in
                    ZStack {
                        theme.backgroundPrimary
                        if let linear = spec.linear {
                            let points = ZOThemeGradientGeometry.endpoints(cssDegrees: linear.cssDegrees, size: geometry.size)
                            LinearGradient(stops: linear.stops, startPoint: points.start, endPoint: points.end)
                        }
                        // At most two layers; named slots preserve reference stacking without array indices as identity.
                        if let first = spec.radials.first { ZOThemeScreenRadialLayer(radial: first, size: geometry.size) }
                        if spec.radials.count == 2, let last = spec.radials.last {
                            ZOThemeScreenRadialLayer(radial: last, size: geometry.size)
                        }
                        if let stripe = spec.backgroundStripe { stripe.shape.fill(stripe.color) }
                    }
                    .clipped()
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay {
                // Both ::after effects sit above content; Freak background stripes remain below it.
                if let stripe = spec.foregroundStripe {
                    stripe.shape.fill(stripe.color)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if theme.designTheme == .freak {
                    ZOFreakGrainLayer()
                }
            }
        // Freak uses pinned transparent browser reference tiles, preserving the original SVG.
        // Native overlay/compositing/full-extent acceptance remains a separate requirement.
    }
}

private struct ZOEnvironmentThemeScreenSurface: ViewModifier {
    @Environment(\.zeroOneTheme) private var theme
    func body(content: Content) -> some View { content.modifier(ZOThemeScreenSurface(theme: theme)) }
}

extension View {
    func zoThemeScreenSurface() -> some View { modifier(ZOEnvironmentThemeScreenSurface()) }
}
