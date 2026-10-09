import CryptoKit
import Foundation

enum RecoveryEnergy: String, Codable, CaseIterable, Sendable {
    case notReported, low, usual, high
}

enum RecoverySoreness: String, Codable, CaseIterable, Sendable {
    case notReported, none, mild, moderate, severe
}

/// Explicit reports, never inferred from missing logs or a missed workout.
struct RecoveryCheckIn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let day: Date
    let timeZoneID: String
    let reportedAt: Date
    let energy: RecoveryEnergy
    let soreness: RecoverySoreness
    let sleepHours: Double?
    let hasNewOrWorseningPain: Bool?
    let feelsUnwell: Bool?
    let feelsUnusuallyHungry: Bool?
    let feelsThirsty: Bool?

    var isStructurallyValid: Bool {
        day.timeIntervalSinceReferenceDate.isFinite
            && reportedAt.timeIntervalSinceReferenceDate.isFinite && day <= reportedAt
            && TimeZone(identifier: timeZoneID) != nil
            && (sleepHours.map { $0.isFinite && (0 ... 24).contains($0) } ?? true)
    }

    func isCurrent(at date: Date, calendar: Calendar) -> Bool {
        isStructurallyValid && reportedAt <= date && date.timeIntervalSince(reportedAt) <= 18 * 3_600
            && timeZoneID == calendar.timeZone.identifier && calendar.isDate(day, inSameDayAs: date)
    }
}

enum NutritionLogCoverage: String, Codable, CaseIterable, Sendable {
    case unknown, partial, complete
}

enum DietFoodGroup: String, Codable, CaseIterable, Sendable {
    case vegetables, fruit, wholeGrains, pulsesNutsSeeds, proteinFoods, unsaturatedFats
}

