import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

/// Focused actual modifier/render fixtures. Native execution and target fonts UNRUN.
@MainActor
final class ContextThemeTypographyRenderTests: XCTestCase {
    func testExplicitCoreContextUsesItsFontInsteadOfGlobalMetricShortcut() throws {
        let spec = contextSpec()
        let oracle = try oracleFont(for: .large)
        let effects = ZOThemeTextEffects(foreground: nil, shadows: [])
        let actual = Text(verbatim: "88:88")
            .zoThemeText(.metric, resolvedSpec: spec, effects: effects, designTheme: .core, colorScheme: .light)
            .foregroundStyle(Color.red)
        let expected = oracleText(font: oracle).foregroundStyle(Color.red)
        XCTAssertEqual(try pixels(actual), try pixels(expected))
        // A broad empty-render comparison cannot pass this case unnoticed.
        XCTAssertNotEqual(try pixels(actual), try pixels(Color.clear))
        let oldRole = Text(verbatim: "88:88")
            .zoThemeText(.metric, designTheme: .core, colorScheme: .light).foregroundStyle(Color.red)
        XCTAssertNotEqual(try pixels(actual), try pixels(oldRole))
    }

    func testExplicitEffectsOverrideCoreLocallyAndNilEffectsRetainCallerInk() throws {
        let spec = contextSpec(), oracle = try oracleFont(for: .large)
        let effects = ZOThemeTextEffects(foreground: AnyShapeStyle(Color.green), shadows: [])
        let actual = Text(verbatim: "88:88")
            .zoThemeText(.metric, resolvedSpec: spec, effects: effects, designTheme: .core, colorScheme: .light)
            .foregroundStyle(Color.red)
        XCTAssertEqual(try pixels(actual), try pixels(oracleText(font: oracle).foregroundStyle(Color.green)))
        XCTAssertNotEqual(try pixels(actual), try pixels(oracleText(font: oracle).foregroundStyle(Color.red)))
    }

    func testExplicitContextKeepsMetricDynamicTypeCapThroughActualModifier() throws {
        let spec = contextSpec(), effects = ZOThemeTextEffects(foreground: nil, shadows: [])
        let actual = Text(verbatim: "88:88")
            .zoThemeText(.metric, resolvedSpec: spec, effects: effects, designTheme: .core, colorScheme: .light)
            .foregroundStyle(Color.red)
        XCTAssertEqual(try pixels(actual, size: .accessibility5), try pixels(actual, size: .xxxLarge))
        XCTAssertEqual(try pixels(actual, size: .accessibility5),
                       try pixels(oracleText(font: oracleFont(for: .xxxLarge)).foregroundStyle(Color.red), size: .accessibility5))
    }

    private func contextSpec() -> ZOThemeTextSpec {
        var spec = ZOThemeTypography.spec(for: .core, role: .metric)
        spec.size = 44; spec.lineHeight = 44
        spec.weight = 700; spec.width = 75; spec.tracking = -0.5
        return spec
    }

    /// Independent fixed face/axes oracle, deliberately bypassing spec.font and the modifier.
    private func oracleFont(for size: DynamicTypeSize) throws -> CTFont {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "InstrumentSans-Variable", withExtension: "ttf"))
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let source = try XCTUnwrap(descriptors.first)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(source,
            [kCTFontVariationAttribute: [UInt32(0x77647468): CGFloat(75), UInt32(0x77676874): CGFloat(700)]] as CFDictionary)
        let capped = min(size, DynamicTypeSize.xxxLarge)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped))
        let points = UIFontMetrics(forTextStyle: .title1).scaledValue(for: 44, compatibleWith: traits)
        return CTFontCreateWithFontDescriptor(descriptor, points, nil)
    }

    private func oracleText(font: CTFont) -> some View {
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return Text(verbatim: "88:88").font(Font(font).monospacedDigit()).tracking(-0.5)
            .lineSpacing(max(0, CTFontGetSize(font) - natural))
    }

    private func pixels<V: View>(_ view: V, size: DynamicTypeSize = .large) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 160)
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light).frame(width: bounds.width, height: bounds.height))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.backgroundColor = .clear
        host.view.frame = bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            didDraw = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        let cgImage = try XCTUnwrap(image.cgImage)
        return (try XCTUnwrap(cgImage.dataProvider?.data)) as Data
    }
}
