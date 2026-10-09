import Foundation
import Observation

enum FoodBodyWeightImportCategory: String, CaseIterable, Identifiable {
    case meals, bodyWeight
    var id: String { rawValue }
    var title: String { self == .meals ? "Food records" : "Body-weight readings" }
}

enum FoodBodyWeightImportError: Error, Equatable, LocalizedError {
    case oversizedFile, invalidFile, unsupportedSchema, categoryNotSelected
    case invalidRecords, conflictingIdentifier, storeUnavailable, importBlocked
    case reviewExpired, storeChanged, writeUnconfirmed

    var errorDescription: String? {
        switch self {
        case .oversizedFile: "Choose a JSON export smaller than 16 MB."
        case .invalidFile: "This file is not a supported 01 JSON export. No records were saved."
        case .unsupportedSchema: "This export version is not supported. No records were saved."
        case .categoryNotSelected: "This export does not include the chosen category. No records were saved."
        case .invalidRecords: "Records could not be validated without changing their meaning. No records were saved."
        case .conflictingIdentifier: "An identifier has different values. The entire chosen category is blocked."
        case .storeUnavailable: "Saved records could not be read. Import is blocked to protect them."
        case .importBlocked: "Resolve active or recoverable work before importing records."
        case .reviewExpired: "Choose the file again and review its records before importing."
        case .storeChanged: "Saved records changed after review. Start a fresh file review."
        case .writeUnconfirmed: "Saving could not be confirmed. Check saved records before starting a fresh review."
        }
    }
}

struct FoodBodyWeightImportReview: Identifiable {
    let id: UUID
    let category: FoodBodyWeightImportCategory
    let schemaVersion: Int
    let exportedAt: Date
    // Source order is kept for review. Exact duplicates are visible too.
    let meals: [NutritionEntry]
    let weights: [BodyWeightEntry]
    let appendedCount: Int
    let skippedCount: Int
    let skippedCategories: [String]
}

struct FoodBodyWeightImportResult {
    let category: FoodBodyWeightImportCategory
    let appendedCount: Int
    let skippedCount: Int
}

/// One selected category per explicit confirmation. There is no cross-store
/// transaction, no suspension between fresh read and write, and no HealthKit replay.
@MainActor
@Observable
final class FoodBodyWeightImportCoordinator {
    let category: FoodBodyWeightImportCategory
    private let nutrition: NutritionRepository
    private let bodyWeight: BodyWeightRepository
    private let canImport: @MainActor () throws -> Bool
    private var pending: Pending?
    private(set) var review: FoodBodyWeightImportReview?
    private(set) var needsReconciliation = false

    private enum Collection: Equatable {
        case meals([NutritionEntry])
        case weights([BodyWeightEntry])
    }
    private struct Pending {
        let review: FoodBodyWeightImportReview
        let baseline: Collection
        let expected: Collection
    }

    init(category: FoodBodyWeightImportCategory, nutrition: NutritionRepository,
         bodyWeight: BodyWeightRepository, canImport: @escaping @MainActor () throws -> Bool) {
        self.category = category
        self.nutrition = nutrition
        self.bodyWeight = bodyWeight
        self.canImport = canImport
    }

    /// Discarding abandons only this review. It never undoes an uncertain write.
    func discardReview() {
        pending = nil
        review = nil
        needsReconciliation = false
    }

