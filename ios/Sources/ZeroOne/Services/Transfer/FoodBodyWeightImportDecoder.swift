import Foundation

enum FoodBodyWeightImportDecoder {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumRecords = 100_000

    struct Source {
        let schemaVersion: Int
        let exportedAt: Date
        let meals: [NutritionEntry]
        let weights: [BodyWeightEntry]
        let skippedCategories: [String]
    }
    private struct Header: Decodable {
        let schemaVersion: Int
        let exportedAt: Date
        let selection: LocalDataExportSelection?
        let bodyWeightProvenance: String?
        let bodyWeightStoredUnit: String?
    }
    private struct Meals: Decodable { let meals: [NutritionEntry] }
    private struct Weight: Decodable {
        let id: UUID
        let recordedAt: Date
        let kilograms: String
        func entry() throws -> BodyWeightEntry {
            // Numeric lexemes are quoted before decoding so Decimal never
            // passes through binary Double. Reject precision we cannot retain.
            let mantissa = kilograms.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
            let digits = mantissa.filter(\.isNumber).drop(while: { $0 == "0" })
            let significant = String(digits).reversed().drop(while: { $0 == "0" }).count
            guard significant <= 38,
                  let value = Decimal(string: kilograms, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN else { throw FoodBodyWeightImportError.invalidRecords }
            return BodyWeightEntry(id: id, recordedAt: recordedAt, kilograms: value)
        }
    }

    static func decode(_ data: Data, category: FoodBodyWeightImportCategory) throws -> Source {
        guard data.count <= maximumFileBytes else { throw FoodBodyWeightImportError.oversizedFile }
        do {
            var syntax = ImportJSONSyntax(data: data)
            try syntax.validate()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FoodBodyWeightImportError.invalidFile
            }
            try allowed(object, ["schemaVersion", "exportedAt", "workoutHistoryProvenance", "bodyWeightProvenance",
                "bodyWeightStoredUnit", "completedWorkouts", "bodyWeightReadings", "selection", "meals",
                "waterSnapshot", "coverageNotes", "outdoorActivities", "goalsAndPreferences"])
            if let selection = object["selection"] as? [String: Any] {
                try allowed(selection, ["workouts", "mealsAndWater", "bodyWeight", "outdoorActivities", "routes", "goalsAndPreferences"])
            }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard (1...6).contains(header.schemaVersion) else { throw FoodBodyWeightImportError.unsupportedSchema }
            guard validDate(header.exportedAt), header.schemaVersion == 1 || header.selection != nil else {
                throw FoodBodyWeightImportError.invalidFile
            }
            let meals: [NutritionEntry]
            let weights: [BodyWeightEntry]
            switch category {
            case .meals:
                // Version one exports did not define meal selection/provenance.
                guard header.schemaVersion >= 2, header.selection?.mealsAndWater == true else {
                    throw FoodBodyWeightImportError.categoryNotSelected
                }
                guard let rows = object["meals"] as? [[String: Any]], rows.count <= maximumRecords else {
                    throw FoodBodyWeightImportError.invalidRecords
                }
                try rows.forEach { row in
                    try allowed(row, ["id", "title", "calories", "proteinGrams", "carbohydrateGrams", "fatGrams", "loggedAt", "foodEvidence"])
                    if let metadata = row["foodEvidence"], !(metadata is NSNull) {
                        guard header.schemaVersion >= 4 else { throw FoodBodyWeightImportError.invalidRecords }
                        try validateEvidenceObject(metadata)
                    }
                }
                meals = try JSONDecoder().decode(Meals.self, from: data).meals
                try validateMeals(meals, requireUniqueIDs: false)
                weights = []
            case .bodyWeight:
                guard header.selection?.bodyWeight != false,
                      header.bodyWeightProvenance == "app-owned local body weight records; original input source unknown",
                      header.bodyWeightStoredUnit == "kg" else {
                    throw FoodBodyWeightImportError.categoryNotSelected
                }
                guard let rows = object["bodyWeightReadings"] as? [[String: Any]], rows.count <= maximumRecords else {
                    throw FoodBodyWeightImportError.invalidRecords
                }
                try rows.forEach { try allowed($0, ["id", "recordedAt", "kilograms"]) }
                let selectedRows = try FoodBodyWeightNumericLexemes.weightRows(in: data)
                let exact = try FoodBodyWeightNumericLexemes.quoteKilograms(in: selectedRows)
                weights = try JSONDecoder().decode([Weight].self, from: exact).map { try $0.entry() }
                try validateWeights(weights, requireUniqueIDs: false)
                meals = []
            }
            var skipped: [String] = []
            if header.selection?.workouts == true || (object["completedWorkouts"] as? [Any])?.isEmpty == false {
                skipped.append("Workout history")
            }
            if category != .meals && (header.selection?.mealsAndWater == true || object["meals"] != nil) {
                skipped.append("Food records")
            }
            if header.selection?.mealsAndWater == true || object["waterSnapshot"] != nil {
                skipped.append("Water daily snapshot")
            }
            if category != .bodyWeight && (header.selection?.bodyWeight == true || (object["bodyWeightReadings"] as? [Any])?.isEmpty == false) {
                skipped.append("Body-weight readings")
            }
            if header.selection?.outdoorActivities == true || object["outdoorActivities"] != nil {
                skipped.append("Walks, runs and routes")
            }
            if header.selection?.goalsAndPreferences == true || object["goalsAndPreferences"] != nil {
                skipped.append("Goals and preferences")
            }
            return Source(schemaVersion: header.schemaVersion, exportedAt: header.exportedAt,
                meals: meals, weights: weights, skippedCategories: skipped)
        } catch let error as FoodBodyWeightImportError { throw error }
        catch let error as WorkoutHistoryImportError {
            throw error == .oversizedFile ? FoodBodyWeightImportError.oversizedFile : .invalidFile
        } catch { throw FoodBodyWeightImportError.invalidFile }
    }

