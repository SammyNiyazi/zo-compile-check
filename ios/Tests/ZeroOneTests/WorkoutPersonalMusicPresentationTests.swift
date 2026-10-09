import XCTest
@testable import ZeroOne

final class WorkoutPersonalMusicPresentationTests: XCTestCase {
    private let app = WorkoutPersonalLibraryFreshness.Context(authorized: true, applicationSource: true)
    private let system = WorkoutPersonalLibraryFreshness.Context(authorized: true, applicationSource: false)

    func testLatestRequestAloneCanPublishEvenWhenTheQueryReturnsToTheSameText() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let first = freshness.begin(in: app)
        let second = freshness.begin(in: app)
        XCTAssertFalse(freshness.accepts(first, in: app, cancelled: false))
        XCTAssertTrue(freshness.accepts(second, in: app, cancelled: false))
        XCTAssertNotEqual(first.requestID, second.requestID)
    }

    func testImmediateQueryInvalidationRejectsTheOldRowBeforeDebounceCompletes() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let rowToken = freshness.begin(in: app)
        freshness.invalidate()
        XCTAssertFalse(freshness.accepts(rowToken, in: app, cancelled: false))
        let newRowToken = freshness.begin(in: app)
        XCTAssertFalse(freshness.accepts(rowToken, in: app, cancelled: false))
        XCTAssertTrue(freshness.accepts(newRowToken, in: app, cancelled: false))
    }

    func testSamePlaylistIDFromNewResultsCannotAuthorizeAnOldRowToken() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let oldResult = freshness.begin(in: app)
        let newResult = freshness.begin(in: app)
        // Membership equality does not enter authority. The request token does.
        XCTAssertNotEqual(oldResult, newResult)
        XCTAssertFalse(freshness.accepts(oldResult, in: app, cancelled: false))
        XCTAssertTrue(freshness.accepts(newResult, in: app, cancelled: false))
    }

    func testCanceledSuccessAndFailureBothLosePublicationAuthority() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let token = freshness.begin(in: app)
        XCTAssertFalse(freshness.accepts(token, in: app, cancelled: true))
        freshness.invalidate() // Picker close, refresh or rebind.
        XCTAssertFalse(freshness.accepts(token, in: app, cancelled: false))
    }

    func testAuthorizationABARejectsRequestDespiteIdenticalFinalContext() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let authorizedRequest = freshness.begin(in: app)
        freshness.invalidate() // refresh observes denied / transition begins
        let denied = WorkoutPersonalLibraryFreshness.Context(authorized: false, applicationSource: true)
        XCTAssertFalse(freshness.accepts(authorizedRequest, in: denied, cancelled: false))
        freshness.invalidate() // refresh observes authorized again
        XCTAssertFalse(freshness.accepts(authorizedRequest, in: app, cancelled: false))
        XCTAssertNotEqual(authorizedRequest.epoch, freshness.epoch)
    }

    func testSourceABARejectsOldRequestEvenAfterReturningToApplication() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let request = freshness.begin(in: app)
        freshness.invalidate() // application -> system
        XCTAssertFalse(freshness.accepts(request, in: system, cancelled: false))
        freshness.invalidate() // system -> application
        XCTAssertFalse(freshness.accepts(request, in: app, cancelled: false))
    }

    func testLibraryCanBeBrowsedFromSystemSourceButChangedSourceIsStale() {
        var freshness = WorkoutPersonalLibraryFreshness()
        let request = freshness.begin(in: system)
        XCTAssertTrue(freshness.accepts(request, in: system, cancelled: false))
        XCTAssertFalse(freshness.accepts(request, in: app, cancelled: false))
        let unauthorized = WorkoutPersonalLibraryFreshness.Context(authorized: false, applicationSource: false)
        XCTAssertFalse(freshness.accepts(request, in: unauthorized, cancelled: false))
    }

    func testPlaybackSuccessOrFailureRequiresThePostBindEpochAndApplicationAuthority() {
        var freshness = WorkoutPersonalLibraryFreshness()
        freshness.invalidate() // Expected deliberate queue bind.
        let playbackEpoch = freshness.epoch
        XCTAssertTrue(freshness.acceptsPlayback(epoch: playbackEpoch, in: app, cancelled: false))
        XCTAssertFalse(freshness.acceptsPlayback(epoch: playbackEpoch, in: app, cancelled: true))
        XCTAssertFalse(freshness.acceptsPlayback(epoch: playbackEpoch, in: system, cancelled: false))
        let denied = WorkoutPersonalLibraryFreshness.Context(authorized: false, applicationSource: true)
        XCTAssertFalse(freshness.acceptsPlayback(epoch: playbackEpoch, in: denied, cancelled: false))
        freshness.invalidate() // Refresh/dismissal/source transition while play awaits.
        XCTAssertFalse(freshness.acceptsPlayback(epoch: playbackEpoch, in: app, cancelled: false))
        let newEpoch = freshness.epoch
        XCTAssertTrue(freshness.acceptsPlayback(epoch: newEpoch, in: app, cancelled: false))
    }

    func testQueuePositionUsesEntryIdentityIncludingRepeatedMusicItems() throws {
        let queue = try XCTUnwrap(queue(ids: ["repeat-1", "repeat-2", "third"], current: "repeat-2"))
        XCTAssertEqual(queue.itemNumber, 2)
        XCTAssertEqual(queue.observedItemCount, 3)
        XCTAssertEqual(queue.playlistID, "library-id")
        XCTAssertEqual(WorkoutPersonalMusicCopy.queueLine(queue, localization: .english), "Queue item 2 of 3")
    }

    func testUnknownCurrentEntryAndMalformedQueuesDropAllPositionClaims() {
        XCTAssertNil(queue(ids: [], current: nil))
        XCTAssertNil(queue(ids: ["a", "b"], current: nil))
        XCTAssertNil(queue(ids: ["a", "b"], current: "missing"))
        XCTAssertNil(queue(ids: ["a", "a"], current: "a"))
        XCTAssertNil(queue(ids: [""], current: ""))
    }

    func testChangedQueueCannotKeepOldPlaylistAttribution() {
        let selected = WorkoutPersonalPlaylistSelection(id: "library-id", title: "Chosen", queueEntryIDs: ["a", "b"])
        XCTAssertNil(WorkoutPersonalQueuePresentation(authorized: true, applicationSource: true,
            selection: selected, queueEntryIDs: ["b", "a"], currentEntryID: "b"))
        XCTAssertNil(WorkoutPersonalQueuePresentation(authorized: true, applicationSource: true,
            selection: selected, queueEntryIDs: ["a", "b", "last-set"], currentEntryID: "last-set"))
    }

    func testSystemSourceOrUnavailableAccessNeverShowsPersonalQueuePosition() {
        let selected = WorkoutPersonalPlaylistSelection(id: "library-id", title: "Chosen", queueEntryIDs: ["a"])
        XCTAssertNil(WorkoutPersonalQueuePresentation(authorized: true, applicationSource: false,
            selection: selected, queueEntryIDs: ["a"], currentEntryID: "a"))
        XCTAssertNil(WorkoutPersonalQueuePresentation(authorized: false, applicationSource: true,
            selection: selected, queueEntryIDs: ["a"], currentEntryID: "a"))
        XCTAssertNil(WorkoutPersonalQueuePresentation(authorized: true, applicationSource: true,
            selection: nil, queueEntryIDs: ["a"], currentEntryID: "a"))
    }

    func testPlayingBadgeRequiresTheSelectedQueueAndActualPlayingStatus() throws {
        let queue = try XCTUnwrap(queue(ids: ["a"], current: "a"))
        let row = WorkoutPersonalPlaylistPresentation(id: "library-id", title: "Name", queue: queue, playback: .playing)
        XCTAssertEqual(row.state, .playing)
        XCTAssertEqual(WorkoutPersonalPlaylistPresentation(id: "library-id", title: "Name", queue: queue, playback: .paused).state, .paused)
        for status in [WorkoutMusicPlayback.stopped, .interrupted] {
            XCTAssertEqual(WorkoutPersonalPlaylistPresentation(id: "library-id", title: "Name", queue: queue, playback: status).state, .available)
        }
        XCTAssertEqual(WorkoutPersonalPlaylistPresentation(id: "different-id", title: "Name", queue: queue, playback: .playing).state, .available)
        XCTAssertEqual(WorkoutPersonalPlaylistPresentation(id: "library-id", title: "Name", queue: nil, playback: .playing).state, .available)
    }

    func testMetadataRemainsVerbatimAndOnlyInterfaceCopyIsLocalized() throws {
        let title = "Your music %1$@ · Paused"
        let selection = WorkoutPersonalPlaylistSelection(id: "library-id", title: title, queueEntryIDs: ["a"])
        let queue = try XCTUnwrap(WorkoutPersonalQueuePresentation(authorized: true, applicationSource: true,
            selection: selection, queueEntryIDs: ["a"], currentEntryID: "a"))
        XCTAssertEqual(WorkoutPersonalMusicCopy.originLine(queue, localization: .english), "In your library · " + title)
        let bg = AppLocalization(language: .bulgarian)
        XCTAssertEqual(WorkoutPersonalMusicCopy.originLine(queue, localization: bg), "В твоята библиотека · " + title)
        XCTAssertEqual(WorkoutPersonalMusicCopy.queueLine(queue, localization: bg), "Елемент 1 от 1 в опашката")
    }

    func testUnqueriedOrInvalidatedLibraryIsIdleRatherThanSuccessfullyEmpty() {
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: false,
            resultCount: 0, hasProblem: false).state, .idle)
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: false,
            resultCount: 3, hasProblem: false).state, .idle)
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: true,
            resultCount: -1, hasProblem: false).state, .idle)
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: true,
            resultCount: 0, hasProblem: false).state, .empty)
    }

    func testLoadingFailureAndAcceptedResultsRemainDistinct() {
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: true, hasAcceptedResults: false,
            resultCount: 0, hasProblem: false).state, .loading)
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: false,
            resultCount: 0, hasProblem: true).state, .failed)
        XCTAssertEqual(WorkoutPersonalLibraryPresentation(loading: false, hasAcceptedResults: true,
            resultCount: 2, hasProblem: false).state, .results)
    }

    func testPersonalLaneUsesKnownPlaylistAndRetainsCurrentTrackInAccessibility() throws {
        let queue = try XCTUnwrap(queue(ids: ["a", "b"], current: "b"))
        let track = WorkoutMusicLanePresentation.Track(title: "Your music %1$@", artist: "Paused")
        let lane = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .playing, track: track))
        let personal = try XCTUnwrap(WorkoutPersonalMusicLanePresentation(lane: lane, access: .authorized,
            problem: nil, lastSetActive: false, track: track, queue: queue, localization: .english))
        XCTAssertEqual(personal.title, "Chosen")
        XCTAssertEqual(personal.subtitle, "Queue item 2 of 2")
        XCTAssertEqual(personal.accessibilityLabel, "Chosen. Playing: Your music %1$@ by Paused. Queue item 2 of 2")
        let pausedLane = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .paused, track: track))
        let paused = try XCTUnwrap(WorkoutPersonalMusicLanePresentation(lane: pausedLane, access: .authorized,
            problem: nil, lastSetActive: false, track: track, queue: queue, localization: .english))
        XCTAssertTrue(paused.accessibilityLabel.contains("Paused: Your music %1$@ by Paused"))
    }

    func testPersonalLaneNeverOverridesUnknownQueueAccessProblemOrLastSet() throws {
        let queue = try XCTUnwrap(queue(ids: ["a"], current: "a"))
        let track = WorkoutMusicLanePresentation.Track(title: "Song", artist: nil)
        let lane = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .playing, track: track))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: lane, access: .authorized,
            problem: nil, lastSetActive: false, track: track, queue: nil, localization: .english))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: lane, access: .denied,
            problem: nil, lastSetActive: false, track: track, queue: queue, localization: .english))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: lane, access: .authorized,
            problem: .offline, lastSetActive: false, track: track, queue: queue, localization: .english))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: lane, access: .authorized,
            problem: nil, lastSetActive: true, track: track, queue: queue, localization: .english))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: lane, access: .authorized,
            problem: nil, lastSetActive: false, track: nil, queue: queue, localization: .english))
        let interrupted = WorkoutMusicLanePresentation(.init(access: .authorized, playback: .interrupted, track: track))
        XCTAssertNil(WorkoutPersonalMusicLanePresentation(lane: interrupted, access: .authorized,
            problem: nil, lastSetActive: false, track: track, queue: queue, localization: .english))
    }

    private func queue(ids: [String], current: String?) -> WorkoutPersonalQueuePresentation? {
        WorkoutPersonalQueuePresentation(authorized: true, applicationSource: true,
            selection: .init(id: "library-id", title: "Chosen", queueEntryIDs: ids),
            queueEntryIDs: ids, currentEntryID: current)
    }
}
