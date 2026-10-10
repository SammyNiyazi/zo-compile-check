import Foundation
import XCTest
@testable import ZeroOne

final class BodyHeightMeasurementTests: XCTestCase {
    func testHeightAcceptsWholeLocaleNumberAndConvertsFeet() throws {
        XCTAssertEqual(try XCTUnwrap(BodyHeightMeasurement.centimeters(from: "178,5", imperial: false)), 178.5)
        XCTAssertEqual(try XCTUnwrap(BodyHeightMeasurement.centimeters(from: "5.75", imperial: true)), 175.26, accuracy: 0.0001)
        for invalid in ["", "178 cm", "5ft9", "-10", "0", "NaN", "301"] {
            XCTAssertNil(BodyHeightMeasurement.centimeters(from: invalid, imperial: false))
        }
    }

    func testImperialHeightIsFeetAndInchesNotDecimalFeet() throws {
        XCTAssertEqual(try XCTUnwrap(BodyHeightMeasurement.centimeters(feet: "5", inches: "10")), 177.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(BodyHeightMeasurement.centimeters(feet: "6", inches: "")), 182.88, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(BodyHeightMeasurement.centimeters(feet: "5", inches: "9,5")), 176.53, accuracy: 0.0001)
        for (feet, inches) in [("", ""), ("5", "12"), ("5.5", "0"), ("-5", "0"), ("5", "-1"), ("12", "0"), ("x", "1")] {
            XCTAssertNil(BodyHeightMeasurement.centimeters(feet: feet, inches: inches), "\(feet) ft \(inches) in")
        }
        let parts = BodyHeightMeasurement(centimeters: 177.8, recordedAt: .now, source: .appleHealth).feetAndInches
        XCTAssertEqual(parts.feet, 5)
        XCTAssertEqual(parts.inches, 10)
        // 71.9 in rounds to 72: 6 ft 0 in, never 5 ft 12 in.
        let carried = BodyHeightMeasurement(centimeters: 182.6, recordedAt: .now, source: .manual).feetAndInches
        XCTAssertEqual(carried.feet, 6)
        XCTAssertEqual(carried.inches, 0)
    }

    func testSavedHeightAndSourceDoNotChangeWhenWeightUnitsChange() throws {
        var profile = ZeroOneUserProfile()
        let height = BodyHeightMeasurement(centimeters: 178, recordedAt: Date(timeIntervalSince1970: 100), source: .appleHealth)
        profile.bodyHeight = height
        profile.startingBodyWeight = 76.5
        let imperial = ZeroOneProfileUnitSelection(weight: .pounds, distance: .miles).applying(to: profile, previousWeight: .kilograms)
        XCTAssertEqual(imperial.bodyHeight, height)
        let restored = try JSONDecoder().decode(ZeroOneUserProfile.self, from: JSONEncoder().encode(imperial))
        XCTAssertEqual(restored.bodyHeight, height)
        XCTAssertTrue(restored.isCompatible)
        let shown = try XCTUnwrap(BodyHeightMeasurement.centimeters(from: height.displayValue(imperial: true), imperial: true))
        XCTAssertEqual(shown, height.centimeters, accuracy: 0.02)
    }

    func testOldProfileWithoutHeightDecodesAndInvalidHeightIsRejected() throws {
        let original = ZeroOneUserProfile()
        let oldData = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("bodyHeight"))
        XCTAssertNil(try JSONDecoder().decode(ZeroOneUserProfile.self, from: oldData).bodyHeight)
        var invalid = original
        invalid.bodyHeight = BodyHeightMeasurement(centimeters: 0, recordedAt: .now, source: .manual)
        XCTAssertFalse(invalid.isCompatible)
        invalid.bodyHeight = BodyHeightMeasurement(centimeters: 178, recordedAt: Date(timeIntervalSinceReferenceDate: .infinity), source: .manual)
        XCTAssertFalse(invalid.isCompatible)
    }
}
