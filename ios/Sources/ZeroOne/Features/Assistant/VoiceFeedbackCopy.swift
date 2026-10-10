import Foundation

/// Only the coordinator's known static feedback is translated. Unknown messages
/// and the recognized transcript retain their exact content.
enum VoiceFeedbackCopy {
    static func message(_ message: String, localization: AppLocalization) -> String {
        switch message {
        case "Transcript confirmed.",
             "Enable microphone access in Settings.",
             "Enable speech recognition in Settings.",
             "Speech recognition is unavailable.",
             "No microphone is available.",
             "Listening was interrupted.",
             "Couldn’t understand that.",
             "Didn’t catch that.":
            return localization.string(message)
        default:
            return message
        }
    }
}
