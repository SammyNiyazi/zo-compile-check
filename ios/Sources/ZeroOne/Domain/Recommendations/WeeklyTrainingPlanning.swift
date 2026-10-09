import Foundation

enum WeeklyTrainingChange: String, CaseIterable {
    case spreadDays, fewerDays
    var titleKey: String {
        switch self {
        case .spreadDays: "More spacing between chosen days"
        case .fewerDays: "One fewer training day per week"
        }
    }
}

enum WeeklyTrainingPlanningError: Error, Equatable {
    case unavailable, activeWorkout, noConcern, symptoms, availability, noChange, stale
    var messageKey: String {
        switch self {
        case .unavailable: "Current programme, schedule or recovery records could not be verified. Reopen this review."
        case .activeWorkout: "Finish or leave the active workout before changing the weekly plan."
        case .noConcern: "There is no current supported recovery or fuelling concern for this weekly option."
        case .symptoms: "Review the reported pain or illness before changing the weekly plan."
        case .availability: "Confirm which weekdays usually fit before reviewing a weekly option."
        case .noChange: "These available days do not support that change within this programme. Your plan is kept."
        case .stale: "The programme, schedule, appointments or recovery context changed. Review a new option."
        }
    }
}

struct ReportedTrainingWeekdays: Equatable {
    let weekdays: Set<Int> // Foundation Sunday1 ... Saturday7, not profile Monday0.
    let confirmedAt: Date
    let timeZoneID: String
    func isCurrent(at now: Date, calendar: Calendar) -> Bool {
        !weekdays.isEmpty && weekdays.allSatisfy { (1 ... 7).contains($0) }
            && confirmedAt.timeIntervalSinceReferenceDate.isFinite && now.timeIntervalSinceReferenceDate.isFinite
            && confirmedAt <= now && now.timeIntervalSince(confirmedAt) <= 600
            && timeZoneID == calendar.timeZone.identifier && calendar.isDate(confirmedAt, inSameDayAs: now)
    }
}

struct WeeklyTrainingContext {
    let programme: WorkoutProgramme
    let schedule: WorkoutProgrammeSchedule
    let assessment: WellbeingAssessment
    let hasUnfinishedWorkout: Bool
    let appointments: [WorkoutAppointment]
}

/// Review-only until the root fresh-reads and acknowledges the existing schedule
/// store. No session, appointment, performed history or clinical fact is created.
struct WeeklyTrainingProposal: Equatable {
    let policyVersion: String
    let change: WeeklyTrainingChange
    let offeredAt: Date
    let timeZoneID: String
    let availability: ReportedTrainingWeekdays
    let programme: WorkoutProgramme
    let originalSchedule: WorkoutProgrammeSchedule
    let proposedWeekdays: Set<Int>
    let concerns: [WellbeingRecommendation]
    var energyTargetSource: String? = nil
    let appointments: [WorkoutAppointment]
}

struct WeeklyTrainingPlanner {
    static let policyVersion = "weekly-rhythm-review-v1"

