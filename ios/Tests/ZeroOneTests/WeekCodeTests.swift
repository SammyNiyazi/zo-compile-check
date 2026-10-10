import XCTest
@testable import ZeroOne

/// Proof 33: the Swift week code matches study 30's codes.js bit for bit and
/// reads a drawn line both ways, at two sizes, like the design's own decoder.
final class WeekCodeTests: XCTestCase {
    func testSegmentsMatchTheDesignCodec() {
        // window.zoWeekBits(127) and (1) from study 30 codes.js, 10 Oct 2026.
        XCTAssertEqual(WeekCode.segments(for: 127),
            [1,1,0,0,1,0,1,1,0,1,0,0,0,1,1,1,1,0,0,1,1,1,0,1,0,0,1,1,0,0,1,1,0,1,1])
        XCTAssertEqual(WeekCode.segments(for: 1),
            [1,1,0,0,1,0,1,1,0,1,0,0,0,1,1,1,1,0,0,1,0,0,1,0,1,1,1,1,1,1,0,0,1,1,0])
        for number in [1, 127, 4_096, 99_999, 16_777_215] {
            XCTAssertEqual(WeekCode.number(fromSegments: WeekCode.segments(for: number)), number)
            XCTAssertEqual(WeekCode.number(fromSegments: Array(WeekCode.segments(for: number).reversed())), number)
        }
        var broken = WeekCode.segments(for: 127)
        broken[20] ^= 1
        XCTAssertNil(WeekCode.number(fromSegments: broken), "The checksum catches a misread segment")
    }

    /// Card 240, faint 150, filled 30, one pixel per layout unit (the reference line).
    private func line(_ number: Int, scale: Int = 1) -> [Double] {
        var s: [Double] = []
        func put(_ v: Double, _ n: Int) { s += Array(repeating: v, count: n * scale) }
        let bits = WeekCode.segments(for: number)
        put(240, 20)
        for g in 0 ..< 7 {
            for q in 0 ..< 5 {
                put(bits[g * 5 + q] == 1 ? 30 : 150, 12)
                if q < 4 { put(240, 4) }
            }
            if g < 6 { put(240, 14) }
        }
        put(240, 20)
        return s
    }

    func testALineReadsBothWaysAndAtThreeTimesTheSize() {
        XCTAssertEqual(WeekCode.decodeLine(line(127)), 127)
        XCTAssertEqual(WeekCode.decodeLine(Array(line(127).reversed())), 127)
        XCTAssertEqual(WeekCode.decodeLine(line(4_096, scale: 3)), 4_096)
        XCTAssertNil(WeekCode.decodeLine(Array(repeating: 200, count: 600)))
    }

    func testAFrameWithTheCodeInTheMiddleReads() {
        let row = line(311, scale: 2)
        let width = row.count, height = 24
        var gray = [UInt8](repeating: 240, count: width * height)
        for y in 8 ..< 16 { for x in 0 ..< width { gray[y * width + x] = UInt8(row[x]) } }
        XCTAssertEqual(WeekCode.decode(gray: gray, width: width, height: height), 311)
    }
}
