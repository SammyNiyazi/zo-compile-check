import AppIntents
import SwiftUI
import WidgetKit

/// Gallery descriptions read display metadata only, even after daily
/// metrics expire. It never opens permissions or writes canonical data.
private enum DailyWidgetMetadata {
    static var language: AppLanguage { (try? FileDailyWidgetSnapshotStore().load())?.displayLanguage ?? .english }
    static var localization: AppLocalization { AppLocalization(language: language) }
    static var designTheme: ZOTheme { (try? FileDailyWidgetSnapshotStore().load())?.displayTheme ?? .core }

}

// System-owned App Intents metadata stays as extractable localized literals.
// Its late resolution can use the system/Siri locale rather than the app override.
extension DailyWidgetCalories: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Calories" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.both: "Eaten and burned", .eaten: "Eaten only", .burned: "Burned only"]
    }
}

enum WidgetWaterAmount: Int, AppEnum {
    case small = 250, medium = 500, large = 750
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Quick-add water" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.small: "250 ml", .medium: "500 ml", .large: "750 ml"]
    }
}

protocol DailyWidgetOptionsProviding { var options: DailyWidgetOptions { get } }

struct StepsWidgetConfiguration: WidgetConfigurationIntent, DailyWidgetOptionsProviding {
    static var title: LocalizedStringResource = "Steps"
    static var description = IntentDescription("Steps from Apple Health, with an optional shortcut to a walk.")
    @Parameter(title: "Show Start walk", default: true) var showsWalk: Bool
    var options: DailyWidgetOptions { var value = DailyWidgetOptions(); value.showsWalk = showsWalk; return value }
}

struct CaloriesWidgetConfiguration: WidgetConfigurationIntent, DailyWidgetOptionsProviding {
    static var title: LocalizedStringResource = "Calories"
    static var description = IntentDescription("Eaten and burned are always separate. Burned is active energy only.")
    @Parameter(title: "Show", default: .both) var calories: DailyWidgetCalories
    var options: DailyWidgetOptions { var value = DailyWidgetOptions(); value.calories = calories; return value }
}

struct WaterWidgetConfiguration: WidgetConfigurationIntent, DailyWidgetOptionsProviding {
    static var title: LocalizedStringResource = "Water"
    @Parameter(title: "Quick-add amount", default: .small) var amount: WidgetWaterAmount
    var options: DailyWidgetOptions { var value = DailyWidgetOptions(); value.waterAmount = amount.rawValue; return value }
}

struct TogetherWidgetConfiguration: WidgetConfigurationIntent, DailyWidgetOptionsProviding {
    static var title: LocalizedStringResource = "Together"
    static var description = IntentDescription("Choose what stays in view. If all metrics are off, Steps remains visible.")
    @Parameter(title: "Steps", default: true) var steps: Bool
    @Parameter(title: "Calories", default: true) var calories: Bool
    @Parameter(title: "Water", default: true) var water: Bool
    @Parameter(title: "Calories shown", default: .both) var calorieMode: DailyWidgetCalories
    @Parameter(title: "Quick-add amount", default: .small) var amount: WidgetWaterAmount
    @Parameter(title: "Show Start walk", default: true) var showsWalk: Bool
    var options: DailyWidgetOptions {
        var value = DailyWidgetOptions()
        value.calories = calorieMode
        value.waterAmount = amount.rawValue
        value.showsWalk = showsWalk
        // Remove in reverse order so an all-off system configuration keeps Steps.
        value.set(.water, included: water)
        value.set(.calories, included: calories)
        value.set(.steps, included: steps)
        return value
    }
}

struct DailyHomeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: DailyWidgetSnapshot?
    let options: DailyWidgetOptions
    let sharedStorageAvailable: Bool
    var accent: AccentPreference = .yellow
    var language: AppLanguage = .english
    var designTheme: ZOTheme = .core
    var water: DailyWidgetWaterState? = nil
    var waterFeedback: String? = nil
    var waterRequestID = UUID()
}

