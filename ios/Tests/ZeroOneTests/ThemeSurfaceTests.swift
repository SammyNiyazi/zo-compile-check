import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class ThemeSurfaceTests: XCTestCase {
    func testThemeShapeRadiusRolesKeepCoreCallerRadius() {
        for role in [ZOThemeComponentRole.card, .button, .control] {
            XCTAssertEqual(ZOThemeComponentShape(theme: .core, role: role, radius: 37).resolvedRadius, 37)
            XCTAssertEqual(ZOThemeComponentShape(theme: .retro, role: role, radius: 37).resolvedRadius, 37)
            XCTAssertEqual(ZOThemeComponentShape(theme: .freak, role: role, radius: 37).resolvedRadius, 2)
        }
        XCTAssertEqual(ZOThemeComponentShape(theme: .core, role: .card).resolvedRadius, 16)
        XCTAssertEqual(ZOThemeComponentShape(theme: .princess, role: .card).resolvedRadius, 22)
        XCTAssertEqual(ZOThemeComponentShape(theme: .princess, role: .button).resolvedRadius, 26)
        XCTAssertEqual(ZOThemeComponentShape(theme: .princess, role: .control).resolvedRadius, 16)
    }

    func testFreakCutRemovesOnlySpecifiedCornersAndPreservesTwoPixelArcs() {
        let path = ZOThemeComponentShape(theme: .freak, role: .card).path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 4)))
        XCTAssertTrue(path.contains(CGPoint(x: 6, y: 6)))
        XCTAssertFalse(path.contains(CGPoint(x: 96, y: 96)))
        XCTAssertTrue(path.contains(CGPoint(x: 94, y: 94)))
        XCTAssertTrue(path.contains(CGPoint(x: 96, y: 4)))
        XCTAssertTrue(path.contains(CGPoint(x: 4, y: 96)))
        XCTAssertFalse(path.contains(CGPoint(x: 99.9, y: 0.1)))
        XCTAssertTrue(path.contains(CGPoint(x: 99.4, y: 0.6)))
        XCTAssertEqual(path.boundingRect, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(ZOThemeComponentShape(theme: .freak, role: .card).path(in: .zero).isEmpty)
    }

    func testCSSGradientAngleUsesRectangularMagicCornerGeometry() {
        let points = ZOThemeGradientGeometry.endpoints(cssDegrees: 140, size: CGSize(width: 320, height: 80))
        // CSS 140-degree gradient on a 4:1 box projects its line beyond the vertical edges.
        XCTAssertEqual(points.start.x, 0.231861560, accuracy: 0.000001)
        XCTAssertEqual(points.start.y, -0.778219797, accuracy: 0.000001)
        XCTAssertEqual(points.end.x, 0.768138440, accuracy: 0.000001)
        XCTAssertEqual(points.end.y, 1.778219797, accuracy: 0.000001)
        let down = ZOThemeGradientGeometry.endpoints(cssDegrees: 180, size: CGSize(width: 320, height: 80))
        XCTAssertEqual(down.start.x, 0.5, accuracy: 0.000001)
        XCTAssertEqual(down.start.y, 0, accuracy: 0.000001)
        XCTAssertEqual(down.end.y, 1, accuracy: 0.000001)
        let zero = ZOThemeGradientGeometry.endpoints(cssDegrees: 140, size: .zero)
        XCTAssertEqual(zero.start, .center)
        XCTAssertEqual(zero.end, .center)
    }

    func testPrincessDefaultSheenStopsAndExplicitOverride() throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = ZeroOneThemeTokens.resolve(designTheme: .princess, colorScheme: scheme)
            let surface = ZOThemeCardSurface(theme: theme)
            let stops = try XCTUnwrap(surface.gradientStops)
            XCTAssertEqual(stops.map(\.location), [0, 0.55, 1])
            assertColor(stops[0].color, theme.surfacePrimary)
            assertColor(stops[1].color, theme.surfacePrimary)
            let channels = components(stops[2].color)
            let base = scheme == .dark ? [38.0, 23.0, 45.0] : [255.0, 255.0, 255.0]
            for index in 0..<3 {
                XCTAssertEqual(channels[index], ([201.0, 180.0, 255.0][index] * 0.12 + base[index] * 0.88) / 255, accuracy: 0.001)
            }
            let override = ZOThemeCardSurface(theme: theme, background: theme.surfaceSecondary, radius: 9)
            XCTAssertNil(override.gradientStops)
            assertColor(try XCTUnwrap(override.background), theme.surfaceSecondary)
        }
    }

    func testCardEdgesMatchRetroAndFreakCSSWithoutCoreDecorations() {
        for scheme in [ColorScheme.light, .dark] {
            let retro = ZeroOneThemeTokens.resolve(designTheme: .retro, colorScheme: scheme)
            let edge = ZOThemeCardSurface(theme: retro).borderColor
            assertColor(edge, scheme == .dark ? Color(zoHex: 0xC04DFF, alpha: 0.26) : retro.separatorStrong)
            let freak = ZeroOneThemeTokens.resolve(designTheme: .freak, colorScheme: scheme)
            assertColor(ZOThemeCardSurface(theme: freak).borderColor, freak.separatorStrong)
            assertColor(ZOThemeCardSurface(theme: freak).topHighlight, freak.textPrimary.opacity(0.14))
            let core = ZOThemeCardSurface(theme: ZeroOneThemeTokens.resolve(designTheme: .core, colorScheme: scheme))
            XCTAssertNil(core.gradientStops)
            XCTAssertEqual(components(core.borderColor)[3], 0, accuracy: 0.001)
            XCTAssertEqual(components(core.topHighlight)[3], 0, accuracy: 0.001)
        }
    }

    private func components(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    private func assertColor(_ actual: Color, _ expected: Color, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(components(actual), components(expected)) {
            XCTAssertEqual(a, b, accuracy: 0.001, file: file, line: line)
        }
    }
}
