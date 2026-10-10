import Foundation

/// Logging food (study 30 proof 54, MIGRATION phase 38). Every addition still goes
/// through NutritionEntryDraft so the stored meal keeps its origin, basis, portion
/// and source; this layer only describes reusable foods and how a portion scales.
enum FoodMeal: String, Codable, CaseIterable, Hashable, Sendable {
    case breakfast, lunch, dinner, snack

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }

    /// Lowercase form used inside sentences ("Add to breakfast").
    var sentenceKey: String {
        switch self {
        case .breakfast: "Add to breakfast · %1$lld kcal"
        case .lunch: "Add to lunch · %1$lld kcal"
        case .dinner: "Add to dinner · %1$lld kcal"
        case .snack: "Add to snack · %1$lld kcal"
        }
    }

    var addedKey: String {
        switch self {
        case .breakfast: "%1$@ added to breakfast"
        case .lunch: "%1$@ added to lunch"
        case .dinner: "%1$@ added to dinner"
        case .snack: "%1$@ added to snack"
        }
    }

    /// Before 10:30 Breakfast, before 15:00 Lunch, before 21:00 Dinner, else Snack.
    static func preset(for date: Date, calendar: Calendar = .current) -> FoodMeal {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        switch minutes {
        case ..<(10 * 60 + 30): return .breakfast
        case ..<(15 * 60): return .lunch
        case ..<(21 * 60): return .dinner
        default: return .snack
        }
    }
}

/// Values for the item's basis: per 100 g, per 100 ml, per serving, or the
/// whole portion. Calories are kilocalories; the rest are grams.
struct FoodNutrients: Codable, Equatable, Sendable {
    var calories: Double
    var protein: Double?
    var carbohydrate: Double?
    var fat: Double?
    var fibre: Double? = nil
    var sugars: Double? = nil
    var salt: Double? = nil
    var saturates: Double? = nil

    func scaled(by factor: Double) -> FoodNutrients {
        FoodNutrients(calories: calories * factor, protein: protein.map { $0 * factor },
            carbohydrate: carbohydrate.map { $0 * factor }, fat: fat.map { $0 * factor },
            fibre: fibre.map { $0 * factor }, sugars: sugars.map { $0 * factor },
            salt: salt.map { $0 * factor }, saturates: saturates.map { $0 * factor })
    }

    var isPlausible: Bool {
        calories.isFinite && (0 ... 10_000).contains(calories)
            && [protein, carbohydrate, fat, fibre, sugars, salt, saturates].allSatisfy {
                $0.map { $0.isFinite && (0 ... 1_000).contains($0) } ?? true
            }
    }
}

/// A portion choice. `amount` is in the item's basis unit: grams, milliliters or
/// servings. A whole-portion item has one option with amount 1.
struct FoodPortionOption: Codable, Equatable, Hashable, Sendable {
    var label: String
    var amount: Double
}

