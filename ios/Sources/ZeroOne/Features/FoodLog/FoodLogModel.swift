import Foundation
import Observation

extension FoodLogModel: Identifiable {}

/// State for the Log food sheet (proof 54). Adds go through NutritionRepository,
/// so Health writes, exports and Undo behave like every other meal.
@MainActor
@Observable
final class FoodLogModel {
    enum SearchState: Equatable {
        case idle, searching, results([FoodItem]), offline, unavailable
    }

    var meal: FoodMeal
    var query = "" {
        didSet { if query != oldValue { productSearch = .idle } }
    }
    private(set) var productSearch: SearchState = .idle
    private(set) var myFoods: [FoodItem] = []
    private(set) var labels = FoodMealLabels()

    let nutrition: NutritionRepository
    private let store: FoodLogStore
    private let catalog: BasicFoodsCatalog
    private let client: OpenFoodFactsClient
    private let now: () -> Date
    private let calendar: Calendar
    private var searchTask: Task<Void, Never>?

    init(nutrition: NutritionRepository, store: FoodLogStore = FoodLogStore(),
         catalog: BasicFoodsCatalog = .shared, client: OpenFoodFactsClient = OpenFoodFactsClient(),
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.nutrition = nutrition
        self.store = store
        self.catalog = catalog
        self.client = client
        self.now = now
        self.calendar = calendar
        meal = FoodMeal.preset(for: now(), calendar: calendar)
        reload()
    }

    func reload() {
        myFoods = store.myFoods()
        labels = store.labels()
    }

    var recents: [FoodItem] { FoodRecents.items(from: nutrition.entries) }

    var yesterday: [NutritionEntry] {
        FoodRecents.sameAsYesterday(entries: nutrition.entries, meal: meal, now: now(), labels: labels, calendar: calendar)
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var myFoodMatches: [FoodItem] {
        let words = BasicFoodsCatalog.words(trimmedQuery)
        guard !words.isEmpty else { return [] }
        return myFoods.filter { item in
            let name = BasicFoodsCatalog.words(item.name)
            return words.allSatisfy { word in name.contains { $0.hasPrefix(word) } }
        }
    }

    var basicMatches: [FoodItem] { catalog.search(trimmedQuery) }

    func searchProducts() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        productSearch = .searching
        searchTask = Task { [client] in
            do {
                let items = try await client.search(text)
                guard !Task.isCancelled else { return }
                self.productSearch = .results(items)
            } catch OpenFoodFactsError.offline {
                guard !Task.isCancelled else { return }
                self.productSearch = .offline
            } catch {
                guard !Task.isCancelled else { return }
                self.productSearch = .unavailable
            }
        }
    }

    func lookUp(barcode: String) async -> Result<OpenFoodFactsLookup, OpenFoodFactsError> {
        guard let code = OpenFoodFactsClient.normalizedBarcode(barcode) else { return .failure(.invalidBarcode) }
        // A label the person saved for this barcode wins over the database.
        if let mine = myFoods.first(where: { $0.barcode == code }) { return .success(.found(mine)) }
        do {
            let result = try await client.product(barcode: code)
            if case let .found(item) = result { store.cacheProduct(item) }
            return .success(result)
        } catch let error as OpenFoodFactsError {
            // A product used before still adds without a connection.
            if error == .offline, let cached = store.cachedProduct(barcode: code) { return .success(.found(cached)) }
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }
    }

    /// Adds one food at an amount to the chosen meal. Returns the saved entry.
    @discardableResult
    func add(_ item: FoodItem, amount: Double, to meal: FoodMeal? = nil) throws -> NutritionEntry {
        let entry = try nutrition.add(item.draft(amount: amount), at: now())
        store.setMeal(meal ?? self.meal, for: entry.id)
        labels = store.labels()
        if item.kind == .product { store.cacheProduct(item) }
        return entry
    }

    /// "Add both" adds yesterday's items at yesterday's portions.
    func addYesterday() throws -> [NutritionEntry] {
        var added: [NutritionEntry] = []
        for entry in yesterday {
            guard let item = FoodItem(entry: entry) else { continue }
            added.append(try add(item, amount: item.defaultAmount))
        }
        return added
    }

    func quickAdd(calories: Int, name: String) throws -> NutritionEntry {
        var draft = NutritionEntryDraft()
        draft.title = name
        draft.calories = String(calories)
        let entry = try nutrition.add(draft, at: now())
        store.setMeal(meal, for: entry.id)
        labels = store.labels()
        return entry
    }

    func saveToMyFoods(_ item: FoodItem) {
        store.saveMyFood(item)
        myFoods = store.myFoods()
    }

    func undo(_ entries: [NutritionEntry]) -> Bool {
        var allRemoved = true
        for entry in entries where DietsPresentation.canUndoAddition(entry, current: nutrition.entries(on: entry.loggedAt)) {
            allRemoved = nutrition.remove(id: entry.id) && allRemoved
        }
        return allRemoved
    }

    /// Today's macro subtotals, for the "today so far" part of the portion bars.
    var todaySoFar: FoodNutrients {
        let totals = nutrition.totals(on: now())
        return FoodNutrients(calories: Double(totals.calories), protein: totals.proteinGrams,
            carbohydrate: totals.carbohydrateGrams, fat: totals.fatGrams)
    }
}
