import SwiftUI

/// Princess finish, README decision 70: one pearl band crosses the finish
/// totals once, left to right, as the sparkles peak. Timing and colour only;
/// whether the finish earned a celebration stays with the caller.
enum ThemeNumberShimmer {
    static let delay = 0.48
    static let duration = 0.72
    /// Width of the band as a share of one number's width.
    static let bandWidth = 0.3

    /// Band centre across the whole row (0 at the left edge of the first
    /// number, 1 at the right edge of the last), or nil outside the sweep.
    static func rowPosition(elapsed: Double, count: Int) -> Double? {
        guard elapsed.isFinite, count > 0, elapsed >= delay, elapsed < delay + duration else { return nil }
        let u = ThemeWinTimeline.eased((elapsed - delay) / duration, curve: ThemeWinTimeline.land)
        // Enter fully off the first number and leave fully off the last.
        let overhang = bandWidth / 2 / Double(count)
        return -overhang + u * (1 + 2 * overhang)
    }

    /// The band centre in one number's own width; 0...1 is on that number.
    static func localPosition(row: Double, index: Int, count: Int) -> Double {
        row * Double(count) - Double(index)
    }

    /// Gradient stops for one number, or nil when the band is not on it.
    static func stops(center: Double, ink: Color, band: [Color]) -> [Gradient.Stop]? {
        let half = bandWidth / 2
        guard !band.isEmpty, center + half > 0, center - half < 1 else { return nil }
        func clamped(_ location: Double) -> Double { min(max(location, 0), 1) }
        var stops: [Gradient.Stop] = [.init(color: ink, location: 0), .init(color: ink, location: clamped(center - half))]
        for (offset, color) in band.enumerated() {
            let location = center - half + Double(offset + 1) * bandWidth / Double(band.count + 1)
            stops.append(.init(color: color, location: clamped(location)))
        }
        stops.append(.init(color: ink, location: clamped(center + half)))
        stops.append(.init(color: ink, location: 1))
        return stops
    }

    /// Dark: pearl lilac, pearl, pearl pink. Light: white would vanish on the
    /// tile, so lilac and the accent.
    static func band(theme: ZeroOneThemeTokens) -> [Color] {
        theme.colorScheme == .light
            ? [Color(zoHex: 0xC9B4FF), theme.accentFill]
            : [Color(zoHex: 0xEDE4FF), Color(zoHex: 0xFFFFFF), Color(zoHex: 0xFBE5EF)]
    }
}

/// Applies the sweep to one number of a row. Starts when `active` first turns
/// true, plays once, then leaves the number exactly as it was. Never under
/// Reduce Motion, never outside Princess.
struct PrincessNumberShimmer: ViewModifier {
    let active: Bool
    let index: Int
    let count: Int

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false

    func body(content: Content) -> some View {
        Group {
            if let start, !finished, !reduceMotion, theme.designTheme == .princess {
                TimelineView(.animation) { context in
                    content.foregroundStyle(style(elapsed: context.date.timeIntervalSince(start)))
                }
            } else {
                content
            }
        }
        .onAppear(perform: latch)
        .onChange(of: active) { _, _ in latch() }
        .task(id: start) {
            guard start != nil else { return }
            try? await Task.sleep(for: .seconds(ThemeNumberShimmer.delay + ThemeNumberShimmer.duration))
            guard !Task.isCancelled else { return }
            finished = true
        }
    }

    private func latch() {
        guard active, start == nil, !finished else { return }
        start = .now
    }

    private func style(elapsed: Double) -> AnyShapeStyle {
        guard let row = ThemeNumberShimmer.rowPosition(elapsed: elapsed, count: count),
              let stops = ThemeNumberShimmer.stops(
                  center: ThemeNumberShimmer.localPosition(row: row, index: index, count: count),
                  ink: theme.textPrimary, band: ThemeNumberShimmer.band(theme: theme))
        else { return AnyShapeStyle(theme.textPrimary) }
        return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
    }
}
