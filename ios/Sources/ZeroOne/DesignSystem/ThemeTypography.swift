import CoreText
import SwiftUI
import UIKit

/// Shared by app and extension. Requires only generated DesignTokens.swift.
/// Resource membership and localization remain the target owner's responsibility.
enum ZOThemeTextRole: CaseIterable, Equatable {
    case display, title, section, body, label, caption, mini, metric, timer, timerHero, primaryButton

    var baseStyle: ZOTextStyle {
        switch self {
        case .display: return .display
        case .title: return .title
        case .section, .primaryButton: return .section
        case .body: return .body
        case .label: return .label
        case .caption: return .caption
        case .mini: return .mini
        case .metric: return .metric
        case .timer: return .timer
        case .timerHero: return .timerHero
        }
    }
}

/// Exact contextual equivalents of themes-fx.css:77. A display role alone is insufficient.
/// Shared classification only; the vector renderer and environment composition stay app-only.
enum ZOHeadingSigilContext: CaseIterable, Equatable {
    case headRowDisplay
    case directScrollDisplay
    case nestedContent
}

extension ZOThemeTextRole {
    /// Does not promote .title, preview words or nested content to a screen heading.
    func isHeadingSigilEligible(in context: ZOHeadingSigilContext) -> Bool {
        guard self == .display else { return false }
        switch context {
        case .headRowDisplay, .directScrollDisplay: return true
        case .nestedContent: return false
        }
    }
}

/// Component dimensions override only the role's size/line box. Keep its resolved
/// face, axes, font matrix, tracking, tabular behavior, effects and Dynamic Type cap.
struct ZOThemeComponentTextMetrics: Equatable {
    let size: CGFloat
    let lineHeight: CGFloat

    init(size: CGFloat, lineHeight: CGFloat) {
        precondition(size.isFinite && size > 0 && lineHeight.isFinite && lineHeight > 0)
        self.size = size
        self.lineHeight = lineHeight
    }

    func scaledSize(baseSize: CGFloat, scaledBaseSize: CGFloat) -> CGFloat {
        size * scaledBaseSize / baseSize
    }

    func scaledLineHeight(baseSize: CGFloat, scaledBaseSize: CGFloat) -> CGFloat {
        lineHeight * scaledBaseSize / baseSize
    }

    /// Resize the already resolved font. nil matrix/descriptor preserve its
    /// matrix and attributes; do not rebuild a family or inject weight/width axes.
    func font(resizing source: CTFont, baseSize: CGFloat) -> CTFont {
        CTFontCreateCopyWithAttributes(source,
            scaledSize(baseSize: baseSize, scaledBaseSize: CTFontGetSize(source)), nil, nil)
    }
}

enum ZOThemeFontAxis {
    static let width: UInt32 = 0x77647468
    static let weight: UInt32 = 0x77676874
    static let opticalSize: UInt32 = 0x6f70737a
    static let softness: UInt32 = 0x534f4654
    static let wonk: UInt32 = 0x574f4e4b
}

struct ZOThemeFontAxisRange: Equatable {
    let minimum: CGFloat
    let defaultValue: CGFloat
    let maximum: CGFloat
}

enum ZOThemeFontResource: String, CaseIterable {
    case instrumentSans = "InstrumentSans-Variable"
    case monoton = "Monoton-Regular"
    case pirataOne = "PirataOne-Regular"
    case anton = "Anton-Regular"
    case frauncesItalic = "Fraunces-Italic-Variable"

    var expectedPostScriptName: String {
        switch self {
        case .instrumentSans: return "InstrumentSans-Regular"
        case .monoton: return "Monoton-Regular"
        case .pirataOne: return "PirataOne-Regular"
        case .anton: return "Anton-Regular"
        case .frauncesItalic: return "Fraunces-9ptBlackItalic"
        }
    }

