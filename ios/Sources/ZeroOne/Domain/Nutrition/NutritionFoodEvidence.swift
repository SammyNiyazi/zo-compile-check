import Foundation

/// These are reported origins, never an assertion of independent retrieval,
/// nutrient accuracy, ingredient/allergen safety or dietary suitability.
enum NutritionValueOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown, estimate, labelReported, databaseReported, recipeReported

    var title: String {
        switch self {
        case .unknown: "Source type not recorded"
        case .estimate: "Estimated values"
        case .labelReported: "Copied from a label"
        case .databaseReported: "Copied from a food database"
        case .recipeReported: "Calculated from a recipe"
        }
    }
}

enum NutritionValueBasis: String, Codable, CaseIterable, Hashable, Sendable {
    case consumedPortion, per100Grams, per100Milliliters, perServing

    var title: String {
        switch self {
        case .consumedPortion: "Whole portion eaten"
        case .per100Grams: "Per 100 grams"
        case .per100Milliliters: "Per 100 milliliters"
        case .perServing: "Per serving"
        }
    }

    var requiredUnit: NutritionPortionUnit? {
        switch self {
        case .consumedPortion: nil
        case .per100Grams: .grams
        case .per100Milliliters: .milliliters
        case .perServing: .servings
        }
    }
}

enum NutritionPortionUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case grams, milliliters, servings
    var title: String {
        switch self {
        case .grams: "Grams"
        case .milliliters: "Milliliters"
        case .servings: "Servings"
        }
    }
}

enum NutritionPortionCertainty: String, Codable, CaseIterable, Hashable, Sendable {
    case reported, measuredReported, estimated
    var title: String {
        switch self {
        case .reported: "Amount entered"
        case .measuredReported: "I measured this amount"
        case .estimated: "I estimated this amount"
        }
    }
}

struct NutritionPortion: Codable, Equatable, Sendable {
    let amount: Double
    let unit: NutritionPortionUnit
    let certainty: NutritionPortionCertainty
    var isValid: Bool { amount.isFinite && amount > 0 && amount <= 10_000 }
}

struct NutritionSourceReference: Codable, Equatable, Sendable {
    let name: String
    let recordID: String?
    let revision: String?

    var isValid: Bool {
        Self.validText(name, maximumBytes: 512)
            && (recordID.map { Self.validText($0, maximumBytes: 512) } ?? true)
            && (revision.map { Self.validText($0, maximumBytes: 512) } ?? true)
    }

    private static func validText(_ text: String, maximumBytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= maximumBytes
    }
}

struct NutritionNutrientValues: Codable, Equatable, Sendable {
    let calories: Int
    let proteinGrams: Double?
    let carbohydrateGrams: Double?
    let fatGrams: Double?

    init(calories: Int, proteinGrams: Double?, carbohydrateGrams: Double?, fatGrams: Double?) {
        self.calories = calories; self.proteinGrams = proteinGrams
        self.carbohydrateGrams = carbohydrateGrams; self.fatGrams = fatGrams
    }

    init(_ entry: NutritionEntry) {
        self.init(calories: entry.calories, proteinGrams: entry.proteinGrams,
            carbohydrateGrams: entry.carbohydrateGrams, fatGrams: entry.fatGrams)
    }

    var isValid: Bool {
        (0 ... 10_000).contains(calories)
            && [proteinGrams, carbohydrateGrams, fatGrams].allSatisfy {
                $0.map { $0.isFinite && (0 ... 1_000).contains($0) } ?? true
            }
    }

    func scaled(by factor: Double) throws -> Self {
        guard isValid, factor.isFinite, factor > 0 else {
            throw NutritionEntryValidationError.foodEvidenceInvalid
        }
        let energy = Double(calories) * factor
        // Stored calories remain whole kilocalories. Keep the reference and
        // consumed amount so this rounding is inspectable and repeatable.
        guard energy.isFinite, energy >= 0, energy <= 10_000 else {
            throw NutritionEntryValidationError.foodEvidenceInvalid
        }
        let result = Self(calories: Int(energy.rounded(.toNearestOrAwayFromZero)),
            proteinGrams: proteinGrams.map { $0 * factor },
            carbohydrateGrams: carbohydrateGrams.map { $0 * factor },
            fatGrams: fatGrams.map { $0 * factor })
        guard result.isValid else { throw NutritionEntryValidationError.foodEvidenceInvalid }
        return result
    }
}

struct NutritionFoodEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let origin: NutritionValueOrigin
    let valueBasis: NutritionValueBasis
    let portion: NutritionPortion?
    let source: NutritionSourceReference?
    let referenceValues: NutritionNutrientValues?

    init(schemaVersion: Int = Self.currentSchemaVersion, origin: NutritionValueOrigin,
         valueBasis: NutritionValueBasis, portion: NutritionPortion?,
         source: NutritionSourceReference?, referenceValues: NutritionNutrientValues?) {
        self.schemaVersion = schemaVersion; self.origin = origin; self.valueBasis = valueBasis
        self.portion = portion; self.source = source; self.referenceValues = referenceValues
    }

    var isStructurallyValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              portion?.isValid ?? true, source?.isValid ?? true else { return false }
        if valueBasis == .consumedPortion { return referenceValues == nil }
        return portion?.unit == valueBasis.requiredUnit && referenceValues?.isValid == true
    }

    func consumedValues() throws -> NutritionNutrientValues {
        guard isStructurallyValid, let portion, let referenceValues else {
            throw NutritionEntryValidationError.foodEvidenceInvalid
        }
        let factor = valueBasis == .perServing ? portion.amount : portion.amount / 100
        return try referenceValues.scaled(by: factor)
    }

    func isValid(for values: NutritionNutrientValues) -> Bool {
        guard isStructurallyValid, values.isValid else { return false }
        if valueBasis == .consumedPortion { return true }
        guard let expected = try? consumedValues(), expected.calories == values.calories else { return false }
        // Accept only floating-point round-trip noise, not a meaningful correction.
        func matches(_ lhs: Double?, _ rhs: Double?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case let (a?, b?): abs(a - b) <= max(1e-12, max(abs(a), abs(b)) * 1e-12)
            default: false
            }
        }
        return matches(expected.proteinGrams, values.proteinGrams)
            && matches(expected.carbohydrateGrams, values.carbohydrateGrams)
            && matches(expected.fatGrams, values.fatGrams)
    }
}

/// Record-level quality is independent of finished-day completeness and of
/// personal energy need. Reported database/label sources are not verified data.
struct NutritionLoggedEvidenceSummary: Equatable, Sendable {
    let entryCount: Int
    let unknownOriginCount: Int
    let estimatedValueCount: Int
    let reportedSourceCount: Int
    let unknownPortionCount: Int
    let estimatedPortionCount: Int

    init(entries: [NutritionEntry]) {
        entryCount = entries.count
        unknownOriginCount = entries.filter { $0.foodEvidence?.origin == nil || $0.foodEvidence?.origin == .unknown }.count
        estimatedValueCount = entries.filter { $0.foodEvidence?.origin == .estimate }.count
        reportedSourceCount = entryCount - unknownOriginCount - estimatedValueCount
        unknownPortionCount = entries.filter { $0.foodEvidence?.portion == nil }.count
        estimatedPortionCount = entries.filter { $0.foodEvidence?.portion?.certainty == .estimated }.count
    }
}
