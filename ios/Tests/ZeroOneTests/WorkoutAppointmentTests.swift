import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutAppointmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFutureAppointmentIsAcknowledgedAndRetryDoesNotDuplicate() {
        let store = AppointmentStoreDouble()
        let repository = WorkoutAppointmentRepository(store: store)
        let value = appointment()
        XCTAssertTrue(repository.save(value, expectedRevision: nil, now: now))
        XCTAssertTrue(repository.save(value, expectedRevision: nil, now: now))
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(repository.appointments, [value])
    }

    func testPastAndDuplicateSourceAtSameInstantAreRejected() {
        let store = AppointmentStoreDouble()
        let repository = WorkoutAppointmentRepository(store: store)
        var past = appointment()
        past.startsAt = now
        XCTAssertFalse(repository.save(past, expectedRevision: nil, now: now))
        let value = appointment()
        XCTAssertTrue(repository.save(value, expectedRevision: nil, now: now))
        let duplicate = appointment(reference: value.reference)
        XCTAssertFalse(repository.save(duplicate, expectedRevision: nil, now: now))
        XCTAssertEqual(store.writes, 1)
    }

    func testEditIncrementsRevisionAndRejectsStaleEditor() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        var edited = value
        edited.startsAt = now.addingTimeInterval(7_200)
        XCTAssertTrue(repository.save(edited, expectedRevision: 1, now: now))
        XCTAssertEqual(repository.appointments.first?.revision, 2)
        edited.startsAt = now.addingTimeInterval(10_800)
        XCTAssertFalse(repository.save(edited, expectedRevision: 1, now: now))
        XCTAssertEqual(store.writes, 1)
    }

    func testFailedSaveAndCancelRetainOriginalForRecovery() {
        let original = appointment()
        let store = AppointmentStoreDouble(values: [original])
        let repository = WorkoutAppointmentRepository(store: store)
        store.discardsWrites = true
        var edited = original
        edited.startsAt = now.addingTimeInterval(7_200)
        XCTAssertFalse(repository.save(edited, expectedRevision: 1, now: now))
        XCTAssertEqual(repository.appointments, [original])
        XCTAssertFalse(repository.isAvailable)
        repository.reload()
        XCTAssertFalse(repository.cancel(id: original.id, expectedRevision: 1))
        XCTAssertEqual(store.values, [original])
        store.discardsWrites = false
        repository.reload()
        XCTAssertTrue(repository.cancel(id: original.id, expectedRevision: 1))
        XCTAssertEqual(repository.appointments.first?.status, .cancelled)
    }

    func testLateWriteErrorIsAcknowledgedOnlyByExactReadback() {
        let store = AppointmentStoreDouble()
        let repository = WorkoutAppointmentRepository(store: store)
        store.throwsAfterWrite = true
        let value = appointment()
        XCTAssertTrue(repository.save(value, expectedRevision: nil, now: now))
        XCTAssertEqual(repository.appointments, [value])
    }

    func testExternallyChangedStoreCannotBeOverwritten() {
        let original = appointment()
        let store = AppointmentStoreDouble(values: [original])
        let repository = WorkoutAppointmentRepository(store: store)
        let newer = appointment(reference: .custom(UUID()))
        store.values.append(newer)
        XCTAssertFalse(repository.cancel(id: original.id, expectedRevision: 1))
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(repository.appointments, [original, newer])
    }

    func testUnreadableStoreIsNeverReplacedAndLastConfirmedStateRemains() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        store.readsFail = true
        repository.reload()
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(repository.appointments, [value])
        XCTAssertFalse(repository.cancel(id: value.id, expectedRevision: 1))
        XCTAssertEqual(store.writes, 0)
    }

    func testCompletionUsesExactReferenceHistoryIDAndIsIdempotent() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let history = UUID()
        XCTAssertFalse(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: .custom(UUID()), historyID: history))
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: history))
        XCTAssertTrue(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: history))
        XCTAssertTrue(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: history))
        XCTAssertEqual(store.writes, 3)
        XCTAssertEqual(repository.appointments.first?.completedHistoryID, history)
        XCTAssertFalse(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: UUID()))
    }

    func testTimePassingNeverCompletesAndCancelledAppointmentCannotComplete() {
        var value = appointment()
        value.startsAt = now.addingTimeInterval(-3_600)
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        XCTAssertTrue(repository.cancel(id: value.id, expectedRevision: 1))
        XCTAssertFalse(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: UUID()))
    }

    func testAcknowledgedHistoryAfterAppointmentCancellationRemainsCancelled() {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let sessionID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: sessionID))
        let current = repository.appointment(id: value.id)!
        XCTAssertTrue(repository.cancel(id: current.id, expectedRevision: current.revision))
        XCTAssertTrue(repository.associateAcknowledgedCompletionForSession(sessionID: sessionID))
        XCTAssertEqual(repository.appointment(id: current.id)?.status, .cancelled)
        XCTAssertNil(repository.appointment(id: current.id)?.completedHistoryID)
    }

    func testOneHistoryRecordCannotCompleteTwoAppointments() {
        let first = appointment()
        let second = appointment(reference: .custom(UUID()))
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [first, second]))
        let historyID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: first, sessionID: historyID))
        XCTAssertTrue(repository.associateAcknowledgedCompletion(appointmentID: first.id, reference: first.reference, historyID: historyID))
        XCTAssertFalse(repository.associateAcknowledgedCompletion(appointmentID: second.id, reference: second.reference, historyID: historyID))
    }

    func testDSTRejectsGapAndExposesBothRepeatedInstants() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        XCTAssertTrue(AppointmentWallTime.instants(year: 2026, month: 3, day: 29, hour: 3, minute: 30, timeZone: zone).isEmpty)
        let repeated = AppointmentWallTime.instants(year: 2026, month: 10, day: 25, hour: 3, minute: 30, timeZone: zone)
        XCTAssertEqual(repeated.count, 2)
        if repeated.count == 2 { XCTAssertEqual(repeated[1].timeIntervalSince(repeated[0]), 3_600) }
        XCTAssertEqual(AppointmentWallTime.instants(year: 2026, month: 10, day: 26, hour: 3, minute: 30, timeZone: zone).count, 1)
    }

    func testFileRoundtripPreservesReferenceInstantZoneAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalWorkoutAppointmentStore(rootURL: root)
        let value = appointment(reference: .programme(.zeroOneStart, sessionID: "session-B"))
        try store.save([value])
        XCTAssertEqual(try store.load(), [value])
        let url = root.appendingPathComponent("appointments-v1.json")
        let corrupt = Data("corrupt schedule".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testCalendarExportIsExplicitAndRepeatedTapDoesNotDuplicate() async {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        XCTAssertEqual(writer.permissionRequests, 0)
        let first = await coordinator.applyCalendarChange(id: value.id, now: now)
        let second = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(writer.upserts, 1)
        XCTAssertEqual(repository.appointments.first?.calendarLink?.eventIdentifier, "owned-event")
    }

    func testLocalEditAndCancelMarkCalendarPendingUntilExplicitAction() async {
        var value = appointment()
        value.calendarLink = AppointmentCalendarLink(eventIdentifier: "owned-event", acknowledgedRevision: 1)
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        var draft = value
        draft.startsAt = now.addingTimeInterval(7_200)
        XCTAssertTrue(repository.save(draft, expectedRevision: 1, now: now))
        XCTAssertEqual(writer.upserts, 0)
        XCTAssertEqual(repository.appointments.first?.calendarLink?.acknowledgedRevision, 1)
        let edited = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(edited)
        XCTAssertEqual(writer.lastIdentifier, "owned-event")
        XCTAssertEqual(writer.lastAppointment?.startsAt, draft.startsAt)
        XCTAssertTrue(repository.cancel(id: value.id, expectedRevision: 2))
        XCTAssertEqual(writer.removes, 0)
        let removed = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(removed)
        XCTAssertEqual(writer.removes, 1)
        XCTAssertNil(repository.appointments.first?.calendarLink?.eventIdentifier)
        XCTAssertEqual(repository.appointments.first?.status, .cancelled)
    }

    func testPermissionDenialLeavesLocalSaveAndNoEventMutation() async {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        writer.grantsAccess = false
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let result = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertFalse(result)
        XCTAssertEqual(repository.appointments, [value])
        XCTAssertEqual(writer.upserts, 0)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testExternalFailureIsSeparateFromLocalAppointmentAndCanRetry() async {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        writer.failure = .unchanged("Calendar failed")
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let failed = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertFalse(failed)
        XCTAssertEqual(repository.appointments.first?.startsAt, value.startsAt)
        XCTAssertEqual(repository.appointments.first?.calendarLink?.errorMessage, "Calendar failed")
        XCTAssertNil(repository.appointments.first?.calendarLink?.operation)
        writer.failure = nil
        let retry = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(retry)
    }

    func testFailedReceiptWriteRetriesReceiptWithoutCreatingAnotherEvent() async {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let writer = AppointmentCalendarDouble()
        writer.afterUpsert = { store.discardsWrites = true }
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let first = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertFalse(first)
        XCTAssertEqual(writer.upserts, 1)
        store.discardsWrites = false
        repository.reload()
        let retry = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(retry)
        XCTAssertEqual(writer.upserts, 1)
        XCTAssertEqual(repository.appointments.first?.calendarLink?.eventIdentifier, "owned-event")
    }

    func testInterruptedUnknownCreateBlocksDuplicateAcrossRelaunchAndRequiresAssertion() async {
        var value = appointment()
        value.calendarLink = AppointmentCalendarLink(operation: AppointmentCalendarOperation(id: UUID(), revision: 1, action: .upsert))
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let result = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertFalse(result)
        XCTAssertEqual(writer.permissionRequests, 0)
        XCTAssertEqual(writer.upserts, 0)
        XCTAssertTrue(coordinator.confirmUncertainCopyRemoved(id: value.id))
        let recovered = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(recovered)
        XCTAssertEqual(writer.upserts, 1)
    }

    func testInterruptedKnownRemovalRetriesRemovalInsteadOfResurrectingEvent() async {
        var value = appointment()
        value.calendarLink = AppointmentCalendarLink(eventIdentifier: "owned-event", acknowledgedRevision: 1,
            operation: AppointmentCalendarOperation(id: UUID(), revision: 1, action: .remove))
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let result = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertTrue(result)
        XCTAssertEqual(writer.upserts, 0)
        XCTAssertEqual(writer.removes, 1)
    }

    func testCompletionFailureRemainsRetryableUntilReceiptRecovery() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let historyID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: historyID))
        store.discardsWrites = true
        XCTAssertFalse(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: historyID))
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        store.discardsWrites = false
        repository.reload()
        XCTAssertTrue(repository.associateAcknowledgedCompletion(appointmentID: value.id, reference: value.reference, historyID: historyID))
        XCTAssertEqual(repository.appointments.first?.status, .completed)
    }

    func testStartedBindingSurvivesRelaunchAndCompletionReconciliation() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let sessionID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: sessionID))
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: sessionID))
        XCTAssertEqual(store.writes, 2)
        XCTAssertFalse(repository.bindStartedSession(appointmentID: value.id, reference: value.reference, sessionID: UUID()))
        let relaunched = WorkoutAppointmentRepository(store: store)
        XCTAssertTrue(relaunched.associateAcknowledgedCompletionForSession(sessionID: UUID()))
        XCTAssertEqual(relaunched.appointments.first?.status, .scheduled)
        XCTAssertTrue(relaunched.associateAcknowledgedCompletionForSession(sessionID: sessionID))
        XCTAssertTrue(relaunched.associateAcknowledgedCompletionForSession(sessionID: sessionID))
        XCTAssertEqual(relaunched.appointments.first?.completedHistoryID, sessionID)
        XCTAssertEqual(store.writes, 3)
    }

    func testStartedWorkoutReferenceCannotBeRetargetedAndBindingIsUnique() {
        let first = appointment()
        let second = appointment(reference: .custom(UUID()))
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [first, second]))
        let sessionID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: first, sessionID: sessionID))
        XCTAssertFalse(repository.bindStartedSession(appointmentID: second.id, reference: second.reference, sessionID: sessionID))
        var edited = first
        edited.reference = .custom(UUID())
        XCTAssertFalse(repository.save(edited, expectedRevision: 2, now: now))
        XCTAssertEqual(repository.appointments.first?.reference, first.reference)
    }

    func testAcknowledgedAbandonmentReleasesBindingWithoutRecordingCompletion() {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let abandonedID = UUID()
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: abandonedID))
        XCTAssertTrue(repository.releaseAcknowledgedAbandonedSession(sessionID: abandonedID))
        XCTAssertTrue(repository.releaseAcknowledgedAbandonedSession(sessionID: abandonedID))
        XCTAssertNil(repository.appointments.first?.startedSessionID)
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        XCTAssertTrue(repository.associateAcknowledgedCompletionForSession(sessionID: abandonedID))
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: UUID()))
    }

    func testPermissionSuspensionRechecksLocalRevisionBeforeExternalWrite() async {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let writer = AppointmentCalendarDouble()
        writer.beforeAccessReturns = { _ = repository.cancel(id: value.id, expectedRevision: value.revision) }
        let coordinator = AppointmentCalendarCoordinator(repository: repository, writer: writer)
        let result = await coordinator.applyCalendarChange(id: value.id, now: now)
        XCTAssertFalse(result)
        XCTAssertEqual(writer.upserts, 0)
        XCTAssertEqual(repository.appointments.first?.status, .cancelled)
    }

    func testFailedBindingDoesNotClaimAStartedAssociationAndCanRetry() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let sessionID = UUID()
        XCTAssertTrue(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: sessionID))
        store.discardsWrites = true
        XCTAssertFalse(repository.bindStartedSession(appointmentID: value.id, reference: value.reference, sessionID: sessionID))
        XCTAssertNil(repository.appointments.first?.startedSessionID)
        store.discardsWrites = false
        repository.reload()
        XCTAssertTrue(prepareAndBind(repository, appointment: value, sessionID: sessionID))
    }

    func testPreparedLaunchSurvivesCrashGapAndOnlyExactActiveAcknowledgmentStartsIt() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let sessionID = UUID()
        XCTAssertTrue(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: sessionID))
        let relaunched = WorkoutAppointmentRepository(store: store)
        XCTAssertNil(relaunched.appointments.first?.startedSessionID)
        XCTAssertNil(relaunched.appointments.first?.completedHistoryID)
        XCTAssertEqual(relaunched.appointments.first?.preparedSessionID, sessionID)
        XCTAssertTrue(relaunched.acknowledgePreparedSessionIfActive(sessionID: UUID()))
        XCTAssertNil(relaunched.appointments.first?.startedSessionID)
        XCTAssertTrue(relaunched.acknowledgePreparedSessionIfActive(sessionID: sessionID))
        XCTAssertEqual(relaunched.appointments.first?.startedSessionID, sessionID)
        XCTAssertNil(relaunched.appointments.first?.preparedSessionID)
    }

    func testPreparedLaunchCanCompleteFromExactAcknowledgedHistoryAcrossCrashGap() {
        let value = appointment()
        let store = AppointmentStoreDouble(values: [value])
        let repository = WorkoutAppointmentRepository(store: store)
        let sessionID = UUID()
        XCTAssertTrue(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: sessionID))
        let relaunched = WorkoutAppointmentRepository(store: store)
        XCTAssertTrue(relaunched.associateAcknowledgedCompletionForSession(sessionID: sessionID))
        XCTAssertEqual(relaunched.appointments.first?.completedHistoryID, sessionID)
        XCTAssertEqual(relaunched.appointments.first?.startedSessionID, sessionID)
        XCTAssertNil(relaunched.appointments.first?.preparedSessionID)
        XCTAssertEqual(store.writes, 2)
    }

    func testOrphanPreparedIntentBlocksAnotherLaunchUntilExplicitClearOrCancel() {
        let value = appointment()
        let repository = WorkoutAppointmentRepository(store: AppointmentStoreDouble(values: [value]))
        let sessionID = UUID()
        XCTAssertTrue(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: sessionID))
        XCTAssertFalse(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: UUID()))
        XCTAssertTrue(repository.clearPreparedSession(appointmentID: value.id, sessionID: sessionID))
        XCTAssertTrue(repository.associateAcknowledgedCompletionForSession(sessionID: sessionID))
        XCTAssertEqual(repository.appointments.first?.status, .scheduled)
        XCTAssertTrue(repository.prepareSessionLaunch(appointmentID: value.id, reference: value.reference, sessionID: UUID()))
        let revision = repository.appointments[0].revision
        XCTAssertTrue(repository.cancel(id: value.id, expectedRevision: revision))
        XCTAssertNil(repository.appointments.first?.preparedSessionID)
        XCTAssertEqual(repository.appointments.first?.status, .cancelled)
    }

    private func prepareAndBind(_ repository: WorkoutAppointmentRepository, appointment: WorkoutAppointment, sessionID: UUID) -> Bool {
        repository.prepareSessionLaunch(appointmentID: appointment.id, reference: appointment.reference, sessionID: sessionID)
            && repository.bindStartedSession(appointmentID: appointment.id, reference: appointment.reference, sessionID: sessionID)
    }

    private func appointment(reference: ScheduledWorkoutReference = .custom(UUID())) -> WorkoutAppointment {
        WorkoutAppointment(reference: reference, title: "My workout", startsAt: now.addingTimeInterval(3_600), timeZoneIdentifier: "Europe/Sofia")
    }
}

