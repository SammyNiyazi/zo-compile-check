import EventKit
import Foundation

/// Retrieves only identifiers previously acknowledged for app-owned appointments. No queries,
/// calendar-event enumeration, analytics, external contents storage or backend requests.
@MainActor
final class AppleAppointmentCalendarWriter: AppointmentCalendarWriting {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) { self.store = store }

    func requestAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .denied, .restricted: return false
        default: return try await store.requestFullAccessToEvents()
        }
    }

    func upsert(_ appointment: WorkoutAppointment, eventIdentifier: String?) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppointmentCalendarError.unchanged("Calendar access is off. Your local appointment is still saved.")
        }
        let event: EKEvent
        if let eventIdentifier {
            guard let owned = store.event(withIdentifier: eventIdentifier) else {
                throw AppointmentCalendarError.unchanged("The Calendar copy is missing. Remove its saved link before adding another copy.")
            }
            guard owned.url == appointment.ownershipURL else {
                throw AppointmentCalendarError.unchanged("The Calendar copy no longer has its 01 ownership marker. It was left unchanged.")
            }
            event = owned
        } else {
            guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
                throw AppointmentCalendarError.unchanged("No writable default Calendar is available. Your local appointment is still saved.")
            }
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        event.title = appointment.title
        event.startDate = appointment.startsAt
        event.endDate = appointment.endsAt
        event.timeZone = TimeZone(identifier: appointment.timeZoneIdentifier)
        event.isAllDay = false
        event.url = appointment.ownershipURL
        event.notes = "One-way copy of a workout appointment in 01. Changes in Calendar do not update 01."
        event.alarms = appointment.calendarAlarmEnabled && appointment.status == .scheduled
            ? [EKAlarm(relativeOffset: 0)] : []
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            // Apple documents rollback of immediate commit failures.
            store.reset()
            throw AppointmentCalendarError.unchanged("Calendar couldn't save this copy. Your local appointment is still saved. Retry Calendar when ready.")
        }
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw AppointmentCalendarError.uncertain("Calendar saved a copy without returning its identifier. Check Calendar before adding another.")
        }
        return identifier
    }

    func remove(eventIdentifier: String, ownershipURL: URL) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppointmentCalendarError.unchanged("Calendar access is off. The Calendar copy may still exist.")
        }
        guard let event = store.event(withIdentifier: eventIdentifier) else { return }
        guard event.url == ownershipURL else {
            throw AppointmentCalendarError.unchanged("The Calendar entry no longer has its 01 ownership marker. Remove it in Calendar if you want to. It was left unchanged.")
        }
        do { try store.remove(event, span: .thisEvent, commit: true) }
        catch {
            store.reset()
            throw AppointmentCalendarError.unchanged("The local appointment is saved, but Calendar couldn't remove its copy. Retry Calendar when ready.")
        }
    }
}
