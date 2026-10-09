import Foundation

enum DietTrackerStorageCodec {
    static let maximumBytes = 16 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> DietTrackerSnapshot {
        do {
            guard data.count <= maximumBytes else { throw DietTrackerError.invalidFile }
            var syntax = ImportJSONSyntax(data: data)
            try syntax.validate()
            let object = try JSONSerialization.jsonObject(with: data)
            try shape(object)
            let snapshot = try JSONDecoder().decode(DietTrackerSnapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch { throw DietTrackerError.invalidFile }
    }

    static func encode(_ snapshot: DietTrackerSnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw DietTrackerError.storageLimit }
        return data
    }

    private static func object(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let result = value as? [String: Any], required.isSubset(of: Set(result.keys)),
              Set(result.keys).isSubset(of: required.union(optional)) else { throw DietTrackerError.invalidFile }
        return result
    }

    private static func time(_ value: Any) throws {
        _ = try object(value, required: ["id", "hour", "minute"])
    }

    private static func shape(_ value: Any) throws {
        let root = try object(value, required: ["version", "trackers", "completions"])
        guard let trackers = root["trackers"] as? [Any], let logs = root["completions"] as? [Any] else {
            throw DietTrackerError.invalidFile
        }
        for value in trackers {
            let entry = try object(value, required: ["id", "revision", "name", "kind", "dose", "times",
                "remindMe", "remindAgainIfNotLogged", "createdAt", "updatedAt", "isArchived"])
            guard let times = entry["times"] as? [Any] else { throw DietTrackerError.invalidFile }
            for slot in times { try time(slot) }
        }
        for value in logs {
            let log = try object(value, required: ["id", "trackerID", "trackerRevision", "name", "kind", "dose", "day", "loggedAt"],
                optional: ["scheduledTime"])
            guard let day = log["day"] else { throw DietTrackerError.invalidFile }
            _ = try object(day, required: ["start", "end", "timeZoneIdentifier"])
            if let slot = log["scheduledTime"], !(slot is NSNull) { try time(slot) }
        }
    }
}

@MainActor
protocol DietTrackerPersisting {
    func load() throws -> DietTrackerSnapshot
    func save(_ candidate: DietTrackerSnapshot, replacing baseline: DietTrackerSnapshot) throws
}

/// Separate local storage. Atomic replacement and exact readback protect a
/// single app owner; no cross-process compare-and-swap guarantee is claimed.
@MainActor
struct FileDietTrackerStore: DietTrackerPersisting {
    let directory: URL?

    // Default arguments are built outside the main actor (AppRootView, DietTrackerRepository).
    nonisolated init(directory: URL? = nil) { self.directory = directory }

    private func file() throws -> URL {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ZeroOne/DietTrackers", isDirectory: true)
        return root.appendingPathComponent("diet-trackers.json")
    }

    func load() throws -> DietTrackerSnapshot {
        let url = try file()
        do { return try DietTrackerStorageCodec.decode(Data(contentsOf: url)) }
        catch {
            let error = error as NSError
            if error.isMissingFile { return .empty }
            throw DietTrackerError.storeUnavailable
        }
    }

    func save(_ candidate: DietTrackerSnapshot, replacing baseline: DietTrackerSnapshot) throws {
        let data = try DietTrackerStorageCodec.encode(candidate)
        // Never replace an unreadable file or another readable owner's newer state.
        guard try load() == baseline else { throw DietTrackerError.storeChanged }
        let url = try file()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else { throw DietTrackerError.saveFailed }
        } catch { throw DietTrackerError.saveFailed }
    }
}
