import SwiftUI
import UIKit

/// "Check what it read" (proof 54): the photo thumbnail, Name (required), One
/// portion, then the per-100 table with every value editable. A value read with
/// low confidence carries the Check badge until it is tapped or edited.
struct FoodLabelCheckView: View {
    @State var draft: FoodLabelDraft
    let photo: UIImage?
    var title = "Check the label"
    var intro: String? = nil
    var saveTitle = "Save and add"
    let onSave: (FoodItem) -> Void
    let onCancel: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @FocusState private var focused: NutritionLabelField?
    @FocusState private var nameFocused: Bool
    @State private var showsProblems = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    readHeader
                    VStack(spacing: 0) {
                        fieldRow("Name") {
                            TextField(localization.string("Required"), text: $draft.name)
                                .focused($nameFocused)
                                .textInputAutocapitalization(.sentences)
                        }
                        Divider().overlay(theme.strokeSubtle)
                        fieldRow("One portion") {
                            HStack(spacing: ZOSpace.s) {
                                TextField(localization.string("1 bar"), text: $draft.portionLabel)
                                TextField("45", text: $draft.portionAmount)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 72)
                                Text(draft.isMilliliters ? "ml" : "g").foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()

                    HStack(alignment: .firstTextBaseline) {
                        Text(draft.isMilliliters ? "Per 100 ml" : "Per 100 g").zoText(.section)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Picker(localization.string("Values per"), selection: $draft.isMilliliters) {
                            Text("100 g").tag(false)
                            Text("100 ml").tag(true)
                        }
                        .pickerStyle(.menu)
                        .zoText(.caption)
                    }
                    VStack(spacing: 0) {
                        ForEach(NutritionLabelField.allCases, id: \.self) { field in
                            valueRow(field)
                            if field != NutritionLabelField.allCases.last { Divider().overlay(theme.strokeSubtle) }
                        }
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .zoThemeCardSurface()

                    if showsProblems, !draft.problems().isEmpty {
                        Label(problemText, systemImage: "exclamationmark.circle")
                            .zoText(.body).foregroundStyle(theme.warningPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Saved to My foods on this iPhone. Nothing is sent anywhere.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.s)
                .padding(.bottom, ZOSpace.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(theme.backgroundPrimary)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(saveButtonTitle) {
                    showsProblems = true
                    if let item = draft.item() { onSave(item) }
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
                .accessibilityIdentifier("foodLog.check.save")
            }
            .navigationTitle(localization.string(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel(Text(localization.string("Cancel")))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(localization.string("Done")) { focused = nil; nameFocused = false }
                }
            }
        }
    }

    private var saveButtonTitle: String {
        guard let calories = draft.previewCalories else { return localization.string(saveTitle) }
        return localization.format("%1$@ · %2$lld kcal", .text(localization.string(saveTitle)), .integer(calories))
    }

    @ViewBuilder private var readHeader: some View {
        if let photo {
            HStack(spacing: ZOSpace.m) {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: 44, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.small))
                    .accessibilityLabel(Text(localization.string("Your label photo")))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read from your photo").zoText(.section)
                    Text(checkHint).zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let intro {
            Text(localization.string(intro)).zoText(.body).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkHint: String {
        switch draft.needsCheck.count {
        case 0: return localization.string("Tap any number to fix it.")
        case 1: return localization.string("Tap any number to fix it. One needs a look.")
        default: return localization.format("Tap any number to fix it. %1$lld need a look.", .integer(draft.needsCheck.count))
        }
    }

    private var problemText: String {
        switch draft.problems().first {
        case .nameRequired?: localization.string("Add a name before saving.")
        case .energyRequired?: localization.string("Add the energy in kcal before saving.")
        case .portionInvalid?: localization.string("Enter a portion greater than zero.")
        case let .invalid(field)?: localization.format("Check %1$@: it needs a number per 100.", .text(localization.string(field.title)))
        case nil: ""
        }
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(localization.string(label)).zoText(.caption).foregroundStyle(theme.textSecondary)
            content().zoText(.section)
        }
        .padding(.vertical, ZOSpace.m)
        .frame(minHeight: 64, alignment: .leading)
    }

    private func valueRow(_ field: NutritionLabelField) -> some View {
        let isSub = field == .saturates || field == .sugars
        return HStack(spacing: ZOSpace.s) {
            Text(localization.string(field.title)).zoText(isSub ? .caption : .body)
                .foregroundStyle(isSub ? theme.textSecondary : theme.textPrimary)
                .padding(.leading, isSub ? ZOSpace.l : 0)
            Spacer(minLength: ZOSpace.s)
            if draft.needsCheck.contains(field) {
                Label(localization.string("Check"), systemImage: "exclamationmark.triangle")
                    .labelStyle(ZOIconLabelStyle())
                    .zoText(.mini)
                    .padding(.horizontal, ZOSpace.s)
                    .frame(minHeight: 22)
                    .foregroundStyle(theme.warningPrimary)
                    .overlay(Capsule().stroke(theme.warningPrimary, lineWidth: 1))
                    .accessibilityLabel(Text(localization.string("Check this value")))
            }
            TextField("–", text: Binding(get: { draft.values[field] ?? "" }, set: { draft.set(field, $0) }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focused, equals: field)
                .frame(maxWidth: 80)
                .zoText(.label)
                .monospacedDigit()
                .accessibilityLabel(Text(localization.format("%1$@ per 100", .text(localization.string(field.title)))))
            Text(field.unit).zoText(.caption).foregroundStyle(theme.textSecondary).frame(width: 30, alignment: .leading)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .onTapGesture { draft.confirm(field); focused = field }
    }
}

/// Quick add: calories only, for when you just know the number.
struct FoodQuickAddView: View {
    let meal: FoodMeal
    let onAdd: (Int, String) -> Void
    let onCancel: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var calories = ""
    @State private var name = ""
    @FocusState private var caloriesFocused: Bool

    private var value: Int? {
        guard let number = Int(calories.trimmingCharacters(in: .whitespaces)), (1 ... 10_000).contains(number) else { return nil }
        return number
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                    TextField("0", text: $calories)
                        .keyboardType(.numberPad)
                        .focused($caloriesFocused)
                        .zoThemeText(.metric)
                        .fixedSize()
                        .accessibilityLabel(Text(localization.string("Calories")))
                    Text("kcal").zoText(.section).foregroundStyle(theme.textSecondary)
                }
                TextField(localization.string("Name (optional)"), text: $name)
                    .zoText(.body)
                    .padding(.horizontal, ZOSpace.m)
                    .frame(minHeight: ZOSpace.rowMinHeight)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.control))
                Text("For when you just know the number. No macros are added.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(ZOSpace.screenMargin)
            .background(theme.backgroundPrimary)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(value.map { localization.format("Add · %1$lld kcal", .integer($0)) } ?? localization.string("Add")) {
                    guard let value else { return }
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(value, trimmed.isEmpty ? localization.string("Quick add") : trimmed)
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(value == nil)
                .padding(ZOSpace.screenMargin)
            }
            .navigationTitle(localization.string("Quick add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel(Text(localization.string("Cancel")))
                }
            }
            .onAppear { caloriesFocused = true }
        }
    }
}
