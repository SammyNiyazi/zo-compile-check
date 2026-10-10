import XCTest
@testable import ZeroOne

final class StarterExerciseSelectionTests: XCTestCase {
    private let bundledIDs = Set(MoveKitExercise.all.map(\.id))

    private func profile(_ equipment: Set<ZeroOneEquipmentItem> = [.none],
                         experience: ZeroOneTrainingExperience = .startingOut) -> ZeroOneUserProfile {
        var value = ZeroOneUserProfile()
        value.availableEquipment = equipment
        value.trainingExperience = experience
        value.preferredSessionMinutes = 45
        return value
    }

    func testUnresolvedSensitivityHasItsOwnOutcomeAndDoesNotMakeAPlan() {
        var value = profile()
        value.trainingConstraint = .movementSensitivity
        XCTAssertEqual(ZeroOneFirstWeekPlanner.assess(for: value, availableVideoIDs: bundledIDs), .needsMovementReview)
        XCTAssertNil(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
    }

    func testExclusionsBeatPreferencesAndSurviveProfileRoundTrip() throws {
        var value = profile([.dumbbells, .bench])
        value.trainingConstraint = .movementSensitivity
        value.starterSelectionPreferences = StarterSelectionPreferences(
            blockedGroups: [.pushing], confirmedEquipment: [.stableRowSupport],
            preferredVideoIDs: ["push-up", "floor-press"])
        let restored = try JSONDecoder().decode(ZeroOneUserProfile.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: restored, availableVideoIDs: bundledIDs))
        XCTAssertTrue(plan.selectionReport?.selections.allSatisfy { !$0.groups.contains(.pushing) } == true)
        XCTAssertTrue(plan.selectionReport?.issues.contains(.excludedCoverage) == true)
    }

    func testBeginnerCannotReceiveIntermediateSquatEvenWhenPreferredAndFamiliar() throws {
        var value = profile([.barbell])
        value.starterSelectionPreferences = StarterSelectionPreferences(
            familiarVideoIDs: ["barbell-squat"], preferredVideoIDs: ["barbell-squat"])
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(plan.sessions.flatMap(\.videoIDs).contains("barbell-squat"))
        value.trainingExperience = .experienced
        let experienced = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertEqual(experienced.sessions.first?.videoIDs.first, "barbell-squat") // This answer includes a rack.
    }

    func testGenericBenchCannotEstablishInclineBenchOrSupportedRow() throws {
        var value = profile([.dumbbells, .bench])
        value.starterSelectionPreferences = StarterSelectionPreferences(preferredVideoIDs: ["chest-supported-dumbbell-row"])
        let unconfirmed = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(unconfirmed.sessions.flatMap(\.videoIDs).contains("chest-supported-dumbbell-row"))
        XCTAssertTrue(unconfirmed.selectionReport?.issues.contains(.equipmentNeedsConfirmation) == true)
        value.starterSelectionPreferences?.confirmedEquipment = [.inclineBench]
        let confirmed = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(confirmed.sessions.flatMap(\.videoIDs).contains("chest-supported-dumbbell-row"))
        XCTAssertFalse(confirmed.selectionReport?.issues.contains(.missingPulling) == true)
    }

    func testBandWithoutConfirmedAnchorDoesNotSupplyPulling() throws {
        var value = profile([.bands])
        let unconfirmed = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(unconfirmed.sessions.flatMap(\.videoIDs).contains("band-row"))
        XCTAssertTrue(unconfirmed.selectionReport?.issues.contains(.missingPulling) == true)
        value.starterSelectionPreferences = StarterSelectionPreferences(confirmedEquipment: [.bandAnchor])
        let confirmed = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(confirmed.sessions.flatMap(\.videoIDs).contains("band-row"))
        XCTAssertFalse(confirmed.selectionReport?.issues.contains(.missingPulling) == true)
    }

    func testMachineCategoryNeedsSpecificStationConfirmation() throws {
        var value = profile([.machines])
        let unknown = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(unknown.sessions.flatMap(\.videoIDs).contains("machine-leg-press"))
        value.starterSelectionPreferences = StarterSelectionPreferences(confirmedEquipment: [.legPress, .chestPress, .seatedRow])
        let known = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(known.sessions.flatMap(\.videoIDs).contains("machine-leg-press"))
        XCTAssertTrue(known.sessions.flatMap(\.videoIDs).contains("machine-neutral-row"))
    }

