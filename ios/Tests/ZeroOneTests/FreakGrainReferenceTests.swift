import CoreGraphics
import Foundation
import XCTest
@testable import ZeroOne

final class FreakGrainReferenceTests: XCTestCase {
    func testOnlyProvenExactDisplayScalesAreAccepted() throws {
        for scale in 1...3 { XCTAssertEqual(try ZOFreakGrainReference.referenceScale(CGFloat(scale)), scale) }
        let unproven: [CGFloat] = [0, -1, 1.5, 4, .infinity, .nan]
        for scale in unproven {
            XCTAssertThrowsError(try ZOFreakGrainReference.referenceScale(scale))
        }
    }

    func testPartialLastTileKeepsOriginalTextureGeometry() {
        let rects = ZOFreakGrainReference.tileRects(in: CGSize(width: 375, height: 257))
        XCTAssertEqual(rects.count, 6)
        XCTAssertEqual(rects.first, CGRect(x: 0, y: 0, width: 160, height: 160))
        XCTAssertEqual(rects.last, CGRect(x: 320, y: 160, width: 160, height: 160))
        XCTAssertEqual(rects.last?.intersection(CGRect(x: 0, y: 0, width: 375, height: 257)), CGRect(x: 320, y: 160, width: 55, height: 97))
    }

    func testExactMultipleDoesNotCreateAnExtraTileOrPhaseShift() {
        XCTAssertEqual(ZOFreakGrainReference.tileRects(in: CGSize(width: 320, height: 320)), [
            CGRect(x: 0, y: 0, width: 160, height: 160), CGRect(x: 160, y: 0, width: 160, height: 160),
            CGRect(x: 0, y: 160, width: 160, height: 160), CGRect(x: 160, y: 160, width: 160, height: 160)
        ])
    }

    func testEmptyOrNonfiniteGeometryDoesNotDraw() {
        for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            XCTAssertTrue(ZOFreakGrainReference.tileRects(in: size).isEmpty)
        }
    }

    func testBundledReferenceFilesPreserveBytesDimensionsAndAlpha() throws {
        // This validates actual target membership and decoding; no synthetic test asset.
        for scale in 1...3 {
            let image = try ZOFreakGrainReference.load(scale: scale)
            XCTAssertEqual(image.width, scale * 160)
            XCTAssertEqual(image.height, scale * 160)
            XCTAssertNotEqual(image.alphaInfo, .none)
            XCTAssertNotEqual(image.alphaInfo, .noneSkipFirst)
            XCTAssertNotEqual(image.alphaInfo, .noneSkipLast)
        }
    }
}