/// A person's review of a finished day. The fingerprint binds completeness to
/// the actual meal records; adding, editing or removing a meal invalidates it.
/// Food groups describe reported presence, not portions or nutrient adequacy.
struct NutritionDayReview: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let day: Date
    let timeZoneID: String
    let reviewedAt: Date
    let coverage: NutritionLogCoverage
    let mealFingerprint: String
    let reviewedFoodGroups: Set<DietFoodGroup>?
    // Explicitly reported for this finished day. Today's goal cannot establish
    // a historical target. Nil remains unknown in older reviews.
    let reportedCalorieGoal: Int?
    let amounts: NutritionDayAmounts?
    let energyTargetContext: NutritionEnergyTargetContext?

    init(id: UUID, day: Date, timeZoneID: String, reviewedAt: Date,
         coverage: NutritionLogCoverage, mealFingerprint: String,
         reviewedFoodGroups: Set<DietFoodGroup>?, reportedCalorieGoal: Int? = nil, amounts: NutritionDayAmounts? = nil,
         energyTargetContext: NutritionEnergyTargetContext? = nil) {
        self.id = id
        self.day = day
        self.timeZoneID = timeZoneID
        self.reviewedAt = reviewedAt
        self.coverage = coverage
        self.mealFingerprint = mealFingerprint
        self.reviewedFoodGroups = reviewedFoodGroups
        self.reportedCalorieGoal = reportedCalorieGoal
        self.amounts = amounts
        self.energyTargetContext = energyTargetContext
    }

    var isStructurallyValid: Bool {
        day.timeIntervalSinceReferenceDate.isFinite && reviewedAt.timeIntervalSinceReferenceDate.isFinite
            && day <= reviewedAt && TimeZone(identifier: timeZoneID) != nil
            && mealFingerprint.count == 64
            && mealFingerprint.allSatisfy { $0.isHexDigit }
            && (reportedCalorieGoal.map { (500 ... 10_000).contains($0) } ?? true)
            && (amounts?.isValid ?? true)
            && (energyTargetContext.map { $0.isValid && reportedCalorieGoal != nil } ?? true)
    }

    func isUsable(entries: [NutritionEntry], at date: Date, calendar: Calendar) -> Bool {
        guard isStructurallyValid, reviewedAt <= date, day < calendar.startOfDay(for: date),
              timeZoneID == calendar.timeZone.identifier,
              calendar.startOfDay(for: day) == day,
              let interval = calendar.dateInterval(of: .day, for: day), reviewedAt >= interval.end else { return false }
        return mealFingerprint == Self.fingerprint(entries: entries, on: day, calendar: calendar)
    }

    static func fingerprint(entries: [NutritionEntry], on day: Date, calendar: Calendar) -> String? {
        guard (try? FoodBodyWeightImportDecoder.validateMeals(entries)) != nil else { return nil }
        let meals = entries.filter { calendar.isDate($0.loggedAt, inSameDayAs: day) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(meals) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RecoverySleepObservation: Equatable, Sendable {
    let hours: Double
    let refreshedAt: Date
    let day: Date
}

struct WellbeingHydrationObservation: Equatable, Sendable {
    let loggedMilliliters: Int
    let storedGoalMilliliters: Int
    let day: Date
}

/// Nil collections mean unavailable. Empty collections mean no acknowledged
/// records, and do not prove that the person did no exercise or ate no food.
struct WellbeingContext {
    let asOf: Date
    let calendar: Calendar
    let strengthHistory: [WorkoutHistoryEntry]?
    let outdoorHistory: [OutdoorActivityRecord]?
    let recoveryCheckIns: [RecoveryCheckIn]
    let meals: [NutritionEntry]?
    let nutritionReviews: [NutritionDayReview]
    // Kept for caller compatibility. A present-day goal never authorises a
    // retrospective food-intake comparison; use the day review's reported goal.
    let chosenFoodGoal: Int?
    let hydration: WellbeingHydrationObservation?
    let healthSleep: RecoverySleepObservation?
    let nutritionGuidance: NutritionGuidanceContext?
    // Supplied arrays are explicit observations in pure domain callers. The
    // host must distinguish an unreadable recovery store from verified emptiness.
    let recoverySourceAvailable: Bool

    init(asOf: Date, calendar: Calendar, strengthHistory: [WorkoutHistoryEntry]?,
         outdoorHistory: [OutdoorActivityRecord]?, recoveryCheckIns: [RecoveryCheckIn],
         meals: [NutritionEntry]?, nutritionReviews: [NutritionDayReview], chosenFoodGoal: Int?,
         hydration: WellbeingHydrationObservation?, healthSleep: RecoverySleepObservation?,
         nutritionGuidance: NutritionGuidanceContext? = nil, recoverySourceAvailable: Bool = true) {
        self.asOf = asOf
        self.calendar = calendar
        self.strengthHistory = strengthHistory
        self.outdoorHistory = outdoorHistory
        self.recoveryCheckIns = recoveryCheckIns
        self.meals = meals
        self.nutritionReviews = nutritionReviews
        self.chosenFoodGoal = chosenFoodGoal
        self.hydration = hydration
        self.healthSleep = healthSleep
        self.nutritionGuidance = nutritionGuidance
        self.recoverySourceAvailable = recoverySourceAvailable
    }
}

enum WellbeingRecommendationKind: String, Codable, Sendable {
    case symptoms, recovery, fuelling, foodVariety, hydration, checkIn
}

enum WellbeingDemand: Int, Comparable, Sendable {
    case review = 0, checkIn, easeTraining, pauseForSymptoms
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum WellbeingEvidenceKind: String, Sendable {
    case reportedPain, reportedIllness, reportedFatigue, reportedSoreness, reportedHunger
    case shortSleep, consecutiveTrainingDays, completeFoodLogsBelowChosenGoal
    case limitedReportedFoodVariety, reportedThirst, incompleteFoodLogs, conflictingSleep
    case waterLogBelowStoredGoal, repeatedComparablePerformanceDecline
    case lowReportedFruitAndVegetables, lowReportedFoodFibre, highReportedFreeSugar, highReportedSalt
    case tailoredNutritionNeeded, nutritionContextUnknown, prescribedFluidRestriction
    case energyTargetContextUnknown
}

struct WellbeingRecommendation: Identifiable, Equatable, Sendable {
    var id: String { kind.rawValue }
    let kind: WellbeingRecommendationKind
    let demand: WellbeingDemand
    let evidence: [WellbeingEvidenceKind]
    let policyVersion: String
    let sourceReferences: [String]
}

enum WellbeingUnavailableSource: String, Hashable, Sendable {
    case strengthHistory, outdoorHistory, recovery, foodLog
}

struct WellbeingAssessment: Equatable, Sendable {
    let recommendations: [WellbeingRecommendation]
    let recordedTrainingDays: Int
    let reviewedNutritionDays: Int
    let hasCurrentRecoveryReport: Bool
    let hasConflictingSleep: Bool
    let evaluatedAt: Date?
    let timeZoneID: String?
    let workload: TrainingWorkloadAssessment?
    let dietQuality: DietQualityAssessment?
    let energyTargetReview: NutritionEnergyTargetReview?
    let unavailableSources: Set<WellbeingUnavailableSource>

    init(recommendations: [WellbeingRecommendation], recordedTrainingDays: Int,
         reviewedNutritionDays: Int, hasCurrentRecoveryReport: Bool, hasConflictingSleep: Bool,
         evaluatedAt: Date? = nil, timeZoneID: String? = nil, workload: TrainingWorkloadAssessment? = nil,
         dietQuality: DietQualityAssessment? = nil, energyTargetReview: NutritionEnergyTargetReview? = nil,
         unavailableSources: Set<WellbeingUnavailableSource> = []) {
        self.recommendations = recommendations
        self.recordedTrainingDays = recordedTrainingDays
        self.reviewedNutritionDays = reviewedNutritionDays
        self.hasCurrentRecoveryReport = hasCurrentRecoveryReport
        self.hasConflictingSleep = hasConflictingSleep
        self.evaluatedAt = evaluatedAt
        self.timeZoneID = timeZoneID
        self.workload = workload
        self.dietQuality = dietQuality
        self.energyTargetReview = energyTargetReview
        self.unavailableSources = unavailableSources
    }

    /// A cached assessment is display context, not permission to act indefinitely.
    /// The host must also reassess whenever its underlying sources change.
    func isCurrent(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let evaluatedAt, evaluatedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, evaluatedAt <= now,
              now.timeIntervalSince(evaluatedAt) <= 10 * 60,
              timeZoneID == calendar.timeZone.identifier,
              calendar.isDate(evaluatedAt, inSameDayAs: now) else { return false }
        return true
    }

    /// A hold on automatic increases, not a diagnosis or a forced cancellation.
    var holdsAutomaticProgression: Bool {
        !unavailableSources.isEmpty || recommendations.contains { $0.demand >= .easeTraining }
    }
}
