import SwiftUI

struct OutdoorRouteThumbnail: View {
    let route: OutdoorRouteAccumulator?
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Canvas { context, size in
            for segment in route.map(OutdoorPresentation.thumbnail) ?? [] {
                var path = Path()
                for (index, point) in segment.points.enumerated() {
                    let position = CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: .color(theme.textPrimary),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if segment.points.count == 1, let point = segment.points.first {
                    context.fill(Path(ellipseIn: CGRect(x: CGFloat(point.x) * size.width - 2,
                                                        y: CGFloat(point.y) * size.height - 2,
                                                        width: 4, height: 4)), with: .color(theme.textPrimary))
                }
            }
        }
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

struct OutdoorSavedTick: View {
    let plays: Bool
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    @State private var hasPlayed = false

    var body: some View {
        Circle().fill(theme.successPrimary)
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 17, y: 28))
                    path.addLine(to: CGPoint(x: 24, y: 35))
                    path.addLine(to: CGPoint(x: 39, y: 19))
                }
                .trim(from: 0, to: progress)
                .stroke(theme.backgroundPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            .onChange(of: reduceMotion) { _, enabled in
                if enabled {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { progress = 1 }
                }
            }
            .task(id: plays) {
                guard plays, !hasPlayed else { return }
                hasPlayed = true
                guard !reduceMotion else { return }
                progress = 0
                withAnimation(ZOMotion.carry(ZOMotion.quick)) { progress = 1 }
            }
    }
}

struct OutdoorSummaryFacts: View {
    let seconds: TimeInterval
    let meters: Double?
    let steps: Int?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            fact("outdoor.design.time", OutdoorPresentation.duration(seconds), unit: "")
            let distance = OutdoorPresentation.distance(meters, locale: localization.locale)
            fact("outdoor.design.distance", distance, unit: distance == "—" ? "" : "km")
            fact("outdoor.design.steps", OutdoorPresentation.steps(steps, locale: localization.locale), unit: "")
        }
    }

    private func fact(_ key: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localization.string(key)).zoText(.caption)
                .foregroundStyle(contrast == .increased ? theme.textPrimary : theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).zoProofText(.metric, size: 26, lineHeight: 30, weight: 800, width: 75, tabular: true)
                if !unit.isEmpty { Text(unit).zoText(.caption) }
            }
            .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Proof 47's small, 22-piece burst. Tick-tier timing, one mounted appearance;
/// the timeline is removed at the end and cannot obscure Done or Share.
struct OutdoorSavedBurst: View {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var finished = false

    var body: some View {
        if !finished && !reduceMotion {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    guard let startedAt else { return }
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let progress = min(1, max(0, elapsed / ZOMotion.Celebration.tick))
                    for index in 0..<22 {
                        let x = Double((index * 71 + 29) % 393) / 393
                        let y = Double((index * 37 + 11) % 120) / 200
                        var piece = context
                        piece.opacity = 1 - progress
                        piece.translateBy(x: size.width * x + Double(index % 5 - 2) * 10 * progress,
                                          y: size.height * y + 36 * progress)
                        piece.rotate(by: .degrees(Double(index * 43) + 90 * progress))
                        let color = index % 3 == 0 ? theme.accentFill : theme.textPrimary
                        piece.fill(Path(roundedRect: CGRect(x: -2, y: -3, width: 4, height: 6), cornerRadius: 1),
                                   with: .color(color))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { finished = true }
            }
            .task {
                guard startedAt == nil else { return }
                startedAt = .now
                do { try await Task.sleep(for: .seconds(ZOMotion.Celebration.tick)) } catch {
                    finished = true
                    return
                }
                finished = true
            }
        }
    }
}
