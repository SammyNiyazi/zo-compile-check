import XCTest
@testable import ZeroOne

@MainActor
final class ExerciseSubstitutionSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)
    private let selector = ExerciseSubstitutionSelector()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let videos: Set<String> = ["dumbbell-curl", "push-up", "chest-supported-dumbbell-row", "lat-pulldown", "machine-assisted-pull-up"]

    func testKnownEquipmentOffersAnAuthoredAlternativeAndItsOwnTarget() throws {
        let model = try model()
        let review = try offer(model)
        XCTAssertEqual(review.candidates.map(\.definition.id), [ExerciseIDs.dumbbellCurl])
        let definition = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellCurl))
        XCTAssertEqual(review.candidates[0].target.lowerBound, definition.defaultRepRange.lowerBound)
        XCTAssertEqual(review.candidates[0].target.unit, .repetitions)
        XCTAssertFalse(review.candidates[0].target.perSide)
        XCTAssertEqual(try offer(model), review)
    }

    func testMissingConflictingEquipmentAndUnknownConstraintsCannotQualify() throws {
        let model = try model()
        let equipmentCases: [Set<ZeroOneEquipmentItem>?] = [nil, [], [.none, .dumbbells]]
        for equipment in equipmentCases {
            var profile = profile()
            profile.availableEquipment = equipment
            XCTAssertThrowsError(try offer(model, context: context(profile))) {
                XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .context)
            }
        }
        let constraintCases: [ZeroOneTrainingConstraint?] = [nil, .notSure]
        for constraint in constraintCases {
            var profile = profile()
            profile.trainingConstraint = constraint
            XCTAssertThrowsError(try offer(model, context: context(profile)))
        }
    }

    func testAuxiliaryBenchSupportIsNotInferredFromDumbbellsOrGenericBench() throws {
        let model = try model(id: ExerciseIDs.seatedCableRow)
        var profile = profile()
        profile.availableEquipment = [.dumbbells, .bench]
        XCTAssertThrowsError(try offer(model, context: context(profile)))
        profile.starterSelectionPreferences = .init(confirmedEquipment: [.inclineBench])
        let review = try offer(model, context: context(profile))
        XCTAssertEqual(review.candidates.map(\.definition.id), [ExerciseIDs.chestSupportedRow])
    }

    func testSpecificMachineStationNeedsConfirmationBeyondGenericMachines() throws {
        let model = try model(id: ExerciseIDs.assistedPullUp)
        var profile = profile()
        profile.availableEquipment = [.machines]
        XCTAssertThrowsError(try offer(model, context: context(profile)))
        profile.starterSelectionPreferences = .init(confirmedEquipment: [.latPulldown])
        XCTAssertEqual(try offer(model, context: context(profile)).candidates.map(\.definition.id), [ExerciseIDs.latPulldown])
    }

    func testMovementAndExerciseExclusionsPrecedeRanking() throws {
        let model = try model()
        var profile = profile()
        profile.starterSelectionPreferences = .init(blockedGroups: [.pulling], preferredVideoIDs: ["dumbbell-curl"])
        XCTAssertThrowsError(try offer(model, context: context(profile)))
        profile.starterSelectionPreferences = .init(blockedExerciseIDs: [ExerciseIDs.dumbbellCurl], familiarVideoIDs: ["dumbbell-curl"])
        XCTAssertThrowsError(try offer(model, context: context(profile)))
    }

    func testUnresolvedSensitivityNeedsReviewAndExplicitExclusionsRemainEffective() throws {
        let model = try model()
        var profile = profile()
        profile.trainingConstraint = .movementSensitivity
        XCTAssertThrowsError(try offer(model, context: context(profile))) {
            XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .context)
        }
        profile.starterSelectionPreferences = .init(blockedGroups: [.pushing])
        XCTAssertEqual(try offer(model, context: context(profile)).candidates.count, 1)
        profile.starterSelectionPreferences = .init(blockedGroups: [.pulling])
        XCTAssertThrowsError(try offer(model, context: context(profile)))
    }

    func testMissingVideoCannotQualifyThroughCatalogueMembership() throws {
        let model = try model()
        XCTAssertThrowsError(try selector.review(session: model.session, input: model.substitutionInput,
            context: context(), availableVideoIDs: [], at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .noAlternative)
        }
    }

    func testExactSeedCustomItemCanUseAuthoredAlternativesButMovVariationCannot() throws {
        var session = try model().session
        let source = try XCTUnwrap(session.currentExercise?.plan)
        let exact = ExercisePlan(id: source.id, exerciseID: source.exerciseID, name: source.name,
            targetLoad: source.targetLoad, targetReps: source.targetReps, plannedSetCount: source.plannedSetCount,
            restSeconds: source.restSeconds, previousPerformance: [])
        session = WorkoutSession(id: session.id, title: session.title, programmeID: .biceps, exercises: [.init(plan: exact)])
        let exactModel = WorkoutViewModel(session: session, persistInitialSnapshot: false)
        XCTAssertEqual(try offer(exactModel).candidates.count, 1)
        let variation = ExercisePlan(id: source.id, exerciseID: "MOV-dumbbell-hammer-curl", name: source.name,
            targetLoad: source.targetLoad, targetReps: source.targetReps, plannedSetCount: source.plannedSetCount,
            restSeconds: source.restSeconds, previousPerformance: [], alternativeExerciseIDs: [ExerciseIDs.dumbbellCurl])
        session = WorkoutSession(id: session.id, title: session.title, programmeID: .biceps, exercises: [.init(plan: variation)])
        XCTAssertThrowsError(try offer(WorkoutViewModel(session: session, persistInitialSnapshot: false)))
    }

    func testNewPainUsesActualWellbeingEngineAndPreventsSwap() throws {
        let report = RecoveryCheckIn(id: UUID(), day: calendar.startOfDay(for: now),
            timeZoneID: calendar.timeZone.identifier, reportedAt: now, energy: .usual, soreness: .none,
            sleepHours: nil, hasNewOrWorseningPain: true, feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: nil)
        let assessment = WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [report], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
        XCTAssertThrowsError(try offer(try model(), context: .init(profile: profile(), assessment: assessment))) {
            XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .symptoms)
        }
    }

    func testSourceInputProfileAndAvailableMediaChangesInvalidateAcceptance() throws {
        let model = try model()
        let review = try offer(model)
        var changedProfile = profile()
        changedProfile.availableEquipment = [.none]
        XCTAssertThrowsError(try accept(model, review: review, context: context(changedProfile)))
        model.enteredRIR = 3
        XCTAssertThrowsError(try accept(model, review: review)) {
            XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .stale)
        }
        model.enteredRIR = nil
        XCTAssertThrowsError(try model.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10),
            review: review, context: context(), confirmedAt: now, at: now, calendar: calendar, availableVideoIDs: []))
        XCTAssertEqual(model.session, review.session)
    }

    func testConfirmationExpiredFutureWrongZoneAndWrongDayFailClosed() throws {
        let model = try model()
        let review = try offer(model)
        let confirmationCases: [Date?] = [nil, now.addingTimeInterval(-1), now.addingTimeInterval(1)]
        for date in confirmationCases {
            XCTAssertThrowsError(try model.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10),
                review: review, context: context(), confirmedAt: date, at: now, calendar: calendar, availableVideoIDs: videos))
        }
        let later = now.addingTimeInterval(601)
        XCTAssertThrowsError(try selector.revalidated(review, selected: ExerciseIDs.dumbbellCurl, session: model.session,
            input: model.substitutionInput, context: context(at: later), availableVideoIDs: videos,
            confirmedAt: later, at: later, calendar: calendar))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let beforeMidnight = nextDay.addingTimeInterval(-60)
        let afterMidnight = nextDay.addingTimeInterval(60)
        let midnightReview = try selector.review(session: model.session, input: model.substitutionInput,
            context: context(at: beforeMidnight), availableVideoIDs: videos, at: beforeMidnight, calendar: calendar)
        XCTAssertThrowsError(try selector.revalidated(midnightReview, selected: ExerciseIDs.dumbbellCurl,
            session: model.session, input: model.substitutionInput, context: context(at: afterMidnight),
            availableVideoIDs: videos, confirmedAt: afterMidnight, at: afterMidnight, calendar: calendar)) {
            XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .stale)
        }
        var other = calendar
        other.timeZone = TimeZone(identifier: "Europe/Sofia")!
        XCTAssertThrowsError(try selector.revalidated(review, selected: ExerciseIDs.dumbbellCurl, session: model.session,
            input: model.substitutionInput, context: context(), availableVideoIDs: videos,
            confirmedAt: now, at: now, calendar: other))
    }

    func testStartedOrPausedExerciseCannotApplyAndDoesNotRewritePerformedWork() throws {
        let model = try model()
        let review = try offer(model)
        model.togglePause(at: now)
        XCTAssertThrowsError(try accept(model, review: review))
        model.togglePause(at: now)
        model.completeCurrentSet(at: now)
        let performed = model.session
        XCTAssertThrowsError(try accept(model, review: review))
        XCTAssertEqual(model.session, performed)
    }

    func testReplacementDoesNotCopyTimedPerSideTargetOrPriorPerformance() throws {
        var session = try model().session
        let original = try XCTUnwrap(session.currentExercise?.plan)
        let timed = ExercisePlan(id: original.id, exerciseID: original.exerciseID, name: original.name,
            targetLoad: original.targetLoad, targetReps: original.targetReps, plannedSetCount: 2, restSeconds: 90,
            previousPerformance: [.init(load: Load(20), reps: 12)],
            alternativeExerciseIDs: original.alternativeExerciseIDs,
            targetPrescription: .init(unit: .seconds, lowerBound: 30, upperBound: 45, perSide: true))
        session = WorkoutSession(id: session.id, title: session.title, programmeID: .biceps, exercises: [.init(plan: timed)])
        try session.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10))
        let replacement = try XCTUnwrap(session.currentExercise?.plan)
        XCTAssertEqual(replacement.prescription.unit, .repetitions)
        XCTAssertFalse(replacement.prescription.perSide)
        XCTAssertEqual(replacement.plannedSetCount, 2)
        XCTAssertEqual(replacement.restSeconds, 90)
        XCTAssertTrue(replacement.previousPerformance.isEmpty)
        XCTAssertEqual(replacement.id, timed.id)
    }

    func testRealRecoveryStorePreservesManualInputUndoAcrossRelaunch() throws {
        let name = "01.swap-review." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsActiveWorkoutStore(defaults: defaults, key: "active")
        let model = try model(save: { snapshot, id in
            if let snapshot { try store.save(snapshot) } else { try store.clear(expectedSessionID: id) }
        })
        model.enteredLoadValue = 17
        model.loadDraft = "-"
        model.repsDraft = "13"
        model.enteredRIR = 4
        let before = model.substitutionInput
        XCTAssertTrue(try accept(model, review: offer(model)))
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.version, ActiveWorkoutSnapshot.currentVersion)
        let relaunched = WorkoutViewModel(session: saved.session, restoredSnapshot: saved, persistInitialSnapshot: false,
            onSnapshotChanged: { snapshot, id in
                if let snapshot { try store.save(snapshot) } else { try store.clear(expectedSessionID: id) }
            })
        XCTAssertTrue(relaunched.undoCurrentSubstitution())
        XCTAssertEqual(relaunched.substitutionInput, before)
        XCTAssertNil(try store.load()?.session.currentExercise?.substitutionInput)
        XCTAssertEqual(try store.load()?.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellHammerCurl)
    }

    func testUnknownLegacyInputAndFutureRecoveryVersionAreNotInvented() throws {
        var session = try model().session
        try session.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10))
        let snapshot = ActiveWorkoutSnapshot(version: 4, session: session, enteredLoadValue: 10, enteredReps: 10,
            enteredRIR: nil, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        let decoded = try JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(decoded.isCompatible)
        XCTAssertNil(decoded.session.currentExercise?.substitutionInput)
        let future = ActiveWorkoutSnapshot(version: ActiveWorkoutSnapshot.currentVersion + 1, session: session, enteredLoadValue: 10, enteredReps: 10,
            enteredRIR: nil, isPaused: false, pausedRemainingRestSeconds: nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
        XCTAssertFalse(future.isCompatible)
    }

    func testUninstalledOrUnavailableAuthorityCannotCreatePermission() async throws {
        let authority = ExerciseSubstitutionAuthority()
        let session = try model().session
        do { _ = try await authority.context(for: session); XCTFail("Uninstalled reader must reject") }
        catch { XCTAssertEqual(error as? ExerciseSubstitutionSelectionError, .unavailable) }
        authority.install { _ in throw WorkoutPersistenceError.unavailable }
        do { _ = try await authority.context(for: session); XCTFail("Unavailable source must reject") }
        catch { XCTAssertEqual(error as? WorkoutPersistenceError, .unavailable) }
    }

    func testTargetSourceOrPurposeCorrectionRejectsOldSwapThroughFreshAuthorityWithoutWriting() async throws {
        let changes: [NutritionEnergyTargetContext] = [
            .init(source: .professionalReported, intent: .performance),
            .init(source: .selfChosen, intent: .weightGain)
        ]
        for changed in changes {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
            let original = NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier,
                reviewedAt: now, coverage: .complete,
                mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: [], on: day, calendar: calendar)),
                reviewedFoodGroups: nil, reportedCalorieGoal: 2_500,
                energyTargetContext: .init(source: .selfChosen, intent: .performance))
            let guidance = NutritionGuidanceContext(reportedAt: now, isAdult: true, needsTailoredNutrition: false,
                hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
            let store = SubstitutionTargetTestStore(.init(nutrition: [original], guidanceContext: guidance))
            let recovery = WellbeingCheckInRepository(store: store)
            let authority = ExerciseSubstitutionAuthority()
            authority.install { [self] _ in
                recovery.reload()
                guard recovery.isAvailable else { throw ExerciseSubstitutionSelectionError.unavailable }
                return .init(profile: profile(), assessment: WellbeingRecommendationEngine().assess(.init(
                    asOf: now, calendar: calendar, strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [],
                    meals: [], nutritionReviews: recovery.snapshot.nutrition, chosenFoodGoal: nil,
                    hydration: nil, healthSleep: nil, nutritionGuidance: recovery.snapshot.guidanceContext)))
            }
            var snapshotWrites = 0
            let model = try model(save: { _, _ in snapshotWrites += 1 })
            model.selectLoad(Load(17))
            let before = model.session
            let input = model.substitutionInput
            let source = try await authority.context(for: before)
            let presented = try offer(model, context: source)
            let corrected = NutritionDayReview(id: original.id, day: day, timeZoneID: original.timeZoneID,
                reviewedAt: original.reviewedAt, coverage: original.coverage, mealFingerprint: original.mealFingerprint,
                reviewedFoodGroups: nil, reportedCalorieGoal: original.reportedCalorieGoal,
                energyTargetContext: changed)
            try recovery.save(recovery: nil, nutrition: corrected, replacing: recovery.snapshot,
                at: now, calendar: calendar, guidanceContext: guidance)
            let fresh = try await authority.context(for: model.session)
            let reopened = try offer(model, context: fresh)
            XCTAssertEqual(source.assessment.recommendations, fresh.assessment.recommendations)
            XCTAssertEqual(presented.candidates, reopened.candidates)
            XCTAssertNotEqual(source.assessment.energyTargetReview?.sourceFingerprint,
                fresh.assessment.energyTargetReview?.sourceFingerprint)
            let writesBeforeAcceptance = snapshotWrites
            XCTAssertThrowsError(try accept(model, review: presented, context: fresh)) {
                XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .stale)
            }
            XCTAssertEqual(model.session, before)
            XCTAssertEqual(model.substitutionInput, input)
            XCTAssertEqual(snapshotWrites, writesBeforeAcceptance)
            XCTAssertEqual(store.value.nutrition, [corrected])
            XCTAssertTrue(try accept(model, review: reopened, context: fresh))
            XCTAssertEqual(snapshotWrites, writesBeforeAcceptance + 1)
            XCTAssertEqual(model.session.currentExercise?.plan.exerciseID, ExerciseIDs.dumbbellCurl)
        }
    }

    func testPresentUnboundTargetReviewCannotOfferASwapOrWriteAManualDraft() throws {
        let model = try model()
        let before = model.session
        let input = model.substitutionInput
        for fingerprint in [nil, "unsupported"] as [String?] {
            let unbound = WellbeingAssessment(recommendations: [], recordedTrainingDays: 0, reviewedNutritionDays: 0,
                hasCurrentRecoveryReport: false, hasConflictingSleep: false, evaluatedAt: now,
                timeZoneID: calendar.timeZone.identifier,
                energyTargetReview: .init(eligibility: .unknownPersonalContext, reportedTargetDayCount: 1,
                    comparisonDayCount: 0, unqualifiedTargetDayCount: 1, sourceFingerprint: fingerprint))
            XCTAssertThrowsError(try offer(model, context: .init(profile: profile(), assessment: unbound))) {
                XCTAssertEqual($0 as? ExerciseSubstitutionSelectionError, .unavailable)
            }
            XCTAssertEqual(model.session, before)
            XCTAssertEqual(model.substitutionInput, input)
        }
    }

    private func profile() -> ZeroOneUserProfile {
        var value = ZeroOneUserProfile()
        value.availableEquipment = [.dumbbells]
        value.trainingExperience = .startingOut
        value.trainingConstraint = .some(.none)
        return value
    }
    private func context(_ profile: ZeroOneUserProfile? = nil, at stamp: Date? = nil) -> ExerciseSubstitutionContext {
        .init(profile: profile ?? self.profile(), assessment: .init(recommendations: [], recordedTrainingDays: 0,
            reviewedNutritionDays: 0, hasCurrentRecoveryReport: false, hasConflictingSleep: false,
            evaluatedAt: stamp ?? now, timeZoneID: calendar.timeZone.identifier))
    }
    private func model(id: ExerciseID = ExerciseIDs.dumbbellHammerCurl,
                       save: @escaping (ActiveWorkoutSnapshot?, UUID) throws -> Void = { _, _ in }) throws -> WorkoutViewModel {
        let definition = try XCTUnwrap(ExerciseLibrary.exercise(id: id))
        let plan = ExercisePlan(exerciseID: id, name: definition.name, targetLoad: Load(16),
            targetReps: .init(8, 12), plannedSetCount: 2, restSeconds: 90, previousPerformance: [],
            alternativeExerciseIDs: definition.resolvedAlternativeIDs)
        return WorkoutViewModel(session: .init(title: "Selection fixture", programmeID: .biceps, exercises: [.init(plan: plan)]),
            onSnapshotChanged: save)
    }
    private func offer(_ model: WorkoutViewModel, context: ExerciseSubstitutionContext? = nil) throws -> ExerciseSubstitutionReview {
        try selector.review(session: model.session, input: model.substitutionInput, context: context ?? self.context(),
            availableVideoIDs: videos, at: now, calendar: calendar)
    }
    private func accept(_ model: WorkoutViewModel, review: ExerciseSubstitutionReview,
                        context: ExerciseSubstitutionContext? = nil) throws -> Bool {
        try model.substituteCurrentExercise(with: ExerciseIDs.dumbbellCurl, load: Load(10), review: review,
            context: context ?? self.context(), confirmedAt: now, at: now, calendar: calendar, availableVideoIDs: videos)
    }
}

private final class SubstitutionTargetTestStore: WellbeingCheckInPersisting {
    var value: WellbeingCheckInSnapshot
    init(_ value: WellbeingCheckInSnapshot) { self.value = value }
    func load() throws -> WellbeingCheckInSnapshot { value }
    func save(_ value: WellbeingCheckInSnapshot) throws { self.value = value }
}
