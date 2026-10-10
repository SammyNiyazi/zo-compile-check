import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class ThemeScreenSurfaceTests: XCTestCase {
    func testRetroHorizonUsesPercentageRadiiAndOffscreenCenter() throws {
        let spec = specification(.retro, .dark)
        let radial = try XCTUnwrap(spec.radials.first)
        assertRect(radial.ellipse(in: CGSize(width: 200, height: 100)), CGRect(x: -140, y: 50, width: 480, height: 120))
        XCTAssertEqual(radial.fade, 0.6)
        assertColor(radial.color, Color(zoHex: 0xC04DFF, alpha: 0.16))
        XCTAssertNil(spec.linear)
        let light = specification(.retro, .light)
        XCTAssertTrue(light.radials.isEmpty)
        let linear = try XCTUnwrap(light.linear)
        XCTAssertEqual(linear.cssDegrees, 0)
        XCTAssertEqual(linear.stops.map(\.location), [0, 0.22, 1])
        assertColor(linear.stops[0].color, Color(zoHex: 0xFF8A3D, alpha: 0.14))
        XCTAssertEqual(channels(linear.stops[1].color)[3], 0, accuracy: 0.001)
    }

    func testPrincessLayerOrderAndEllipsesInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let spec = specification(.princess, scheme)
            XCTAssertEqual(spec.radials.count, 2)
            let bottom = spec.radials[0], top = spec.radials[1]
            assertRect(bottom.ellipse(in: CGSize(width: 200, height: 100)), CGRect(x: -160, y: 60, width: 320, height: 80))
            assertRect(top.ellipse(in: CGSize(width: 200, height: 100)), CGRect(x: -10, y: -50, width: 360, height: 100))
            assertColor(bottom.color, spec.theme.accentFill.opacity(0.14))
            assertColor(top.color, Color(zoHex: 0xC9B4FF, alpha: 0.22))
            XCTAssertEqual(bottom.fade, 0.7)
            XCTAssertEqual(top.fade, 0.7)
            XCTAssertNil(spec.backgroundStripe)
            XCTAssertNil(spec.foregroundStripe)
        }
    }

    func testFreakAppearanceChangesOnlyTheSpecifiedBackgroundLayers() throws {
        let dark = specification(.freak, .dark)
        let radial = try XCTUnwrap(dark.radials.first)
        assertRect(radial.ellipse(in: CGSize(width: 200, height: 100)), CGRect(x: -80, y: -40, width: 360, height: 80))
        assertColor(radial.color, dark.theme.textPrimary.opacity(0.07))
        XCTAssertEqual(radial.fade, 0.7)
        XCTAssertNil(dark.backgroundStripe)
        XCTAssertNil(dark.foregroundStripe)
        let light = specification(.freak, .light)
        XCTAssertTrue(light.radials.isEmpty)
        let linear = try XCTUnwrap(light.linear)
        XCTAssertEqual(linear.cssDegrees, 170)
        XCTAssertEqual(linear.stops.map(\.location), [0, 0.4, 1])
        assertColor(linear.stops[0].color, light.theme.surfacePrimary)
        assertColor(linear.stops[1].color, light.theme.backgroundPrimary)
        assertColor(linear.stops[2].color, light.theme.surfaceSecondary)
        assertColor(try XCTUnwrap(light.backgroundStripe).color, Color(zoHex: 0xFFFFFF, alpha: 0.3))
        XCTAssertNil(light.foregroundStripe)
    }

    func testScanlineTopologyAndLayerSelection() throws {
        for scheme in [ColorScheme.light, .dark] {
            let spec = specification(.retro, scheme)
            let stripe = try XCTUnwrap(spec.foregroundStripe)
            let path = stripe.shape.path(in: CGRect(x: 12, y: 30, width: 20, height: 10))
            XCTAssertTrue(path.contains(CGPoint(x: 20, y: 30.5)))
            XCTAssertFalse(path.contains(CGPoint(x: 20, y: 31.5)))
            XCTAssertTrue(path.contains(CGPoint(x: 20, y: 33.5)))
            XCTAssertFalse(path.contains(CGPoint(x: 20, y: 34.5)))
            assertColor(stripe.color, scheme == .dark ? Color(zoHex: 0xFFE9A8, alpha: 0.05) : spec.theme.textPrimary.opacity(0.025))
            XCTAssertNil(spec.backgroundStripe)
        }
        let stripe = try XCTUnwrap(specification(.freak, .light).backgroundStripe)
        let path = stripe.shape.path(in: CGRect(x: 12, y: 30, width: 10, height: 20))
        XCTAssertTrue(path.contains(CGPoint(x: 12.5, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: 13.5, y: 40)))
        XCTAssertTrue(path.contains(CGPoint(x: 16.5, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: 17.5, y: 40)))
        XCTAssertTrue(stripe.shape.path(in: .zero).isEmpty)
    }

    func testCoreHasOnlyCanvasAndStaticSpecificationHasNoExtraLayers() {
        for scheme in [ColorScheme.light, .dark] {
            let core = specification(.core, scheme)
            XCTAssertTrue(core.radials.isEmpty)
            XCTAssertNil(core.linear)
            XCTAssertNil(core.backgroundStripe)
            XCTAssertNil(core.foregroundStripe)
        }
    }

    private func specification(_ designTheme: ZOTheme, _ scheme: ColorScheme) -> ZOThemeScreenSpecification {
        .init(theme: ZeroOneThemeTokens.resolve(designTheme: designTheme, colorScheme: scheme))
    }
    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip([actual.minX, actual.minY, actual.width, actual.height],
                [expected.minX, expected.minY, expected.width, expected.height]) {
            XCTAssertEqual(a, b, accuracy: 0.000001, file: file, line: line)
        }
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