    /// Metadata from the actual pinned binaries, not inferred from family names.
    var expectedAxes: [UInt32: ZOThemeFontAxisRange] {
        switch self {
        case .instrumentSans:
            return [ZOThemeFontAxis.width: .init(minimum: 75, defaultValue: 100, maximum: 100),
                ZOThemeFontAxis.weight: .init(minimum: 400, defaultValue: 400, maximum: 700)]
        case .frauncesItalic:
            return [ZOThemeFontAxis.opticalSize: .init(minimum: 9, defaultValue: 9, maximum: 144),
                ZOThemeFontAxis.weight: .init(minimum: 100, defaultValue: 900, maximum: 900),
                ZOThemeFontAxis.softness: .init(minimum: 0, defaultValue: 0, maximum: 100),
                ZOThemeFontAxis.wonk: .init(minimum: 0, defaultValue: 1, maximum: 1)]
        case .monoton, .pirataOne, .anton: return [:]
        }
    }

    func resourceURL(in bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: rawValue, withExtension: "ttf") else {
            throw ZOThemeFontError.missingResource(rawValue + ".ttf")
        }
        return url
    }

    private func loadDescriptor(in bundle: Bundle) throws -> CTFontDescriptor {
        let url = try resourceURL(in: bundle)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw ZOThemeFontError.unreadableResource(rawValue)
        }
        // iOS 26 can list a variable font's named instances first (Fraunces-ThinItalic);
        // the pinned PostScript name is the default instance.
        let names = descriptors.map { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        guard let index = names.firstIndex(of: expectedPostScriptName) else {
            let found = names.compactMap { $0 }.joined(separator: ", ")
            throw ZOThemeFontError.metadataMismatch(rawValue + ": PostScript " + (found.isEmpty ? "unavailable" : found))
        }
        let descriptor = descriptors[index]
        let source = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let axes = CTFontCopyVariationAxes(source) as? [[String: Any]] ?? []
        var actual: [UInt32: ZOThemeFontAxisRange] = [:]
        for axis in axes {
            guard let identifier = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                  let minimum = axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber,
                  let defaultValue = axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber,
                  let maximum = axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber else {
                throw ZOThemeFontError.metadataMismatch(rawValue + ": incomplete axis metadata")
            }
            actual[identifier.uint32Value] = .init(minimum: CGFloat(minimum.doubleValue),
                defaultValue: CGFloat(defaultValue.doubleValue), maximum: CGFloat(maximum.doubleValue))
        }
        guard actual == expectedAxes else {
            throw ZOThemeFontError.metadataMismatch(rawValue + ": variation axis ranges")
        }
        if self == .frauncesItalic,
           !CTFontGetSymbolicTraits(source).contains(.traitItalic) {
            throw ZOThemeFontError.metadataMismatch(rawValue + ": true italic trait")
        }
        return descriptor
    }

    // Immutable, once-per-process URL descriptor cache. Never globally register the
    // Instrument Sans variable face: its static Regular has the same PostScript name.
    private static let mainDescriptors: [ZOThemeFontResource: Result<CTFontDescriptor, Error>] = {
        var result: [ZOThemeFontResource: Result<CTFontDescriptor, Error>] = [:]
        for resource in allCases {
            result[resource] = Result { try resource.loadDescriptor(in: .main) }
        }
        return result
    }()

    func descriptor(in bundle: Bundle = .main) throws -> CTFontDescriptor {
        if bundle.bundleURL == Bundle.main.bundleURL, let cached = Self.mainDescriptors[self] {
            return try cached.get()
        }
        return try loadDescriptor(in: bundle)
    }
}

enum ZOThemeFontError: Error {
    case missingResource(String)
    case unreadableResource(String)
    case metadataMismatch(String)
    case unsupportedVariation(UInt32, CGFloat)
}

