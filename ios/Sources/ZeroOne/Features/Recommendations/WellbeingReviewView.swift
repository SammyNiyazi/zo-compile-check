import SwiftUI

enum CheckInAnswer: String, CaseIterable {
    case notReported, no, yes
    var value: Bool? {
        switch self { case .notReported: nil; case .no: false; case .yes: true }
    }
    init(_ value: Bool?) { self = value.map { $0 ? .yes : .no } ?? .notReported }
    var title: LocalizedStringResource {
        switch self { case .notReported: "Not reported"; case .no: "No"; case .yes: "Yes" }
    }
}

extension RecoveryEnergy {
    var title: LocalizedStringResource {
        switch self { case .notReported: "Not reported"; case .low: "Low"; case .usual: "Usual"; case .high: "High" }
    }
}

extension RecoverySoreness {
    var title: LocalizedStringResource {
        switch self {
        case .notReported: "Not reported"
        case .none: "None"
        case .mild: "Mild"
        case .moderate: "Moderate"
        case .severe: "Severe"
        }
    }
}

extension NutritionLogCoverage {
    var title: LocalizedStringResource {
        switch self { case .unknown: "Not sure"; case .partial: "Some meals are missing"; case .complete: "Everything is logged" }
    }
}

extension DietFoodGroup {
    var title: LocalizedStringResource {
        switch self {
        case .vegetables: "Vegetables"
        case .fruit: "Fruit"
        case .wholeGrains: "Whole grains"
        case .pulsesNutsSeeds: "Beans, lentils, nuts or seeds"
        case .proteinFoods: "Protein-rich foods"
        case .unsaturatedFats: "Unsaturated fats"
        }
    }
}

extension NutritionAmountBasis {
    var title: LocalizedStringResource {
        switch self {
        case .notReported: "Not reported"
        case .foodRecords: "Food labels or trusted food records"
        case .estimated: "Estimated"
        case .mixed: "Mixed or uncertain sources"
        }
    }
}

extension WellbeingRecommendation {
    var title: LocalizedStringResource { .init(stringLiteral: message.titleKey) }
    var detail: LocalizedStringResource { .init(stringLiteral: message.detailKey) }
}

extension WellbeingEvidenceKind {
    var title: LocalizedStringResource {
        switch self {
        case .reportedPain: "Reported new or worsening pain"
        case .reportedIllness: "Reported feeling unwell"
        case .reportedFatigue: "Reported low energy"
        case .reportedSoreness: "Reported moderate or severe soreness"
        case .reportedHunger: "Reported unusual hunger"
        case .shortSleep: "Reported or recently imported short sleep"
        case .consecutiveTrainingDays: "Several recent days with recorded training"
        case .completeFoodLogsBelowChosenGoal: "Confirmed complete training-day food logs below the chosen goal"
        case .limitedReportedFoodVariety: "Limited food groups in completed day reviews"
        case .reportedThirst: "Reported thirst"
        case .incompleteFoodLogs: "Food logging is incomplete"
        case .conflictingSleep: "Sleep reports disagree"
        case .waterLogBelowStoredGoal: "Afternoon water log below its stored goal"
        case .repeatedComparablePerformanceDecline: "Repeated decline in comparable saved repetitions"
        case .lowReportedFruitAndVegetables: "Fruit and vegetable amounts below the general adult reference on multiple reviewed days"
        case .lowReportedFoodFibre: "Food fibre below the general adult reference on multiple reviewed days"
        case .highReportedFreeSugar: "Free sugar at or above the general energy-share limit on multiple reviewed days"
        case .highReportedSalt: "Salt at or above the general adult limit on multiple reviewed days"
        case .tailoredNutritionNeeded: "Reported dietary needs require tailored review"
        case .nutritionContextUnknown: "Nutrition limits are not confirmed for general adult guidance"
        case .prescribedFluidRestriction: "Reported prescribed fluid restriction"
        case .energyTargetContextUnknown: "Calorie target source or purpose is not confirmed"
        }
    }
}

extension WellbeingUnavailableSource {
    var title: LocalizedStringResource {
        switch self {
        case .strengthHistory: "Saved workout history"
        case .outdoorHistory: "Outdoor activity history"
        case .recovery: "Recovery and completed-day reviews"
        case .foodLog: "Food records"
        }
    }
}

