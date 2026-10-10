import ActivityKit
import Foundation

struct WorkoutActivityProjection: Equatable {
    let sessionID: UUID
    let workoutTitle: String
    let state: WorkoutActivityAttributes.ContentState

    var staleDate: Date? {
        state.phase == .rest ? state.restEndsAt : nil
    }

    /// Apply to the exact retained projection before presentation overrides.
    /// Pure qualification: reading failure clears display metadata, never mutates the owner.
    @MainActor
    func usingConfirmedElapsed(from owner: WorkoutViewModel,
                               clock: WorkoutElapsedClock = .continuous) -> Self {
        var content = state
        content.frozenElapsed = nil
        let cleared = Self(sessionID: sessionID, workoutTitle: workoutTitle, state: content)
        let session = owner.session
        let paused = owner.isPaused
        guard owner.persistedActivity == cleared, session.id == sessionID,
              owner.persistenceErrorMessage == nil, !owner.isCompletionSaved,
              let evidence = owner.confirmedElapsedEvidence,
              evidence.matches(sessionID: sessionID, isPaused: paused, isComplete: session.isComplete) else { return cleared }
        let transportState: WorkoutActivityFrozenElapsed.State
        switch evidence.state {
        case .paused:
            guard content.phase == .paused else { return cleared }
            transportState = .paused
        case .stopped:
            guard content.phase == .readyToFinish || content.phase == .saving else { return cleared }
            transportState = .stopped
        case .running:
            // A Date timer cannot prove continuity with this process's ContinuousClock.
            return cleared
        }
        let reading = clock.read()
        guard owner.session == session, owner.isPaused == paused,
              owner.persistedActivity == cleared, owner.confirmedElapsedEvidence == evidence,
              owner.persistenceErrorMessage == nil, !owner.isCompletionSaved,
              let seconds = evidence.elapsed(at: reading) else { return cleared }
        let frozen = WorkoutActivityFrozenElapsed(version: 1, seconds: seconds,
            observedAt: evidence.lastTransition.observedAt, state: transportState)
        guard frozen.wholeSeconds != nil else { return cleared }
        content.frozenElapsed = frozen
        return Self(sessionID: sessionID, workoutTitle: workoutTitle, state: content)
    }

    func usingLanguage(_ language: AppLanguage) -> Self {
        Self(sessionID: sessionID, workoutTitle: workoutTitle, state: state.usingLanguage(language))
    }

    func usingDesignTheme(_ theme: ZOTheme) -> Self {
        Self(sessionID: sessionID, workoutTitle: workoutTitle, state: state.usingDesignTheme(theme))
    }

    /// Changes presentation only; the persisted workout projection remains authoritative.
    func usingAccent(_ accent: AccentPreference) -> Self {
        var content = state
        content.accentPreference = accent.rawValue
        return Self(sessionID: sessionID, workoutTitle: workoutTitle, state: content)
    }
}

enum WorkoutActivityProjector {
    static func project(
        _ snapshot: ActiveWorkoutSnapshot,
        phase forcedPhase: WorkoutActivityAttributes.ContentState.Phase? = nil,
        at date: Date = .now,
        accent: AccentPreference = .yellow,
        language: AppLanguage? = nil
    ) -> WorkoutActivityProjection {
        let session = snapshot.session
        let exercise = session.currentExercise ?? session.exercises.last!
        let phase: WorkoutActivityAttributes.ContentState.Phase
        if let forcedPhase {
            phase = forcedPhase
        } else if snapshot.isPaused {
            phase = .paused
        } else if session.requiresWarmUp {
            phase = .warmUp
        } else if snapshot.awaitingFinalSetConfirmation == true {
            phase = .readyToFinish
        } else if snapshot.awaitingNextSetAcknowledgement == true {
            phase = .awaitingNextSet
        } else if session.isResting(at: date) {
            phase = .rest
        } else if session.restEndsAt != nil, session.completedSetCount > 0 {
            phase = .awaitingNextSet
        } else {
            phase = .active
        }

        let coach = WorkoutActivityCoach.lines(session: session, phase: phase,
            localization: AppLocalization(language: language ?? .english))
        return WorkoutActivityProjection(
            sessionID: session.id,
            workoutTitle: session.title,
            state: WorkoutActivityAttributes.ContentState(
                exerciseName: exercise.plan.name,
                currentSet: session.currentSetNumber ?? exercise.completedSets.count,
                plannedSetsForExercise: exercise.plan.plannedSetCount,
                completedSets: session.completedSetCount,
                totalSets: session.totalPlannedSetCount,
                phase: phase,
                restEndsAt: phase == .rest ? session.restEndsAt : nil,
                pausedRestSeconds: phase == .paused ? snapshot.pausedRemainingRestSeconds : nil,
                accentPreference: accent.rawValue,
                displayLanguageIdentifier: language?.rawValue,
                restTotalSeconds: restTotalSeconds(for: session, phase: phase, at: date),
                coachLine: coach.coach,
                lastTimeShort: coach.lastShort,
                gainText: coach.gain
            )
        )
    }

