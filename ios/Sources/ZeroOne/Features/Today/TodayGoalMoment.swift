import SwiftUI

/// Proof 1 / README "goal moment": when a Today ring is seen crossing its goal, it
/// closes, fills to the accent disc with the burst, holds 1.44 s, then settles to a
/// full ink ring with the small check. Once per goal per day; Reduce Motion settles.
enum TodayGoalMomentLog {
    static let key = "01.today.goalMoments"
    /// A second copy of the same ring (ViewThatFits) joins a moment started this recently.
    static let joinWindow: TimeInterval = 3

    /// The start of today's moment for this goal: new when first seen crossing,
    /// shared while it plays, nil once today's moment has already played.
    static func start(_ kind: String, now: Date = .now, calendar: Calendar = .current,
                      defaults: UserDefaults = .standard) -> Date? {
        let day = dayKey(kind, now, calendar)
        var log = load(defaults)
        if let existing = log[day] {
            return now.timeIntervalSince(existing) < joinWindow ? existing : nil
        }
        log[day] = now
        let cutoff = now.addingTimeInterval(-21 * 86_400)
        log = log.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: key) }
        return now
    }

    /// Goals met this calendar week, across steps and water.
    static func goalsThisWeek(now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Int {
        load(defaults).values.filter { calendar.isDate($0, equalTo: now, toGranularity: .weekOfYear) }.count
    }

    private static func dayKey(_ kind: String, _ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(kind)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private static func load(_ defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return log
    }
}

/// The moment itself, drawn over the 60 pt Today ring.
struct TodayGoalMomentRing: View {
    let start: Date
    let fromProgress: Double
    let symbol: String

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let frame = StepsGoalMomentTiming.frame(elapsed: elapsed, fromProgress: fromProgress, reduceMotion: reduceMotion)
            ZStack {
                Circle().stroke(theme.surfaceTertiary, lineWidth: 7).opacity(frame.ringOpacity)
                Circle().trim(from: 0, to: frame.progress)
                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(frame.ringOpacity)
                Circle().fill(theme.accentFill)
                    .overlay { Circle().strokeBorder(theme.accentEdge, lineWidth: 1) }
                    .scaleEffect(frame.discScale)
                    .opacity(frame.discOpacity)
                ZOAppIcon(symbol).foregroundStyle(frame.onAccent ? theme.onAccent : theme.textPrimary)
            }
            .padding(3.5)
            .frame(width: 60, height: 60)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .zoIcon(ZOIcon.inline)
                    .foregroundStyle(theme.backgroundPrimary)
                    .frame(width: 22, height: 22)
                    .background(theme.textPrimary, in: Circle())
                    .overlay { Circle().strokeBorder(theme.surfacePrimary, lineWidth: 2) }
                    .offset(x: 2, y: 2)
                    .scaleEffect(frame.checkScale)
                    .opacity(frame.checkOpacity)
            }
            .overlay {
                if !reduceMotion, elapsed >= StepsGoalMomentTiming.close {
                    ThemeWinRenderer(theme: theme, tier: .goal(origin: CGPoint(x: 110, y: 110)),
                        elapsed: elapsed - StepsGoalMomentTiming.close, reduceMotion: reduceMotion)
                        .frame(width: 220, height: 220)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