struct FoodItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case product, basic, mine, recent }

    var id: String
    var kind: Kind
    var name: String
    var detail: String?
    var basis: NutritionValueBasis
    var values: FoodNutrients
    var portions: [FoodPortionOption]
    var defaultPortion: Int = 0
    var origin: NutritionValueOrigin
    var sourceName: String?
    var recordID: String?
    var revision: String?
    var barcode: String? = nil

    var unitSymbol: String {
        switch basis {
        case .per100Milliliters: "ml"
        case .perServing: "×"
        default: "g"
        }
    }

    var defaultAmount: Double {
        portions.indices.contains(defaultPortion) ? portions[defaultPortion].amount : (basis == .consumedPortion ? 1 : 100)
    }

    /// The factor that turns the basis values into the eaten amount.
    func factor(for amount: Double) -> Double {
        switch basis {
        case .per100Grams, .per100Milliliters: amount / 100
        case .perServing: amount
        case .consumedPortion: 1
        }
    }

    func nutrients(for amount: Double) -> FoodNutrients {
        values.scaled(by: factor(for: amount))
    }

    func calories(for amount: Double) -> Int {
        Int(nutrients(for: amount).calories.rounded(.toNearestOrAwayFromZero))
    }

    /// The same draft a person could type by hand, so validation, storage,
    /// export and Health writes stay on the one existing path.
    func draft(amount: Double, certainty: NutritionPortionCertainty = .reported) -> NutritionEntryDraft {
        var draft = NutritionEntryDraft()
        draft.title = name
        draft.valueOrigin = origin
        draft.valueBasis = basis
        draft.calories = String(Int(values.calories.rounded(.toNearestOrAwayFromZero)))
        draft.proteinGrams = Self.text(values.protein)
        draft.carbohydrateGrams = Self.text(values.carbohydrate)
        draft.fatGrams = Self.text(values.fat)
        if let unit = basis.requiredUnit {
            draft.portionUnit = unit
            draft.portionAmount = Self.text(amount)
            draft.portionCertainty = certainty
        }
        draft.sourceName = sourceName ?? ""
        draft.sourceRecordID = sourceName == nil ? "" : (recordID ?? "")
        draft.sourceRevision = sourceName == nil ? "" : (revision ?? "")
        return draft
    }

    /// Rebuilds an item from a saved meal so Recent can add it again at the
    /// same portion. Entries without evidence repeat their stored totals.
    init?(entry: NutritionEntry) {
        let evidence = entry.foodEvidence
        id = "recent:" + entry.title.lowercased()
        kind = .recent
        name = entry.title
        detail = nil
        origin = evidence?.origin ?? .unknown
        sourceName = evidence?.source?.name
        recordID = evidence?.source?.recordID
        revision = evidence?.source?.revision
        if let evidence, evidence.valueBasis != .consumedPortion,
           let reference = evidence.referenceValues, let portion = evidence.portion {
            basis = evidence.valueBasis
            values = FoodNutrients(calories: Double(reference.calories), protein: reference.proteinGrams,
                carbohydrate: reference.carbohydrateGrams, fat: reference.fatGrams)
            portions = [FoodPortionOption(label: Self.portionLabel(portion.amount, basis: evidence.valueBasis), amount: portion.amount)]
        } else {
            basis = .consumedPortion
            values = FoodNutrients(calories: Double(entry.calories), protein: entry.proteinGrams,
                carbohydrate: entry.carbohydrateGrams, fat: entry.fatGrams)
            portions = [FoodPortionOption(label: "", amount: 1)]
        }
    }

    init(id: String, kind: Kind, name: String, detail: String?, basis: NutritionValueBasis,
         values: FoodNutrients, portions: [FoodPortionOption], defaultPortion: Int = 0,
         origin: NutritionValueOrigin, sourceName: String?, recordID: String?, revision: String?,
         barcode: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.detail = detail; self.basis = basis
        self.values = values; self.portions = portions; self.defaultPortion = defaultPortion
        self.origin = origin; self.sourceName = sourceName; self.recordID = recordID
        self.revision = revision; self.barcode = barcode
    }

    static func portionLabel(_ amount: Double, basis: NutritionValueBasis) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(0 ... 1)))
        switch basis {
        case .per100Milliliters: return number + " ml"
        case .perServing: return number + " ×"
        default: return number + " g"
        }
    }

    static func text(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        // Three decimals keep label values exact without float noise in the draft.
        return String((value * 1_000).rounded() / 1_000)
    }
}

/// The last 20 distinct foods, newest first, from today's and earlier meals.
enum FoodRecents {
    static func items(from entries: [NutritionEntry], limit: Int = 20) -> [FoodItem] {
        var seen = Set<String>()
        var result: [FoodItem] = []
        for entry in entries.sorted(by: { $0.loggedAt > $1.loggedAt }) {
            let key = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted, let item = FoodItem(entry: entry) else { continue }
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }

    /// "Same as yesterday?" only when the same meal yesterday had at least one item.
    static func sameAsYesterday(entries: [NutritionEntry], meal: FoodMeal, now: Date,
                                labels: FoodMealLabels, calendar: Calendar = .current) -> [NutritionEntry] {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return [] }
        return entries
            .filter { calendar.isDate($0.loggedAt, inSameDayAs: yesterday) && labels.meal(for: $0, calendar: calendar) == meal }
            .sorted { $0.loggedAt < $1.loggedAt }
    }
}

/// Which meal each saved entry belongs to. Kept beside the meal records, so the
/// strict meal storage format and its exports stay unchanged; an entry with no
/// label falls back to the time it was logged.
struct FoodMealLabels: Codable, Equatable, Sendable {
    var byEntry: [UUID: FoodMeal] = [:]

    func meal(for entry: NutritionEntry, calendar: Calendar = .current) -> FoodMeal {
        byEntry[entry.id] ?? FoodMeal.preset(for: entry.loggedAt, calendar: calendar)
    }
}

/// A meal row on Diets: one entry shows its own name, several show the meal.
struct FoodMealGroup: Identifiable, Equatable {
    let meal: FoodMeal
    let entries: [NutritionEntry]
    var id: FoodMeal { meal }
    var calories: Int { entries.reduce(0) { $0 + $1.calories } }
    var firstLoggedAt: Date { entries.map(\.loggedAt).min() ?? .distantPast }

    static func groups(_ entries: [NutritionEntry], labels: FoodMealLabels, calendar: Calendar = .current) -> [FoodMealGroup] {
        let grouped = Dictionary(grouping: entries) { labels.meal(for: $0, calendar: calendar) }
        return grouped.map { FoodMealGroup(meal: $0.key, entries: $0.value.sorted { $0.loggedAt < $1.loggedAt }) }
            .sorted { $0.firstLoggedAt > $1.firstLoggedAt }
    }
}
