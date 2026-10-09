import Foundation
import XCTest
@testable import ZeroOne

final class WorkoutMusicPresentationTests: XCTestCase {
    private typealias Lane = WorkoutMusicLanePresentation
    private let track = Lane.Track(title: "Iron Weather", artist: "Halvard Lane")

    func testAccessStatesComeBeforeAnyProblemOrTrack() {
        let cases: [(WorkoutMusicAccess, String, Lane.Accessory)] = [
            (.notConfigured, "Music is unavailable in this version", Lane.Accessory.none),
            (.notDetermined, "Add your music", .action(.connect)),
            (.denied, "Apple Music is off for 01", .action(.settings)),
            (.restricted, "Apple Music is restricted", Lane.Accessory.none)
        ]
        for (access, title, accessory) in cases {
            let lane = Lane(.init(access: access, playback: .playing, problem: .offline, track: track))
            XCTAssertEqual(lane.title, title, "\(access)")
            XCTAssertEqual(lane.accessory, accessory, "\(access)")
            XCTAssertFalse(lane.isInverted, "\(access)")
        }
    }

    func testProblemsOutrankTheCurrentTrackAndOfferOneAction() {
        let cases: [(WorkoutMusicProblem, Lane.Action)] = [
            (.offline, .retry), (.needsSubscription, .choose), (.itemUnavailable, .choose),
            (.playbackFailed, .retry), (.catalogCheckFailed, .retry)
        ]
        for (problem, action) in cases {
            let lane = Lane(.init(access: .authorized, playback: .playing, problem: problem, track: track))
            XCTAssertEqual(lane.accessory, .action(action), "\(problem)")
            XCTAssertNotEqual(lane.title, track.title, "\(problem)")
        }
    }

    func testNoTrackAsksToChooseAndActionLabelsMatch() {
        let lane = Lane(.init(access: .authorized))
        XCTAssertEqual(lane.title, "Pick a soundtrack")
        XCTAssertEqual(lane.actionLabel, "Choose")
        XCTAssertEqual(Lane(.init(access: .notDetermined)).actionLabel, "Connect")
        XCTAssertEqual(Lane(.init(access: .denied)).actionLabel, "Settings")
        XCTAssertEqual(Lane(.init(access: .authorized, problem: .offline)).actionLabel, "Retry")
        XCTAssertNil(Lane(.init(access: .restricted)).actionLabel)
    }

    func testInterruptionHasNoControlsAndNeverClaimsACall() {
        let lane = Lane(.init(access: .authorized, playback: .interrupted, track: track))
        XCTAssertEqual(lane.accessory, Lane.Accessory.none)
        XCTAssertEqual(lane.glyph, .interrupted)
        XCTAssertFalse(lane.title.localizedCaseInsensitiveContains("call"))
        XCTAssertFalse(lane.subtitle.localizedCaseInsensitiveContains("call"))
    }

    func testPlayingPausedAndLastSetSubtitles() {
        let playing = Lane(.init(access: .authorized, playback: .playing, track: track, sourceName: "Steady Load"))
        XCTAssertEqual(playing.title, "Iron Weather")
        XCTAssertEqual(playing.subtitle, "Halvard Lane · Steady Load")
        XCTAssertEqual(playing.accessory, .transport(isPlaying: true))
        XCTAssertEqual(playing.accessibilityLabel, "Playing: Iron Weather by Halvard Lane")

        let paused = Lane(.init(access: .authorized, playback: .paused, track: track, sourceName: "Steady Load"))
        XCTAssertEqual(paused.subtitle, "Paused · Halvard Lane")
        XCTAssertEqual(paused.accessory, .transport(isPlaying: false))

        let lastSet = Lane(.init(access: .authorized, playback: .playing, track: track, lastSetActive: true))
        XCTAssertTrue(lastSet.isInverted)
        XCTAssertEqual(lastSet.subtitle, "Your last-set track · Halvard Lane")
        XCTAssertFalse(playing.isInverted)
    }

