import Foundation

/// Stable source identity. Titles are snapshots for display, never routing keys.
enum ScheduledWorkoutReference: Codable, Equatable, Hashable {
    case programme(WorkoutProgrammeID, sessionID: String)
    case custom(UUID)

    var stableKey: String {
        switch self {
        case let .programme(id, sessionID): "programme:\(id.rawValue):\(sessionID)"
        case let .custom(id): "custom:\(id.uuidString)"
        }
    }

    var isValid: Bool {
        switch self {
        case let .programme(_, sessionID): !sessionID.isEmpty
        case .custom: true
        }
    }
}

struct SchedulingWorkoutOption: Identifiable, Equatable {
    let reference: ScheduledWorkoutReference
    let title: String
    var id: String { reference.stableKey }

    static func available(programmes: [WorkoutProgramme], customWorkouts: [CustomWorkout]) -> [Self] {
        let sessions = programmes.flatMap { programme in
            programme.sessions.map {
                Self(reference: .programme(programme.id, sessionID: $0.id), title: "\(programme.title) · \($0.title)")
            }
        }
        return sessions + customWorkouts.filter(\.isValid).map { Self(reference: .custom($0.id), title: $0.name) }
    }
}

enum AppointmentStatus: String, Codable {
    case scheduled, cancelled, completed
}

enum AppointmentCalendarAction: String, Codable {
    case upsert, remove
}

struct AppointmentCalendarOperation: Codable, Equatable {
    let id: UUID
    let revision: Int
    let action: AppointmentCalendarAction
}

struct AppointmentCalendarLink: Codable, Equatable {
    var eventIdentifier: String?
    var acknowledgedRevision: Int?
    /// Written before crossing the store boundary. An interrupted create is never retried blindly.
    var operation: AppointmentCalendarOperation?
    var errorMessage: String?
    var creationUncertain = false
}

struct WorkoutAppointment: Identifiable, Codable, Equatable {
    let id: UUID
    var revision: Int
    var reference: ScheduledWorkoutReference
    var title: String
    /// Travel changes the displayed local time, never this resolved instant.
    var startsAt: Date
    var timeZoneIdentifier: String
    /// Calendar reservation length, chosen by the user; not measured workout duration.
    var durationMinutes: Int
    var calendarAlarmEnabled: Bool
    var status: AppointmentStatus
    /// Durable launch intent, saved before the host attempts the active snapshot write.
    /// It does not assert that a workout started or completed.
    var preparedSessionID: UUID?
    /// Written only after this exact generated session's active snapshot is acknowledged.
    var startedSessionID: UUID?
    var completedHistoryID: UUID?
    var calendarLink: AppointmentCalendarLink?

    init(
        id: UUID = UUID(), reference: ScheduledWorkoutReference, title: String,
        startsAt: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
        durationMinutes: Int = 45, calendarAlarmEnabled: Bool = false
    ) {
        self.id = id
        revision = 1
        self.reference = reference
        self.title = title
        self.startsAt = startsAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.durationMinutes = durationMinutes
        self.calendarAlarmEnabled = calendarAlarmEnabled
        status = .scheduled
    }

    var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var ownershipURL: URL { URL(string: "the01://appointment/\(id.uuidString)")! }

    var isValid: Bool {
        revision > 0 && reference.isValid
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 240
            && startsAt.timeIntervalSinceReferenceDate.isFinite
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && (5 ... 240).contains(durationMinutes)
            && (status == .completed) == (completedHistoryID != nil)
            && (completedHistoryID == nil || completedHistoryID == startedSessionID)
            && (preparedSessionID == nil || (startedSessionID == nil && status == .scheduled))
            && (calendarLink?.eventIdentifier.map { !$0.isEmpty } ?? true)
            && (calendarLink?.operation.map { $0.revision <= revision && $0.revision > 0 } ?? true)
            && (calendarLink?.acknowledgedRevision.map { $0 <= revision && $0 > 0 } ?? true)
    }

    var calendarMessage: String {
        guard let link = calendarLink else { return "Saved on this iPhone. Calendar is optional." }
        if link.creationUncertain || (link.operation != nil && link.eventIdentifier == nil) {
            return "Calendar save is uncertain. Check Calendar before adding another copy."
        }
        if let error = link.errorMessage { return error }
        if link.operation != nil { return "Calendar change awaiting confirmation." }
        if link.eventIdentifier == nil { return "Calendar copy removed." }
        if status == .cancelled { return "Cancelled locally. Remove the Calendar copy to cancel its alert too." }
        if status == .completed, link.acknowledgedRevision != revision {
            return "Completion linked locally. Update the Calendar copy to remove its alert."
        }
        if link.acknowledgedRevision != revision { return "Local change saved. Update the Calendar copy when ready." }
        return "Calendar copy saved. Calendar edits do not update 01."
    }
}

/// Reject nonexistent wall times and expose the two instants of a repeated DST hour.
enum AppointmentWallTime {
    static func instants(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayComponents = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: dayComponents) else { return [] }
        let match = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        let anchor = calendar.startOfDay(for: date).addingTimeInterval(-1)
        let values = [Calendar.RepeatedTimePolicy.first, .last].compactMap {
            calendar.nextDate(after: anchor, matching: match, matchingPolicy: .strict, repeatedTimePolicy: $0, direction: .forward)
        }.filter { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) == DateComponents(year: year, month: month, day: day, hour: hour, minute: minute) }
        return Array(Set(values)).sorted()
    }
}
