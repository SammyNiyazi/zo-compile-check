import CoreText
import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class DesignTokensTests: XCTestCase {
    private let widthAxis = 0x77647468
    private let weightAxis = 0x77676874

    func testBundledVariableFontMatchesApprovedSource() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InstrumentSans-Variable", withExtension: "ttf"))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "b24f1812584816958afcf22e22d08e44318c5e51651e25d2438efdde389b33b1")
        XCTAssertNotNil(Bundle.main.url(forResource: "InstrumentSans-Variable-OFL", withExtension: "txt"))
    }

    func testAllTenStylesResolveTheVariableResourceAndBothAxes() throws {
        XCTAssertEqual(ZOTextStyle.allCases.count, 10)
        let resourceURL = try XCTUnwrap(Bundle.main.url(forResource: "InstrumentSans-Variable", withExtension: "ttf"))
        for size in [DynamicTypeSize.large, .accessibility5] {
            for style in ZOTextStyle.allCases {
                let font = style.ctFont(for: size)
                let resolvedURL = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
                XCTAssertEqual(resolvedURL.standardizedFileURL, resourceURL.standardizedFileURL)
                let axes = try XCTUnwrap(CTFontCopyVariationAxes(font) as? [[String: Any]])
                let identifiers = Set(axes.compactMap { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue })
                XCTAssertTrue(identifiers.contains(widthAxis), "Missing width axis for \(style)")
                XCTAssertTrue(identifiers.contains(weightAxis), "Missing weight axis for \(style)")
                let variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
                for (axisID, expected) in [(widthAxis, style.spec.width), (weightAxis, style.spec.weight)] {
                    let axis = try XCTUnwrap(axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == axisID })
                    let fallback = try XCTUnwrap(axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)
                    let actual = variations[NSNumber(value: axisID)] ?? fallback
                    XCTAssertEqual(actual.doubleValue, Double(expected), accuracy: 0.01, "Wrong axis for \(style) at \(size)")
                }
            }
        }
    }

    func testDynamicTypeScalesTextAndPreservesApprovedNumericCaps() {
        XCTAssertGreaterThan(CTFontGetSize(ZOTextStyle.body.ctFont(for: .accessibility5)), CTFontGetSize(ZOTextStyle.body.ctFont(for: .large)))
        XCTAssertEqual(CTFontGetSize(ZOTextStyle.timerHero.ctFont(for: .large)), 112, accuracy: 0.01)
        XCTAssertEqual(CTFontGetSize(ZOTextStyle.timerHero.ctFont(for: .accessibility5)), 112, accuracy: 0.01)
        for style in [ZOTextStyle.metric, .timer] {
            XCTAssertEqual(CTFontGetSize(style.ctFont(for: .xxxLarge)), CTFontGetSize(style.ctFont(for: .accessibility5)), accuracy: 0.01)
        }
    }

    func testLoadingVariableStylesDoesNotReplaceLegacyStaticRegular() throws {
        ZeroOneFontRegistrar.registerBundledFonts()
        let before = try XCTUnwrap(UIFont(name: "InstrumentSans-Regular", size: 17))
        XCTAssertNil(CTFontCopyVariationAxes(before as CTFont))
        let beforeURL = CTFontCopyAttribute(before as CTFont, kCTFontURLAttribute) as? URL
        for style in ZOTextStyle.allCases { _ = style.ctFont(for: .accessibility5) }
        let after = try XCTUnwrap(UIFont(name: "InstrumentSans-Regular", size: 17))
        XCTAssertNil(CTFontCopyVariationAxes(after as CTFont))
        XCTAssertEqual(CTFontCopyAttribute(after as CTFont, kCTFontURLAttribute) as? URL, beforeURL)
        XCTAssertEqual(after.pointSize, before.pointSize)
    }

    func testCoreRolesResolveInBothAppearances() {
        assertHex(ZOColor.canvas, light: 0xF7F6F1, dark: 0x0D0D0C)
        assertHex(ZOColor.surface1, light: 0xFFFFFF, dark: 0x181817)
        assertHex(ZOColor.surface2, light: 0xEFEEE8, dark: 0x222221)
        assertHex(ZOColor.surface3, light: 0xE4E3DB, dark: 0x2D2D2B)
        assertHex(ZOColor.inkPrimary, light: 0x020202, dark: 0xF7F6F1)
        assertHex(ZOColor.Swatch.pink.fill, light: 0xFF9AD5, dark: 0xFF9AD5)
        XCTAssertNotEqual(rgb(ZOColor.Status.success, .dark), rgb(ZOColor.Swatch.yellow.fill, .dark))
    }

    func testResolvedCoreTextAndDataContrast() {
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            for surface in [ZOColor.canvas, ZOColor.surface1, ZOColor.surface2, ZOColor.surface3] {
                XCTAssertGreaterThanOrEqual(contrast(ZOColor.inkPrimary, surface, scheme), 7)
                for ink in [ZOColor.inkSecondary, ZOColor.inkTertiary, ZOColor.Status.success, ZOColor.Status.warning, ZOColor.Status.error] {
                    XCTAssertGreaterThanOrEqual(contrast(ink, surface, scheme), 4.5)
                }
            }
            for surface in [ZOColor.canvas, ZOColor.surface1, ZOColor.surface2] {
                for ink in [ZOColor.Data.protein, ZOColor.Data.carbs, ZOColor.Data.fat, ZOColor.Data.sleep] {
                    XCTAssertGreaterThanOrEqual(contrast(ink, surface, scheme), 3)
                }
            }
            for swatch in ZOColor.Swatch.allCases {
                XCTAssertGreaterThanOrEqual(contrast(swatch.on, swatch.fill, scheme), 7)
                XCTAssertGreaterThanOrEqual(contrast(swatch.on, swatch.pressed, scheme), 7)
            }
        }
    }

    func testEveryThemePreservesLegibleRolesAndOwnAccent() throws {
        XCTAssertNil(ZOTheme.core.palette(dark: true))
        for theme in [ZOTheme.retro, .freak, .princess] {
            for dark in [false, true] {
                let palette = try XCTUnwrap(theme.palette(dark: dark))
                let scheme: UIUserInterfaceStyle = dark ? .dark : .light
                XCTAssertNotEqual(rgb(palette.accent, scheme), rgb(ZOColor.Swatch.yellow.fill, scheme))
                for surface in [palette.canvas, palette.surface1, palette.surface2, palette.surface3] {
                    XCTAssertGreaterThanOrEqual(contrast(palette.inkPrimary, surface, scheme), 7)
                    XCTAssertGreaterThanOrEqual(contrast(palette.inkSecondary, surface, scheme), 4.5)
                    XCTAssertGreaterThanOrEqual(contrast(palette.inkTertiary, surface, scheme), 4.5)
                }
            }
        }
    }

    private func rgb(_ color: Color, _ scheme: UIUserInterfaceStyle) -> [CGFloat] {
        let value = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(value.getRed(&r, green: &g, blue: &b, alpha: &a))
        return [r, g, b]
    }

    private func assertHex(_ color: Color, light: UInt32, dark: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        for (scheme, hex) in [(UIUserInterfaceStyle.light, light), (.dark, dark)] {
            let actual = rgb(color, scheme)
            let expected = [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255]
            for index in 0..<3 { XCTAssertEqual(actual[index], expected[index], accuracy: 0.001, file: file, line: line) }
        }
    }

    private func contrast(_ foreground: Color, _ background: Color, _ scheme: UIUserInterfaceStyle) -> Double {
        func luminance(_ color: Color) -> Double {
            let values = rgb(color, scheme).map { component -> Double in
                let c = Double(component)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
