import SwiftUI
import UIKit

struct LanguageSettingsView: View {
    @AppStorage(AppLanguagePreference.storageKey) private var storedPreference = AppLanguagePreference.system.rawValue
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.openURL) private var openURL

    private var preference: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference.storedValue(storedPreference) },
            set: { storedPreference = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsThemeGroup(title: "App language",
                    footer: "Changes apply immediately. Your saved workouts and entries keep their original names.",
                    isList: true) {
                    VStack(spacing: 0) {
                        languageOption(.system) { Text("Use device language") }
                        languageOption(.english, showsSeparator: true) { Text(verbatim: AppLanguage.english.nativeName) }
                        languageOption(.bulgarian, showsSeparator: true) { Text(verbatim: AppLanguage.bulgarian.nativeName) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Language")
                    .accessibilityValue(Text(verbatim: selectedPreferenceLabel))
                    .accessibilityIdentifier("profile.language.preference")
                    .accessibilityHint("Changes the language of the app interface.")
                }

                VStack(alignment: .leading, spacing: 0) {
                    LabeledContent("Current language") {
                        Text(verbatim: localization.language.nativeName)
                            .zoProofText(.body, size: 15, lineHeight: 20)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .zoText(.section)
                    .modifier(SettingsThemeListRow())
                    Text("If your device language is unsupported, 01 uses English.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(SettingsThemeListRow(showsSeparator: true))
                    Text("Some exercise guides and educational content are available in English.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(SettingsThemeListRow(showsSeparator: true))
                }
                .padding(.horizontal, ZOSpace.l)
                .zoThemeCardSurface()

                // The actual Apple Settings action remains independent of the app preference.
                VStack(spacing: 0) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    HStack(spacing: ZOSpace.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iPhone Settings for 01")
                                .zoText(.section)
                            Text("Opens iPhone Settings, where Apple keeps each app's settings. 01 keeps the language you choose here.")
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right.square")
                            .zoIcon(ZOIcon.inline)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .modifier(SettingsThemeListRow())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.language.openSettings")
                .accessibilityHint("Opens the Settings app.")
                }
                .padding(.horizontal, ZOSpace.l)
                .zoThemeCardSurface()
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 28)
            .padding(.bottom, ZOSpace.screenMargin)
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accentForeground)
        .zoThemeScreenSurface()
        .toolbar { ToolbarItem(placement: .principal) { Text("Language").zoText(.section) } }
    }

    /// Reads the same preference binding as the selection rows, never a second resolver.
    private var selectedPreferenceLabel: String {
        switch preference.wrappedValue {
        case .system: localization.string("Use device language")
        case .english: AppLanguage.english.nativeName
        case .bulgarian: AppLanguage.bulgarian.nativeName
        }
    }

    /// Explicit single-choice row. The binding remains the sole storage writer.
    private func languageOption<Label: View>(_ value: AppLanguagePreference,
        showsSeparator: Bool = false, @ViewBuilder label: () -> Label) -> some View {
        let selected = preference.wrappedValue == value
        return Button { preference.wrappedValue = value } label: {
            HStack(spacing: ZOSpace.m) {
                label().zoText(.section)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark").zoIcon(ZOIcon.inline)
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .modifier(SettingsThemeListRow(showsSeparator: showsSeparator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
