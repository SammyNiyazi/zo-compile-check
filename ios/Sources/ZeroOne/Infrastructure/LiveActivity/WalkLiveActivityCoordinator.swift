import ActivityKit
import Foundation

/// Study 36: what the walk or run Live Activity should show right now, built only
/// from the saved checkpoint. Distance and steps are rounded so the activity
/// updates on real progress, not on every second of the clock.
struct WalkActivityProjection: Equatable {
    let sessionID: UUID
    let kind: OutdoorActivityKind
    let state: WalkActivityAttributes.ContentState

    static func make(surface: OutdoorActivitySurface, checkpoint: OutdoorActivityCheckpoint?,
                     withoutGPS: Bool, accent: AccentPreference, language: AppLanguage,
                     theme: ZOTheme) -> WalkActivityProjection? {
        guard let checkpoint else { return nil }
        let seconds = max(0, checkpoint.confirmedActiveSeconds)
        let distance = checkpoint.trackingMode == .route
            ? checkpoint.route.recordedDistanceMeters.map { ($0 / 10).rounded(.down) * 10 } : nil
        let steps = checkpoint.steps.recordedSteps.map { $0 / 10 * 10 }
        let phase: WalkActivityAttributes.ContentState.Phase
        switch surface {
        case .recording:
            if checkpoint.trackingMode == .timerOnly || withoutGPS { phase = .noGPS }
            else { phase = distance == nil ? .finding : .recording }
        case .saving: phase = .saving
        case .paused, .interrupted, .locationUnavailable, .storageBlocked, .requestingPermission, .setup:
            phase = .paused
        case .summary: return nil
        }
        let live = phase == .finding || phase == .recording || phase == .noGPS
        let anchor = checkpoint.checkpointedAt.addingTimeInterval(-seconds)
        return WalkActivityProjection(sessionID: checkpoint.id, kind: checkpoint.kind, state: .init(
            phase: phase,
            elapsedAnchor: Date(timeIntervalSinceReferenceDate: anchor.timeIntervalSinceReferenceDate.rounded()),
            frozenSeconds: live ? nil : Int(seconds),
            distanceMetres: distance, steps: steps,
            distanceIncomplete: checkpoint.route.hasMissingLocationCoverage,
            designThemeIdentifier: theme.rawValue, accentPreference: accent.rawValue,
            displayLanguageIdentifier: language.rawValue))
    }
}

@MainActor
final class WalkLiveActivityCoordinator {
    private var last: WalkActivityProjection?

    func sync(_ desired: WalkActivityProjection?) async {
        guard !Task.isCancelled else { return }
        let activities = Activity<WalkActivityAttributes>.activities
        guard let desired else {
            // A walk that was saving ends as Saved for a few minutes; anything else goes now.
            let saved = last?.state.phase == .saving ? last : nil
            last = nil
            for activity in activities {
                if let saved, activity.attributes.sessionID == saved.sessionID {
                    var state = saved.state
                    state.phase = .saved
                    await activity.end(ActivityContent(state: state, staleDate: nil),
                                       dismissalPolicy: .after(.now.addingTimeInterval(10 * 60)))
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }
        last = desired
        let matching = activities.first { $0.attributes.sessionID == desired.sessionID }
        for other in activities where other.id != matching?.id {
            await other.end(nil, dismissalPolicy: .immediate)
        }
        let content = ActivityContent(state: desired.state,
            staleDate: desired.state.isLive ? Date.now.addingTimeInterval(30 * 60) : nil)
        if let matching {
            guard matching.content.state != desired.state else { return }
            await matching.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled, desired.state.phase != .saving {
            // The walk and its saving never depend on ActivityKit.
            _ = try? Activity.request(attributes: WalkActivityAttributes(sessionID: desired.sessionID,
                                                                        kind: desired.kind.rawValue),
                                      content: content, pushType: nil)
        }
    }
}