    static func validateMeals(_ entries: [NutritionEntry], requireUniqueIDs: Bool = true) throws {
        guard entries.count <= maximumRecords,
              !requireUniqueIDs || Set(entries.map(\.id)).count == entries.count else {
            throw FoodBodyWeightImportError.invalidRecords
        }
        for entry in entries {
            guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.title.utf8.count <= 4_096, (0...10_000).contains(entry.calories), validDate(entry.loggedAt),
                  entry.foodEvidence.map({ $0.isValid(for: NutritionNutrientValues(entry)) }) ?? true,
                  [entry.proteinGrams, entry.carbohydrateGrams, entry.fatGrams].allSatisfy({
                      $0.map { $0.isFinite && (0...1_000).contains($0) } ?? true
                  }) else { throw FoodBodyWeightImportError.invalidRecords }
        }
    }

    /// Local storage uses the same lossless field boundaries as transfer. A
    /// future field or duplicate key cannot be decoded then silently discarded
    /// by a subsequent correction/save, even if its version was not advanced.
    static func validateStoredMealSyntax(_ data: Data) throws {
        var syntax = ImportJSONSyntax(data: data)
        try syntax.validate()
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] { rows = array }
        else {
            guard let envelope = object as? [String: Any],
                  let array = envelope["entries"] as? [[String: Any]] else {
                throw FoodBodyWeightImportError.invalidRecords
            }
            try allowed(envelope, ["schemaVersion", "entries"])
            rows = array
        }
        guard rows.count <= maximumRecords else { throw FoodBodyWeightImportError.invalidRecords }
        for row in rows {
            try allowed(row, ["id", "title", "calories", "proteinGrams", "carbohydrateGrams", "fatGrams", "loggedAt", "foodEvidence"])
            if let evidence = row["foodEvidence"], !(evidence is NSNull) {
                try validateEvidenceObject(evidence)
            }
        }
    }

    private static func validateEvidenceObject(_ value: Any) throws {
        guard let evidence = value as? [String: Any] else { throw FoodBodyWeightImportError.invalidRecords }
        try allowed(evidence, ["schemaVersion", "origin", "valueBasis", "portion", "source", "referenceValues"])
        for (key, fields) in [
            ("portion", Set(["amount", "unit", "certainty"])),
            ("source", Set(["name", "recordID", "revision"])),
            ("referenceValues", Set(["calories", "proteinGrams", "carbohydrateGrams", "fatGrams"]))
        ] {
            if let nested = evidence[key], !(nested is NSNull) {
                guard let object = nested as? [String: Any] else { throw FoodBodyWeightImportError.invalidRecords }
                try allowed(object, fields)
            }
        }
    }

    static func validateWeights(_ entries: [BodyWeightEntry], requireUniqueIDs: Bool = true) throws {
        guard entries.count <= maximumRecords,
              !requireUniqueIDs || Set(entries.map(\.id)).count == entries.count else {
            throw FoodBodyWeightImportError.invalidRecords
        }
        for entry in entries {
            guard !entry.kilograms.isNaN, entry.kilograms >= Decimal(string: "0.5")!,
                  entry.kilograms <= 1_000, validDate(entry.recordedAt) else {
                throw FoodBodyWeightImportError.invalidRecords
            }
        }
    }

    static func mealsNewestFirst(_ lhs: NutritionEntry, _ rhs: NutritionEntry) -> Bool {
        lhs.loggedAt == rhs.loggedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.loggedAt > rhs.loggedAt
    }
    static func weightsNewestFirst(_ lhs: BodyWeightEntry, _ rhs: BodyWeightEntry) -> Bool {
        lhs.recordedAt == rhs.recordedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.recordedAt > rhs.recordedAt
    }
    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.isFinite && (-62_000_000_000...100_000_000_000).contains(seconds)
    }
    private static func allowed(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys).isSubset(of: keys) else { throw FoodBodyWeightImportError.invalidRecords }
    }
}

