import Foundation

/// Counts of recorded countdown coverage, never seconds of physical recovery.
struct WorkoutRestTimerWorkload: Equatable, Sendable {
    var unknownSetCount = 0
    var notScheduledSetCount = 0
    var completeObservationCount = 0
    var partialObservationCount = 0

    mutating func include(_ set: CompletedSet, before nextRecordedBoundary: Date) {
        guard let observation = set.restTimerObservation else { unknownSetCount += 1; return }
        if observation.hasUnobservedGap || !observation.isClosed
            || observation.events.contains(where: { $0.observedAt > nextRecordedBoundary }) { partialObservationCount += 1 }
        else if observation.events.first?.kind == .notScheduled { notScheduledSetCount += 1 }
        else { completeObservationCount += 1 }
    }
}

/// An incoming countdown belongs to the previously performed set. Its exact
/// relative transitions can qualify a comparison, not establish equal recovery.
enum WorkoutIncomingTimerContext: Equatable, Sendable {
    case sessionStart, unknown, unavailable
    case observed([WorkoutRelativeTimerTransition])
}

struct WorkoutRelativeTimerTransition: Equatable, Sendable {
    let kind: WorkoutRestTimerEvent.Kind
    let observedSeconds: TimeInterval
    let deadlineSeconds: TimeInterval?
    let remainingSeconds: TimeInterval?
}

enum WorkoutRestTimerEvidence {
    static let policyVersion = "incoming-countdown-context-v1"

    static func validStoredObservation(for set: CompletedSet, finishedAt: Date) -> Bool {
        guard let observation = set.restTimerObservation else { return true }
        return observation.isClosed && observation.isValid(for: set.id, completedAt: set.completedAt)
            && observation.events.allSatisfy { $0.observedAt <= finishedAt }
    }

    /// Nil rejects unsupported record order or occurrence identity. Unavailable
    /// is retained as a barrier rather than relabelled as legacy unknown.
    static func incomingContexts(in entry: WorkoutHistoryEntry, occurrenceID: UUID) -> [WorkoutIncomingTimerContext]? {
        guard let exercises = entry.exercises, exercises.count <= 500,
              exercises.filter({ $0.id == occurrenceID }).count == 1 else { return nil }
        var total = 0
        for exercise in exercises {
            guard exercise.completedSets.count <= 5_000 - total else { return nil }
            total += exercise.completedSets.count
        }
        var previous: CompletedSet?
        var result: [WorkoutIncomingTimerContext] = []
        for exercise in exercises {
            for set in exercise.completedSets {
                guard set.completedAt.timeIntervalSinceReferenceDate.isFinite,
                      set.completedAt <= entry.completedAt,
                      previous.map({ $0.completedAt <= set.completedAt }) ?? true else { return nil }
                if exercise.id == occurrenceID {
                    result.append(previous.map { context(after: $0, before: set, finishedAt: entry.completedAt) } ?? .sessionStart)
                }
                previous = set
            }
        }
        return result
    }

    static func permitsComparison(_ contexts: [WorkoutIncomingTimerContext]) -> Bool {
        !contexts.contains(.unavailable)
    }

    private static func context(after previous: CompletedSet, before next: CompletedSet,
                                finishedAt: Date) -> WorkoutIncomingTimerContext {
        guard let observation = previous.restTimerObservation else { return .unknown }
        guard validStoredObservation(for: previous, finishedAt: finishedAt), !observation.hasUnobservedGap,
              observation.events.allSatisfy({ $0.observedAt <= next.completedAt }) else { return .unavailable }
        let origin = previous.completedAt
        return .observed(observation.events.map {
            .init(kind: $0.kind, observedSeconds: $0.observedAt.timeIntervalSince(origin),
                  deadlineSeconds: $0.deadline.map { $0.timeIntervalSince(origin) }, remainingSeconds: $0.remainingSeconds)
        })
    }
}
