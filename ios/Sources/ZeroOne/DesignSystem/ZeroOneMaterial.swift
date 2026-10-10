import SwiftUI


enum ZeroOneGlassShape: Equatable {
    case capsule
    case rounded(CGFloat)
}



private struct ZeroOneGlassSurfaceModifier: ViewModifier {
    let shape: ZeroOneGlassShape
    let tint: Color?
    let interactive: Bool
    let clear: Bool

    @Environment(\.zeroOneTheme) private var theme

    // Legacy callers keep their shape and interaction ownership during migration.
    // 01-owned chrome always uses the opaque generated surface role.
    @ViewBuilder
    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content.background(theme.surfacePrimary, in: Capsule())
        case let .rounded(radius):
            content.background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

private struct ZeroOneMaterialSurfaceModifier: ViewModifier {
    let shape: ZeroOneGlassShape

    @Environment(\.zeroOneTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content.background(theme.surfacePrimary, in: Capsule())
        case let .rounded(radius):
            content.background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    func zeroOneGlassSurface(
        _ shape: ZeroOneGlassShape = .capsule,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        modifier(
            ZeroOneGlassSurfaceModifier(
                shape: shape,
                tint: tint,
                interactive: interactive,
                clear: clear
            )
        )
    }

    func zeroOneMaterialSurface(_ shape: ZeroOneGlassShape = .capsule) -> some View {
        modifier(ZeroOneMaterialSurfaceModifier(shape: shape))
    }
}
