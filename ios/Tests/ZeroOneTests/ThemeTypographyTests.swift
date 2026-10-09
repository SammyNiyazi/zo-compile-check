import CoreText
import SwiftUI
import XCTest
@testable import ZeroOne

final class ThemeTypographyTests: XCTestCase {
    func testPrincessUsesTrueItalicResourceAndAllFourPinnedAxes() throws {
        let spec = ZOThemeTypography.spec(for: .princess, role: .display)
        XCTAssertEqual(spec.resource, .frauncesItalic)
        XCTAssertEqual(spec.resource.expectedPostScriptName, "Fraunces-9ptBlackItalic")
        XCTAssertEqual(spec.variations, [ZOThemeFontAxis.weight: 600, ZOThemeFontAxis.opticalSize: 72,
            ZOThemeFontAxis.softness: 100, ZOThemeFontAxis.wonk: 1])
        XCTAssertEqual(spec.obliqueDegrees, 0)
        let font = try spec.font(for: .large)
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Fraunces")
        XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitItalic))
        let values = try XCTUnwrap(CTFontCopyVariation(font) as? [NSNumber: NSNumber])
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        for (axis, value) in spec.variations {
            // iOS 26 omits an axis already at its default (Fraunces WONK defaults to 1).
            let defaultValue = axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == axis }?[
                kCTFontVariationAxisDefaultValueKey as String] as? NSNumber
            XCTAssertEqual(try XCTUnwrap(values[NSNumber(value: axis)] ?? defaultValue).doubleValue, Double(value), accuracy: 0.001)
        }
    }

    func testRetroUnsupportedStaticTimerRequestDoesNotInventAxes() throws {
        let timer = ZOThemeTypography.spec(for: .retro, role: .timer)
        XCTAssertEqual(timer.resource, .monoton)
        XCTAssertEqual(timer.weight, 600)
        XCTAssertEqual(timer.width, 75)
        XCTAssertTrue(timer.hasUnsupportedStaticRequest)
        XCTAssertTrue(timer.variations.isEmpty)
        let font = try timer.font(for: .large)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Monoton-Regular")
        let axes = CTFontCopyVariationAxes(font) as? [Any]
        XCTAssertTrue(axes?.isEmpty ?? true)
    }

    func testThemeNumericPolicyKeepsOriginalDynamicTypeCaps() {
        for theme in ZOTheme.allCases {
            let metric = ZOThemeTypography.spec(for: theme, role: .metric)
            let timer = ZOThemeTypography.spec(for: theme, role: .timer)
            let hero = ZOThemeTypography.spec(for: theme, role: .timerHero)
            XCTAssertEqual(metric.maxSize, .xxxLarge)
            XCTAssertEqual(timer.maxSize, .xxxLarge)
            XCTAssertEqual(hero.maxSize, .large)
            XCTAssertEqual(metric.scaledSize(for: .accessibility5), metric.scaledSize(for: .xxxLarge), accuracy: 0.001)
            XCTAssertEqual(hero.scaledSize(for: .accessibility5), hero.scaledSize(for: .large), accuracy: 0.001)
            let display = ZOThemeTypography.spec(for: theme, role: .display)
            XCTAssertNil(display.maxSize)
            XCTAssertGreaterThan(display.scaledSize(for: .accessibility5), display.scaledSize(for: .large))
        }
    }

    func testFreakButtonCasingAndFaceAreRestrictedToPrimaryRole() {
        let primary = ZOThemeTypography.spec(for: .freak, role: .primaryButton)
        XCTAssertEqual(primary.resource, .anton)
        XCTAssertEqual(primary.size, 20)
        XCTAssertEqual(primary.lineHeight, 22)
        XCTAssertEqual(primary.tracking, 1.5)
        XCTAssertTrue(primary.uppercase)
        for role in [ZOThemeTextRole.body, .label, .caption, .section] {
            let ordinary = ZOThemeTypography.spec(for: .freak, role: role)
            XCTAssertEqual(ordinary.resource, .instrumentSans)
            XCTAssertFalse(ordinary.uppercase)
        }
        XCTAssertEqual(ZOThemeTypography.spec(for: .princess, role: .timer).resource, .instrumentSans)
    }

    func testCoreFontsRemainEquivalentToGeneratedFacesAndScaling() throws {
        for role in ZOThemeTextRole.allCases {
            let expected = role.baseStyle.ctFont(for: .accessibility5)
            let core = try ZOThemeTypography.font(for: .core, role: role, dynamicTypeSize: .accessibility5)
            XCTAssertEqual(CTFontCopyPostScriptName(core) as String, CTFontCopyPostScriptName(expected) as String)
            XCTAssertEqual(CTFontGetSize(core), CTFontGetSize(expected), accuracy: 0.001)
            XCTAssertEqual(CTFontCopyVariation(core) as? [NSNumber: NSNumber],
                CTFontCopyVariation(expected) as? [NSNumber: NSNumber])
        }
    }

    func testStaticThemeRolesResolveTheirActualPinnedFaces() throws {
        let requests: [(ZOTheme, ZOThemeTextRole, String)] = [
            (.freak, .display, "PirataOne-Regular"), (.freak, .primaryButton, "Anton-Regular"),
            (.retro, .display, "Monoton-Regular")]
        for (theme, role, postScriptName) in requests {
            let font = try ZOThemeTypography.font(for: theme, role: role, dynamicTypeSize: .large)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, postScriptName)
        }
    }

    func testMissingResourceBundleIsRejectedByThrowingPreflight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: String] = ["CFBundleIdentifier": "app.the01.tests.empty-theme-fonts", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let emptyBundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertThrowsError(try ZOThemeTypography.font(for: .princess, role: .title,
            dynamicTypeSize: .large, bundle: emptyBundle)) { error in
            guard let fontError = error as? ZOThemeFontError,
                  case let .missingResource(filename) = fontError else {
                return XCTFail("Missing bundle must reject theme preflight, got \(error)")
            }
            XCTAssertEqual(filename, "Fraunces-Italic-Variable.ttf")
        }
    }

    func testEffectsRespectModeAndGlyphSelectors() {
        let dark = ZOThemeTextEffects.resolve(designTheme: .retro, role: .display, colorScheme: .dark)
        XCTAssertEqual(dark.shadows.map(\.cssBlur), [4, 14, 30])
        let light = ZOThemeTextEffects.resolve(designTheme: .retro, role: .display, colorScheme: .light)
        XCTAssertEqual(light.shadows.map(\.cssBlur), [0, 0])
        XCTAssertEqual(light.shadows.map(\.x), [2, 4])
        XCTAssertTrue(ZOThemeTextEffects.resolve(designTheme: .retro, role: .metric, colorScheme: .light).shadows.isEmpty)
        let title = ZOThemeTextEffects.resolve(designTheme: .retro, role: .title, colorScheme: .light)
        XCTAssertEqual(title.gradientStops?.map(\.location), [0, 0.54, 0.54, 0.59, 0.59, 0.68, 0.68, 0.72, 0.72, 0.82, 0.82, 0.86, 0.86, 1])
        let chrome = ZOThemeTextEffects.resolve(designTheme: .freak, role: .display, colorScheme: .dark)
        XCTAssertEqual(chrome.gradientStops?.map(\.location), [0, 0.3, 0.5, 0.52, 0.8, 1])
        XCTAssertNil(ZOThemeTextEffects.resolve(designTheme: .freak, role: .title, colorScheme: .dark).foreground)
        XCTAssertNil(ZOThemeTextEffects.resolve(designTheme: .freak, role: .display, colorScheme: .light).foreground)
    }

    func testOutOfRangeVariableRequestFailsInsteadOfSilentlyClamping() throws {
        var spec = ZOThemeTypography.spec(for: .princess, role: .title)
        spec.weight = 1000
        XCTAssertThrowsError(try spec.font(for: .large)) { error in
            guard let fontError = error as? ZOThemeFontError,
                  case let .unsupportedVariation(axis, value) = fontError else {
                return XCTFail("Expected explicit unsupported-variation diagnostic, got \(error)")
            }
            XCTAssertEqual(axis, ZOThemeFontAxis.weight)
            XCTAssertEqual(value, 1000)
        }
    }
}
