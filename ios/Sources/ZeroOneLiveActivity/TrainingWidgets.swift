import SwiftUI
import WidgetKit

/// Study 36 widgets: Today (small, medium), This week (large), the 01 Club card
/// (small, medium) and the Lock Screen. Read-only views of the snapshot 01
/// publishes; buttons open 01, nothing starts by itself.
struct TrainingWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: DailyWidgetSnapshot?

    var training: DailyWidgetSnapshot.Training? {
        guard let snapshot, snapshot.isCurrent(on: date) else { return nil }
        return snapshot.training
    }
    var language: AppLanguage { snapshot?.displayLanguage ?? .english }
    var localization: AppLocalization { AppLocalization(language: language) }
    var accent: AccentPreference { snapshot?.accent ?? .yellow }
    var theme: ZOTheme { snapshot?.displayTheme ?? .core }
}

struct TrainingWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrainingWidgetEntry { .init(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TrainingWidgetEntry) -> Void) {
        completion(.init(date: .now, snapshot: try? FileDailyWidgetSnapshotStore().load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainingWidgetEntry>) -> Void) {
        let now = Date.now
        let saved = try? FileDailyWidgetSnapshotStore().load()
        let calendar = Calendar.autoupdatingCurrent
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        // Today's facts expire at midnight even if iOS defers the next refresh.
        completion(Timeline(entries: [.init(date: now, snapshot: saved), .init(date: midnight, snapshot: saved)],
                            policy: .after(min(now.addingTimeInterval(1_800), midnight))))
    }
}

private struct WidgetMark: View {
    var height: CGFloat = 12
    var body: some View {
        Image("01-mark-warm-white-approved-4096").renderingMode(.template).resizable().scaledToFit()
            .frame(width: height * 1.6, height: height)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private struct WeekStrip: View {
    let days: [DailyWidgetSnapshot.Training.Day]
    let language: AppLanguage
    let ink: Color
    let track: Color
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                ZStack {
                    Circle().fill(day.trained ? ink : Color.clear)
                    Circle().strokeBorder(day.trained ? .clear : (day.planned ? ink : track), lineWidth: 1.5)
                    if day.trained {
                        Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.background)
                    }
                }
                .frame(width: size, height: size)
                .overlay(Circle().stroke(day.isToday ? ink : .clear, lineWidth: 1).padding(-2.5))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(weekday(index)))
                .accessibilityValue(Text(AppLocalization(language: language).string(day.trained ? "Trained" : (day.planned ? "Planned" : "Rest day"))))
            }
        }
    }

    private func weekday(_ index: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        let symbols = calendar.standaloneWeekdaySymbols
        return symbols[(index + 1) % 7]
    }
}

