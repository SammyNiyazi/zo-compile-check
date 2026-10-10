import Foundation
import Observation

enum AppointmentCalendarError: Error {
    /// Adapter guarantees no external mutation, including EventKit commit rollback.
    case unchanged(String)
    /// A result without a durable identifier must not become a second create.
    case uncertain(String)

    var message: String {
        switch self {
        case let .unchanged(message), let .uncertain(message): message
        }
    }
}

@MainActor
protocol AppointmentCalendarWriting {
    /// Permission requests happen only in response to the explicit Calendar button.
    func requestAccess() async throws -> Bool
    func upsert(_ appointment: WorkoutAppointment, eventIdentifier: String?) throws -> String
    func remove(eventIdentifier: String, ownershipURL: URL) throws
}

@MainActor @Observable
final class AppointmentCalendarCoordinator {
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    let repository: WorkoutAppointmentRepository
    @ObservationIgnored private let writer: any AppointmentCalendarWriting
    /// Retain a received identifier when its local write fails. Retry persists this receipt only.
    @ObservationIgnored private var unconfirmedReceipts: [UUID: AppointmentCalendarLink] = [:]

    init(repository: WorkoutAppointmentRepository, writer: any AppointmentCalendarWriting) {
        self.repository = repository
        self.writer = writer
    }

    /// One-way copy management; never automatic sync, enumeration or external edit import.
    @discardableResult
    func applyCalendarChange(id: UUID, removeCopy: Bool = false, now: Date = .now) async -> Bool {
        guard !isBusy, let current = repository.appointment(id: id), repository.isAvailable else { return false }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        if let receipt = unconfirmedReceipts[id] {
            let saved = repository.replaceCalendarLink(id: id, expectedRevision: current.revision, link: receipt)
            if saved { unconfirmedReceipts.removeValue(forKey: id) }
            return saved
        }

        var link = current.calendarLink ?? AppointmentCalendarLink()
        let remove = removeCopy || current.status == .cancelled || link.operation?.action == .remove
        if link.creationUncertain || (link.operation != nil && link.eventIdentifier == nil) {
            errorMessage = "A Calendar copy may already exist. Check Calendar and remove it before confirming recovery."
            return false
        }
        if remove, link.eventIdentifier == nil {
            return repository.replaceCalendarLink(id: id, expectedRevision: current.revision, link: nil)
        }
        if !remove, current.status == .scheduled, current.startsAt <= now {
            errorMessage = "This appointment time has passed. Reschedule it before adding a Calendar copy."
            return false
        }
        if !remove, link.operation == nil, link.errorMessage == nil,
           link.eventIdentifier != nil, link.acknowledgedRevision == current.revision { return true }

        do {
            guard try await writer.requestAccess() else {
                errorMessage = "Calendar access is off. Your local appointment is still saved. You can change access in iPhone Settings."
                return false
            }
        } catch {
            errorMessage = "Calendar access couldn't be requested. Your local appointment is still saved."
            return false
        }
        // Revalidate after the permission suspension; another local operation may have occurred.
        guard repository.appointment(id: id) == current else {
            errorMessage = "The appointment changed. Review it before updating Calendar."
            return false
        }
        let operation = AppointmentCalendarOperation(id: UUID(), revision: current.revision, action: remove ? .remove : .upsert)
        link.operation = operation
        link.errorMessage = nil
        guard repository.replaceCalendarLink(id: id, expectedRevision: current.revision, link: link) else { return false }

        do {
            if remove {
                if let identifier = link.eventIdentifier {
                    try writer.remove(eventIdentifier: identifier, ownershipURL: current.ownershipURL)
                }
                link.eventIdentifier = nil
            } else {
                link.eventIdentifier = try writer.upsert(current, eventIdentifier: link.eventIdentifier)
            }
            link.acknowledgedRevision = current.revision
            link.operation = nil
            link.creationUncertain = false
            link.errorMessage = nil
        } catch {
            let failure = error as? AppointmentCalendarError
                ?? .uncertain("Calendar didn't confirm this change. Check the Calendar copy before retrying.")
            link.errorMessage = failure.message
            switch failure {
            case .unchanged:
                link.operation = nil
            case .uncertain:
                link.creationUncertain = link.eventIdentifier == nil
                // Existing owned IDs can be retried idempotently. Unknown creates stay blocked.
            }
        }

        let saved = repository.replaceCalendarLink(id: id, expectedRevision: current.revision, link: link)
        if !saved { unconfirmedReceipts[id] = link }
        errorMessage = saved ? link.errorMessage : "Calendar responded, but its receipt wasn't saved. Keep 01 open, retry recovery, then retry Calendar to confirm the same receipt."
        return saved && link.errorMessage == nil
    }

    /// Explicit recovery assertion from the user, after they checked Calendar and removed an
    /// uncertain orphan. We cannot discover it without reading other events, so never pretend to.
    @discardableResult
    func confirmUncertainCopyRemoved(id: UUID) -> Bool {
        guard !isBusy, unconfirmedReceipts[id] == nil, let current = repository.appointment(id: id),
              let link = current.calendarLink, link.eventIdentifier == nil,
              link.creationUncertain || link.operation != nil else { return false }
        return repository.replaceCalendarLink(id: id, expectedRevision: current.revision, link: nil)
    }
}
