import CryptoKit
import Foundation

protocol OutdoorRecommendationLoading: Sendable {
    func loadRecommendationObservation() async throws -> OutdoorRecommendationObservation
}

/// An exact, local observation. Absence is verified empty history; unreadable
/// bytes are unavailable. The receipt never leaves the device.
struct OutdoorRecommendationObservation: Sendable {
    enum Source: Equatable, Sendable {
        case absent
        case bytes(String)
    }

    let records: [OutdoorActivityRecord]
    let source: Source

    static func load(from url: URL) throws -> Self {
        guard let data = try read(from: url) else { return .init(records: [], source: .absent) }
        return .init(records: try OutdoorHistoryTransferDecoder.decodeStoredRecords(data), source: signature(data))
    }

    static func currentSource(at url: URL) throws -> Source {
        try read(from: url).map(signature) ?? .absent
    }

    private static func signature(_ data: Data) -> Source {
        .bytes(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Bounded read only. Never creates directories, rewrites records or touches
    /// the actor's active journal or transfer state.
    private static func read(from url: URL) throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch {
            let failure = error as NSError
            if failure.isMissingFile { return nil }
            throw error
        }
        defer { try? handle.close() }
        var data = Data()
        while true {
            let remaining = OutdoorHistoryTransferDecoder.maximumFileBytes - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw OutdoorActivityPersistenceError.invalidHistory }
            data.append(chunk)
        }
        return data
    }
}
