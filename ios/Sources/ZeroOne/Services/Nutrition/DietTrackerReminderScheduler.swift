import Foundation
import UserNotifications

/// Proof 23: "Remind me" and "Remind again if not logged" for supplement and
/// medicine trackers. Local notifications only, for the next two days, rebuilt
/// whenever trackers or logs change. A logged time drops its second nudge. The
/// text repeats the person's own name and dose; 01 never suggests a dose.
protocol DietTrackerReminderScheduling: AnyObject {
    func reconcile(_ snapshot: DietTrackerSnapshot, now: Date)
}

struct DietTrackerReminderPlan: Equatable {
    struct Item: Equatable {
        let identifier: String
        let fireAt: Date
        let title: String
        let body: String
    }

    static let prefix = "01.tracker."
    static let secondNudgeMinutes = 30
    /// iOS keeps at most 64 pending requests per app, shared with 01's other notes.
    static let maximum = 24

    static func make(_ snapshot: DietTrackerSnapshot, now: Date, calendar: Calendar,
                     localization: AppLocalization = .english) -> [Item] {
        var items: [Item] = []
        for dayOffset in 0 ... 1 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let day = try? DietTrackerDay(containing: dayDate, timeZone: calendar.timeZone) else { continue }
            let dayStart = calendar.startOfDay(for: dayDate)
            let stamp = calendar.dateComponents([.year, .month, .day], from: dayStart)
            let dayKey = "\(stamp.year ?? 0)\(stamp.month ?? 0)\(stamp.day ?? 0)"
            for tracker in snapshot.trackers where tracker.remindMe && !tracker.isArchived {
                for time in tracker.times {
                    guard let fire = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: dayStart) else { continue }
                    let logged = snapshot.completions.contains {
                        $0.trackerID == tracker.id && $0.scheduledTime?.id == time.id && $0.day == day
                    }
                    let base = prefix + tracker.id.uuidString + "." + time.id.uuidString + "." + dayKey
                    let tick = localization.string("Tap to tick it off.")
                    let body = tracker.dose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? tick : tracker.dose + ". " + tick
                    if fire > now, !logged {
                        items.append(Item(identifier: base + ".first", fireAt: fire, title: tracker.name, body: body))
                    }
                    if tracker.remindAgainIfNotLogged, !logged,
                       let again = calendar.date(byAdding: .minute, value: secondNudgeMinutes, to: fire), again > now {
                        items.append(Item(identifier: base + ".again", fireAt: again, title: tracker.name,
                            body: localization.string("Not ticked yet. ") + body))
                    }
                }
            }
        }
        return Array(items.sorted { $0.fireAt < $1.fireAt }.prefix(maximum))
    }
}

final class DietTrackerReminderScheduler: DietTrackerReminderScheduling {
    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    init(center: UNUserNotificationCenter = .current(), calendar: Calendar = .current) {
        self.center = center
        self.calendar = calendar
    }

    func reconcile(_ snapshot: DietTrackerSnapshot, now: Date = .now) {
        let language = AppLanguagePreference.storedValue(UserDefaults.standard.string(forKey: AppLanguagePreference.storageKey)).resolvedLanguage()
        let plan = DietTrackerReminderPlan.make(snapshot, now: now, calendar: calendar,
                                                localization: AppLocalization(language: language))
        let center = center
        let calendar = calendar
        Task {
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(DietTrackerReminderPlan.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            guard !plan.isEmpty else { return }
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                // Asked only once a tracker has Remind me switched on.
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            for item in plan {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                content.threadIdentifier = "01.trackers"
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireAt)
                let request = UNNotificationRequest(identifier: item.identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                try? await center.add(request)
            }
        }
    }
}
