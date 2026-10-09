import Foundation
import Observation

struct NutritionEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let calories: Int
    let proteinGrams: Double?
    let carbohydrateGrams: Double?
    let fatGrams: Double?
    let loggedAt: Date
    // Nil is retained for legacy entries. Missing provenance is not evidence of
    // a measured portion, known source, or independently verified nutrients.
    let foodEvidence: NutritionFoodEvidence?

    init(id: UUID, title: String, calories: Int, proteinGrams: Double?,
         carbohydrateGrams: Double?, fatGrams: Double?, loggedAt: Date,
         foodEvidence: NutritionFoodEvidence? = nil) {
        self.id = id; self.title = title; self.calories = calories
        self.proteinGrams = proteinGrams; self.carbohydrateGrams = carbohydrateGrams
        self.fatGrams = fatGrams; self.loggedAt = loggedAt; self.foodEvidence = foodEvidence
    }
}

struct NutritionDailyTotals: Equatable, Sendable {
    let calories: Int
    let proteinGrams: Double
    let carbohydrateGrams: Double
    let fatGrams: Double

    static let zero = NutritionDailyTotals(
        calories: 0,
        proteinGrams: 0,
        carbohydrateGrams: 0,
        fatGrams: 0
    )
}

enum NutritionMacroCoverage: Equatable, Sendable {
    case notRecorded, partial, allLoggedEntries, unavailable
}

/// Coverage of this macro within saved meal records, not proof that all meals
/// were logged or that the person's daily intake met a dietary requirement.
struct NutritionMacroTotal: Equatable, Sendable {
    let knownSubtotalGrams: Double?
    let recordedEntryCount: Int
    let loggedEntryCount: Int
    let coverage: NutritionMacroCoverage

    init(values: [Double?]) {
        loggedEntryCount = values.count
        let recorded = values.compactMap { $0 }
        recordedEntryCount = recorded.count
        guard recorded.allSatisfy({ $0.isFinite && (0 ... 1_000).contains($0) }) else {
            knownSubtotalGrams = nil
            coverage = .unavailable
            return
        }
        knownSubtotalGrams = recorded.isEmpty ? nil : recorded.reduce(0, +)
        coverage = recorded.isEmpty ? .notRecorded
            : (recorded.count == values.count ? .allLoggedEntries : .partial)
    }
}

struct NutritionLoggedMacroSummary: Equatable, Sendable {
    let protein: NutritionMacroTotal
    let carbohydrates: NutritionMacroTotal
    let fat: NutritionMacroTotal

    init(entries: [NutritionEntry]) {
        protein = NutritionMacroTotal(values: entries.map(\.proteinGrams))
        carbohydrates = NutritionMacroTotal(values: entries.map(\.carbohydrateGrams))
        fat = NutritionMacroTotal(values: entries.map(\.fatGrams))
    }
}

struct NutritionEntryDraft: Equatable, Sendable {
    var title = ""
    var calories = ""
    var proteinGrams = ""
    var carbohydrateGrams = ""
    var fatGrams = ""
    var valueOrigin = NutritionValueOrigin.unknown
    var valueBasis = NutritionValueBasis.consumedPortion
    var portionAmount = ""
    var portionUnit = NutritionPortionUnit.grams
    var portionCertainty = NutritionPortionCertainty.reported
    var sourceName = ""
    var sourceRecordID = ""
    var sourceRevision = ""
    private(set) var originalEntry: NutritionEntry?

    init() {}

    init(entry: NutritionEntry) {
        originalEntry = entry
        title = entry.title
        let values = entry.foodEvidence?.referenceValues ?? NutritionNutrientValues(entry)
        calories = String(values.calories)
        proteinGrams = Self.string(values.proteinGrams)
        carbohydrateGrams = Self.string(values.carbohydrateGrams)
        fatGrams = Self.string(values.fatGrams)
        if let evidence = entry.foodEvidence {
            valueOrigin = evidence.origin; valueBasis = evidence.valueBasis
            if let portion = evidence.portion {
                portionAmount = String(portion.amount); portionUnit = portion.unit
                portionCertainty = portion.certainty
            }
            sourceName = evidence.source?.name ?? ""
            sourceRecordID = evidence.source?.recordID ?? ""
            sourceRevision = evidence.source?.revision ?? ""
        }
    }

    /// A basis change cannot silently reinterpret a serving count as a mass.
    mutating func prepareForBasisChange() {
        if let required = valueBasis.requiredUnit, portionUnit != required {
            portionAmount = ""; portionUnit = required; portionCertainty = .reported
        }
    }