struct ZOThemeTextSpec {
    var resource: ZOThemeFontResource
    var size: CGFloat
    var lineHeight: CGFloat
    /// CSS request. Static faces do not acquire invented weight/width axes.
    var weight: CGFloat
    var width: CGFloat
    var tracking: CGFloat
    var uppercase = false
    var obliqueDegrees: CGFloat = 0
    let textStyle: UIFont.TextStyle
    let tabular: Bool
    let maxSize: DynamicTypeSize?

    var variations: [UInt32: CGFloat] {
        switch resource {
        case .instrumentSans: return [ZOThemeFontAxis.width: width, ZOThemeFontAxis.weight: weight]
        case .frauncesItalic: return [ZOThemeFontAxis.weight: weight, ZOThemeFontAxis.opticalSize: 72,
            ZOThemeFontAxis.softness: 100, ZOThemeFontAxis.wonk: 1]
        case .monoton, .pirataOne, .anton: return [:]
        }
    }

    /// Effective Retro timer CSS requests Monoton600/75; the supplied file is
    /// Regular400/normal width only. No native synthetic parity is asserted.
    var hasUnsupportedStaticRequest: Bool {
        resource.expectedAxes.isEmpty && (weight != 400 || width != 100)
    }

    func scaledSize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let capped = maxSize.map { min(dynamicTypeSize, $0) } ?? dynamicTypeSize
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped))
        return UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size, compatibleWith: traits)
    }

    func font(for dynamicTypeSize: DynamicTypeSize, bundle: Bundle = .main) throws -> CTFont {
        let source = try resource.descriptor(in: bundle)
        for (identifier, value) in variations {
            guard let range = resource.expectedAxes[identifier],
                  value >= range.minimum, value <= range.maximum else {
                throw ZOThemeFontError.unsupportedVariation(identifier, value)
            }
        }
        let descriptor = variations.isEmpty ? source : CTFontDescriptorCreateCopyWithAttributes(source,
            [kCTFontVariationAttribute: variations] as CFDictionary)
        let pointSize = scaledSize(for: dynamicTypeSize)
        if obliqueDegrees != 0 {
            // CoreText glyph shear; true Fraunces italic never enters this branch.
            var matrix = CGAffineTransform(a: 1, b: 0, c: tan(obliqueDegrees * .pi / 180), d: 1, tx: 0, ty: 0)
            return CTFontCreateWithFontDescriptor(descriptor, pointSize, &matrix)
        }
        return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
    }
}

enum ZOThemeTypography {
    static func spec(for designTheme: ZOTheme, role: ZOThemeTextRole) -> ZOThemeTextSpec {
        let base = role.baseStyle.spec
        var result = ZOThemeTextSpec(resource: .instrumentSans, size: base.size,
            lineHeight: base.lineHeight, weight: base.weight, width: base.width,
            tracking: base.tracking, textStyle: base.textStyle, tabular: base.tabular, maxSize: base.maxSize)
        switch designTheme {
        case .core: break
        case .retro:
            switch role {
            case .display:
                result.resource = .monoton; result.size = 38; result.lineHeight = 44
                result.weight = 400; result.tracking = 1
            case .title:
                result.weight = 700; result.width = 75; result.tracking = 0; result.obliqueDegrees = 10
            case .timer:
                // Effective dist/tokens.css timer inherits font-display, despite
                // tokens.json prose reserving Monoton to display/rest countdown.
                result.resource = .monoton
            case .timerHero:
                result.resource = .monoton; result.size = 104; result.lineHeight = 112
                result.weight = 400; result.tracking = 2
            default: break
            }
        case .freak:
            switch role {
            case .display, .title:
                result.resource = .pirataOne; result.weight = 400; result.width = 100; result.tracking = 0.3
                result.size = role == .display ? 44 : 28; result.lineHeight = role == .display ? 48 : 32
            case .metric, .timer, .timerHero, .primaryButton:
                result.resource = .anton; result.weight = 400; result.width = 100
                result.uppercase = true; result.tracking = 0.5
                if role == .metric { result.size = 34; result.lineHeight = 38 }
                if role == .timerHero { result.size = 132; result.lineHeight = 132; result.tracking = -1 }
                if role == .primaryButton { result.size = 20; result.tracking = 1.5 }
            default: break
            }
        case .princess:
            if role == .display || role == .title {
                result.resource = .frauncesItalic; result.weight = 600; result.tracking = -0.3
                if role == .display { result.size = 38; result.lineHeight = 44 }
            }
        }
        return result
    }

