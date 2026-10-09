import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class AppearancePreferenceTests: XCTestCase {
    func testMissingOrUnknownStoredAppearanceFollowsSystem() {
        let rawValues: [String?] = [nil, "", "unknown-future-value"]
        for rawValue in rawValues {
            XCTAssertEqual(AppearancePreference.storedValue(rawValue), .system)
        }
        for preference in AppearancePreference.allCases {
            XCTAssertEqual(AppearancePreference.storedValue(preference.rawValue), preference)
        }
    }

    func testAccentRelaunchIsIndependentOfSavedAppearanceAndLegacyFamily() throws {
        let suiteName = "AccentPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(AccentPreference.storedValue(nil), .yellow)
        XCTAssertEqual(AccentPreference.storedValue("unknown"), .yellow)
        defaults.set("atelier", forKey: "slick.visualTheme")
        for appearance in AppearancePreference.allCases {
            defaults.set(appearance.rawValue, forKey: AppearancePreference.storageKey)
            for accent in AccentPreference.allCases {
                let selection = AppStorage<String>(wrappedValue: "yellow", AccentPreference.storageKey, store: defaults)
                selection.wrappedValue = accent.rawValue
                let restored = AppStorage<String>(wrappedValue: "yellow", AccentPreference.storageKey, store: defaults)
                XCTAssertEqual(AccentPreference.storedValue(restored.wrappedValue), accent)
                XCTAssertEqual(defaults.string(forKey: AppearancePreference.storageKey), appearance.rawValue)
                XCTAssertEqual(defaults.string(forKey: "slick.visualTheme"), "atelier")
            }
        }
    }

    func testAccentContrastAndStatusColoursAcrossBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let baseline = ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme)
            for accent in AccentPreference.allCases {
                let theme = ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme, accent: accent)
                XCTAssertEqual(theme.accentPreference, accent)
                for surface in [theme.backgroundPrimary, theme.surfacePrimary, theme.surfaceSecondary] {
                    XCTAssertGreaterThanOrEqual(contrast(theme.accentForeground, surface), 4.5)
                    XCTAssertGreaterThanOrEqual(contrast(theme.chartAccent, surface), 3)
                }
                XCTAssertGreaterThanOrEqual(contrast(theme.onAccent, theme.accentFill), 4.5)
                XCTAssertGreaterThanOrEqual(contrast(theme.disabledAccentForeground, theme.disabledAccentFill), 4.5)
                XCTAssertEqual(components(theme.successPrimary), components(baseline.successPrimary))
                XCTAssertEqual(components(theme.warningPrimary), components(baseline.warningPrimary))
                XCTAssertEqual(components(theme.destructivePrimary), components(baseline.destructivePrimary))
                XCTAssertEqual(components(TrainingCompanionPalette.canvas(for: scheme)), components(theme.backgroundPrimary))
                XCTAssertEqual(components(TrainingCompanionPalette.surface(for: scheme)), components(theme.surfacePrimary))
            }
        }
    }

    func testPinkOnlyChangesActionFillAndLeavesNavigationNeutral() {
        let theme = ZeroOneThemeTokens.resolve(.atelier, colorScheme: .light, accent: .pink)
        assertColor(theme.navigationAccent, hex: 0x020202)
        assertColor(theme.accentFill, hex: 0xFF9AD5)
        assertColor(theme.accentForeground, hex: 0x020202)
        XCTAssertGreaterThanOrEqual(contrast(theme.accentForeground, theme.surfacePrimary), 4.5)
        let palette = DailyWidgetPalette(dark: false, accent: .pink)
        assertColor(palette.action, hex: 0xFF9AD5)
        XCTAssertGreaterThanOrEqual(contrast(palette.accentForeground, palette.background), 4.5)
    }

    func testPreferredSchemeAndSystemChanges() {
        XCTAssertNil(AppearancePreference.system.preferredColorScheme)
        XCTAssertEqual(AppearancePreference.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.preferredColorScheme, .dark)

        for systemScheme in [ColorScheme.light, .dark] {
            XCTAssertEqual(AppearancePreference.system.resolvedColorScheme(systemColorScheme: systemScheme), systemScheme)
            XCTAssertEqual(AppearancePreference.light.resolvedColorScheme(systemColorScheme: systemScheme), .light)
            XCTAssertEqual(AppearancePreference.dark.resolvedColorScheme(systemColorScheme: systemScheme), .dark)
        }
    }

    func testAppStorageRelaunchRetainsAppearanceWithoutChangingLegacyFamily() throws {
        let suiteName = "AppearancePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ThemeFamily.iridescentAura.rawValue, forKey: "slick.visualTheme")

        let selection = AppStorage<String>(
            wrappedValue: AppearancePreference.system.rawValue,
            AppearancePreference.storageKey,
            store: defaults
        )
        XCTAssertEqual(selection.wrappedValue, "system")

        for preference in AppearancePreference.allCases {
            selection.wrappedValue = preference.rawValue
            let restoredSelection = AppStorage<String>(
                wrappedValue: AppearancePreference.system.rawValue,
                AppearancePreference.storageKey,
                store: defaults
            )
            XCTAssertEqual(AppearancePreference.storedValue(restoredSelection.wrappedValue), preference)
            XCTAssertEqual(defaults.string(forKey: "slick.visualTheme"), "iridescentAura")
        }
    }

    func testEveryLegacyFamilyResolvesTo01WithoutChangingItsIdentifier() {
        for family in ThemeFamily.allCases {
            for systemScheme in [ColorScheme.light, .dark] {
                for preference in AppearancePreference.allCases {
                    let theme = ZeroOneThemeTokens.resolve(
                        family,
                        appearance: preference,
                        systemColorScheme: systemScheme
                    )
                    let expectedScheme = preference.preferredColorScheme ?? systemScheme
                    XCTAssertEqual(theme.id, family)
                    XCTAssertEqual(theme.colorScheme, expectedScheme)
                    assertColor(theme.backgroundPrimary, hex: expectedScheme == .light ? 0xF7F6F1 : 0x0D0D0C)
                    assertColor(theme.surfacePrimary, hex: expectedScheme == .light ? 0xFFFFFF : 0x181817)
                    assertColor(theme.textPrimary, hex: expectedScheme == .light ? 0x020202 : 0xF7F6F1)
                    assertColor(theme.signalYellow, hex: 0xFFFE2A)
                    assertColor(theme.accentForeground, hex: expectedScheme == .light ? 0x020202 : 0xF7F6F1)
                }
            }
        }
    }

    func testReadableTextAndControlBoundariesOnEverySolidSurface() {
        for family in ThemeFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let theme = ZeroOneThemeTokens.resolve(family, colorScheme: scheme)
                // Separators are decorative. Focus is the interactive boundary role.
                assertColor(theme.strokeSubtle, hex: scheme == .light ? 0xDEDDD5 : 0x2A2A28)
                let backgrounds = [theme.backgroundPrimary, theme.surfacePrimary, theme.surfaceSecondary]
                let labels = [theme.textPrimary, theme.textSecondary, theme.textTertiary,
                              theme.accentForeground, theme.warningPrimary, theme.destructivePrimary]
                for background in backgrounds {
                    for label in labels {
                        XCTAssertGreaterThanOrEqual(contrast(label, background), 4.5, "\(family) \(scheme) text")
                    }
                    XCTAssertGreaterThanOrEqual(contrast(theme.focus, background), 3, "\(family) \(scheme) boundary")
                }
            }
        }
    }

    func testLegacyForegroundAliasesResolveForBothSystemTraits() {
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme)
            let resolved = UIColor(ZeroOneTheme.liquidCyan).resolvedColor(with: traits)
            assertColor(Color(uiColor: resolved), hex: scheme == .light ? 0x020202 : 0xF7F6F1)
        }
    }

    func testWidgetAndLegacyRolesFollowExplicitAppearance() {
        for scheme in [ColorScheme.light, .dark] {
            let theme = ZeroOneThemeTokens.resolve(.atelier, colorScheme: scheme, accent: .pink)
            let widget = DailyWidgetPalette(dark: scheme == .dark, accent: .pink)
            XCTAssertEqual(components(widget.background), components(theme.backgroundPrimary))
            XCTAssertEqual(components(widget.ink), components(theme.textPrimary))
            XCTAssertEqual(components(widget.secondary), components(theme.textSecondary))
            XCTAssertEqual(components(widget.track), components(theme.surfaceTertiary))
            assertColor(widget.track, hex: scheme == .dark ? 0x2D2D2B : 0xE4E3DB)
            assertColor(theme.successPrimary, hex: scheme == .dark ? 0x6CCB8A : 0x1A6E37)
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let legacy = Color(uiColor: UIColor(ZeroOneColors.background).resolvedColor(with: traits))
            XCTAssertEqual(components(legacy), components(theme.backgroundPrimary))
        }
    }

    private func assertColor(_ color: Color, hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let channels = components(color)
        XCTAssertEqual(channels[0], Double((hex >> 16) & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(channels[1], Double((hex >> 8) & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(channels[2], Double(hex & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
    }

    private func components(_ color: Color) -> [Double] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [Double(red), Double(green), Double(blue)]
    }

    private func luminance(_ color: Color) -> Double {
        let channels = components(color).map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    private func contrast(_ first: Color, _ second: Color) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