/// Runs only after the bounded JSON syntax and Foundation grammar checks. It
/// preserves every original byte except quoting a numeric kilograms field. String
/// values for kilograms are rejected, even if they look numeric.
private enum FoodBodyWeightNumericLexemes {
    /// Select just the top-level weight array without Foundation numeric
    /// round-tripping, so unsupported categories never enter this decoder.
    static func weightRows(in data: Data) throws -> Data {
        let bytes = Array(data)
        var index = 0
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91: depth += 1; index += 1
            case 125, 93: depth -= 1; index += 1
            case 34:
                let start = index
                index = stringEnd(bytes, at: index)
                if depth != 1 { continue }
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                guard key == "bodyWeightReadings" else { continue }
                var cursor = index
                while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count, bytes[cursor] == 58 else { continue }
                cursor += 1
                while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count, bytes[cursor] == 91 else { throw FoodBodyWeightImportError.invalidRecords }
                let arrayStart = cursor
                var nested = 0
                while cursor < bytes.count {
                    switch bytes[cursor] {
                    case 34: cursor = stringEnd(bytes, at: cursor); continue
                    case 91, 123: nested += 1
                    case 93, 125: nested -= 1
                    default: break
                    }
                    cursor += 1
                    if nested == 0 { return Data(bytes[arrayStart..<cursor]) }
                }
                throw FoodBodyWeightImportError.invalidRecords
            default: index += 1
            }
        }
        throw FoodBodyWeightImportError.invalidRecords
    }

    private static func stringEnd(_ bytes: [UInt8], at start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { index += 1 }
            else if byte == 34 { return index }
        }
        return index // preflight has already rejected unterminated strings
    }

    static func quoteKilograms(in data: Data) throws -> Data {
        let bytes = Array(data)
        var output = Data()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 34 else { output.append(bytes[index]); index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { break }
            }
            let token = Data(bytes[start..<index])
            output.append(token)
            let text = try JSONDecoder().decode(String.self, from: token)
            guard text == "kilograms" else { continue }
            var cursor = index
            while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == 58 else { continue }
            cursor += 1
            while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == 45 || (48...57).contains(bytes[cursor]) else {
                throw FoodBodyWeightImportError.invalidRecords
            }
            output.append(contentsOf: bytes[index..<cursor])
            let numberStart = cursor
            while cursor < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
            output.append(34)
            output.append(contentsOf: bytes[numberStart..<cursor])
            output.append(34)
            index = cursor
        }
        return output
    }
}