    func validatedEntry(id: UUID = UUID(), loggedAt: Date = .now) throws -> NutritionEntry {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw NutritionEntryValidationError.titleRequired }
        guard normalizedTitle.utf8.count <= 4_096 else { throw NutritionEntryValidationError.titleTooLong }
        let caloriesText = calories.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caloriesText.isEmpty else { throw NutritionEntryValidationError.caloriesRequired }
        guard let calorieValue = Int(caloriesText), (0 ... 10_000).contains(calorieValue) else {
            throw NutritionEntryValidationError.caloriesInvalid
        }
        let input = NutritionNutrientValues(calories: calorieValue,
            proteinGrams: try parsedMacro(proteinGrams, field: "Protein"),
            carbohydrateGrams: try parsedMacro(carbohydrateGrams, field: "Carbohydrates"),
            fatGrams: try parsedMacro(fatGrams, field: "Fat"))
        let amountText = portionAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        let portion: NutritionPortion?
        if amountText.isEmpty { portion = nil }
        else {
            guard let amount = Double(amountText.replacingOccurrences(of: ",", with: ".")),
                  amount.isFinite, amount > 0, amount <= 10_000 else {
                throw NutritionEntryValidationError.portionInvalid
            }
            portion = NutritionPortion(amount: amount, unit: portionUnit, certainty: portionCertainty)
        }
        // An edit to one source field must not normalize untouched record IDs
        // or revisions from a lossless import.
        func sourceText(_ text: String, original: String?) -> String? {
            text == (original ?? "") ? original : Self.optionalText(text)
        }
        let priorSource = originalEntry?.foodEvidence?.source
        let name = sourceText(sourceName, original: priorSource?.name)
        let recordID = sourceText(sourceRecordID, original: priorSource?.recordID)
        let revision = sourceText(sourceRevision, original: priorSource?.revision)
        let source: NutritionSourceReference?
        if let name { source = NutritionSourceReference(name: name, recordID: recordID, revision: revision) }
        else {
            guard recordID == nil, revision == nil else { throw NutritionEntryValidationError.sourceInvalid }
            source = nil
        }
        let evidence = NutritionFoodEvidence(origin: valueOrigin, valueBasis: valueBasis,
            portion: portion, source: source, referenceValues: valueBasis == .consumedPortion ? nil : input)
        guard evidence.isStructurallyValid else { throw NutritionEntryValidationError.foodEvidenceInvalid }
        let computed = valueBasis == .consumedPortion ? input : try evidence.consumedValues()
        let consumed: NutritionNutrientValues
        if let original = originalEntry, let previous = original.foodEvidence,
           previous.valueBasis == valueBasis,
           previous.portion?.amount == portion?.amount, previous.portion?.unit == portion?.unit,
           (previous.referenceValues ?? NutritionNutrientValues(original)) == input {
            // Title/source/certainty-only corrections retain accepted raw totals,
            // including valid floating-point round-trip differences on import.
            consumed = NutritionNutrientValues(original)
        } else { consumed = computed }
        guard evidence.isValid(for: consumed) else { throw NutritionEntryValidationError.foodEvidenceInvalid }
        // With no source or portion facts, absence remains unknown for old
        // and newly entered records alike. Do not invent manual verification.
        let retainedUnknown = originalEntry?.foodEvidence == nil
            && valueOrigin == .unknown && valueBasis == .consumedPortion && portion == nil && source == nil
        return NutritionEntry(id: id, title: normalizedTitle, calories: consumed.calories,
            proteinGrams: consumed.proteinGrams, carbohydrateGrams: consumed.carbohydrateGrams,
            fatGrams: consumed.fatGrams, loggedAt: loggedAt,
            foodEvidence: retainedUnknown ? nil : evidence)
    }

    private func parsedMacro(_ text: String, field: String) throws -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        guard let value = Double(normalized), value.isFinite, (0 ... 1_000).contains(value) else {
            throw NutritionEntryValidationError.macroInvalid(field)
        }
        return value
    }

    private static func optionalText(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func string(_ value: Double?) -> String {
        // Round-trip storage precision; display formatting belongs in the view.
        value.map { String($0) } ?? ""
    }
}

enum NutritionEntryValidationError: LocalizedError, Equatable {
    case titleRequired
    case titleTooLong
    case caloriesRequired
    case caloriesInvalid
    case macroInvalid(String)
    case entryNotFound
    case entryChanged
    case portionInvalid, sourceInvalid, foodEvidenceInvalid
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .titleRequired:
            "Add a short name for this entry."
        case .titleTooLong:
            "Use a shorter food name before saving."
        case .caloriesRequired:
            "Add calories before saving."
        case .caloriesInvalid:
            "Calories must be a whole number between 0 and 10,000."
        case let .macroInvalid(field):
            "\(field) must be a number from 0 to 1,000 grams."
        case .entryNotFound:
            "This entry is no longer available to edit."
        case .entryChanged:
            "This food entry changed while you were editing. Reopen it before correcting it."
        case .portionInvalid:
            "Enter a portion greater than zero and no more than 10,000."
        case .sourceInvalid:
            "Add a source name before its record or revision."
        case .foodEvidenceInvalid:
            "Check the source, value basis and portion. Keep grams, milliliters and servings separate."
        case .saveFailed:
            "Saving could not be confirmed. Check your saved meal records before trying again."
        }
    }
}

