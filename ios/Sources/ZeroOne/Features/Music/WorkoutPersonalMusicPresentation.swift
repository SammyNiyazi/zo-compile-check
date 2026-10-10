import Foundation

/// Request authority is ephemeral. Invalidation changes the epoch even if access
/// or player source returns to the same value before a suspended request resumes.
struct WorkoutPersonalLibraryFreshness: Equatable {
    struct Context: Equatable {
        let authorized: Bool
        let applicationSource: Bool
    }
    struct Token: Equatable {
        let epoch: UUID
        let requestID: UUID
        let context: Context
    }

    private(set) var epoch = UUID()
    private var latest: Token?

    mutating func invalidate() {
        epoch = UUID()
        latest = nil
    }

    mutating func begin(in context: Context) -> Token {
        let token = Token(epoch: epoch, requestID: UUID(), context: context)
        latest = token
        return token
    }

    func accepts(_ token: Token, in context: Context, cancelled: Bool) -> Bool {
        !cancelled && context.authorized && token == latest
            && token.epoch == epoch && token.context == context
    }

    /// Playback captures its epoch after the deliberate application queue bind.
    /// Refresh, dismissal or another ownership transition then revokes completion.
    func acceptsPlayback(epoch expectedEpoch: UUID, in context: Context, cancelled: Bool) -> Bool {
        !cancelled && context.authorized && context.applicationSource && expectedEpoch == epoch
    }
}

/// Library membership is not evidence of personal authorship. This selection is
/// never encoded or stored as a catalog playlist and does not replace lastPick.
struct WorkoutPersonalPlaylistSelection: Equatable {
    let id: String
    let title: String
    var queueEntryIDs: [String] = []
}

/// An unqueried or invalidated listing is unknown, not a successfully empty library.
struct WorkoutPersonalLibraryPresentation: Equatable {
    enum State: Equatable { case idle, loading, failed, empty, results }
    let state: State

    init(loading: Bool, hasAcceptedResults: Bool, resultCount: Int, hasProblem: Bool) {
        if loading { state = .loading }
        else if hasProblem { state = .failed }
        else if !hasAcceptedResults || resultCount < 0 { state = .idle }
        else if resultCount == 0 { state = .empty }
        else { state = .results }
    }
}

/// A position in the observed application queue, never a playlist song count.
struct WorkoutPersonalQueuePresentation: Equatable {
    let playlistID: String
    let playlistTitle: String
    let itemNumber: Int
    let observedItemCount: Int

    init?(authorized: Bool, applicationSource: Bool,
          selection: WorkoutPersonalPlaylistSelection?,
          queueEntryIDs: [String], currentEntryID: String?) {
        guard authorized, applicationSource, let selection,
              !queueEntryIDs.isEmpty, !queueEntryIDs.contains(""),
              Set(queueEntryIDs).count == queueEntryIDs.count,
              selection.queueEntryIDs == queueEntryIDs,
              let currentEntryID,
              let index = queueEntryIDs.firstIndex(of: currentEntryID) else { return nil }
        playlistID = selection.id
        playlistTitle = selection.title
        itemNumber = index + 1
        observedItemCount = queueEntryIDs.count
    }
}

struct WorkoutPersonalPlaylistPresentation: Equatable {
    enum State: Equatable { case available, playing, paused }
    let id: String
    let title: String
    let state: State

    init(id: String, title: String, queue: WorkoutPersonalQueuePresentation?,
         playback: WorkoutMusicPlayback) {
        self.id = id
        self.title = title
        if queue?.playlistID == id, playback == .playing {
            state = .playing
        } else if queue?.playlistID == id, playback == .paused {
            state = .paused
        } else {
            state = .available
        }
    }
}

enum WorkoutPersonalMusicCopy {
    static func originLine(_ queue: WorkoutPersonalQueuePresentation,
                           localization: AppLocalization) -> String {
        localization.format("In your library · %1$@", .text(queue.playlistTitle))
    }

    static func queueLine(_ queue: WorkoutPersonalQueuePresentation,
                          localization: AppLocalization) -> String {
        localization.format("Queue item %1$lld of %2$lld",
                            .integer(queue.itemNumber), .integer(queue.observedItemCount))
    }

    static func why(localization: AppLocalization) -> String {
        localization.string("You chose this playlist from your library. This selection stays only while its queue is known in 01; your saved last pick is unchanged.")
    }
}

/// The existing lane keeps its errors, access prompts, last-set track and
/// transports. Only known personal queue context supplies this optional copy.
struct WorkoutPersonalMusicLanePresentation: Equatable {
    let title: String
    let subtitle: String
    let accessibilityLabel: String

    init?(lane: WorkoutMusicLanePresentation, access: WorkoutMusicAccess,
          problem: WorkoutMusicProblem?, lastSetActive: Bool,
          track: WorkoutMusicLanePresentation.Track?,
          queue: WorkoutPersonalQueuePresentation?, localization: AppLocalization) {
        guard access == .authorized, problem == nil, !lastSetActive,
              let track, let queue, case .transport = lane.accessory else { return nil }
        title = queue.playlistTitle
        subtitle = WorkoutPersonalMusicCopy.queueLine(queue, localization: localization)
        accessibilityLabel = localization.format("%1$@. %2$@. %3$@",
            .text(title), .text(WorkoutOwnMusicCopy.accessibilityLabel(for: lane, track: track, localization: localization)),
            .text(subtitle))
    }
}
