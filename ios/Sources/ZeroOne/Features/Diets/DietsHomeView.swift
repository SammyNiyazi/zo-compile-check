import SwiftUI
import AVFoundation
import UIKit

struct DietsHomeView: View {
    @Bindable var nutrition: NutritionRepository
    @Bindable var hydration: HydrationViewModel
    var reviewDraft: NutritionEntryDraft?
    @Binding var focusHydration: Bool
    let onOpenProfile: () -> Void
    var showsHeader = true
    var onOpenTrackers: (() -> Void)? = nil
    var isActive = true
    /// Optional actual tracker content supplied by the owner of the tracker repository.
    var trackerSummary: (() -> AnyView)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var isPresentingEntry = false
    @State private var editingEntryID: UUID?
    @State private var draft = NutritionEntryDraft()
    @State private var validationMessage: String?
    @State private var didApplyReviewDraft = false
    @State private var waterUndoGroup: HydrationQuickLogGroup?
    @State private var waterFeedback: String?
    @State private var showsFoodCamera = false
    @State private var pendingFoodPhoto: Data?
    @State private var foodPhoto: UIImage?
    @State private var foodPhotoMessage: String?
    @State private var foodCaptureFailed = false
    @State private var canOpenCameraSettings = false
    @State private var isRequestingFoodCamera = false
    @State private var foodCameraRequest: Task<Void, Never>?
    @State private var addedEntryForUndo: NutritionEntry?
    @State private var mealFeedback: String?
    @State private var mealFeedbackTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsHeader { header }

                        if nutrition.availability == .unavailable {
                            unavailableState
                        } else {
                            dailyOverview
                        }

                        if hydration.canConfirmQuickWaterSave {
                            hydrationSurface
                                .id("hydration")
                        } else {
                            hydrationUnavailableState
                                .id("hydration")
                        }

                        if nutrition.availability != .unavailable {
                            entriesSection
                            DisclosureGroup("About food logging") {
                                Text("Meals are entered manually. Your logged values stay on this iPhone.")
                                    .zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, ZOSpace.l)
                        }

