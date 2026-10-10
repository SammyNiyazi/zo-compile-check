import CoreGraphics
import Foundation

/// Reads a nutrition table from recognised text (Vision on the iPhone). The photo
/// never leaves the phone; this only turns lines into per-100 values and marks the
/// ones read with low confidence, which the Check screen badges until confirmed.
struct NutritionLabelToken: Equatable, Sendable {
    var text: String
    /// Normalised, origin top left.
    var box: CGRect
    var confidence: Float
}

enum NutritionLabelField: String, CaseIterable, Codable, Hashable, Sendable {
    case energy, fat, saturates, carbohydrate, sugars, fibre, protein, salt

    var title: String {
        switch self {
        case .energy: "Energy"
        case .fat: "Fat"
        case .saturates: "of which saturates"
        case .carbohydrate: "Carbohydrate"
        case .sugars: "of which sugars"
        case .fibre: "Fibre"
        case .protein: "Protein"
        case .salt: "Salt"
        }
    }

    var unit: String { self == .energy ? "kcal" : "g" }

    /// Checked in this order, so "of which saturates" is never read as fat and
    /// "of which sugars" never as carbohydrate.
    fileprivate static let matchOrder: [NutritionLabelField] = [.saturates, .sugars, .energy, .fat, .carbohydrate, .fibre, .protein, .salt]

    fileprivate var keywords: [String] {
        switch self {
        case .energy: ["energy", "energie", "energia", "енергия", "енергийна"]
        case .fat: ["fat", "fats", "fett", "мазнини"]
        case .saturates: ["saturates", "saturated", "наситени"]
        case .carbohydrate: ["carbohydrate", "carbohydrates", "carbs", "въглехидрати"]
        case .sugars: ["sugars", "sugar", "захари"]
        case .fibre: ["fibre", "fiber", "fibres", "влакнини", "фибри"]
        case .protein: ["protein", "proteins", "белтъци", "протеини"]
        case .salt: ["salt", "сол"]
        }
    }

    /// Folded like the label words ("й" becomes "и"), so both sides compare equal.
    fileprivate var foldedKeywords: [String] { keywords.compactMap { BasicFoodsCatalog.words($0).first } }
}

struct NutritionLabelReading: Equatable, Sendable {
    var values: [NutritionLabelField: Double] = [:]
    var lowConfidence: Set<NutritionLabelField> = []
    var isPer100Milliliters = false
    /// "1 bar (45 g)" style portion printed on the label, when it is not 100.
    var portionAmount: Double?

    var foundCount: Int { values.count }
    static let fieldCount = NutritionLabelField.allCases.count
}

enum NutritionLabelParser {
    static let lowConfidenceThreshold: Float = 0.5

    /// Vision returns name and value as separate boxes; join boxes that share a row.
    static func rows(_ tokens: [NutritionLabelToken]) -> [(text: String, confidence: Float)] {
        let sorted = tokens.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.box.midY < $1.box.midY }
        var rows: [[NutritionLabelToken]] = []
        for token in sorted {
            if let last = rows.last, let reference = last.first,
               abs(token.box.midY - reference.box.midY) < max(reference.box.height, token.box.height) * 0.5 {
                rows[rows.count - 1].append(token)
            } else {
                rows.append([token])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            return (ordered.map(\.text).joined(separator: " "), ordered.map(\.confidence).min() ?? 0)
        }
    }

    static func parse(_ tokens: [NutritionLabelToken]) -> NutritionLabelReading {
        parse(lines: rows(tokens))
    }

    static func parse(lines: [(text: String, confidence: Float)]) -> NutritionLabelReading {
        var reading = NutritionLabelReading()
        for line in lines {
            let lower = line.text.lowercased()
            if lower.range(of: #"100\s*ml"#, options: .regularExpression) != nil { reading.isPer100Milliliters = true }
            if reading.portionAmount == nil, let portion = portion(in: lower) { reading.portionAmount = portion }
            let words = BasicFoodsCatalog.words(lower)
            guard let field = NutritionLabelField.matchOrder.first(where: { field in
                      field.foldedKeywords.contains { words.contains($0) }
                  }), reading.values[field] == nil,
                  let value = value(for: field, in: lower) else { continue }
            reading.values[field] = value
            if line.confidence < lowConfidenceThreshold { reading.lowConfidence.insert(field) }
        }
        return reading
    }

    private static let numberPattern = #"(\d+(?:[.,]\d+)?)\s*(kcal|kj|mg|g)?"#

    private static func numbers(in text: String) -> [(value: Double, unit: String?)] {
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let unit = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            return (value, unit)
        }
    }

    static func value(for field: NutritionLabelField, in line: String) -> Double? {
        // Ignore the "100 g" of a "per 100 g" heading folded into the row.
        let candidates = numbers(in: line).filter { !($0.value == 100 && $0.unit == "g" && line.contains("per")) }
        guard !candidates.isEmpty else { return nil }
        if field == .energy {
            if let kcal = candidates.first(where: { $0.unit == "kcal" }) { return kcal.value }
            if candidates.count >= 2, line.contains("kcal") {
                return candidates.prefix(2).map(\.value).min()
            }
            if let kj = candidates.first(where: { $0.unit == "kj" }) { return (kj.value / 4.184).rounded() }
            return line.contains("kj") ? (candidates[0].value / 4.184).rounded() : candidates[0].value
        }
        let first = candidates[0]
        let grams = first.unit == "mg" ? first.value / 1_000 : first.value
        return grams <= 100 ? grams : nil
    }

    private static func portion(in line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\((\d+(?:[.,]\d+)?)\s*(g|ml)\)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              let value = Double(line[range].replacingOccurrences(of: ",", with: ".")),
              value > 0, value != 100, value <= 2_000 else { return nil }
        return value
    }
}
