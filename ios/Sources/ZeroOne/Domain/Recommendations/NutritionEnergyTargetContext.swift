import CryptoKit
import Foundation

enum NutritionEnergyTargetSource: String, Codable, CaseIterable, Hashable, Sendable {
    case notReported, selfChosen, professionalReported

    var title: String {
        switch self {
        case .notReported: "Target source not reported"
        case .selfChosen: "Chosen by me"
        case .professionalReported: "Reported professional advice"
        }
    }
}

enum NutritionEnergyTargetIntent: String, Codable, CaseIterable, Hashable, Sendable {
    case notReported, maintenance, weightLoss, weightGain, performance

    var title: String {
        switch self {
        case .notReported: "Target purpose not reported"
        case .maintenance: "Maintain weight"
        case .weightLoss: "Lose weight"
        case .weightGain: "Gain weight"
        case .performance: "Support training and performance"
        }
    }
}

/// Retrospective, reported context for one day's target. Professional advice
/// is reported by the user, never verified clearance or measured expenditure.
struct NutritionEnergyTargetContext: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let schemaVersion: Int
    let source: NutritionEnergyTargetSource
    let intent: NutritionEnergyTargetIntent

    init(source: NutritionEnergyTargetSource, intent: NutritionEnergyTargetIntent,
         schemaVersion: Int = Self.currentVersion) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.intent = intent
    }

    var isValid: Bool { schemaVersion == Self.currentVersion }
    var isExplicit: Bool { isValid && source != .notReported && intent != .notReported }
}

enum NutritionEnergyTargetEligibility: Equatable, Sendable {
    case unknownPersonalContext, tailoredReview, unknownTargetContext, reportedTargetComparison

    var title: String {
        switch self {
        case .unknownPersonalContext: "Nutrition context needs review"
        case .tailoredReview: "Tailored nutrition takes priority"
        case .unknownTargetContext: "Target source and purpose need review"
        case .reportedTargetComparison: "Reported target comparison only"
        }
    }
}

enum NutritionEnergyTargetDraftError: Error, Equatable { case confirmationRequired }

struct NutritionEnergyTargetDraft: Equatable {
    var source: NutritionEnergyTargetSource = .notReported
    var intent: NutritionEnergyTargetIntent = .notReported

    init() {}
    init(_ context: NutritionEnergyTargetContext?) {
        source = context?.source ?? .notReported; intent = context?.intent ?? .notReported
    }

    func confirmedContext(goal: Int?, replacing originalGoal: Int?,
                          context original: NutritionEnergyTargetContext?, confirmed: Bool) throws -> NutritionEnergyTargetContext? {
        let value: NutritionEnergyTargetContext?
        if goal == nil { value = nil }
        else if self == NutritionEnergyTargetDraft(original) { value = original }
        else if source == .notReported && intent == .notReported { value = nil }
        else { value = .init(source: source, intent: intent) }
        guard confirmed || (goal == originalGoal && value == original) else {
            throw NutritionEnergyTargetDraftError.confirmationRequired
        }
        return value
    }
}

enum NutritionEnergyTargetPolicy {
    static let version = "reported-energy-target-v1"

    static func eligibility(guidance: NutritionGuidanceContext?, target: NutritionEnergyTargetContext?,
                            at now: Date) -> NutritionEnergyTargetEligibility {
        if guidance?.requiresTailoredReview(at: now) == true { return .tailoredReview }
        guard guidance?.permitsGeneralAdultAmounts(at: now) == true else { return .unknownPersonalContext }
        guard target?.isExplicit == true else { return .unknownTargetContext }
        // No case grants permission to prescribe calories, macros or fluids.
        // A fully reported target remains a chosen reference, not a requirement.
        return .reportedTargetComparison
    }
}

struct NutritionEnergyTargetReview: Equatable, Sendable {
    let eligibility: NutritionEnergyTargetEligibility
    let reportedTargetDayCount: Int
    let comparisonDayCount: Int
    let unqualifiedTargetDayCount: Int
    let sourceFingerprint: String?

    var hasBoundSource: Bool {
        sourceFingerprint.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? false
    }

    static func assess(reviews: [NutritionDayReview], guidance: NutritionGuidanceContext?,
                       at now: Date) -> Self {
        let targets = reviews.filter { $0.reportedCalorieGoal != nil }
        let comparable = targets.filter {
            NutritionEnergyTargetPolicy.eligibility(guidance: guidance, target: $0.energyTargetContext,
                at: now) == .reportedTargetComparison
        }
        let eligibility = NutritionEnergyTargetPolicy.eligibility(guidance: guidance,
            target: comparable.first?.energyTargetContext, at: now)
        // Bind raw reported goal/context changes even when they leave the
        // displayed concern and count unchanged. Do not hash unordered groups.
        let source = Source(policy: NutritionEnergyTargetPolicy.version, guidance: guidance,
            records: reviews.sorted { $0.id.uuidString < $1.id.uuidString }.map(Record.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = (try? encoder.encode(source)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        return .init(eligibility: eligibility, reportedTargetDayCount: targets.count,
            comparisonDayCount: comparable.count, unqualifiedTargetDayCount: targets.count - comparable.count,
            sourceFingerprint: fingerprint)
    }

    private struct Source: Encodable {
        let policy: String
        let guidance: NutritionGuidanceContext?
        let records: [Record]
    }

    private struct Record: Encodable {
        let id: UUID
        let day: Date
        let timeZoneID: String
        let reviewedAt: Date
        let mealFingerprint: String
        let reportedCalorieGoal: Int?
        let energyTargetContext: NutritionEnergyTargetContext?
        init(_ review: NutritionDayReview) {
            id = review.id; day = review.day; timeZoneID = review.timeZoneID; reviewedAt = review.reviewedAt
            mealFingerprint = review.mealFingerprint; reportedCalorieGoal = review.reportedCalorieGoal
            energyTargetContext = review.energyTargetContext
        }
    }
}
