import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class FinalThemePresentationTests: XCTestCase {
    func testFinalThemesUseGeneratedRolesInBothModesAndOverrideCoreAccent() throws {
        for designTheme in [ZOTheme.retro, .freak, .princess] {
            for scheme in [ColorScheme.light, .dark] {
                let palette = try XCTUnwrap(designTheme.palette(dark: scheme == .dark))
                for accent in AccentPreference.allCases {
                    let theme = ZeroOneThemeTokens.resolve(designTheme: designTheme, colorScheme: scheme, accent: accent)
                    XCTAssertEqual(theme.designTheme, designTheme)
                    XCTAssertEqual(theme.accentPreference, accent)
                    let actual = [theme.backgroundPrimary, theme.surfacePrimary, theme.surfaceSecondary,
                        theme.surfaceTertiary, theme.textPrimary, theme.textSecondary, theme.textTertiary,
                        theme.strokeSubtle, theme.separatorStrong, theme.focus, theme.accentFill, theme.onAccent]
                    let expected = [palette.canvas, palette.surface1, palette.surface2, palette.surface3,
                        palette.inkPrimary, palette.inkSecondary, palette.inkTertiary,
                        palette.separator, palette.separatorStrong, palette.focus, palette.accent, palette.onAccent]
                    for (value, reference) in zip(actual, expected) { assertColor(value, reference) }
                    assertColor(theme.signalYellow, palette.accent)
                    assertColor(theme.chartAccent, palette.inkPrimary)
                    assertColor(theme.disabledAccentFill, palette.surface3)
                    assertColor(theme.disabledAccentForeground, palette.inkTertiary)
                    XCTAssertEqual(theme.displayFont, palette.displayFont)
                }
            }
        }
    }

    func testLegacyFamiliesKeepCoreRolesAndIdentifiers() {
        XCTAssertEqual(ThemeFamily.allCases.map(\.rawValue), ["liquidMidnight", "iridescentAura", "atelier"])
        for family in ThemeFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for accent in AccentPreference.allCases {
                    let legacy = ZeroOneThemeTokens.resolve(family, colorScheme: scheme, accent: accent)
                    let core = ZeroOneThemeTokens.resolve(designTheme: .core, colorScheme: scheme, accent: accent)
                    XCTAssertEqual(legacy.id, family)
                    XCTAssertEqual(legacy.designTheme, .core)
                    assertColor(legacy.backgroundPrimary, core.backgroundPrimary)
                    assertColor(legacy.accentFill, accent.fill)
                    assertColor(legacy.accentPressed, accent.swatch.pressed)
                    assertColor(legacy.accentEdge, accent.swatch.edge(in: scheme))
                }
            }
        }
    }

    func testAppearanceResolutionUsesCallerSystemScheme() {
        for scheme in [ColorScheme.light, .dark] {
            for appearance in AppearancePreference.allCases {
                let theme = ZeroOneThemeTokens.resolve(appearance: appearance, systemColorScheme: scheme,
                    designTheme: .retro, accent: .pink)
                XCTAssertEqual(theme.colorScheme, appearance.preferredColorScheme ?? scheme)
                XCTAssertEqual(theme.designTheme, .retro)
            }
        }
    }

    func testThemePressedAndEdgeStatesMatchFinalTokenValues() {
        let cases: [(ZOTheme, UInt32, UInt32, UInt32, Double)] = [
            (.retro, 0xF29F18, 0xF0B932, 0x2A0E1E, 0.16),
            (.freak, 0x2B2F35, 0xC3C8CF, 0x050506, 0.30),
            (.princess, 0xF28AC8, 0xF28AC8, 0x35122B, 0.14)
        ]
        for (designTheme, lightPressed, darkPressed, edge, alpha) in cases {
            let light = ZeroOneThemeTokens.resolve(designTheme: designTheme, colorScheme: .light)
            let dark = ZeroOneThemeTokens.resolve(designTheme: designTheme, colorScheme: .dark)
            assertColor(light.accentPressed, Color(zoHex: lightPressed))
            assertColor(dark.accentPressed, Color(zoHex: darkPressed))
            assertColor(light.accentEdge, Color(zoHex: edge, alpha: alpha))
            XCTAssertEqual(channels(dark.accentEdge)[3], 0, accuracy: 0.001)
        }
    }

    func testRetroAndFreakPrimaryBackgroundStopsFollowFinalCSS() {
        let retroDark = ZeroOneThemeTokens.resolve(designTheme: .retro)
        XCTAssertEqual(retroDark.primaryActionGradientStops.map(\.location), [0, 0.30, 0.72, 1])
        for (stop, hex) in zip(retroDark.primaryActionGradientStops, [UInt32(0xFFE9A8), 0xFFC94A, 0xFF8A3D, 0xFF4D6D]) {
            assertColor(stop.color, Color(zoHex: hex))
        }
        let retroLight = ZeroOneThemeTokens.resolve(designTheme: .retro, colorScheme: .light)
        XCTAssertEqual(retroLight.primaryActionGradientStops.map(\.location), [0, 0.62, 1])
        let freakDark = ZeroOneThemeTokens.resolve(designTheme: .freak)
        let freakLight = ZeroOneThemeTokens.resolve(designTheme: .freak, colorScheme: .light)
        XCTAssertEqual(freakDark.primaryActionGradientStops.map(\.location), [0, 0.26, 0.58, 1])
        XCTAssertEqual(freakLight.primaryActionGradientStops.map(\.location), [0, 0.26, 0.58, 1])
        let darkFoot = channels(freakDark.primaryActionGradientStops[3].color)
        XCTAssertEqual(darkFoot[0], (217 * 0.78 + 141 * 0.22) / 255, accuracy: 0.001)
        let lightTop = channels(freakLight.primaryActionGradientStops[0].color)
        XCTAssertEqual(lightTop[0], (30 * 0.70 + 255 * 0.30) / 255, accuracy: 0.001)
        XCTAssertTrue(ZeroOneThemeTokens.resolve(designTheme: .core).primaryActionGradientStops.isEmpty)
        XCTAssertTrue(ZeroOneThemeTokens.resolve(designTheme: .princess).primaryActionGradientStops.isEmpty)
    }

    private func channels(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    private func assertColor(_ actual: Color, _ expected: Color, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(channels(actual), channels(expected)) {
            XCTAssertEqual(a, b, accuracy: 0.001, file: file, line: line)
        }
    }
}
