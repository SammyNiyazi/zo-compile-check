import SwiftUI

/// Navigation only. Actual transfer screens retain their existing previews and guards.
struct ProfileSettingsImportView: View {
    let workoutHistoryImport: WorkoutHistoryImportCoordinator?
    let onImportedWorkoutHistory: (@MainActor ([WorkoutHistoryEntry]) throws -> Void)?
    let mealRecordImport: FoodBodyWeightImportCoordinator?
    let bodyWeightRecordImport: FoodBodyWeightImportCoordinator?
    let outdoorHistoryTransfer: OutdoorHistoryTransferCoordinator?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text("From an 01 export. Review each kind before anything changes.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                VStack(spacing: 0) {
                    if let workoutHistoryImport, let onImportedWorkoutHistory {
                    NavigationLink {
                        LocalWorkoutHistoryImportView(coordinator: workoutHistoryImport,
                                                     didConfirm: onImportedWorkoutHistory)
                    } label: {
                        importRow("Workout history", symbol: "dumbbell")
                    }
                }
                if let mealRecordImport {
                    NavigationLink {
                        LocalFoodBodyWeightImportView(coordinator: mealRecordImport)
                    } label: { importRow("Meals", symbol: "fork.knife") }
                }
                if let bodyWeightRecordImport {
                    NavigationLink {
                        LocalFoodBodyWeightImportView(coordinator: bodyWeightRecordImport)
                    } label: { importRow("Body-weight readings", symbol: "scalemass") }
                }
                if let outdoorHistoryTransfer {
                    NavigationLink {
                        LocalOutdoorHistoryTransferView(coordinator: outdoorHistoryTransfer)
                    } label: { importRow("Walks and runs", symbol: "01.jog") }
                }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, ZOSpace.l)
                .background(theme.surfacePrimary, in: .rect(cornerRadius: ZORadius.card))
                Text("Workouts, meals and body weight use an 01 JSON export. Complete walks and runs use their separate outdoor-history file, with route review. ZIP, water and settings cannot be restored.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(ZOSpace.l)
        }
        .navigationTitle("Import")
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
        .background(theme.backgroundPrimary)
    }

    private func importRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: ZOSpace.m) {
            ZOAppIcon(symbol, size: 16)
                .frame(width: 32, height: 32)
                .background(theme.surfaceSecondary, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(verbatim: localization.string(title))
                .zoText(.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .zoIcon(16)
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, ZOSpace.s)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
