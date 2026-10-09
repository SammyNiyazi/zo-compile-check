import Foundation

/// Optional self-reported boundaries, without collecting a diagnosis or date
/// of birth. This is context for general advice, never clinical clearance.
struct NutritionGuidanceContext: Codable, Equatable, Sendable {
    let reportedAt: Date
    let isAdult: Bool?
    let needsTailoredNutrition: Bool?
    let hasFoodRestrictions: Bool?
    let hasPrescribedFluidRestriction: Bool?

    var isValid: Bool { reportedAt.timeIntervalSinceReferenceDate.isFinite }

    func isCurrent(at now: Date) -> Bool {
        isValid && now.timeIntervalSinceReferenceDate.isFinite && reportedAt <= now
            && now.timeIntervalSince(reportedAt) <= 90 * 86_400
    }

    /// A previously reported restriction does not expire into unrestricted
    /// advice. Updating the report is an explicit user action.
    func requiresTailoredReview(at now: Date) -> Bool {
        isValid && now.timeIntervalSinceReferenceDate.isFinite && reportedAt <= now && (isAdult == false || needsTailoredNutrition == true
            || hasFoodRestrictions == true || hasPrescribedFluidRestriction == true)
    }

    func permitsGeneralAdultAmounts(at now: Date) -> Bool {
        isCurrent(at: now) && isAdult == true && needsTailoredNutrition == false
            && hasFoodRestrictions == false && hasPrescribedFluidRestriction == false
    }
}

enum NutritionGuidanceDraftError: Error, Equatable { case confirmationRequired, invalidDate }

/// Unchanged, unconfirmed answers do not refresh old context. Changed answers
/// must never be silently discarded, especially a newly reported restriction.
struct NutritionGuidanceDraft: Equatable {
    let isAdult: Bool?
    let needsTailoredNutrition: Bool?
    let hasFoodRestrictions: Bool?
    let hasPrescribedFluidRestriction: Bool?

    init(isAdult: Bool?, needsTailoredNutrition: Bool?, hasFoodRestrictions: Bool?,
         hasPrescribedFluidRestriction: Bool?) {
        self.isAdult = isAdult
        self.needsTailoredNutrition = needsTailoredNutrition
        self.hasFoodRestrictions = hasFoodRestrictions
        self.hasPrescribedFluidRestriction = hasPrescribedFluidRestriction
    }

    init(_ context: NutritionGuidanceContext?) {
        self.init(isAdult: context?.isAdult, needsTailoredNutrition: context?.needsTailoredNutrition,
            hasFoodRestrictions: context?.hasFoodRestrictions,
            hasPrescribedFluidRestriction: context?.hasPrescribedFluidRestriction)
    }

    func confirmedUpdate(replacing previous: NutritionGuidanceContext?, confirmed: Bool,
                         at now: Date) throws -> NutritionGuidanceContext? {
        guard confirmed else {
            guard self == NutritionGuidanceDraft(previous) else { throw NutritionGuidanceDraftError.confirmationRequired }
            return nil
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw NutritionGuidanceDraftError.invalidDate }
        return .init(reportedAt: now, isAdult: isAdult, needsTailoredNutrition: needsTailoredNutrition,
            hasFoodRestrictions: hasFoodRestrictions, hasPrescribedFluidRestriction: hasPrescribedFluidRestriction)
    }
}

/// Retrospective totals explicitly reported for one finished food day. A
/// missing quantity is unknown, even when other quantities are complete.
/// Fibre is food fibre, free sugar is not total sugar/carbohydrate, and salt
/// is not sodium. These are not inferred from titles, pictures or macros.
enum NutritionAmountBasis: String, Codable, CaseIterable, Sendable {
    case notReported, foodRecords, estimated, mixed
}

struct NutritionDayAmounts: Codable, Equatable, Sendable {
    let coverage: NutritionLogCoverage
    let basis: NutritionAmountBasis
    let fruitAndVegetablesGrams: Double?
    let foodFibreGrams: Double?
    let freeSugarGrams: Double?
    let saltGrams: Double?

