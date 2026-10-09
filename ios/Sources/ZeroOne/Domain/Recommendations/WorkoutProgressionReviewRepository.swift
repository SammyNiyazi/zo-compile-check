import Foundation
import Observation

struct WorkoutProgressionReviewSnapshot: Codable, Equatable {
    let version: Int
    let reviews: [WorkoutProgressionReview]

    init(reviews: [WorkoutProgressionReview] = [], version: Int = 1) {
        self.version = version
        self.reviews = reviews
    }

    var isValid: Bool {
        version == 1 && reviews.count <= 10_000 && reviews.allSatisfy(\.isValid)
            && Set(reviews.map(\.id)).count == reviews.count
            && Set(reviews.map { "\($0.sourceSessionID)|\($0.occurrenceID)" }).count == reviews.count
    }
}

enum WorkoutProgressionReviewError: Error, Equatable {
    case unavailable, invalid, changed, sourceChanged, saveNotConfirmed
}

protocol WorkoutProgressionReviewPersisting {
    func load() throws -> WorkoutProgressionReviewSnapshot
    func save(_ value: WorkoutProgressionReviewSnapshot) throws
}

struct UserDefaultsWorkoutProgressionReviewStore: WorkoutProgressionReviewPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "01.workoutProgressionReviews.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> WorkoutProgressionReviewSnapshot {
        guard let stored = defaults.object(forKey: key) else { return .init() }
        guard let data = stored as? Data else { throw WorkoutProgressionReviewError.unavailable }
        let value = try JSONDecoder().decode(WorkoutProgressionReviewSnapshot.self, from: data)
        guard value.isValid else { throw WorkoutProgressionReviewError.unavailable }
        return value
    }

    func save(_ value: WorkoutProgressionReviewSnapshot) throws {
        guard value.isValid else { throw WorkoutProgressionReviewError.invalid }
        _ = try load()
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data, try load() == value else {
            throw WorkoutProgressionReviewError.saveNotConfirmed
        }
    }
}

@MainActor @Observable
final class WorkoutProgressionReviewRepository {
    private(set) var snapshot = WorkoutProgressionReviewSnapshot()
    private(set) var isAvailable = false
    @ObservationIgnored private let store: any WorkoutProgressionReviewPersisting

    init(store: any WorkoutProgressionReviewPersisting = UserDefaultsWorkoutProgressionReviewStore()) {
        self.store = store
        reload()
    }

    @discardableResult func reload() -> Bool {
        do {
            let loaded = try store.load()
            guard loaded.isValid else { throw WorkoutProgressionReviewError.unavailable }
            snapshot = loaded
            isAvailable = true
            return true
        } catch {
            isAvailable = false
            return false
        }
    }

    /// An answer can be recorded without earning an increase. An unknown RIR,
    /// negative answer or unsuitable increment still remains that fact.
    func save(_ review: WorkoutProgressionReview, for plan: ExercisePlan, history: WorkoutHistoryRepository,
              replacing baseline: WorkoutProgressionReviewSnapshot, at now: Date) throws {
        guard isAvailable, now.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkoutProgressionReviewError.unavailable
        }
        guard review.isValid, review.reviewedAt <= now,
              review.planFingerprint == WorkoutProgressionEvidence.planFingerprint(plan),
              review.exerciseID == plan.exerciseID else { throw WorkoutProgressionReviewError.invalid }
        let entries = try history.confirmedEntries()
        let engine = WorkoutProgressionEngine(asOf: now)
        guard let performance = engine.latestPerformance(for: plan, history: entries),
              let source = performance.sourceEntry, source.id == review.sourceSessionID,
              source.executionCompleteness == .confirmedComplete,
              let confirmed = source.executionCompletionConfirmedAt, confirmed <= review.reviewedAt,
              source.completedAt <= now, now.timeIntervalSince(source.completedAt) <= WorkoutProgressionEvidence.maximumAge,
              WorkoutProgressionEvidence.fingerprint(source) == review.sourceFingerprint,
              let occurrence = WorkoutProgressionEvidence.matchingOccurrence(plan: plan, occurrences: performance.occurrences),
              occurrence.id == review.occurrenceID else { throw WorkoutProgressionReviewError.sourceChanged }
        let fresh = try freshSnapshot()
        guard fresh == baseline else { snapshot = fresh; throw WorkoutProgressionReviewError.changed }
        if fresh.reviews.contains(review) { return } // Exact retry never invents a later review.
        let kept = fresh.reviews.filter {
            $0.sourceSessionID != review.sourceSessionID || $0.occurrenceID != review.occurrenceID
        }
        try commit(WorkoutProgressionReviewSnapshot(reviews: kept + [review]))
    }

    func deleteAll(replacing baseline: WorkoutProgressionReviewSnapshot) throws {
        guard isAvailable else { throw WorkoutProgressionReviewError.unavailable }
        let fresh = try freshSnapshot()
        guard fresh == baseline else { snapshot = fresh; throw WorkoutProgressionReviewError.changed }
        try commit(.init())
    }

    private func commit(_ candidate: WorkoutProgressionReviewSnapshot) throws {
        guard candidate.isValid else { throw WorkoutProgressionReviewError.invalid }
        do {
            try store.save(candidate)
            let confirmed = try store.load()
            guard confirmed.isValid, confirmed == candidate else { throw WorkoutProgressionReviewError.saveNotConfirmed }
            snapshot = confirmed
        } catch {
            _ = reload()
            throw error
        }
    }

    private func freshSnapshot() throws -> WorkoutProgressionReviewSnapshot {
        do {
            let fresh = try store.load()
            guard fresh.isValid else { throw WorkoutProgressionReviewError.unavailable }
            return fresh
        } catch {
            isAvailable = false
            throw error
        }
    }
}