private final class AppointmentStoreDouble: WorkoutAppointmentPersisting {
    var values: [WorkoutAppointment]
    var writes = 0
    var discardsWrites = false
    var throwsAfterWrite = false
    var readsFail = false

    init(values: [WorkoutAppointment] = []) { self.values = values }

    func load() throws -> [WorkoutAppointment] {
        if readsFail { throw AppointmentStoreError.unavailable }
        return values
    }

    func save(_ appointments: [WorkoutAppointment]) throws {
        writes += 1
        if !discardsWrites { values = appointments }
        if throwsAfterWrite { throw AppointmentStoreError.unavailable }
    }
}

@MainActor
private final class AppointmentCalendarDouble: AppointmentCalendarWriting {
    var permissionRequests = 0
    var upserts = 0
    var removes = 0
    var grantsAccess = true
    var failure: AppointmentCalendarError?
    var lastIdentifier: String?
    var lastAppointment: WorkoutAppointment?
    var afterUpsert: (() -> Void)?
    var beforeAccessReturns: (() -> Void)?

    func requestAccess() async throws -> Bool {
        permissionRequests += 1
        beforeAccessReturns?()
        return grantsAccess
    }

    func upsert(_ appointment: WorkoutAppointment, eventIdentifier: String?) throws -> String {
        upserts += 1
        lastIdentifier = eventIdentifier
        lastAppointment = appointment
        if let failure { throw failure }
        afterUpsert?()
        return eventIdentifier ?? "owned-event"
    }

    func remove(eventIdentifier: String, ownershipURL: URL) throws {
        removes += 1
        if let failure { throw failure }
    }
}
