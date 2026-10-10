import SwiftUI

extension EnvironmentValues {
    @Entry var zeroOneLocalization = AppLocalization.english
}

private struct ZeroOneLanguageModifier: ViewModifier {
    @AppStorage(AppLanguagePreference.storageKey) private var storedPreference = AppLanguagePreference.system.rawValue
    @State private var preferredLanguages = Locale.preferredLanguages
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let language = AppLanguagePreference.storedValue(storedPreference)
            .resolvedLanguage(preferredLanguages: preferredLanguages)
        content
            .environment(\.locale, language.locale)
            // Both supported interface languages read left to right. Arabic/RTL
            // remains a later, separately reviewed localization milestone.
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.zeroOneLocalization, AppLocalization(language: language))
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                preferredLanguages = Locale.preferredLanguages
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { preferredLanguages = Locale.preferredLanguages }
            }
    }
}

extension View {
    /// Install once above the entire app presentation tree. Locale changes keep
    /// view identity, drafts and active workouts; no .id(language) reconstruction.
    func zeroOneLanguage() -> some View {
        modifier(ZeroOneLanguageModifier())
    }
}