enum NutritionAvailability: Equatable {
    case available
    case unavailable
}

protocol NutritionPersisting {
    var isAvailable: Bool { get }
    func load() -> [NutritionEntry]
    func save(_ entries: [NutritionEntry])
    func loadVerified() throws -> [NutritionEntry]
}

extension NutritionPersisting {
    var isAvailable: Bool { true }
    func loadVerified() throws -> [NutritionEntry] {
        guard isAvailable else { throw NutritionEntryValidationError.saveFailed }
        let loaded = load()
        guard isAvailable else { throw NutritionEntryValidationError.saveFailed }
        return loaded
    }
}

struct UserDefaultsNutritionStore: NutritionPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.nutritionEntries") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [NutritionEntry] {
        (try? loadVerified()) ?? []
    }

    func loadVerified() throws -> [NutritionEntry] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data else { throw NutritionEntryValidationError.saveFailed }
        try FoodBodyWeightImportDecoder.validateStoredMealSyntax(data)
        let entries: [NutritionEntry]
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            entries = try JSONDecoder().decode([NutritionEntry].self, from: data)
        } else {
            let envelope = try JSONDecoder().decode(NutritionStorageEnvelope.self, from: data)
            guard envelope.schemaVersion == NutritionStorageEnvelope.currentSchemaVersion else {
                throw NutritionEntryValidationError.saveFailed
            }
            entries = envelope.entries
        }
        try FoodBodyWeightImportDecoder.validateMeals(entries)
        return entries
    }

    func save(_ entries: [NutritionEntry]) {
        // The legacy nonthrowing load method cannot signal decoding failures.
        // Never let its empty fallback authorize replacing an unreadable payload.
        guard (try? loadVerified()) != nil else { return }
        guard (try? FoodBodyWeightImportDecoder.validateMeals(entries)) != nil,
              let data = try? JSONEncoder().encode(NutritionStorageEnvelope(entries: entries)) else { return }
        defaults.set(data, forKey: key)
    }

    var isAvailable: Bool {
        (try? loadVerified()) != nil
    }
}

/// Writing a versioned object rather than the old bare array prevents an older
/// binary from decoding then silently dropping the new provenance on a save.
/// Legacy arrays remain readable; loading never rewrites their original bytes.
private struct NutritionStorageEnvelope: Codable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let entries: [NutritionEntry]
    init(entries: [NutritionEntry]) {
        schemaVersion = Self.currentSchemaVersion; self.entries = entries
    }
}

@MainActor
@Observable
final class NutritionRepository {
    private(set) var entries: [NutritionEntry]
    private(set) var availability: NutritionAvailability
    private(set) var persistenceErrorMessage: String?
    private(set) var removalFailureMessage: String?

    private let store: any NutritionPersisting
    private let calendar: Calendar
    private let onConfirmedAddition: (NutritionEntry) -> Void
    private let onConfirmedRemoval: (UUID) -> Void

