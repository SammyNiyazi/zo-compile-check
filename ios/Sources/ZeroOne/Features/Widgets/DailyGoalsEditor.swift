import SwiftUI

struct DailyGoalsEditor: View {
    let repository: DailyGoalsRepository
    let hydration: HydrationViewModel?
    let onSaved: (() -> Void)?
    @State private var draft: DailyGoalsDraft
    @State private var original: DailyGoals
    @State private var saved = false
    @State private var water: String
    @State private var originalWater: Int?
    @State private var waterSaveError: String?
    @Environment(\.zeroOneTheme) private var theme

    init(repository: DailyGoalsRepository, hydration: HydrationViewModel? = nil, onSaved: (() -> Void)? = nil) {
        self.repository = repository
        self.hydration = hydration
        _originalWater = State(initialValue: hydration?.state.goalMilliliters)
        _water = State(initialValue: hydration.map { String(Double($0.state.goalMilliliters) / 1_000) } ?? "")
        self.onSaved = onSaved
        // Intentional editing draft. It is not a mirror of live parent state.
        _draft = State(initialValue: DailyGoalsDraft(value: repository.value))
        _original = State(initialValue: repository.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your daily targets").zoText(.title)
            Text("Choose your targets for the app and widgets. Leave steps or food energy blank to hide that target bar.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Steps per day").zoText(.label)
                TextField("Optional", text: $draft.steps).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Daily step target")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Food energy per day · kcal").zoText(.label)
                TextField("Optional", text: $draft.foodKilocalories).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Daily food calorie target")
            }
            if hydration != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Water per day").zoText(.label)
                    HStack {
                        TextField("Water per day", text: $water).keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Water per day")
                        Text(verbatim: "L").zoText(.label)
                    }
                }
            }
            Text("01 does not recommend a calorie target here. Active calories burned never change your food target.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            if let waterSaveError {
                Text(LocalizedStringKey(waterSaveError)).zoText(.caption).foregroundStyle(theme.textPrimary)
            } else if let error = repository.errorMessage {
                Text(error).zoText(.caption).foregroundStyle(theme.textPrimary)
            } else if let hydration, !hydration.canConfirmQuickWaterSave {
                Text("Your targets could not be loaded. Try again.").zoText(.caption).foregroundStyle(theme.textPrimary)
            } else if (try? draft.validated()) == nil {
                Text(DailyGoalsError.invalidNumber.localizedDescription).zoText(.caption).foregroundStyle(theme.textPrimary)
            } else if hydration != nil && ZeroOneSetupWaterGoal.milliliters(water) == nil {
                Text("Enter a positive water target in litres, with up to three decimal places.")
                    .zoText(.caption).foregroundStyle(theme.textPrimary)
            } else if saved {
                Label("Targets saved", systemImage: "checkmark.circle").zoText(.caption).labelStyle(ZOIconLabelStyle())
            }
            HStack {
                Button("Reload") {
                    repository.reload()
                    hydration?.refreshForCurrentDay()
                    if repository.isAvailable {
                        original = repository.value; draft = .init(value: repository.value); saved = false
                    }
                    if let hydration, hydration.canConfirmQuickWaterSave {
                        originalWater = hydration.state.goalMilliliters
                        water = String(Double(hydration.state.goalMilliliters) / 1_000)
                        waterSaveError = nil
                    }
                }.frame(minHeight: 44)
                Spacer()
                Button {
                    guard isValid, let proposed = try? draft.validated() else { return }
                    let target = ZeroOneSetupWaterGoal.milliliters(water)
                    saved = false
                    guard repository.save(proposed, replacing: original) else { return }
                    original = proposed
                    draft = .init(value: proposed)
                    if let hydration {
                        guard let expected = originalWater, let target,
                              hydration.setWaterGoal(milliliters: target, replacing: expected) else {
                            waterSaveError = "Your other targets were saved. Reload to check your water target before continuing."
                            return
                        }
                        originalWater = target
                    }
                    waterSaveError = nil
                    saved = true
                    onSaved?()
                } label: {
                    Text(onSaved == nil ? LocalizedStringKey("Save targets") : LocalizedStringKey("Continue"))
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(!repository.isAvailable || !isValid || (onSaved == nil && (try? draft.validated()) == original && (hydration == nil || ZeroOneSetupWaterGoal.milliliters(water) == originalWater)))
            }
        }
        .padding(18).background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: draft) { _, draft in if draft != DailyGoalsDraft(value: original) { saved = false } }
        .onChange(of: water) { _, _ in saved = false }
    }

    private var isValid: Bool {
        (try? draft.validated()) != nil
            && (hydration == nil || (hydration?.canConfirmQuickWaterSave == true && originalWater != nil && ZeroOneSetupWaterGoal.milliliters(water) != nil))
    }
}
