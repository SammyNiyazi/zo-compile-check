import Foundation
import Observation
import UserNotifications

/// Proof 53 and 56: the end of the standard two-week trial, told through the
/// person's own numbers. Day 13 and 14 carry a Today card (the fairness reminder),
/// the last evening opens "Your 14 days" once, and two local notifications cover
/// two days before the charge and, for people who turned renewal off, the held card.
struct TrialWindow: Equatable {
    static let days = 14
    /// The number stays held for 30 days after a trial that did not continue.
    static let holdDays = 30
    let end: Date

    func start(calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: -Self.days, to: end)
    }

    /// Local calendar days from today to the day the charge happens.
    func daysLeft(now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day ?? 0
    }

    /// 1 to 14: "Day 13 of 14".
    func dayNumber(now: Date, calendar: Calendar) -> Int {
        guard let start = start(calendar: calendar) else { return Self.days }
        let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        return min(Self.days, max(1, elapsed + 1))
    }

    /// The last two days before Apple charges.
    func showsTodayCard(now: Date, calendar: Calendar) -> Bool {
        now < end && daysLeft(now: now, calendar: calendar) <= 2
    }

    /// The evening before the card becomes theirs (from 17:00), the morning of
    /// the charge, or within a week after a trial that ended.
    func recapIsDue(now: Date, calendar: Calendar) -> Bool {
        if now >= end {
            guard let week = calendar.date(byAdding: .day, value: 7, to: end) else { return false }
            return now < week
        }
        let left = daysLeft(now: now, calendar: calendar)
        return left == 0 || (left == 1 && calendar.component(.hour, from: now) >= 17)
    }
}

/// Remembers the trial after StoreKit stops reporting it, so the recap and the
/// held-card note still work once it has ended. Never stores prices or receipts.
@MainActor
@Observable
final class TrialMomentStore {
    private(set) var window: TrialWindow?
    private(set) var continuation: MembershipRecapRenewal.Continuation = .unknown
    private(set) var cardDismissedEnd: Date?
    private(set) var recapShownEnd: Date?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let end = "01.trial.end"
        static let renews = "01.trial.renews"
        static let cardDismissed = "01.trial.cardDismissed"
        static let recapShown = "01.trial.recapShown"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        window = (defaults.object(forKey: Key.end) as? Date).map(TrialWindow.init(end:))
        if let renews = defaults.object(forKey: Key.renews) as? Bool { continuation = renews ? .renews : .cancelled }
        cardDismissedEnd = defaults.object(forKey: Key.cardDismissed) as? Date
        recapShownEnd = defaults.object(forKey: Key.recapShown) as? Date
    }

    func record(_ renewal: MembershipRecapRenewal) {
        if window?.end != renewal.trialEnds {
            window = TrialWindow(end: renewal.trialEnds)
            defaults.set(renewal.trialEnds, forKey: Key.end)
            continuation = .unknown
            defaults.removeObject(forKey: Key.renews)
        }
        guard renewal.continuation != .unknown, renewal.continuation != continuation else { return }
        continuation = renewal.continuation
        defaults.set(renewal.continuation == .renews, forKey: Key.renews)
    }

    var cardDismissed: Bool { window != nil && cardDismissedEnd == window?.end }
    var recapShown: Bool { window != nil && recapShownEnd == window?.end }

    func dismissCard() {
        guard let end = window?.end else { return }
        cardDismissedEnd = end
        defaults.set(end, forKey: Key.cardDismissed)
    }

    func markRecapShown() {
        guard let end = window?.end else { return }
        recapShownEnd = end
        defaults.set(end, forKey: Key.recapShown)
    }
}

/// The person's numbers inside the trial window, from saved history only.
struct TrialProgress: Equatable {
    let workouts: Int
    let sets: Int
    let bests: Int?
    let topLift: ZOShareRecapLift?
    let share: ZOShareRecapFacts?

    static func == (lhs: TrialProgress, rhs: TrialProgress) -> Bool {
        lhs.workouts == rhs.workouts && lhs.sets == rhs.sets && lhs.bests == rhs.bests && lhs.topLift == rhs.topLift
    }