struct DailyHomeWidgetProvider<Configuration: WidgetConfigurationIntent & DailyWidgetOptionsProviding>: AppIntentTimelineProvider {
    typealias Intent = Configuration
    typealias Entry = DailyHomeWidgetEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil, options: DailyWidgetOptions(), sharedStorageAvailable: true, language: DailyWidgetMetadata.language, designTheme: DailyWidgetMetadata.designTheme)
    }

    func snapshot(for configuration: Configuration, in context: Context) async -> Entry {
        entry(configuration: configuration, at: .now)
    }

    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<Entry> {
        let now = Date.now
        let current = entry(configuration: configuration, at: now)
        let calendar = Calendar.autoupdatingCurrent
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        // Even when a refresh is deferred by iOS, yesterday's values expire at midnight.
        let expired = Entry(date: midnight, snapshot: nil, options: configuration.options,
                            sharedStorageAvailable: current.sharedStorageAvailable, accent: current.accent, language: current.language, designTheme: current.designTheme)
        var entries = [current]
        // Archive a settled entry too; an OS-deferred refresh must not leave an
        // expired Undo button on screen indefinitely.
        if let receipt = current.water?.undo {
            let expiry = receipt.date.addingTimeInterval(900)
            if expiry > now && expiry < midnight {
                entries.append(entry(configuration: configuration, at: expiry))
            }
        }
        entries.append(expired)
        return Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(900), midnight)))
    }

    private func entry(configuration: Configuration, at date: Date) -> Entry {
        let store = FileDailyWidgetSnapshotStore()
        let saved = try? store.load()
        let water = DailyWidgetWaterState(transaction: try? SharedHydrationStore().readTransaction(), at: date)
        let language = saved?.displayLanguage ?? .english
        // Water's existing projection replaces display facts but keeps transaction
        // semantics unchanged. Restore only metadata after that projection.
        let display = (water?.displaySnapshot(base: saved, at: date)
            ?? DailyWidgetWaterState.unavailableSnapshot(base: saved, at: date)).usingLanguage(language)
            .usingDesignTheme(saved?.displayTheme ?? .core)
        return Entry(date: date, snapshot: display,
                     options: configuration.options, sharedStorageAvailable: store.isAvailable,
                     accent: saved?.accent ?? .yellow, language: language, designTheme: saved?.displayTheme ?? .core,
                     water: water, waterFeedback: WidgetWaterFeedback.read(at: date))
    }
}

private struct DailyHomeWidgetView: View {
    let kind: DailyWidgetSnapshot.Kind
    let entry: DailyHomeWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    private var localization: AppLocalization { AppLocalization(language: entry.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !entry.sharedStorageAvailable {
                Text(localization.string("Setup pending in 01")).zoText(.mini).foregroundStyle(.secondary)
            }
            DailyWidgetFace(kind: kind, size: size, options: entry.options, snapshot: entry.snapshot,
                            waterHasUndo: entry.water?.undo != nil, accent: entry.accent, language: entry.language, designTheme: entry.designTheme) {
                waterActions
            } walkAction: {
                Link(destination: DailyWidgetRoute.walk.url) {
                    DailyWidgetActionLabel(title: localization.string("Start walk"), symbol: "figure.walk", accent: entry.accent, designTheme: entry.designTheme)
                }.accessibilityHint(localization.string("Opens walk setup in 01. Recording starts only after confirmation."))
            }
        }
        .containerBackground(for: .widget) { DailyWidgetPalette(dark: colorScheme == .dark, accent: entry.accent, designTheme: entry.designTheme).background }
        .environment(\.locale, localization.locale)
        .widgetURL(defaultRoute.url)
    }