    init(
        store: any NutritionPersisting = UserDefaultsNutritionStore(),
        calendar: Calendar = .current,
        onConfirmedAddition: @escaping (NutritionEntry) -> Void = { _ in },
        onConfirmedRemoval: @escaping (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.calendar = calendar
        self.onConfirmedAddition = onConfirmedAddition
        self.onConfirmedRemoval = onConfirmedRemoval
        do {
            let loaded = try store.loadVerified()
            try FoodBodyWeightImportDecoder.validateMeals(loaded)
            entries = loaded.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
            availability = .available
        } catch {
            entries = []
            availability = .unavailable
        }
    }

    func entries(on date: Date = .now) -> [NutritionEntry] {
        entries.filter { calendar.isDate($0.loggedAt, inSameDayAs: date) }
    }

    /// Legacy numeric subtotals of known values. A zero here is not evidence
    /// of zero intake. Use macroSummary for display and dietary decisions.
    func totals(on date: Date = .now) -> NutritionDailyTotals {
        entries(on: date).reduce(into: .zero) { totals, entry in
            totals = NutritionDailyTotals(
                calories: totals.calories + entry.calories,
                proteinGrams: totals.proteinGrams + (entry.proteinGrams ?? 0),
                carbohydrateGrams: totals.carbohydrateGrams + (entry.carbohydrateGrams ?? 0),
                fatGrams: totals.fatGrams + (entry.fatGrams ?? 0)
            )
        }
    }

    @discardableResult
    func add(_ draft: NutritionEntryDraft, at date: Date = .now) throws -> NutritionEntry {
        guard availability == .available else {
            throw NutritionEntryValidationError.entryNotFound
        }
        let entry = try draft.validatedEntry(loggedAt: date)
        try saveVerified([entry] + entries)
        onConfirmedAddition(entry)
        return entry
    }

    @discardableResult
    func update(id: UUID, with draft: NutritionEntryDraft) throws -> NutritionEntry {
        guard availability == .available,
              let index = entries.firstIndex(where: { $0.id == id }) else {
            throw NutritionEntryValidationError.entryNotFound
        }
        let existing = entries[index]
        let replacement = try draft.validatedEntry(id: existing.id, loggedAt: existing.loggedAt)
        guard draft.originalEntry == existing else { throw NutritionEntryValidationError.entryChanged }
        var candidate = entries
        candidate[index] = replacement
        try saveVerified(candidate)
        return replacement
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard availability == .available,
              entries.contains(where: { $0.id == id }) else { return false }
        do {
            try saveVerified(entries.filter { $0.id != id })
            removalFailureMessage = nil
            onConfirmedRemoval(id)
            return true
        } catch {
            removalFailureMessage = error.localizedDescription
            return false
        }
    }

    func dismissRemovalFailure() {
        removalFailureMessage = nil
    }

    func macroSummary(on date: Date = .now) -> NutritionLoggedMacroSummary? {
        guard availability == .available else { return nil }
        return NutritionLoggedMacroSummary(entries: entries(on: date))
    }

    /// A read-only recovery keeps the last readable collection on failure. Imported
    /// meals never invoke addition/removal callbacks or replay HealthKit writes.
    func readForImport() throws -> [NutritionEntry] {
        do {
            let loaded = try store.loadVerified()
            try FoodBodyWeightImportDecoder.validateMeals(loaded)
            entries = loaded.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
            availability = .available
            persistenceErrorMessage = nil
            return entries
        } catch {
            availability = .unavailable
            throw FoodBodyWeightImportError.storeUnavailable
        }
    }

    func importReviewed(_ candidate: [NutritionEntry], replacing baseline: [NutritionEntry]) throws {
        try FoodBodyWeightImportDecoder.validateMeals(candidate)
        guard try readForImport() == baseline else { throw FoodBodyWeightImportError.storeChanged }
        let byID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.id, $0) })
        guard baseline.allSatisfy({ byID[$0.id] == $0 }) else {
            throw FoodBodyWeightImportError.conflictingIdentifier
        }
        try saveVerified(candidate)
    }

    private func saveVerified(_ candidate: [NutritionEntry]) throws {
        // Ordinary additions and edits must meet the same bounds as readback.
        // Reject the proposal before any store write or availability change.
        try FoodBodyWeightImportDecoder.validateMeals(candidate)
        // Do not turn a failed optimistic mutation into an unrelated later save.
        // Keep published state at the last acknowledged store contents.
        guard store.isAvailable else {
            availability = .unavailable
            persistenceErrorMessage = NutritionEntryValidationError.saveFailed.localizedDescription
            throw NutritionEntryValidationError.saveFailed
        }
        // Prevent a stale published collection from overwriting another writer.
        let fresh: [NutritionEntry]
        do {
            fresh = try store.loadVerified().sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
            try FoodBodyWeightImportDecoder.validateMeals(fresh)
        } catch {
            availability = .unavailable
            throw NutritionEntryValidationError.saveFailed
        }
        guard fresh == entries.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst) else {
            entries = fresh
            throw NutritionEntryValidationError.saveFailed
        }
        store.save(candidate)
        let confirmed: [NutritionEntry]
        do {
            confirmed = try store.loadVerified()
            try FoodBodyWeightImportDecoder.validateMeals(confirmed)
        } catch {
            availability = .unavailable
            persistenceErrorMessage = NutritionEntryValidationError.saveFailed.localizedDescription
            throw NutritionEntryValidationError.saveFailed
        }
        guard confirmed.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
                == candidate.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst) else {
            // A rejected write with readable unchanged storage remains safely
            // retryable. A different readable collection becomes the fresh state.
            entries = confirmed.sorted(by: FoodBodyWeightImportDecoder.mealsNewestFirst)
            persistenceErrorMessage = NutritionEntryValidationError.saveFailed.localizedDescription
            throw NutritionEntryValidationError.saveFailed
        }
        entries = candidate
        persistenceErrorMessage = nil
    }
}