private struct TodayWidgetView: View {
    let entry: TrainingWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    private var palette: DailyWidgetPalette { DailyWidgetPalette(dark: colorScheme == .dark, accent: entry.accent, designTheme: entry.theme) }
    private var l: AppLocalization { entry.localization }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                WidgetMark()
                Text(l.string("Today")).zoText(.mini).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
            }
            if let training = entry.training {
                content(training)
            } else {
                Text(l.string("Open 01 to see today's workout.")).zoText(.caption).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(palette.ink)
        .containerBackground(for: .widget) { palette.background }
        .environment(\.locale, l.locale)
        .widgetURL(DailyWidgetRoute.today.url)
    }

    @ViewBuilder private func content(_ training: DailyWidgetSnapshot.Training) -> some View {
        switch training.state {
        case .next:
            Text(verbatim: training.workoutTitle ?? l.string("Workout"))
                .zoProofText(.title, size: 18, lineHeight: 22, weight: 700).lineLimit(2)
            if let detail = detail(training) { Text(verbatim: detail).zoText(.mini).foregroundStyle(palette.secondary) }
            Spacer(minLength: 0)
            if family == .systemMedium { dailyRows }
            Link(destination: DailyWidgetRoute.workout.url) {
                DailyWidgetActionLabel(title: l.string("Start workout"), symbol: "play.fill", accent: entry.accent,
                                       language: entry.language, designTheme: entry.theme)
            }
        case .restDay:
            Text(l.string("Rest day")).zoProofText(.title, size: 18, lineHeight: 22, weight: 700)
            Text(l.string("Recovery is part of the plan.")).zoText(.mini).foregroundStyle(palette.secondary)
            Spacer(minLength: 0)
            if family == .systemMedium { dailyRows }
            WeekStrip(days: training.days, language: entry.language, ink: palette.ink, track: palette.track)
        case .inProgress:
            Text(l.string("Workout in progress")).zoProofText(.title, size: 18, lineHeight: 22, weight: 700).lineLimit(2)
            Spacer(minLength: 0)
            Link(destination: DailyWidgetRoute.workout.url) {
                DailyWidgetActionLabel(title: l.string("Open 01"), symbol: "arrow.up.forward", accent: entry.accent,
                                       language: entry.language, designTheme: entry.theme)
            }
        case .done:
            Label { Text(l.string("Done today")) } icon: { Image(systemName: "checkmark.circle.fill").widgetAccentable() }
                .zoProofText(.title, size: 18, lineHeight: 22, weight: 700)
            Text(verbatim: l.format("%1$lld workouts this week", .integer(training.workoutsThisWeek)))
                .zoText(.mini).foregroundStyle(palette.secondary)
            Spacer(minLength: 0)
            if family == .systemMedium { dailyRows }
            WeekStrip(days: training.days, language: entry.language, ink: palette.ink, track: palette.track)
        }
    }

    private func detail(_ training: DailyWidgetSnapshot.Training) -> String? {
        var parts: [String] = []
        if let count = training.exerciseCount, count > 0 {
            parts.append(l.format(count == 1 ? "%1$lld exercise" : "%1$lld exercises", .integer(count)))
        }
        if let minutes = training.minutes, minutes > 0 { parts.append(l.format("%1$lld min", .integer(minutes))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Medium: steps and water beside today's workout.
    @ViewBuilder private var dailyRows: some View {
        if let snapshot = entry.snapshot, snapshot.isCurrent(on: entry.date) {
            HStack(spacing: 12) {
                if let steps = snapshot.steps.value {
                    Label { Text(Int(steps).formatted(.number.locale(l.locale))) } icon: { Image(systemName: "shoeprints.fill") }
                }
                if let water = snapshot.waterMilliliters.value {
                    Label { Text(verbatim: (water / 1000).formatted(.number.precision(.fractionLength(1)).locale(l.locale)) + " L") }
                        icon: { Image(systemName: "drop.fill") }
                }
            }
            .zoText(.mini).foregroundStyle(palette.secondary)
        }
    }
}

private struct WeekWidgetView: View {
    let entry: TrainingWidgetEntry
    @Environment(\.colorScheme) private var colorScheme
    private var palette: DailyWidgetPalette { DailyWidgetPalette(dark: colorScheme == .dark, accent: entry.accent, designTheme: entry.theme) }
    private var l: AppLocalization { entry.localization }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                WidgetMark()
                Text(l.string("This week")).zoText(.mini).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
            }
            if let training = entry.training {
                Text(verbatim: headline(training)).zoProofText(.title, size: 22, lineHeight: 26, weight: 700)
                WeekStrip(days: training.days, language: entry.language, ink: palette.ink, track: palette.track, size: 30)
                HStack(spacing: 18) {
                    stat(String(training.setsThisWeek), l.string("Sets"))
                    if let last = training.workoutsLastWeek { stat(String(last), l.string("Last week")) }
                }
                Spacer(minLength: 0)
                if training.state == .next {
                    Text(verbatim: training.workoutTitle ?? "").zoText(.caption).lineLimit(1)
                    Link(destination: DailyWidgetRoute.workout.url) {
                        DailyWidgetActionLabel(title: l.string("Start workout"), symbol: "play.fill", accent: entry.accent,
                                               language: entry.language, designTheme: entry.theme)
                    }
                }
            } else {
                Text(l.string("Open 01 to see your week.")).zoText(.caption).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(palette.ink)
        .containerBackground(for: .widget) { palette.background }
        .environment(\.locale, l.locale)
        .widgetURL(DailyWidgetRoute.today.url)
    }

    private func headline(_ training: DailyWidgetSnapshot.Training) -> String {
        if let planned = training.plannedThisWeek {
            return l.format("%1$lld of %2$lld workouts", .integer(training.workoutsThisWeek), .integer(planned))
        }
        return l.format("%1$lld workouts this week", .integer(training.workoutsThisWeek))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value).zoProofText(.label, size: 20, lineHeight: 24, weight: 700, tabular: true)
            Text(verbatim: label).zoText(.mini).foregroundStyle(palette.secondary)
        }
    }
}

