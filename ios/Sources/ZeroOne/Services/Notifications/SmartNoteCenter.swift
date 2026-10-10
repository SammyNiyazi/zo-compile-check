import Foundation
import Observation
import UserNotifications

struct SmartNoteSnapshot: Codable {
    var preferences = SmartNotePreferences()
    var candidates: [SmartNoteCandidate] = []
    var records: [SmartNoteRecord] = []
    var handledActions: Set<String> = []
    var loadChoiceUndo: WorkoutLoadChoiceUndo? = nil

    /// Opting out is a preference change, not a plan action. Resolve its kind
    /// only from local evidence, including a receipt for an expired revision.
    func stopping(requestID: String, at date: Date) -> (snapshot: Self, kind: SmartNoteKind)? {
        let key = requestID + ".NOTE_STOP"
        guard !handledActions.contains(key) else { return nil }
        let matchingCandidates = candidates.filter { $0.requestID == requestID }
        let matchingRecords = records.filter { $0.requestID == requestID }
        let kinds = Set(matchingCandidates.map(\.kind) + matchingRecords.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return nil }
        var next = self
        next.preferences.enabledKinds.remove(kind)
        next.handledActions.insert(key)
        if next.handledActions.count > 500 { next.handledActions = [key] }
        if let index = next.records.firstIndex(where: { $0.requestID == requestID }) {
            next.records[index].outcome = .stopped
            next.records[index].reason = "Turned off by you."
        } else if let note = matchingCandidates.first {
            next.records.append(.init(requestID: requestID, candidateID: note.id,
                kind: kind, date: date, outcome: .stopped, reason: "Turned off by you."))
        }
        return (next, kind)
    }
}

/// Retains a confirmed canonical action's undo metadata while the separate
/// notification store is temporarily unwritable. Never implies disk durability.
struct SmartNoteUndoJournal {
    private(set) var hasPendingChange = false
    private(set) var pendingReceipt: WorkoutLoadChoiceUndo?

    mutating func stage(_ receipt: WorkoutLoadChoiceUndo?) {
        pendingReceipt = receipt
        hasPendingChange = true
    }

    func applying(to snapshot: SmartNoteSnapshot) -> SmartNoteSnapshot {
        var updated = snapshot
        if hasPendingChange { updated.loadChoiceUndo = pendingReceipt }
        return updated
    }

    mutating func confirmed() {
        hasPendingChange = false
        pendingReceipt = nil
    }
}

@MainActor
@Observable
final class SmartNoteCenter {
    private(set) var snapshot = SmartNoteSnapshot()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var decisions: [SmartNoteDecision] = []
    private(set) var errorMessage: String?
    private(set) var storageAvailable = true
    private(set) var isUpdating = false
    var routeCandidateID: String?
    var opensSettings = false
    var actionMessage: String?
    // Fail closed until the host restores its active/recovering workout state.
    private var workoutActive = true
    private var progressionAllowed = false
    private var needsReconcile = false
    private var undoJournal = SmartNoteUndoJournal()
    var loadChoiceUndo: WorkoutLoadChoiceUndo? {
        undoJournal.hasPendingChange ? undoJournal.pendingReceipt : snapshot.loadChoiceUndo
    }
    // Retain observed, app-owned removals if protected storage temporarily fails.
    // This is not delivery evidence and never survives as a fabricated receipt.
    @ObservationIgnored private var withdrawalsAwaitingPersistence: Set<String> = []
    private let center: UNUserNotificationCenter
    private let fileURL: URL
    @ObservationIgnored private var delegate: SmartNoteDelegate?
    @ObservationIgnored private var progressChoice: (@MainActor (SmartNoteCandidate, WorkoutLoadChoiceSelection) -> SmartNoteProgressActionResult)?
    @ObservationIgnored private var progressUndo: (@MainActor (WorkoutLoadChoiceUndo) -> Bool)?
    private static let progressChoiceCategory = "01.note.progress.loadChoice"

