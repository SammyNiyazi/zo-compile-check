import Foundation

enum DietTrackerKind: String, Codable, CaseIterable, Sendable {
    case supplement, medicine, other
}

/// User-entered wall-clock time, not a prescribed dose or a notification grant.
struct DietTrackerTime: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let hour: Int
    let minute: Int

    init(id: UUID = UUID(), hour: Int, minute: Int) {
        self.id = id; self.hour = hour; self.minute = minute
    }

    var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
    var minuteOfDay: Int { hour * 60 + minute }
}

struct DietTracker: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let revision: UUID
    let name: String
    let kind: DietTrackerKind
    let dose: String
    let times: [DietTrackerTime]
    let remindMe: Bool
    let remindAgainIfNotLogged: Bool
    let createdAt: Date
    let updatedAt: Date
    let isArchived: Bool

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 4_096 && dose.utf8.count <= 4_096
            && times.count <= 64 && times.allSatisfy(\.isValid)
            && Set(times.map(\.id)).count == times.count
            && Set(times.map(\.minuteOfDay)).count == times.count
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && updatedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

struct DietTrackerDraft: Equatable, Sendable {
    var name = ""
    var kind = DietTrackerKind.other
    var dose = ""
    var times: [DietTrackerTime] = []
    var remindMe = false
    var remindAgainIfNotLogged = false
    private(set) var original: DietTracker?

    init() {}

    init(tracker: DietTracker) {
        name = tracker.name; kind = tracker.kind; dose = tracker.dose
        times = tracker.times; remindMe = tracker.remindMe
        remindAgainIfNotLogged = tracker.remindAgainIfNotLogged; original = tracker
    }

    func validated(id: UUID, revision: UUID = UUID(), at date: Date) throws -> DietTracker {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DietTrackerError.nameRequired }
        guard times.count <= 64, times.allSatisfy(\.isValid) else { throw DietTrackerError.invalidEntry }
        guard Set(times.map(\.minuteOfDay)).count == times.count,
              Set(times.map(\.id)).count == times.count else { throw DietTrackerError.duplicateTime }
        let entry = DietTracker(id: id, revision: revision, name: title, kind: kind,
            dose: dose, times: times.sorted { $0.minuteOfDay < $1.minuteOfDay },
            remindMe: remindMe, remindAgainIfNotLogged: remindAgainIfNotLogged,
            createdAt: original?.createdAt ?? date, updatedAt: date,
            isArchived: original?.isArchived ?? false)
        guard entry.isValid else { throw DietTrackerError.invalidEntry }
        return entry
    }
}

/// Captures the actual civil-day interval and timezone used by the visible checklist.
/// A day may be23 or25 hours. No fixed86400-second reset or midnight timer is used.
struct DietTrackerDay: Codable, Equatable, Hashable, Sendable {
    let start: Date
    let end: Date
    let timeZoneIdentifier: String

    init(containing date: Date, timeZone: TimeZone) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw DietTrackerError.invalidDay }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw DietTrackerError.invalidDay
        }
        start = interval.start; end = interval.end; timeZoneIdentifier = timeZone.identifier
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    var isValid: Bool {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              let zone = TimeZone(identifier: timeZoneIdentifier),
              let derived = try? Self(containing: start, timeZone: zone) else { return false }
        return derived == self && end > start
    }
}

/// A manual log of one occurrence. Names/dose/times retain their entered values
/// at the action; an edit never rewrites what the person previously logged.
struct DietTrackerCompletion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let trackerID: UUID
    let trackerRevision: UUID
    let name: String
    let kind: DietTrackerKind
    let dose: String
    let scheduledTime: DietTrackerTime?
    let day: DietTrackerDay
    let loggedAt: Date

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 4_096 && dose.utf8.count <= 4_096
            && (scheduledTime?.isValid ?? true) && day.isValid
            && loggedAt.timeIntervalSinceReferenceDate.isFinite && day.contains(loggedAt)
    }
}

struct DietTrackerOccurrence: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let trackerID: UUID
        let timeID: UUID?
        let day: DietTrackerDay
    }

    let tracker: DietTracker
    let time: DietTrackerTime?
    let day: DietTrackerDay
    let completions: [DietTrackerCompletion]
    var id: ID { ID(trackerID: tracker.id, timeID: time?.id, day: day) }
    var isCompleted: Bool { !completions.isEmpty }
    var hasEarlierDetails: Bool {
        completions.contains {
            $0.name != tracker.name || $0.kind != tracker.kind || $0.dose != tracker.dose
                || $0.scheduledTime != time
        }
    }
}

struct DietTrackerSnapshot: Codable, Equatable, Sendable {
    let version: Int
    var trackers: [DietTracker]
    var completions: [DietTrackerCompletion]
    static let empty = Self(version: 1, trackers: [], completions: [])

    func validate() throws {
        guard version == 1, trackers.count <= 10_000, completions.count <= 100_000,
              trackers.allSatisfy(\.isValid), completions.allSatisfy(\.isValid),
              Set(trackers.map(\.id)).count == trackers.count,
              Set(completions.map(\.id)).count == completions.count else {
            throw DietTrackerError.invalidFile
        }
        let owners = Set(trackers.map(\.id))
        var occurrences = Set<DietTrackerOccurrence.ID>()
        for log in completions {
            guard owners.contains(log.trackerID), occurrences.insert(.init(
                trackerID: log.trackerID, timeID: log.scheduledTime?.id, day: log.day)).inserted else {
                throw DietTrackerError.invalidFile
            }
        }
    }
}

enum DietTrackerError: Error, Equatable, LocalizedError, Sendable {
    case nameRequired, duplicateTime, invalidEntry, invalidDay, entryNotFound
    case entryChanged, archived, outsideDay, invalidFile, storeChanged, storeUnavailable, saveFailed, storageLimit

    var errorDescription: String? {
        switch self {
        case .nameRequired: return "Enter a tracker name."
        case .duplicateTime: return "Each tracker time must be different."
        case .invalidEntry: return "Check the tracker fields and times."
        case .invalidDay, .outsideDay: return "The day changed. Open the current checklist and try again."
        case .entryNotFound: return "This tracker or log is no longer available."
        case .entryChanged: return "The tracker changed. Open its latest details before editing or logging."
        case .archived: return "Restore this tracker before logging it."
        case .invalidFile, .storeUnavailable: return "Tracker storage could not be read. Your saved data has not been replaced."
        case .storeChanged: return "Tracker storage changed. Reload it before trying again."
        case .saveFailed: return "The change was not confirmed saved. Reload or retry before continuing."
        case .storageLimit: return "Tracker storage reached its size limit. Remove unwanted trackers before saving."
        }
    }
}
