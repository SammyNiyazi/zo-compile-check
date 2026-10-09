import SwiftUI

enum ZOThemeComponentRole {
    case card, button, control
}

/// tokens.json/themes.list radius overrides and themes-fx.css's exact --cut.
/// The supplied radius remains authoritative for Core/Retro and defaults to the card token.
struct ZOThemeComponentShape: Shape {
    let theme: ZOTheme
    let role: ZOThemeComponentRole
    var radius: CGFloat = ZORadius.card

    var resolvedRadius: CGFloat {
        switch theme {
        case .core, .retro: radius
        case .freak: 2
        case .princess:
            switch role {
            case .card: 22
            case .button: 26
            case .control: 16
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        guard theme == .freak else {
            return RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous).path(in: rect)
        }
        guard rect.width > 0, rect.height > 0 else { return Path() }
        // CSS: polygon(10px 0,100% 0,100% calc(100% - 10px),
        // calc(100% - 10px) 100%,0 100%,0 10px), intersected with border-radius:2px.
        // Only the uncut top-right/bottom-left circular corners remain from that rectangle.
        // Tiny degenerate boxes are bounded; normal controls/cards retain the literal 10 pt.
        let cut = min(CGFloat(10), min(rect.width, rect.height) / 2)
        let r = min(resolvedRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addRelativeArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r, startAngle: .degrees(-90), delta: .degrees(90))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addRelativeArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), delta: .degrees(90))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}

/// CSS linear-gradient angle: 0° points up and 90° points right. The gradient line
/// spans projections of the actual box corners; UnitPoints may extend beyond the box.
enum ZOThemeGradientGeometry {
    static func endpoints(cssDegrees: Double, size: CGSize) -> (start: UnitPoint, end: UnitPoint) {
        guard size.width > 0, size.height > 0 else { return (.center, .center) }
        let radians = cssDegrees * .pi / 180
        let dx = CGFloat(sin(radians)), dy = CGFloat(-cos(radians))
        let length = abs(size.width * dx) + abs(size.height * dy)
        let x = dx * length / (2 * size.width), y = dy * length / (2 * size.height)
        return (UnitPoint(x: 0.5 - x, y: 0.5 - y), UnitPoint(x: 0.5 + x, y: 0.5 + y))
    }
}

/// Static card decoration only. Caller owns padding, content, hit region and behavior.
/// An explicit background stays the caller's exact solid color, including in-sheet surfaces.
struct ZOThemeCardSurface: ViewModifier {
    let theme: ZeroOneThemeTokens
    var background: Color? = nil
    var radius: CGFloat = ZORadius.card

    var borderColor: Color {
        switch theme.designTheme {
        case .core, .princess: .clear
        case .retro: theme.colorScheme == .dark ? Color(zoHex: 0xC04DFF, alpha: 0.26) : theme.separatorStrong
        case .freak: theme.separatorStrong
        }
    }

    var topHighlight: Color {
        theme.designTheme == .freak ? theme.textPrimary.opacity(0.14) : .clear
    }

    var gradientStops: [Gradient.Stop]? {
        guard background == nil, theme.designTheme == .princess else { return nil }
        // themes-fx.css: linear-gradient(140deg,surface1 0,surface1 55%,
        // color-mix(in srgb,lilac 12%,surface1) 100%). Palette source is tokens.json.
        let surfaceHex: UInt32 = theme.colorScheme == .dark ? 0x26172D : 0xFFFFFF
        return [.init(color: theme.surfacePrimary, location: 0),
            .init(color: theme.surfacePrimary, location: 0.55),
            .init(color: ZOColor.mixedSRGB(0xC9B4FF, weight: 0.12, with: surfaceHex), location: 1)]
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = ZOThemeComponentShape(theme: theme.designTheme, role: .card, radius: radius)
        let decorated = content.background {
            GeometryReader { geometry in
                ZStack {
                    if let stops = gradientStops {
                        let points = ZOThemeGradientGeometry.endpoints(cssDegrees: 140, size: geometry.size)
                        shape.fill(LinearGradient(stops: stops, startPoint: points.start, endPoint: points.end))
                    } else {
                        shape.fill(background ?? theme.surfacePrimary)
                    }
                    if theme.designTheme == .freak {
                        // CSS inset shadows belong to the rounded box before --cut clipping.
                        // Draw highlight below the strong edge (first listed CSS shadow is on top).
                        Rectangle().fill(topHighlight)
                            .frame(height: ZOStroke.hairline)
                            .frame(maxHeight: .infinity, alignment: .top)
                        RoundedRectangle(cornerRadius: 2, style: .circular)
                            .strokeBorder(borderColor, lineWidth: ZOStroke.hairline)
                    } else if theme.designTheme == .retro {
                        RoundedRectangle(cornerRadius: shape.resolvedRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: ZOStroke.hairline)
                    }
                }
                .clipShape(shape)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        if theme.designTheme == .freak {
            // CSS clip-path clips the entire element, including overflowing child content.
            decorated.clipShape(shape)
        } else {
            decorated
        }
    }
}

private struct ZOEnvironmentThemeCardSurface: ViewModifier {
    let background: Color?
    let radius: CGFloat
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content.modifier(ZOThemeCardSurface(theme: theme, background: background, radius: radius))
    }
}

extension View {
    func zoThemeCardSurface(background: Color? = nil, radius: CGFloat = ZORadius.card) -> some View {
        modifier(ZOEnvironmentThemeCardSurface(background: background, radius: radius))
    }
}