    init(center: UNUserNotificationCenter = .current(), fileURL: URL? = nil) {
        self.center = center
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("01-notes", isDirectory: true).appendingPathComponent("notes-v1.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do { snapshot = try JSONDecoder().decode(SmartNoteSnapshot.self, from: Data(contentsOf: self.fileURL)) }
            catch { storageAvailable = false; errorMessage = "Your note settings couldn't be read. Existing data is preserved. Try again after unlocking your iPhone." }
        }
    }

    var preferences: SmartNotePreferences { snapshot.preferences }
    var canDeliver: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }

    func retry() async {
        if !storageAvailable {
            do {
                snapshot = try JSONDecoder().decode(SmartNoteSnapshot.self, from: Data(contentsOf: fileURL))
                storageAvailable = true
                errorMessage = nil
            } catch { return }
        }
        await reconcile()
    }

    /// A one-off reminder chosen by the user. It does not rewrite their programme.
    func addWorkoutReminder(programme: WorkoutProgramme, sessionID: String, start: Date, windowEnd: Date) async -> Bool {
        guard let session = programme.sessions.first(where: { $0.id == sessionID }),
              !session.exercisePlans.isEmpty,
              start.timeIntervalSinceReferenceDate.isFinite,
              windowEnd.timeIntervalSinceReferenceDate.isFinite,
              start.timeIntervalSinceNow > 45 * 60,
              windowEnd.timeIntervalSince(start).isFinite,
              let estimate = WorkoutTimeEstimator().estimate(for: programme.makeSession(sessionID: sessionID)),
              windowEnd.timeIntervalSince(start) >= Double(estimate.maximumMinutes * 60) else {
            errorMessage = "Choose a training time at least 45 minutes ahead, with room for the full session."
            return false
        }
        let occurrence = UUID()
        let time = start.formatted(date: .omitted, time: .shortened)
        let note = SmartNoteCandidate(
            id: occurrence.uuidString, occurrenceID: occurrence, revision: 1, kind: .fits,
            title: "\(session.title) at \(time)",
            body: "Estimated up to \(estimate.maximumMinutes) min. Your training time runs to \(windowEnd.formatted(date: .omitted, time: .shortened)). Actual time can vary.",
            directTitle: "\(time): \(session.title)", directBody: "Your chosen training time. Open your plan when you're ready.",
            reasons: ["You chose this workout and training time.", "The estimate includes warm-up, working sets, authored rest and transitions. Actual time can vary."],
            unknowns: ["Whether you're free. Calendar isn't connected to these notes.", "How recovered you are. This reminder makes no recovery claim."],
            deliveryDate: start.addingTimeInterval(-45 * 60), expiresAt: start,
            isRestDay: false, isCurrent: true, isFreshEvent: true,
            programmeID: programme.id.rawValue, sessionID: session.id
        )
        var next = snapshot
        next.candidates.append(note)
        guard persist(next) else { return false }
        await reconcile()
        return errorMessage == nil
    }

    func cancelReminder(_ id: String) async {
        var next = snapshot
        next.candidates.removeAll { $0.id == id }
        guard persist(next) else { return }
        await reconcile()
    }

    /// Install once at app initialization and retain this owner for the app lifetime.
    /// If another notification delegate is introduced, forward these methods from it.
    func install(
        workoutActive: Bool,
        progressionAllowed: Bool = false,
        progressChoice: (@MainActor (SmartNoteCandidate, WorkoutLoadChoiceSelection) -> SmartNoteProgressActionResult)? = nil,
        progressUndo: (@MainActor (WorkoutLoadChoiceUndo) -> Bool)? = nil
    ) async {
        self.progressChoice = progressChoice
        self.progressUndo = progressUndo
        self.progressionAllowed = progressionAllowed
        guard delegate == nil else { return }
        self.workoutActive = workoutActive
        let delegate = SmartNoteDelegate(owner: self)
        self.delegate = delegate
        center.delegate = delegate
        let existing = await center.notificationCategories()
        let categories = SmartNoteKind.allCases.flatMap { kind in
            [false, true].map { snoozed in
                var actions = [UNNotificationAction(identifier: "NOTE_OPEN", title: "Review options", options: [.foreground])]
                if !snoozed {
                    actions.append(UNNotificationAction(identifier: "NOTE_SNOOZE", title: "Remind me in 30 minutes", options: [.authenticationRequired]))
                }
                actions.append(UNNotificationAction(identifier: "NOTE_STOP", title: "Stop these notes", options: [.authenticationRequired]))
                return UNNotificationCategory(
                    identifier: Self.category(kind, snoozed: snoozed), actions: actions,
                    intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "A note from 01",
                    options: [.customDismissAction]
                )
            }
        }
        let progressActions = UNNotificationCategory(
            identifier: Self.progressChoiceCategory,
            actions: [
                UNNotificationAction(identifier: "NOTE_LOAD_NEXT", title: "Use suggested load", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "NOTE_LOAD_KEEP", title: "Keep previous load", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "NOTE_OPEN", title: "Review the saved sets", options: [.foreground])
            ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "A note from 01",
            options: [.customDismissAction]
        )
        center.setNotificationCategories(existing.union(Set(categories)).union([progressActions]))
        await reconcile()
    }

    func enable(quietly: Bool) async {
        guard storageAvailable else { return }
        do {
            let options: UNAuthorizationOptions = quietly
                ? [.alert, .sound, .provisional, .providesAppNotificationSettings]
                : [.alert, .sound, .providesAppNotificationSettings]
            _ = try await center.requestAuthorization(options: options)
            var next = snapshot
            next.preferences.enabled = true
            guard persist(next) else { return }
            await reconcile()
        } catch { errorMessage = "iPhone notification permission couldn't be requested. Try again in a moment." }
    }

    func updatePreferences(_ change: (inout SmartNotePreferences) -> Void) async {
        var next = snapshot
        change(&next.preferences)
        guard persist(next) else { return }
        await reconcile()
    }

    /// Host replaces the complete current candidate set after acknowledged plan/history
    /// changes. A completed/cancelled occurrence must be removed or marked not current.
    func replaceCandidates(_ candidates: [SmartNoteCandidate], workoutActive: Bool) async {
        self.workoutActive = workoutActive
        var next = snapshot
        let oldCandidates = next.candidates
        var seen: Set<String> = []
        next.candidates = candidates.filter { seen.insert($0.id).inserted }.map { candidate in
            // Preserve an explicit snooze when the host refreshes the same plan revision.
            if let existing = oldCandidates.first(where: { $0.id == candidate.id && $0.revision == candidate.revision && $0.wasSnoozed }) {
                var refreshed = candidate
                refreshed.wasSnoozed = true
                refreshed.snoozedUntil = existing.snoozedUntil
                return refreshed
            }
            return candidate
        }
        guard persist(next) else { await removeOwnedRequests(); return }
        await reconcile()
    }

    func foreground(workoutActive: Bool, progressionAllowed: Bool? = nil) async {
        self.workoutActive = workoutActive
        if let progressionAllowed { self.progressionAllowed = progressionAllowed }
        await reconcile()
    }

    func updateProgressionAllowed(_ allowed: Bool) async {
        progressionAllowed = allowed
        await reconcile()
    }

    /// Call only after the workout completion has been acknowledged by History.
    /// Suppress all training prompts for that local day, even if a different session
    /// was completed. This does not equate a planned workout with recorded performance.
    func trainingCompleted(at date: Date, calendar: Calendar = .current) async {
        var next = snapshot
        next.candidates.removeAll {
            !$0.kind.isPassive && calendar.isDate($0.expiresAt, inSameDayAs: date)
        }
        guard persist(next) else { await removeOwnedRequests(); return }
        await reconcile()
    }

    func reconcile() async {
        needsReconcile = true
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        while needsReconcile {
            needsReconcile = false
            authorization = await center.notificationSettings().authorizationStatus
            guard storageAvailable else { await removeOwnedRequests(); return }
            let now = Date()
            let delivered = await center.deliveredNotifications()
            var next = snapshot
            for notification in delivered where notification.request.identifier.hasPrefix("01.note.") {
                if let index = next.records.firstIndex(where: { $0.requestID == notification.request.identifier && $0.outcome == .scheduled }) {
                    next.records[index].outcome = .delivered
                    next.records[index].reason = "Reported in Notification Center."
                }
            }
            next.records.removeAll { $0.date < now.addingTimeInterval(-14 * 86400) }
            next.records = SmartNoteRules.recordingWithdrawal(records: next.records,
                removedPendingIDs: withdrawalsAwaitingPersistence, at: now)
            guard persist(next) else { await removeOwnedRequests(); return }
            withdrawalsAwaitingPersistence.removeAll()
            decisions = SmartNoteRules.decisions(candidates: snapshot.candidates, preferences: preferences,
                records: snapshot.records, authorized: canDeliver, workoutActive: workoutActive, now: now,
                progressionAllowed: progressionAllowed)
            let desired = decisions.filter { $0.deliveryDate != nil }
            let desiredIDs = Set(desired.map { $0.candidate.requestID })
            let pending = await center.pendingNotificationRequests()
            if needsReconcile { continue }
            let obsolete = pending.filter { $0.identifier.hasPrefix("01.note.") && !desiredIDs.contains($0.identifier) }.map(\.identifier)
            withdrawalsAwaitingPersistence.formUnion(obsolete)
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            let withdrawalRecords = SmartNoteRules.recordingWithdrawal(
                records: snapshot.records, removedPendingIDs: Set(obsolete), at: Date()
            )
            let releasedReservation = withdrawalRecords != snapshot.records
            if releasedReservation {
                var withdrawn = snapshot
                withdrawn.records = withdrawalRecords
                guard persist(withdrawn) else { await removeOwnedRequests(); return }
            }
            withdrawalsAwaitingPersistence.subtract(obsolete)
            let validIDs = Set(snapshot.candidates.filter {
                $0.isCurrent && $0.expiresAt > now && preferences.enabledKinds.contains($0.kind)
                    && preferences.enabled && !workoutActive && (progressionAllowed || $0.kind != .progress)
            }.map(\.requestID))
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
                $0.request.identifier.hasPrefix("01.note.") && !validIDs.contains($0.request.identifier)
            }.map { $0.request.identifier })
            // A removed future reservation must no longer consume the budget
            // or block the new revision. Recompute once against the updated ledger.
            if releasedReservation { needsReconcile = true }
            if needsReconcile { continue }
            for decision in decisions {
                let note = decision.candidate
                guard let date = decision.deliveryDate else {
                    record(note, date: now, outcome: .held, reason: decision.reason, preserveDelivery: true)
                    continue
                }
                // An accepted request which is no longer pending is not rescheduled;
                // it may already have been delivered and cleared outside the app.
                guard SmartNoteRules.maySubmit(requestID: note.requestID, records: snapshot.records,
                    pendingIDs: Set(pending.map(\.identifier))) else { continue }
                do {
                    try await center.add(request(note, at: date))
                    if needsReconcile { break }
                    record(note, date: date, outcome: .scheduled, reason: "Scheduled on this iPhone. Delivery depends on iOS and Focus.")
                    if errorMessage != nil {
                        withdrawalsAwaitingPersistence.insert(note.requestID)
                        center.removePendingNotificationRequests(withIdentifiers: [note.requestID])
                        break
                    }
                } catch { record(note, date: now, outcome: .failed, reason: "iPhone couldn't schedule this note. Try again.") }
            }
        }
    }

    func handle(requestID: String, action: String) async {
        let key = requestID + "." + action
        guard storageAvailable, !snapshot.handledActions.contains(key) else { return }
        if action == "NOTE_STOP" {
            guard let change = snapshot.stopping(requestID: requestID, at: Date()) else {
                actionMessage = "This note couldn't be identified. You can turn notes off in notification settings."
                return
            }
            guard persist(change.snapshot) else {
                actionMessage = "Couldn't confirm that these notes are off. Try again in notification settings."
                return
            }
            actionMessage = "\(change.kind.title) notes are off. Your plan is unchanged."
            center.removePendingNotificationRequests(withIdentifiers: [requestID])
            center.removeDeliveredNotifications(withIdentifiers: [requestID])
            await reconcile()
            return
        }
        guard ["NOTE_OPEN", "NOTE_SNOOZE", "NOTE_LOAD_NEXT", "NOTE_LOAD_KEEP", UNNotificationDefaultActionIdentifier,
               UNNotificationDismissActionIdentifier].contains(action) else {
            actionMessage = "This action isn't available. Nothing changed."
            return
        }
        guard let note = snapshot.candidates.first(where: { $0.requestID == requestID }),
              note.isCurrent, note.expiresAt > Date(), !workoutActive else {
            actionMessage = "This note is out of date. Nothing changed."
            return
        }
        if action == "NOTE_LOAD_NEXT" || action == "NOTE_LOAD_KEEP" {
            guard let progressChoice else {
                actionMessage = "Open 01 to review this load choice. Nothing changed."
                return
            }
            let selection: WorkoutLoadChoiceSelection = action == "NOTE_LOAD_NEXT" ? .tryNext : .repeatPrevious
            switch progressChoice(note, selection) {
            case .policyHold:
                actionMessage = "Review your recovery and fuelling before planning a higher load. Nothing changed."
                return
            case .workoutActive:
                actionMessage = "Finish your current workout before choosing the next load. Nothing changed."
                return
            case .stale:
                actionMessage = "This load suggestion changed. Open Progress to review the latest saved sets."
                return
            case .unavailable:
                actionMessage = "The load choice couldn't be confirmed saved. Unlock your iPhone and try again."
                return
            case let .saved(load, undo):
                var next = snapshot
                if let undo { undoJournal.stage(undo) }
                next.handledActions.insert(key)
                if next.handledActions.count > 500 { next.handledActions = [key] }
                next.preferences.consecutiveDismissals = 0
                next.candidates.removeAll { $0.id == note.id }
                if let index = next.records.firstIndex(where: { $0.requestID == requestID }) {
                    next.records[index].outcome = .opened
                    next.records[index].reason = "Your next-load choice was saved."
                } else {
                    next.records.append(.init(requestID: requestID, candidateID: note.id, kind: note.kind,
                        date: Date(), outcome: .opened, reason: "Your next-load choice was saved."))
                }
                // The canonical choice has already been confirmed. If this receipt
                // fails, retry is idempotent through that choice, not another write.
                let receiptSaved = persist(next)
                actionMessage = "\(load.displayText) saved for next time. You can change it in Progress."
                    + (receiptSaved ? "" : " The notification receipt couldn't be saved.")
                center.removePendingNotificationRequests(withIdentifiers: [requestID])
                center.removeDeliveredNotifications(withIdentifiers: [requestID])
                await reconcile()
                return
            }
        }
        var next = snapshot
        next.handledActions.insert(key)
        // Bounded local receipts; occurrence IDs must never be reused by the host.
        if next.handledActions.count > 500 { next.handledActions = [key] }
        if action == UNNotificationDismissActionIdentifier {
            next.preferences.consecutiveDismissals += 1
        } else if action == "NOTE_SNOOZE" {
            let date = Date().addingTimeInterval(30 * 60)
            guard !note.wasSnoozed, date < note.expiresAt,
                  let index = next.candidates.firstIndex(where: { $0.id == note.id }) else {
                actionMessage = "There isn't enough time for another reminder. Nothing changed."
                return
            }
            next.candidates[index].wasSnoozed = true
            next.candidates[index].snoozedUntil = date
            next.preferences.consecutiveDismissals = 0
        } else {
            next.preferences.consecutiveDismissals = 0
        }
        guard persist(next) else { return }
        switch action {
        case "NOTE_SNOOZE": actionMessage = "One more reminder requested. Your quiet hours and limits still apply."
        case UNNotificationDismissActionIdentifier:
            record(note, date: Date(), outcome: .cleared, reason: "Cleared without acting.")
        default:
            routeCandidateID = note.id
            record(note, date: Date(), outcome: .opened, reason: "Opened to review options.")
        }
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        await reconcile()
    }

    func undoLastLoadChoice() async {
        guard storageAvailable, let receipt = loadChoiceUndo, let progressUndo else { return }
        guard progressUndo(receipt) else {
            actionMessage = "Couldn't undo this choice. A workout or a newer choice may have changed it, or storage is unavailable. Review Progress."
            return
        }
        var next = snapshot
        next.loadChoiceUndo = nil
        undoJournal.stage(nil)
        let receiptSaved = persist(next)
        actionMessage = "Undone. Your previous next-load choice is restored. Recorded sets are unchanged."
            + (receiptSaved ? "" : " The notification receipt couldn't be cleared.")
        // The handled note stays handled. Undo never generates another notification.
        await reconcile()
    }

    func dismissLoadChoiceUndo() {
        var next = snapshot
        next.loadChoiceUndo = nil
        undoJournal.stage(nil)
        _ = persist(next)
    }

    private func request(_ note: SmartNoteCandidate, at date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let direct = preferences.directVoice && note.kind != .missed
        content.title = preferences.showDetails ? (direct ? note.directTitle ?? note.title : note.title) : "01"
        content.body = preferences.showDetails ? (direct ? note.directBody ?? note.body : note.body) : "A note from 01. Open to review your options."
        // With private notification copy, the person cannot see which loads they
        // would be accepting. Keep Review options instead of a blind load change.
        content.categoryIdentifier = preferences.showDetails && note.kind == .progress
            && note.progressEvidence != nil && progressChoice != nil
            ? Self.progressChoiceCategory : Self.category(note.kind, snoozed: note.wasSnoozed)
        content.threadIdentifier = note.kind == .progress ? "01.progress" : "01.plan"
        content.interruptionLevel = note.kind.isPassive ? .passive : .active
        if !note.kind.isPassive { content.sound = .default }
        // IDs only: health observations and reasons never go into the OS payload.
        content.userInfo = ["noteID": note.id, "revision": note.revision]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: note.requestID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    private static func category(_ kind: SmartNoteKind, snoozed: Bool) -> String {
        "01.note.\(kind.rawValue)\(snoozed ? ".snoozed" : "")"
    }

    private func record(_ note: SmartNoteCandidate, date: Date, outcome: SmartNoteRecord.Outcome, reason: String, preserveDelivery: Bool = false) {
        var next = snapshot
        if let index = next.records.firstIndex(where: { $0.requestID == note.requestID }) {
            if preserveDelivery && [.scheduled, .delivered, .opened, .cleared, .stopped].contains(next.records[index].outcome) { return }
            next.records[index].outcome = outcome
            next.records[index].reason = reason
            // Preserve original reservation time for weekly/daily limits after actions.
            if outcome == .scheduled { next.records[index].date = date }
        } else {
            next.records.append(.init(requestID: note.requestID, candidateID: note.id, kind: note.kind, date: date, outcome: outcome, reason: reason))
        }
        _ = persist(next)
    }

    @discardableResult private func persist(_ next: SmartNoteSnapshot) -> Bool {
        guard storageAvailable else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let acknowledged = undoJournal.applying(to: next)
            let data = try JSONEncoder().encode(acknowledged)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            guard try Data(contentsOf: fileURL) == data else { throw CocoaError(.fileWriteUnknown) }
            snapshot = acknowledged
            undoJournal.confirmed()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "That change couldn't be confirmed saved. Try again after unlocking your iPhone."
            return false
        }
    }

    private func removeOwnedRequests() async {
        let pending = await center.pendingNotificationRequests()
        let owned = pending.filter { $0.identifier.hasPrefix("01.note.") }.map(\.identifier)
        withdrawalsAwaitingPersistence.formUnion(owned)
        center.removePendingNotificationRequests(withIdentifiers: owned)
    }
}

/// Extract only immutable IDs before crossing from UserNotifications to MainActor.
private final class SmartNoteDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let owner: SmartNoteCenter
    init(owner: SmartNoteCenter) { self.owner = owner }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [] // Suggestions stay in-app; never interrupt the foreground workout.
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        guard id.hasPrefix("01.note.") else { return }
        await owner.handle(requestID: id, action: action)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        Task { @MainActor [owner] in owner.opensSettings = true }
    }
}