    /// nil when history cannot be read: unknown is never shown as zero.
    static func make(window: TrialWindow, history: [WorkoutHistoryEntry]?, calendar: Calendar) -> TrialProgress? {
        guard let history, let start = window.start(calendar: calendar) else { return nil }
        guard let facts = ZOShareRecapFacts(start: start, acknowledgedHistory: history, calendar: calendar) else {
            let any = history.contains { $0.completedAt >= start && $0.completedAt < window.end && $0.completedSetCount > 0 }
            return any ? nil : TrialProgress(workouts: 0, sets: 0, bests: 0, topLift: nil, share: nil)
        }
        let top = facts.lifts.max { lhs, rhs in
            (lhs.last.value - lhs.first.value) / max(lhs.first.value, 1) < (rhs.last.value - rhs.first.value) / max(rhs.first.value, 1)
        }
        return TrialProgress(workouts: facts.workouts, sets: facts.sets, bests: facts.priorBestCount,
                             topLift: top.flatMap { $0.last.value > $0.first.value ? $0 : nil }, share: facts)
    }

    /// "9 workouts and 3 new bests"
    func summary(_ localization: AppLocalization) -> String {
        let count = workouts.formatted(.number.locale(localization.locale))
        let done = localization.format(workouts == 1 ? "%1$@ workout" : "%1$@ workouts", .text(count))
        guard let bests, bests > 0 else { return done }
        let best = localization.format(bests == 1 ? "%1$@ new best" : "%1$@ new bests",
                                       .text(bests.formatted(.number.locale(localization.locale))))
        return localization.format("%1$@ and %2$@", .text(done), .text(best))
    }

    /// "Your Squat went from 12 to 18 kg."
    func liftLine(_ localization: AppLocalization) -> String? {
        guard let lift = topLift else { return nil }
        let unit = localization.string(lift.last.unit == .kilograms ? "kg" : "lb")
        return localization.format("Your %1$@ went from %2$@ to %3$@ %4$@.", .text(lift.name),
            .text(lift.first.value.formatted(.number.locale(localization.locale))),
            .text(lift.last.value.formatted(.number.locale(localization.locale))), .text(unit))
    }

    /// The recap screen's facts: the same numbers, with the observed lift dates.
    func recap(window: TrialWindow, history: [WorkoutHistoryEntry], calendar: Calendar) -> MembershipTrialRecap? {
        guard let start = window.start(calendar: calendar) else { return nil }
        var recap = MembershipTrialRecap(interval: DateInterval(start: start, end: window.end))
        recap.workouts = workouts
        recap.completedSets = sets
        recap.bests = bests
        let inWindow = history.filter { $0.completedAt >= start && $0.completedAt < window.end && $0.completedSetCount > 0 }
            .sorted { $0.completedAt < $1.completedAt }
        recap.strength = (share?.lifts ?? []).compactMap { lift in
            let dates = inWindow.filter { ($0.exercises ?? []).contains { $0.exerciseID == lift.id } }.map(\.completedAt)
            guard let first = dates.first, let last = dates.last, first < last else { return nil }
            let factor = lift.last.unit == .pounds ? 0.45359237 : 1
            return MembershipTrialRecap.Strength(id: lift.id.rawValue, exerciseName: lift.name,
                firstLoadKilograms: lift.first.value * factor, currentLoadKilograms: lift.last.value * factor,
                firstObservedAt: first, currentObservedAt: last, comparisonQualified: lift.first.unit == lift.last.unit)
        }
        if let days = share?.trainingDays {
            recap.attendance = days.map { MembershipTrialRecap.AttendanceDay(date: $0.id, planned: nil, completed: $0.trained) }
        }
        return recap
    }
}

/// Proof 56: "2 days left in your trial" and "Your card is waiting". Local only,
/// rebuilt whenever the trial or history changes; never asks for permission (the
/// trial reminder also goes by email to account holders).
enum TrialNotificationScheduler {
    static let reminderID = "01.trial.reminder"
    static let waitingID = "01.trial.cardWaiting"
    static let hour = 18

    struct Plan: Equatable {
        let identifier: String
        let fireAt: Date
        let title: String
        let body: String
    }

