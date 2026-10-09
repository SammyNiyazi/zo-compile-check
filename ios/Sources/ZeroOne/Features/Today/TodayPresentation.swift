import Foundation
import SwiftUI

enum TodayGoalPresentation {
    /// An absent/invalid goal is unknown, never a zero denominator or default goal.
    static func progress(value: Int, goal: Int?) -> Double? {
        guard let goal, goal > 0, value >= 0 else { return nil }
        return min(Double(value) / Double(goal), 1)
    }
}

/// Proof 1's paired 60 pt rings. Nil progress shows only the source icon,
/// without suggesting a known goal. The settled win is ink with an edge check.
struct TodayGoalRing: View {
    let progress: Double?
    let symbol: String
    @Environment(\.zeroOneTheme) private var theme

    private var bounded: Double? {
        progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    var body: some View {
        ZStack {
            if let bounded {
                Circle().stroke(theme.surfaceTertiary, lineWidth: 7)
                Circle().trim(from: 0, to: bounded)
                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().fill(theme.surfaceSecondary)
            }
            ZOAppIcon(symbol).foregroundStyle(theme.textPrimary)
        }
        .padding(3.5)
        .frame(width: 60, height: 60)
        .overlay(alignment: .bottomTrailing) {
            if bounded == 1 {
                Image(systemName: "checkmark")
                    .zoIcon(ZOIcon.inline)
                    .foregroundStyle(theme.backgroundPrimary)
                    .frame(width: 22, height: 22)
                    .background(theme.textPrimary, in: Circle())
                    .overlay { Circle().strokeBorder(theme.surfacePrimary, lineWidth: 2) }
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}
