import SwiftUI

struct ZOHeadingSigilGradientStop: Equatable {
    let rgb: UInt32
    let location: CGFloat
}

/// Canonical CSS block/mask geometry. These fixed decoration dimensions do not
/// scale with the heading's Dynamic Type size; the heading itself remains free to grow.
enum ZOHeadingSigilSpecification {
    static let assetName = "CanonicalFreakHeadingSigil"
    static let box = CGSize(width: 150, height: 24)
    static let svgViewBox = CGSize(width: 300, height: 60)
    static let marginLeft: CGFloat = -12
    static let marginBottom: CGFloat = 4
    static let opacity: Double = 1

    static func isSelected(designTheme: ZOTheme, role: ZOThemeTextRole,
                           context: ZOHeadingSigilContext) -> Bool {
        designTheme == .freak && role.isHeadingSigilEligible(in: context)
    }

    /// CSS mask: no-repeat left center / contain. The 150x24 box paints a
    /// 120x24 viewBox at its left, leaving 30pt transparent at the right.
    static func maskFrame(in box: CGSize) -> CGRect {
        let scale = min(box.width / svgViewBox.width, box.height / svgViewBox.height)
        let size = CGSize(width: svgViewBox.width * scale, height: svgViewBox.height * scale)
        return CGRect(x: 0, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Contract for the normal-flow block after a measured heading. The render
    /// uses the same fixed box and negative/bottom padding; native layout is UNRUN.
    static func flowSize(after heading: CGSize) -> CGSize {
        CGSize(width: max(heading.width, box.width + marginLeft),
               height: heading.height + box.height + marginBottom)
    }

    static func blockFrame(after heading: CGSize) -> CGRect {
        CGRect(x: marginLeft, y: heading.height, width: box.width, height: box.height)
    }

    static func chromeStops(colorScheme: ColorScheme) -> [ZOHeadingSigilGradientStop] {
        if colorScheme == .light {
            // Freak light inkSecondary / inkPrimary / inkSecondary, CSS61.
            return [.init(rgb: 0x353A41, location: 0), .init(rgb: 0x0A0B0D, location: 0.5),
                    .init(rgb: 0x353A41, location: 1)]
        }
        // Freak fx.chrome1 / 3 / 2 / 4 / 3 / 1, CSS59.
        return [.init(rgb: 0xFFFFFF, location: 0), .init(rgb: 0xE9ECEF, location: 0.3),
                .init(rgb: 0x8D939B, location: 0.5), .init(rgb: 0x4D535B, location: 0.52),
                .init(rgb: 0xE9ECEF, location: 0.8), .init(rgb: 0xFFFFFF, location: 1)]
    }
}

private struct ZOCanonicalHeadingSigil: View {
    let colorScheme: ColorScheme
    private var maskFrame: CGRect { ZOHeadingSigilSpecification.maskFrame(in: ZOHeadingSigilSpecification.box) }

    var body: some View {
        LinearGradient(stops: ZOHeadingSigilSpecification.chromeStops(colorScheme: colorScheme).map {
            Gradient.Stop(color: Color(zoHex: $0.rgb), location: $0.location)
        }, startPoint: .top, endPoint: .bottom)
        .frame(width: ZOHeadingSigilSpecification.box.width, height: ZOHeadingSigilSpecification.box.height)
        .mask(alignment: .leading) {
            Image(decorative: ZOHeadingSigilSpecification.assetName, bundle: .main)
                .renderingMode(.template)
                .resizable()
                .frame(width: maskFrame.width, height: maskFrame.height)
        }
        .opacity(ZOHeadingSigilSpecification.opacity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// App only. The app's resolved environment supplies the same theme/mode as its
/// heading typography. Extension targets must not compile this helper or asset.
private struct ZOContextualHeadingSigilModifier: ViewModifier {
    let role: ZOThemeTextRole
    let context: ZOHeadingSigilContext
    @Environment(\.zeroOneTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if ZOHeadingSigilSpecification.isSelected(designTheme: theme.designTheme, role: role, context: context) {
            VStack(alignment: .leading, spacing: 0) {
                content
                ZOCanonicalHeadingSigil(colorScheme: theme.colorScheme)
                    .padding(.leading, ZOHeadingSigilSpecification.marginLeft)
                    .padding(.bottom, ZOHeadingSigilSpecification.marginBottom)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Opt in at a verified CSS-equivalent heading node, after its typography.
    /// Never apply to an entire header row, preview/card container or arbitrary title.
    func zoContextualHeadingSigil(role: ZOThemeTextRole, context: ZOHeadingSigilContext) -> some View {
        modifier(ZOContextualHeadingSigilModifier(role: role, context: context))
    }

    /// App-only opt-in composition: preserve the supplied role and current typography
    /// effects, then append the canonical block only for an eligible Freak context.
    /// Use the raw sigil modifier after custom-size/proof typography instead.
    func zoThemeHeading(_ role: ZOThemeTextRole, context: ZOHeadingSigilContext) -> some View {
        zoThemeText(role).zoContextualHeadingSigil(role: role, context: context)
    }
}