    static func plan(window: TrialWindow?, continuation: MembershipRecapRenewal.Continuation,
                     continued: Bool, renewal: MembershipRecapRenewal?, progress: TrialProgress?,
                     now: Date, calendar: Calendar, localization: AppLocalization) -> [Plan] {
        guard let window, !continued else { return [] }
        var plans: [Plan] = []
        let day = Date.FormatStyle.dateTime.day().month(.wide).locale(localization.locale)
        let cancelBy = MembershipOfferCalendar.lastFreeDay(paymentStarts: window.end, calendar: calendar) ?? window.end
        if continuation != .cancelled,
           let twoBefore = calendar.date(byAdding: .day, value: -2, to: window.end),
           let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: twoBefore), fire > now {
            var lines: [String] = []
            if let progress, progress.workouts > 0 {
                lines.append(localization.format("%1$@ so far.", .text(progress.summary(localization))))
            }
            if let renewal, renewal.hasVerifiedPriceAndPeriod, let price = renewal.verifiedPrice, let period = renewal.verifiedPeriod {
                lines.append(localization.format("On %1$@ it becomes %2$@ %3$@.", .text(window.end.formatted(day)),
                                                 .text(price), .text(localization.string(period))))
            } else {
                lines.append(localization.format("On %1$@ your card becomes yours.", .text(window.end.formatted(day))))
            }
            lines.append(localization.format("Cancel by %1$@ and nothing is charged.", .text(cancelBy.formatted(day))))
            plans.append(Plan(identifier: reminderID, fireAt: fire, title: localization.string("2 days left in your trial"),
                              body: lines.joined(separator: " ")))
        }
        if continuation == .cancelled,
           let threeAfter = calendar.date(byAdding: .day, value: 3, to: window.end),
           let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: threeAfter), fire > now {
            let held = (TrialWindow.holdDays - 3).formatted(.number.locale(localization.locale))
            let body: String
            if let progress, progress.workouts > 0 {
                body = localization.format("Your card is held for you for %1$@ more days, with your %2$@.",
                                           .text(held), .text(progress.summary(localization)))
            } else {
                body = localization.format("Your card is held for you for %1$@ more days.", .text(held))
            }
            plans.append(Plan(identifier: waitingID, fireAt: fire, title: localization.string("Your card is waiting"), body: body))
        }
        return plans
    }

    static func reconcile(_ plans: [Plan], calendar: Calendar = .current) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID, Self.waitingID])
        guard !plans.isEmpty else { return }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            for plan in plans {
                let content = UNMutableNotificationContent()
                content.title = plan.title
                content.body = plan.body
                content.sound = .default
                // Scheduled outside the smart-note daily limit: the trial reminder is never dropped.
                content.threadIdentifier = "01.membership"
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: plan.fireAt)
                try? await center.add(UNNotificationRequest(identifier: plan.identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
        }
    }
}

/// Settings, Notifications (proof 56): Club and membership rows, on by default.
enum MembershipNotificationPreference {
    static let clubKey = "01.notify.club"
    static let membershipKey = "01.notify.membership"
    /// Sammy 10 Oct: "Remind me 2 days before I'm charged", on by default, switched off on the
    /// Membership screen. Covers the trial reminder and every renewal.
    static let chargeReminderKey = "01.notify.chargeReminder"
    static var membershipOn: Bool { UserDefaults.standard.object(forKey: membershipKey) as? Bool ?? true }
    static var chargeReminderOn: Bool { UserDefaults.standard.object(forKey: chargeReminderKey) as? Bool ?? true }
    /// Both the trial notes and the renewal reminder.
    static var remindersOn: Bool { membershipOn && chargeReminderOn }
}

/// Sammy 10 Oct: a note 2 days before every paid renewal (the trial has its own, richer note above).
/// Only while Apple says the plan renews; local, rebuilt whenever membership changes.
enum ChargeReminderScheduler {
    static let reminderID = "01.renewal.reminder"

    static func plan(next: MembershipNextCharge?, enabled: Bool, now: Date, calendar: Calendar,
                     localization: AppLocalization) -> TrialNotificationScheduler.Plan? {
        guard enabled, let next, next.renews, !next.isTrial,
              let twoBefore = calendar.date(byAdding: .day, value: -2, to: next.date),
              let fire = calendar.date(bySettingHour: TrialNotificationScheduler.hour, minute: 0, second: 0, of: twoBefore),
              fire > now else { return nil }
        let day = next.date.formatted(.dateTime.day().month(.wide).locale(localization.locale))
        let body: String
        if let price = next.price, let period = next.period {
            body = localization.format("On %1$@ your 01 membership renews for %2$@ %3$@. To change or cancel, use Manage in App Store.",
                                       .text(day), .text(price), .text(localization.string(period)))
        } else {
            body = localization.format("On %1$@ your 01 membership renews. To change or cancel, use Manage in App Store.", .text(day))
        }
        return TrialNotificationScheduler.Plan(identifier: reminderID, fireAt: fire,
                                               title: localization.string("Your membership renews in 2 days"), body: body)
    }

    static func reconcile(_ plan: TrialNotificationScheduler.Plan?, calendar: Calendar = .current) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard let plan else { return }
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.threadIdentifier = "01.membership"
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: plan.fireAt)
            try? await center.add(UNNotificationRequest(identifier: plan.identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }
}

extension Notification.Name {
    /// The Membership screen's reminder switch changed; the app root rebuilds the notes.
    static let zeroOneChargeReminderChanged = Notification.Name("01.chargeReminderChanged")
}