                        if let trackerSummary {
                            trackerSummary()
                                .padding(.top, ZOSpace.l)
                        }
                        if let onOpenTrackers {
                            Button(action: onOpenTrackers) {
                                HStack(spacing: ZOSpace.m) {
                                    Text("Trackers")
                                        .zoText(.section)
                                    Spacer(minLength: ZOSpace.s)
                                    Image(systemName: "chevron.right")
                                        .zoIcon(ZOIcon.inline)
                                        .foregroundStyle(theme.textTertiary)
                                        .accessibilityHidden(true)
                                }
                                .foregroundStyle(theme.textPrimary)
                                .padding(ZOSpace.l)
                                .frame(minHeight: ZOSpace.rowMinHeight)
                                .zoThemeCardSurface()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(localization.string("Open trackers")))
                            .accessibilityIdentifier("diets.trackers.open")
                            .padding(.top, ZOSpace.l)
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, ZOSpace.screenMargin)
                    .padding(.top, ZOSpace.s)
                    .padding(.bottom, ZOSpace.x4)
                }
                .scrollIndicators(.hidden)
                .task(id: focusHydration) {
                    guard focusHydration else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        scrollProxy.scrollTo("hydration", anchor: .top)
                    }
                    focusHydration = false
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let mealFeedback {
                ZOToast(message: localization.string(mealFeedback),
                    actionTitle: addedEntryForUndo == nil ? nil : localization.string("Undo"),
                    action: addedEntryForUndo == nil ? nil : undoAddedEntry)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.s)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("diets.food.feedback")
            }
        }
        .sheet(isPresented: $isPresentingEntry, onDismiss: { foodPhoto = nil }) {
            Group {
                NutritionEntrySheet(
                    draft: $draft,
                    validationMessage: validationMessage,
                    isEditing: editingEntryID != nil,
                    foodPhoto: foodPhoto,
                    onCancel: dismissEditor,
                    onSave: saveDraft
                )
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.surfacePrimary)
            }
            .zoSheet(theme)
        }
        .fullScreenCover(isPresented: $showsFoodCamera, onDismiss: reviewFoodPhoto) {
            InAppStillCamera { result in
                switch result {
                case .captured(let data): pendingFoodPhoto = data
                case .cancelled: pendingFoodPhoto = nil
                case .failed:
                    pendingFoodPhoto = nil
                    foodCaptureFailed = true
                }
                showsFoodCamera = false
            }
            .ignoresSafeArea()
        }
        .alert("Food photo", isPresented: Binding(
            get: { foodPhotoMessage != nil }, set: { if !$0 { foodPhotoMessage = nil } }
        )) {
            if canOpenCameraSettings {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { foodPhotoMessage = nil }
        } message: {
            Text(localization.string(foodPhotoMessage ?? ""))
        }
        .onDisappear(perform: cancelTransientWork)
        .onChange(of: isActive) { _, active in
            if !active { cancelTransientWork() }
        }
        .onAppear {
            guard !didApplyReviewDraft, let reviewDraft else { return }
            didApplyReviewDraft = true
            draft = reviewDraft
            isPresentingEntry = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ZOSpace.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diets")
                    .zoThemeHeading(.display, context: .headRowDisplay)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month()))
                    .zoText(.body)

                    .foregroundStyle(theme.textSecondary)

            }

            Spacer(minLength: ZOSpace.s)
            ZeroOneProfileButton(action: onOpenProfile)
        }
        .padding(.bottom, 20)
    }

    private var dailyOverview: some View {
        let macros = nutrition.macroSummary()
        return VStack(alignment: .leading, spacing: 14) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: ZOSpace.l) {
                        VStack(alignment: .leading, spacing: ZOSpace.xs) {
                            calorieNumber
                            calorieUnit
                        }
                        macroSummary(macros)
                    }
                } else {
                    HStack(alignment: .center, spacing: ZOSpace.l) {
                        calorieRing
                        macroSummary(macros)
                    }
                }
            }
            Text("Totals include only the meals and values you logged.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)

            DisclosureGroup("Nutrition details") {
                if nutrition.availability == .available {
                    let quality = NutritionLoggedEvidenceSummary(entries: todaysEntries)
                    Text(localization.format("Unspecified source types: %1$lld. Estimated values: %2$lld. Reported label, database or recipe sources: %3$lld.",
                        .integer(quality.unknownOriginCount), .integer(quality.estimatedValueCount), .integer(quality.reportedSourceCount)))
                        .zoText(.caption)
                    Text("Reported sources and measured amounts are not independently verified. A complete log does not establish personal calorie needs.")
                        .zoText(.caption)
                }
                Text("Totals include only the meals and values you logged.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .zoText(.body)
            .foregroundStyle(theme.textSecondary)

        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .padding(.bottom, ZOSpace.m)
    }

    private var calorieRing: some View {
        ZStack {
            Circle().stroke(theme.surfaceTertiary, lineWidth: 12)
            // No target is supplied by this repository. The open ring never
            // guesses a personal target or a percent-complete intake.
            VStack(spacing: 2) {
                calorieNumber
                calorieUnit
            }
        }
        .padding(6)
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localization.format("%1$lld kcal logged", .integer(totals.calories))))
    }

    private func macroSummary(_ macros: NutritionLoggedMacroSummary?) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            macroValue("Protein", value: macros?.protein, color: ZOColor.Data.protein)
            macroValue("Carbs", value: macros?.carbohydrates, color: ZOColor.Data.carbs)
            macroValue("Fat", value: macros?.fat, color: ZOColor.Data.fat)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calorieNumber: some View {
        Text(totals.calories.formatted())
            .zoThemeText(.metric)

            .foregroundStyle(theme.textPrimary)
            .contentTransition(.numericText(value: Double(totals.calories)))
    }

    private var calorieUnit: some View {
        Text("kcal logged")
            .zoText(.caption)

            .foregroundStyle(theme.textSecondary)
    }

    private var hydrationSurface: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: ZOSpace.l) {
                        hydrationSummary
                        hydrationAddButton
                    }
                } else {
                    HStack(spacing: ZOSpace.l) {
                        hydrationSummary
                        Spacer(minLength: ZOSpace.s)
                        hydrationAddButton
                    }
                }
            }

            DietsWaterGlasses(state: hydration.state)
            Text("Glasses show 250 ml portions. Undo removes your recent additions together.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let waterFeedback {
                Text(waterFeedback)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)

                if let waterUndoGroup {
                    Button("Undo \(waterUndoGroup.addedMilliliters) ml") {
                        if hydration.undoQuickWaterLog(waterUndoGroup) {
                            self.waterUndoGroup = nil
                            self.waterFeedback = "\(waterUndoGroup.addedMilliliters) ml undone."
                        } else {
                            self.waterUndoGroup = nil
                            self.waterFeedback = "Undo could not be confirmed. Check your water total."
                        }
                    }
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .accessibilityIdentifier("diets.water.undo")
                }
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityElement(children: .contain)
    }

    private var hydrationSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
                Text("Water")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)

                Text(hydrationProgressText)
                    .zoThemeText(.metric)
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText(value: Double(hydration.state.currentMilliliters)))

                Text(hydrationRemainingText)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
        }
    }

    private var hydrationAddButton: some View {
        Button {
            if let receipt = hydration.addWaterFromQuickAction(milliliters: 250) {
                waterUndoGroup = waterUndoGroup?.appending(receipt) ?? HydrationQuickLogGroup(receipt)
                waterFeedback = "+250 ml saved. \(receipt.savedMilliliters) ml today."
            } else {
                waterFeedback = "Water save could not be confirmed. Check your total before trying again."
            }
        } label: {
            Label("Glass", systemImage: "plus").labelStyle(ZOIconLabelStyle())
        }
        .buttonStyle(ZOButtonStyle(.secondary))
        .sensoryFeedback(.increase, trigger: hydration.state.currentMilliliters) { old, new in
            new > old
        }
        .accessibilityLabel("Add 250 milliliters of water")
        .accessibilityHint("Saves to the same hydration total shown on Today.")
        .accessibilityIdentifier("diets.water.add")
    }

    private var hydrationUnavailableState: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("Hydration unavailable")
                .zoText(.caption)
                .foregroundStyle(theme.warningPrimary)
            Text("Water data cannot be saved on this device right now.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ZOSpace.l)
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meals").zoText(.section).accessibilityAddTraits(.isHeader)
                Spacer(minLength: ZOSpace.s)
                Text(localization.format("%1$lld logged", .integer(todaysEntries.count)))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }

            if todaysEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing logged yet.")
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)

                    Text("Log your first meal when you're ready.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, ZOSpace.m)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 0) {
                    ForEach(todaysEntries) { entry in
                        entryRow(entry)

                        if entry.id != todaysEntries.last?.id {
                            Rectangle()
                                .fill(theme.strokeSubtle)
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, ZOSpace.l)
                .zoThemeCardSurface()
            }

            Button("Log a meal", action: beginAddingEntry)
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityHint("Opens a local manual nutrition entry form.")
                .accessibilityIdentifier("diets.food.add")
            Button(action: requestFoodCamera) {
                Label("Take food photo", systemImage: "camera")
            }
            .buttonStyle(ZOButtonStyle(.secondary, isLoading: isRequestingFoodCamera))
            .disabled(isRequestingFoodCamera)
            .accessibilityIdentifier("diets.food.takePhoto")
            .accessibilityHint("Opens the camera, then lets you review a picture and enter meal values. Automatic nutrition estimates are not connected.")
        }
        .padding(.top, ZOSpace.xl)
    }

    private func entryRow(_ entry: NutritionEntry) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    entryDescription(entry)

                    HStack(spacing: ZOSpace.m) {
                        calorieValue(entry)
                        Spacer(minLength: ZOSpace.s)
                        entryMenu(entry)
                    }
                }
            } else {
                HStack(spacing: ZOSpace.m) {
                    entryDescription(entry)
                    Spacer(minLength: ZOSpace.s)
                    calorieValue(entry)
                    entryMenu(entry)
                }
            }
        }
        .padding(.vertical, ZOSpace.m)
    }

    private func entryDescription(_ entry: NutritionEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.title)
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            Text(localization.string(entry.foodEvidence?.origin.title ?? "Source type not recorded"))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(entrySummary(entry))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func calorieValue(_ entry: NutritionEntry) -> some View {
        Text(localization.format("%1$lld kcal", .integer(entry.calories)))
            .zoText(.label)
            .foregroundStyle(theme.textPrimary)
            .accessibilityLabel("\(entry.calories) calories")
    }

    private func entryMenu(_ entry: NutritionEntry) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") {
                beginEditing(entry)
            }
            Button("Remove", systemImage: "trash", role: .destructive) {
                if nutrition.remove(id: entry.id) {
                    if addedEntryForUndo?.id == entry.id { addedEntryForUndo = nil }
                } else {
                    showMealFeedback("Removal could not be confirmed. Check your meals before trying again.")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoIcon(ZOIcon.inline)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Options for \(entry.title)")
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Local data unavailable")
                .zoText(.caption)

                .foregroundStyle(theme.warningPrimary)

            Text("Meals couldn't be opened")
                .zoThemeText(.display)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Local nutrition data cannot be opened right now. Workout and other offline destinations remain available.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .padding(.top, ZOSpace.xl)
    }

    private func macroValue(_ label: String, value: NutritionMacroTotal?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ZOColor.resolved(color, in: theme.colorScheme))
                    .frame(width: 10, height: 10).accessibilityHidden(true)
                Text(localization.string(label)).zoText(.label)
                Spacer(minLength: 0)
            Group {
                if let grams = value?.knownSubtotalGrams {
                    Text(localization.format("%1$@ g", .text(self.grams(grams))))
                } else if value?.coverage == .notRecorded {
                    Text("Not recorded")
                } else {
                    Text("Unavailable")
                }
            }
            .zoText(.caption)
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            }
            if value?.coverage == .partial {
                Text("Some meals have no value recorded.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totals: NutritionDailyTotals {
        nutrition.totals()
    }

    private var todaysEntries: [NutritionEntry] {
        nutrition.entries()
    }

    private var hydrationProgressText: String {
        liters(hydration.state.currentMilliliters)
            + " / "
            + liters(hydration.state.goalMilliliters)
            + " L"
    }

    private var hydrationRemainingText: String {
        liters(hydration.state.remainingMilliliters) + " L left"
    }

    private func liters(_ milliliters: Int) -> String {
        (Double(milliliters) / 1_000).formatted(
            .number.precision(.fractionLength(1 ... 2))
        )
    }

    private func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    private func entrySummary(_ entry: NutritionEntry) -> String {
        let macros = [
            entry.proteinGrams.map { "P \(grams($0)) g" },
            entry.carbohydrateGrams.map { "C \(grams($0)) g" },
            entry.fatGrams.map { "F \(grams($0)) g" }
        ].compactMap { $0 }
        return macros.isEmpty ? "Macros not added" : macros.joined(separator: "  ")
    }

    private func beginAddingEntry() {
        foodPhoto = nil
        editingEntryID = nil
        draft = NutritionEntryDraft()
        validationMessage = nil
        isPresentingEntry = true
    }

    private func beginEditing(_ entry: NutritionEntry) {
        foodPhoto = nil
        editingEntryID = entry.id
        draft = NutritionEntryDraft(entry: entry)
        validationMessage = nil
        isPresentingEntry = true
    }

    private func dismissEditor() {
        isPresentingEntry = false
        validationMessage = nil
        foodPhoto = nil
    }

    private func requestFoodCamera() {
        guard isActive, !isRequestingFoodCamera, !isPresentingEntry else { return }
        canOpenCameraSettings = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            foodPhotoMessage = "This device has no available camera. You can still log a meal manually."
            return
        }
        isRequestingFoodCamera = true
        foodCameraRequest = Task { @MainActor in
            defer { isRequestingFoodCamera = false }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            case .denied, .restricted: allowed = false
            @unknown default: allowed = false
            }
            guard !Task.isCancelled, isActive else { return }
            guard allowed else {
                canOpenCameraSettings = AVCaptureDevice.authorizationStatus(for: .video) == .denied
                foodPhotoMessage = "Camera access is off. You can change access in Settings or log a meal manually."
                return
            }
            pendingFoodPhoto = nil
            foodPhoto = nil
            foodCaptureFailed = false
            showsFoodCamera = true
        }
    }

    private func reviewFoodPhoto() {
        guard isActive else {
            pendingFoodPhoto = nil
            foodCaptureFailed = false
            return
        }
        if foodCaptureFailed {
            foodCaptureFailed = false
            foodPhotoMessage = "The picture could not be prepared. Nothing was saved."
            return
        }
        guard let data = pendingFoodPhoto else { return }
        pendingFoodPhoto = nil
        guard let image = UIImage(data: data) else {
            foodPhotoMessage = "The picture could not be prepared. Nothing was saved."
            return
        }
        foodPhoto = image
        editingEntryID = nil
        // A picture never supplies guessed calories or macros.
        draft = NutritionEntryDraft()
        validationMessage = nil
        isPresentingEntry = true
    }

    private func saveDraft() {
        do {
            if let editingEntryID {
                try nutrition.update(id: editingEntryID, with: draft)
            } else {
                let added = try nutrition.add(draft)
                showMealFeedback(localization.format("%1$@ added", .text(added.title)), undoEntry: added)
            }
            dismissEditor()
        } catch let error as NutritionEntryValidationError {
            validationMessage = error.localizedDescription
        } catch {
            validationMessage = "This entry could not be saved locally."
        }
    }

    private func cancelTransientWork() {
        foodCameraRequest?.cancel()
        mealFeedbackTask?.cancel()
        addedEntryForUndo = nil
        mealFeedback = nil
    }

    private func showMealFeedback(_ message: String, undoEntry: NutritionEntry? = nil) {
        mealFeedbackTask?.cancel()
        addedEntryForUndo = undoEntry
        mealFeedback = message
        UIAccessibility.post(notification: .announcement, argument: localization.string(message))
        mealFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            addedEntryForUndo = nil
            mealFeedback = nil
        }
    }

    private func undoAddedEntry() {
        guard let entry = addedEntryForUndo else { return }
        addedEntryForUndo = nil
        // An edited or replaced entry is no longer the addition this toast owns.
        guard DietsPresentation.canUndoAddition(entry, current: nutrition.entries(on: entry.loggedAt)) else {
            showMealFeedback("This meal changed. Open it to review your saved entry.")
            return
        }
        if nutrition.remove(id: entry.id) {
            showMealFeedback("Meal undone.")
        } else {
            showMealFeedback("Undo could not be confirmed. Check your meals.")
        }
    }
}