    func prepare(data: Data) throws -> FoodBodyWeightImportReview {
        guard !needsReconciliation else { throw FoodBodyWeightImportError.writeUnconfirmed }
        pending = nil
        review = nil
        try checkGate()
        let source = try FoodBodyWeightImportDecoder.decode(data, category: category)
        let baseline = try readCurrent()
        let expected: Collection
        let added: Int
        let skipped: Int
        switch baseline {
        case .meals(let original):
            let merge = try Self.merge(original: original, incoming: source.meals, id: { $0.id })
            let values = merge.values.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
            try FoodBodyWeightImportDecoder.validateMeals(values)
            expected = .meals(values); added = merge.added; skipped = merge.skipped
        case .weights(let original):
            let merge = try Self.merge(original: original, incoming: source.weights, id: { $0.id })
            let values = merge.values.sorted(by: FoodBodyWeightImportDecoder.weightsNewestFirst)
            try FoodBodyWeightImportDecoder.validateWeights(values)
            expected = .weights(values); added = merge.added; skipped = merge.skipped
        }
        let next = FoodBodyWeightImportReview(id: UUID(), category: category,
            schemaVersion: source.schemaVersion, exportedAt: source.exportedAt,
            meals: source.meals, weights: source.weights, appendedCount: added,
            skippedCount: skipped, skippedCategories: source.skippedCategories)
        pending = Pending(review: next, baseline: baseline, expected: expected)
        review = next
        return next
    }

    func confirm(reviewID: UUID) throws -> FoodBodyWeightImportResult {
        guard let pending, pending.review.id == reviewID else { throw FoodBodyWeightImportError.reviewExpired }
        guard !needsReconciliation else { throw FoodBodyWeightImportError.writeUnconfirmed }
        try checkGate()
        guard try readCurrent() == pending.baseline else {
            discardReview()
            throw FoodBodyWeightImportError.storeChanged
        }
        if pending.review.appendedCount == 0 { return finish(pending) }
        needsReconciliation = true
        do {
            switch (pending.expected, pending.baseline) {
            case (.meals(let proposed), .meals(let baseline)):
                try nutrition.importReviewed(proposed, replacing: baseline)
            case (.weights(let proposed), .weights(let baseline)):
                try bodyWeight.importReviewed(proposed, replacing: baseline)
            default: throw FoodBodyWeightImportError.invalidRecords
            }
            guard try readCurrent() == pending.expected else { throw FoodBodyWeightImportError.writeUnconfirmed }
            return finish(pending)
        } catch {
            // Keep the review and last readable state. Never roll back or replay
            // this ambiguous write. Reconciliation below performs no save.
            throw FoodBodyWeightImportError.writeUnconfirmed
        }
    }

    /// Returns a confirmed result only if the exact whole collection landed.
    /// A nil result means nothing was added; a fresh review is required to retry.
    func reconcile(reviewID: UUID) throws -> FoodBodyWeightImportResult? {
        guard let pending, pending.review.id == reviewID, needsReconciliation else {
            throw FoodBodyWeightImportError.reviewExpired
        }
        try checkGate()
        let fresh = try readCurrent()
        if fresh == pending.expected { return finish(pending) }
        if fresh == pending.baseline {
            discardReview()
            return nil
        }
        throw FoodBodyWeightImportError.storeChanged
    }

    private func readCurrent() throws -> Collection {
        switch category {
        case .meals: .meals(try nutrition.readForImport())
        case .bodyWeight: .weights(try bodyWeight.readForImport())
        }
    }
    private func checkGate() throws {
        guard try canImport() else { throw FoodBodyWeightImportError.importBlocked }
    }
    private func finish(_ pending: Pending) -> FoodBodyWeightImportResult {
        let result = FoodBodyWeightImportResult(category: category,
            appendedCount: pending.review.appendedCount, skippedCount: pending.review.skippedCount)
        discardReview()
        return result
    }
    private static func merge<Value: Equatable>(original: [Value], incoming: [Value],
                                               id: (Value) -> UUID) throws -> (values: [Value], added: Int, skipped: Int) {
        var byID = Dictionary(uniqueKeysWithValues: original.map { (id($0), $0) })
        var added: [Value] = []
        var skipped = 0
        for value in incoming {
            if let existing = byID[id(value)] {
                guard existing == value else { throw FoodBodyWeightImportError.conflictingIdentifier }
                skipped += 1
            } else {
                byID[id(value)] = value
                added.append(value)
            }
        }
        return (original + added, added.count, skipped)
    }
}
