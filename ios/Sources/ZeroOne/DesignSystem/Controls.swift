import SwiftUI

/// Shared selector and timing policy, consumed by the native control styles below.
enum ZOControlFidelity {
    static func hasDisabledForeground(_ variant: ZOButtonStyle.Variant, theme: ZOTheme) -> Bool {
        switch variant {
        case .primary: theme != .freak
        case .secondary, .quiet, .destructive, .step: true
        case .ink, .round: false
        }
    }

    static func usesPressedBackground(_ variant: ZOButtonStyle.Variant) -> Bool {
        switch variant {
        case .primary, .secondary, .quiet, .step: true
        case .destructive, .ink, .round: false
        }
    }

    static func pressScale(pressed: Bool, reduceMotion: Bool) -> CGFloat {
        pressed && !reduceMotion ? ZOMotion.pressScale : 1
    }

    static func primaryPressedFillIsSolid(theme: ZOTheme, scheme: ColorScheme) -> Bool {
        // Retro light's later four-class selector ties the actual :active selector.
        !(theme == .retro && scheme == .light)
    }

    static func labelStyle(_ variant: ZOButtonStyle.Variant) -> ZOTextStyle {
        // Round inherits .zo-btn's 600 17/22; the regular families override to 15/20.
        variant == .round ? .section : .label
    }

    static func buttonBackgroundAnimation(_ variant: ZOButtonStyle.Variant, reduceMotion: Bool) -> Animation? {
        // .zo-step normally transitions only transform; its pressed fill changes immediately.
        // RM replaces the property list: background-color now takes the first (Brace) curve.
        if reduceMotion { return ZOMotion.brace(ZOMotion.micro) }
        return variant == .step ? nil : .linear(duration: ZOMotion.micro)
    }

    static func buttonForegroundAnimation(_ variant: ZOButtonStyle.Variant, reduceMotion: Bool) -> Animation? {
        guard reduceMotion else { return nil }
        // Color takes the second curve; .zo-step repeats its sole Brace entry instead.
        return variant == .step ? ZOMotion.brace(ZOMotion.micro) : .linear(duration: ZOMotion.micro)
    }

    static func toggleDuration(reduceMotion: Bool) -> Double {
        // dist/tokens.css retains quick at 180 ms under Reduce Motion.
        reduceMotion ? ZOMotion.label : ZOMotion.quick
    }

    static func toggleTrackAnimation(reduceMotion: Bool) -> Animation {
        ZOMotion.land(toggleDuration(reduceMotion: reduceMotion))
    }

    static func toggleThumbColorAnimation(reduceMotion: Bool) -> Animation {
        // RM's first property is background-color, so the first (Carry) curve applies.
        reduceMotion ? ZOMotion.carry(toggleDuration(reduceMotion: true)) : .linear(duration: ZOMotion.quick)
    }

    static func toggleThumbTravelAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : ZOMotion.carry(ZOMotion.quick)
    }

    static func toggleDisabledOpacityAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? toggleTrackAnimation(reduceMotion: true) : nil
    }
}

/// Study 30's button family. Feature views own actions, enabled state and loading state.
struct ZOButtonStyle: ButtonStyle {
    enum Variant: Equatable {
        case primary, secondary, quiet, destructive, ink, round, step
    }

