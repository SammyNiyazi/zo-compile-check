import CoreLocation
import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorLocationServiceTests: XCTestCase {
    func testConfigurationRequiresPurposeAndBackgroundModeBeforeAuthorization() {
        let empty = OutdoorLocationConfiguration(infoDictionary: [:])
        XCTAssertEqual(empty.readiness(
            servicesEnabled: true, authorization: .notDetermined, accuracy: .fullAccuracy
        ), .missingUsageDescription)

        let purposeOnly = OutdoorLocationConfiguration(infoDictionary: [
            "NSLocationWhenInUseUsageDescription": "Record an outdoor route only when you start it."
        ])
        XCTAssertEqual(purposeOnly.readiness(
            servicesEnabled: true, authorization: .notDetermined, accuracy: .fullAccuracy
        ), .missingBackgroundMode)

        let configured = OutdoorLocationConfiguration(infoDictionary: [
            "NSLocationWhenInUseUsageDescription": "Record an outdoor route only when you start it.",
            "UIBackgroundModes": ["location"]
        ])
        XCTAssertEqual(configured.readiness(
            servicesEnabled: true, authorization: .notDetermined, accuracy: .fullAccuracy
        ), .needsPermission)
        XCTAssertEqual(configured.readiness(
            servicesEnabled: false, authorization: .authorizedWhenInUse, accuracy: .fullAccuracy
        ), .servicesDisabled)
    }

    func testDeniedRestrictedAndReducedAccuracyCannotStartPreciseRoute() {
        let configured = OutdoorLocationConfiguration(infoDictionary: [
            "NSLocationWhenInUseUsageDescription": "Outdoor route",
            "UIBackgroundModes": ["location"]
        ])
        XCTAssertEqual(configured.readiness(
            servicesEnabled: true, authorization: .denied, accuracy: .fullAccuracy
        ), .denied)
        XCTAssertEqual(configured.readiness(
            servicesEnabled: true, authorization: .restricted, accuracy: .fullAccuracy
        ), .restricted)
        XCTAssertEqual(configured.readiness(
            servicesEnabled: true, authorization: .authorizedWhenInUse, accuracy: .reducedAccuracy
        ), .reducedAccuracy)
        XCTAssertEqual(configured.readiness(
            servicesEnabled: true, authorization: .authorizedWhenInUse, accuracy: .fullAccuracy
        ), .ready)
    }
}
