import Charts
import SwiftUI

struct ProgressWeightTrendCard: View {
    let chart: ProgressWeightChart
    let unit: BodyWeightUnit
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Weight, 7-day average").zoText(.caption).foregroundStyle(theme.textSecondary)
            if let average = chart.recentAverage {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(unit.displayedValue(for: average).formatted(.number.precision(.fractionLength(1)).locale(localization.locale)))
                        .zoText(.metric)
                    Text(unit.rawValue).zoProofText(.body, size: 15, lineHeight: 20, weight: 500)
                        .foregroundStyle(theme.textSecondary)
                }
                Text(localization.format("%1$lld of 7 days recorded", .integer(chart.recentSampleCount)))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                Text("No recent readings").zoText(.section)
            }
            if chart.domain(unit: unit) != nil {
                Chart {
                    ForEach(chart.days) { day in
                        if let reading = day.reading {
                            PointMark(x: .value(localization.string("Date"), day.day),
                                      y: .value(localization.string("Reading"), unit.displayedValue(for: reading)))
                                .foregroundStyle(theme.textTertiary)
                                .symbolSize(20)
                        }
                        if let average = day.average {
                            LineMark(x: .value(localization.string("Date"), day.day),
                                     y: .value(localization.string("7-day average"), unit.displayedValue(for: average)),
                                     series: .value(localization.string("Recorded interval"), day.series))
                                .foregroundStyle(theme.textPrimary)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            // An isolated observed day still has an average, without a connecting line.
                            PointMark(x: .value(localization.string("Date"), day.day),
                                      y: .value(localization.string("7-day average"), unit.displayedValue(for: average)))
                                .foregroundStyle(theme.textPrimary).symbolSize(12)
                        }
                    }
                }
                .chartXScale(domain: chart.interval.start ... chart.interval.end)
                .chartYScale(domain: chart.domain(unit: unit) ?? (0 ... 1))
                .chartLegend(.hidden)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [chart.interval.start, chart.interval.end.addingTimeInterval(-1)]) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(height: 120)
                .accessibilityLabel(localization.format("Weight readings and 7-day averages in %1$@", .text(unit.rawValue)))
                .accessibilityValue(chart.days.map { day in
                    let date = day.day.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))
                    guard let reading = day.reading else {
                        return localization.format("%1$@: not recorded", .text(date))
                    }
                    return localization.format("%1$@: %2$@ %3$@", .text(date),
                        .text(unit.displayedValue(for: reading).formatted(.number.precision(.fractionLength(1)).locale(localization.locale))), .text(unit.rawValue))
                }.joined(separator: "; "))
            } else {
                Text("No readings in this period").zoText(.body).foregroundStyle(theme.textSecondary)
            }
            Text("Daily dots. The line averages recorded days only. Missing days are gaps, never zero.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .zeroOneFeatureSurface()
    }
}

struct ProgressWorkoutTrendCard: View {
    let weeks: [ProgressWorkoutWeek]
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Workouts per week").zoText(.caption).foregroundStyle(theme.textSecondary)
            if let latest = weeks.last, let count = latest.count {
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.xs) {
                    Text(count.formatted(.number.locale(localization.locale))).zoText(.metric)
                    Text("saved this week").zoProofText(.body, size: 15, lineHeight: 20, weight: 500)
                        .foregroundStyle(theme.textSecondary)
                }
                Chart(weeks) { week in
                    if let count = week.count {
                        BarMark(x: .value(localization.string("Week"), week.start, unit: .weekOfYear), y: .value(localization.string("Saved workouts"), count))
                            .foregroundStyle(theme.textPrimary).cornerRadius(4)
                    }
                }
                .chartYScale(domain: 0 ... max(1, weeks.compactMap(\.count).max() ?? 1))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(height: 110)
                .accessibilityLabel("Workouts per week")
                .accessibilityValue(weeks.map { week in
                    if let count = week.count {
                        return localization.format("Week of %1$@: %2$lld saved workouts", .text(week.start.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))), .integer(count))
                    }
                    return localization.format("Week of %1$@: history unavailable", .text(week.start.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))))
                }.joined(separator: "; "))
                Text("Saved sessions only. Partial weeks include only dates in the selected period.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                Text("History unavailable").zoText(.section)
                Text("Saved workouts could not be read. No count or plan comparison is shown.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .zeroOneFeatureSurface()
    }
}

/// The current repository supplies one sleep duration, not stages, bedtime, a goal or weekly history.
struct ProgressSleepSummaryView: View {
    let healthConnection: HealthConnectionRepository
    @Environment(\.calendar) private var calendar
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    private func sleep(at now: Date) -> HealthSleepPresentation {
        HealthSleepPresentation(context: healthConnection.context, status: healthConnection.status,
            isStale: healthConnection.isContextStale, now: now, calendar: calendar)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
        let sleep = sleep(at: timeline.date)
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Label(LocalizedStringKey(sleep.periodKey), systemImage: "moon").zoText(.caption).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(theme.textSecondary)
                if let duration = sleep.duration {
                    Text(localization.format("%1$@ hr", .text((duration / 3_600).formatted(.number.precision(.fractionLength(1)).locale(localization.locale)))))
                        .zoProofText(.timer, size: 56, lineHeight: 56)
                } else {
                    Text("No readable sleep data").zoText(.title)
                    Text("There may be no recorded sleep, or access may be off. Apple Health does not tell 01 which.")
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                }
                if healthConnection.isContextStale {
                    Text("Last available reading").zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                if let context = healthConnection.context {
                    Text(localization.format("Updated %1$@", .text(context.refreshedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localization.locale)))))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                if let issue = healthConnection.issue {
                    Text(localization.string(issue.message)).zoText(.body).foregroundStyle(theme.textSecondary)
                }
                Text("From Apple Health. 01 shows what was recorded; it does not score your recovery.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                NavigationLink("Apple Health access") {
                    AppleHealthConnectionView(healthConnection: healthConnection)
                }.buttonStyle(ZOButtonStyle(.secondary))
            }
            .padding(.horizontal, ZOSpace.xl).padding(.vertical, ZOSpace.l)
        }
        }
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Sleep").navigationBarTitleDisplayMode(.inline)
        .task { await healthConnection.refreshIfConnected() }
    }
}
