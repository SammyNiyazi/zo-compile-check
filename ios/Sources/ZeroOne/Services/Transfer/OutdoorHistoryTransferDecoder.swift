import Foundation

enum OutdoorHistoryTransferDecoder {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumRecords = 10_000
    static let maximumPoints = 100_000
    static let maximumPointsPerRecord = 10_000
    static let maximumIntervals = 100_000

    static func decode(_ data: Data) throws -> OutdoorHistoryTransferPackage {
        do {
            let raw = try rawJSON(data)
            guard let object = raw as? [String: Any], object["format"] as? String == OutdoorHistoryTransferPackage.formatName else {
                throw OutdoorHistoryTransferError.invalidFile
            }
            try allowed(object, ["format", "schemaVersion", "exportedAt", "routePolicy", "records"])
            guard let rows = object["records"] as? [[String: Any]] else { throw OutdoorHistoryTransferError.invalidRecords }
            try validateRawRows(rows)
            let package = try JSONDecoder().decode(OutdoorHistoryTransferPackage.self, from: data)
            try validate(package)
            return package
        } catch let error as OutdoorHistoryTransferError { throw error }
        catch { throw OutdoorHistoryTransferError.invalidFile }
    }

    static func encode(_ package: OutdoorHistoryTransferPackage) throws -> Data {
        try validate(package)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(package)
        guard try decode(data) == package else { throw OutdoorHistoryTransferError.invalidRecords }
        return data
    }

    static func decodeStoredRecords(_ data: Data) throws -> [OutdoorActivityRecord] {
        guard let rows = try rawJSON(data) as? [[String: Any]] else { throw OutdoorHistoryTransferError.invalidRecords }
        try validateRawRows(rows)
        let records = try JSONDecoder().decode([OutdoorActivityRecord].self, from: data)
        try validateRecords(records, requireUniqueIDs: true)
        return records
    }

    static func validate(_ package: OutdoorHistoryTransferPackage) throws {
        guard package.format == OutdoorHistoryTransferPackage.formatName,
              package.routePolicy == OutdoorHistoryTransferPackage.fullRoutePolicy else { throw OutdoorHistoryTransferError.invalidFile }
        guard package.schemaVersion == OutdoorHistoryTransferPackage.currentSchemaVersion else { throw OutdoorHistoryTransferError.unsupportedSchema }
        guard validDate(package.exportedAt) else { throw OutdoorHistoryTransferError.invalidRecords }
        try validateRecords(package.records, requireUniqueIDs: false)
    }

    static func validateRecords(_ records: [OutdoorActivityRecord], requireUniqueIDs: Bool) throws {
        guard records.count <= maximumRecords,
              !requireUniqueIDs || Set(records.map(\.id)).count == records.count else { throw OutdoorHistoryTransferError.invalidRecords }
        var points = 0
        var intervals = 0
        for record in records {
            guard validDate(record.startedAt), validDate(record.finishedAt),
                  record.routeDeletedAt.map(validDate) ?? true,
                  record.steps.intervals.count <= 1_000,
                  intervals <= maximumIntervals - record.steps.intervals.count else { throw OutdoorHistoryTransferError.invalidRecords }
            intervals += record.steps.intervals.count
            for interval in record.steps.intervals {
                guard validDate(interval.startedAt), interval.endedAt.map(validDate) ?? true,
                      interval.lastSampleAt.map(validDate) ?? true else { throw OutdoorHistoryTransferError.invalidRecords }
            }
            var recordPoints = 0
            if let route = record.route {
                guard route.segments.count <= 1_000 else { throw OutdoorHistoryTransferError.invalidRecords }
                for segment in route.segments {
                    guard segment.points.count <= maximumPointsPerRecord,
                          recordPoints <= maximumPointsPerRecord - segment.points.count,
                          points <= maximumPoints - segment.points.count else { throw OutdoorHistoryTransferError.invalidRecords }
                    recordPoints += segment.points.count
                    points += segment.points.count
                    guard segment.points.allSatisfy({ validDate($0.timestamp) }) else { throw OutdoorHistoryTransferError.invalidRecords }
                }
            }
            // Reuse the current domain integrity audit. No accumulator is replayed
            // and no recorded distance, steps, flags or geometry are rewritten.
            guard record.isValid else { throw OutdoorHistoryTransferError.invalidRecords }
        }
    }

    private static func rawJSON(_ data: Data) throws -> Any {
        guard data.count <= maximumFileBytes else { throw OutdoorHistoryTransferError.oversizedFile }
        do {
            var syntax = ImportJSONSyntax(data: data)
            try syntax.validate()
            return try JSONSerialization.jsonObject(with: data)
        } catch { throw OutdoorHistoryTransferError.invalidFile }
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.isFinite && (-62_000_000_000...100_000_000_000).contains(seconds)
    }
    private static func allowed(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys).isSubset(of: keys) else { throw OutdoorHistoryTransferError.invalidRecords }
    }
    private static func validateRawRows(_ rows: [[String: Any]]) throws {
        guard rows.count <= maximumRecords else { throw OutdoorHistoryTransferError.invalidRecords }
        for record in rows {
            try allowed(record, ["version", "id", "kind", "trackingMode", "startedAt", "finishedAt", "confirmedActiveSeconds",
                "recordedDistanceMeters", "hasMissingLocationCoverage", "recordedSteps", "hasIncompleteStepCoverage", "steps", "route", "routeDeletedAt"])
            guard let steps = record["steps"] as? [String: Any], let stepRows = steps["intervals"] as? [[String: Any]] else {
                throw OutdoorHistoryTransferError.invalidRecords
            }
            try allowed(steps, ["intervals", "hasClockDiscontinuity"])
            guard stepRows.count <= 1_000 else { throw OutdoorHistoryTransferError.invalidRecords }
            for interval in stepRows {
                try allowed(interval, ["id", "startedAt", "endedAt", "lastSampleAt", "latestCumulativeSteps", "isFinal"])
            }
            if let route = record["route"], !(route is NSNull) {
                guard let route = route as? [String: Any], let segments = route["segments"] as? [[String: Any]], segments.count <= 1_000 else {
                    throw OutdoorHistoryTransferError.invalidRecords
                }
                try allowed(route, ["segments", "totalRecordedMeters", "hasMissingLocationCoverage", "hasMeasuredInterval", "pendingBreak"])
                for segment in segments {
                    try allowed(segment, ["id", "points", "endsAtUserPause"])
                    guard let fixes = segment["points"] as? [[String: Any]], fixes.count <= maximumPointsPerRecord else {
                        throw OutdoorHistoryTransferError.invalidRecords
                    }
                    for fix in fixes { try allowed(fix, ["latitude", "longitude", "timestamp", "horizontalAccuracyMeters"]) }
                }
            }
        }
    }
}
