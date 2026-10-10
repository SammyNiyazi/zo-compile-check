import Foundation

/// Barcode and product search against Open Food Facts (Open Database Licence).
/// Only the barcode, or the words typed into "Search products", is sent; nothing
/// about the person. The User-Agent names the app and a contact, as their API asks.
enum OpenFoodFactsLookup: Equatable, Sendable {
    case found(FoodItem)
    case notFound
    /// The product exists but has no energy value, which the design treats as not found.
    case missingCalories(name: String?)
}

enum OpenFoodFactsError: Error, Equatable {
    case invalidBarcode, offline, unavailable
}

struct OpenFoodFactsClient: Sendable {
    static let sourceName = "Open Food Facts"
    static let fields = "code,product_name,brands,quantity,serving_size,serving_quantity,product_quantity,product_quantity_unit,nutriments,last_modified_t"

    var session: URLSession = .shared
    var baseURL = URL(string: "https://world.openfoodfacts.org")!

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "01/\(version) (iOS; hello@the01.app)"
    }

    /// EAN-13, EAN-8, UPC-A and UPC-E, digits only.
    static func normalizedBarcode(_ text: String) -> String? {
        let digits = text.filter(\.isNumber)
        guard digits.count == text.filter({ !$0.isWhitespace }).count,
              [8, 12, 13].contains(digits.count) || digits.count == 6 || digits.count == 7 || digits.count == 14 else { return nil }
        return digits
    }

    func product(barcode raw: String) async throws -> OpenFoodFactsLookup {
        guard let barcode = Self.normalizedBarcode(raw) else { throw OpenFoodFactsError.invalidBarcode }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v2/product/\(barcode)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        let (data, response) = try await fetch(components.url!)
        if response.statusCode == 404 { return .notFound }
        guard (200 ..< 300).contains(response.statusCode) else { throw OpenFoodFactsError.unavailable }
        return try Self.parseProductResponse(data, barcode: barcode)
    }

    func search(_ text: String) async throws -> [FoodItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("cgi/search.pl"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: String(query.prefix(80))),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        let (data, response) = try await fetch(components.url!)
        guard (200 ..< 300).contains(response.statusCode) else { throw OpenFoodFactsError.unavailable }
        return try Self.parseSearchResponse(data)
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenFoodFactsError.unavailable }
            return (data, http)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                             .cannotConnectToHost, .dataNotAllowed].contains(error.code) {
            throw OpenFoodFactsError.offline
        } catch let error as OpenFoodFactsError {
            throw error
        } catch {
            throw OpenFoodFactsError.unavailable
        }
    }

    // MARK: Parsing (pure, tested)

    static func parseProductResponse(_ data: Data, barcode: String) throws -> OpenFoodFactsLookup {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenFoodFactsError.unavailable
        }
        guard number(root["status"]) == 1, let product = root["product"] as? [String: Any] else { return .notFound }
        return lookup(product, barcode: barcode)
    }

    static func parseSearchResponse(_ data: Data) throws -> [FoodItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { throw OpenFoodFactsError.unavailable }
        return products.compactMap { product in
            guard let code = product["code"] as? String, let barcode = normalizedBarcode(code),
                  case let .found(item) = lookup(product, barcode: barcode) else { return nil }
            return item
        }
    }

    static func lookup(_ product: [String: Any], barcode: String) -> OpenFoodFactsLookup {
        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Double? {
            number(nutriments[key + "_100g"]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        let kcal = value("energy-kcal") ?? value("energy").map { $0 / 4.184 }
        guard let kcal, kcal <= 1_000, let name, !name.isEmpty else {
            return .missingCalories(name: name?.isEmpty == false ? name : nil)
        }
        let quantity = (product["quantity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (product["product_quantity_unit"] as? String)?.lowercased()
        let isLiquid = unit == "ml" || unit == "l" || quantity.map(isVolume) == true
        let basis: NutritionValueBasis = isLiquid ? .per100Milliliters : .per100Grams
        let symbol = isLiquid ? "ml" : "g"
        let values = FoodNutrients(calories: kcal, protein: value("proteins"), carbohydrate: value("carbohydrates"),
            fat: value("fat"), fibre: value("fiber"), sugars: value("sugars"), salt: value("salt"),
            saturates: value("saturated-fat"))
        var portions: [FoodPortionOption] = []
        func format(_ amount: Double) -> String { amount.formatted(.number.precision(.fractionLength(0 ... 1))) + " " + symbol }
        if let serving = number(product["serving_quantity"]), serving > 0, serving <= 5_000 {
            portions.append(FoodPortionOption(label: format(serving), amount: serving))
        }
        if let package = number(product["product_quantity"]), package > 0, package <= 10_000,
           !portions.contains(where: { $0.amount == package }) {
            portions.append(FoodPortionOption(label: "whole:" + format(package), amount: package))
        }
        if !portions.contains(where: { $0.amount == 100 }) {
            portions.append(FoodPortionOption(label: format(100), amount: 100))
        }
        let brand = (product["brands"] as? String)?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let detail = [quantity, Self.spacedBarcode(barcode)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        let revision = number(product["last_modified_t"]).map { String(Int($0)) }
        let item = FoodItem(id: "off:\(barcode)", kind: .product,
            name: brand.map { name.localizedCaseInsensitiveContains($0) ? name : name + ", " + $0 } ?? name,
            detail: detail.isEmpty ? nil : detail, basis: basis, values: values, portions: portions,
            defaultPortion: 0, origin: .databaseReported, sourceName: sourceName, recordID: barcode,
            revision: revision, barcode: barcode)
        return .found(item)
    }

    static func spacedBarcode(_ barcode: String) -> String {
        guard barcode.count == 13 else { return barcode }
        let digits = Array(barcode)
        return String(digits[0]) + " " + String(digits[1 ..< 7]) + " " + String(digits[7...])
    }

    private static func isVolume(_ quantity: String) -> Bool {
        let lower = quantity.lowercased()
        return lower.range(of: #"\d\s*(ml|cl|dl|l)\b"#, options: .regularExpression) != nil
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }
}
