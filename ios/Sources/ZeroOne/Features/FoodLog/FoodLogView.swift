import SwiftUI
import UIKit

/// Log food (proof 54): full-screen sheet from Log a meal and from Main Action.
/// Meal control preset by the time of day, search, Scan a barcode and Quick add,
/// "Same as yesterday?", Recent and My foods; typing searches My foods, then
/// basic foods on this iPhone, then one row for Open Food Facts products.
struct FoodLogView: View {
    @Bindable var model: FoodLogModel
    let onAdded: ([NutritionEntry], FoodMeal) -> Void
    let onManualEntry: () -> Void
    let onClose: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var searchFocused: Bool
    @State private var selected: FoodItem?
    @State private var scanning = false
    @State private var scanStartsWithLabel = false
    @State private var quickAdding = false
    @State private var typingLabel = false
    @State private var hidesYesterday = false
    @State private var toast: (message: String, entries: [NutritionEntry])?
    @State private var toastTask: Task<Void, Never>?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    ZOSegmentedControl("Meal", selection: $model.meal, options: FoodMeal.allCases.map {
                        ZOSegment(value: $0, label: Text(localization.string($0.title)))
                    })
                    searchField
                    if model.trimmedQuery.isEmpty { home } else { results }
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.s)
                .padding(.bottom, ZOSpace.x4)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(theme.backgroundPrimary)
            .navigationTitle(localization.string("Log food"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel(Text(localization.string("Close")))
                        .accessibilityIdentifier("foodLog.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let toast {
                    ZOToast(message: toast.message, actionTitle: localization.string("Undo")) { undo() }
                        .padding(.horizontal, ZOSpace.screenMargin)
                        .padding(.bottom, ZOSpace.s)
                        .accessibilityIdentifier("foodLog.toast")
                }
            }
        }
        .sheet(item: $selected) { item in
            FoodProductView(item: item, model: model, onAdd: { food, amount in
                add(food, amount: amount, closes: true)
            }, onClose: { selected = nil })
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
        .fullScreenCover(isPresented: $scanning) {
            FoodScanFlowView(model: model, startWithLabel: scanStartsWithLabel, onAdded: { entries, meal in
                scanning = false
                onAdded(entries, meal)
            }, onSearchInstead: {
                scanning = false
                searchFocused = true
            }, onClose: { scanning = false })
            .zeroOneTheme(theme)
        }
        .sheet(isPresented: $quickAdding) {
            FoodQuickAddView(meal: model.meal, onAdd: { calories, name in
                quickAdding = false
                do {
                    let entry = try model.quickAdd(calories: calories, name: name)
                    showToast([entry])
                } catch { failure = localization.string("This food couldn't be saved. Check your meals before trying again.") }
            }, onCancel: { quickAdding = false })
            .presentationDetents([.medium])
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
        .sheet(isPresented: $typingLabel) {
            FoodLabelCheckView(draft: FoodLabelDraft(), photo: nil, title: "Type it in",
                intro: "Copy the values per 100 g or 100 ml from the label. It's saved to My foods.") { item in
                model.saveToMyFoods(item)
                typingLabel = false
                add(item, amount: item.defaultAmount, closes: false)
            } onCancel: { typingLabel = false }
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
        }
        .alert(localization.string("Log food"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(localization.string("OK"), role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .onDisappear { toastTask?.cancel() }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: ZOSpace.s) {
            HStack(spacing: ZOSpace.s) {
                Image(systemName: "magnifyingglass").zoIcon(ZOIcon.inline).foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(localization.string("Search foods"), text: $model.query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .zoText(.body)
                    .accessibilityIdentifier("foodLog.search")
            }
            .padding(.horizontal, ZOSpace.m)
            .frame(minHeight: ZOSpace.hitTarget + 4)
            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.control))
            .overlay(RoundedRectangle(cornerRadius: ZORadius.control).stroke(searchFocused ? theme.textPrimary : .clear, lineWidth: 1.5))
            if searchFocused || !model.query.isEmpty {
                Button(localization.string("Cancel")) { model.query = ""; searchFocused = false }
                    .zoText(.label)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: ZOSpace.hitTarget)
            }
        }
    }

    // MARK: Empty query

    @ViewBuilder private var home: some View {
        HStack(spacing: ZOSpace.m) {
            tile("Scan a barcode", icon: "barcode.viewfinder", id: "foodLog.scan") {
                scanStartsWithLabel = false
                scanning = true
            }
            tile("Quick add", icon: "plus", id: "foodLog.quickAdd") { quickAdding = true }
        }
        if !hidesYesterday, !model.yesterday.isEmpty { yesterdayCard }
        let recents = model.recents
        if !recents.isEmpty {
            section("Recent", trailing: nil)
            list(recents) { item in item.basis == .consumedPortion ? nil : item.portions.first?.label }
        }
        section("My foods", trailing: model.myFoods.isEmpty ? nil : localization.format("%1$lld saved", .integer(model.myFoods.count)))
        if model.myFoods.isEmpty {
            Text("Foods you photograph from a label, fix or type in are kept here.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
        } else {
            list(model.myFoods, mine: true) { $0.portions.first?.label }
        }
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Button(localization.string("Photo a nutrition label"), systemImage: "camera") {
                scanStartsWithLabel = true
                scanning = true
            }
            Button(localization.string("Type a label in"), systemImage: "keyboard") { typingLabel = true }
            Button(localization.string("Enter a meal by hand"), systemImage: "square.and.pencil", action: onManualEntry)
        }
        .zoText(.label)
        .foregroundStyle(theme.textPrimary)
        .buttonStyle(.plain)
        .padding(.top, ZOSpace.s)
    }

    private func tile(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Image(systemName: icon).zoIcon(ZOIcon.row)
                Text(localization.string(title)).zoText(.label)
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, ZOSpace.m)
            .zoThemeCardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var yesterdayCard: some View {
        let entries = model.yesterday
        let calories = entries.reduce(0) { $0 + $1.calories }
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Same as yesterday?").zoText(.caption).foregroundStyle(theme.textSecondary)
                Text(entries.map(\.title).joined(separator: ", ")).zoText(.section).foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
            }
            HStack(spacing: ZOSpace.m) {
                Button(entries.count == 2 ? localization.format("Add both · %1$lld kcal", .integer(calories))
                       : entries.count == 1 ? localization.format("Add it · %1$lld kcal", .integer(calories))
                       : localization.format("Add all · %1$lld kcal", .integer(calories))) {
                    do { showToast(try model.addYesterday()) }
                    catch { failure = localization.string("This food couldn't be saved. Check your meals before trying again.") }
                    hidesYesterday = true
                }
                .buttonStyle(ZOButtonStyle(.primary))
                Button(localization.string("Not today")) { hidesYesterday = true }
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .overlay(RoundedRectangle(cornerRadius: ZORadius.card).stroke(theme.textPrimary, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let mine = model.myFoodMatches
        if !mine.isEmpty {
            section("My foods", trailing: nil)
            list(mine, mine: true) { $0.portions.first?.label }
        }
        let basic = model.basicMatches
        if !basic.isEmpty {
            section("Basic foods", trailing: localization.string("portion · kcal"))
            list(basic) { $0.portions.first?.label }
        }
        Button { model.searchProducts() } label: {
            HStack(spacing: ZOSpace.m) {
                Image(systemName: "globe").zoIcon(ZOIcon.row).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.format("Search products for \u{201C}%1$@\u{201D}", .text(model.trimmedQuery))).zoText(.label)
                    Text("Open Food Facts · needs a connection").zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: ZOSpace.s)
                Image(systemName: "chevron.right").zoIcon(ZOIcon.inline).foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.l)
            .zoThemeCardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("foodLog.searchProducts")
        switch model.productSearch {
        case .idle: EmptyView()
        case .searching:
            HStack { ProgressView(); Text("Searching Open Food Facts").zoText(.caption) }
                .foregroundStyle(theme.textSecondary)
        case let .results(items):
            if items.isEmpty {
                Text("No products found. Try fewer words, or scan the barcode.").zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else {
                section("Products", trailing: localization.string("Open Food Facts"))
                list(items) { $0.detail }
            }
        case .offline:
            Text("No connection. Your foods and basic foods still work.").zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        case .unavailable:
            Text("Open Food Facts didn't answer. Try again in a moment.").zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        Text("Basic foods come from USDA FoodData Central and live on this iPhone, so search works offline.")
            .zoText(.caption).foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    private func section(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(localization.string(title)).zoText(.section).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).zoText(.caption).foregroundStyle(theme.textSecondary) }
        }
        .padding(.top, ZOSpace.s)
    }

    private func list(_ items: [FoodItem], mine: Bool = false, detail: @escaping (FoodItem) -> String?) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item, mine: mine, detail: detail(item))
                if item.id != items.last?.id { Divider().overlay(theme.strokeSubtle) }
            }
        }
        .padding(.horizontal, ZOSpace.l)
        .zoThemeCardSurface()
    }

    private func row(_ item: FoodItem, mine: Bool, detail: String?) -> some View {
        HStack(spacing: ZOSpace.m) {
            Button { selected = item } label: {
                HStack(spacing: ZOSpace.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).zoText(.label).foregroundStyle(theme.textPrimary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            if mine { Image(systemName: "person").zoIcon(10).accessibilityHidden(true) }
                            if let detail, !detail.isEmpty {
                                Text(detail.hasPrefix("whole:") ? String(detail.dropFirst(6)) : detail).zoText(.caption)
                            }
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: ZOSpace.s)
                    Text(localization.format("%1$lld kcal", .integer(item.calories(for: item.defaultAmount))))
                        .zoText(.caption).monospacedDigit().foregroundStyle(theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { add(item, amount: item.defaultAmount, closes: false) } label: {
                Image(systemName: "plus").zoIcon(ZOIcon.inline)
                    .frame(width: 36, height: 36)
                    .background(theme.surfaceSecondary, in: Circle())
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(localization.format("Add %1$@", .text(item.name))))
        }
        .frame(minHeight: ZOSpace.rowMinHeight)
    }

    // MARK: Adding

    private func add(_ item: FoodItem, amount: Double, closes: Bool) {
        do {
            let entry = try model.add(item, amount: amount)
            if closes {
                selected = nil
                onAdded([entry], model.meal)
            } else {
                showToast([entry])
            }
        } catch {
            failure = localization.string("This food couldn't be saved. Check your meals before trying again.")
        }
    }

    private func showToast(_ entries: [NutritionEntry]) {
        guard let first = entries.first else { return }
        let name = entries.count == 1 ? first.title : localization.format("%1$lld foods", .integer(entries.count))
        let message = localization.format(model.meal.addedKey, .text(name))
        toastTask?.cancel()
        toast = (message, entries)
        UIAccessibility.post(notification: .announcement, argument: message)
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func undo() {
        guard let entries = toast?.entries else { return }
        toastTask?.cancel()
        let undone = model.undo(entries)
        toast = nil
        if !undone { failure = localization.string("Undo could not be confirmed. Check your meals.") }
    }
}
