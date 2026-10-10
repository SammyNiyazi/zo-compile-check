import Foundation
import Observation

/// UI actions use the root-owned repository. No optimistic tick/save, medical
/// prescription, notification scheduler or permission state lives in this model.
@MainActor
@Observable
final class DietTrackerFeatureModel {
    let repository: DietTrackerRepository
    private(set) var day: DietTrackerDay?
    private(set) var observationEpoch = 0
    private(set) var errorMessage: String?
    private(set) var requiresSavedDataReview = false
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: () -> TimeZone
    /// Proof 23 reminders; the root supplies the real scheduler, tests leave it nil.
    @ObservationIgnored private let reminders: DietTrackerReminderScheduling?

    init(repository: DietTrackerRepository, now: @escaping () -> Date = { .now },
         timeZone: @escaping () -> TimeZone = { .current },
         reminders: DietTrackerReminderScheduling? = nil) {
        self.repository = repository
        self.now = now
        self.timeZone = timeZone
        self.reminders = reminders
        refresh(reloadStorage: false)
    }

    private func rescheduleReminders() {
        guard repository.availability == .available else { return }
        reminders?.reconcile(repository.snapshot, now: now())
    }

    var checklist: [DietTrackerOccurrence]? {
        guard let day, repository.availability == .available else { return nil }
        return try? repository.checklist(for: day)
    }

    func refresh(reloadStorage: Bool = true) {
        do {
            let currentDay = try DietTrackerDay(containing: now(), timeZone: timeZone())
            if reloadStorage { try repository.reload() }
            day = currentDay
            observationEpoch += 1
            // A successful read does not unlock an uncertain editor save.
            if !requiresSavedDataReview { errorMessage = nil }
            rescheduleReminders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginEditor() {
        requiresSavedDataReview = false
        errorMessage = nil
    }

    @discardableResult
    func save(_ draft: DietTrackerDraft) -> Bool {
        guard !requiresSavedDataReview else { return false }
        let baseline = repository.snapshot
        do {
            if draft.original == nil { _ = try repository.add(draft, at: now()) }
            else { _ = try repository.update(draft, at: now()) }
            errorMessage = nil
            rescheduleReminders()
            return true
        } catch {
            let failure = error as? DietTrackerError
            errorMessage = error.localizedDescription
            if failure == .saveFailed || failure == .storeChanged || failure == .storeUnavailable || failure == .invalidFile {
                do {
                    try repository.reload()
                    if repository.snapshot != baseline {
                        // The repository may have written before acknowledgement failed.
                        // Its add API creates identity internally; never guess ownership
                        // from matching names, and never create a second tracker blindly.
                        requiresSavedDataReview = true
                        errorMessage = "Saved tracker data changed. Review the list before saving again."
                    }
                } catch {
                    requiresSavedDataReview = true
                    errorMessage = "The save could not be confirmed. Review saved trackers when storage is readable."
                }
            } else if failure == .entryChanged || failure == .entryNotFound {
                requiresSavedDataReview = true
            }
            return false
        }
    }

    @discardableResult
    func toggle(_ occurrence: DietTrackerOccurrence) -> Bool {
        do {
            let date = now()
            let currentDay = try DietTrackerDay(containing: date, timeZone: timeZone())
            guard currentDay == occurrence.day else {
                day = currentDay
                observationEpoch += 1
                throw DietTrackerError.outsideDay
            }
            if let completion = occurrence.completions.first {
                // Exactly this recorded log; other times and older logs stay intact.
                try repository.undo(completion)
            } else {
                _ = try repository.log(occurrence, at: date)
            }
            errorMessage = nil
            rescheduleReminders()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setArchived(_ archived: Bool, tracker: DietTracker) -> Bool {
        do {
            try repository.setArchived(archived, tracker: tracker, at: now())
            errorMessage = nil
            rescheduleReminders()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
