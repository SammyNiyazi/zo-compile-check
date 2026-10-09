import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

/// Authored native/semantic coverage. Execution and resource/render acceptance are UNRUN.
final class ComponentThemeTypographyTests: XCTestCase {
    func testTwentySixThirtyScalesFromEitherRoleBaseWithoutKeepingGenericSize() {
        let metrics = ZOThemeComponentTextMetrics(size: 26, lineHeight: 30)
        for base in [CGFloat(32), 34] {
            XCTAssertEqual(metrics.scaledSize(baseSize: base, scaledBaseSize: base), 26)
            XCTAssertEqual(metrics.scaledLineHeight(baseSize: base, scaledBaseSize: base), 30)
            XCTAssertEqual(metrics.scaledSize(baseSize: base, scaledBaseSize: base * 2), 52)
            XCTAssertEqual(metrics.scaledLineHeight(baseSize: base, scaledBaseSize: base * 2), 60)
        }
    }

    func testMetricContextKeepsFreakAntonAndOtherThemesInstrumentAxes() {
        for theme in ZOTheme.allCases {
            let spec = ZOThemeTypography.spec(for: theme, role: .metric)
            XCTAssertEqual(spec.resource, theme == .freak ? .anton : .instrumentSans)
            XCTAssertEqual(spec.weight, theme == .freak ? 400 : 700)
            XCTAssertEqual(spec.width, theme == .freak ? 100 : 85)
            XCTAssertEqual(spec.tracking, theme == .freak ? 0.5 : 0)
            XCTAssertEqual(spec.uppercase, theme == .freak)
            XCTAssertTrue(spec.tabular)
            XCTAssertEqual(spec.maxSize, .xxxLarge)
            XCTAssertEqual(spec.size, theme == .freak ? 34 : 32)
            XCTAssertEqual(spec.lineHeight, theme == .freak ? 38 : 36)
        }
    }

    func testDisplayTitleContextsRetainTrueItalicAndStaticFaceRequests() {
        let princess = ZOThemeTypography.spec(for: .princess, role: .display)
        XCTAssertEqual(princess.resource, .frauncesItalic)
        XCTAssertEqual(princess.weight, 600)
        XCTAssertEqual(princess.width, 100)
        XCTAssertEqual(princess.obliqueDegrees, 0)
        XCTAssertEqual(princess.variations, [ZOThemeFontAxis.weight: 600, ZOThemeFontAxis.opticalSize: 72,
            ZOThemeFontAxis.softness: 100, ZOThemeFontAxis.wonk: 1])
        let retro = ZOThemeTypography.spec(for: .retro, role: .display)
        XCTAssertEqual(retro.resource, .monoton)
        XCTAssertEqual(retro.weight, 400)
        XCTAssertTrue(retro.variations.isEmpty)
        let retroTitle = ZOThemeTypography.spec(for: .retro, role: .title)
        XCTAssertEqual(retroTitle.resource, .instrumentSans)
        XCTAssertEqual(retroTitle.width, 75)
        XCTAssertEqual(retroTitle.obliqueDegrees, 10)
        XCTAssertEqual(ZOThemeTypography.spec(for: .freak, role: .display).resource, .pirataOne)
        // Existing unsupported static timer request is retained and diagnosed, not fabricated.
        XCTAssertTrue(ZOThemeTypography.spec(for: .retro, role: .timer).hasUnsupportedStaticRequest)
    }

    func testNativeFontCopyRetainsSelectedFaceVariationsAndMatrix() throws {
        let metrics = ZOThemeComponentTextMetrics(size: 26, lineHeight: 30)
        for theme in ZOTheme.allCases {
            for role in [ZOThemeTextRole.metric, .display, .title] {
                let spec = ZOThemeTypography.spec(for: theme, role: role)
                let base = try spec.font(for: .large)
                let copy = metrics.font(resizing: base, baseSize: spec.size)
                XCTAssertEqual(CTFontGetSize(copy), 26 * CTFontGetSize(base) / spec.size, accuracy: 0.0001)
                XCTAssertEqual(CTFontCopyPostScriptName(copy) as String, CTFontCopyPostScriptName(base) as String)
                XCTAssertEqual(CTFontGetMatrix(copy), CTFontGetMatrix(base))
                XCTAssertEqual(CTFontCopyVariation(copy) as? [NSNumber: NSNumber],
                               CTFontCopyVariation(base) as? [NSNumber: NSNumber])
                if theme == .princess && (role == .display || role == .title) {
                    XCTAssertTrue(CTFontGetSymbolicTraits(copy).contains(.traitItalic))
                }
            }
        }
    }

    func testMetricComponentKeepsCurrentDynamicTypeCapAndBaseFontRatio() throws {
        let metrics = ZOThemeComponentTextMetrics(size: 26, lineHeight: 30)
        for theme in ZOTheme.allCases {
            let spec = ZOThemeTypography.spec(for: theme, role: .metric)
            let capped = try spec.font(for: .xxxLarge)
            let accessibility = try spec.font(for: .accessibility5)
            XCTAssertEqual(CTFontGetSize(accessibility), CTFontGetSize(capped), accuracy: 0.0001)
            let copy = metrics.font(resizing: accessibility, baseSize: spec.size)
            XCTAssertEqual(CTFontGetSize(copy), 26 * CTFontGetSize(capped) / spec.size, accuracy: 0.0001)
            XCTAssertEqual(metrics.scaledLineHeight(baseSize: spec.size, scaledBaseSize: CTFontGetSize(capped)),
                           30 * CTFontGetSize(capped) / spec.size, accuracy: 0.0001)
        }
    }

    func testCoreComponentUsesGeneratedRoleScalingAndDoesNotSetANewCap() {
        let spec = ZOThemeTypography.spec(for: .core, role: .metric)
        let base = ZOTextStyle.metric.ctFont(for: .accessibility5)
        let capped = ZOTextStyle.metric.ctFont(for: .xxxLarge)
        let metrics = ZOThemeComponentTextMetrics(size: 26, lineHeight: 30)
        XCTAssertEqual(CTFontGetSize(base), CTFontGetSize(capped), accuracy: 0.0001)
        let copy = metrics.font(resizing: base, baseSize: spec.size)
        XCTAssertEqual(CTFontGetSize(copy), 26 * CTFontGetSize(base) / 32, accuracy: 0.0001)
        XCTAssertEqual(CTFontCopyVariation(copy) as? [NSNumber: NSNumber],
                       CTFontCopyVariation(base) as? [NSNumber: NSNumber])
    }

    func testMetricEffectsRemainRoleAndModeSpecificWithoutHeadingDecoration() {
        let retroDark = ZOThemeTextEffects.resolve(designTheme: .retro, role: .metric, colorScheme: .dark)
        XCTAssertEqual(retroDark.shadows.count, 1)
        XCTAssertEqual(retroDark.shadows.first?.cssBlur, 10)
        XCTAssertNil(retroDark.gradientStops)
        XCTAssertTrue(ZOThemeTextEffects.resolve(designTheme: .retro, role: .metric, colorScheme: .light).shadows.isEmpty)
        XCTAssertNil(ZOThemeTextEffects.resolve(designTheme: .freak, role: .metric, colorScheme: .dark).gradientStops)
        XCTAssertFalse(ZOThemeTextRole.metric.isHeadingSigilEligible(in: .headRowDisplay))
        XCTAssertFalse(ZOThemeTextRole.metric.isHeadingSigilEligible(in: .directScrollDisplay))
    }
}