    let variant: Variant
    var wide = false
    var isLoading = false
    /// Component minimum for primary actions; other variants keep their own heights.
    let primaryMinHeight: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.zeroOneTheme) private var theme

    init(_ variant: Variant = .primary, wide: Bool = false, isLoading: Bool = false,
         primaryMinHeight: CGFloat = ZOSpace.rowMinHeight) {
        precondition(primaryMinHeight.isFinite && primaryMinHeight >= ZOSpace.hitTarget)
        self.variant = variant
        self.wide = wide
        self.isLoading = isLoading
        self.primaryMinHeight = primaryMinHeight
    }

    private var isRound: Bool { variant == .round || variant == .step }
    private var minHeight: CGFloat {
        switch variant {
        // Study 30, round 3: primary controls grow to at least 64 pt at accessibility sizes.
        case .primary: dynamicTypeSize.isAccessibilitySize ? max(64, primaryMinHeight) : primaryMinHeight
        case .quiet, .round: ZOSpace.hitTarget
        default: ZOSpace.x4
        }
    }
    private var radius: CGFloat {
        if isRound { return minHeight / 2 }
        return ZOThemeComponentShape(theme: theme.designTheme,
            role: variant == .quiet ? .control : .button,
            radius: variant == .quiet ? ZORadius.control : ZORadius.button).resolvedRadius
    }
    private var hasDisabledAppearance: Bool { !isEnabled && !isLoading }
    private var foreground: Color {
        // themes-fx.css's later .zo-theme-freak .zo-btn.primary color wins
        // over .zo-btn.primary[disabled], with equal (0,3,0) specificity.
        if hasDisabledAppearance && ZOControlFidelity.hasDisabledForeground(variant, theme: theme.designTheme) {
            return contrast == .increased ? theme.textSecondary : theme.textTertiary
        }
        return switch variant {
        case .primary: theme.onAccent
        case .ink: theme.backgroundPrimary
        case .destructive: theme.destructivePrimary
        default: theme.textPrimary
        }
    }
    private var edge: Color {
        switch variant {
        // Theme CSS replaces the base accent edge with Retro's outer effects or
        // Freak's top highlight. Princess keeps the accent edge.
        case .primary:
            switch theme.designTheme {
            case .core: hasDisabledAppearance ? .clear : theme.accentEdge
            case .princess: theme.accentEdge
            case .retro, .freak: .clear
            }
        case .secondary, .destructive: theme.separatorStrong
        default: .clear
        }
    }
    private func background(pressed: Bool) -> AnyShapeStyle {
        let pressed = pressed && ZOControlFidelity.usesPressedBackground(variant)
        switch variant {
        case .primary:
            if hasDisabledAppearance && theme.designTheme != .retro && theme.designTheme != .freak {
                return AnyShapeStyle(theme.surfaceTertiary)
            }
            if pressed && ZOControlFidelity.primaryPressedFillIsSolid(theme: theme.designTheme, scheme: theme.colorScheme) {
                return AnyShapeStyle(theme.accentPressed)
            }
            return theme.primaryActionBackground(pressed: pressed)
        case .ink: return AnyShapeStyle(theme.textPrimary)
        case .quiet: return AnyShapeStyle(pressed ? theme.surfaceSecondary : Color.clear)
        case .step: return AnyShapeStyle(pressed ? theme.surfaceTertiary : theme.surfaceSecondary)
        default: return AnyShapeStyle(pressed ? theme.surfaceSecondary : theme.surfacePrimary)
        }
    }

    @ViewBuilder
    private func buttonLabel(_ label: Configuration.Label) -> some View {
        if variant == .primary {
            label.zoThemeText(.primaryButton)
        } else {
            label.zoText(ZOControlFidelity.labelStyle(variant))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled && !isLoading
        let shape = RoundedRectangle(cornerRadius: radius, style: theme.designTheme == .freak && !isRound ? .circular : .continuous)
        // The outer hit shape keeps the layout footprint while only the decorated label scales.
        return ZStack {
            HStack(spacing: ZOSpace.s) {
                if isLoading {
                    ZOLoadingSpinner()
                }
                buttonLabel(configuration.label)
                    .fontWeight(variant == .destructive || variant == .ink ? .semibold : nil)
                    .underline(variant == .quiet && isEnabled,
                        color: theme.separatorStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(ZOControlFidelity.buttonForegroundAnimation(variant, reduceMotion: reduceMotion)) {
                $0.foregroundStyle(foreground)
            }
            .frame(maxWidth: wide || variant == .primary ? .infinity : nil, minHeight: minHeight)
            .frame(width: isRound ? minHeight : nil)
            .padding(.horizontal, isRound ? 0 : (variant == .quiet ? ZOSpace.m : ZOSpace.xl))
            .animation(ZOControlFidelity.buttonBackgroundAnimation(variant, reduceMotion: reduceMotion)) {
                $0.background(background(pressed: pressed), in: shape)
            }
            .overlay { shape.strokeBorder(edge, lineWidth: ZOStroke.hairline) }
            .modifier(ZOThemePrimaryButtonDecoration(theme: theme, radius: radius,
                isPrimary: variant == .primary))
            .animation(reduceMotion ? nil : ZOMotion.brace(ZOMotion.micro)) {
                $0.scaleEffect(ZOControlFidelity.pressScale(pressed: pressed, reduceMotion: reduceMotion))
            }
        }
        .contentShape(ZOThemeComponentShape(
            theme: variant == .primary ? theme.designTheme : .core, role: .button, radius: radius))
        .allowsHitTesting(!isLoading)
    }
}

/// Static themes-fx.css decoration. It owns no action, timing or loading state.
private struct ZOThemePrimaryButtonDecoration: ViewModifier {
    let theme: ZeroOneThemeTokens
    let radius: CGFloat
    let isPrimary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrimary && theme.designTheme == .freak {
            // The CSS shadow is on the rounded box, then --cut clips it.
            // No stroke is drawn along the new diagonal cuts.
            content.overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.45)).frame(height: ZOStroke.hairline)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(ZOThemeComponentShape(theme: .freak, role: .button, radius: radius))
        } else if isPrimary {
            content.background {
                Group {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                switch theme.designTheme {
                case .retro:
                    if theme.colorScheme == .dark {
                        ZStack {
                            shape.fill(Color(zoHex: 0xFF4D6D, alpha: 0.30)).blur(radius: 44)
                            shape.fill(Color(zoHex: 0xFF8A3D, alpha: 0.55)).blur(radius: 18)
                            // Spread 1 pt sits outside the opaque button background.
                            shape.stroke(Color(zoHex: 0xFFE9A8, alpha: 0.60), lineWidth: 2)
                        }
                    } else {
                        shape.fill(theme.textPrimary).offset(x: 3, y: 3)
                    }
                case .princess:
                    shape.fill(theme.accentFill.opacity(0.45)).blur(radius: 22).offset(y: 8)
                case .core, .freak: EmptyView()
                }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// The same bounded value binding as the native stepper, with Study 30's controls.
struct ZOStepper<Value: Strideable & Comparable>: View {
    let title: LocalizedStringKey
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride = 1) {
        precondition(step > .zero)
        self.title = title
        self._value = value
        self.range = range
        self.step = step
    }

    private func adjust(increasing: Bool) {
        guard isEnabled else { return }
        guard increasing ? value < range.upperBound : value > range.lowerBound else { return }
        value = min(max(value.advanced(by: increasing ? step : -step), range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: ZOSpace.m) {
            Text(title)
                .zoText(.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { adjust(increasing: false) } label: {
                Image(systemName: "minus").zoIcon(ZOIcon.row)
            }
            .buttonStyle(ZOButtonStyle(.step))
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(Text("Decrease"))
            Button { adjust(increasing: true) } label: {
                Image(systemName: "plus").zoIcon(ZOIcon.row)
            }
            .buttonStyle(ZOButtonStyle(.step))
            .disabled(value >= range.upperBound)
            .accessibilityLabel(Text("Increase"))
        }
        .frame(minHeight: ZOSpace.x4 + ZOSpace.xxl + ZOSpace.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(String(describing: value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(increasing: true)
            case .decrement: adjust(increasing: false)
            @unknown default: break
            }
        }
    }
}

struct ZOToggleStyle: ToggleStyle {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ZOSpace.m) {
            configuration.label
                .zoText(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { configuration.isOn.toggle() } label: {
                RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous)
                    .fill()
                    .animation(ZOControlFidelity.toggleTrackAnimation(reduceMotion: reduceMotion)) {
                        $0.foregroundStyle(configuration.isOn ? theme.textPrimary : theme.surfaceTertiary)
                    }
                    .frame(width: ZOSpace.x4 + ZOSpace.xs, height: ZOSpace.x3)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill()
                            .animation(ZOControlFidelity.toggleThumbColorAnimation(reduceMotion: reduceMotion)) {
                                $0.foregroundStyle(configuration.isOn ? theme.backgroundPrimary :
                                    (theme.colorScheme == .dark ? theme.textSecondary : theme.surfacePrimary))
                            }
                            .frame(width: ZOSpace.xxl + 2 * ZOStroke.hairline, height: ZOSpace.xxl + 2 * ZOStroke.hairline)
                            .shadow(color: theme.colorScheme == .light ? ZOColor.Swatch.yellow.on.opacity(0.2) : .clear,
                                radius: 3 * ZOStroke.hairline, y: ZOStroke.hairline)
                            .animation(ZOControlFidelity.toggleThumbTravelAnimation(reduceMotion: reduceMotion)) {
                                $0.offset(x: configuration.isOn ? ZOSpace.xl + 3 * ZOStroke.hairline : 3 * ZOStroke.hairline)
                            }
                    }
                    .frame(minHeight: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(ZOControlFidelity.toggleDisabledOpacityAnimation(reduceMotion: reduceMotion)) {
                $0.opacity(isEnabled ? 1 : 0.5)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// A shaped object (the Main Action or next-exercise card) keeps its own geometry.
struct ZOPressStyle: ButtonStyle {
    var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .scaleEffect(pressed && motionEnabled && !reduceMotion ? ZOMotion.pressScale : 1)
            .animation(motionEnabled && !reduceMotion ? ZOMotion.brace(ZOMotion.micro) : nil, value: pressed)
    }
}

struct ZOChipStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .zoText(.label)
            .foregroundStyle(!isEnabled ? (contrast == .increased ? theme.textSecondary : theme.textTertiary) : (isSelected ? theme.backgroundPrimary : theme.textPrimary))
            .padding(.horizontal, ZOSpace.l)
            .frame(minHeight: ZOSpace.x3 + ZOSpace.xs)
            .background(isSelected ? theme.textPrimary : theme.surfacePrimary, in: Capsule())
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(theme.separatorStrong, lineWidth: ZOStroke.hairline)
                }
            }
            .frame(minHeight: ZOSpace.hitTarget)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ZOChip: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(ZOChipStyle(isSelected: isSelected))
    }
}

struct ZOBadge: View {
    let text: String
    var isInk = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .zoText(.caption)
            .fontWeight(.medium)
            .monospacedDigit()
            .padding(.horizontal, ZOSpace.s + 2 * ZOStroke.hairline)
            .frame(minHeight: ZOSpace.xxl)
            .foregroundStyle(isInk ? theme.backgroundPrimary : (contrast == .increased ? theme.textPrimary : theme.textSecondary))
            .background(isInk ? theme.textPrimary : theme.surfaceSecondary, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reference spinner: an 18 pt ring with one open quadrant, rotating every 720 ms.
/// Reduce Motion uses the reference's complete, half-opacity ring.
struct ZOLoadingSpinner: View {
    var size: CGFloat = ZOSpace.l + 2 * ZOStroke.hairline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotates = false

    var body: some View {
        Circle()
            // CSS border-box: inset the 2 pt border's centerline inside the outer size.
            .inset(by: ZOStroke.hairline)
            // The transparent right border leaves the quadrant from -45 to +45 degrees.
            .trim(from: reduceMotion ? 0 : 0.125, to: reduceMotion ? 1 : 0.875)
            .stroke(style: StrokeStyle(lineWidth: 2 * ZOStroke.hairline, lineCap: .butt))
            .frame(width: size, height: size)
            .opacity(reduceMotion ? 0.5 : 1)
            .rotationEffect(.degrees(rotates && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 3 * ZOMotion.quick).repeatForever(autoreverses: false), value: rotates)
            .task(id: reduceMotion) {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { rotates = false }
                await Task.yield()
                guard !Task.isCancelled, !reduceMotion else { return }
                rotates = true
            }
            .accessibilityLabel(Text("Loading"))
    }
}

/// Keeps each original Text label and typed selection value, including localized labels.
struct ZOSegment<Value: Hashable>: Identifiable {
    let value: Value
    let label: Text
    var id: Value { value }
}

struct ZOSegmentedControl<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [ZOSegment<Value>]

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [ZOSegment<Value>]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private func moveSelection(forward: Bool) {
        guard isEnabled, let index = options.firstIndex(where: { $0.value == selection }) else { return }
        let next = index + (forward ? 1 : -1)
        guard options.indices.contains(next) else { return }
        selection = options[next].value
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2 * ZOStroke.hairline))
            : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(options) { option in
                Button { selection = option.value } label: { option.label }
                    .buttonStyle(ZOSegmentedStyle(isSelected: selection == option.value))
                    .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(2 * ZOStroke.hairline)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius:
            ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius,
            style: theme.designTheme == .freak ? .circular : .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(options.first(where: { $0.value == selection })?.label ?? Text(""))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveSelection(forward: true)
            case .decrement: moveSelection(forward: false)
            @unknown default: break
            }
        }
    }
}

struct ZOSegmentedStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .zoText(.label)
            .fontWeight(isSelected ? .semibold : .medium)
            .foregroundStyle(!isEnabled ? (contrast == .increased ? theme.textSecondary : theme.textTertiary) : (isSelected || contrast == .increased ? theme.textPrimary : theme.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: ZOSpace.x3 + ZOSpace.xs)
            .background(isSelected ? (theme.colorScheme == .dark ? theme.surfaceTertiary : theme.surfacePrimary) : .clear,
                // components.css .zo-seg button uses literal 10 px, with no theme override.
                in: RoundedRectangle(cornerRadius: ZORadius.control - 2 * ZOStroke.hairline, style: .continuous))
            .shadow(color: isSelected && theme.colorScheme == .light ? ZOColor.Swatch.yellow.on.opacity(0.08) : .clear,
                radius: 2 * ZOStroke.hairline, y: ZOStroke.hairline)
            .contentShape(Rectangle())
    }
}