    static func font(for designTheme: ZOTheme, role: ZOThemeTextRole,
                     dynamicTypeSize: DynamicTypeSize, bundle: Bundle = .main) throws -> CTFont {
        try spec(for: designTheme, role: role).font(for: dynamicTypeSize, bundle: bundle)
    }
}

struct ZOThemeTextShadow {
    let color: Color
    let cssBlur: CGFloat
    let x: CGFloat
    let y: CGFloat
}

struct ZOThemeTextEffects {
    /// nil preserves the caller's semantic foreground; gradients follow glyph bounds.
    let foreground: AnyShapeStyle?
    /// Front-to-back order from CSS text-shadow. Independent glyph copies avoid
    /// applying a later shadow to an earlier shadow. Native blur kernels UNRUN.
    let shadows: [ZOThemeTextShadow]
    /// Public numeric contract for source/native comparison before rendering.
    var gradientStops: [Gradient.Stop]? = nil

    static func resolve(designTheme: ZOTheme, role: ZOThemeTextRole, colorScheme: ColorScheme) -> Self {
        let ink = designTheme.palette(dark: colorScheme == .dark)?.inkPrimary ?? ZOColor.inkPrimary
        let glowA = Color(zoHex: 0xFF4D6D), glowB = Color(zoHex: 0xFF8A3D)
        let glowC = Color(zoHex: 0xC04DFF), glowD = Color(zoHex: 0xFFE9A8)
        if designTheme == .retro {
            if role == .title {
                let stops: [Gradient.Stop] = [.init(color: ink, location: 0), .init(color: ink, location: 0.54),
                    .init(color: .clear, location: 0.54), .init(color: .clear, location: 0.59),
                    .init(color: glowB, location: 0.59), .init(color: glowB, location: 0.68),
                    .init(color: .clear, location: 0.68), .init(color: .clear, location: 0.72),
                    .init(color: glowA, location: 0.72), .init(color: glowA, location: 0.82),
                    .init(color: .clear, location: 0.82), .init(color: .clear, location: 0.86),
                    .init(color: glowC, location: 0.86), .init(color: glowC, location: 1)]
                return .init(foreground: AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)), shadows: [], gradientStops: stops)
            }
            if role == .display || role == .timerHero {
                if colorScheme == .light {
                    return .init(foreground: AnyShapeStyle(ink), shadows: [
                        .init(color: glowA, cssBlur: 0, x: 2, y: 2), .init(color: glowB, cssBlur: 0, x: 4, y: 4)])
                }
                let hero = role == .timerHero
                return .init(foreground: AnyShapeStyle(glowD), shadows: [
                    .init(color: glowB.opacity(hero ? 1 : 0.8), cssBlur: hero ? 6 : 4, x: 0, y: 0),
                    .init(color: glowA.opacity(hero ? 0.7 : 0.55), cssBlur: hero ? 22 : 14, x: 0, y: 0),
                    .init(color: glowC.opacity(hero ? 0.5 : 0.4), cssBlur: hero ? 48 : 30, x: 0, y: 0)])
            }
            if role == .metric || role == .timer {
                return .init(foreground: AnyShapeStyle(colorScheme == .dark ? glowD : ink), shadows:
                    colorScheme == .dark ? [.init(color: glowB.opacity(0.55), cssBlur: 10, x: 0, y: 0)] : [])
            }
        }
        if designTheme == .freak, colorScheme == .dark, role == .display || role == .timerHero {
            let stops: [Gradient.Stop] = [.init(color: Color(zoHex: 0xFFFFFF), location: 0),
                .init(color: Color(zoHex: 0xE9ECEF), location: 0.3), .init(color: Color(zoHex: 0x8D939B), location: 0.5),
                .init(color: Color(zoHex: 0x4D535B), location: 0.52), .init(color: Color(zoHex: 0xE9ECEF), location: 0.8),
                .init(color: Color(zoHex: 0xFFFFFF), location: 1)]
            return .init(foreground: AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)), shadows: [], gradientStops: stops)
        }
        return .init(foreground: nil, shadows: [])
    }
}

