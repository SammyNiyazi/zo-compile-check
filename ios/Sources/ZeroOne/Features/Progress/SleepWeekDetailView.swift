import SwiftUI

/// Proof 19 body: last night with its stages, the week with the average, bedtimes
/// and nights over the person's own goal.
struct SleepWeekDetailView: View {
    let week: SleepWeek
    @AppStorage(SleepGoal.key) private var goalMinutes = SleepGoal.defaultMinutes
    @Environment(\.calendar) private var calendar
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var editsGoal = false

    private var sleepColor: Color { ZOColor.resolved(ZOColor.Data.sleep, in: theme.colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let night = week.lastNight, night.hasData {
                lastNight(night)
                stages(night)
            } else {
                Text("No sleep was recorded last night.").zoText(.body).foregroundStyle(theme.textSecondary)
            }
            weekCard
            HStack(alignment: .top, spacing: ZOSpace.s) {
                tile(title: "Bedtime", value: bedtimeText, caption: localization.string("this week"))
                Button { editsGoal = true } label: {
                    tile(title: localization.format("Over %1$@", .text(Self.hours(goalMinutes, localization: localization, short: true))),
                         value: nightsText,
                         caption: localization.format("goal %1$@", .text(Self.hours(goalMinutes, localization: localization))))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(localization.string("Change your sleep goal")))
            }
        }
        .sheet(isPresented: $editsGoal) {
            NavigationStack {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text(Self.hours(goalMinutes, localization: localization)).zoThemeText(.metric)
                    Stepper(localization.string("Sleep goal"), value: $goalMinutes, in: SleepGoal.range, step: 15)
                    Text("Your own goal. 01 uses it only to count nights; it does not tell you how much to sleep.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(ZOSpace.screenMargin)
                .navigationTitle(localization.string("Sleep goal"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(localization.string("Done")) { editsGoal = false } } }
            }
            .presentationDetents([.medium])
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
    }

    // MARK: Last night

    private func lastNight(_ night: SleepNight) -> some View {
        let minutes = Int((night.asleepSeconds / 60).rounded())
        return VStack(alignment: .leading, spacing: ZOSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "\(minutes / 60)").zoProofText(.timer, size: 44, lineHeight: 48)
                Text(verbatim: "h").zoText(.label).foregroundStyle(theme.textSecondary)
                Text(verbatim: String(format: "%02d", minutes % 60)).zoProofText(.timer, size: 44, lineHeight: 48)
                    .padding(.leading, 4)
                Text("min").zoText(.label).foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(localization.format("%1$lld hours %2$lld minutes asleep", .integer(minutes / 60), .integer(minutes % 60))))
            if let start = night.fellAsleep, let end = night.wokeUp {
                Text(localization.format("%1$@ to %2$@ · goal %3$@", .text(time(start)), .text(time(end)),
                                         .text(Self.hours(goalMinutes, localization: localization))))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func stages(_ night: SleepNight) -> some View {
        let start = night.segments.map(\.start).min() ?? night.wakeDay
        let end = night.segments.map(\.end).max() ?? night.wakeDay
        let span = max(end.timeIntervalSince(start), 1)
        let hasStages = night.segments.contains { [.deep, .core, .rem].contains($0.stage) }
        return VStack(alignment: .leading, spacing: ZOSpace.s) {
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(night.segments.enumerated()), id: \.offset) { _, segment in
                        let x = proxy.size.width * segment.start.timeIntervalSince(start) / span
                        let width = max(1, proxy.size.width * segment.duration / span)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fill(segment.stage))
                            .frame(width: width, height: proxy.size.height * height(segment.stage))
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 44)
            .accessibilityHidden(true)
            if hasStages {
                HStack(spacing: ZOSpace.m) {
                    legend("Deep", .deep)
                    legend("Core", .core)
                    legend("REM", .rem)
                    legend("Awake", .awake)
                }
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stagesSummary(night)))
    }

    private func fill(_ stage: SleepStage) -> Color {
        switch stage {
        case .deep: sleepColor
        case .rem: sleepColor.opacity(0.7)
        case .core, .asleep: sleepColor.opacity(0.45)
        case .awake: theme.surfaceTertiary
        }
    }

    private func height(_ stage: SleepStage) -> CGFloat {
        switch stage {
        case .deep: 1
        case .rem: 0.62
        case .core, .asleep: 0.78
        case .awake: 0.3
        }
    }

    private func legend(_ title: String, _ stage: SleepStage) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(fill(stage)).frame(width: 8, height: 8)
            Text(localization.string(title)).zoText(.mini).foregroundStyle(theme.textSecondary)
        }
    }

    private func stagesSummary(_ night: SleepNight) -> String {
        func minutes(_ stage: SleepStage) -> Int { Int((night.segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration } / 60).rounded()) }
        return localization.format("Stages: deep %1$lld minutes, core %2$lld, REM %3$lld, awake %4$lld.",
            .integer(minutes(.deep)), .integer(minutes(.core) + minutes(.asleep)), .integer(minutes(.rem)), .integer(minutes(.awake)))
    }

    // MARK: Week

    private var weekCard: some View {
        let maximum = max(week.nights.map(\.asleepSeconds).max() ?? 0, Double(goalMinutes) * 60, 1)
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").zoText(.section).accessibilityAddTraits(.isHeader)
                Spacer()
                if let average = week.averageSeconds {
                    Text(localization.format("Average %1$@", .text(Self.hours(Int((average / 60).rounded()), localization: localization))))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            HStack(alignment: .bottom, spacing: ZOSpace.s) {
                ForEach(Array(week.nights.enumerated()), id: \.offset) { index, night in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == week.nights.count - 1 ? sleepColor : sleepColor.opacity(0.45))
                            .frame(height: night.hasData ? max(4, 64 * night.asleepSeconds / maximum) : 4)
                            .opacity(night.hasData ? 1 : 0.35)
                        Text(night.wakeDay.formatted(.dateTime.weekday(.narrow).locale(localization.locale)))
                            .zoText(.mini).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(night.hasData
                        ? localization.format("%1$@, %2$@", .text(night.wakeDay.formatted(.dateTime.weekday(.wide).locale(localization.locale))),
                                              .text(Self.hours(Int((night.asleepSeconds / 60).rounded()), localization: localization)))
                        : localization.format("%1$@, no sleep recorded", .text(night.wakeDay.formatted(.dateTime.weekday(.wide).locale(localization.locale))))))
                }
            }
            .frame(height: 84, alignment: .bottom)
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }

    private func tile(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Text(value).zoText(.section).foregroundStyle(theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).zoText(.mini).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var bedtimeText: String {
        guard let range = week.bedtimeRange(calendar: calendar) else { return localization.string("Not recorded") }
        let earliest = time(range.earliest), latest = time(range.latest)
        return earliest == latest ? earliest : localization.format("%1$@ to %2$@", .text(earliest), .text(latest))
    }

    private var nightsText: String {
        let count = week.nightsOver(goalMinutes: goalMinutes)
        return localization.format("%1$lld of %2$lld nights", .integer(count.met), .integer(count.recorded))
    }

    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(localization.locale))
    }

    static func hours(_ minutes: Int, localization: AppLocalization, short: Bool = false) -> String {
        let h = minutes / 60, m = minutes % 60
        if short && m == 0 { return localization.format("%1$lld hours", .integer(h)) }
        return m == 0 ? localization.format("%1$lld h", .integer(h)) : localization.format("%1$lld h %2$lld", .integer(h), .integer(m))
    }
}