    func testNoEquipmentPlanDisclosesPullingGapAndNeverInventsAnEquivalent() throws {
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: profile(), availableVideoIDs: bundledIDs))
        XCTAssertTrue(plan.selectionReport?.issues.contains(.missingPulling) == true)
        XCTAssertTrue(plan.selectionReport?.selections.allSatisfy { !$0.groups.contains(.pulling) } == true)
    }

    func testBandLegCurlNeedsBenchAsWellAsAnchor() throws {
        var value = profile([.bands])
        value.preferredSessionMinutes = 60
        value.starterSelectionPreferences = StarterSelectionPreferences(confirmedEquipment: [.bandAnchor])
        let noBench = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(noBench.sessions.flatMap(\.videoIDs).contains("band-leg-curl"))
        value.availableEquipment = [.bands, .bench]
        let withBench = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(withBench.sessions.flatMap(\.videoIDs).contains("band-leg-curl"))
    }

    func testSingleCableHandleDoesNotConfirmDualPulleyPress() throws {
        var value = profile([.cables])
        value.starterSelectionPreferences = StarterSelectionPreferences(confirmedEquipment: [.singleCableHandle])
        let single = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertFalse(single.sessions.flatMap(\.videoIDs).contains("cable-chest-press"))
        XCTAssertTrue(single.sessions.flatMap(\.videoIDs).contains("cable-standing-single-arm-chest-press"))
        value.starterSelectionPreferences?.confirmedEquipment.insert(.dualCableStation)
        let dual = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(dual.sessions.flatMap(\.videoIDs).contains("cable-chest-press"))
    }

    func testExactIdentityAndMediaVariationStaySeparateAndOccurrencesStayStable() throws {
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile([.barbell], experience: .experienced), availableVideoIDs: bundledIDs))
        XCTAssertEqual(plan.selectionReport?.selections.first?.exerciseIDs.first, ExerciseIDs.barbellBackSquat)
        let ids = [UUID(), UUID()]
        let first = try XCTUnwrap(plan.makeCustomWorkouts(ids: ids, weightUnit: .kilograms))
        let retry = try XCTUnwrap(plan.makeCustomWorkouts(ids: ids, weightUnit: .kilograms))
        XCTAssertEqual(first.flatMap(\.items).map(\.id), retry.flatMap(\.items).map(\.id))
        XCTAssertEqual(Set(first.flatMap(\.items).map(\.id)).count, first.flatMap(\.items).count)
        let variation = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: profile([.dumbbells]), availableVideoIDs: bundledIDs))
        XCTAssertEqual(variation.selectionReport?.selections.first?.exerciseIDs.first, ExerciseID(rawValue: "MOV-dumbbell-goblet-squat"))
        XCTAssertNotEqual(variation.selectionReport?.selections.first?.exerciseIDs.first, ExerciseIDs.gobletSquat)
    }

    func testMissingClipUsesOnlySupportedReplacementAndBlockedIdentityCannotReappear() throws {
        var value = profile()
        value.starterSelectionPreferences = StarterSelectionPreferences(blockedExerciseIDs: [ExerciseIDs.pushUp])
        let available = bundledIDs.subtracting(["bird-dog"])
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: available))
        XCTAssertTrue(plan.sessions.flatMap(\.videoIDs).allSatisfy(available.contains))
        XCTAssertFalse(plan.sessions.flatMap(\.videoIDs).contains("push-up"))
        XCTAssertFalse(plan.sessions.flatMap(\.videoIDs).contains("bird-dog"))
    }

    func testDuplicateCandidatesAndPreferenceIDsFailWithoutDictionaryTrap() throws {
        let candidate = try XCTUnwrap(StarterExerciseSelector.catalogue.first)
        XCTAssertNil(StarterExerciseSelector.select(preferred: [], candidates: [candidate, candidate],
            profile: profile(), availableVideoIDs: bundledIDs, count: 5))
        XCTAssertNil(StarterExerciseSelector.select(preferred: ["push-up", "push-up"],
            profile: profile(), availableVideoIDs: bundledIDs, count: 5))
    }

    func testShortWindowPreservesRestAndActualPrescriptionFitsEstimate() throws {
        for experience in [ZeroOneTrainingExperience.startingOut, .experienced] {
            var value = profile([.dumbbells], experience: experience)
            value.preferredSessionMinutes = 30
            let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
            XCTAssertEqual(plan.restSeconds, 120)
            XCTAssertLessThanOrEqual(try XCTUnwrap(plan.maximumEstimatedMinutes), 30)
            let workouts = try XCTUnwrap(plan.makeCustomWorkouts(ids: [UUID(), UUID()], weightUnit: .kilograms))
            XCTAssertTrue(workouts.flatMap(\.items).allSatisfy { $0.restSeconds == 120 && $0.targetLoad == 0 })
            XCTAssertTrue(workouts.flatMap(\.items).contains { $0.perSide == true })
        }
    }

    func testChangedAnswersAndLegacyReportInvalidateAcceptanceButDoNotRewriteOldPlan() throws {
        var value = profile()
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertTrue(ZeroOneFirstWeekPlanner.isCurrent(plan, for: value, availableVideoIDs: bundledIDs))
        value.starterSelectionPreferences = StarterSelectionPreferences(blockedGroups: [.pushing])
        XCTAssertFalse(ZeroOneFirstWeekPlanner.isCurrent(plan, for: value, availableVideoIDs: bundledIDs))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        payload.removeValue(forKey: "selectionReport")
        let legacy = try JSONDecoder().decode(ZeroOneFirstWeekPlan.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(legacy.selectionReport)
        XCTAssertEqual(legacy.sessions, plan.sessions)
        XCTAssertFalse(ZeroOneFirstWeekPlanner.isCurrent(legacy, for: profile(), availableVideoIDs: bundledIDs))
    }

    func testSevenSelectedDaysStaySelectedWithVisibleRecoveryReview() throws {
        var value = profile()
        value.preferredTrainingDays = Set(ZeroOneTrainingDay.allCases)
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(for: value, availableVideoIDs: bundledIDs))
        XCTAssertEqual(plan.trainingDays, ZeroOneTrainingDay.allCases)
        XCTAssertTrue(plan.selectionReport?.issues.contains(.closeTrainingDays) == true)
    }
}