    func testOnlyURLNetworkFailuresCountAsOffline() {
        XCTAssertEqual(WorkoutMusicProblem.classify(URLError(.notConnectedToInternet)), .offline)
        let wrapped = NSError(domain: "MusicKit", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)])
        XCTAssertEqual(WorkoutMusicProblem.classify(wrapped), .offline)
        XCTAssertEqual(WorkoutMusicProblem.classify(URLError(.badServerResponse)), .playbackFailed)
        XCTAssertEqual(WorkoutMusicProblem.classify(NSError(domain: "MusicKit", code: 7)), .playbackFailed)
    }

    func testDeckNotesExplainInPlaceAndOfferOnlyRelevantActions() {
        let noSubscription = WorkoutMusicDeckNote(problem: .needsSubscription, playback: .stopped, canBecomeSubscriber: true)
        XCTAssertEqual(noSubscription?.actions, [.useLibrary, .tryAppleMusic])
        let cannotSubscribe = WorkoutMusicDeckNote(problem: .needsSubscription, playback: .stopped, canBecomeSubscriber: false)
        XCTAssertEqual(cannotSubscribe?.actions, [.useLibrary])
        XCTAssertEqual(WorkoutMusicDeckNote(problem: .offline, playback: .paused, canBecomeSubscriber: false)?.actions, [.retry])
        XCTAssertEqual(WorkoutMusicDeckNote(problem: .itemUnavailable, playback: .paused, canBecomeSubscriber: false)?.actions,
                       [.chooseAnother])
        XCTAssertEqual(WorkoutMusicDeckNote(problem: .playbackFailed, playback: .paused, canBecomeSubscriber: false)?.actions,
                       [.retry, .chooseAnother])

        let interrupted = WorkoutMusicDeckNote(problem: nil, playback: .interrupted, canBecomeSubscriber: false)
        XCTAssertEqual(interrupted?.actions, [])
        XCTAssertFalse(interrupted?.detail.localizedCaseInsensitiveContains("call") ?? true)
        XCTAssertNil(WorkoutMusicDeckNote(problem: nil, playback: .playing, canBecomeSubscriber: true))
        XCTAssertNil(WorkoutMusicDeckNote(problem: nil, playback: .paused, canBecomeSubscriber: true))
    }

    func testSourceNoteSaysWhyAndLastSetWins() {
        let mix = WorkoutMusicSourceNote(origin: .mix(.steadyLoad), lastSetActive: false)
        XCTAssertEqual(mix?.line, "01 Mix · Steady Load")
        XCTAssertTrue(mix?.why.contains("Nothing from your listening is used") ?? false)

        let recommendation = WorkoutMusicSourceNote(origin: .recommendation("Lifting"), lastSetActive: false)
        XCTAssertEqual(recommendation?.line, "Apple Music pick · Lifting")
        XCTAssertTrue(recommendation?.why.contains("doesn't store it") ?? false)

        let lastSet = WorkoutMusicSourceNote(origin: .mix(.topSet), lastSetActive: true)
        XCTAssertEqual(lastSet?.line, "Your last-set track, chosen by you")
        XCTAssertNil(WorkoutMusicSourceNote(origin: nil, lastSetActive: false))
    }

    func testMixesAreReadyOnlyWithCuratedSongIDs() {
        XCTAssertEqual(WorkoutMusicMix.allCases.map(\.energy), [1, 2, 3])
        for mix in WorkoutMusicMix.allCases {
            let hasSongs = !(WorkoutMusicMixCatalog.songIDs[mix] ?? []).isEmpty
            XCTAssertEqual(mix.isReady, hasSongs, mix.name)
            XCTAssertEqual(mix.coverLines.count, 4, mix.name)
            XCTAssertTrue(mix.accessibilityDescription.hasPrefix("01 Mix \(mix.name)."), mix.name)
            XCTAssertEqual(mix.accessibilityDescription.hasSuffix("Not available yet."), !hasSongs, mix.name)
        }
    }

    func testLastPickRoundTripsAndRejectsDamagedData() throws {
        let pick = WorkoutMusicLastPick(kind: .catalogPlaylist, id: "pl.123", title: "Lifting",
                                        subtitle: "Apple Music Fitness", pickedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(WorkoutMusicLastPick.decode(pick.encoded), pick)
        XCTAssertEqual(pick.kindLabel, "Playlist")
        XCTAssertNil(WorkoutMusicLastPick.decode(nil))
        XCTAssertNil(WorkoutMusicLastPick.decode(Data("not json".utf8)))
    }

    func testClockAndProgressFraction() {
        XCTAssertEqual(WorkoutMusicTime.clock(228.9), "3:48")
        XCTAssertEqual(WorkoutMusicTime.clock(5), "0:05")
        XCTAssertEqual(WorkoutMusicTime.clock(-4), "0:00")
        XCTAssertNil(WorkoutMusicTime.fraction(30, of: nil))
        XCTAssertNil(WorkoutMusicTime.fraction(30, of: 0))
        XCTAssertEqual(WorkoutMusicTime.fraction(57, of: 228), 0.25)
        XCTAssertEqual(WorkoutMusicTime.fraction(400, of: 228), 1)
        XCTAssertEqual(WorkoutMusicTime.fraction(-3, of: 228), 0)
    }
}
