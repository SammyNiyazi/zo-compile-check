import XCTest
@testable import ZeroOne

@MainActor
final class NutritionEnergyTargetContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var today: Date { calendar.startOfDay(for: now) }
    private var target: NutritionEnergyTargetContext { .init(source: .selfChosen, intent: .performance) }
    private var guidance: NutritionGuidanceContext {
        .init(reportedAt: now, isAdult: true, needsTailoredNutrition: false,
            hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
    }

    func testExplicitTargetContextRequiresCurrentUnrestrictedAdultAnswers() {
        XCTAssertEqual(eligibility(nil), .unknownPersonalContext)
        for changed in [context(adult: nil), context(tailored: nil), context(food: nil), context(fluid: nil),
                        context(at: now.addingTimeInterval(-90 * 86_400 - 1)), context(at: now.addingTimeInterval(1))] {
            XCTAssertEqual(eligibility(changed), .unknownPersonalContext)
        }
        XCTAssertEqual(eligibility(context(at: now.addingTimeInterval(-90 * 86_400))), .reportedTargetComparison)
    }

    func testOldPositiveRestrictionsCannotExpireIntoTargetPermission() {
        let old = now.addingTimeInterval(-100 * 86_400)
        for changed in [context(at: old, adult: false), context(at: old, tailored: true),
                        context(at: old, food: true), context(at: old, fluid: true)] {
            XCTAssertEqual(eligibility(changed), .tailoredReview)
        }
    }

    func testReportedProfessionalAdviceDoesNotOverrideRestrictionsOrVerifyNeed() {
        let reported = NutritionEnergyTargetContext(source: .professionalReported, intent: .weightLoss)
        XCTAssertEqual(NutritionEnergyTargetPolicy.eligibility(guidance: context(tailored: true), target: reported, at: now), .tailoredReview)
        XCTAssertEqual(NutritionEnergyTargetPolicy.eligibility(guidance: nil, target: reported, at: now), .unknownPersonalContext)
        XCTAssertEqual(NutritionEnergyTargetPolicy.eligibility(guidance: guidance, target: reported, at: now), .reportedTargetComparison)
    }

    func testMissingSourcePurposeAndFutureMetadataRemainUnqualified() {
        for unknown in [nil, NutritionEnergyTargetContext(source: .notReported, intent: .performance),
                        .init(source: .selfChosen, intent: .notReported), .init(source: .selfChosen, intent: .performance, schemaVersion: 99)] {
            XCTAssertEqual(NutritionEnergyTargetPolicy.eligibility(guidance: guidance, target: unknown, at: now), .unknownTargetContext)
        }
    }

    func testNonFiniteClockNeverCreatesTargetEligibility() {
        for instant in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            XCTAssertEqual(NutritionEnergyTargetPolicy.eligibility(guidance: guidance, target: target, at: instant), .unknownPersonalContext)
        }
    }

    func testUnchangedLegacyTargetKeepsUnknownContextWithoutNewConfirmation() throws {
        let draft = NutritionEnergyTargetDraft(nil)
        XCTAssertNil(try draft.confirmedContext(goal: 2_500, replacing: 2_500, context: nil, confirmed: false))
        XCTAssertNil(try draft.confirmedContext(goal: nil, replacing: nil, context: nil, confirmed: false))
    }

    func testTargetSourcePurposeAmountAndRemovalChangesRequireConfirmation() throws {
        var draft = NutritionEnergyTargetDraft(target)
        XCTAssertThrowsError(try draft.confirmedContext(goal: 3_000, replacing: 2_500, context: target, confirmed: false))
        draft.source = .professionalReported
        XCTAssertThrowsError(try draft.confirmedContext(goal: 2_500, replacing: 2_500, context: target, confirmed: false))
        XCTAssertEqual(try draft.confirmedContext(goal: 2_500, replacing: 2_500, context: target, confirmed: true)?.source, .professionalReported)
        draft = NutritionEnergyTargetDraft(target); draft.intent = .weightGain
        XCTAssertThrowsError(try draft.confirmedContext(goal: 2_500, replacing: 2_500, context: target, confirmed: false))
        XCTAssertThrowsError(try draft.confirmedContext(goal: nil, replacing: 2_500, context: target, confirmed: false))
        XCTAssertNil(try draft.confirmedContext(goal: nil, replacing: 2_500, context: target, confirmed: true))
    }

    func testExplicitUnknownMetadataSurvivesAnUnchangedDraft() throws {
        let unknown = NutritionEnergyTargetContext(source: .notReported, intent: .notReported)
        XCTAssertEqual(try NutritionEnergyTargetDraft(unknown).confirmedContext(goal: 2_500, replacing: 2_500,
            context: unknown, confirmed: false), unknown)
    }

    func testTargetMetadataWithoutANumberOrUnknownVersionIsInvalid() throws {
        let data = try scenario()
        XCTAssertFalse(copy(data.reviews[0], clearsGoal: true, target: target).isStructurallyValid)
        XCTAssertFalse(copy(data.reviews[0], target: .init(source: .selfChosen, intent: .performance, schemaVersion: 99)).isStructurallyValid)
        XCTAssertTrue(copy(data.reviews[0], target: nil).isStructurallyValid)
    }

    func testQualifiedRepeatedDiscrepancyHoldsDemandUsingEachDayTarget() throws {
        let data = try scenario()
        let result = evaluate(data, guidance: guidance)
        let fuelling = try XCTUnwrap(result.recommendations.first { $0.kind == .fuelling })
        XCTAssertEqual(fuelling.demand, .easeTraining)
        XCTAssertTrue(fuelling.evidence.contains(.completeFoodLogsBelowChosenGoal))
        XCTAssertTrue(result.holdsAutomaticProgression)
        XCTAssertEqual(result.energyTargetReview?.comparisonDayCount, 2)
        XCTAssertTrue(fuelling.message.detailKey.contains("not measured calorie requirements"))
    }

    func testUnknownLegacyTargetStillPromptsCheckInWithoutNumericalDemandHold() throws {
        var data = try scenario(); data.reviews = data.reviews.map { copy($0, target: nil) }
        let result = evaluate(data, guidance: guidance)
        let fuelling = try XCTUnwrap(result.recommendations.first { $0.kind == .fuelling })
        XCTAssertEqual(fuelling.demand, .checkIn)
        XCTAssertTrue(fuelling.evidence.contains(.energyTargetContextUnknown))
        XCTAssertFalse(fuelling.evidence.contains(.completeFoodLogsBelowChosenGoal))
        XCTAssertFalse(result.holdsAutomaticProgression)
        XCTAssertEqual(result.energyTargetReview?.unqualifiedTargetDayCount, 2)
    }

    func testRestrictedAndUnknownPersonalContextPreserveNonNumericSymptomReview() throws {
        let data = try scenario()
        for personal in [nil, context(adult: false), context(tailored: true), context(food: true), context(fluid: true)] {
            let result = evaluate(data, guidance: personal)
            let fuelling = try XCTUnwrap(result.recommendations.first { $0.kind == .fuelling })
            XCTAssertEqual(fuelling.demand, .checkIn)
            XCTAssertFalse(fuelling.evidence.contains(.completeFoodLogsBelowChosenGoal))
            XCTAssertFalse(result.holdsAutomaticProgression)
            XCTAssertEqual(result.energyTargetReview?.comparisonDayCount, 0)
        }
    }

    func testTargetContextCannotEraseIndependentPainOrRecoveryHold() throws {
        let data = try scenario()
        let result = evaluate(data, guidance: nil, pain: true)
        XCTAssertEqual(result.recommendations.first?.kind, .symptoms)
        XCTAssertTrue(result.holdsAutomaticProgression)
        XCTAssertTrue(result.recommendations.contains { $0.kind == .fuelling && $0.demand == .checkIn })
    }

    func testPartialOrMealChangedReviewsCannotSupplyTargetComparisons() throws {
        var data = try scenario()
        data.reviews = data.reviews.map { copy($0, target: $0.energyTargetContext, coverage: .partial) }
        XCTAssertEqual(evaluate(data, guidance: guidance).energyTargetReview?.reportedTargetDayCount, 0)
        data = try scenario()
        data.meals.append(NutritionEntry(id: UUID(), title: "Later food", calories: 100, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, loggedAt: data.reviews[0].day.addingTimeInterval(7_200)))
        let result = evaluate(data, guidance: guidance)
        XCTAssertEqual(result.energyTargetReview?.comparisonDayCount, 1)
        XCTAssertFalse(result.recommendations.contains { $0.evidence.contains(.completeFoodLogsBelowChosenGoal) })
    }

    func testRawSourceAndIntentChangesBindAssessmentEvenWhenAdviceDoesNotChange() throws {
        let data = try scenario(); let original = evaluate(data, guidance: guidance)
        var changed = data
        changed.reviews[0] = copy(data.reviews[0], target: .init(source: .professionalReported, intent: .performance))
        let updated = evaluate(changed, guidance: guidance)
        XCTAssertEqual(original.recommendations, updated.recommendations)
        XCTAssertEqual(original.energyTargetReview?.comparisonDayCount, updated.energyTargetReview?.comparisonDayCount)
        XCTAssertNotEqual(original.energyTargetReview?.sourceFingerprint, updated.energyTargetReview?.sourceFingerprint)
        XCTAssertNotEqual(original, updated)
        changed.reviews[0] = copy(data.reviews[0], target: .init(source: .selfChosen, intent: .weightGain))
        XCTAssertNotEqual(original, evaluate(changed, guidance: guidance))
    }

    func testSourceFingerprintIsOrderStableAndClockIndependentWhileContextIsCurrent() throws {
        let data = try scenario()
        let first = NutritionEnergyTargetReview.assess(reviews: data.reviews, guidance: guidance, at: now)
        let second = NutritionEnergyTargetReview.assess(reviews: Array(data.reviews.reversed()), guidance: guidance,
            at: now.addingTimeInterval(60))
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first.sourceFingerprint)
    }

    func testActiveOptionRejectsChangedTargetSourceWithIdenticalConcernsAndPrescription() throws {
        let data = try scenario(); let initial = evaluate(data, guidance: guidance)
        let session = WorkoutSession(title: "Planned training", exercises: [WorkoutExercise(plan: workingPlan)])
        let adapter = WorkoutDemandAdapter()
        let offered = try adapter.proposal(for: session, change: .fewerSets, assessment: initial, at: now, calendar: calendar)
        XCTAssertNoThrow(try adapter.revalidated(offered, current: session, assessment: initial, at: now, calendar: calendar))
        var changed = data; changed.reviews[0] = copy(data.reviews[0], target: .init(source: .professionalReported, intent: .performance))
        let fresh = evaluate(changed, guidance: guidance)
        XCTAssertEqual(initial.recommendations, fresh.recommendations)
        let refreshed = try adapter.proposal(for: session, change: .fewerSets, assessment: fresh, at: now, calendar: calendar)
        XCTAssertEqual(refreshed.adaptedSession, offered.adaptedSession)
        XCTAssertThrowsError(try adapter.revalidated(offered, current: session, assessment: fresh, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .staleProposal)
        }
    }

    func testWeeklyOptionRejectsChangedTargetPurposeWithIdenticalConcernsAndWeekdays() throws {
        let data = try scenario(); let initial = evaluate(data, guidance: guidance)
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let schedule = try WorkoutProgrammeSchedule(programme: programme, weekdays: [2, 3, 4], confirmedAt: now)
        let availability = ReportedTrainingWeekdays(weekdays: [2, 3, 4], confirmedAt: now, timeZoneID: calendar.timeZone.identifier)
        func context(_ assessment: WellbeingAssessment) -> WeeklyTrainingContext {
            .init(programme: programme, schedule: schedule, assessment: assessment, hasUnfinishedWorkout: false, appointments: [])
        }
        let planner = WeeklyTrainingPlanner()
        let offered = try planner.proposal(change: .fewerDays, availability: availability, context: context(initial), at: now, calendar: calendar)
        XCTAssertNoThrow(try planner.revalidated(offered, context: context(initial), at: now, calendar: calendar))
        var changed = data; changed.reviews[0] = copy(data.reviews[0], target: .init(source: .selfChosen, intent: .weightGain))
        let fresh = evaluate(changed, guidance: guidance)
        let refreshed = try planner.proposal(change: .fewerDays, availability: availability, context: context(fresh), at: now, calendar: calendar)
        XCTAssertEqual(refreshed.concerns, offered.concerns); XCTAssertEqual(refreshed.proposedWeekdays, offered.proposedWeekdays)
        XCTAssertThrowsError(try planner.revalidated(offered, context: context(fresh), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WeeklyTrainingPlanningError, .stale)
        }
    }

    func testFutureVolumeOptionRejectsChangedTargetContextWithIdenticalSetCounts() throws {
        let data = try scenario(); let initial = evaluate(data, guidance: guidance)
        let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: .zeroOneStart))
        let recovery = recoveryReport()
        func context(_ assessment: WellbeingAssessment) -> ProgrammeVolumeContext {
            .init(programme: programme, revision: nil, calendarEvidence: .absent, assessment: assessment,
                recovery: recovery, hasUnfinishedWorkout: false)
        }
        let planner = ProgrammeVolumePlanner()
        let offered = try planner.proposal(change: .ease, context: context(initial), at: now, calendar: calendar)
        XCTAssertNoThrow(try planner.revalidated(offered, context: context(initial), at: now, calendar: calendar))
        var changed = data; changed.reviews[0] = copy(data.reviews[0], target: .init(source: .professionalReported, intent: .performance))
        let fresh = evaluate(changed, guidance: guidance)
        let refreshed = try planner.proposal(change: .ease, context: context(fresh), at: now, calendar: calendar)
        XCTAssertEqual(refreshed.concerns, offered.concerns); XCTAssertEqual(refreshed.after, offered.after)
        XCTAssertThrowsError(try planner.revalidated(offered, context: context(fresh), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
    }

    func testActualVersionThreeAmountsAndGuidanceReadWithoutRewritingLegacyBytes() throws {
        let data = try scenario(); let review = copy(data.reviews[0], target: nil,
            amounts: .init(coverage: .complete, fruitAndVegetablesGrams: 401, foodFibreGrams: 25,
                freeSugarGrams: nil, saltGrams: nil, basis: .foodRecords))
        let old = WellbeingCheckInSnapshot(nutrition: [review], version: 3, guidanceContext: guidance)
        let (defaults, name) = try temporaryDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let bytes = try JSONEncoder().encode(old); defaults.set(bytes, forKey: "checkins")
        let store = UserDefaultsWellbeingCheckInStore(defaults: defaults, key: "checkins")
        XCTAssertEqual(try store.load(), old); XCTAssertEqual(defaults.data(forKey: "checkins"), bytes)
        let repository = WellbeingCheckInRepository(store: store)
        try repository.save(recovery: nil, nutrition: review, replacing: old, at: now, calendar: calendar)
        XCTAssertEqual(try store.load().version, 4)
        XCTAssertEqual(try store.load().guidanceContext, guidance)
        XCTAssertEqual(try store.load().nutrition.first?.amounts, review.amounts)
        XCTAssertNil(try store.load().nutrition.first?.energyTargetContext)
    }

    func testHistoricalVersionIntroductionBoundariesAreEnforced() throws {
        let data = try scenario(); let review = data.reviews[0]
        XCTAssertFalse(WellbeingCheckInSnapshot(nutrition: [review], version: 3).isValid)
        XCTAssertTrue(WellbeingCheckInSnapshot(nutrition: [review], version: 4).isValid)
        let legacy = copy(review, target: nil)
        XCTAssertTrue(WellbeingCheckInSnapshot(nutrition: [legacy], version: 2).isValid)
        XCTAssertFalse(WellbeingCheckInSnapshot(nutrition: [legacy], version: 1).isValid)
        XCTAssertFalse(WellbeingCheckInSnapshot(nutrition: [legacy], version: 2, guidanceContext: guidance).isValid)
    }

    func testUnboundTargetEvidenceCannotAuthoriseAWorkoutOption() throws {
        let data = try scenario()
        let report = RecoveryCheckIn(id: UUID(), day: today, timeZoneID: calendar.timeZone.identifier, reportedAt: now,
            energy: .low, soreness: .severe, sleepHours: nil, hasNewOrWorseningPain: false, feelsUnwell: false,
            feelsUnusuallyHungry: false, feelsThirsty: false)
        let invalidGuidance = context(at: Date(timeIntervalSinceReferenceDate: .nan))
        let assessment = WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: data.history, outdoorHistory: [], recoveryCheckIns: [report], meals: data.meals,
            nutritionReviews: data.reviews, chosenFoodGoal: nil, hydration: nil, healthSleep: nil,
            nutritionGuidance: invalidGuidance))
        XCTAssertTrue(assessment.holdsAutomaticProgression)
        XCTAssertFalse(try XCTUnwrap(assessment.energyTargetReview).hasBoundSource)
        let session = WorkoutSession(title: "Planned training", exercises: [WorkoutExercise(plan: workingPlan)])
        XCTAssertThrowsError(try WorkoutDemandAdapter().proposal(for: session, change: .fewerSets,
            assessment: assessment, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? WorkoutDemandAdaptationError, .contextUnavailable)
        }
    }

    func testVersionFourTargetContextSurvivesActualStoreRelaunchAndExport() throws {
        let data = try scenario(); let (defaults, name) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWellbeingCheckInStore(defaults: defaults, key: "checkins")
        let repository = WellbeingCheckInRepository(store: store)
        try repository.save(recovery: nil, nutrition: data.reviews[0], replacing: repository.snapshot,
            at: now, calendar: calendar, guidanceContext: guidance)
        let restored = WellbeingCheckInRepository(store: store)
        XCTAssertEqual(restored.snapshot.nutrition.first?.energyTargetContext, target)
        let exported = try JSONEncoder().encode(restored.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: exported), restored.snapshot)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("energyTargetContext"))
    }

    func testTargetContextOnlyExternalCorrectionInvalidatesAnOpenRepositoryBaseline() throws {
        let data = try scenario(); let store = Store(WellbeingCheckInSnapshot(nutrition: data.reviews, guidanceContext: guidance))
        let repository = WellbeingCheckInRepository(store: store); let baseline = repository.snapshot
        var changed = data.reviews
        changed[0] = copy(changed[0], target: .init(source: .professionalReported, intent: .performance))
        store.value = WellbeingCheckInSnapshot(nutrition: changed, guidanceContext: guidance)
        XCTAssertThrowsError(try repository.save(recovery: nil, nutrition: data.reviews[0], replacing: baseline,
            at: now, calendar: calendar)) { XCTAssertEqual($0 as? WellbeingCheckInError, .changed) }
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(repository.snapshot, store.value)
    }

    func testUnsupportedNestedTargetFactsCannotBeDroppedByFollowingSave() throws {
        let data = try scenario(); let valid = WellbeingCheckInSnapshot(nutrition: data.reviews, guidanceContext: guidance)
        let (defaults, name) = try temporaryDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        for field in ["futureField", "schemaVersion", "source", "intent"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
            var rows = try XCTUnwrap(object["nutrition"] as? [[String: Any]])
            var context = try XCTUnwrap(rows[0]["energyTargetContext"] as? [String: Any])
            context[field] = field == "schemaVersion" ? 99 as Any : "unknown-value" as Any
            rows[0]["energyTargetContext"] = context; object["nutrition"] = rows
            let bytes = try JSONSerialization.data(withJSONObject: object); defaults.set(bytes, forKey: "checkins")
            let store = UserDefaultsWellbeingCheckInStore(defaults: defaults, key: "checkins")
            XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(valid))
            XCTAssertEqual(defaults.data(forKey: "checkins"), bytes)
        }
    }

    func testFutureSnapshotUnknownRootAndDuplicateKeysPreserveStoredBytes() throws {
        let data = try scenario(); let valid = WellbeingCheckInSnapshot(nutrition: data.reviews, guidanceContext: guidance)
        let (defaults, name) = try temporaryDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        future["version"] = 99
        var unknown = future; unknown["version"] = 4; unknown["futureContext"] = true
        let payloads = [try JSONSerialization.data(withJSONObject: future), try JSONSerialization.data(withJSONObject: unknown),
            Data("{\"version\":4,\"version\":3,\"recovery\":[],\"nutrition\":[]}".utf8)]
        for bytes in payloads {
            defaults.set(bytes, forKey: "checkins"); let store = UserDefaultsWellbeingCheckInStore(defaults: defaults, key: "checkins")
            XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(valid))
            XCTAssertEqual(defaults.data(forKey: "checkins"), bytes)
        }
    }

    func testRejectedAndLandedUnreadableWritesDoNotInventAcknowledgedContext() throws {
        let data = try scenario()
        for land in [false, true] {
            let store = Store(WellbeingCheckInSnapshot()); let repository = WellbeingCheckInRepository(store: store)
            let baseline = repository.snapshot; store.reject = !land; store.failAfterSave = land
            XCTAssertThrowsError(try repository.save(recovery: nil, nutrition: data.reviews[0], replacing: baseline,
                at: now, calendar: calendar, guidanceContext: guidance))
            XCTAssertEqual(repository.snapshot, baseline)
            if land {
                XCTAssertFalse(repository.isAvailable); store.readsFail = false; repository.reload()
                XCTAssertEqual(repository.snapshot.nutrition.first?.energyTargetContext, target)
                XCTAssertEqual(store.writes, 1)
            } else { XCTAssertTrue(repository.isAvailable); XCTAssertEqual(store.value, baseline) }
        }
    }

    private func context(at date: Date? = nil, adult: Bool? = true, tailored: Bool? = false,
                         food: Bool? = false, fluid: Bool? = false) -> NutritionGuidanceContext {
        .init(reportedAt: date ?? now, isAdult: adult, needsTailoredNutrition: tailored,
            hasFoodRestrictions: food, hasPrescribedFluidRestriction: fluid)
    }
    private func eligibility(_ context: NutritionGuidanceContext?) -> NutritionEnergyTargetEligibility {
        NutritionEnergyTargetPolicy.eligibility(guidance: context, target: target, at: now)
    }
    private struct Scenario { var meals: [NutritionEntry]; var reviews: [NutritionDayReview]; var history: [WorkoutHistoryEntry] }
    private var workingPlan: ExercisePlan {
        .init(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 3, restSeconds: 120, previousPerformance: [])
    }
    private func scenario() throws -> Scenario {
        let days = [-1, -2].map { calendar.date(byAdding: .day, value: $0, to: today)! }
        let meals = days.map { NutritionEntry(id: UUID(), title: "Synthetic food", calories: 900, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, loggedAt: $0.addingTimeInterval(3_600)) }
        let reviews = try days.map { day in
            NutritionDayReview(id: UUID(), day: day, timeZoneID: calendar.timeZone.identifier, reviewedAt: now,
                coverage: .complete, mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: meals, on: day, calendar: calendar)),
                reviewedFoodGroups: nil, reportedCalorieGoal: 2_500, energyTargetContext: target)
        }
        let plan = ExercisePlan(exerciseID: ExerciseIDs.gobletSquat, name: "Squat", targetLoad: Load(10),
            targetReps: RepRange(8, 12), plannedSetCount: 1, restSeconds: 120, previousPerformance: [])
        let history = days.map { day in
            WorkoutHistoryEntry(session: WorkoutSession(title: "Training", exercises: [WorkoutExercise(plan: plan,
                completedSets: [CompletedSet(load: Load(10), reps: 8, completedAt: day.addingTimeInterval(3_600))])],
                completedAt: day.addingTimeInterval(3_600)))
        }
        return Scenario(meals: meals, reviews: reviews, history: history)
    }
    private func copy(_ review: NutritionDayReview, goal: Int? = nil, clearsGoal: Bool = false, target: NutritionEnergyTargetContext?,
                      coverage: NutritionLogCoverage? = nil, amounts: NutritionDayAmounts? = nil) -> NutritionDayReview {
        .init(id: review.id, day: review.day, timeZoneID: review.timeZoneID, reviewedAt: review.reviewedAt,
            coverage: coverage ?? review.coverage, mealFingerprint: review.mealFingerprint, reviewedFoodGroups: review.reviewedFoodGroups,
            reportedCalorieGoal: clearsGoal ? nil : (goal ?? review.reportedCalorieGoal),
            amounts: amounts ?? review.amounts, energyTargetContext: target)
    }
    private func evaluate(_ data: Scenario, guidance: NutritionGuidanceContext?, pain: Bool = false) -> WellbeingAssessment {
        let report = recoveryReport(pain: pain)
        return WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar, strengthHistory: data.history,
            outdoorHistory: [], recoveryCheckIns: [report], meals: data.meals, nutritionReviews: data.reviews,
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil, nutritionGuidance: guidance))
    }
    private func recoveryReport(pain: Bool = false) -> RecoveryCheckIn {
        .init(id: UUID(), day: today, timeZoneID: calendar.timeZone.identifier, reportedAt: now,
            energy: .low, soreness: .none, sleepHours: nil, hasNewOrWorseningPain: pain, feelsUnwell: false,
            feelsUnusuallyHungry: false, feelsThirsty: false)
    }
    private func temporaryDefaults() throws -> (UserDefaults, String) {
        let name = "EnergyTarget-" + UUID().uuidString; return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
    private final class Store: WellbeingCheckInPersisting {
        var value: WellbeingCheckInSnapshot; var writes = 0; var reject = false; var failAfterSave = false; var readsFail = false
        init(_ value: WellbeingCheckInSnapshot) { self.value = value }
        func load() throws -> WellbeingCheckInSnapshot {
            if readsFail { throw WellbeingCheckInError.unavailable }; return value
        }
        func save(_ value: WellbeingCheckInSnapshot) throws {
            writes += 1; if reject { throw WellbeingCheckInError.saveNotConfirmed }
            self.value = value; if failAfterSave { readsFail = true }
        }
    }
}
