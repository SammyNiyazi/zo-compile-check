import SwiftUI
import UIKit

/// User-entered targets. No calorie target is made. The water field may be
/// pre-filled from step 7's weight (Sammy, 9 Oct: 30 ml per kg, 1.5 to 3 L),
/// shown as a starting point the person edits; nothing is saved until Continue.
struct ZeroOneSetupDailyGoalsView: View {
    let goals: DailyGoalsRepository
    let hydration: HydrationViewModel
    let onContinue: () -> Void
    @State private var original: DailyGoals
    @State private var originalWater: Int
    @State private var steps: String
    @State private var water: String
    @State private var waterIsSuggested: Bool
    @State private var saveMessage: String?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    init(goals: DailyGoalsRepository, hydration: HydrationViewModel, bodyKilograms: Double? = nil,
         onContinue: @escaping () -> Void) {
        self.goals = goals
        self.hydration = hydration
        self.onContinue = onContinue
        _original = State(initialValue: goals.value)
        _originalWater = State(initialValue: hydration.state.goalMilliliters)
        _steps = State(initialValue: goals.value.steps.map(String.init) ?? "")
        // Only an untouched default is replaced; a target the person already chose stays.
        let suggestion = hydration.state.goalMilliliters == ZeroOneSetupWaterGoal.untouchedDefault
            ? bodyKilograms.flatMap(ZeroOneSetupWaterGoal.suggestedMilliliters(bodyKilograms:)) : nil
        _waterIsSuggested = State(initialValue: suggestion != nil)
        _water = State(initialValue: String(Double(suggestion ?? hydration.state.goalMilliliters) / 1_000))
    }

    private var proposedGoals: DailyGoals? {
        var draft = DailyGoalsDraft(value: original)
        draft.steps = steps
        return try? draft.validated()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            Text("Choose the daily targets for your rings. You can change them later.")
                .zoText(.body).foregroundStyle(theme.textSecondary)
            VStack(spacing: 0) {
                goalRow("Steps per day", text: $steps, unit: nil, keyboard: .numberPad)
                Divider().overlay(theme.strokeSubtle)
                goalRow("Water per day", text: $water, unit: "L", keyboard: .decimalPad)
            }
            .zoThemeCardSurface()
            if waterIsSuggested {
                Text("Water starts at 30 ml per kg of your weight. Change it to suit you. If you have a heart or kidney condition, follow your doctor.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                Text("Leave steps blank to hide its target. Your water target is a choice, not a recommendation.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            if let saveMessage {
                ZOBanner(message: localization.string(saveMessage), symbol: "info.circle")
            } else if !goals.isAvailable || !hydration.canConfirmQuickWaterSave {
                ZOBanner(message: localization.string("Your targets could not be loaded. Try again."), symbol: "info.circle")
            } else if ZeroOneSetupWaterGoal.milliliters(water) == nil {
                Text("Enter a positive water target in litres, with up to three decimal places.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            if !goals.isAvailable || !hydration.canConfirmQuickWaterSave || saveMessage != nil {
                Button("Reload", action: reload).buttonStyle(ZOButtonStyle(.quiet))
            }
            Button("Continue", action: save)
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(proposedGoals == nil || ZeroOneSetupWaterGoal.milliliters(water) == nil
                    || !goals.isAvailable || !hydration.canConfirmQuickWaterSave)
        }
    }

    private func goalRow(_ title: LocalizedStringKey, text: Binding<String>, unit: String?, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(title).zoText(.caption).foregroundStyle(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                TextField("Optional", text: text)
                    .keyboardType(keyboard).zoText(.metric).accessibilityLabel(Text(title))
                if let unit { Text(verbatim: unit).zoText(.label).foregroundStyle(theme.textSecondary) }
            }
        }
        .padding(ZOSpace.cardPadding)
    }

    private func save() {
        guard let proposed = proposedGoals, let milliliters = ZeroOneSetupWaterGoal.milliliters(water) else { return }
        guard goals.save(proposed, replacing: original) else {
            saveMessage = goals.errorMessage
            return
        }
        original = proposed
        guard hydration.setWaterGoal(milliliters: milliliters, replacing: originalWater) else {
            // Two existing stores, so a partial save must not masquerade as failure of both.
            saveMessage = "Your step target was saved. Reload to check your water target before continuing."
            return
        }
        originalWater = milliliters
        saveMessage = nil
        onContinue()
    }

    private func reload() {
        goals.reload()
        hydration.refreshForCurrentDay()
        guard goals.isAvailable, hydration.canConfirmQuickWaterSave else {
            saveMessage = "Your targets could not be loaded. Try again."
            return
        }
        original = goals.value
        originalWater = hydration.state.goalMilliliters
        steps = original.steps.map(String.init) ?? ""
        water = String(Double(originalWater) / 1_000)
        waterIsSuggested = false
        saveMessage = nil
    }
}

enum ZeroOneSetupWaterGoal {
    /// The hydration store's first-run goal (HydrationState default).
    static let untouchedDefault = 2_500

    /// 30 ml per kg, to the nearest 250 ml, kept between 1.5 and 3 L.
    static func suggestedMilliliters(bodyKilograms: Double) -> Int? {
        guard bodyKilograms.isFinite, (20 ... 400).contains(bodyKilograms) else { return nil }
        let rounded = Int((bodyKilograms * 30 / 250).rounded()) * 250
        return min(3_000, max(1_500, rounded))
    }

    static func milliliters(_ liters: String) -> Int? {
        guard let decimal = BodyWeightInput.number(liters) else { return nil }
        let value = NSDecimalNumber(decimal: decimal * 1_000).doubleValue
        guard value.isFinite, value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
}
