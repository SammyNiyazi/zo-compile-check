import Foundation

/// Small on-device stores beside the meal records: meal labels, My foods and the
/// cache of looked-up products (so a second scan works offline). Nothing here
/// leaves the iPhone.
struct FoodLogStore {
    private let defaults: UserDefaults
    static let labelsKey = "zeroone.foodLog.mealLabels"
    static let myFoodsKey = "zeroone.foodLog.myFoods"
    static let productsKey = "zeroone.foodLog.productCache"
    static let maximumMyFoods = 500
    static let maximumCachedProducts = 300

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func labels() -> FoodMealLabels {
        decode(FoodMealLabels.self, Self.labelsKey) ?? FoodMealLabels()
    }

    func setMeal(_ meal: FoodMeal, for entryID: UUID) {
        var labels = labels()
        labels.byEntry[entryID] = meal
        encode(labels, Self.labelsKey)
    }

    /// Drops labels whose meal no longer exists, so the file never grows unbounded.
    func prune(keeping ids: Set<UUID>) {
        var labels = labels()
        let before = labels.byEntry.count
        labels.byEntry = labels.byEntry.filter { ids.contains($0.key) }
        if labels.byEntry.count != before { encode(labels, Self.labelsKey) }
    }

    func myFoods() -> [FoodItem] {
        decode([FoodItem].self, Self.myFoodsKey) ?? []
    }

    func saveMyFood(_ item: FoodItem) {
        var foods = myFoods().filter { $0.id != item.id }
        var saved = item
        saved.kind = .mine
        foods.insert(saved, at: 0)
        encode(Array(foods.prefix(Self.maximumMyFoods)), Self.myFoodsKey)
    }

    func removeMyFood(id: String) {
        encode(myFoods().filter { $0.id != id }, Self.myFoodsKey)
    }

    func cachedProduct(barcode: String) -> FoodItem? {
        decode([FoodItem].self, Self.productsKey)?.first { $0.barcode == barcode }
    }

    func cacheProduct(_ item: FoodItem) {
        guard let barcode = item.barcode else { return }
        var products = (decode([FoodItem].self, Self.productsKey) ?? []).filter { $0.barcode != barcode }
        products.insert(item, at: 0)
        encode(Array(products.prefix(Self.maximumCachedProducts)), Self.productsKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Basic foods from USDA FoodData Central (public domain): Foundation Foods
/// (April 2026) and SR Legacy (April 2018, without baby, fast and restaurant
/// foods), trimmed to energy, macros, fibre, sugars, salt, saturates and up to
/// five household portions. Values are per 100 g. Bundled, so search works offline.
final class BasicFoodsCatalog: @unchecked Sendable {
    static let shared = BasicFoodsCatalog()
    static let sourceName = "USDA FoodData Central"

    private struct File: Decodable {
        let v: Int
        let foods: [Row]
    }

    /// [fdcId, name, kcal, protein, carbs, fat, fibre, sugars, salt, saturates, [[label, grams]]]
    private struct Row: Decodable {
        let item: FoodItem
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(Int.self)
            let name = try c.decode(String.self)
            let kcal = try c.decode(Double.self)
            let values = FoodNutrients(calories: kcal, protein: try c.decodeIfPresent(Double.self),
                carbohydrate: try c.decodeIfPresent(Double.self), fat: try c.decodeIfPresent(Double.self),
                fibre: try c.decodeIfPresent(Double.self), sugars: try c.decodeIfPresent(Double.self),
                salt: try c.decodeIfPresent(Double.self), saturates: try c.decodeIfPresent(Double.self))
            var portionsContainer = try c.nestedUnkeyedContainer()
            var portions: [FoodPortionOption] = []
            while !portionsContainer.isAtEnd {
                var pair = try portionsContainer.nestedUnkeyedContainer()
                let label = try pair.decode(String.self)
                let grams = try pair.decode(Double.self)
                portions.append(FoodPortionOption(label: label + ", " + FoodItem.portionLabel(grams, basis: .per100Grams), amount: grams))
            }
            portions.append(FoodPortionOption(label: "100 g", amount: 100))
            item = FoodItem(id: "usda:\(id)", kind: .basic, name: name, detail: nil, basis: .per100Grams,
                values: values, portions: portions, defaultPortion: 0, origin: .databaseReported,
                sourceName: BasicFoodsCatalog.sourceName, recordID: String(id), revision: nil)
        }
    }

    private let lock = NSLock()
    private var loaded: [(item: FoodItem, words: [String])]?
    private let bundle: Bundle
    private let resource: String

    init(bundle: Bundle = .main, resource: String = "USDABasicFoods") {
        self.bundle = bundle
        self.resource = resource
    }

    init(items: [FoodItem]) {
        bundle = .main
        resource = ""
        loaded = items.map { ($0, Self.words($0.name)) }
    }

    var foods: [FoodItem] { indexed.map(\.item) }

    private var indexed: [(item: FoodItem, words: [String])] {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let file = try? JSONDecoder().decode(File.self, from: data), file.v == 1 else {
            loaded = []
            return []
        }
        let index = file.foods.map { ($0.item, Self.words($0.item.name)) }
        loaded = index
        return index
    }

    /// Every word must match the start of a word in the name. Raw foods and
    /// shorter names rank first, so "banana" finds "Bananas, raw" before chips.
    func search(_ query: String, limit: Int = 25) -> [FoodItem] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        var scored: [(Int, FoodItem)] = []
        for (item, nameWords) in indexed {
            guard words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) else { continue }
            var score = item.name.count
            if let first = nameWords.first, first.hasPrefix(words[0]) { score -= 40 }
            if nameWords.contains("raw") { score -= 15 }
            scored.append((score, item))
        }
        return scored.sorted { $0.0 == $1.0 ? $0.1.name < $1.1.name : $0.0 < $1.0 }.prefix(limit).map(\.1)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
