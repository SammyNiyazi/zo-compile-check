import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// Exact original SVG rendered by Edge154.0.4258.62 at intrinsic160 CSSpx/DPR1,2,3.
/// Provenance and RGBA hashes are in Lead-Freak-Grain/REFERENCE-RASTERS.json.
/// No procedural substitute, flattening of alpha, or resampling between reference scales.
enum ZOFreakGrainReference {
    static let tileSize: CGFloat = 160
    static let opacity: Double = 0.05
    static let canonicalSVG_SHA256 = "e0c04da249ceb7e8a9eae9b0df59a75c8cfe178d8eb718c105a672793cd7253c"

    enum Failure: Error {
        case unprovenDisplayScale(CGFloat)
        case missingResource(String)
        case alteredReference(String)
        case invalidImage(String)
    }

    static func referenceScale(_ displayScale: CGFloat) throws -> Int {
        guard displayScale.isFinite, displayScale == 1 || displayScale == 2 || displayScale == 3 else {
            throw Failure.unprovenDisplayScale(displayScale)
        }
        return Int(displayScale)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func expectedHash(scale: Int) throws -> String {
        switch scale {
        case 1: "51e3a92563ba1516bdeae0efc4edc14666872f58a13c3dbc0b01c43e0728372d"
        case 2: "9a55a27480022a34c1e73003103d9b4146be03ac845f6a5e22855c339d102ba7"
        case 3: "d74c95893a64c533c2c9b7f2714db98f4e4f348acd8b0c8e744be126797c07b9"
        default: throw Failure.unprovenDisplayScale(CGFloat(scale))
        }
    }

    static func load(scale: Int, bundle: Bundle = .main) throws -> CGImage {
        let name = "FreakGrain-\(scale)x"
        let expected = try expectedHash(scale: scale)
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "ThemeFX") else {
            throw Failure.missingResource(name)
        }
        let data = try Data(contentsOf: url)
        guard sha256(data) == expected else { throw Failure.alteredReference(name) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == 160 * scale, image.height == 160 * scale,
              image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast ||
                  image.alphaInfo == .first || image.alphaInfo == .last else {
            throw Failure.invalidImage(name)
        }
        return image
    }

    /// Preserve every complete160pt tile, including the last partially visible tile.
    /// The Canvas clips at its existing content bounds; clipping never shrinks a tile.
    static func tileRects(in size: CGSize) -> [CGRect] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let columns = ceil(size.width / tileSize), rows = ceil(size.height / tileSize)
        guard columns < CGFloat(Int.max), rows < CGFloat(Int.max), columns * rows < CGFloat(Int.max) else { return [] }
        return (0..<Int(rows)).flatMap { row in
            (0..<Int(columns)).map { column in
                CGRect(x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize, width: tileSize, height: tileSize)
            }
        }
    }
}

@MainActor
private enum ZOFreakGrainCache {
    // Once per process. Missing/altered images remain diagnosed failures, never fake grain.
    static let references: [Int: Result<CGImage, Error>] = Dictionary(uniqueKeysWithValues: (1...3).map { scale in
        (scale, Result { try ZOFreakGrainReference.load(scale: scale) })
    })

    static func image(displayScale: CGFloat) throws -> CGImage {
        let scale = try ZOFreakGrainReference.referenceScale(displayScale)
        guard let reference = references[scale] else { throw ZOFreakGrainReference.Failure.unprovenDisplayScale(displayScale) }
        return try reference.get()
    }
}

/// Static foreground decoration for Freak in both appearances. Screen host owns bounds.
/// Native CSS-overlay color/compositing/scale acceptance remains UNRUN.
@MainActor
struct ZOFreakGrainLayer: View {
    @Environment(\.displayScale) private var displayScale

    private var referenceImage: CGImage? {
        do { return try ZOFreakGrainCache.image(displayScale: displayScale) }
        catch {
            assertionFailure("Exact Freak grain reference unavailable; theme parity is not accepted: \(error)")
            return nil
        }
    }

    var body: some View {
        let image = referenceImage
        Canvas(rendersAsynchronously: false) { context, size in
            if let image {
                let resolved = context.resolve(Image(decorative: image, scale: displayScale, orientation: .up).interpolation(.none))
                for tile in ZOFreakGrainReference.tileRects(in: size) { context.draw(resolved, in: tile) }
            }
        }
        .clipped()
        .opacity(ZOFreakGrainReference.opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
