import SwiftUI

enum ZeroOneMotion {
    // Legacy names retain caller compatibility while using the final motion roles.
    static let micro = ZOMotion.land(ZOMotion.micro)
    static let fast = ZOMotion.land(ZOMotion.quick)
    static let standard = ZOMotion.land(ZOMotion.shape)
    static let heroTransition = ZOMotion.carry(ZOMotion.beat)
    static let controlRelease = ZOMotion.brace(ZOMotion.micro)
    static let assistantMorph = ZOMotion.carry(ZOMotion.shape)
    static let quick = fast
    static let stateChange = standard
    static let progress = ZOMotion.carry(ZOMotion.beat)
    static let successMicro = ZOMotion.land(ZOMotion.Celebration.tick)
    static let successMid = ZOMotion.land(ZOMotion.Celebration.goal)
    static let successMajor = ZOMotion.land(ZOMotion.Celebration.major)
}



enum ZeroOneChartStyle {
    static let lineWidth: CGFloat = 3
    static let pointSize: CGFloat = 42
    static let gridLine = ZeroOneColors.divider
}

struct ZeroOneCardStyle: ViewModifier {
    let padding: CGFloat
    let background: Color?
    let radius: CGFloat
    let elevated: Bool

    init(
        padding: CGFloat = ZOSpace.cardPadding,
        background: Color? = nil,
        radius: CGFloat = ZORadius.card,
        elevated: Bool = false
    ) {
        self.padding = padding
        self.background = background
        self.radius = radius
        self.elevated = elevated
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .zoThemeCardSurface(background: background, radius: radius)
        // Retain the legacy elevated argument for callers; the final card has no shadow.
    }
}

struct ZeroOneFeatureSurfaceStyle: ViewModifier {
    let accent: Color?
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content
            .zeroOneCard(background: theme.surfaceSecondary, elevated: true)
    }
}

struct ZeroOneStatTileStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .zeroOneCard(padding: ZOSpace.cardPadding, radius: ZORadius.card)
    }
}

struct ZeroOneRevealStyle: ViewModifier {
    let isVisible: Bool
    let delay: Double
    let distance: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : distance)
            .animation(
                reduceMotion ? ZOMotion.crossfade(panel: true) : ZeroOneMotion.standard.delay(delay),
                value: isVisible
            )
    }
}

extension View {
    func zeroOneCard(
        padding: CGFloat = ZOSpace.cardPadding,
        background: Color? = nil,
        radius: CGFloat = ZORadius.card,
        elevated: Bool = false
    ) -> some View {
        modifier(
            ZeroOneCardStyle(
                padding: padding,
                background: background,
                radius: radius,
                elevated: elevated
            )
        )
    }

    func zeroOneStatTile() -> some View {
        modifier(ZeroOneStatTileStyle())
    }

    func zeroOneFeatureSurface(accent: Color? = nil) -> some View {
        modifier(ZeroOneFeatureSurfaceStyle(accent: accent))
    }

    func zeroOneReveal(_ isVisible: Bool, delay: Double = 0, distance: CGFloat = 10) -> some View {
        modifier(ZeroOneRevealStyle(isVisible: isVisible, delay: delay, distance: distance))
    }

}

struct ZeroOneWordmark: View {
    var markSize: CGFloat = 32
    var showsMark = true
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Group {
            if showsMark {
                Image("ZeroOneWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: markSize)
            } else {
                Text("01")
                    .zoText(.section)

                    .foregroundStyle(theme.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("01")
    }
}

struct ZeroOneProfileButton: View {
    let action: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.crop.circle")
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textPrimary)
                .frame(width: 44, height: 44)
                .zeroOneGlassSurface(
                    .rounded(22),
                    tint: theme.materials.functionalGlassTint,
                    interactive: true
                )
                .overlay {
                    Circle().stroke(contrast == .increased ? theme.separatorStrong : theme.strokeSubtle, lineWidth: ZOStroke.hairline)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open profile")
        .accessibilityHint("Opens Profile, Progress, and Settings.")
    }
}

struct ZeroOneStatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(spacing: ZOSpace.s) {
                Image(systemName: symbol)
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(theme.brandGradientPrimary))

                Text(title)
                    .zoText(.caption)
                    .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
            }

            Text(value)
                .zoThemeText(.metric)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .minimumScaleFactor(0.75)
        }
        .zeroOneStatTile()
        .accessibilityElement(children: .combine)
    }
}

struct ZeroOneMetricReadout: View {
    let label: String
    let value: String
    var detail: String?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(label)
                .zoText(.caption)
                .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)

            Text(value)
                .zoThemeText(.metric)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .minimumScaleFactor(0.72)

            if let detail {
                Text(detail)
                    .zoText(.caption)
                    .foregroundStyle(contrast == .increased ? theme.textSecondary : theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ZeroOneSectionHeader: View {
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(title)
                    .zoThemeText(.title)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                if let detail {
                    Text(detail)
                        .zoText(.caption)
                        .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
                }
            }

            Spacer(minLength: ZOSpace.m)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .zoText(.caption)
                    .foregroundStyle(theme.brandGradientHorizontal)
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens \(title)"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}


struct ZeroOneRingProgress: View {
    let progress: Double
    var tint: Color? = nil
    var track: Color? = nil
    var lineWidth: CGFloat = 10
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    private var boundedProgress: Double {
        progress.isFinite ? min(max(progress, 0), 1) : 0
    }

    var body: some View {
        Circle()
            .stroke(track ?? (contrast == .increased ? theme.separatorStrong : theme.surfaceTertiary), style: StrokeStyle(lineWidth: lineWidth))
            .overlay {
                Circle()
                    .trim(from: 0, to: boundedProgress)
                    .stroke(
                        progressStyle,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text("\(Int((boundedProgress * 100).rounded())) percent"))
    }

    private var progressStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(theme.textPrimary)
    }
}

struct ZeroOneEmptyState: View {
    let label: String
    let title: String
    let message: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text(label)
                .zoText(.caption)
                .foregroundStyle(theme.brandGradientHorizontal)

            Text(title)
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .zoText(.label)
                .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ZOSpace.l)
        .overlay(alignment: .bottom) {
            Rectangle().fill(contrast == .increased ? theme.separatorStrong : theme.strokeSubtle).frame(height: ZOStroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ZeroOneLoadingState: View {
    let label: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: ZOSpace.m) {
            ZOLoadingSpinner()
                .foregroundStyle(theme.textPrimary)
                .accessibilityHidden(true)

            Text(label)
                .zoText(.section)
                .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ZOSpace.l)
        .accessibilityElement(children: .combine)
    }
}
