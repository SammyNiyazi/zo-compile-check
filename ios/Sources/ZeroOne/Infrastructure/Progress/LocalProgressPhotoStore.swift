import Foundation
import UIKit

struct ProgressPhotoEncodedImage: Sendable {
    let imageData: Data
    let thumbnailData: Data
}

enum ProgressPhotoImageEncoder {
    static func encode(_ sourceData: Data) throws -> ProgressPhotoEncodedImage {
        guard let source = UIImage(data: sourceData) else {
            throw ProgressPhotoStoreError.invalidImage
        }

        let image = try render(source, maximumDimension: 2_048, compressionQuality: 0.9)
        let thumbnail = try render(source, maximumDimension: 480, compressionQuality: 0.82)
        return ProgressPhotoEncodedImage(imageData: image, thumbnailData: thumbnail)
    }

    private static func render(
        _ source: UIImage,
        maximumDimension: CGFloat,
        compressionQuality: CGFloat
    ) throws -> Data {
        let originalSize = source.size
        guard originalSize.width > 0, originalSize.height > 0 else {
            throw ProgressPhotoStoreError.invalidImage
        }
        let scale = min(1, maximumDimension / max(originalSize.width, originalSize.height))
        let targetSize = CGSize(
            width: max(1, (originalSize.width * scale).rounded()),
            height: max(1, (originalSize.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            source.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = normalized.jpegData(compressionQuality: compressionQuality) else {
            throw ProgressPhotoStoreError.invalidImage
        }
        return data
    }
}

struct LocalProgressPhotoStore: ProgressPhotoPersisting {
    private let fileManager: FileManager
    private let rootURL: URL
    private let manifestURL: URL

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let resolvedRoot = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.rootURL = resolvedRoot.standardizedFileURL
        manifestURL = resolvedRoot.appendingPathComponent("records.json", isDirectory: false)
    }

    var isAvailable: Bool {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return true }
        return (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([ProgressPhotoRecord].self, from: $0) } != nil
    }

    func loadRecords() throws -> [ProgressPhotoRecord] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode([ProgressPhotoRecord].self, from: data)
        } catch {
            throw ProgressPhotoStoreError.unavailable
        }
    }

    func save(
        _ record: ProgressPhotoRecord,
        imageData: Data,
        thumbnailData: Data
    ) throws {
        let imageURL = try ownedURL(
            relativePath: record.imageRelativePath,
            recordID: record.id,
            expectedFilename: "master.jpg"
        )
        let thumbnailURL = try ownedURL(
            relativePath: record.thumbnailRelativePath,
            recordID: record.id,
            expectedFilename: "thumbnail.jpg"
        )
        let recordDirectory = imageURL.deletingLastPathComponent()
        try prepareRootDirectory()
        try fileManager.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
        applyFileProtection(to: recordDirectory)

        do {
            try imageData.write(to: imageURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
            applyFileProtection(to: imageURL)
            applyFileProtection(to: thumbnailURL)
            var records = try loadRecords()
            records.removeAll { $0.id == record.id }
            records.append(record)
            try writeManifest(records)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: thumbnailURL)
            try? removeDirectoryIfEmpty(recordDirectory)
            throw error
        }
    }

    func delete(_ record: ProgressPhotoRecord) throws {
        let imageURL = try ownedURL(
            relativePath: record.imageRelativePath,
            recordID: record.id,
            expectedFilename: "master.jpg"
        )
        let thumbnailURL = try ownedURL(
            relativePath: record.thumbnailRelativePath,
            recordID: record.id,
            expectedFilename: "thumbnail.jpg"
        )

        if fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.removeItem(at: imageURL)
        }
        if fileManager.fileExists(atPath: thumbnailURL.path) {
            try fileManager.removeItem(at: thumbnailURL)
        }
        try removeDirectoryIfEmpty(imageURL.deletingLastPathComponent())

        var records = try loadRecords()
        records.removeAll { $0.id == record.id }
        try writeManifest(records)
    }

    func data(at relativePath: String, for record: ProgressPhotoRecord) -> Data? {
        let expectedFilename = relativePath == record.imageRelativePath
            ? "master.jpg"
            : relativePath == record.thumbnailRelativePath ? "thumbnail.jpg" : nil
        guard let expectedFilename,
              let url = try? ownedURL(
                relativePath: relativePath,
                recordID: record.id,
                expectedFilename: expectedFilename
              ) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func relativePaths(for id: UUID) -> (image: String, thumbnail: String) {
        let directory = id.uuidString.lowercased()
        return (directory + "/master.jpg", directory + "/thumbnail.jpg")
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Slick", isDirectory: true)
            .appendingPathComponent("ProgressPhotos", isDirectory: true)
    }

    private func ownedURL(
        relativePath: String,
        recordID: UUID,
        expectedFilename: String
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let expectedDirectory = recordID.uuidString.lowercased()
        guard components.count == 2,
              components[0].lowercased() == expectedDirectory,
              components[1] == Substring(expectedFilename),
              !relativePath.hasPrefix("/") else {
            throw ProgressPhotoStoreError.invalidOwnedPath
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path.hasPrefix(rootPath) else {
            throw ProgressPhotoStoreError.invalidOwnedPath
        }
        return url
    }

    private func writeManifest(_ records: [ProgressPhotoRecord]) throws {
        try prepareRootDirectory()
        let data = try JSONEncoder().encode(records)
        try data.write(to: manifestURL, options: .atomic)
        applyFileProtection(to: manifestURL)
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var protectedRoot = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedRoot.setResourceValues(values)
        applyFileProtection(to: rootURL)
    }

    private func applyFileProtection(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func removeDirectoryIfEmpty(_ directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        if contents.isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }
}

struct LocalBodyWeightStore: BodyWeightPersisting {
    private let fileManager: FileManager
    private let rootURL: URL?
    private var entriesURL: URL? { rootURL?.appendingPathComponent("entries.json") }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.rootURL = support?.appendingPathComponent("Slick", isDirectory: true)
                .appendingPathComponent("BodyWeight", isDirectory: true)
        }
    }

    func load() throws -> [BodyWeightEntry] {
        guard let entriesURL else { throw BodyWeightStoreError.unavailable }
        guard fileManager.fileExists(atPath: entriesURL.path) else { return [] }
        return try JSONDecoder().decode([BodyWeightEntry].self, from: Data(contentsOf: entriesURL))
    }

    func save(_ entries: [BodyWeightEntry]) throws {
        guard let rootURL, let entriesURL else { throw BodyWeightStoreError.unavailable }
        // Never replace an existing payload that cannot be decoded.
        _ = try load()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: entriesURL, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: entriesURL.path
        )
        guard try Data(contentsOf: entriesURL) == data else {
            throw BodyWeightStoreError.verificationFailed
        }
    }
}
