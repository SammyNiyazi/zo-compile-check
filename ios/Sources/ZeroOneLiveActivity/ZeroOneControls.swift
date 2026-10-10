import AppIntents
import SwiftUI
import WidgetKit

/// Study 36 controls (iOS 18+): Control Center, the Lock Screen slots and the
/// Action button. Workout opens 01 on today's workout; Log water adds 250 ml
/// without opening 01. Walk waits for the 01.jog custom symbol (controls only
/// take SF Symbols), and Next move waits for the workout's own intents.
@available(iOS 18.0, *)
struct OpenWorkoutControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open today's workout in 01"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(DailyWidgetRoute.workout.url))
    }
}

@available(iOS 18.0, *)
struct AddWaterControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Add 250 ml of water in 01"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // No displayed revision exists in a control, so this is a plain add to today.
        _ = try SharedHydrationStore().add(250, at: .now, calendar: .autoupdatingCurrent)
        for kind in DailyWidgetSnapshot.Kind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue) }
        return .result()
    }
}

@available(iOS 18.0, *)
struct WorkoutControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.the01.control.workout") {
            ControlWidgetButton(action: OpenWorkoutControlIntent()) {
                Label("Workout", systemImage: "dumbbell.fill")
            }
        }
        .displayName("Workout")
        .description("Opens today's workout in 01.")
    }
}

@available(iOS 18.0, *)
struct WaterControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.the01.control.water") {
            ControlWidgetButton(action: AddWaterControlIntent()) {
                Label("Log water", systemImage: "drop.fill")
            }
        }
        .displayName("Log water")
        .description("Adds 250 ml to today's water.")
    }
}