private struct DietsWaterGlasses: View {
    let state: HydrationState
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        Group {
            if let glasses = DietsPresentation.waterGlasses(current: state.currentMilliliters, goal: state.goalMilliliters) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0, maximum: 26), spacing: 4), count: min(10, glasses.count)), alignment: .leading, spacing: ZOSpace.s) {
                    ForEach(glasses) { glass in
                        GeometryReader { geometry in
                            DietsGlassShape().fill(theme.surfaceTertiary)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(theme.textPrimary)
                                        .frame(height: geometry.size.height * glass.fraction)
                                }
                                .clipShape(DietsGlassShape())
                        }
                        .aspectRatio(16.0 / 22.0, contentMode: .fit)
                    }
                }
            } else {
                ZOProgress(progress: state.progress)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localization.format("Water, %1$lld of %2$lld milliliters", .integer(state.currentMilliliters), .integer(state.goalMilliliters))))
    }
}

/// Native path from proof's 16 × 22 water-glass SVG. It is a display of the
/// actual aggregate water amount, never an individual stored drink receipt.
private struct DietsGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 2))
        path.addLine(to: CGPoint(x: 14, y: 2))
        path.addLine(to: CGPoint(x: 12.4, y: 19.2))
        path.addCurve(to: CGPoint(x: 10.4, y: 21), control1: CGPoint(x: 12.30, y: 20.22), control2: CGPoint(x: 11.43, y: 21))
        path.addLine(to: CGPoint(x: 5.6, y: 21))
        path.addCurve(to: CGPoint(x: 3.6, y: 19.2), control1: CGPoint(x: 4.57, y: 21), control2: CGPoint(x: 3.70, y: 20.22))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 22)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct NutritionEntrySheet: View {
    @Binding var draft: NutritionEntryDraft
    let validationMessage: String?
    let isEditing: Bool
    var foodPhoto: UIImage? = nil
    let onCancel: () -> Void
    let onSave: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: String?
    @AccessibilityFocusState private var titleFocused: Bool

    private var title: String {
        isEditing ? "Correct entry" : foodPhoto == nil ? "Manual entry" : "Review meal"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text(localization.string(title)).zoThemeText(.display)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    if let foodPhoto {
                        VStack(alignment: .leading, spacing: ZOSpace.m) {
                            Image(uiImage: foodPhoto).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: ZORadius.card))
                                .accessibilityLabel("Your captured food photo")
                            Text("Automatic nutrition estimates aren't connected yet. Enter or edit the values you want to save.")
                                .zoText(.body).foregroundStyle(theme.textSecondary)
                            Text("The photo is held only while this entry is open. It is not uploaded or saved with the meal.")
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                    VStack(spacing: 0) {
                        entryField("Name", placeholder: "Food or meal", text: $draft.title, numeric: false)
                        Divider().overlay(theme.strokeSubtle)
                        entryField("Calories", placeholder: "Required", text: $draft.calories, numeric: true, decimal: false)
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()
                    if let validationMessage {
                        Label(localization.string(validationMessage), systemImage: "exclamationmark.circle")
                            .zoText(.body).foregroundStyle(theme.warningPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(localization.format("Cannot save. %1$@", .text(localization.string(validationMessage)))))
                            .accessibilityIdentifier("diets.food.validation")
                    }
                    NutritionFoodEvidenceFields(draft: $draft, fieldFocus: $focusedField)
                    Text("Optional macros in grams").zoText(.section).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        entryField("Protein", placeholder: "Optional", text: $draft.proteinGrams, numeric: true)
                        Divider().overlay(theme.strokeSubtle)
                        entryField("Carbohydrates", placeholder: "Optional", text: $draft.carbohydrateGrams, numeric: true)
                        Divider().overlay(theme.strokeSubtle)
                        entryField("Fat", placeholder: "Optional", text: $draft.fatGrams, numeric: true)
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()
                    Text("Saved only on this iPhone.").zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, ZOSpace.screenMargin).padding(.top, ZOSpace.s).padding(.bottom, ZOSpace.l)
                .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden)
            .background(theme.backgroundPrimary)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Save", action: onSave).buttonStyle(ZOButtonStyle(.primary))
                    .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
                    .background(theme.backgroundPrimary).accessibilityIdentifier("diets.food.save")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round)).accessibilityLabel("Cancel")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear { titleFocused = true }
            .onChange(of: validationMessage) { _, message in
                guard let message else { return }
                UIAccessibility.post(notification: .announcement, argument: localization.string(message))
            }
        }
    }

    private func entryField(_ title: String, placeholder: String, text: Binding<String>, numeric: Bool, decimal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(theme.textSecondary)
            TextField(localization.string(placeholder), text: text)
                .keyboardType(numeric ? (decimal ? .decimalPad : .numberPad) : .default)
                .textInputAutocapitalization(numeric ? .never : .sentences)
                .zoText(.section).focused($focusedField, equals: title)
                .accessibilityLabel(Text(localization.string(title)))
        }
        .padding(.vertical, ZOSpace.m)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 64, alignment: .leading)
    }
}