    /// Reads only the same confirmed snapshot used for the original projection.
    /// Existing phase resolution and rest policy remain the workout owner's.
    private static func restTotalSeconds(
        for session: WorkoutSession,
        phase: WorkoutActivityAttributes.ContentState.Phase,
        at date: Date
    ) -> TimeInterval? {
        guard phase == .rest, date.timeIntervalSinceReferenceDate.isFinite,
              let duration = session.activeRestDuration, duration.isFinite, duration > 0,
              let end = session.restEndsAt, end.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let origin = end.addingTimeInterval(-duration)
        guard origin.timeIntervalSinceReferenceDate.isFinite, origin < end,
              origin <= date, date < end else { return nil }
        return duration
    }
}

enum WorkoutActivityDecision: Equatable {
    case endAll
    case request
    case update
    case unchanged

    static func decide(
        desired: WorkoutActivityProjection?,
        existingSessionID: UUID?,
        existingState: WorkoutActivityAttributes.ContentState?
    ) -> Self {
        guard let desired else { return .endAll }
        guard existingSessionID == desired.sessionID else { return .request }
        return existingState == desired.state ? .unchanged : .update
    }
}

/// Narrow ActivityKit boundary so actual coordinator suspension can be tested.
/// The production backend preserves the original SDK request/update/end calls.
@MainActor
protocol WorkoutLiveActivityHandle: AnyObject {
    var id: String { get }
    var sessionID: UUID { get }
    var state: WorkoutActivityAttributes.ContentState { get }
    func end() async
    func update(_ projection: WorkoutActivityProjection) async
}

@MainActor
protocol WorkoutLiveActivityClient: AnyObject {
    var activities: [any WorkoutLiveActivityHandle] { get }
    var areActivitiesEnabled: Bool { get }
    func request(_ projection: WorkoutActivityProjection) throws
}

@MainActor
private final class SystemWorkoutLiveActivityHandle: WorkoutLiveActivityHandle {
    private let activity: Activity<WorkoutActivityAttributes>
    init(_ activity: Activity<WorkoutActivityAttributes>) { self.activity = activity }
    var id: String { activity.id }
    var sessionID: UUID { activity.attributes.sessionID }
    var state: WorkoutActivityAttributes.ContentState { activity.content.state }
    func end() async { await activity.end(nil, dismissalPolicy: .immediate) }
    func update(_ projection: WorkoutActivityProjection) async {
        await activity.update(ActivityContent(state: projection.state, staleDate: projection.staleDate))
    }
}

@MainActor
private final class SystemWorkoutLiveActivityClient: WorkoutLiveActivityClient {
    var activities: [any WorkoutLiveActivityHandle] {
        Activity<WorkoutActivityAttributes>.activities.map { SystemWorkoutLiveActivityHandle($0) }
    }
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    func request(_ projection: WorkoutActivityProjection) throws {
        let attributes = WorkoutActivityAttributes(sessionID: projection.sessionID,
            workoutTitle: projection.workoutTitle)
        _ = try Activity.request(attributes: attributes,
            content: ActivityContent(state: projection.state, staleDate: projection.staleDate), pushType: nil)
    }
}

@MainActor
final class WorkoutLiveActivityCoordinator {
    private var generation = 0
    private var requestedSessionIDs = Set<UUID>()
    private let client: any WorkoutLiveActivityClient

    init() { client = SystemWorkoutLiveActivityClient() }
    init(client: any WorkoutLiveActivityClient) { self.client = client }

    private func isCurrent(_ capturedGeneration: Int) -> Bool {
        generation == capturedGeneration && !Task.isCancelled
    }

    func sync(_ desired: WorkoutActivityProjection?) async {
        // A cancelled invocation must not steal an earlier live sync's generation.
        guard !Task.isCancelled else { return }
        generation += 1
        let currentGeneration = generation
        let activities = client.activities
        guard isCurrent(currentGeneration) else { return }
        let matching = desired.flatMap { projection in
            activities.first { $0.sessionID == projection.sessionID }
        }
        if let matching { requestedSessionIDs.insert(matching.sessionID) }

        for activity in activities where activity.id != matching?.id {
            guard isCurrent(currentGeneration) else { return }
            await activity.end()
            guard isCurrent(currentGeneration) else { return }
        }

        guard isCurrent(currentGeneration) else { return }
        let decision = WorkoutActivityDecision.decide(desired: desired,
            existingSessionID: matching?.sessionID, existingState: matching?.state)
        guard let desired, isCurrent(currentGeneration) else { return }

        switch decision {
        case .request:
            guard client.areActivitiesEnabled, isCurrent(currentGeneration) else { return }
            guard requestedSessionIDs.insert(desired.sessionID).inserted else { return }
            do {
                try client.request(desired)
            } catch {
                requestedSessionIDs.remove(desired.sessionID)
                // The workout and its persistence do not depend on ActivityKit.
            }
        case .update:
            guard isCurrent(currentGeneration) else { return }
            await matching?.update(desired)
            // No new work may follow a cancelled/superseded suspension. An OS
            // operation already submitted cannot be recalled by this guard.
            guard isCurrent(currentGeneration) else { return }
        case .unchanged, .endAll:
            break
        }
    }
}
