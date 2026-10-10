import Foundation

/// Override only the obsolete empty-state invitation, preserving actual errors and playback facts.
enum WorkoutOwnMusicCopy {
    static func title(for lane: WorkoutMusicLanePresentation, access: WorkoutMusicAccess,
                      problem: WorkoutMusicProblem?, hasTrack: Bool,
                      localization: AppLocalization = .english) -> String {
        if access == .authorized, problem == nil, !hasTrack {
            return localization.string("Your music")
        }
        switch lane.glyph {
        case .playing, .paused: return lane.title // A real track title is never a lookup key.
        default: return localization.string(lane.title)
        }
    }

    static func subtitle(for lane: WorkoutMusicLanePresentation, access: WorkoutMusicAccess,
                         problem: WorkoutMusicProblem?, hasTrack: Bool,
                         localization: AppLocalization = .english,
                         track: WorkoutMusicLanePresentation.Track? = nil,
                         playback: WorkoutMusicPlayback? = nil,
                         lastSetActive: Bool = false) -> String {
        if access == .authorized, problem == nil, !hasTrack {
            return localization.string("From your Apple Music library")
        }
        switch lane.glyph {
        case .playing, .paused:
            // Rebuild only typed interface prefixes; never parse the artist/source text.
            if let track, let playback, lastSetActive || playback != .playing {
                let prefix = localization.string(lastSetActive ? "Your last-set track" : "Paused")
                if let artist = track.artist {
                    return localization.format("%1$@ · %2$@", .text(prefix), .text(artist))
                }
                return prefix
            }
            return lane.subtitle
        default: return localization.string(lane.subtitle)
        }
    }

    static func accessibilityLabel(for lane: WorkoutMusicLanePresentation,
                                   track: WorkoutMusicLanePresentation.Track?,
                                   localization: AppLocalization) -> String {
        guard let track, case .transport(let playing) = lane.accessory else {
            return localization.string(lane.accessibilityLabel)
        }
        let status = localization.string(playing ? "Playing" : "Paused")
        if let artist = track.artist {
            return localization.format("%1$@: %2$@ by %3$@", .text(status), .text(track.title), .text(artist))
        }
        return localization.format("%1$@: %2$@", .text(status), .text(track.title))
    }
}
