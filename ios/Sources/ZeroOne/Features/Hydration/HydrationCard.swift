import SwiftUI

struct HydrationCard: View {
    let state: HydrationState
    let onAddWater: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text("Water")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text("GOAL \(liters(state.goalMilliliters)) L")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
            }

            hydrationCopy

            ZOProgress(progress: state.progress)
            .accessibilityLabel("Water goal")

            DisclosureGroup("This week's water") {
                HydrationTrendLine(records: state.recentIntake(), goalMilliliters: state.goalMilliliters)
            }
            .zoText(.label)
            .foregroundStyle(theme.textSecondary)

            HStack(spacing: ZOSpace.s) {
                quickAddButton(amount: 250, isPrimary: true)
                quickAddButton(amount: 500, isPrimary: false)
            }
        }
        .padding(ZOSpace.xl)
        .zoThemeCardSurface()
        .sensoryFeedback(.increase, trigger: state.currentMilliliters)
        .accessibilityElement(children: .contain)
    }

    private var hydrationCopy: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                Text(liters(state.currentMilliliters))
                    .zoThemeText(.metric)
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText(value: Double(state.currentMilliliters)))

                Text("L")
                    .zoText(.section)
                    .foregroundStyle(theme.textSecondary)
            }

            Text(hydrationSummary)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(
                    reduceMotion ? nil : ZeroOneMotion.standard,
                    value: state.remainingMilliliters
                )

            Text(state.progress.formatted(.percent.precision(.fractionLength(0))))
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
                .contentTransition(.numericText(value: state.progress))
                .animation(reduceMotion ? nil : ZeroOneMotion.standard, value: state.progress)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hydration")
        .accessibilityValue("\(state.currentMilliliters) of \(state.goalMilliliters) milliliters")
    }

    private var hydrationSummary: String {
        if state.remainingMilliliters == 0 {
            return "Goal reached. Keep the rhythm steady."
        }

        return "\(liters(state.remainingMilliliters)) L left. Small additions, no catch-up."
    }

    private func quickAddButton(amount: Int, isPrimary: Bool) -> some View {
        Button {
            onAddWater(amount)
        } label: {
            HStack(spacing: ZOSpace.s) {
                Image(systemName: "plus")
                    .zoIcon(ZOIcon.row)
                Text("\(amount) ml")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ZOButtonStyle(isPrimary ? .primary : .secondary, wide: true))
        .accessibilityLabel("Add \(amount) milliliters")
        .accessibilityHint("Adds water to today's hydration total.")
    }

    private func liters(_ milliliters: Int) -> String {
        (Double(milliliters) / 1_000)
            .formatted(.number.precision(.fractionLength(1 ... 2)))
    }
}

private struct HydrationTrendLine: View {
    let records: [HydrationDailyRecord]
    let goalMilliliters: Int
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                Text("7-DAY RHYTHM")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text("TODAY")
                    .zoText(.caption)

                    .foregroundStyle(theme.textPrimary)
            }

            GeometryReader { proxy in
                Canvas { context, size in
                    guard !records.isEmpty else { return }
                    let maximum = Double(max(goalMilliliters, records.map(\.consumedMilliliters).max() ?? goalMilliliters))
                    let widthStep = records.count > 1 ? size.width / CGFloat(records.count - 1) : 0
                    let lastIndex = records.index(before: records.endIndex)

                    func point(at index: Int) -> CGPoint {
                        let ratio = Double(records[index].consumedMilliliters) / maximum
                        return CGPoint(
                            x: CGFloat(index) * widthStep,
                            y: size.height - CGFloat(ratio) * (size.height - 8) - 4
                        )
                    }

                    var guide = Path()
                    let goalY = size.height - CGFloat(Double(goalMilliliters) / maximum) * (size.height - 8) - 4
                    guide.move(to: CGPoint(x: 0, y: goalY))
                    guide.addLine(to: CGPoint(x: size.width, y: goalY))
                    context.stroke(guide, with: .color(theme.textSecondary.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                    var line = Path()
                    line.move(to: point(at: 0))
                    for index in records.indices.dropFirst() {
                        line.addLine(to: point(at: index))
                    }
                    context.stroke(line, with: .color(theme.textSecondary.opacity(0.78)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    for index in records.indices {
                        let point = point(at: index)
                        let size: CGFloat = index == lastIndex ? 7 : 4
                        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                        if index == lastIndex {
                            context.fill(Path(ellipseIn: rect), with: .linearGradient(
                                Gradient(colors: theme.brandGradientColors),
                                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                            ))
                        } else {
                            context.fill(Path(ellipseIn: rect), with: .color(theme.textSecondary))
                        }
                    }
                }
            }
            .frame(height: 52)
        }
        .padding(.vertical, ZOSpace.l)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hydration trend for the last seven days")
        .accessibilityValue(trendAccessibilityValue)
    }

    private var trendAccessibilityValue: String {
        records.map { record in
            "\(record.date.formatted(.dateTime.weekday(.wide))): \(record.consumedMilliliters) milliliters"
        }.joined(separator: ", ")
    }
}