    @ViewBuilder private var waterActions: some View {
        VStack(spacing: 5) {
            if let message = entry.waterFeedback {
                Text(localization.string(message)).zoText(.mini).foregroundStyle(.secondary).lineLimit(2)
            }
            if let water = entry.water {
                if let receipt = water.undo {
                    Text(localization.format("Added %1$lld ml", .integer(receipt.amount))).zoText(.mini).privacySensitive()
                    Button(intent: UndoWidgetWaterIntent(receipt: receipt)) {
                        Label(localization.string("Undo"), systemImage: "arrow.uturn.backward")
                            .zoProofText(.label, size: 13, lineHeight: 18, weight: 600).labelStyle(ZOIconLabelStyle()).frame(maxWidth: .infinity, minHeight: ZOSpace.hitTarget)
                    }.buttonStyle(.plain).accessibilityLabel(localization.format("Undo the last %1$lld millilitres", .integer(receipt.amount)))
                }
                if water.undo == nil || kind == .water {
                    waterButton(entry.options.validatedWaterAmount, water: water)
                    if size == .medium && kind == .water {
                        waterButton(entry.options.secondaryWaterAmount, water: water, prominent: false)
                    }
                }
            } else {
                Link(destination: DailyWidgetRoute.water.url) {
                    DailyWidgetActionLabel(title: localization.string("Open water"), symbol: "drop", prominent: false, accent: entry.accent, designTheme: entry.designTheme)
                }.accessibilityHint(localization.string("Open 01 to set up water logging."))
            }
        }
    }

    private func waterButton(_ amount: Int, water: DailyWidgetWaterState, prominent: Bool = true) -> some View {
        Button(intent: AddWidgetWaterIntent(amount: amount, revision: water.transaction.revision, dayStart: water.dayStart, requestID: entry.waterRequestID)) {
            DailyWidgetActionLabel(waterAmount: amount, prominent: prominent && !waterGoalReached, accent: entry.accent, language: entry.language, designTheme: entry.designTheme)
        }.buttonStyle(.plain).accessibilityLabel(localization.format("Log %1$lld millilitres of water", .integer(amount)))
    }

    private var waterGoalReached: Bool {
        WidgetMetricProgress(metric: entry.snapshot?.waterMilliliters,
                             target: entry.snapshot?.waterGoalMilliliters)?.reached == true
    }

    private var size: DailyWidgetSize {
        switch family { case .systemSmall: .small; case .systemLarge: .large; default: .medium }
    }
    private var defaultRoute: DailyWidgetRoute {
        switch kind { case .steps: .steps; case .calories: .calories; case .water: .water; case .together: .today }
    }
}

struct DailyStepsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DailyWidgetSnapshot.Kind.steps.rawValue, intent: StepsWidgetConfiguration.self,
                               provider: DailyHomeWidgetProvider<StepsWidgetConfiguration>()) {
            DailyHomeWidgetView(kind: .steps, entry: $0)
        }
        .configurationDisplayName(Text(verbatim: DailyWidgetMetadata.localization.string("Steps")))
        .description(Text(verbatim: DailyWidgetMetadata.localization.string("Today's steps from Apple Health.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DailyCaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DailyWidgetSnapshot.Kind.calories.rawValue, intent: CaloriesWidgetConfiguration.self,
                               provider: DailyHomeWidgetProvider<CaloriesWidgetConfiguration>()) {
            DailyHomeWidgetView(kind: .calories, entry: $0)
        }
        .configurationDisplayName(Text(verbatim: DailyWidgetMetadata.localization.string("Calories")))
        .description(Text(verbatim: DailyWidgetMetadata.localization.string("Eaten and burned, always labelled and never combined.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DailyWaterWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DailyWidgetSnapshot.Kind.water.rawValue, intent: WaterWidgetConfiguration.self,
                               provider: DailyHomeWidgetProvider<WaterWidgetConfiguration>()) {
            DailyHomeWidgetView(kind: .water, entry: $0)
        }
        .configurationDisplayName(Text(verbatim: DailyWidgetMetadata.localization.string("Water")))
        .description(Text(verbatim: DailyWidgetMetadata.localization.string("Water logged in 01, against your daily goal.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DailyTogetherWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DailyWidgetSnapshot.Kind.together.rawValue, intent: TogetherWidgetConfiguration.self,
                               provider: DailyHomeWidgetProvider<TogetherWidgetConfiguration>()) {
            DailyHomeWidgetView(kind: .together, entry: $0)
        }
        .configurationDisplayName(Text(verbatim: DailyWidgetMetadata.localization.string("Together")))
        .description(Text(verbatim: DailyWidgetMetadata.localization.string("Steps, calories and water. Choose which metrics stay in view.")))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

