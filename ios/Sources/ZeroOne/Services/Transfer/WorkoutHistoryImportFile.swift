import Foundation

enum WorkoutHistoryImportFile {
    /// Reads the user-selected file only. No path from the export is followed.
    /// Chunk bounds also cover a provider file that grows after it was selected.
    static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = WorkoutHistoryImportDecoder.maximumFileBytes - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw WorkoutHistoryImportError.oversizedFile }
            data.append(chunk)
        }
        return data
    }
}
