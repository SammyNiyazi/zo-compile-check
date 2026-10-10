import Foundation

/// What "Check what it read" edits: a photo reading, a typed label, or a
/// correction of a looked-up product ("Fix it"). Saving makes a My foods item.
struct FoodLabelDraft: Equatable, Sendable {
    enum Problem: Equatable { case nameRequired, energyRequired, invalid(NutritionLabelField), portionInvalid }

    var name = ""
    var portionLabel = ""
    var portionAmount = ""
    var isMilliliters = false
    var values: [NutritionLabelField: String] = [:]
    /// Read with low confidence and not yet confirmed or edited.
    var needsCheck: Set<NutritionLabelField> = []
    var barcode: String?
    var existingID: String?

    init() {}

    init(reading: NutritionLabelReading, barcode: String?) {
        self.barcode = barcode
        isMilliliters = reading.isPer100Milliliters
        for (field, value) in reading.values { values[field] = Self.text(value) }
        needsCheck = reading.lowConfidence
        if let portion = reading.portionAmount { portionAmount = Self.text(portion) }
    }

    init(item: FoodItem) {
        name = item.name
        barcode = item.barcode
        isMilliliters = item.basis == .per100Milliliters
        let v = item.values
        let pairs: [(NutritionLabelField, Double?)] = [(.energy, v.calories), (.fat, v.fat), (.saturates, v.saturates),
            (.carbohydrate, v.carbohydrate), (.sugars, v.sugars), (.fibre, v.fibre), (.protein, v.protein), (.salt, v.salt)]
        for (field, value) in pairs { if let value { values[field] = Self.text(value) } }
        if item.basis != .consumedPortion, let first = item.portions.first, first.amount != 100 {
            portionAmount = Self.text(first.amount)
        }
        existingID = item.kind == .mine ? item.id : nil
    }

    mutating func confirm(_ field: NutritionLabelField) { needsCheck.remove(field) }

    mutating func set(_ field: NutritionLabelField, _ text: String) {
        values[field] = text
        needsCheck.remove(field)
    }

    func number(_ field: NutritionLabelField) -> Double? {
        guard let text = values[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    var portion: Double? {
        let text = portionAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0, value <= 5_000 else { return nil }
        return value
    }

    /// Calories for the printed portion, else per 100.
    var previewCalories: Int? {
        guard let energy = number(.energy) else { return nil }
        return Int((energy * (portion ?? 100) / 100).rounded())
    }

    func problems() -> [Problem] {
        var problems: [Problem] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.nameRequired) }
        if number(.energy) == nil { problems.append(.energyRequired) }
        for field in NutritionLabelField.allCases {
            guard let text = values[field], !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let value = number(field), value.isFinite, value >= 0,
                  value <= (field == .energy ? 1_000 : 100) else { problems.append(.invalid(field)); continue }
        }
        if !portionAmount.trimmingCharacters(in: .whitespaces).isEmpty && portion == nil { problems.append(.portionInvalid) }
        return problems
    }

    /// A My foods item with the values per 100 g or 100 ml, copied from a label.
    func item(id: String = "mine:" + UUID().uuidString) -> FoodItem? {
        guard problems().isEmpty, let energy = number(.energy) else { return nil }
        let basis: NutritionValueBasis = isMilliliters ? .per100Milliliters : .per100Grams
        let unit = isMilliliters ? "ml" : "g"
        var portions: [FoodPortionOption] = []
        if let portion {
            let label = portionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = portion.formatted(.number.precision(.fractionLength(0 ... 1))) + " " + unit
            portions.append(FoodPortionOption(label: label.isEmpty ? amount : label + ", " + amount, amount: portion))
        }
        portions.append(FoodPortionOption(label: "100 " + unit, amount: 100))
        let values = FoodNutrients(calories: energy, protein: number(.protein), carbohydrate: number(.carbohydrate),
            fat: number(.fat), fibre: number(.fibre), sugars: number(.sugars), salt: number(.salt),
            saturates: number(.saturates))
        return FoodItem(id: existingID ?? id, kind: .mine, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: portionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : portionLabel,
            basis: basis, values: values, portions: portions, defaultPortion: 0, origin: .labelReported,
            sourceName: nil, recordID: nil, revision: nil, barcode: barcode)
    }

    static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
