import SwiftUI

/// Proof 27 "Ask like a person, show what you get": before iOS asks, a Lock
/// Screen with the three kinds of note 01 sends (reminders you set, recovery
/// after a big week, now and then something worth knowing). Examples only.
struct NotificationPermissionCard: View {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    private struct Example: Identifiable {
        let id: Int
        let title: String
        let when: String
        let body: String
        let symbol: String
        let opacity: Double
    }

    private var examples: [Example] {
        [
            Example(id: 0, title: "Training day", when: "18:00",
                    body: "Upper body A is ready when you are. About 40 min.", symbol: "calendar", opacity: 1),
            Example(id: 1, title: "Big week for legs", when: "09:10",
                    body: "16 hard sets since Monday. An easy walk today helps.", symbol: "shoeprints.fill", opacity: 0.8),
            Example(id: 2, title: "Did you know", when: localization.string("Tue"),
                    body: "Under 6 hours of sleep can cost you reps. 2 min read.", symbol: "book", opacity: 0.6)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            VStack(spacing: ZOSpace.s) {
                VStack(spacing: 0) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(localization.locale)))
                        .font(.system(size: 13, weight: .semibold))
                    Text("18:02").font(.system(size: 44, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, ZOSpace.s)
                .accessibilityHidden(true)
                ForEach(examples) { example in row(example) }
            }
            .padding(ZOSpace.l)
            .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text("Reminders worth getting").zoThemeText(.title)
                    .accessibilityAddTraits(.isHeader)
                Text("Your training days, a recovery tip after a big week, and now and then something worth knowing. Never during a workout, never guilt.")
                    .zoText(.body).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ example: Example) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image("ZeroOneWordmark")
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(.black)
                .padding(5)
                .frame(width: 30, height: 30)
                .background(Color(red: 1, green: 0.996, blue: 0.165), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(localization.string(example.title)).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(verbatim: example.when).font(.system(size: 12)).opacity(0.7)
                }
                Text(localization.string(example.body)).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: example.symbol).font(.system(size: 13)).opacity(0.7).accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(example.opacity)
        .accessibilityElement(children: .combine)
    }
}
