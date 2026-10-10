import SwiftUI

/// The "Found" sheet (proof 54): portion chips, the portion card with one bar per
/// macro (solid is today so far, striped is this portion), the per-100 line, the
/// source line with Fix it, the meal control and "Add to breakfast · 95 kcal".
struct FoodProductView: View {
    let item: FoodItem
    @Bindable var model: FoodLogModel
    var showsFoundBadge = false
    let onAdd: (FoodItem, Double) -> Void
    let onClose: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var amount: Double?
    @State private var isOther = false
    @State private var otherText = ""
    @State private var corrected: FoodItem?
    @State private var isFixing = false

    private var food: FoodItem { corrected ?? item }
    private var currentAmount: Double {
        if isOther, let typed = Double(otherText.replacingOccurrences(of: ",", with: ".")), typed > 0, typed <= 5_000 { return typed }
        return amount ?? food.defaultAmount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                header
                if food.basis != .consumedPortion { portionChips }
                portionCard
                if food.basis != .consumedPortion {
                    Text(per100Line).zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                sourceLine
                ZOSegmentedControl("Meal", selection: $model.meal, options: FoodMeal.allCases.map {
                    ZOSegment(value: $0, label: Text(localization.string($0.title)))
                })
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xl)
            .padding(.bottom, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .background(theme.surfacePrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(localization.format(model.meal.sentenceKey, .integer(food.calories(for: currentAmount)))) {
                onAdd(food, currentAmount)
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .disabled(isOther && Double(otherText.replacingOccurrences(of: ",", with: ".")) == nil)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.surfacePrimary)
            .accessibilityIdentifier("foodLog.product.add")
        }
        .sheet(isPresented: $isFixing) {
            FoodLabelCheckView(draft: FoodLabelDraft(item: food), photo: nil, title: "Fix it",
                intro: "Correct the values for yourself. They are saved to My foods on this iPhone.",
                saveTitle: "Save") { fixed in
                model.saveToMyFoods(fixed)
                corrected = fixed
                isFixing = false
            } onCancel: { isFixing = false }
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(food.name).zoText(.title).foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail = food.detail {
                    Text(detail).zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: ZOSpace.s)
            if showsFoundBadge {
                Label(localization.string("Found"), systemImage: "checkmark")
                    .labelStyle(ZOIconLabelStyle())
                    .zoText(.mini)
                    .padding(.horizontal, ZOSpace.s)
                    .frame(minHeight: 22)
                    .foregroundStyle(theme.textSecondary)
                    .overlay(Capsule().stroke(theme.strokeSubtle, lineWidth: 1))
            }
        }
    }

    private var portionChips: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            ScrollView(.horizontal) {
                HStack(spacing: ZOSpace.s) {
                    ForEach(Array(food.portions.enumerated()), id: \.offset) { _, portion in
                        ZOChip(title: chipTitle(portion), isSelected: !isOther && currentAmount == portion.amount) {
                            isOther = false
                            amount = portion.amount
                        }
                    }
                    ZOChip(title: localization.string("Other"), isSelected: isOther) {
                        isOther = true
                        if otherText.isEmpty { otherText = FoodLabelDraft.text(currentAmount) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            if isOther {
                HStack(spacing: ZOSpace.s) {
                    TextField(localization.string("Amount"), text: $otherText)
                        .keyboardType(.decimalPad)
                        .zoText(.section)
                        .frame(maxWidth: 120)
                        .padding(.horizontal, ZOSpace.m)
                        .frame(minHeight: ZOSpace.hitTarget)
                        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.control))
                        .accessibilityLabel(Text(localization.string("Amount")))
                    Text(food.unitSymbol).zoText(.label).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
            }
        }
    }

    private func chipTitle(_ portion: FoodPortionOption) -> String {
        if portion.label.hasPrefix("whole:") {
            return localization.format("Whole pack, %1$@", .text(String(portion.label.dropFirst(6))))
        }
        return portion.label.isEmpty ? FoodItem.portionLabel(portion.amount, basis: food.basis) : portion.label
    }

    private var portionCard: some View {
        let portion = food.nutrients(for: currentAmount)
        let today = model.todaySoFar
        return HStack(alignment: .center, spacing: ZOSpace.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This portion").zoText(.caption).foregroundStyle(theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(food.calories(for: currentAmount).formatted()).zoThemeText(.metric)
                        .contentTransition(.numericText(value: currentAmount))
                    Text("kcal").zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: ZOSpace.m) {
                FoodMacroBar(title: "Protein", color: ZOColor.Data.protein, today: today.protein ?? 0, portion: portion.protein)
                FoodMacroBar(title: "Carbs", color: ZOColor.Data.carbs, today: today.carbohydrate ?? 0, portion: portion.carbohydrate)
                FoodMacroBar(title: "Fat", color: ZOColor.Data.fat, today: today.fat ?? 0, portion: portion.fat)
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }

    private var per100Line: String {
        let v = food.values
        func grams(_ value: Double?) -> String {
            value.map { $0.formatted(.number.precision(.fractionLength(0 ... 1))) + " g" } ?? "?"
        }
        return localization.format(food.basis == .per100Milliliters ? "Per 100 ml: %1$lld kcal, protein %2$@, carbs %3$@, fat %4$@"
                : "Per 100 g: %1$lld kcal, protein %2$@, carbs %3$@, fat %4$@",
            .integer(Int(v.calories.rounded())), .text(grams(v.protein)), .text(grams(v.carbohydrate)), .text(grams(v.fat)))
    }

    private var sourceText: String? {
        if food.sourceName == OpenFoodFactsClient.sourceName { return "Food data from Open Food Facts, open licence" }
        if food.sourceName == BasicFoodsCatalog.sourceName { return "Basic food data from USDA FoodData Central" }
        return food.origin == .labelReported ? "Your values, copied from a label" : nil
    }

    @ViewBuilder private var sourceLine: some View {
        if let text = sourceText {
            HStack(spacing: ZOSpace.s) {
                Image(systemName: "info.circle").zoIcon(ZOIcon.inline).foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                Text(localization.string(text)).zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ZOSpace.s)
                if food.basis != .consumedPortion {
                    Button(localization.string("Fix it")) { isFixing = true }
                        .zoText(.caption)
                        .underline()
                        .foregroundStyle(theme.textPrimary)
                        .frame(minHeight: ZOSpace.hitTarget)
                        .accessibilityHint(Text(localization.string("Correct the values for yourself")))
                }
            }
        }
    }
}

/// One macro: solid for today so far, 2 pt diagonal stripes (100% and 40%) for
/// this portion. No personal target is set yet, so the scale leaves headroom and
/// the label says "so far" instead of "of 150".
struct FoodMacroBar: View {
    let title: String
    let color: Color
    let today: Double
    let portion: Double?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        let resolved = ZOColor.resolved(color, in: theme.colorScheme)
        let added = portion ?? 0
        let scale = max((today + added) * 1.25, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.xs) {
                RoundedRectangle(cornerRadius: 2).fill(resolved).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(localization.string(title)).zoText(.label)
                Spacer(minLength: ZOSpace.xs)
                Text(portion == nil ? localization.string("Not listed")
                     : localization.format("+%1$@ g · %2$@ so far", .text(Self.grams(added)), .text(Self.grams(today))))
                    .zoText(.mini).monospacedDigit().foregroundStyle(theme.textSecondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceTertiary)
                    HStack(spacing: 0) {
                        Rectangle().fill(resolved).frame(width: width * today / scale)
                        FoodStripes(color: resolved).frame(width: width * added / scale)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(portion == nil ? localization.format("%1$@, not listed for this food", .text(localization.string(title)))
            : localization.format("%1$@, %2$@ grams so far, plus %3$@ in this portion",
                .text(localization.string(title)), .text(Self.grams(today)), .text(Self.grams(added)))))
    }

    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

struct FoodStripes: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.4)))
            var x = -size.height
            while x < size.width + size.height {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(color), lineWidth: 2)
                x += 4
            }
        }
        .accessibilityHidden(true)
    }
}