struct WellbeingSummaryView: View {
    let assessment: WellbeingAssessment
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !assessment.unavailableSources.isEmpty,
               (assessment.recommendations.first?.demand ?? .review) < .easeTraining {
                Text("Check your records").zoText(.section)
                Text("Some recovery, food or activity records could not be verified. Review them before using training advice.")
                    .zoText(.label).foregroundStyle(.secondary)
            } else if let recommendation = assessment.recommendations.first {
                Text(recommendation.title).zoText(.section)
                Text(recommendation.detail).zoText(.label).foregroundStyle(.secondary)
            } else {
                Text("Recovery and fuelling").zoText(.section)
                Text("Your check-in is saved. No concern was flagged from the available information.")
                    .zoText(.label).foregroundStyle(.secondary)
            }
            Button("Review check-in", action: onReview)
                .buttonStyle(ZOButtonStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WellbeingReviewView: View {
    @Bindable var repository: WellbeingCheckInRepository
    let nutrition: NutritionRepository
    let assessment: WellbeingAssessment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.zeroOneLocalization) private var localization
    @State private var baseline: WellbeingCheckInSnapshot
    @State private var mealBaseline: [NutritionEntry]
    @State private var energy = RecoveryEnergy.notReported
    @State private var soreness = RecoverySoreness.notReported
    @State private var sleepHours = ""
    @State private var pain = CheckInAnswer.notReported
    @State private var illness = CheckInAnswer.notReported
    @State private var hunger = CheckInAnswer.notReported
    @State private var thirst = CheckInAnswer.notReported
    @State private var foodDay: Date
    @State private var coverage = NutritionLogCoverage.unknown
    @State private var foodGoal = ""
    @State private var energyTargetDraft = NutritionEnergyTargetDraft()
    @State private var confirmsEnergyTarget = false
    @State private var reviewsFoodGroups = false
    @State private var foodGroups: Set<DietFoodGroup> = []
    @State private var reviewsAmounts = false
    @State private var amountDraft = NutritionDayAmountsDraft()
    @State private var adult = CheckInAnswer.notReported
    @State private var tailoredNutrition = CheckInAnswer.notReported
    @State private var foodRestrictions = CheckInAnswer.notReported
    @State private var fluidRestriction = CheckInAnswer.notReported
    @State private var confirmsNutritionContext = false
    @State private var errorKey: String?
    @State private var showsDeleteConfirmation = false

    init(repository: WellbeingCheckInRepository, nutrition: NutritionRepository, assessment: WellbeingAssessment) {
        self.repository = repository
        self.nutrition = nutrition
        self.assessment = assessment
        _baseline = State(initialValue: repository.snapshot)
        _mealBaseline = State(initialValue: nutrition.entries)
        _foodDay = State(initialValue: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !assessment.unavailableSources.isEmpty {
                    Section("Check your records") {
                        Text("Some recovery, food or activity records could not be verified. Review them before using training advice.")
                        ForEach(assessment.unavailableSources.sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                            Text($0.title).zoText(.caption)
                        }
                    }
                }
                ForEach(assessment.recommendations) { recommendation in
                    Section {
                        Text(recommendation.detail)
                        ForEach(recommendation.evidence, id: \.self) { Text($0.title).zoText(.caption).foregroundStyle(.secondary) }
                    } header: { Text(recommendation.title) }
                }
                if assessment.hasConflictingSleep {
                    Section { Text("Your sleep report and Apple Health disagree. Sleep was left out of this assessment.") }
                }
                if let workload = assessment.workload {
                    Section { TrainingWorkloadSummaryView(assessment: workload) }
                }
                if let quality = assessment.dietQuality {
                    Section { DietQualitySummaryView(assessment: quality) }
                }
                if let targets = assessment.energyTargetReview {
                    Section("Calorie target context") {
                        Text(localization.string(targets.eligibility.title))
                        Text(localization.format("Reported targets: %1$lld days. Qualified comparisons: %2$lld. Context withheld: %3$lld.",
                            .integer(targets.reportedTargetDayCount), .integer(targets.comparisonDayCount),
                            .integer(targets.unqualifiedTargetDayCount))).zoText(.caption)
                        Text("Targets remain reported references, not measured requirements. No calorie, macro or fluid prescription is generated.")
                            .zoText(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("How you feel today") {
                    Picker("Energy", selection: $energy) {
                        ForEach(RecoveryEnergy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Muscle soreness", selection: $soreness) {
                        ForEach(RecoverySoreness.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Last night's sleep in hours (optional)", text: $sleepHours).keyboardType(.decimalPad)
                    answer("New or worsening pain", selection: $pain)
                    answer("Feeling unwell", selection: $illness)
                    answer("Unusually hungry", selection: $hunger)
                    answer("Thirsty", selection: $thirst)
                }
                Section {
                    DisclosureGroup("Nutrition preferences and limits") {
                        answer("Aged 18 or older", selection: $adult)
                        answer("Need professionally tailored nutrition", selection: $tailoredNutrition)
                        Text("This includes pregnancy or breastfeeding, a prescribed diet, or support with eating-related concerns. You do not need to record a diagnosis.")
                            .zoText(.caption).foregroundStyle(.secondary)
                        answer("Food restrictions or allergies", selection: $foodRestrictions)
                        answer("Prescribed fluid restriction", selection: $fluidRestriction)
                        Toggle("Confirm these nutrition answers", isOn: $confirmsNutritionContext)
                        Text("Confirm only when you have reviewed these answers. Saving food does not renew an older nutrition-context report.")
                            .zoText(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DatePicker("Finished food day", selection: $foodDay,
                        in: ...latestFinishedDay, displayedComponents: .date)
                    Picker("Food log", selection: $coverage) {
                        ForEach(NutritionLogCoverage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Calorie goal for this day (optional)", text: $foodGoal).keyboardType(.numberPad)
                    Text("Enter only the goal you used on this day. Leave it blank if you are unsure. A goal is not a measured calorie requirement.")
                        .zoText(.caption).foregroundStyle(.secondary)
                    if !foodGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Picker("Target source", selection: $energyTargetDraft.source) {
                            ForEach(NutritionEnergyTargetSource.allCases, id: \.self) { Text(localization.string($0.title)).tag($0) }
                        }
                        Picker("Target purpose", selection: $energyTargetDraft.intent) {
                            ForEach(NutritionEnergyTargetIntent.allCases, id: \.self) { Text(localization.string($0.title)).tag($0) }
                        }
                        Text("Professional advice is reported by you and does not override your nutrition limits. Leave the source or purpose unreported if unsure.")
                            .zoText(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Confirm changes to this day's target and context", isOn: $confirmsEnergyTarget)
                    Toggle("Review food groups for this day", isOn: $reviewsFoodGroups)
                    if reviewsFoodGroups {
                        ForEach(DietFoodGroup.allCases, id: \.self) { group in
                            Toggle(isOn: Binding(get: { foodGroups.contains(group) }, set: {
                                if $0 { foodGroups.insert(group) } else { foodGroups.remove(group) }
                            })) { Text(group.title) }
                        }
                    }
                    Toggle("Review food amounts for this day", isOn: $reviewsAmounts)
                    if reviewsAmounts {
                        Picker("Amount coverage", selection: $amountDraft.coverage) {
                            Text("Not sure").tag(NutritionLogCoverage.unknown)
                            Text("Some quantities are missing").tag(NutritionLogCoverage.partial)
                            Text("Each entered amount covers the full day").tag(NutritionLogCoverage.complete)
                        }
                        Picker("Amount source", selection: $amountDraft.basis) {
                            ForEach(NutritionAmountBasis.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("Fruit and vegetables in grams (optional)", text: $amountDraft.fruitAndVegetables).keyboardType(.decimalPad)
                        TextField("Food fibre in grams (optional)", text: $amountDraft.foodFibre).keyboardType(.decimalPad)
                        TextField("Free sugar in grams (optional)", text: $amountDraft.freeSugar).keyboardType(.decimalPad)
                        Text("Free sugar includes added sugar and sugars in honey, syrups and juice. It is different from total sugar or carbohydrates on a label.")
                            .zoText(.caption).foregroundStyle(.secondary)
                        TextField("Salt in grams (optional)", text: $amountDraft.salt).keyboardType(.decimalPad)
                        Text("Enter salt, not sodium. Leave amounts blank if you do not know them. Estimates and partial quantities do not qualify for reference comparisons.")
                            .zoText(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Food review") } footer: {
                    Text("Confirm a full day only when all food and drinks with calories are logged. Food-group choices describe variety, not portion sizes or nutrient adequacy. Changes to meals require a new confirmation.")
                }
                .disabled(nutrition.availability != .available)
                if let errorKey { Text(localization.string(errorKey)).foregroundStyle(.red) }
                Section {
                    Text("Check-ins stay on this device. They do not diagnose a condition or calculate a calorie requirement.")
                        .zoText(.caption).foregroundStyle(.secondary)
                    if let export = exportText {
                        ShareLink(item: export) { Label("Export check-ins", systemImage: "square.and.arrow.up") }
                    }
                    Button("Delete check-ins", role: .destructive) { showsDeleteConfirmation = true }
                }
            }
            .navigationTitle("Recovery and fuelling")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!repository.isAvailable) }
            }
            .confirmationDialog("Delete all recovery and food-review check-ins?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete check-ins", role: .destructive) {
                    do { try repository.deleteAll(replacing: baseline); dismiss() }
                    catch { handle(error) }
                }
            } message: { Text("Meal, water and workout records will be kept.") }
            .onAppear(perform: loadDraft)
            .onChange(of: foodDay) { _, _ in loadFoodDraft() }
            .onChange(of: foodGoal) { confirmsEnergyTarget = false }
            .onChange(of: energyTargetDraft) { confirmsEnergyTarget = false }
        }
    }

    private var latestFinishedDay: Date {
        calendar.date(byAdding: .second, value: -1, to: calendar.startOfDay(for: .now)) ?? .now
    }

    private var exportText: String? {
        guard repository.isAvailable else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(repository.snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func answer(_ label: LocalizedStringKey, selection: Binding<CheckInAnswer>) -> some View {
        Picker(label, selection: selection) {
            ForEach(CheckInAnswer.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    private func loadDraft() {
        if let report = baseline.recovery.first(where: { $0.isCurrent(at: .now, calendar: calendar) }) {
            energy = report.energy; soreness = report.soreness
            sleepHours = report.sleepHours.map { String($0) } ?? ""
            pain = CheckInAnswer(report.hasNewOrWorseningPain); illness = CheckInAnswer(report.feelsUnwell)
            hunger = CheckInAnswer(report.feelsUnusuallyHungry); thirst = CheckInAnswer(report.feelsThirsty)
        }
        if let guidance = baseline.guidanceContext {
            adult = CheckInAnswer(guidance.isAdult)
            tailoredNutrition = CheckInAnswer(guidance.needsTailoredNutrition)
            foodRestrictions = CheckInAnswer(guidance.hasFoodRestrictions)
            fluidRestriction = CheckInAnswer(guidance.hasPrescribedFluidRestriction)
        }
        if !repository.isAvailable { errorKey = "Check-ins could not be loaded. Existing data has been kept." }
        loadFoodDraft()
    }

    private func loadFoodDraft() {
        confirmsEnergyTarget = false
        let day = calendar.startOfDay(for: foodDay)
        if let review = baseline.nutrition.first(where: { $0.day == day && $0.timeZoneID == calendar.timeZone.identifier }),
           review.isUsable(entries: nutrition.entries, at: .now, calendar: calendar) {
            coverage = review.coverage; reviewsFoodGroups = review.reviewedFoodGroups != nil
            foodGroups = review.reviewedFoodGroups ?? []
            foodGoal = review.reportedCalorieGoal.map { String($0) } ?? ""
            energyTargetDraft = NutritionEnergyTargetDraft(review.energyTargetContext)
            reviewsAmounts = review.amounts != nil
            amountDraft = review.amounts.map(NutritionDayAmountsDraft.init) ?? .init()
        } else {
            coverage = .unknown; reviewsFoodGroups = false; foodGroups = []; foodGoal = ""
            energyTargetDraft = .init()
            reviewsAmounts = false; amountDraft = .init()
        }
    }

    private func save() {
        let now = Date.now
        let text = sleepHours.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let hours = text.isEmpty ? nil : Double(text)
        guard text.isEmpty || hours.map({ $0.isFinite && (0 ... 24).contains($0) }) == true else {
            errorKey = "Use sleep hours from 0 to 24, or leave the field blank."
            return
        }
        let day = calendar.startOfDay(for: now)
        let previous = baseline.recovery.first { $0.day == day && $0.timeZoneID == calendar.timeZone.identifier }
        let recovery = RecoveryCheckIn(id: previous?.id ?? UUID(), day: day, timeZoneID: calendar.timeZone.identifier,
            reportedAt: now, energy: energy, soreness: soreness, sleepHours: hours,
            hasNewOrWorseningPain: pain.value, feelsUnwell: illness.value,
            feelsUnusuallyHungry: hunger.value, feelsThirsty: thirst.value)
        var foodReview: NutritionDayReview?
        let guidance: NutritionGuidanceContext?
        do {
            guidance = try NutritionGuidanceDraft(isAdult: adult.value, needsTailoredNutrition: tailoredNutrition.value,
                hasFoodRestrictions: foodRestrictions.value, hasPrescribedFluidRestriction: fluidRestriction.value)
                .confirmedUpdate(replacing: baseline.guidanceContext, confirmed: confirmsNutritionContext, at: now)
        } catch NutritionGuidanceDraftError.confirmationRequired {
            errorKey = "Confirm the changed nutrition answers before saving."
            return
        } catch {
            errorKey = "Review the dates and values before saving the check-in."
            return
        }
        if nutrition.availability == .available {
            let goalText = foodGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = goalText.isEmpty ? nil : Int(goalText)
            guard goalText.isEmpty || goal.map({ (500 ... 10_000).contains($0) }) == true else {
                errorKey = "Use a calorie goal from 500 to 10,000, or leave it blank."
                return
            }
            let foodDate = calendar.startOfDay(for: foodDay)
            let freshMeals: [NutritionEntry]
            do { freshMeals = try nutrition.readForImport() }
            catch {
                errorKey = "Food records could not be verified. Review your saved meals before confirming the day."
                return
            }
            guard let fingerprint = NutritionDayReview.fingerprint(entries: freshMeals, on: foodDate, calendar: calendar),
                  fingerprint == NutritionDayReview.fingerprint(entries: mealBaseline, on: foodDate, calendar: calendar) else {
                errorKey = "Food records could not be verified. Review your saved meals before confirming the day."
                return
            }
            let previous = baseline.nutrition.first { $0.day == foodDate && $0.timeZoneID == calendar.timeZone.identifier }
            let targetContext: NutritionEnergyTargetContext?
            do {
                targetContext = try energyTargetDraft.confirmedContext(goal: goal,
                    replacing: previous?.reportedCalorieGoal, context: previous?.energyTargetContext,
                    confirmed: confirmsEnergyTarget)
            } catch {
                errorKey = "Confirm the changed target and its context for this day before saving."
                return
            }
            let amounts: NutritionDayAmounts?
            do { amounts = reviewsAmounts ? try amountDraft.validated() : nil }
            catch {
                errorKey = "Use non-negative known amounts in grams within the supported range, or leave them blank."
                return
            }
            foodReview = NutritionDayReview(id: previous?.id ?? UUID(), day: foodDate, timeZoneID: calendar.timeZone.identifier,
                reviewedAt: now, coverage: coverage, mealFingerprint: fingerprint,
                reviewedFoodGroups: reviewsFoodGroups ? foodGroups : nil, reportedCalorieGoal: goal, amounts: amounts,
                energyTargetContext: targetContext)
        }
        do {
            try repository.save(recovery: recovery, nutrition: foodReview, replacing: baseline, at: now, calendar: calendar,
                guidanceContext: guidance)
            dismiss()
        }
        catch { handle(error) }
    }

    private func handle(_ error: Error) {
        switch error as? WellbeingCheckInError {
        case .changed: errorKey = "Check-ins changed elsewhere. Close and reopen this review before saving."
        case .invalid: errorKey = "Review the dates and values before saving the check-in."
        default: errorKey = "Saving the check-in could not be confirmed. Your last readable records have been kept."
        }
    }
}