/// The card is a brand object: Onyx in core, the theme's edition otherwise.
private struct ClubCardWidgetView: View {
    let entry: TrainingWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var l: AppLocalization { entry.localization }
    private var material: (background: Color, ink: Color) {
        if let palette = entry.theme.palette(dark: true), entry.theme != .core { return (palette.surface1, palette.inkPrimary) }
        return (Color(red: 0.051, green: 0.051, blue: 0.047), Color(red: 0.96, green: 0.95, blue: 0.92))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetMark(height: family == .systemSmall ? 16 : 20)
            Spacer(minLength: 0)
            if let card = entry.snapshot?.memberCard {
                Text(verbatim: family == .systemSmall ? (card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName) : card.holderName)
                    .zoProofText(.title, size: 16, lineHeight: 20, weight: 700).lineLimit(1)
                Text(verbatim: "No. " + card.number).zoProofText(.label, size: 14, lineHeight: 18, weight: 600, tabular: true)
                    .opacity(0.8)
                Text(verbatim: l.format(card.workouts == 1 ? "%1$lld workout" : "%1$lld workouts", .integer(card.workouts)))
                    .zoText(.mini).opacity(0.7)
            } else {
                Text(l.string("Join the Club in 01 to get your card.")).zoText(.caption).opacity(0.8)
            }
        }
        .foregroundStyle(material.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { material.background }
        .environment(\.locale, l.locale)
        .widgetURL(DailyWidgetRoute.today.url)
    }
}

private struct TrainingAccessoryView: View {
    let entry: TrainingWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var l: AppLocalization { entry.localization }

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let snapshot = entry.snapshot, snapshot.isCurrent(on: entry.date), let steps = snapshot.steps.value {
                let goal = Double(snapshot.stepGoal ?? 8_000)
                Gauge(value: min(steps, goal), in: 0 ... goal) {
                    Image(systemName: "shoeprints.fill")
                } currentValueLabel: {
                    Text(steps >= 1_000 ? String(format: "%.1fk", steps / 1_000) : String(Int(steps)))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetURL(DailyWidgetRoute.steps.url)
            } else {
                ZStack { AccessoryWidgetBackground(); WidgetMark(height: 14) }.widgetURL(DailyWidgetRoute.today.url)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) { WidgetMark(height: 10); Text(l.string("Today")).font(.caption2.weight(.semibold)) }
                Text(verbatim: line).font(.headline).lineLimit(1)
                if let training = entry.training {
                    Text(verbatim: l.format("%1$lld workouts this week", .integer(training.workoutsThisWeek))).font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(DailyWidgetRoute.today.url)
        default:
            Text(verbatim: line).widgetURL(DailyWidgetRoute.today.url)
        }
    }

    private var line: String {
        guard let training = entry.training else { return l.string("01") }
        switch training.state {
        case .next: return training.workoutTitle ?? l.string("Workout")
        case .restDay: return l.string("Rest day")
        case .inProgress: return l.string("Workout in progress")
        case .done: return l.string("Done today")
        }
    }
}

struct TodayTrainingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "01.training.today", provider: TrainingWidgetProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today")
            .description("Today's workout, or your rest day, at a glance.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WeekTrainingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "01.training.week", provider: TrainingWidgetProvider()) { WeekWidgetView(entry: $0) }
            .configurationDisplayName("This week")
            .description("Your week against your plan.")
            .supportedFamilies([.systemLarge])
    }
}

struct ClubCardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "01.club.card", provider: TrainingWidgetProvider()) { ClubCardWidgetView(entry: $0) }
            .configurationDisplayName("01 Club card")
            .description("Your member card: name, number and workouts.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TrainingLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "01.training.lock", provider: TrainingWidgetProvider()) { TrainingAccessoryView(entry: $0) }
            .configurationDisplayName("01")
            .description("Steps, or today's workout, on the Lock Screen.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Grouped so the main bundle stays within WidgetBundleBuilder's size.
struct TrainingWidgets: WidgetBundle {
    var body: some Widget {
        TodayTrainingWidget()
        WeekTrainingWidget()
        ClubCardWidget()
        TrainingLockScreenWidget()
    }
}
