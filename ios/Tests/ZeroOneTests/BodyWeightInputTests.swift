import Foundation
import XCTest
@testable import ZeroOne

final class BodyWeightInputTests: XCTestCase {
    func testWholeDecimalsAndDecimalKeyboardDigits() {
        for input in ["80.25", "80,25", " 80,25\n", "٨٠٫٢٥"] {
            XCTAssertEqual(BodyWeightInput.number(input), Decimal(string: "80.25"), input)
        }
        XCTAssertEqual(BodyWeightInput.number(".5"), Decimal(string: "0.5"))
    }

    func testInvalidSuffixesSeparatorsSignsAndScientificNotationAreNotReadings() {
        for input in ["", " ", ".", "80.", "80kg", "80 25", "80.2.5", "1,234.5",
                      "70/80", "+80", "-80", "8e1", "NaN", "Infinity", "８０kg", "²"] {
            XCTAssertNil(BodyWeightInput.number(input), input)
        }
    }

    func testSamePhysicalBoundsAfterUnitConversion() throws {
        XCTAssertEqual(BodyWeightInput.kilograms("80.125", unit: .kilograms), Decimal(string: "80.125"))
        let pounds = try XCTUnwrap(BodyWeightInput.kilograms("176.3698", unit: .pounds))
        XCTAssertEqual(NSDecimalNumber(decimal: pounds).doubleValue, 80, accuracy: 0.001)
        XCTAssertNil(BodyWeightInput.kilograms("0", unit: .kilograms))
        XCTAssertNil(BodyWeightInput.kilograms("1000.1", unit: .kilograms))
        XCTAssertNil(BodyWeightInput.kilograms("3000", unit: .pounds))
        XCTAssertNil(BodyWeightInput.number(String(repeating: "9", count: 129)))
    }
}
