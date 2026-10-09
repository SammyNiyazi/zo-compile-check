import CoreText
import SwiftUI
import UIKit

/// Component-specific sizes from the final components.css, using the generated
/// Instrument Sans face and Dynamic Type rules. Generated tokens stay untouched.
private struct ZOProofTextModifier: ViewModifier {
    let style: ZOTextStyle
    let size: CGFloat
    let lineHeight: CGFloat
    let weight: CGFloat?
    let width: CGFloat?
    let tracking: CGFloat
    let tabular: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let source = style.ctFont(for: dynamicTypeSize)
        let scale = CTFontGetSize(source) / style.spec.size
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(source), [
            kCTFontVariationAttribute: [
                0x77647468: width ?? style.spec.width,
                0x77676874: weight ?? style.spec.weight
            ]
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size * scale, nil)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let face = Font(font)
        content
            .font(tabular || style.spec.tabular ? face.monospacedDigit() : face)
            .tracking(tracking)
            .lineSpacing(max(0, lineHeight * scale - natural))
    }
}

extension View {
    func zoProofText(_ style: ZOTextStyle, size: CGFloat, lineHeight: CGFloat,
                     weight: CGFloat? = nil, width: CGFloat? = nil,
                     tracking: CGFloat = 0, tabular: Bool = false) -> some View {
        modifier(ZOProofTextModifier(style: style, size: size, lineHeight: lineHeight,
                                     weight: weight, width: width, tracking: tracking, tabular: tabular))
    }
}