    func proposal(change: WeeklyTrainingChange, availability: ReportedTrainingWeekdays,
                  context: WeeklyTrainingContext, at now: Date, calendar: Calendar = .current) throws -> WeeklyTrainingProposal {
        guard !context.hasUnfinishedWorkout else { throw WeeklyTrainingPlanningError.activeWorkout }
        guard context.schedule.isValid(for: context.programme), context.schedule.confirmedAt <= now,
              context.assessment.isCurrent(at: now, calendar: calendar), context.assessment.hasCurrentRecoveryReport,
              context.assessment.unavailableSources.isEmpty,
              context.assessment.energyTargetReview?.hasBoundSource ?? true,
              context.assessment.recommendations.allSatisfy({ $0.policyVersion == WellbeingRecommendationEngine.policyVersion }) else {
            throw WeeklyTrainingPlanningError.unavailable
        }
        guard !context.assessment.recommendations.contains(where: { $0.demand == .pauseForSymptoms || $0.kind == .symptoms }) else {
            throw WeeklyTrainingPlanningError.symptoms
        }
        let concerns = context.assessment.recommendations.filter {
            $0.demand == .easeTraining && ($0.kind == .recovery || $0.kind == .fuelling)
        }
        guard !concerns.isEmpty else { throw WeeklyTrainingPlanningError.noConcern }
        guard availability.isCurrent(at: now, calendar: calendar) else { throw WeeklyTrainingPlanningError.availability }
        let original = Set(context.schedule.weekdays)
        let count = original.count - (change == .fewerDays ? 1 : 0)
        let pool = change == .fewerDays ? original.intersection(availability.weekdays) : availability.weekdays
        guard count >= min(2, context.programme.sessions.count), count <= pool.count else { throw WeeklyTrainingPlanningError.noChange }
        let candidates = (1 ..< 128).map { mask in Set((1 ... 7).filter { mask & (1 << ($0 - 1)) != 0 }) }
            .filter { $0.count == count && $0.isSubset(of: pool) }
            .sorted { preferred($0, to: $1, keeping: original) }
        guard let chosen = candidates.first, chosen != original else { throw WeeklyTrainingPlanningError.noChange }
        if change == .spreadDays {
            guard adjacentPairs(chosen) < adjacentPairs(original)
                || (adjacentPairs(chosen) == adjacentPairs(original) && shortestGap(chosen) > shortestGap(original)) else {
                throw WeeklyTrainingPlanningError.noChange
            }
        }
        return .init(policyVersion: Self.policyVersion, change: change, offeredAt: now,
            timeZoneID: calendar.timeZone.identifier, availability: availability, programme: context.programme,
            originalSchedule: context.schedule, proposedWeekdays: chosen, concerns: concerns,
            energyTargetSource: context.assessment.energyTargetReview?.sourceFingerprint,
            appointments: context.appointments.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    func revalidated(_ presented: WeeklyTrainingProposal, context: WeeklyTrainingContext,
                     at now: Date, calendar: Calendar = .current) throws -> WeeklyTrainingProposal {
        guard presented.policyVersion == Self.policyVersion, presented.offeredAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, presented.offeredAt <= now,
              now.timeIntervalSince(presented.offeredAt) <= 600,
              presented.timeZoneID == calendar.timeZone.identifier,
              calendar.isDate(presented.offeredAt, inSameDayAs: now),
              presented.programme == context.programme, presented.originalSchedule == context.schedule else {
            throw WeeklyTrainingPlanningError.stale
        }
        let fresh = try proposal(change: presented.change, availability: presented.availability, context: context, at: now, calendar: calendar)
        guard fresh.proposedWeekdays == presented.proposedWeekdays, fresh.concerns == presented.concerns,
              fresh.energyTargetSource == presented.energyTargetSource,
              fresh.appointments == presented.appointments else { throw WeeklyTrainingPlanningError.stale }
        return fresh
    }

    /// Calendar spacing, not a biological recovery estimate. Sunday/Saturday
    /// wraparound matters even when the device's first displayed weekday differs.
    func adjacentPairs(_ days: Set<Int>) -> Int {
        days.filter { days.contains($0 % 7 + 1) }.count
    }

    private func shortestGap(_ days: Set<Int>) -> Int {
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.indices.map { index in
            let next = index + 1 < sorted.count ? sorted[index + 1] : sorted[0] + 7
            return next - sorted[index]
        }.min() ?? 0
    }

    private func preferred(_ lhs: Set<Int>, to rhs: Set<Int>, keeping original: Set<Int>) -> Bool {
        if adjacentPairs(lhs) != adjacentPairs(rhs) { return adjacentPairs(lhs) < adjacentPairs(rhs) }
        if shortestGap(lhs) != shortestGap(rhs) { return shortestGap(lhs) > shortestGap(rhs) }
        if lhs.intersection(original).count != rhs.intersection(original).count {
            return lhs.intersection(original).count > rhs.intersection(original).count
        }
        return lhs.sorted().lexicographicallyPrecedes(rhs.sorted())
    }
}
