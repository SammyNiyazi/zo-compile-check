import Foundation
import StoreKit

/// Presentation qualification repeats the approved offer contract without changing
/// eligibility or entitlements. An eligibility flag alone never promises a duration.
enum MembershipTrialPresentation {
    static func approvedDays(unit: Product.SubscriptionPeriod.Unit, value: Int,
                             periodCount: Int, isFreeTrial: Bool,
                             eligibility: MembershipEligibility) -> Int? {
        guard eligibility == .eligible, isFreeTrial, periodCount == 1 else { return nil }
        switch unit {
        case .day where value == 14, .week where value == 2: return 14
        default: return nil
        }
    }

    static func approvedDays(product: Product?, eligibility: MembershipEligibility) -> Int? {
        guard let offer = product?.subscription?.introductoryOffer else { return nil }
        return approvedDays(unit: offer.period.unit, value: offer.period.value,
                            periodCount: offer.periodCount,
                            isFreeTrial: offer.paymentMode == .freeTrial,
                            eligibility: eligibility)
    }

    /// Count by local calendar days, never by dividing seconds across a DST change.
    /// Only an already verified, unexpired trial has a days-left badge.
    static func daysLeft(access: MembershipAccess, now: Date,
                         calendar: Calendar = .current) -> Int? {
        guard case .trial(let end) = access, end > now else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: end)).day ?? 0
        return max(1, days)
    }

    static func plannedDays(_ dates: [Date], start: Date, days: Int,
                            calendar: Calendar = .current) -> [Date] {
        guard days > 0, let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        return Array(Set(dates.filter { $0 >= start && $0 < end }
            .map { calendar.startOfDay(for: $0) })).sorted()
    }
}

/// Root supplies a factual 14-day projection from readable saved history. nil is
/// unknown, not zero. No presentation type reads repositories or infers a best.
struct MembershipTrialRecap: Equatable {
    let interval: DateInterval
    var workouts: Int? = nil
    var completedSets: Int? = nil
    var bests: Int? = nil
    var strength: [Strength] = []
    var attendance: [AttendanceDay]? = nil
    var weightTrend: [WeightDay]? = nil
    var averageDailySteps: Int? = nil
    var longestWalkKilometres: Double? = nil
    var lessons: [Lesson] = []

    struct Strength: Equatable, Identifiable {
        let id: String
        let exerciseName: String
        let firstLoadKilograms: Double
        let currentLoadKilograms: Double
        let firstObservedAt: Date
        let currentObservedAt: Date
        /// Supplied only after matching exercise, equipment, reps and side conventions.
        let comparisonQualified: Bool
        var isDisplayable: Bool {
            comparisonQualified && firstLoadKilograms.isFinite && currentLoadKilograms.isFinite
                && firstLoadKilograms >= 0 && currentLoadKilograms >= 0
        }
    }

    struct AttendanceDay: Equatable, Identifiable {
        let date: Date
        let planned: Bool?
        let completed: Bool?
        var id: Date { date }
    }

    /// Apple Health-derived seven-day averages supplied by root. nil preserves gaps.
    struct WeightDay: Equatable, Identifiable {
        let date: Date
        let sevenDayAverageKilograms: Double?
        var id: Date { date }
    }

    struct Lesson: Equatable, Identifiable {
        let id: String
        let title: String
        let readAt: Date
    }

    var qualifiedStrength: [Strength] {
        let candidates = strength.filter {
            $0.isDisplayable && contains($0.firstObservedAt) && contains($0.currentObservedAt)
                && $0.firstObservedAt < $0.currentObservedAt
        }
        guard Set(candidates.map(\.id)).count == candidates.count else { return [] }
        return candidates
    }
    func contains(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
    func isFourteenDays(calendar: Calendar = .current) -> Bool {
        calendar.date(byAdding: .day, value: 14, to: interval.start) == interval.end
    }
    func attendanceDays(calendar: Calendar = .current) -> [AttendanceDay]? {
        guard let attendance else { return nil }
        let days = attendance.filter { contains($0.date) }.sorted { $0.date < $1.date }
        guard Set(days.map { calendar.startOfDay(for: $0.date) }).count == days.count else { return nil }
        return days.isEmpty ? nil : days
    }
    struct WeightPlotPoint: Equatable, Identifiable {
        let date: Date
        let kilograms: Double
        let segment: Int
        var id: Date { date }
    }
    /// Missing/invalid observations and missing local days break the line. No bridging.
    func weightPlot(calendar: Calendar = .current) -> [WeightPlotPoint] {
        let days = (weightTrend ?? []).filter { contains($0.date) }.sorted { $0.date < $1.date }
        guard Set(days.map { calendar.startOfDay(for: $0.date) }).count == days.count else { return [] }
        var result: [WeightPlotPoint] = []
        var segment = 0
        var previous: Date?
        for day in days {
            guard let weight = day.sevenDayAverageKilograms, weight.isFinite, weight > 0 else {
                segment += 1
                previous = nil
                continue
            }
            if let previous, calendar.dateComponents([.day], from: calendar.startOfDay(for: previous),
                                                     to: calendar.startOfDay(for: day.date)).day != 1 {
                segment += 1
            }
            result.append(WeightPlotPoint(date: day.date, kilograms: weight, segment: segment))
            previous = day.date
        }
        return result
    }
    var readLessons: [Lesson] {
        let read = lessons.filter { contains($0.readAt) }
        guard Set(read.map(\.id)).count == read.count else { return [] }
        return read
    }
    /// A valid interval alone is not evidence that anything was observed.
    /// Observed zeros remain facts; absent, invalid and unqualified values do not.
    func hasDisplayableFacts(calendar: Calendar = .current) -> Bool {
        guard isFourteenDays(calendar: calendar) else { return false }
        return Self.count(workouts) != nil || Self.count(completedSets) != nil
            || Self.count(bests) != nil || !qualifiedStrength.isEmpty
            || attendanceDays(calendar: calendar)?.contains { $0.planned != nil || $0.completed != nil } == true
            || !weightPlot(calendar: calendar).isEmpty
            || Self.count(averageDailySteps) != nil || validLongestWalk != nil
            || !readLessons.isEmpty
    }
    static func count(_ count: Int?) -> Int? { count.flatMap { $0 >= 0 ? $0 : nil } }
    var validLongestWalk: Double? {
        longestWalkKilometres.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// Root obtains verified renewal information separately from StoreKit. A currently
/// selected offer is not the subscriber's renewal price. nil means not verified.
struct MembershipRecapRenewal: Equatable {
    enum Continuation: Equatable { case renews, cancelled, unknown }
    let trialEnds: Date
    let continuation: Continuation
    let verifiedPrice: String?
    let verifiedPeriod: String?

    func matches(_ recap: MembershipTrialRecap?, calendar: Calendar = .current) -> Bool {
        guard let recap, recap.isFourteenDays(calendar: calendar) else { return false }
        return trialEnds == recap.interval.end
    }

    var hasVerifiedPriceAndPeriod: Bool {
        guard let verifiedPrice, let verifiedPeriod else { return false }
        return !verifiedPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !verifiedPeriod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
