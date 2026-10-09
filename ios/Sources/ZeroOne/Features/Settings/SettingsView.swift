import SwiftUI

struct SettingsScreen: View {
    @Binding var selectedAppearance: AppearancePreference
    @AppStorage(AccentPreference.storageKey) private var selectedAccentRawValue = AccentPreference.yellow.rawValue
    @AppStorage(LocalDayProgress.preferenceKey) private var showsDayProgress = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            // Proof 46's shared control family: each choice is a segmented
            // control under its group title. Same preferences, same keys.
            SettingsThemeGroup(title: "Appearance", hasCard: false) {
                ZOSegmentedControl("Appearance", selection: $selectedAppearance,
                                   options: AppearancePreference.allCases.map { appearance in
                    ZOSegment(value: appearance, label: Text(localization.string(appearance.title)))
                })
                .accessibilityIdentifier("settings.appearance")
                .accessibilityHint("System follows your iPhone's appearance.")
            }

            SettingsThemeGroup(title: "Accent", footer: "Applies to both light and dark appearances.", hasCard: false) {
                ZOSegmentedControl("Accent", selection: Binding(
                    get: { AccentPreference.storedValue(selectedAccentRawValue) },
                    set: { selectedAccentRawValue = $0.rawValue }
                ), options: AccentPreference.allCases.map { accent in ZOSegment(value: accent, label: Text(localization.string(accent.title))) })
                .accessibilityIdentifier("settings.accent")
                .accessibilityHint("Applies to both light and dark appearances.")
            }

            SettingsThemeGroup(title: "Foundation", isList: true) {
                Toggle("Show day percentage", isOn: $showsDayProgress)
                    .zoText(.section).modifier(SettingsThemeListRow())
                    .accessibilityHint("Shows elapsed time in your local calendar day on Today.")
                LabeledContent("Network") {
                    Text(verbatim: localization.string("Not required"))
                        .zoProofText(.body, size: 15, lineHeight: 20).foregroundStyle(theme.textSecondary)
                }.zoText(.section).modifier(SettingsThemeListRow(showsSeparator: true))
                LabeledContent("Apple Health") {
                    Text(verbatim: localization.string("Optional"))
                        .zoProofText(.body, size: 15, lineHeight: 20).foregroundStyle(theme.textSecondary)
                }.zoText(.section).modifier(SettingsThemeListRow(showsSeparator: true))
                Text("Core workout logging works offline.").zoText(.caption)
                    .modifier(SettingsThemeListRow(showsSeparator: true))
                    .foregroundStyle(theme.textSecondary)
            }
            }.padding(.horizontal, ZOSpace.screenMargin).padding(.top, 28).padding(.bottom, ZOSpace.screenMargin)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Settings").zoText(.section) } }
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accentForeground)
        .zoThemeScreenSurface()
    }
}


/// Scoped presentation replacement for read-only ProfileDataGroup. Only the
/// assigned callers opt into whole-card effects; hasCard is fixed at each call.
/// Callers retain their own content, keys, state, callbacks and adaptive layout.
struct SettingsThemeGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    var hasCard = true
    var isList = false
    @ViewBuilder let content: Content
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(localization.string(title))
                .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                .textCase(nil).foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, ZOSpace.xs)
                .padding(.bottom, ZOSpace.xs)
            surface
            if let footer {
                Text(localization.string(footer))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZOSpace.xs)
            }
        }
    }

    @ViewBuilder private var surface: some View {
        if hasCard {
            VStack(alignment: .leading, spacing: isList ? 0 : ZOSpace.m) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZOSpace.cardPadding)
                .padding(.vertical, isList ? 0 : ZOSpace.cardPadding)
                .zoThemeCardSurface()
        } else {
            content
        }
    }
}

/// Measured .zo-row layout and zero-layout inset separator. The whole group owns
/// the shared card shape/gradient; each row keeps its original content/action.
struct SettingsThemeListRow: ViewModifier {
    var showsSeparator = false
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content.padding(.vertical, ZOSpace.s)
            .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight, alignment: .leading)
            .overlay(alignment: .top) {
                if showsSeparator {
                    Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
