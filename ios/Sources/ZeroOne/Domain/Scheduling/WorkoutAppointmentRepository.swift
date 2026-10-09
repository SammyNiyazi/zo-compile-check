import Foundation
import Observation

protocol WorkoutAppointmentPersisting {
    func load() throws -> [WorkoutAppointment]
    func save(_ appointments: [WorkoutAppointment]) throws
}

enum AppointmentStoreError: Error {
    case unavailable, invalid, conflict
}

@MainActor @Observable
final class WorkoutAppointmentRepository {
    private(set) var appointments: [WorkoutAppointment] = []
    private(set) var isAvailable = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let store: any WorkoutAppointmentPersisting

    init(store: any WorkoutAppointmentPersisting) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            let loaded = try store.load()
            guard Self.isValid(loaded) else { throw AppointmentStoreError.invalid }
            appointments = loaded
            isAvailable = true
            errorMessage = nil
        } catch {
            isAvailable = false
            errorMessage = "Your schedule couldn't be read. Existing appointments are preserved. Retry recovery."
        }
    }

    func appointment(id: UUID) -> WorkoutAppointment? { appointments.first { $0.id == id } }

    /// The editor keeps the same ID across retries, so ambiguous acknowledgments cannot duplicate it.
    @discardableResult
    func save(_ draft: WorkoutAppointment, expectedRevision: Int?, now: Date = .now) -> Bool {
        guard draft.isValid, draft.status == .scheduled, draft.startsAt > now else {
            errorMessage = "Choose a future date and a valid workout and reservation length."
            return false
        }
        guard !appointments.contains(where: { $0.id != draft.id && $0.status == .scheduled && $0.reference == draft.reference && $0.startsAt == draft.startsAt }) else {
            errorMessage = "This workout is already scheduled at that time."
            return false
        }
        var next = appointments
        if let index = next.firstIndex(where: { $0.id == draft.id }) {
            let existing = next[index]
            // Exact retry after an acknowledged save needs no new revision.
            if existing.reference == draft.reference, existing.title == draft.title,
               existing.startsAt == draft.startsAt, existing.timeZoneIdentifier == draft.timeZoneIdentifier,
               existing.durationMinutes == draft.durationMinutes,
               existing.calendarAlarmEnabled == draft.calendarAlarmEnabled, existing.status == .scheduled {
                return persist(next)
            }
            guard existing.revision == expectedRevision, existing.status == .scheduled,
                  existing.preparedSessionID == nil,
                  existing.startedSessionID == nil || existing.reference == draft.reference,
                  existing.calendarLink?.operation == nil,
                  existing.calendarLink?.creationUncertain != true else {
                errorMessage = "This appointment changed or has an unresolved Calendar save. Reload it before editing."
                return false
            }
            var edited = draft
            edited.revision = existing.revision + 1
            edited.startedSessionID = existing.startedSessionID
            edited.calendarLink = existing.calendarLink
            edited.calendarLink?.errorMessage = nil
            next[index] = edited
        } else {
            guard expectedRevision == nil, draft.revision == 1, draft.calendarLink == nil,
                  draft.startedSessionID == nil, draft.preparedSessionID == nil else {
                errorMessage = "This appointment no longer matches your saved schedule."
                return false
            }
            guard !next.contains(where: { $0.status == .scheduled && $0.reference == draft.reference && $0.startsAt == draft.startsAt }) else {
                errorMessage = "This workout is already scheduled at that time."
                return false
            }
            next.append(draft)
        }
        return persist(next)
    }

    @discardableResult
    func cancel(id: UUID, expectedRevision: Int) -> Bool {
        guard var current = appointment(id: id), current.revision == expectedRevision,
              current.status != .completed else { return failConflict() }
        if current.status == .cancelled { return persist(appointments) }
        guard current.calendarLink?.operation == nil else {
            errorMessage = "Confirm the pending Calendar result before cancelling this appointment."
            return false
        }
        current.status = .cancelled
        current.preparedSessionID = nil
        current.revision += 1
        current.calendarLink?.errorMessage = nil
        return replace(current)
    }

    /// Host calls this only after actual History persistence acknowledges this workout UUID.
    /// Identity is the appointment chosen at Start, never a nearest-time guess.
    @discardableResult
    func associateAcknowledgedCompletion(appointmentID: UUID, reference: ScheduledWorkoutReference, historyID: UUID) -> Bool {
        guard var current = appointment(id: appointmentID), current.reference == reference,
              current.startedSessionID == historyID || current.preparedSessionID == historyID else { return failConflict() }
        if current.status == .completed {
            return current.completedHistoryID == historyID ? persist(appointments) : failConflict()
        }
        guard current.status == .scheduled, current.calendarLink?.operation == nil,
              !appointments.contains(where: { $0.id != current.id && $0.completedHistoryID == historyID }) else { return failConflict() }
        current.status = .completed
        current.startedSessionID = historyID
        current.preparedSessionID = nil
        current.completedHistoryID = historyID
        current.revision += 1
        return replace(current)
    }

    /// Save before creating the active snapshot. Failure must prevent launch, so the gap
    /// between snapshot acknowledgment and binding acknowledgment has durable context.
    @discardableResult
    func prepareSessionLaunch(appointmentID: UUID, reference: ScheduledWorkoutReference, sessionID: UUID) -> Bool {
        guard var current = appointment(id: appointmentID), current.reference == reference,
              current.status == .scheduled,
              !appointments.contains(where: { $0.id != appointmentID && ($0.startedSessionID == sessionID || $0.preparedSessionID == sessionID) }) else { return failConflict() }
        if let started = current.startedSessionID { return started == sessionID ? persist(appointments) : failConflict() }
        if let prepared = current.preparedSessionID { return prepared == sessionID ? persist(appointments) : failConflict() }
        guard current.calendarLink?.operation == nil else { return failConflict() }
        let previousRevision = current.revision
        current.preparedSessionID = sessionID
        current.revision += 1
        if current.calendarLink?.acknowledgedRevision == previousRevision { current.calendarLink?.acknowledgedRevision = current.revision }
        return replace(current)
    }

    /// Host calls after the exact session's active snapshot save is acknowledged.
    /// Relaunch/retry retains this association; each session can own only one appointment.
    @discardableResult
    func bindStartedSession(appointmentID: UUID, reference: ScheduledWorkoutReference, sessionID: UUID) -> Bool {
        guard var current = appointment(id: appointmentID), current.reference == reference,
              current.status == .scheduled,
              !appointments.contains(where: { $0.id != appointmentID && $0.startedSessionID == sessionID }) else { return failConflict() }
        if let existing = current.startedSessionID {
            return existing == sessionID ? persist(appointments) : failConflict()
        }
        guard current.calendarLink?.operation == nil, current.preparedSessionID == sessionID else { return failConflict() }
        let previousRevision = current.revision
        current.startedSessionID = sessionID
        current.preparedSessionID = nil
        current.revision += 1
        // Binding changes no exported content, so an existing acknowledgment remains valid.
        if current.calendarLink?.acknowledgedRevision == previousRevision {
            current.calendarLink?.acknowledgedRevision = current.revision
        }
        return replace(current)
    }

    /// Invoke only for session IDs proven to exist in acknowledged History, including after relaunch.
    /// Missing bindings are a harmless no-op: unrelated workouts never complete an appointment.
    @discardableResult
    func associateAcknowledgedCompletionForSession(sessionID: UUID) -> Bool {
        guard let current = appointments.first(where: { $0.startedSessionID == sessionID || $0.preparedSessionID == sessionID }) else { return true }
        if current.status == .cancelled { return true }
        return associateAcknowledgedCompletion(appointmentID: current.id, reference: current.reference, historyID: sessionID)
    }

    /// Root calls only with an exact active snapshot UUID acknowledged by its persistence.
    @discardableResult
    func acknowledgePreparedSessionIfActive(sessionID: UUID) -> Bool {
        guard let current = appointments.first(where: { $0.preparedSessionID == sessionID }) else { return true }
        return bindStartedSession(appointmentID: current.id, reference: current.reference, sessionID: sessionID)
    }

    /// Explicit orphan-intent recovery only after root checks no matching snapshot or History.
    @discardableResult
    func clearPreparedSession(appointmentID: UUID, sessionID: UUID) -> Bool {
        guard var current = appointment(id: appointmentID), current.preparedSessionID == sessionID,
              current.startedSessionID == nil, current.status == .scheduled else { return failConflict() }
        current.preparedSessionID = nil
        let previousRevision = current.revision
        current.revision += 1
        if current.calendarLink?.acknowledgedRevision == previousRevision { current.calendarLink?.acknowledgedRevision = current.revision }
        return replace(current)
    }

    /// Only after unfinished Exit acknowledges owner-snapshot cleanup and History has no such ID.
    /// An abandoned session is not a completion; the appointment can then be started again.
    @discardableResult
    func releaseAcknowledgedAbandonedSession(sessionID: UUID) -> Bool {
        guard var current = appointments.first(where: { $0.startedSessionID == sessionID }) else { return true }
        guard current.status == .scheduled, current.completedHistoryID == nil,
              current.calendarLink?.operation == nil else { return failConflict() }
        let previousRevision = current.revision
        current.startedSessionID = nil
        current.revision += 1
        if current.calendarLink?.acknowledgedRevision == previousRevision {
            current.calendarLink?.acknowledgedRevision = current.revision
        }
        return replace(current)
    }

    @discardableResult
    func replaceCalendarLink(id: UUID, expectedRevision: Int, link: AppointmentCalendarLink?) -> Bool {
        guard var current = appointment(id: id), current.revision == expectedRevision else { return failConflict() }
        current.calendarLink = link
        return replace(current)
    }

    private func replace(_ appointment: WorkoutAppointment) -> Bool {
        var next = appointments
        guard let index = next.firstIndex(where: { $0.id == appointment.id }) else { return failConflict() }
        next[index] = appointment
        return persist(next)
    }

    private func failConflict() -> Bool {
        errorMessage = "This appointment no longer matches the saved schedule. Reload it and try again."
        return false
    }

    private func persist(_ next: [WorkoutAppointment]) -> Bool {
        guard isAvailable, Self.isValid(next) else { return false }
        do {
            let before = try store.load()
            guard Self.isValid(before) else { throw AppointmentStoreError.invalid }
            guard before == appointments else {
                appointments = before
                errorMessage = "The saved schedule changed. Review it before trying again."
                return false
            }
            if before != next {
                // A late I/O error is acknowledged only by exact readback.
                do { try store.save(next) } catch { }
            }
            guard try store.load() == next else { throw AppointmentStoreError.unavailable }
            appointments = next
            errorMessage = nil
            return true
        } catch {
            isAvailable = false
            errorMessage = "Your change wasn't confirmed. Keep this screen open and retry recovery. The last confirmed appointment is preserved."
            return false
        }
    }

    nonisolated static func isValid(_ values: [WorkoutAppointment]) -> Bool {
        let completions = values.compactMap(\.completedHistoryID)
        let bindings = values.compactMap(\.startedSessionID) + values.compactMap(\.preparedSessionID)
        return Set(values.map(\.id)).count == values.count && values.allSatisfy(\.isValid)
            && Set(completions).count == completions.count
            && Set(bindings).count == bindings.count
    }
}
