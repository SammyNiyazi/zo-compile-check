import XCTest
@testable import ZeroOne

/// Source-authored regression for the actual typed placeholder renderer. UNRUN.
final class ProfileSettingsYouLocalizationTests: XCTestCase {
    func testTrainingDayKeysUseSupportedPositionalIntegerSubstitution() {
        XCTAssertEqual(AppLocalization.english.format("%1$lld training day", .integer(1)), "1 training day")
        XCTAssertEqual(AppLocalization.english.format("%1$lld training days", .integer(7)), "7 training days")
    }
}