    init(coverage: NutritionLogCoverage, fruitAndVegetablesGrams: Double?, foodFibreGrams: Double?,
         freeSugarGrams: Double?, saltGrams: Double?, basis: NutritionAmountBasis = .notReported) {
        self.coverage = coverage
        self.basis = basis
        self.fruitAndVegetablesGrams = fruitAndVegetablesGrams
        self.foodFibreGrams = foodFibreGrams
        self.freeSugarGrams = freeSugarGrams
        self.saltGrams = saltGrams
    }

    var isValid: Bool {
        (fruitAndVegetablesGrams.map { $0.isFinite && (0 ... 20_000).contains($0) } ?? true)
            && (foodFibreGrams.map { $0.isFinite && (0 ... 500).contains($0) } ?? true)
            && (freeSugarGrams.map { $0.isFinite && (0 ... 2_000).contains($0) } ?? true)
            && (saltGrams.map { $0.isFinite && (0 ... 100).contains($0) } ?? true)
    }

    var hasAnyAmount: Bool {
        fruitAndVegetablesGrams != nil || foodFibreGrams != nil || freeSugarGrams != nil || saltGrams != nil
    }
}

enum DietQualityEligibility: Equatable, Sendable {
    case unknown, tailoredReview, generalAdultReview
}

enum DietQualityFinding: String, Equatable, Sendable {
    case limitedVariety, lowFruitAndVegetables, lowFoodFibre, highFreeSugar, highSalt
}

struct DietQualityAssessment: Equatable, Sendable {
    let eligibility: DietQualityEligibility
    let findings: [DietQualityFinding]
    let completeFoodDayCount: Int
    let completeAmountDayCount: Int
    let unqualifiedAmountDayCount: Int
    let fruitAndVegetableDayCount: Int
    let foodFibreDayCount: Int
    let freeSugarDayCount: Int
    let saltDayCount: Int
    let hasConflictingSugarEnergy: Bool

    // Energy expenditure, ingredient safety and micronutrient adequacy are
    // still unmeasured. No aggregate 'balanced/unbalanced' score is offered.
}

enum DietQualityEvidence {
    static let policyVersion = "reported-diet-quality-v1"

