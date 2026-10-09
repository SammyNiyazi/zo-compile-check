import Foundation

enum RecommendationFocus: Equatable, Sendable {
    case wellbeing(WellbeingRecommendation)
    case continueWorkout
    case startWorkout(fitsReportedWindow: Bool)
    case reviewProgress
    case sourceUnavailable
    case none
}

/// A reported duration is availability, not an inferred calendar opening.
struct ReportedWorkoutAvailability: Equatable, Sendable {
    let minutes: Int
    let reportedAt: Date

    func isCurrent(at now: Date, calendar: Calendar) -> Bool {
        (10 ... 240).contains(minutes) && reportedAt.timeIntervalSinceReferenceDate.isFinite
            && reportedAt <= now && now.timeIntervalSince(reportedAt) <= 6 * 3_600
            && calendar.isDate(reportedAt, inSameDayAs: now)
    }
}

/// Shared ordering, without a fabricated confidence/readiness score.
/// Safety and corroborated recovery/fuelling concerns precede training pressure.
/// A passive log review does not interrupt an active workout.
struct RecommendationArbiter: Sendable {
    static let policyVersion = "next-action-v2"

    func focus(at now: Date, calendar: Calendar = .current,
               workout: PromptWorkoutStatus, wellbeing: WellbeingAssessment?,
               availability: ReportedWorkoutAvailability? = nil,
               estimatedUpperMinutes: Int? = nil,
               progressReviewDue: Bool = false) -> RecommendationFocus {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return .none }
        let available = wellbeing?.isCurrent(at: now, calendar: calendar) == true
            ? wellbeing?.recommendations ?? [] : []
        let recommendations = available.filter { $0.policyVersion == WellbeingRecommendationEngine.policyVersion }.sorted {
            if $0.demand != $1.demand { return $0.demand > $1.demand }
            return priority($0.kind) < priority($1.kind)
        }
        if let concern = recommendations.first(where: { $0.demand >= .easeTraining }) {
            return .wellbeing(concern)
        }
        if wellbeing?.unavailableSources.isEmpty == false { return .sourceUnavailable }
        if workout == .active { return .continueWorkout }
        if let checkIn = recommendations.first(where: {
            $0.demand == .checkIn && ($0.kind == .recovery || $0.kind == .fuelling)
        }) { return .wellbeing(checkIn) }
        if workout == .ready {
            let fits = availability.map { reported in
                reported.isCurrent(at: now, calendar: calendar)
                    && estimatedUpperMinutes.map { (1 ... 240).contains($0) && $0 <= reported.minutes } == true
            } ?? false
            return .startWorkout(fitsReportedWindow: fits)
        }
        if let review = recommendations.first(where: { $0.kind != .checkIn }) {
            return .wellbeing(review)
        }
        if progressReviewDue { return .reviewProgress }
        return .none
    }

    private func priority(_ kind: WellbeingRecommendationKind) -> Int {
        switch kind {
        case .symptoms: 0
        case .fuelling: 1
        case .recovery: 2
        case .hydration: 3
        case .foodVariety: 4
        case .checkIn: 5
        }
    }
}
