import XCTest
@testable import ZeroOne

final class ShareGeometryTests: XCTestCase {
    func testExactExportDimensions() {
        XCTAssertEqual(ZOShareSize.story.pixels.width, 1080); XCTAssertEqual(ZOShareSize.story.pixels.height, 1920)
        XCTAssertEqual(ZOShareSize.post.pixels.width, 1080); XCTAssertEqual(ZOShareSize.post.pixels.height, 1350)
        XCTAssertEqual(ZOShareSize.square.pixels.width, 1080); XCTAssertEqual(ZOShareSize.square.pixels.height, 1080)
        XCTAssertEqual(ZOShareSize.wide.pixels.width, 1920); XCTAssertEqual(ZOShareSize.wide.pixels.height, 1080)
    }

    func testRouteFramesStayInsideEveryExportShape() {
        for size in ZOShareSize.allCases {
            for layout in [ZOShareLayout.stats, .route, .noPhoto, .sticker] {
                let frame = ZOShareRouteGeometry(size: size, layout: layout)
                XCTAssertGreaterThanOrEqual(frame.x, 0); XCTAssertGreaterThanOrEqual(frame.y, 0)
                XCTAssertLessThanOrEqual(frame.x + frame.side, 300)
                XCTAssertLessThanOrEqual(frame.y + frame.side, 300 / size.aspectRatio)
                XCTAssertGreaterThan(frame.side, 0)
            }
        }
    }
}
