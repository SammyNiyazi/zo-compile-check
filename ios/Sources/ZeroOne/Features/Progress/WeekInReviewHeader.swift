import SwiftUI

/// Proof 43: the top of "Week in review". Dates, one headline, the seven days,
/// the coach's lines, hard sets by muscle group against what the plan schedules,
/// and, at the end of the week, the one group furthest under the plan.
struct WeekInReviewHeader: View {
    let review: WeekInReview

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dates: String {
        let style = Date.FormatStyle.dateTime.day().month(.wide).locale(localization.locale)
        let last = review.end.addingTimeInterval(-1)
        return localization.format("%1$@ to %2$@", .text(review.start.formatted(style)), .text(last.formatted(style)))
    }

    private var maximum: Double {
        let values = review.rows.flatMap { [Double($0.done), $0.plan?.upperBound ?? 0] }
        return max(values.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: dates).zoText(.caption).foregroundStyle(theme.textSecondary)
                Text(verbatim: review.headline(localization)).zoThemeText(.display)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: ZOSpace.xs) {
                ForEach(review.days) { day in dayDot(day) }
            }
            let lines = review.coachLines(localization)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line).zoText(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !review.rows.isEmpty {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Hard sets by muscle group").zoText(.section)
                        Spacer(minLength: ZOSpace.s)
                        Text("This week").zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    VStack(spacing: ZOSpace.s) {
                        ForEach(review.rows) { row in bar(row) }
                    }
                    if review.rows.contains(where: { $0.plan != nil }) {
                        HStack(spacing: ZOSpace.m) {
                            legend(fill: theme.textPrimary, label: "Done")
                            legend(fill: theme.textPrimary.opacity(0.18), label: "Your plan")
                        }
                    }
                }
                .padding(ZOSpace.cardPadding)
                .zoThemeCardSurface()
            }
            if review.isWeekEnding, let gap = review.shortfall {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("For next week").zoText(.caption).foregroundStyle(theme.textSecondary)
                    Text(verbatim: localization.format(gap.sets == 1 ? "%1$@ is %2$@ set under your plan." : "%1$@ is %2$@ sets under your plan.",
                        .text(localization.string(gap.group.title)), .text(String(gap.sets))))
                        .zoText(.section).fixedSize(horizontal: false, vertical: true)
                    Text("Your plan and your days stay the same unless you change them.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                .padding(ZOSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zoThemeCardSurface()
            }
        }
    }

    private func dayDot(_ day: WeekInReview.Day) -> some View {
        let label = day.date.formatted(.dateTime.weekday(.narrow).locale(localization.locale))
        return VStack(spacing: ZOSpace.xs) {
            Text(verbatim: label).zoText(.caption).foregroundStyle(theme.textSecondary)
            ZStack {
                Circle().fill(day.trained ? theme.textPrimary : theme.surfaceSecondary)
                if day.trained {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.backgroundPrimary)
                } else {
                    Text(day.date.formatted(.dateTime.day().locale(localization.locale)))
                        .zoText(.caption)
                        .foregroundStyle(day.isFuture ? theme.textSecondary : theme.textPrimary)
                }
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(day.isToday && !day.trained ? theme.textPrimary : .clear, lineWidth: ZOStroke.focus))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(localization.locale)))
        .accessibilityValue(localization.string(day.trained ? "Trained" : (day.isFuture ? "Ahead" : "Rest day")))
    }

    private func bar(_ row: WeekInReview.Row) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.xs))
            : AnyLayout(HStackLayout(spacing: ZOSpace.s))
        return layout {
            Text(localization.string(row.group.title)).zoText(.label)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 84, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceSecondary)
                    if let plan = row.plan {
                        Capsule().fill(theme.textPrimary.opacity(0.18))
                            .frame(width: max(4, width * (plan.upperBound - plan.lowerBound) / maximum))
                            .offset(x: width * plan.lowerBound / maximum)
                    }
                    Capsule().fill(theme.textPrimary)
                        .frame(width: max(row.done > 0 ? 4 : 0, width * Double(row.done) / maximum))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            Text(String(row.done)).zoText(.label).monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.string(row.group.title))
        .accessibilityValue(row.plan.map { plan in
            localization.format("%1$@ hard sets. Your plan: %2$@ to %3$@.", .text(String(row.done)),
                                .text(String(Int(plan.lowerBound.rounded()))), .text(String(Int(plan.upperBound.rounded()))))
        } ?? localization.format("%1$@ hard sets.", .text(String(row.done))))
    }

    private func legend(fill: Color, label: String) -> some View {
        HStack(spacing: ZOSpace.xs) {
            Capsule().fill(fill).frame(width: 14, height: 6)
            Text(localization.string(label)).zoText(.caption).foregroundStyle(theme.textSecondary)
        }
    }
}