/// Draft state belongs to the parent; this only presents optional evidence and
/// an explicit consumed-value preview. It never writes or fetches food data.
private struct NutritionFoodEvidenceFields: View {
    @Binding var draft: NutritionEntryDraft
    let fieldFocus: FocusState<String?>.Binding
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private static let previewID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Values and portion").zoText(.section).accessibilityAddTraits(.isHeader)
            Picker("Value source", selection: $draft.valueOrigin) {
                ForEach(NutritionValueOrigin.allCases, id: \.self) { origin in
                    Text(localization.string(origin.title)).tag(origin)
                }
            }
            Picker("Values refer to", selection: $draft.valueBasis) {
                ForEach(NutritionValueBasis.allCases, id: \.self) { basis in
                    Text(localization.string(basis.title)).tag(basis)
                }
            }
            .onChange(of: draft.valueBasis) { draft.prepareForBasisChange() }
            LabeledContent("Amount eaten") {
                TextField(localization.string(draft.valueBasis == .consumedPortion ? "Optional" : "Required"), text: $draft.portionAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused(fieldFocus, equals: "portionAmount")
            }
            if let unit = draft.valueBasis.requiredUnit {
                LabeledContent("Portion unit") { Text(localization.string(unit.title)) }
            } else {
                Picker("Portion unit", selection: $draft.portionUnit) {
                    ForEach(NutritionPortionUnit.allCases, id: \.self) { unit in
                        Text(localization.string(unit.title)).tag(unit)
                    }
                }
            }
            if !draft.portionAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("How you got the amount", selection: $draft.portionCertainty) {
                    ForEach(NutritionPortionCertainty.allCases, id: \.self) { certainty in
                        Text(localization.string(certainty.title)).tag(certainty)
                    }
                }
            }
            DisclosureGroup("Source details") {
                TextField("Source name", text: $draft.sourceName).focused(fieldFocus, equals: "sourceName")
                TextField("Food or recipe record ID", text: $draft.sourceRecordID).focused(fieldFocus, equals: "sourceRecordID")
                TextField("Source revision or date", text: $draft.sourceRevision).focused(fieldFocus, equals: "sourceRevision")
            }
            if draft.valueBasis != .consumedPortion,
               let entry = try? draft.validatedEntry(id: Self.previewID, loggedAt: Date(timeIntervalSinceReferenceDate: 0)) {
                Text(localization.format("This saves %1$lld kcal for the amount eaten.", .integer(entry.calories)))
                    .zoText(.body)
                Text(localization.format("Recorded macros for this portion: protein %1$@; carbohydrates %2$@; fat %3$@.",
                    .text(macro(entry.proteinGrams)), .text(macro(entry.carbohydrateGrams)), .text(macro(entry.fatGrams))))
                    .zoText(.caption)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Choose whether calories and macros describe the whole portion or a reference amount. Changing this basis reinterprets the entered values.")
                Text("Grams, milliliters and servings stay separate. Scaled calories are rounded to whole kilocalories; unknown macros stay unknown.")
                Text("Sources and measurements are reported by you, not independently verified by 01.")
            }
        }
        .padding(ZOSpace.l)
        .zoText(.body)
        .zoThemeCardSurface()
    }

    private func macro(_ value: Double?) -> String {
        guard let value else { return localization.string("Not recorded") }
        return localization.format("%1$@ g", .text(value.formatted(.number.precision(.fractionLength(0 ... 3)))))
    }
}
