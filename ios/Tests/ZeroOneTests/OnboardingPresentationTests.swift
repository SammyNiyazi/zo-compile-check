import Foundation
import XCTest
@testable import ZeroOne

final class ZeroOneOnboardingPresentationTests: XCTestCase {
    func testPlanSaveRequiresAnActualPlanAndNoConcurrentOperation() {
        for hasPlan in [false, true] {
            for isSaving in [false, true] {
                for isImporting in [false, true] {
                    let controls = ZeroOneSetupPlanControls(hasPlan: hasPlan, isSaving: isSaving, isImportingBodyWeight: isImporting)
                    XCTAssertEqual(controls.canSave, hasPlan && !isSaving && !isImporting)
                    XCTAssertEqual(controls.canEdit, !isSaving && !isImporting)
                    XCTAssertEqual(controls.canReload, !isSaving && !isImporting)
                }
            }
        }
    }

    func testReloadAvailabilityDoesNotTurnAMissingPlanIntoASave() {
        let controls = ZeroOneSetupPlanControls(hasPlan: false, isSaving: false, isImportingBodyWeight: false)
        XCTAssertTrue(controls.canReload)
        XCTAssertFalse(controls.canSave)
    }

    func testNoEquipmentIsExclusiveWithoutSelectingEquipmentForThePerson() {
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.none, in: [.barbell, .bench]), [.none])
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.dumbbells, in: [.none]), [.dumbbells])
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.none, in: [.none]), [])
        XCTAssertEqual(ZeroOneEquipmentItem.toggling(.bench, in: [.bench, .dumbbells]), [.dumbbells])
    }

    func testIncompleteEquipmentAndSingleDayDoNotBecomeKnownLegacyDefaults() {
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: []), .notSure)
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: [.bench, .dumbbells]), .notSure)
        XCTAssertEqual(ZeroOneEquipmentItem.legacyAccess(for: [.none]), .bodyweight)
        XCTAssertEqual(ZeroOneTrainingDay.legacyAvailability(for: [.monday]), .notSure)
        XCTAssertEqual(ZeroOneTrainingDay.legacyAvailability(for: [.monday, .thursday]), .twoDays)
    }

    func testUnitDefaultsAreRegionSpecificAndIndependent() {
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.weight(for: Locale(identifier: "en_US")), .pounds)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.distance(for: Locale(identifier: "en_US")), .miles)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.weight(for: Locale(identifier: "en_GB")), .kilograms)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.distance(for: Locale(identifier: "en_GB")), .miles)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.weight(for: Locale(identifier: "bg_BG")), .kilograms)
        XCTAssertEqual(ZeroOneOnboardingUnitDefaults.distance(for: Locale(identifier: "bg_BG")), .kilometers)
    }

    func testCurrentFoundationScopeHasExactlyTheSixExistingReadsAndNoWrites() {
        let expected: Set<HealthReadDataType> = [.stepCount, .activeEnergy, .workouts, .sleepAnalysis, .bodyMass, .height, .distanceWalkingRunning]
        XCTAssertEqual(HealthAuthorizationScope.zeroOneFoundation.readTypes, expected)
        XCTAssertTrue(HealthAuthorizationScope.zeroOneFoundation.writeTypes.isEmpty)
    }

    func testFailedReadDoesNotImplyAReversedPermissionOrHideTheIssue() {
        let value = ZeroOneSetupHealthPresentation(scope: .zeroOneFoundation, status: .connected, issue: .readFailed)
        XCTAssertEqual(value.issue, .readFailed)
        XCTAssertFalse(value.canRequest)
        XCTAssertFalse(value.isRequesting)
        XCTAssertEqual(value.statusKey, "Access request completed. Data appears only when available.")
    }

    func testProgressDoesNotReinterpretLegacyFiveQuestionCount() throws {
        let progress = try XCTUnwrap(ZeroOneSetupProgress(current: 3, total: 5))
        XCTAssertEqual(progress.segments.map(\.mark), [.completed, .completed, .current, .ahead, .ahead])
        XCTAssertEqual(progress.segments.map(\.id), [1, 2, 3, 4, 5])
    }

    func testUnknownOrOutOfRangeProgressCannotClaimCompletion() {
        XCTAssertNil(ZeroOneSetupProgress(current: -1, total: 5))
        XCTAssertNil(ZeroOneSetupProgress(current: 6, total: 5))
        XCTAssertNil(ZeroOneSetupProgress(current: 1, total: 0))
        XCTAssertNil(ZeroOneSetupProgress(current: 1, total: 11))
    }

    func testProposedTenStepRailShowsCurrentAsCurrentNotSaved() throws {
        let progress = try XCTUnwrap(ZeroOneSetupProgress(current: 10, total: 10))
        XCTAssertEqual(progress.segments.filter { $0.mark == .completed }.count, 9)
        XCTAssertEqual(progress.segments.last?.mark, .current)
    }

    func testCompletedHealthRequestDoesNotClaimGrantedReads() {
        let value = ZeroOneSetupHealthPresentation(scope: .zeroOneFoundation, status: .connected, issue: nil)
        XCTAssertFalse(value.canRequest)
        XCTAssertEqual(value.statusKey, "Access request completed. Data appears only when available.")
        XCTAssertTrue(value.writeTypes.isEmpty)
        XCTAssertEqual(Set(value.readTypes), HealthAuthorizationScope.zeroOneFoundation.readTypes)
    }

    func testHealthBusyUnavailableAndRetryStatesRemainDistinct() {
        let busy = ZeroOneSetupHealthPresentation(scope: .zeroOneFoundation, status: .connecting, issue: nil)
        let unavailable = ZeroOneSetupHealthPresentation(scope: .zeroOneFoundation, status: .unavailable, issue: nil)
        let retry = ZeroOneSetupHealthPresentation(scope: .zeroOneFoundation, status: .notConnected, issue: .requestFailed)
        XCTAssertTrue(busy.isRequesting)
        XCTAssertFalse(busy.canRequest)
        XCTAssertFalse(unavailable.canRequest)
        XCTAssertFalse(unavailable.isRequesting)
        XCTAssertTrue(retry.canRequest)
        XCTAssertEqual(retry.issue, .requestFailed)
    }

    func testSuppliedScopeDoesNotInventHeightOrWorkoutWriteAccess() {
        let scope = HealthAuthorizationScope(readTypes: [.bodyMass], writeTypes: [])
        let value = ZeroOneSetupHealthPresentation(scope: scope, status: .notConnected, issue: .cancelled)
        XCTAssertEqual(value.readTypes, [.bodyMass])
        XCTAssertEqual(value.writeTypes, [])
        XCTAssertEqual(value.issue, .cancelled)
    }
}
