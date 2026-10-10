import CoreGraphics
import XCTest
@testable import ZeroOne

final class OwnMusicVoicePresentationTests: XCTestCase {
    func testEmptyAuthorizedLaneReplacesTheWithdrawnMixInvitation() {
        let lane = WorkoutMusicLanePresentation(.init(access: .authorized))
        XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: lane, access: .authorized,
                       problem: nil, hasTrack: false), AppLocalization.english.string("From your Apple Music library"))
    }

    func testPermissionAndPlaybackProblemsKeepTheirRealExplanation() {
        for access in [WorkoutMusicAccess.notConfigured, .notDetermined, .denied, .restricted] {
            let lane = WorkoutMusicLanePresentation(.init(access: access))
            XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: lane, access: access,
                           problem: nil, hasTrack: false), lane.subtitle)
        }
        for problem in [WorkoutMusicProblem.offline, .needsSubscription, .catalogCheckFailed,
                        .itemUnavailable, .playbackFailed] {
            let lane = WorkoutMusicLanePresentation(.init(access: .authorized, problem: problem))
            XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: lane, access: .authorized,
                           problem: problem, hasTrack: false), lane.subtitle)
        }
    }

    func testAnActualTrackKeepsItsPlayerSubtitle() {
        let lane = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .interrupted,
                   track: .init(title: "Chosen song", artist: "Chosen artist")))
        XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: lane, access: .authorized,
                       problem: nil, hasTrack: true), lane.subtitle)
    }

    func testCancelHitTargetFollowsLayoutDirectionAndDoesNotAcceptTheGap() {
        XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: -38, y: 32)))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: 32, y: 32)))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: -8, y: 32)))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: -38, y: 5)))
        XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: 102, y: 32), isRightToLeft: true))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: -38, y: 32), isRightToLeft: true))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: 72, y: 32), isRightToLeft: true))
    }

    func testSelectedLanguageChangesEmptyLaneWithoutChangingTrackMetadata() {
        let bulgarian = AppLocalization(language: .bulgarian)
        let empty = WorkoutMusicLanePresentation(.init(access: .authorized))
        XCTAssertEqual(WorkoutOwnMusicCopy.title(for: empty, access: .authorized,
            problem: nil, hasTrack: false, localization: bulgarian), "Твоята музика")
        let track = WorkoutMusicLanePresentation.Track(title: "Your music", artist: "Paused · %1$@")
        let playing = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .playing, track: track))
        XCTAssertEqual(WorkoutOwnMusicCopy.title(for: playing, access: .authorized,
            problem: nil, hasTrack: true, localization: bulgarian), track.title)
        XCTAssertEqual(WorkoutOwnMusicCopy.accessibilityLabel(for: playing, track: track,
            localization: .english), "Playing: Your music by Paused · %1$@")
    }

    func testLocalizedPausedAndLastSetPrefixesLeaveArtistVerbatim() {
        let bulgarian = AppLocalization(language: .bulgarian)
        let track = WorkoutMusicLanePresentation.Track(title: "Ready", artist: "Paused · %1$@")
        let paused = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .paused, track: track))
        XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: paused, access: .authorized, problem: nil,
            hasTrack: true, localization: bulgarian, track: track, playback: .paused),
            "На пауза · Paused · %1$@")
        let lastSet = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .playing,
            track: track, lastSetActive: true))
        XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: lastSet, access: .authorized, problem: nil,
            hasTrack: true, localization: bulgarian, track: track, playback: .playing, lastSetActive: true),
            "Твоята песен за последната серия · Paused · %1$@")
        let unavailable = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .paused,
            problem: .offline, track: track))
        XCTAssertEqual(WorkoutOwnMusicCopy.subtitle(for: unavailable, access: .authorized,
            problem: .offline, hasTrack: true, localization: .english, track: track, playback: .paused),
            unavailable.subtitle)
    }

    func testOriginFormattingRetainsTitlesAndDoesNotOfferWithdrawnMixes() {
        let title = "Your music %1$@"
        XCTAssertEqual(WorkoutMusicOriginCopy.line(origin: .picked(title), lastSetActive: false,
            localization: .english), "You picked · " + title)
        XCTAssertEqual(WorkoutMusicOriginCopy.line(origin: .mix(.warmStart), lastSetActive: false,
            localization: .english), "From Apple Music")
        XCTAssertFalse(WorkoutMusicOriginCopy.why(origin: .mix(.warmStart), lastSetActive: false,
            localization: .english).contains("01 picks its mixes"))
    }

    func testKnownVoiceFeedbackTranslatesButUnknownMessageRemainsVerbatim() {
        let bulgarian = AppLocalization(language: .bulgarian)
        XCTAssertEqual(VoiceFeedbackCopy.message("Transcript confirmed.", localization: bulgarian),
            "Текстът е потвърден.")
        let unknown = "My request · %1$@ · 你好"
        XCTAssertEqual(VoiceFeedbackCopy.message(unknown, localization: bulgarian), unknown)
    }
}
