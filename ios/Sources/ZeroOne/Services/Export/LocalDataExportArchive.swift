import CoreFoundation
import Foundation

enum LocalDataExportArchiveError: Error {
    case invalidSnapshot, invalidFilename, archiveUnavailable, cleanupFailed
}

/// Creates the spreadsheet representation from the already-selected snapshot.
/// This never rereads live stores or widens the user's selection.
enum LocalDataExportFiles {
    static func make(from json: Data) throws -> [String: Data] {
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: json)
        guard package.schemaVersion == LocalDataExportPackage.currentSchemaVersion,
              let selection = package.selection, selection.hasSelection,
              selection.workouts || package.completedWorkouts.isEmpty,
              selection.bodyWeight || package.bodyWeightReadings.isEmpty,
              selection.mealsAndWater || (package.meals == nil && package.waterSnapshot == nil),
              selection.outdoorActivities || package.outdoorActivities == nil,
              selection.goalsAndPreferences || package.goalsAndPreferences == nil,
              !selection.routes || selection.outdoorActivities,
              selection.routes || (package.outdoorActivities ?? []).allSatisfy({ $0.routeSegments == nil }) else {
            throw LocalDataExportArchiveError.invalidSnapshot
        }
        var files = ["snapshot.json": json]
        if selection.workouts {
            do { _ = try WorkoutHistoryImportDecoder.decode(json) }
            catch { throw LocalDataExportArchiveError.invalidSnapshot }
            var workouts = [[String: Any]](), exercises = [[String: Any]](), sets = [[String: Any]]()
            for workout in package.completedWorkouts {
                var row = try object(workout)
                row.removeValue(forKey: "exercises")
                row["exerciseDetailsRecorded"] = workout.exercises != nil
                workouts.append(row)
                for (exerciseIndex, exercise) in (workout.exercises ?? []).enumerated() {
                    var exerciseRow = try object(exercise)
                    exerciseRow.removeValue(forKey: "completedSets")
                    exerciseRow["workoutID"] = workout.id.uuidString
                    exerciseRow["exerciseOrder"] = exerciseIndex + 1
                    exercises.append(exerciseRow)
                    for (setIndex, set) in exercise.completedSets.enumerated() {
                        var setRow = try object(set)
                        setRow["workoutID"] = workout.id.uuidString
                        setRow["exerciseOccurrenceID"] = exercise.id.uuidString
                        setRow["exerciseOrder"] = exerciseIndex + 1
                        setRow["setOrder"] = setIndex + 1
                        sets.append(setRow)
                    }
                }
            }
            files["workouts.csv"] = try csv(workouts, minimumColumns: ["id", "title", "completedAt", "exerciseDetailsRecorded"])
            files["exercises.csv"] = try csv(exercises, minimumColumns: ["workoutID", "id", "exerciseID", "exerciseOrder"])
            files["sets.csv"] = try csv(sets, minimumColumns: ["workoutID", "exerciseOccurrenceID", "id", "setOrder", "load.value", "load.unit", "reps", "durationSeconds", "isPerSide", "rir"])
        }
        if selection.mealsAndWater {
            files["meals.csv"] = try csv((package.meals ?? []).map { try object($0) },
                minimumColumns: ["id", "title", "loggedAt", "calories", "proteinGrams", "carbohydrateGrams", "fatGrams"])
            files["water.csv"] = try csv(package.waterSnapshot.map { [try object($0)] } ?? [],
                minimumColumns: ["date", "currentMilliliters", "goalMilliliters", "dayStart"])
        }
        if selection.bodyWeight {
            files["body-weight.csv"] = try csv(package.bodyWeightReadings.map { try object($0) },
                minimumColumns: ["id", "recordedAt", "kilograms"])
        }
        if selection.outdoorActivities {
            var rows = [[String: Any]]()
            for activity in package.outdoorActivities ?? [] {
                var row = try object(activity)
                row.removeValue(forKey: "routeSegments")
                rows.append(row)
            }
            files["walks-runs.csv"] = try csv(rows, minimumColumns: ["id", "kind", "startedAt", "finishedAt",
                "confirmedActiveSeconds", "recordedDistanceMeters", "recordedSteps", "routeStatus"])
            if selection.routes, let gpx = gpx(package.outdoorActivities ?? []) {
                files["routes.gpx"] = Data(gpx.utf8)
            }
        }
        if selection.goalsAndPreferences {
            files["goals-preferences.csv"] = try csv(package.goalsAndPreferences.map { [try object($0)] } ?? [],
                minimumColumns: ["dailyGoals.steps", "dailyGoals.foodKilocalories", "appearancePreference"])
        }
        let notes = (package.coverageNotes ?? []).joined(separator: "\n")
        files["README.txt"] = Data("""
        01 personal data export
        Private, unencrypted files. No automatic upload.
        Review snapshot.json in 01 to import workout history, meals or body-weight readings, one category at a time. Complete outdoor history uses a separate transfer under Your data. This general export cannot restore outdoor activities or routes. ZIP, CSV, water and settings cannot be restored.
        \(notes)

        CSV is UTF-8, comma-separated, with quoted fields and CRLF rows.
        Blank cells mean absent/unknown, not zero. Empty selected tables retain headers.
        Dates in CSV and GPX use UTC ISO 8601 with millisecond precision.
        Nested objects use dotted columns; arrays remain JSON inside a cell.
        Workouts, exercise occurrences and sets join by IDs; explicit order columns preserve order.
        Formula-like text is prefixed with an apostrophe for spreadsheet safety.
        snapshot.json retains the original selected values, exact date encodings and text.
        Body weight remains kilograms; set loads retain each recorded unit.
        Route gaps remain separate GPX track segments. No elevation, speed or missing points are invented.
        A missing routes.gpx means no coordinates were selected or available in this snapshot.
        """.utf8)
        return files
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let dateFormatter = timestampFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        guard let dictionary = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] else {
            throw LocalDataExportArchiveError.invalidSnapshot
        }
        return dictionary
    }

    private static func flatten(_ row: [String: Any], prefix: String = "") throws -> [String: String] {
        var result = [String: String]()
        for (key, value) in row {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                result.merge(try flatten(nested, prefix: path)) { _, new in new }
            } else if let text = value as? String {
                let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
                result[path] = first.map { "=+-@".contains($0) } == true ? "'" + text : text
            } else if let number = value as? NSNumber {
                result[path] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false") : number.stringValue
            } else if value is NSNull { result[path] = "null" }
            else {
                result[path] = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            }
        }
        return result
    }

    private static func csv(_ rows: [[String: Any]], minimumColumns: [String]) throws -> Data {
        let flattened = try rows.map { try flatten($0) }
        let columns = Set(minimumColumns + flattened.flatMap { Array($0.keys) }).sorted()
        func line(_ values: [String]) -> String {
            values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        return Data(([line(columns)] + flattened.map { row in line(columns.map { row[$0] ?? "" }) })
            .joined(separator: "\r\n").appending("\r\n").utf8)
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func gpx(_ activities: [OutdoorActivityExport]) -> String? {
        var tracks = [String]()
        let dateFormatter = timestampFormatter()
        for activity in activities {
            guard let segments = activity.routeSegments, !segments.isEmpty else { continue }
            var track = "<trk><name>\(activity.kind.rawValue) \(activity.id.uuidString)</name>"
            for segment in segments {
                track += "<trkseg>"
                for point in segment.points {
                    track += "<trkpt lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\"><time>\(dateFormatter.string(from: point.timestamp))</time></trkpt>"
                }
                track += "</trkseg>"
            }
            tracks.append(track + "</trk>")
        }
        guard !tracks.isEmpty else { return nil }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx xmlns=\"http://www.topografix.com/GPX/1/1\" version=\"1.1\" creator=\"01\">"
            + tracks.joined() + "</gpx>"
    }

    /// GPX uses xsd:decimal, not scientific notation. Expand Swift's shortest
    /// round-tripping representation instead of rounding to fixed decimal places.
    static func coordinate(_ value: Double) -> String {
        let raw = String(value)
        let components = raw.lowercased().split(separator: "e")
        guard components.count == 2, let exponent = Int(components[1]) else { return raw }
        let sign = components[0].hasPrefix("-") ? "-" : ""
        let mantissa = String(components[0].filter { $0 != "-" && $0 != "+" })
        let wholeCount = mantissa.prefix { $0 != "." }.count
        let digits = mantissa.filter { $0 != "." }
        let position = wholeCount + exponent
        if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + digits }
        if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: position)
        return sign + String(digits[..<split]) + "." + String(digits[split...])
    }
}

