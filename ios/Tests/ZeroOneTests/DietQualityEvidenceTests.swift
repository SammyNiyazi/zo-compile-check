import XCTest
@testable import ZeroOne

@MainActor
final class DietQualityEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }
    private var meals: [NutritionEntry] {
        [-1, -2, -3].map { offset in
            NutritionEntry(id: UUID(), title: "Synthetic complete food day", calories: 1_800, proteinGrams: nil,
                carbohydrateGrams: nil, fatGrams: nil, loggedAt: day(offset).addingTimeInterval(3_600))
        }
    }
    private var quantities: NutritionDayAmounts {
        .init(coverage: .complete, fruitAndVegetablesGrams: 300, foodFibreGrams: 10,
            freeSugarGrams: 60, saltGrams: 6, basis: .foodRecords)
    }
    private var eligible: NutritionGuidanceContext {
        .init(reportedAt: now, isAdult: true, needsTailoredNutrition: false,
            hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
    }

    func testKnownCompleteAmountsAndAdultContextProduceSpecificReviewsWithoutAScore() throws {
        let food = meals
        let reviews = try reviews(food: food, amounts: quantities)
        let value = assess(food: food, reviews: reviews, guidance: eligible)
        XCTAssertEqual(value.eligibility, .generalAdultReview)
        XCTAssertEqual(value.completeFoodDayCount, 3)
        XCTAssertEqual(value.completeAmountDayCount, 3)
        XCTAssertEqual(Set(value.findings), [.lowFruitAndVegetables, .lowFoodFibre, .highFreeSugar, .highSalt])
        XCTAssertFalse(value.hasConflictingSugarEnergy)
        let live = wellbeing(food: food, reviews: reviews, guidance: eligible)
        XCTAssertEqual(live.recommendations.first?.kind, .foodVariety)
        XCTAssertEqual(live.recommendations.first?.message.titleKey, "Review food amounts")
        XCTAssertFalse(live.holdsAutomaticProgression)
    }

    func testUnknownAgeOrLimitsCannotBecomeGeneralAdultEligibility() throws {
        let food = meals
        let reviews = try reviews(food: food, amounts: quantities)
        for guidance in [nil, NutritionGuidanceContext(reportedAt: now, isAdult: nil,
             needsTailoredNutrition: false, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false),
             NutritionGuidanceContext(reportedAt: now, isAdult: true,
             needsTailoredNutrition: nil, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)] {
            let value = assess(food: food, reviews: reviews, guidance: guidance)
            XCTAssertEqual(value.eligibility, .unknown)
            XCTAssertTrue(value.findings.isEmpty)
            let live = wellbeing(food: food, reviews: reviews, guidance: guidance)
            XCTAssertTrue(live.recommendations.flatMap(\.evidence).contains(.nutritionContextUnknown))
            XCTAssertFalse(live.holdsAutomaticProgression)
        }
    }

    func testReportedRestrictionsAndYoungerAgeWithholdAdultReferences() throws {
        let food = meals
        let reviews = try reviews(food: food, amounts: quantities)
        let contexts = [
            NutritionGuidanceContext(reportedAt: now, isAdult: false, needsTailoredNutrition: false, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false),
            NutritionGuidanceContext(reportedAt: now, isAdult: true, needsTailoredNutrition: true, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false),
            NutritionGuidanceContext(reportedAt: now, isAdult: true, needsTailoredNutrition: false, hasFoodRestrictions: true, hasPrescribedFluidRestriction: false),
            NutritionGuidanceContext(reportedAt: now, isAdult: true, needsTailoredNutrition: false, hasFoodRestrictions: false, hasPrescribedFluidRestriction: true)
        ]
        for context in contexts {
            let value = assess(food: food, reviews: reviews, guidance: context)
            XCTAssertEqual(value.eligibility, .tailoredReview)
            XCTAssertTrue(value.findings.isEmpty)
            XCTAssertTrue(wellbeing(food: food, reviews: reviews, guidance: context).recommendations
                .flatMap(\.evidence).contains(.tailoredNutritionNeeded))
        }
    }

    func testExpiredNegativeContextBecomesUnknownButAnOldRestrictionRemainsCautious() {
        let old = now.addingTimeInterval(-91 * 86_400)
        let staleNegative = NutritionGuidanceContext(reportedAt: old, isAdult: true, needsTailoredNutrition: false,
            hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
        XCTAssertFalse(staleNegative.permitsGeneralAdultAmounts(at: now))
        let oldPositive = NutritionGuidanceContext(reportedAt: old, isAdult: true, needsTailoredNutrition: true,
            hasFoodRestrictions: nil, hasPrescribedFluidRestriction: nil)
        XCTAssertTrue(oldPositive.requiresTailoredReview(at: now))
        let future = NutritionGuidanceContext(reportedAt: now.addingTimeInterval(1), isAdult: true,
            needsTailoredNutrition: false, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
        XCTAssertFalse(future.permitsGeneralAdultAmounts(at: now))
    }

    func testPartialFoodAndPartialEstimatedOrUnsourcedAmountsCannotCreateFindings() throws {
        let food = meals
        let partialFood = try reviews(food: food, amounts: quantities, coverage: .partial)
        XCTAssertTrue(assess(food: food, reviews: partialFood, guidance: eligible).findings.isEmpty)
        XCTAssertEqual(assess(food: food, reviews: partialFood, guidance: eligible).completeAmountDayCount, 0)
        for basis in [NutritionAmountBasis.estimated, .mixed, .notReported] {
            let amounts = NutritionDayAmounts(coverage: .complete, fruitAndVegetablesGrams: 0,
                foodFibreGrams: 0, freeSugarGrams: 100, saltGrams: 8, basis: basis)
            let value = assess(food: food, reviews: try reviews(food: food, amounts: amounts), guidance: eligible)
            XCTAssertTrue(value.findings.isEmpty)
            XCTAssertEqual(value.unqualifiedAmountDayCount, 3)
        }
        let partial = NutritionDayAmounts(coverage: .partial, fruitAndVegetablesGrams: 0,
            foodFibreGrams: 0, freeSugarGrams: nil, saltGrams: nil, basis: .foodRecords)
        XCTAssertTrue(assess(food: food, reviews: try reviews(food: food, amounts: partial), guidance: eligible).findings.isEmpty)
    }

    func testUnknownAmountsAndExplicitZeroRemainDifferent() throws {
        let food = meals
        let unknown = NutritionDayAmounts(coverage: .complete, fruitAndVegetablesGrams: nil,
            foodFibreGrams: nil, freeSugarGrams: nil, saltGrams: nil, basis: .foodRecords)
        let unknownAssessment = assess(food: food, reviews: try reviews(food: food, amounts: unknown), guidance: eligible)
        XCTAssertEqual(unknownAssessment.completeAmountDayCount, 0)
        XCTAssertTrue(unknownAssessment.findings.isEmpty)
        let zero = NutritionDayAmounts(coverage: .complete, fruitAndVegetablesGrams: 0,
            foodFibreGrams: nil, freeSugarGrams: 0, saltGrams: nil, basis: .foodRecords)
        let zeroAssessment = assess(food: food, reviews: try reviews(food: food, amounts: zero), guidance: eligible)
        XCTAssertEqual(zeroAssessment.findings, [.lowFruitAndVegetables])
        XCTAssertEqual(zeroAssessment.foodFibreDayCount, 0)
        XCTAssertEqual(zeroAssessment.freeSugarDayCount, 3)
    }

    func testSingleDayOrReferenceBoundaryDoesNotManufactureAPattern() throws {
        let food = meals
        let one = try reviews(food: food, amounts: quantities).prefix(1)
        XCTAssertTrue(assess(food: food, reviews: Array(one), guidance: eligible).findings.isEmpty)
        let reference = NutritionDayAmounts(coverage: .complete, fruitAndVegetablesGrams: 400,
            foodFibreGrams: 25, freeSugarGrams: 44, saltGrams: 4.9, basis: .foodRecords)
        XCTAssertTrue(assess(food: food, reviews: try reviews(food: food, amounts: reference), guidance: eligible).findings.isEmpty)
    }

    func testChangedMealsInvalidateAmountsAndHistoricalGoalDoesNotSupplyEnergy() throws {
        let food = meals
        let reviews = try reviews(food: food, amounts: quantities)
        let edited = food.map { NutritionEntry(id: $0.id, title: $0.title, calories: 900, proteinGrams: nil,
            carbohydrateGrams: nil, fatGrams: nil, loggedAt: $0.loggedAt) }
        XCTAssertEqual(assess(food: edited, reviews: reviews, guidance: eligible).completeFoodDayCount, 0)
        let withChangedGoal = try self.reviews(food: food, amounts: quantities, goal: 10_000)
        XCTAssertEqual(assess(food: food, reviews: withChangedGoal, guidance: eligible).findings,
            assess(food: food, reviews: reviews, guidance: eligible).findings)
    }

    func testConflictingSugarEnergyIsOmittedRatherThanComparedWithAGoal() throws {
        let food = meals
        let impossible = NutritionDayAmounts(coverage: .complete, fruitAndVegetablesGrams: nil,
            foodFibreGrams: nil, freeSugarGrams: 1_000, saltGrams: nil, basis: .foodRecords)
        let value = assess(food: food, reviews: try reviews(food: food, amounts: impossible, goal: 10_000), guidance: eligible)
        XCTAssertTrue(value.hasConflictingSugarEnergy)
        XCTAssertEqual(value.freeSugarDayCount, 0)
        XCTAssertFalse(value.findings.contains(.highFreeSugar))
    }

    func testDuplicateConflictingOrFutureReviewsFailClosed() throws {
        let food = meals
        let reviews = try reviews(food: food, amounts: quantities)
        XCTAssertTrue(assess(food: food, reviews: reviews + reviews, guidance: eligible).findings.isEmpty)
        let original = reviews[0]
        let conflicting = NutritionDayReview(id: UUID(), day: original.day, timeZoneID: original.timeZoneID,
            reviewedAt: now, coverage: .complete, mealFingerprint: original.mealFingerprint, reviewedFoodGroups: nil,
            amounts: quantities)
        XCTAssertFalse(assess(food: food, reviews: reviews + [conflicting], guidance: eligible).findings.contains(.highSalt))
        let future = reviews.map { NutritionDayReview(id: $0.id, day: $0.day, timeZoneID: $0.timeZoneID,
            reviewedAt: now.addingTimeInterval(1), coverage: .complete, mealFingerprint: $0.mealFingerprint,
            reviewedFoodGroups: nil, amounts: quantities) }
        XCTAssertTrue(assess(food: food, reviews: future, guidance: eligible).findings.isEmpty)
    }

    func testActualAmountDraftPreservesZeroUnknownAndRejectsNonFiniteOrWrongRange() throws {
        var draft = NutritionDayAmountsDraft()
        draft.coverage = .complete; draft.basis = .foodRecords
        draft.fruitAndVegetables = "0"; draft.salt = "4,5"
        let value = try draft.validated()
        XCTAssertEqual(value.fruitAndVegetablesGrams, 0)
        XCTAssertNil(value.foodFibreGrams)
        XCTAssertEqual(value.saltGrams, 4.5)
        XCTAssertEqual(try NutritionDayAmountsDraft(value).validated(), value)
        for invalid in ["-1", "NaN", "inf", "20001", "unknown"] {
            draft.fruitAndVegetables = invalid
            XCTAssertThrowsError(try draft.validated())
        }
    }

    func testPrescribedFluidRestrictionOverridesGoalAndSurvivesContextAge() {
        let guidance = NutritionGuidanceContext(reportedAt: now.addingTimeInterval(-91 * 86_400), isAdult: true,
            needsTailoredNutrition: nil, hasFoodRestrictions: nil, hasPrescribedFluidRestriction: true)
        let report = RecoveryCheckIn(id: UUID(), day: day(0), timeZoneID: calendar.timeZone.identifier,
            reportedAt: now, energy: .usual, soreness: .none, sleepHours: nil, hasNewOrWorseningPain: nil,
            feelsUnwell: nil, feelsUnusuallyHungry: nil, feelsThirsty: true)
        let result = WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [report], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil, nutritionGuidance: guidance))
        XCTAssertTrue(result.recommendations.first?.evidence.contains(.prescribedFluidRestriction) == true)
        XCTAssertTrue(result.recommendations.first?.message.detailKey.contains("Follow that plan") == true)
        XCTAssertFalse(result.holdsAutomaticProgression)
    }

    func testVersionThreeContextAndAmountsSurviveRelaunchExportAndExplicitDeletion() throws {
        let name = "01.dietQualityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWellbeingCheckInStore(defaults: defaults)
        let repository = WellbeingCheckInRepository(store: store)
        let food = meals
        let review = try XCTUnwrap(reviews(food: food, amounts: quantities).first)
        try repository.save(recovery: nil, nutrition: review, replacing: repository.snapshot,
            at: now, calendar: calendar, guidanceContext: eligible)
        let restored = WellbeingCheckInRepository(store: store)
        XCTAssertEqual(restored.snapshot.version, WellbeingCheckInSnapshot.currentVersion)
        XCTAssertEqual(restored.snapshot.guidanceContext, eligible)
        XCTAssertEqual(restored.snapshot.nutrition.first?.amounts, quantities)
        let exported = try JSONEncoder().encode(restored.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: exported), restored.snapshot)
        try restored.deleteAll(replacing: restored.snapshot)
        XCTAssertNil(try store.load().guidanceContext)
        XCTAssertTrue(try store.load().nutrition.isEmpty)
        XCTAssertEqual(food.count, 3)
    }

    func testVersionTwoRemainsUnknownButCannotClaimVersionThreeEvidence() throws {
        let food = meals
        let old = try reviews(food: food, amounts: nil)
        let legacy = WellbeingCheckInSnapshot(nutrition: old, version: 2)
        XCTAssertTrue(legacy.isValid)
        let decoded = try JSONDecoder().decode(WellbeingCheckInSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.guidanceContext)
        XCTAssertTrue(decoded.nutrition.allSatisfy { $0.amounts == nil })
        XCTAssertFalse(WellbeingCheckInSnapshot(nutrition: try reviews(food: food, amounts: quantities), version: 2).isValid)
        XCTAssertFalse(WellbeingCheckInSnapshot(version: 2, guidanceContext: eligible).isValid)
    }

    func testSavingFoodDoesNotRenewAnUnchangedOlderGuidanceReport() throws {
        let store = DietContextTestStore()
        let old = NutritionGuidanceContext(reportedAt: now.addingTimeInterval(-91 * 86_400), isAdult: true,
            needsTailoredNutrition: false, hasFoodRestrictions: false, hasPrescribedFluidRestriction: false)
        store.value = .init(guidanceContext: old)
        let repository = WellbeingCheckInRepository(store: store)
        let food = meals
        let review = try XCTUnwrap(reviews(food: food, amounts: quantities).first)
        try repository.save(recovery: nil, nutrition: review, replacing: repository.snapshot, at: now, calendar: calendar)
        XCTAssertEqual(repository.snapshot.guidanceContext, old)
        XCTAssertFalse(repository.snapshot.guidanceContext?.permitsGeneralAdultAmounts(at: now) == true)
        let baseline = repository.snapshot
        try repository.save(recovery: nil, nutrition: nil, replacing: baseline, at: now, calendar: calendar, guidanceContext: eligible)
        XCTAssertEqual(repository.snapshot.guidanceContext, eligible)
        XCTAssertThrowsError(try repository.save(recovery: nil, nutrition: nil, replacing: baseline,
            at: now, calendar: calendar, guidanceContext: eligible))
    }

    func testActualGuidanceDraftCannotDiscardAChangedRestrictionOrRenewUnconfirmedAnswers() throws {
        let unchanged = NutritionGuidanceDraft(eligible)
        XCTAssertNil(try unchanged.confirmedUpdate(replacing: eligible, confirmed: false, at: now))
        let changed = NutritionGuidanceDraft(isAdult: true, needsTailoredNutrition: false,
            hasFoodRestrictions: false, hasPrescribedFluidRestriction: true)
        XCTAssertThrowsError(try changed.confirmedUpdate(replacing: eligible, confirmed: false, at: now)) {
            XCTAssertEqual($0 as? NutritionGuidanceDraftError, .confirmationRequired)
        }
        let saved = try XCTUnwrap(changed.confirmedUpdate(replacing: eligible, confirmed: true, at: now))
        XCTAssertTrue(saved.requiresTailoredReview(at: now))
        XCTAssertEqual(saved.hasPrescribedFluidRestriction, true)
        XCTAssertEqual(saved.reportedAt, now)
        let unknown = try XCTUnwrap(NutritionGuidanceDraft(nil).confirmedUpdate(replacing: nil, confirmed: true, at: now))
        XCTAssertNil(unknown.isAdult)
        XCTAssertFalse(unknown.permitsGeneralAdultAmounts(at: now))
        XCTAssertThrowsError(try unchanged.confirmedUpdate(replacing: eligible, confirmed: true,
            at: Date(timeIntervalSinceReferenceDate: .infinity)))
    }

    private func reviews(food: [NutritionEntry], amounts: NutritionDayAmounts?,
                         coverage: NutritionLogCoverage = .complete, goal: Int? = nil) throws -> [NutritionDayReview] {
        try [-1, -2, -3].map { offset in
            NutritionDayReview(id: UUID(), day: day(offset), timeZoneID: calendar.timeZone.identifier,
                reviewedAt: now, coverage: coverage,
                mealFingerprint: try XCTUnwrap(NutritionDayReview.fingerprint(entries: food, on: day(offset), calendar: calendar)),
                reviewedFoodGroups: nil, reportedCalorieGoal: goal, amounts: amounts)
        }
    }

    private func assess(food: [NutritionEntry]?, reviews: [NutritionDayReview], guidance: NutritionGuidanceContext?) -> DietQualityAssessment {
        DietQualityEvidence.assess(reviews: reviews, meals: food, guidance: guidance, at: now, calendar: calendar)
    }

    private func wellbeing(food: [NutritionEntry]?, reviews: [NutritionDayReview], guidance: NutritionGuidanceContext?) -> WellbeingAssessment {
        WellbeingRecommendationEngine().assess(.init(asOf: now, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: [], meals: food, nutritionReviews: reviews,
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil, nutritionGuidance: guidance))
    }
}

private final class DietContextTestStore: WellbeingCheckInPersisting {
    var value = WellbeingCheckInSnapshot()
    func load() throws -> WellbeingCheckInSnapshot { value }
    func save(_ value: WellbeingCheckInSnapshot) throws { self.value = value }
}
