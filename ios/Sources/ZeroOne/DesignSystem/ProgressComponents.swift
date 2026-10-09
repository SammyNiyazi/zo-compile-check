import SwiftUI

struct ZOProgress: View {
    let progress: Double
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var boundedProgress: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }
    // themes-fx.css zero-radius selectors do not include generic .zo-progress.
    private var radius: CGFloat { ZOStroke.progress / 2 }

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: radius)
                .fill(contrast == .increased ? theme.separatorStrong : theme.surfaceTertiary)
                .overlay(alignment: .leading) {
                    if reduceMotion {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(theme.textPrimary)
                            .frame(width: proxy.size.width * boundedProgress)
                            // Each supplied fraction is a fixed-width fill; only opacity changes.
                            .id(boundedProgress)
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(theme.textPrimary)
                            .frame(width: proxy.size.width * boundedProgress)
                    }
                }
        }
        .frame(height: ZOStroke.progress)
        .animation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.land(ZOMotion.quick), value: boundedProgress)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text("\(Int((boundedProgress * 100).rounded())) percent"))
    }
}

/// Rest is the folded next-action object. It retains the chosen accent while counting down.
struct ZORestLine: View {
    let progress: Double
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    private var boundedProgress: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }
    private var radius: CGFloat { theme.designTheme == .freak ? 0 : ZOStroke.restLine / 2 }

    private var fill: AnyShapeStyle {
        switch theme.designTheme {
        case .core: AnyShapeStyle(theme.accentFill)
        case .retro:
            AnyShapeStyle(LinearGradient(colors: [Color(zoHex: 0xC04DFF), Color(zoHex: 0xFF4D6D),
                Color(zoHex: 0xFF8A3D), theme.accentFill], startPoint: .leading, endPoint: .trailing))
        case .princess:
            AnyShapeStyle(LinearGradient(colors: [Color(zoHex: 0xC9B4FF), theme.accentFill],
                startPoint: .leading, endPoint: .trailing))
        case .freak:
            if theme.colorScheme == .light {
                AnyShapeStyle(LinearGradient(colors: [theme.textSecondary, theme.textPrimary, theme.textSecondary],
                    startPoint: .top, endPoint: .bottom))
            } else {
                AnyShapeStyle(LinearGradient(stops: [
                    .init(color: Color(zoHex: 0xFFFFFF), location: 0),
                    .init(color: Color(zoHex: 0xE9ECEF), location: 0.30),
                    .init(color: Color(zoHex: 0x8D939B), location: 0.50),
                    .init(color: Color(zoHex: 0x4D535B), location: 0.52),
                    .init(color: Color(zoHex: 0xE9ECEF), location: 0.80),
                    .init(color: Color(zoHex: 0xFFFFFF), location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: radius)
            shape.fill(contrast == .increased ? theme.separatorStrong : theme.surfaceTertiary)
                .overlay(alignment: .leading) {
                    shape.fill(fill)
                        .overlay {
                            shape.strokeBorder(theme.designTheme == .retro ? .clear : theme.accentEdge,
                                lineWidth: ZOStroke.hairline)
                        }
                        .frame(width: proxy.size.width * boundedProgress)
                        .shadow(color: theme.designTheme == .retro && theme.colorScheme == .dark
                            ? Color(zoHex: 0xFF8A3D) : .clear, radius: 12)
                }
                // Reference .zo-restline clips its fill and any static glow.
                .clipShape(shape)
        }
        .frame(height: ZOStroke.restLine)
        .accessibilityHidden(true)
    }
}

struct ZORailSegment: View {
    enum Mark { case saved, current, ahead }
    let mark: Mark
    var radius: CGFloat = 2 * ZOStroke.hairline
    // Retained for caller compatibility; canonical generic rails have static state changes.
    var motionEnabled = true
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    private var saved: Bool { mark == .saved }
    private var resolvedRadius: CGFloat {
        switch theme.designTheme {
        case .core, .retro: radius
        case .freak: 0
        case .princess: 4
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: resolvedRadius)
                .fill(mark == .current ? theme.textPrimary.opacity(0.45) : (contrast == .increased ? theme.separatorStrong : theme.surfaceTertiary))
            RoundedRectangle(cornerRadius: resolvedRadius)
                .fill(theme.textPrimary)
                .shadow(color: saved && theme.designTheme == .retro && theme.colorScheme == .dark
                    ? Color(zoHex: 0xFF8A3D, alpha: 0.70) : .clear, radius: 6)
                .opacity(saved ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ZORail: View {
    let marks: [ZORailSegment.Mark]

    var body: some View {
        HStack(spacing: 2 * ZOStroke.hairline) {
            ForEach(marks.indices, id: \.self) { index in ZORailSegment(mark: marks[index]) }
        }
        .frame(height: ZOStroke.railApp)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text("\(marks.filter { $0 == .saved }.count) of \(marks.count) saved"))
    }
}