private struct ZOThemeTextEffectsModifier: ViewModifier {
    let effects: ZOThemeTextEffects

    @ViewBuilder private func shadow(_ content: Content, at index: Int) -> some View {
        if effects.shadows.indices.contains(index) {
            let shadow = effects.shadows[index]
            content.foregroundStyle(shadow.color)
                .blur(radius: shadow.cssBlur)
                .offset(x: shadow.x, y: shadow.y)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func face(_ content: Content) -> some View {
        if let foreground = effects.foreground { content.foregroundStyle(foreground) }
        else { content }
    }

    func body(content: Content) -> some View {
        face(content).background {
            ZStack { shadow(content, at: 2); shadow(content, at: 1); shadow(content, at: 0) }
        }
    }
}

private struct ZOThemeTextModifier: ViewModifier {
    let role: ZOThemeTextRole
    let designTheme: ZOTheme
    let colorScheme: ColorScheme
    let componentMetrics: ZOThemeComponentTextMetrics?
    let resolvedSpec: ZOThemeTextSpec?
    let resolvedEffects: ZOThemeTextEffects?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(role: ZOThemeTextRole, designTheme: ZOTheme, colorScheme: ColorScheme,
         componentMetrics: ZOThemeComponentTextMetrics? = nil,
         resolvedSpec: ZOThemeTextSpec? = nil, effects: ZOThemeTextEffects? = nil) {
        self.role = role
        self.designTheme = designTheme
        self.colorScheme = colorScheme
        self.componentMetrics = componentMetrics
        self.resolvedSpec = resolvedSpec
        self.resolvedEffects = effects
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let spec = resolvedSpec {
            // Caller-owned face/axes/metrics take priority even for Core.
            let font = resolvedFont(spec) ?? contextualCoreFont(spec)
            styled(content, font: font, spec: spec, effectsTheme: designTheme)
        } else if designTheme == .core {
            coreText(content)
        } else {
            let spec = ZOThemeTypography.spec(for: designTheme, role: role)
            if let font = resolvedFont(spec) {
                styled(content, font: font, spec: spec, effectsTheme: designTheme)
            } else {
                // Same diagnosed readable Core fallback, retaining component
                // dimensions when supplied. This is never selected-face parity.
                coreText(content)
            }
        }
    }

    /// Reuse the diagnosed readable Core fallback, retaining explicit context
    /// dimensions and Dynamic Type cap. Its face/axes are not selected-font parity.
    private func contextualCoreFont(_ spec: ZOThemeTextSpec) -> CTFont {
        CTFontCreateCopyWithAttributes(role.baseStyle.ctFont(for: dynamicTypeSize),
            spec.scaledSize(for: dynamicTypeSize), nil, nil)
    }

    @ViewBuilder private func coreText(_ content: Content) -> some View {
        if componentMetrics != nil {
            let spec = ZOThemeTypography.spec(for: .core, role: role)
            // Reuse the generated Core engine, including its existing cap/fallback.
            styled(content, font: role.baseStyle.ctFont(for: dynamicTypeSize),
                   spec: spec, effectsTheme: .core)
        } else {
            // Existing public role semantics are unchanged without an override.
            content.zoText(role.baseStyle)
        }
    }

    @ViewBuilder private func styled(_ content: Content, font: CTFont, spec: ZOThemeTextSpec,
                        effectsTheme: ZOTheme) -> some View {
        let renderedFont = componentMetrics?.font(resizing: font, baseSize: spec.size) ?? font
        let face = Font(renderedFont)
        let natural = CTFontGetAscent(renderedFont) + CTFontGetDescent(renderedFont) + CTFontGetLeading(renderedFont)
        let scale = CTFontGetSize(font) / spec.size
        let lineHeight = componentMetrics?.lineHeight ?? spec.lineHeight
        let sizedContent = content.font(spec.tabular ? face.monospacedDigit() : face)
            .tracking(spec.tracking)
            .lineSpacing(max(0, lineHeight * scale - natural))
        if let effects = resolvedEffects {
            // Explicit effects preserve nil foreground and share the exact glyph renderer.
            sizedContent.textCase(spec.uppercase ? .uppercase : nil)
                .modifier(ZOThemeTextEffectsModifier(effects: effects))
        } else if effectsTheme == .core {
            // Generated Core/proof typography preserves inherited textCase/foreground.
            sizedContent
        } else {
            sizedContent.textCase(spec.uppercase ? .uppercase : nil)
                .modifier(ZOThemeTextEffectsModifier(effects: .resolve(designTheme: effectsTheme,
                    role: role, colorScheme: colorScheme)))
        }
    }

    private func resolvedFont(_ spec: ZOThemeTextSpec) -> CTFont? {
        do { return try spec.font(for: dynamicTypeSize) }
        catch {
            assertionFailure("Theme font unavailable or invalid; readable core fallback is not theme parity: \(error)")
            return nil
        }
    }
}

extension View {
    /// Reuse final face decoration at a caller-owned font size, such as a 28/34 theme tile.
    /// Apply before surrounding foregroundStyle so the face/shadow colors remain local.
    func zoThemeTextEffects(_ role: ZOThemeTextRole, designTheme: ZOTheme, colorScheme: ColorScheme) -> some View {
        modifier(ZOThemeTextEffectsModifier(effects: .resolve(designTheme: designTheme, role: role, colorScheme: colorScheme)))
    }

    /// Apply to text before its surrounding backgrounds/layout. Explicit API is
    /// extension-safe; do not pre-uppercase localized keys or suppress native glyph fallback.
    func zoThemeText(_ role: ZOThemeTextRole, designTheme: ZOTheme, colorScheme: ColorScheme) -> some View {
        modifier(ZOThemeTextModifier(role: role, designTheme: designTheme, colorScheme: colorScheme))
    }

    /// Component-owned dimensions with the selected role's face/axes/effects.
    /// Scale 26/30-style overrides from the current role base font, not a new cap.
    /// Extension-safe; this overload adds neither an app environment nor a sigil.
    func zoThemeText(_ role: ZOThemeTextRole, size: CGFloat, lineHeight: CGFloat,
                     designTheme: ZOTheme, colorScheme: ColorScheme) -> some View {
        modifier(ZOThemeTextModifier(role: role, designTheme: designTheme, colorScheme: colorScheme,
            componentMetrics: .init(size: size, lineHeight: lineHeight)))
    }

    /// Explicit caller context, shared by app and extension without environment/sigil.
    /// The resolved spec owns face, axes, tracking, line box, tabular behavior and cap;
    /// effects own local foreground and up to three glyph shadows. Apply before
    /// surrounding foregroundStyle to preserve caller ink when foreground is nil.
    func zoThemeText(_ role: ZOThemeTextRole, resolvedSpec: ZOThemeTextSpec,
                     effects: ZOThemeTextEffects, designTheme: ZOTheme,
                     colorScheme: ColorScheme) -> some View {
        precondition(resolvedSpec.size.isFinite && resolvedSpec.size > 0
            && resolvedSpec.lineHeight.isFinite && resolvedSpec.lineHeight > 0)
        return modifier(ZOThemeTextModifier(role: role, designTheme: designTheme, colorScheme: colorScheme,
            resolvedSpec: resolvedSpec, effects: effects))
    }
}
