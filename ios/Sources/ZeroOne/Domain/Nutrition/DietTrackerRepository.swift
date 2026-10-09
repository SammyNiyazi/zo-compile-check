import Foundation
import Observation

@MainActor
@Observable
final class DietTrackerRepository {
    enum Availability { case available, unavailable }

    private(set) var snapshot = DietTrackerSnapshot.empty
    private(set) var availability = Availability.unavailable
    private(set) var lastError: DietTrackerError?
    @ObservationIgnored private let store: any DietTrackerPersisting

    init(store: any DietTrackerPersisting = FileDietTrackerStore()) {
        self.store = store
        try? reload()
    }

    func reload() throws {
        do {
            let loaded = try store.load()
            try loaded.validate()
            snapshot = loaded; availability = .available; lastError = nil
        } catch {
            availability = .unavailable; lastError = .storeUnavailable
            throw DietTrackerError.storeUnavailable
        }
    }

    var activeTrackers: [DietTracker] { snapshot.trackers.filter { !$0.isArchived } }
    var archivedTrackers: [DietTracker] { snapshot.trackers.filter(\.isArchived) }

    @discardableResult
    func add(_ draft: DietTrackerDraft, at date: Date = .now) throws -> DietTracker {
        guard draft.original == nil else { throw DietTrackerError.entryChanged }
        let tracker = try draft.validated(id: UUID(), at: date)
        var candidate = snapshot; candidate.trackers.append(tracker)
        try commit(candidate)
        return tracker
    }

    @discardableResult
    func update(_ draft: DietTrackerDraft, at date: Date = .now) throws -> DietTracker {
        guard let old = draft.original, let index = snapshot.trackers.firstIndex(where: { $0.id == old.id }) else {
            throw DietTrackerError.entryNotFound
        }
        guard snapshot.trackers[index] == old else { throw DietTrackerError.entryChanged }
        let tracker = try draft.validated(id: old.id, at: date)
        var candidate = snapshot; candidate.trackers[index] = tracker
        try commit(candidate)
        return tracker
    }

    func setArchived(_ archived: Bool, tracker: DietTracker, at date: Date = .now) throws {
        guard let index = snapshot.trackers.firstIndex(where: { $0.id == tracker.id }) else {
            throw DietTrackerError.entryNotFound
        }
        guard snapshot.trackers[index] == tracker else { throw DietTrackerError.entryChanged }
        if tracker.isArchived == archived { return }
        let replacement = DietTracker(id: tracker.id, revision: UUID(), name: tracker.name, kind: tracker.kind,
            dose: tracker.dose, times: tracker.times, remindMe: tracker.remindMe,
            remindAgainIfNotLogged: tracker.remindAgainIfNotLogged, createdAt: tracker.createdAt,
            updatedAt: date, isArchived: archived)
        var candidate = snapshot; candidate.trackers[index] = replacement
        try commit(candidate)
    }

    /// Explicit deletion removes this tracker and its local logs. Archive retains both.
    func delete(_ tracker: DietTracker) throws {
        guard snapshot.trackers.contains(where: { $0.id == tracker.id }) else { throw DietTrackerError.entryNotFound }
        guard snapshot.trackers.contains(tracker) else { throw DietTrackerError.entryChanged }
        var candidate = snapshot
        candidate.trackers.removeAll { $0.id == tracker.id }
        candidate.completions.removeAll { $0.trackerID == tracker.id }
        try commit(candidate)
    }

    func checklist(for day: DietTrackerDay) throws -> [DietTrackerOccurrence] {
        guard availability == .available else { throw DietTrackerError.storeUnavailable }
        guard day.isValid else { throw DietTrackerError.invalidDay }
        return activeTrackers.flatMap { tracker in
            let slots: [DietTrackerTime?] = tracker.times.isEmpty ? [nil] : tracker.times.map { Optional($0) }
            return slots.map { time in
                // Project actual logging instants into the requested civil day.
                // Travel preserves original timezone metadata instead of replaying a dose.
                let logs = snapshot.completions.filter {
                    $0.trackerID == tracker.id && $0.scheduledTime?.id == time?.id && day.contains($0.loggedAt)
                }.sorted { $0.loggedAt > $1.loggedAt }
                return DietTrackerOccurrence(tracker: tracker, time: time, day: day, completions: logs)
            }
        }
    }

    @discardableResult
    func log(_ occurrence: DietTrackerOccurrence, at date: Date = .now) throws -> DietTrackerCompletion {
        guard occurrence.day.isValid, occurrence.day.contains(date) else { throw DietTrackerError.outsideDay }
        guard let tracker = snapshot.trackers.first(where: { $0.id == occurrence.tracker.id }) else {
            throw DietTrackerError.entryNotFound
        }
        guard tracker == occurrence.tracker else { throw DietTrackerError.entryChanged }
        guard !tracker.isArchived else { throw DietTrackerError.archived }
        guard (occurrence.time.map { tracker.times.contains($0) } ?? tracker.times.isEmpty) else {
            throw DietTrackerError.entryChanged
        }
        if let existing = try checklist(for: occurrence.day).first(where: { $0.id == occurrence.id })?.completions.first {
            return existing // repeated taps do not add another claimed occurrence
        }
        let log = DietTrackerCompletion(id: UUID(), trackerID: tracker.id, trackerRevision: tracker.revision,
            name: tracker.name, kind: tracker.kind, dose: tracker.dose, scheduledTime: occurrence.time,
            day: occurrence.day, loggedAt: date)
        var candidate = snapshot; candidate.completions.append(log)
        try commit(candidate)
        return log
    }

    /// Undo identifies the actual recorded log; it never clears all scheduled doses.
    func undo(_ completion: DietTrackerCompletion) throws {
        guard snapshot.completions.contains(where: { $0.id == completion.id }) else {
            throw DietTrackerError.entryNotFound
        }
        guard snapshot.completions.contains(completion) else { throw DietTrackerError.entryChanged }
        var candidate = snapshot; candidate.completions.removeAll { $0.id == completion.id }
        try commit(candidate)
    }

    private func commit(_ candidate: DietTrackerSnapshot) throws {
        guard availability == .available else { throw DietTrackerError.storeUnavailable }
        try candidate.validate()
        do {
            try store.save(candidate, replacing: snapshot)
            let confirmed = try store.load()
            try confirmed.validate()
            guard confirmed == candidate else { throw DietTrackerError.saveFailed }
            snapshot = confirmed; lastError = nil
        } catch {
            let failure = (error as? DietTrackerError) ?? .saveFailed
            lastError = failure
            if failure == .storeUnavailable || failure == .invalidFile { availability = .unavailable }
            throw failure
        }
    }
}
