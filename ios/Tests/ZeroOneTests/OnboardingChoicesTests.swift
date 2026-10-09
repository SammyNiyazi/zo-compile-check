import XCTest
@testable import ZeroOne

final class OnboardingChoicesTests: XCTestCase {
    func testNoEquipmentIsExclusiveOfPhysicalEquipment() {
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.none, in: [.barbell, .bands]), [.none])
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.dumbbells, in: [.none]), [.dumbbells])
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.none, in: [.none]), [])
    }

    func testDetailedDaysMapConservativelyToOldSummary() {
        XCTAssertEqual(ZeroOneTrainingDay.legacyAvailability(for: [.monday]), .notSure)
        XCTAssertEqual(ZeroOneTrainingDay.legacyAvailability(for: [.monday, .wednesday, .friday]), .threeDays)
        XCTAssertEqual(ZeroOneTrainingDay.legacyAvailability(for: Set(ZeroOneTrainingDay.allCases)), .fiveOrMoreDays)
    }

    func testEquipmentSummaryDoesNotClaimFullGymForPartialKit() {
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: [.none]), .bodyweight)
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: [.dumbbells]), .dumbbells)
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: [.dumbbells, .bands]), .notSure)
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: ZeroOneEquipmentItem.fullGym), .fullGym)
    }

    func testUnitDefaultsFollowRegionWithoutLocationAccess() {
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.weight(for: Locale(identifier: "en_US")), .pounds)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.distance(for: Locale(identifier: "en_US")), .miles)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.weight(for: Locale(identifier: "bg_BG")), .kilograms)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.distance(for: Locale(identifier: "bg_BG")), .kilometers)
    }
}
