import XCTest
@testable import ZeroOne

final class DesignThemePreferenceTests: XCTestCase {
    func testAbsentUnknownAndLegacyValuesUseCoreWithoutReinterpretingThem() {
        for raw in [nil, "", "future-theme", "liquidMidnight", "iridescentAura", "atelier"] {
            XCTAssertEqual(DesignThemePreference.storedValue(raw), .core)
        }
        XCTAssertNotEqual(DesignThemePreference.storageKey, "slick.visualTheme")
    }

    func testFinalSelectionSurvivesStorageRoundTrip() {
        for choice in DesignThemePreference.allCases {
            XCTAssertEqual(DesignThemePreference.storedValue(choice.rawValue), choice)
            XCTAssertEqual(choice.designTheme.rawValue, choice.rawValue)
        }
    }
}