enum LocalDataExportArchive {
    /// Call off the main actor. The system produces the ZIP snapshot; no network
    /// operation occurs despite the Foundation option's `forUploading` name.
    static func make(from json: Data, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> Data {
        try Task.checkCancellation()
        let files = try LocalDataExportFiles.make(from: json)
        let manager = FileManager.default
        var root = temporaryDirectory.appendingPathComponent("01-export-\(UUID().uuidString)", isDirectory: true)
        var createdStagingDirectory = false
        let result: Result<Data, Error>
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete])
            createdStagingDirectory = true
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            for (name, data) in files {
                try Task.checkCancellation()
                guard name == (name as NSString).lastPathComponent, !name.contains("/"), !name.contains("\\") else {
                    throw LocalDataExportArchiveError.invalidFilename
                }
                try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            }
            var coordinationError: NSError?
            var snapshot: Result<Data, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: root, options: .forUploading, error: &coordinationError) { url in
                snapshot = Result { try Data(contentsOf: url) }
            }
            if let coordinationError { throw coordinationError }
            guard let snapshot else { throw LocalDataExportArchiveError.archiveUnavailable }
            let data = try snapshot.get()
            guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw LocalDataExportArchiveError.archiveUnavailable }
            result = .success(data)
        } catch { result = .failure(error) }
        // Only this operation's generated UUID directory, never a shared data root.
        do {
            if createdStagingDirectory { try manager.removeItem(at: root) }
        } catch { throw LocalDataExportArchiveError.cleanupFailed }
        return try result.get()
    }
}
