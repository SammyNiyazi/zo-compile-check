import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A Club photo as stored: "<auth user id>/<sha256 of the full file>". The full file is "<key>.heic" and
/// the thumbnail "<key>-thumb.heic" (supabase/migrations/202610100004_club_live_photos.sql).
struct ClubPhotoKey: Hashable, Sendable, Codable {
    let value: String

    init?(_ value: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              parts[0] == parts[0].lowercased(), parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = ClubPhotoKey(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "photo key"))
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    func objectName(thumbnail: Bool) -> String { value + (thumbnail ? "-thumb.heic" : ".heic") }
}

extension ClubPhotoKey: Identifiable {
    var id: String { value }
}

/// Shrinks a photo on this iPhone before it leaves it: the long side at most 1600 px (640 px for the
/// thumbnail), HEIC, and no metadata at all, so location, camera and time never reach the Club.
enum ClubPhotoEncoder {
    struct Prepared: Sendable {
        let full: Data
        let thumbnail: Data
        let width: Int
        let height: Int
        /// SHA-256 of the full file, lowercase hex: the file name, so a file never changes.
        let hash: String
    }

    static let fullSide = 1600
    static let thumbnailSide = 640
    /// The server refuses files above 600 KB; stay well under it.
    static let maximumBytes = 560_000

    static func prepare(_ data: Data) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Quality steps: the first is the sweet spot; the rest only for unusually detailed photos.
        for (side, quality) in [(fullSide, 0.62), (fullSide, 0.5), (1280, 0.5)] {
            guard let image = downsample(source, maxSide: side),
                  let full = heic(image, quality: quality) else { return nil }
            guard full.count <= maximumBytes else { continue }
            guard let small = downsample(source, maxSide: thumbnailSide),
                  let thumbnail = heic(small, quality: 0.55) else { return nil }
            let hash = SHA256.hash(data: full).map { String(format: "%02x", $0) }.joined()
            return Prepared(full: full, thumbnail: thumbnail, width: image.width, height: image.height, hash: hash)
        }
        return nil
    }

    /// Decodes straight to the target size (never the full 12 MP bitmap) and applies the photo's orientation.
    static func downsample(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// Only the pixels are written: no EXIF, GPS or TIFF dictionaries are passed on.
    static func heic(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Supabase Storage for the club-photos bucket. Uploads never overwrite (x-upsert false).
struct ClubPhotoStorage: Sendable {
    let configuration: ZeroOneAccountConfiguration
    var network: URLSession = .shared

    func upload(_ data: Data, name: String, session: ZeroOneAccountSession) async throws {
        var request = authorized(path: "storage/v1/object/club-photos/" + name, session: session)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("image/heic", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.setValue("max-age=31536000, immutable", forHTTPHeaderField: "cache-control")
        let (body, response) = try await network.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return }
        // The same file is already there (same content hash): nothing to do.
        let text = String(decoding: body, as: UTF8.self)
        if status == 409 || text.contains("Duplicate") || text.contains("already exists") { return }
        throw status == 401 ? ClubServiceError.signedOut : ClubServiceError.unavailable
    }

    func download(name: String, session: ZeroOneAccountSession) async throws -> Data {
        var request = authorized(path: "storage/v1/object/authenticated/club-photos/" + name, session: session)
        request.timeoutInterval = 30
        let (data, response) = try await network.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw ClubServiceError.unavailable }
        return data
    }

    private func authorized(path: String, session: ZeroOneAccountSession) -> URLRequest {
        var request = URLRequest(url: configuration.url.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Every Club photo is downloaded once per iPhone: files never change, so the disk copy is kept until the
/// cache passes 200 MB (least recently used go first). Decoded images are kept in memory for scrolling.
@MainActor
final class ClubPhotoCache {
    static let shared = ClubPhotoCache()
    static let diskLimit = 200 * 1_048_576

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClubPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        memory.totalCostLimit = 60 * 1_048_576
    }

    func fileURL(_ name: String) -> URL {
        folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }

    /// The image for `name`, from memory, then disk, then one download shared by every caller.
    func image(_ name: String, maxSide: CGFloat,
               fetch: @escaping @MainActor () async -> Data?) async -> UIImage? {
        let key = "\(name)@\(Int(maxSide))" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        if let running = inFlight[key as String] { return await running.value }
        let file = fileURL(name)
        let task = Task<UIImage?, Never> { @MainActor in
            var data = try? Data(contentsOf: file)
            if data == nil, let fetched = await fetch() {
                try? fetched.write(to: file, options: .atomic)
                data = fetched
                self.trimIfNeeded()
            } else {
                // Touch, so the least recently used files are trimmed first.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            }
            guard let data, let image = Self.decode(data, maxSide: maxSide) else { return nil }
            self.memory.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        return image
    }

    /// Keep a just-uploaded photo so the sender never downloads their own file.
    func store(_ data: Data, name: String) {
        try? data.write(to: fileURL(name), options: .atomic)
    }

    static func decode(_ data: Data, maxSide: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = ClubPhotoEncoder.downsample(source, maxSide: Int(maxSide)) else { return nil }
        return UIImage(cgImage: image)
    }

    private var lastTrim = Date.distantPast

    func trimIfNeeded() {
        guard Date().timeIntervalSince(lastTrim) > 60 else { return }
        lastTrim = Date()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > Self.diskLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > Self.diskLimit * 8 / 10 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
