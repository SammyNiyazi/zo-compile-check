import SwiftUI

private struct ZOSheetModifier: ViewModifier {
    let selectedTheme: ZeroOneThemeTokens?
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        let resolvedTheme = selectedTheme ?? theme
        return content
            .zeroOneTheme(resolvedTheme)
            .presentationBackground(resolvedTheme.surfacePrimary)
            .toolbarBackground(resolvedTheme.surfacePrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(resolvedTheme.colorScheme, for: .navigationBar)
            .presentationDragIndicator(.visible)
            .tint(resolvedTheme.textPrimary)
    }
}

extension View {
    /// Apply to a sheet's presented root so its chrome follows the chosen appearance.
    func zoSheet(_ theme: ZeroOneThemeTokens? = nil) -> some View {
        modifier(ZOSheetModifier(selectedTheme: theme))
    }
}
