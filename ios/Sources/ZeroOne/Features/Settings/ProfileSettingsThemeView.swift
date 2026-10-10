import CoreText
import SwiftUI
import UIKit

/// Uses the root-owned preference contract; appearance remains a separate setting.
struct ProfileSettingsThemeView: View {
    @Binding var selectedAppearance: AppearancePreference
    @AppStorage(DesignThemePreference.storageKey) private var selectedRawValue = DesignThemePreference.core.rawValue
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selected: DesignThemePreference { .storedValue(selectedRawValue) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: ZOSpace.m),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text("A whole new vibe for 01. Your data stay the same.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                LazyVGrid(columns: columns, spacing: ZOSpace.m) {
                    ForEach(DesignThemePreference.allCases) { preference in
                        Button { selectedRawValue = preference.rawValue } label: {
                            ProfileSettingsThemeTile(preference: preference, isSelected: preference == selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: localization.string(preference.title)))
                        .accessibilityValue(Text(verbatim: localization.string(preference == selected ? "Selected" : "Not selected")))
                        .accessibilityAddTraits(preference == selected ? .isSelected : [])
                    }
                }
                Text("Appearance")
                    .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                    .foregroundStyle(theme.textSecondary)
                ZOSegmentedControl("Appearance", selection: $selectedAppearance,
                    options: AppearancePreference.allCases.map { preference in
                        ZOSegment(value: preference, label: Text(verbatim: localization.string(preference.title)))
                    })
                Text("Every theme has light and dark")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(ZOSpace.l)
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
    }
}

private struct ProfileSettingsThemeTile: View {
    let preference: DesignThemePreference
    let isSelected: Bool
    @Environment(\.zeroOneTheme) private var hostTheme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Proof themes.js previews 01/Retro/Freak dark and Princess light.
    private var dark: Bool { preference != .princess }
    private var palette: ZOPalette? { preference.designTheme.palette(dark: dark) }
    private var canvas: Color { palette?.canvas ?? ZOColor.resolved(ZOColor.canvas, in: .dark) }
    private var ink: Color { palette?.inkPrimary ?? ZOColor.resolved(ZOColor.inkPrimary, in: .dark) }
    private var secondaryInk: Color { palette?.inkSecondary ?? ZOColor.resolved(ZOColor.inkSecondary, in: .dark) }
    private var accent: Color { palette?.accent ?? ZOColor.Swatch.yellow.fill }
    private var onAccent: Color { palette?.onAccent ?? ZOColor.Swatch.yellow.on }

    private var previewDisplaySpec: ZOThemeTextSpec {
        var spec = ZOThemeTypography.spec(for: preference.designTheme, role: .display)
        // themes.js:73 overrides the theme display to 28/34 for selection tiles.
        spec.size = 28
        spec.lineHeight = 34
        return spec
    }

    private func previewFont(_ spec: ZOThemeTextSpec) -> CTFont? {
        do { return try spec.font(for: dynamicTypeSize) }
        catch {
            assertionFailure("Theme preview font unavailable or invalid; readable core fallback is not theme parity: \(error)")
            return nil
        }
    }

    @ViewBuilder
    private var displayWord: some View {
        let title = localization.string(preference == .core ? "Today" : preference.title)
        if preference == .core {
            Text(verbatim: title)
                .zoProofText(.display, size: 28, lineHeight: 34, weight: 700)
        } else {
            let spec = previewDisplaySpec
            if let font = previewFont(spec) {
                let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
                let scale = CTFontGetSize(font) / spec.size
                Text(verbatim: title)
                    .font(Font(font))
                    .tracking(spec.tracking)
                    .lineSpacing(max(0, spec.lineHeight * scale - natural))
            } else {
                // Diagnosed readable failure only; native resource preflight must
                // reject this fallback before accepting theme-face fidelity.
                Text(verbatim: title)
                    .zoProofText(.display, size: 28, lineHeight: 34, weight: 700)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            displayWord
                .zoThemeTextEffects(.display, designTheme: preference.designTheme,
                                    colorScheme: dark ? .dark : .light)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("Start")
                .zoProofText(.caption, size: 13, lineHeight: 26, weight: 600)
                .foregroundStyle(onAccent)
                .padding(.horizontal, ZOSpace.m)
                .frame(minHeight: 26)
                .background(accent, in: Capsule())
            Text(verbatim: (preference == .core ? "01 · " : "") + localization.string("Light and dark"))
                .zoText(.caption)
                .foregroundStyle(secondaryInk)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(canvas, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(palette?.separatorStrong ?? hostTheme.strokeSubtle, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(hostTheme.textPrimary, lineWidth: 3)
                    .padding(-6)
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
