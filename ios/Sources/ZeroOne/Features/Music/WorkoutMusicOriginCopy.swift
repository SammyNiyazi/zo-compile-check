import Foundation

/// Formats known interface copy around verbatim MusicKit metadata.
enum WorkoutMusicOriginCopy {
    static func line(origin: WorkoutMusicOrigin?, lastSetActive: Bool,
                     localization: AppLocalization) -> String {
        if lastSetActive { return localization.string("Your last-set track, chosen by you") }
        switch origin {
        case .picked(let title)?: return localization.format("You picked · %1$@", .text(title))
        case .lastPick(let title)?: return localization.format("Your last pick · %1$@", .text(title))
        case .recommendation(let title)?: return localization.format("Apple Music pick · %1$@", .text(title))
        case .musicApp?: return localization.string("From the Music app")
        case .mix(_)?: return localization.string("From Apple Music")
        case nil: return ""
        }
    }

    static func why(origin: WorkoutMusicOrigin?, lastSetActive: Bool,
                    localization: AppLocalization) -> String {
        if lastSetActive {
            return localization.string("You chose this song for your final set. It was queued next when the set began.")
        }
        switch origin {
        case .picked(_)?, .lastPick(_)?:
            return localization.string("You chose this in 01. 01 remembers only your last pick, on this iPhone.")
        case .recommendation(_)?:
            return localization.string("Apple Music suggested this from your listening because you turned on Apple Music picks. 01 doesn't store it.")
        case .musicApp?:
            return localization.string("This was already playing in the Music app. 01 can see only the current song.")
        case .mix(_)?:
            // Historical store compatibility is not an invitation to 01 playlists.
            return localization.string("You can choose music from your own library.")
        case nil: return ""
        }
    }
}