    static func assess(reviews: [NutritionDayReview], meals: [NutritionEntry]?,
                       guidance: NutritionGuidanceContext?, at now: Date, calendar: Calendar) -> DietQualityAssessment {
        let eligibility: DietQualityEligibility = guidance?.requiresTailoredReview(at: now) == true ? .tailoredReview
            : (guidance?.permitsGeneralAdultAmounts(at: now) == true ? .generalAdultReview : .unknown)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
              let meals, reviews.count <= 3_650, Set(reviews.map(\.id)).count == reviews.count else {
            return empty(eligibility)
        }
        let byDay = Dictionary(grouping: reviews, by: \.day)
        let qualified = byDay.values.compactMap { records -> NutritionDayReview? in
            guard records.count == 1, let review = records.first, review.day >= start,
                  review.coverage == .complete, review.isUsable(entries: meals, at: now, calendar: calendar) else { return nil }
            return review
        }
        let amounts = qualified.compactMap { review -> NutritionDayAmounts? in
            guard let amounts = review.amounts, amounts.isValid, amounts.hasAnyAmount,
                  amounts.coverage == .complete, amounts.basis == .foodRecords else { return nil }
            return amounts
        }
        var findings: [DietQualityFinding] = []
        let groupReviews = qualified.compactMap(\.reviewedFoodGroups)
        if groupReviews.count >= 3 {
            let groups = groupReviews.reduce(into: Set<DietFoodGroup>()) { $0.formUnion($1) }
            let plants: Set<DietFoodGroup> = [.vegetables, .fruit, .wholeGrains, .pulsesNutsSeeds]
            if plants.subtracting(groups).count >= 2 { findings.append(.limitedVariety) }
        }
        let fruit = amounts.compactMap(\.fruitAndVegetablesGrams)
        let fibre = amounts.compactMap(\.foodFibreGrams)
        let salt = amounts.compactMap(\.saltGrams)
        var sugarPercentages: [Double] = []
        var conflictingSugar = false
        for review in qualified {
            guard let amounts = review.amounts, amounts.coverage == .complete, amounts.basis == .foodRecords,
                  let sugar = amounts.freeSugarGrams else { continue }
            let calories = meals.filter { calendar.isDate($0.loggedAt, inSameDayAs: review.day) }
                .reduce(0.0) { $0 + Double($1.calories) }
            // Use that day's complete recorded energy, never a goal, macro
            // subtotal or estimated expenditure. Impossible pairs are omitted.
            guard calories > 0, sugar * 4 <= calories else { conflictingSugar = true; continue }
            sugarPercentages.append(sugar * 4 / calories * 100)
        }
        if eligibility == .generalAdultReview {
            // WHO adult general reference values. Requiring three observed
            // days is a product review threshold, not diagnosis or a mandate.
            if fruit.filter({ $0 < 400 }).count >= 3 { findings.append(.lowFruitAndVegetables) }
            if fibre.filter({ $0 < 25 }).count >= 3 { findings.append(.lowFoodFibre) }
            if sugarPercentages.filter({ $0 >= 10 }).count >= 3 { findings.append(.highFreeSugar) }
            if salt.filter({ $0 >= 5 }).count >= 3 { findings.append(.highSalt) }
        }
        return DietQualityAssessment(eligibility: eligibility, findings: findings,
            completeFoodDayCount: qualified.count, completeAmountDayCount: amounts.count,
            unqualifiedAmountDayCount: qualified.filter { $0.amounts?.hasAnyAmount == true }.count - amounts.count,
            fruitAndVegetableDayCount: fruit.count, foodFibreDayCount: fibre.count,
            freeSugarDayCount: sugarPercentages.count, saltDayCount: salt.count,
            hasConflictingSugarEnergy: conflictingSugar)
    }

    private static func empty(_ eligibility: DietQualityEligibility) -> DietQualityAssessment {
        .init(eligibility: eligibility, findings: [], completeFoodDayCount: 0, completeAmountDayCount: 0, unqualifiedAmountDayCount: 0,
            fruitAndVegetableDayCount: 0, foodFibreDayCount: 0, freeSugarDayCount: 0, saltDayCount: 0,
            hasConflictingSugarEnergy: false)
    }
}

enum NutritionAmountDraftError: Error { case invalidAmount }

struct NutritionDayAmountsDraft: Equatable {
    var coverage = NutritionLogCoverage.unknown
    var basis = NutritionAmountBasis.notReported
    var fruitAndVegetables = ""
    var foodFibre = ""
    var freeSugar = ""
    var salt = ""

    init() {}
    init(_ value: NutritionDayAmounts) {
        coverage = value.coverage
        basis = value.basis
        fruitAndVegetables = value.fruitAndVegetablesGrams.map { String($0) } ?? ""
        foodFibre = value.foodFibreGrams.map { String($0) } ?? ""
        freeSugar = value.freeSugarGrams.map { String($0) } ?? ""
        salt = value.saltGrams.map { String($0) } ?? ""
    }

    func validated() throws -> NutritionDayAmounts {
        let value = NutritionDayAmounts(coverage: coverage, fruitAndVegetablesGrams: try grams(fruitAndVegetables),
            foodFibreGrams: try grams(foodFibre), freeSugarGrams: try grams(freeSugar), saltGrams: try grams(salt), basis: basis)
        guard value.isValid else { throw NutritionAmountDraftError.invalidAmount }
        return value
    }

    private func grams(_ text: String) throws -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        guard let value = Double(cleaned), value.isFinite else { throw NutritionAmountDraftError.invalidAmount }
        return value
    }
}
