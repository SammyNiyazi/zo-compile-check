import Foundation

/// Ephemeral, factual host context. It never changes a queue, permission or provider.
/// Workout titles describe the selected session; they are not classified into inferred intensity.
struct WorkoutMusicContext: Equatable, Sendable {
    enum Activity: Equatable, Sendable { case workout, walk, run }
    enum Phase: Equatable, Sendable { case ready, warmUp, workingSets, resting, recording, paused, finalReview, complete }
    enum Stage: Equatable, Sendable { case ready, active }

    let activity: Activity
    let phase: Phase
    let sessionTitle: String?
    let hasPlannedWarmUp: Bool

    init(session: WorkoutSession, stage: Stage, isPaused: Bool = false,
         awaitingNextSet: Bool = false, awaitingFinalSetConfirmation: Bool = false) {
        activity = .workout
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTitle = title.isEmpty ? nil : title
        hasPlannedWarmUp = session.requiresWarmUp
        if session.isComplete && awaitingFinalSetConfirmation {
            phase = .finalReview
        } else if session.isComplete {
            phase = .complete
        } else if stage == .ready {
            phase = .ready
        } else if isPaused {
            phase = .paused
        } else if session.requiresWarmUp {
            phase = .warmUp
        } else if session.restEndsAt != nil || awaitingNextSet {
            // The host keeps its rest surface until the next set is acknowledged.
            phase = .resting
        } else {
            phase = .workingSets
        }
    }

    init(outdoor: OutdoorActivityCheckpoint, needsExplicitResume: Bool = false) {
        activity = outdoor.kind == .walk ? .walk : .run
        sessionTitle = nil
        hasPlannedWarmUp = false
        switch outdoor.phase {
        case .readyToSave: phase = .complete
        case .paused: phase = .paused
        case .recording: phase = needsExplicitResume ? .paused : .recording
        }
    }
}

/// A choice offered from session facts, not a claim about recovery or performance.
/// Nil context deliberately yields neutral copy and no suggested energy.
struct WorkoutMusicContextSuggestion: Equatable, Sendable {
    enum Energy: Equatable, Sendable { case easy, steady }

    let title: String
    let reason: String
    let energy: Energy?

    init(context: WorkoutMusicContext?) {
        guard let context else {
            title = "Your soundtrack"
            reason = "Choose the music you want. Music is optional."
            energy = nil
            return
        }
        let session = context.sessionTitle.map { " for \($0)" } ?? ""
        switch context.phase {
        case .ready:
            title = context.hasPlannedWarmUp ? "An easy start" : "A steady soundtrack"
            reason = context.sessionTitle.map { "Suggested because today is \($0). Choose whatever you prefer." }
                ?? "Suggested for your selected workout. Choose whatever you prefer."
            energy = context.hasPlannedWarmUp ? .easy : .steady
        case .warmUp:
            title = "An easy start"
            reason = "Suggested because you're warming up\(session). Choose whatever you prefer."
            energy = .easy
        case .workingSets:
            title = "A steady soundtrack"
            reason = "Suggested because you're on working sets\(session). Choose whatever you prefer."
            energy = .steady
        case .resting:
            title = "Keep your soundtrack"
            reason = "You're between sets\(session). Music stays as you chose it."
            energy = nil
        case .paused:
            title = "Music is your choice"
            reason = "Your \(context.activity == .workout ? "workout" : context.activity == .walk ? "walk" : "run") is paused. Music stays as you chose it."
            energy = nil
        case .recording:
            title = "A steady soundtrack"
            reason = "Suggested because you're recording a \(context.activity == .walk ? "walk" : "run"). Choose whatever you prefer."
            energy = .steady
        case .complete:
            title = "Music stays with you"
            reason = "Your session is finished. You choose whether to keep listening."
            energy = nil
        case .finalReview:
            title = "Keep your soundtrack"
            reason = "Your final set is ready to review. Music stays as you chose it."
            energy = nil
        }
    }
}
