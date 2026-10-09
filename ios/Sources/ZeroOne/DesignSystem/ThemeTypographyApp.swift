import SwiftUI

/// App only: the extension compiles ThemeTypography.swift with explicit theme/scheme.
private struct ZOEnvironmentThemeTextModifier: ViewModifier {
    let role: ZOThemeTextRole
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content.zoThemeText(role, designTheme: theme.designTheme, colorScheme: theme.colorScheme)
    }
}

/// App-only environment bridge for component dimensions; shared rendering stays explicit.
private struct ZOEnvironmentComponentThemeTextModifier: ViewModifier {
    let role: ZOThemeTextRole
    let size: CGFloat
    let lineHeight: CGFloat
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content.zoThemeText(role, size: size, lineHeight: lineHeight,
                           designTheme: theme.designTheme, colorScheme: theme.colorScheme)
    }
}

extension View {
    func zoThemeText(_ role: ZOThemeTextRole) -> some View {
        modifier(ZOEnvironmentThemeTextModifier(role: role))
    }

    /// Component dimensions remain explicit; theme and mode come from the nearest host.
    func zoThemeText(_ role: ZOThemeTextRole, size: CGFloat, lineHeight: CGFloat) -> some View {
        modifier(ZOEnvironmentComponentThemeTextModifier(role: role, size: size, lineHeight: lineHeight))
    }
}
