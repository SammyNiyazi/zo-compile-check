import Combine
import Foundation
import MusicKit
import Observation

// MARK: - Pure presentation inputs (no MusicKit types, so they are testable)

enum WorkoutMusicAccess: Equatable {
    case notConfigured, notDetermined, denied, restricted, authorized
}

enum WorkoutMusicPlayback: Equatable {
    case playing, paused, stopped, interrupted
}

/// What went wrong with the last music action. Never inferred from playback
/// status alone: `.interrupted` is shown as a system interruption, not a call.
enum WorkoutMusicProblem: Equatable {
    case catalogCheckFailed, offline, needsSubscription, itemUnavailable, playbackFailed

    private static let networkCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue,
        URLError.timedOut.rawValue, URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue, URLError.dnsLookupFailed.rawValue,
        URLError.internationalRoamingOff.rawValue, URLError.dataNotAllowed.rawValue
    ]

    /// Only a URL-domain network failure counts as offline. Anything else is a
    /// generic playback failure; 01 does not guess a more specific cause.
    static func classify(_ error: Error) -> WorkoutMusicProblem {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSURLErrorDomain, networkCodes.contains(nsError.code) { return .offline }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .playbackFailed
    }
}

/// Where the current soundtrack came from, so the deck can say why it plays.
enum WorkoutMusicOrigin: Equatable {
    case picked(String), lastPick(String), recommendation(String), mix(WorkoutMusicMix), musicApp

    var line: String {
        switch self {
        case .picked(let title): "You picked · \(title)"
        case .lastPick(let title): "Your last pick · \(title)"
        case .recommendation(let title): "Apple Music pick · \(title)"
        case .mix(let mix): "01 Mix · \(mix.name)"
        case .musicApp: "From the Music app"
        }
    }

    var why: String {
        switch self {
        case .picked, .lastPick: "You chose this in 01. 01 remembers only your last pick, on this iPhone."
        case .recommendation: "Apple Music suggested this from your listening because you turned on Apple Music picks. 01 doesn't store it."
        case .mix: "01 picks its mixes by energy. Nothing from your listening is used."
        case .musicApp: "This was already playing in the Music app. 01 can see only the current song."
        }
    }
}

/// 01's own mixes. Playback needs 01-curated Apple Music catalog song IDs.
/// Until those lists exist the mixes are shown as not available, never
/// substituted by search results.
enum WorkoutMusicMix: String, CaseIterable, Identifiable, Equatable {
    case warmStart, steadyLoad, topSet
    var id: String { rawValue }

    var name: String {
        switch self { case .warmStart: "Warm Start"; case .steadyLoad: "Steady Load"; case .topSet: "Top Set" }
    }
    var energy: Int {
        switch self { case .warmStart: 1; case .steadyLoad: 2; case .topSet: 3 }
    }
    var character: String {
        switch self { case .warmStart: "Easy"; case .steadyLoad: "Mid-tempo"; case .topSet: "Loud" }
    }
    var basis: String {
        switch self {
        case .warmStart: "01's easy mix for warm-ups and cooldowns. Picked by 01, not from your listening."
        case .steadyLoad: "01's mid-tempo mix for steady working sets. Picked by 01, not from your listening."
        case .topSet: "01's high-energy mix for heavy top sets. Picked by 01, not from your listening."
        }
    }
    /// Cover line pattern: (relative width, height in points), from Study 21.
    var coverLines: [(width: Double, height: Double)] {
        switch self {
        case .warmStart: [(1, 5), (0.74, 4), (0.5, 3), (0.28, 2)]
        case .steadyLoad: [(1, 5), (1, 5), (1, 5), (1, 5)]
        case .topSet: [(0.34, 6), (0.56, 6), (0.78, 6), (1, 6)]
        }
    }
}

/// Integration dependency: 01 has not yet supplied curated catalog song IDs.
enum WorkoutMusicMixCatalog {
    static let songIDs: [WorkoutMusicMix: [String]] = [:]

    static func isAvailable(_ mix: WorkoutMusicMix) -> Bool {
        !(songIDs[mix] ?? []).isEmpty
    }
}

/// The one item remembered on this iPhone because the person picked it.
struct WorkoutMusicLastPick: Codable, Equatable {
    enum Kind: String, Codable { case librarySong, catalogSong, catalogPlaylist }
    let kind: Kind
    let id: String
    let title: String
    let subtitle: String?
    let pickedAt: Date

    static let storageKey = "slick.music.lastPick"

    static func decode(_ data: Data?) -> WorkoutMusicLastPick? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WorkoutMusicLastPick.self, from: data)
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }

    var kindLabel: String { kind == .catalogPlaylist ? "Playlist" : "Song" }
}

/// The lane's single row, derived from state in the priority the person can act on.
struct WorkoutMusicLanePresentation: Equatable {
    enum Action: Equatable { case connect, settings, choose, retry }
    enum Accessory: Equatable { case transport(isPlaying: Bool), action(Action), none }
    enum Glyph: Equatable { case note, noteOff, lock, cloudOff, interrupted, playing, paused }

    struct Track: Equatable {
        let title: String
        let artist: String?
    }

    struct Input: Equatable {
        var access: WorkoutMusicAccess
        var playback: WorkoutMusicPlayback = .stopped
        var problem: WorkoutMusicProblem? = nil
        var track: Track? = nil
        var sourceName: String? = nil
        var lastSetActive = false
    }

    let title: String
    let subtitle: String
    let accessory: Accessory
    let glyph: Glyph
    let isInverted: Bool
    let accessibilityLabel: String

    init(_ input: Input) {
        let resolved = Self.resolve(input)
        title = resolved.title
        subtitle = resolved.subtitle
        accessory = resolved.accessory
        glyph = resolved.glyph
        isInverted = resolved.isInverted
        accessibilityLabel = resolved.label
    }

    private typealias Resolved = (
        title: String, subtitle: String, accessory: Accessory, glyph: Glyph, isInverted: Bool, label: String
    )

    private static func resolve(_ input: Input) -> Resolved {
        switch input.access {
        case .notConfigured:
            return ("Music is unavailable in this version", "Music from other apps still plays", .none, .noteOff, false,
                    "Apple Music is unavailable in this version")
        case .notDetermined:
            return ("Add your music", "Connect Apple Music", .action(.connect), .note, false, "Music not connected")
        case .denied:
            return ("Apple Music is off for 01", "Other apps' music still plays", .action(.settings), .noteOff, false,
                    "Apple Music access is off")
        case .restricted:
            return ("Apple Music is restricted", "Set by Screen Time or a device profile", .none, .lock, false,
                    "Apple Music is restricted")
        case .authorized:
            break
        }
        if let problem = input.problem {
            switch problem {
            case .offline:
                return ("Can't reach Apple Music", "Downloaded songs still play", .action(.retry), .cloudOff, false,
                        "No connection to Apple Music")
            case .needsSubscription:
                return ("Apple Music subscription needed", "Your own library still plays", .action(.choose), .noteOff, false,
                        "Catalog music needs an Apple Music subscription")
            case .itemUnavailable:
                return ("This music isn't available", "Choose another track", .action(.choose), .noteOff, false,
                        "The chosen music isn't available for playback")
            case .playbackFailed:
                return ("Music couldn't play", "Try again or choose another track", .action(.retry), .noteOff, false,
                        "Music couldn't play")
            case .catalogCheckFailed:
                return ("Couldn't check Apple Music", "Your library still plays", .action(.retry), .cloudOff, false,
                        "Couldn't check Apple Music")
            }
        }
        guard let track = input.track else {
            return ("Pick a soundtrack", "01 Mixes or your own music", .action(.choose), .note, false, "No music chosen")
        }
        if input.playback == .interrupted {
            // Status alone never tells 01 why iOS interrupted playback.
            return ("Music interrupted", "Paused by iOS · Your workout isn't affected", .none, .interrupted, false,
                    "Music interrupted by the system")
        }
        let playing = input.playback == .playing
        let artist = track.artist
        let subtitle: String
        if input.lastSetActive {
            subtitle = ["Your last-set track", artist].compactMap { $0 }.joined(separator: " · ")
        } else if !playing {
            subtitle = ["Paused", artist].compactMap { $0 }.joined(separator: " · ")
        } else {
            subtitle = [artist, input.sourceName].compactMap { $0 }.joined(separator: " · ")
        }
        let label = "\(playing ? "Playing" : "Paused"): \(track.title)" + (artist.map { " by \($0)" } ?? "")
        return (track.title, subtitle, .transport(isPlaying: playing), playing ? .playing : .paused,
                input.lastSetActive, label)
    }

    var actionLabel: String? {
        guard case .action(let action) = accessory else { return nil }
        switch action {
        case .connect: return "Connect"
        case .settings: return "Settings"
        case .choose: return "Choose"
        case .retry: return "Retry"
        }
    }
}

enum WorkoutMusicTime {
    /// "3:48"; used by the deck's once-per-second progress while it is open.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func fraction(_ elapsed: TimeInterval, of duration: TimeInterval?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, elapsed / duration))
    }
}

// MARK: - Store

/// Music never owns or mutates workout state. The host supplies a final-set event explicitly.
@MainActor
@Observable
final class WorkoutMusicStore {
    enum Source { case application, system }
    enum LibraryScope: String, CaseIterable, Identifiable {
        case library = "Your library", catalog = "Apple Music"
        var id: String { rawValue }
    }

    private(set) var authorization = MusicAuthorization.currentStatus
    private(set) var canPlayCatalog = false
    private(set) var canBecomeSubscriber = false
    private(set) var source: Source = .application {
        didSet {
            if oldValue != source {
                invalidatePersonalLibrary()
                personalSelection = nil
            }
        }
    }
    private(set) var origin: WorkoutMusicOrigin?
    private(set) var currentEntry: MusicPlayer.Queue.Entry?
    private(set) var currentDuration: TimeInterval?
    private(set) var upcoming: [MusicPlayer.Queue.Entry] = []
    private(set) var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    private(set) var systemNowPlaying: WorkoutMusicLanePresentation.Track?
    private(set) var systemIsPlaying = false
    private(set) var isBusy = false
    private(set) var isSearching = false
    private(set) var songs: [Song] = []
    private(set) var playlists: [Playlist] = []
    private(set) var problem: WorkoutMusicProblem?
    private(set) var searchProblem: String?
    private(set) var personalPlaylists: [Playlist] = []
    private(set) var isSearchingPersonalLibrary = false
    private(set) var personalLibraryProblem: String?
    private(set) var personalLibrarySelectionToken: WorkoutPersonalLibraryFreshness.Token?
    private(set) var personalSelection: WorkoutPersonalPlaylistSelection?
    private(set) var lastSetSong: Song?
    private(set) var lastSetStarted = false
    private(set) var canUndo = false
    private(set) var undoTitle: String?
    private(set) var lastPick: WorkoutMusicLastPick?
    private(set) var recommendations: [Playlist] = []
    private(set) var recommendationProblem: String?
    var keepOutOfHistory = false {
        didSet {
            applyHistoryPreference()
            UserDefaults.standard.set(keepOutOfHistory, forKey: Self.historyKey)
        }
    }

    /// `affectsListeningHistory` is iOS 26.4+; the app targets iOS 17, so the
    /// Recently Played control exists only where the system supports it.
    static var canKeepOutOfHistory: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }
    private(set) var recommendationsEnabled = false

    @ObservationIgnored private let application = ApplicationMusicPlayer.shared
    @ObservationIgnored private let system = SystemMusicPlayer.shared
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var personalFreshness = WorkoutPersonalLibraryFreshness()

    @ObservationIgnored private var finalSetSessionID: UUID?
    @ObservationIgnored private var workoutSessionID: UUID?
    @ObservationIgnored private var undoState: QueueSnapshot?
    @ObservationIgnored private let onOpenedControls: () -> Void
    private static let historyKey = "slick.music.keepOutOfHistory"
    private static let recommendationsKey = "slick.music.recommendationsEnabled"

    init(onOpenedControls: @escaping () -> Void = {}) {
        self.onOpenedControls = onOpenedControls
        let defaults = UserDefaults.standard
        keepOutOfHistory = defaults.bool(forKey: Self.historyKey)
        recommendationsEnabled = defaults.bool(forKey: Self.recommendationsKey)
        lastPick = WorkoutMusicLastPick.decode(defaults.data(forKey: WorkoutMusicLastPick.storageKey))
    }

    /// Explicit opening only, never refresh, player observation or a view's reappearance.
    func recordControlsOpened() {
        onOpenedControls()
    }

    private struct QueueSnapshot {
        let source: Source
        let origin: WorkoutMusicOrigin?
        let entries: [MusicPlayer.Queue.Entry]
        let current: MusicPlayer.Queue.Entry?
        let time: TimeInterval
        let wasPlaying: Bool
        let personalSelection: WorkoutPersonalPlaylistSelection?
    }

    var isConfigured: Bool {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isPlaying: Bool { playbackStatus == .playing }
    var hasAccess: Bool { authorization == .authorized && isConfigured }
    var canControl: Bool { hasAccess && currentEntry != nil && !isBusy && playbackStatus != .interrupted }

    var access: WorkoutMusicAccess {
        guard isConfigured else { return .notConfigured }
        switch authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

    var playback: WorkoutMusicPlayback {
        switch playbackStatus {
        case .playing, .seekingForward, .seekingBackward: return .playing
        case .interrupted: return .interrupted
        case .stopped: return .stopped
        default: return .paused
        }
    }

    var currentTrack: WorkoutMusicLanePresentation.Track? {
        currentEntry.map { .init(title: $0.title, artist: $0.subtitle) }
    }

    var lane: WorkoutMusicLanePresentation {
        WorkoutMusicLanePresentation(.init(
            access: access,
            playback: playback,
            problem: problem,
            track: currentTrack,
            sourceName: laneSourceName,
            lastSetActive: lastSetStarted
        ))
    }

    // Keep existing host/view callers coherent while the Study21 view replacement is unfinished.
    var statusText: String { lane.title }

    private var laneSourceName: String? {
        if let personalQueue = personalQueuePresentation {
            return personalQueue.playlistTitle == currentEntry?.title ? nil : personalQueue.playlistTitle
        }
        return switch origin {
        case .mix(let mix)?: mix.name
        case .musicApp?: "Music app"
        case .picked(let title)?, .lastPick(let title)?, .recommendation(let title)?:
            title == currentEntry?.title ? nil : title
        case nil: nil
        }
    }

    /// Read once per second by the open deck only; never observed.
    var playbackTime: TimeInterval { hasAccess ? player.playbackTime : 0 }

    private var player: MusicPlayer { source == .application ? application : system }

    /// Run in the visible host's task. Cancellation stops subscription observation.
    func observe() async {
        await refreshAccess()
        guard hasAccess else { return }
        for await subscription in MusicSubscription.subscriptionUpdates {
            guard !Task.isCancelled else { return }
            canPlayCatalog = subscription.canPlayCatalogContent
            canBecomeSubscriber = subscription.canBecomeSubscriber
            if problem == .needsSubscription, canPlayCatalog { problem = nil }
        }
    }

    /// Reads state only. Never prepares, resumes or replaces playback.
    func refreshAccess() async {
        // Every explicit refresh supersedes suspended personal requests, including
        // access ABA where the final authorization value is unchanged.
        invalidatePersonalLibrary()
        authorization = MusicAuthorization.currentStatus
        guard hasAccess else {
            personalSelection = nil
            canPlayCatalog = false
            canBecomeSubscriber = false
            currentEntry = nil
            currentDuration = nil
            upcoming = []
            songs = []
            playlists = []
            recommendations = []
            systemNowPlaying = nil
            searchID = UUID()
            isSearching = false
            lastSetSong = nil
            lastSetStarted = false
            undoState = nil
            canUndo = false
            undoTitle = nil
            problem = nil
            subscriptions.removeAll()
            return
        }
        bindPlayer()
        do {
            let subscription = try await MusicSubscription.current
            canPlayCatalog = subscription.canPlayCatalogContent
            canBecomeSubscriber = subscription.canBecomeSubscriber
            if problem == .catalogCheckFailed || (problem == .needsSubscription && canPlayCatalog) { problem = nil }
        } catch {
            canPlayCatalog = false
            problem = .catalogCheckFailed
        }
        refreshPlayback()
    }

    /// The only call site for the OS permission prompt; invoked by Connect.
    func connect() async {
        guard isConfigured, authorization == .notDetermined, !isBusy else { return }
        isBusy = true
        authorization = await MusicAuthorization.request()
        isBusy = false
        await refreshAccess()
    }

    func keepWhatsPlaying() {
        guard hasAccess, !isBusy, source != .system else { return }
        // Selecting the system source does not resume, prepare or replace its queue.
        application.pause()
        source = .system
        origin = .musicApp
        problem = nil
        undoState = nil
        canUndo = false
        undoTitle = nil
        bindPlayer()
        refreshPlayback()
    }

    func togglePlayback() async {
        guard canControl else { return }
        await perform {
            if self.isPlaying { self.player.pause() }
            else { try await self.player.play() }
        }
    }

    func skip(forward: Bool) async {
        guard canControl else { return }
        await perform {
            if forward { try await self.player.skipToNextEntry() }
            else if self.player.playbackTime > 3 { self.player.restartCurrentEntry() }
            else { try await self.player.skipToPreviousEntry() }
        }
    }

    /// Retry exactly what the lane reports; never starts music that wasn't chosen.
    func retry() async {
        switch problem {
        case .catalogCheckFailed:
            await refreshAccess()
        case .offline, .playbackFailed:
            guard hasAccess, currentEntry != nil else { problem = nil; return }
            await perform { try await self.player.play() }
        default:
            problem = nil
        }
    }

    func search(_ term: String, scope: LibraryScope, includePlaylists: Bool = false) async {
        guard hasAccess else { return }
        let requestID = UUID()
        searchID = requestID
        isSearching = true
        searchProblem = nil
        songs = []
        playlists = []
        defer { if searchID == requestID { isSearching = false } }
        do {
            if scope == .catalog {
                guard canPlayCatalog else {
                    searchProblem = "Apple Music catalog playback needs a subscription. Your library still plays."
                    return
                }
                guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let types: [any MusicCatalogSearchable.Type] = includePlaylists ? [Song.self, Playlist.self] : [Song.self]
                var request = MusicCatalogSearchRequest(term: term, types: types)
                request.limit = 25
                let response = try await request.response()
                guard searchID == requestID, hasAccess, !Task.isCancelled else { return }
                songs = Array(response.songs)
                playlists = includePlaylists ? Array(response.playlists) : []
            } else if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var request = MusicLibraryRequest<Song>()
                request.limit = 50
                let response = try await request.response()
                guard searchID == requestID, hasAccess, !Task.isCancelled else { return }
                songs = Array(response.items)
            } else {
                var request = MusicLibrarySearchRequest(term: term, types: [Song.self])
                request.limit = 25
                let response = try await request.response()
                guard searchID == requestID, hasAccess, !Task.isCancelled else { return }
                songs = Array(response.songs)
            }
        } catch {
            guard searchID == requestID, !Task.isCancelled else { return }
            searchProblem = WorkoutMusicProblem.classify(error) == .offline
                ? "Can't reach Apple Music. Downloaded songs in your library still play."
                : "Couldn't load music. Try again."
        }
    }

    // MARK: - Explicit personal library picker

    private var personalContext: WorkoutPersonalLibraryFreshness.Context {
        .init(authorized: hasAccess && MusicAuthorization.currentStatus == .authorized,
              applicationSource: source == .application)
    }

    /// Called immediately when query changes or the explicit picker closes.
    /// Cancellation alone cannot reject an auth/source ABA; the epoch does.
    func invalidatePersonalLibrary() {
        personalFreshness.invalidate()
        personalLibrarySelectionToken = nil
        personalPlaylists = []
        personalLibraryProblem = nil
        isSearchingPersonalLibrary = false
    }

    /// The picker is reachable only by an explicit choose/search action. This
    /// reads authorized library membership and never prompts or starts playback.
    func searchPersonalPlaylists(_ term: String) async {
        guard personalContext.authorized, !Task.isCancelled else { return }
        let token = personalFreshness.begin(in: personalContext)
        personalLibrarySelectionToken = nil
        personalPlaylists = []
        personalLibraryProblem = nil
        isSearchingPersonalLibrary = true
        defer {
            if personalFreshness.accepts(token, in: personalContext, cancelled: false) {
                isSearchingPersonalLibrary = false
            }
        }
        do {
            let items: [Playlist]
            let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                var request = MusicLibraryRequest<Playlist>()
                request.limit = 50
                items = Array(try await request.response().items)
            } else {
                var request = MusicLibrarySearchRequest(term: query, types: [Playlist.self])
                request.limit = 25
                items = Array(try await request.response().playlists)
            }
            guard personalFreshness.accepts(token, in: personalContext, cancelled: Task.isCancelled) else { return }
            var seen = Set<MusicItemID>()
            personalPlaylists = items.filter { seen.insert($0.id).inserted }
            personalLibrarySelectionToken = token
        } catch {
            guard personalFreshness.accepts(token, in: personalContext, cancelled: Task.isCancelled) else { return }
            personalLibraryProblem = WorkoutMusicProblem.classify(error) == .offline
                ? "Can't reach Apple Music. Downloaded songs in your library still play."
                : "Couldn't load playlists. Try again."
        }
    }

    var personalLibraryPresentation: WorkoutPersonalLibraryPresentation {
        let accepted = personalLibrarySelectionToken.map {
            personalFreshness.accepts($0, in: personalContext, cancelled: false)
        } ?? false
        return .init(loading: isSearchingPersonalLibrary, hasAcceptedResults: accepted,
                     resultCount: personalPlaylists.count, hasProblem: personalLibraryProblem != nil)
    }

    func canChoosePersonalPlaylist(_ playlist: Playlist,
                                   token: WorkoutPersonalLibraryFreshness.Token?) -> Bool {
        guard let token, token == personalLibrarySelectionToken,
              let acceptedPlaylist = personalPlaylists.first(where: { $0.id == playlist.id }) else { return false }
        return !isBusy && acceptedPlaylist.playParameters != nil
            && personalFreshness.accepts(token, in: personalContext, cancelled: false)
    }

    /// A library playlist has its own entry point, never the catalog overload.
    /// The actual returned Playlist is used; no relationship fetch or substitution.
    @discardableResult
    func playPersonalPlaylist(_ playlist: Playlist,
                              token: WorkoutPersonalLibraryFreshness.Token?) async -> Bool {
        guard canChoosePersonalPlaylist(playlist, token: token), !Task.isCancelled,
              let acceptedPlaylist = personalPlaylists.first(where: { $0.id == playlist.id }) else { return false }
        return await replaceQueue(ApplicationMusicPlayer.Queue(for: [acceptedPlaylist]),
                                  origin: nil,
                                  personalPlaylist: .init(id: acceptedPlaylist.id.rawValue, title: acceptedPlaylist.name))
    }

    var personalQueuePresentation: WorkoutPersonalQueuePresentation? {
        WorkoutPersonalQueuePresentation(authorized: personalContext.authorized,
            applicationSource: source == .application, selection: personalSelection,
            queueEntryIDs: Array(application.queue.entries).map(\.id),
            currentEntryID: source == .application ? application.queue.currentEntry?.id : nil)
    }

    func personalPlaylistPresentation(_ playlist: Playlist) -> WorkoutPersonalPlaylistPresentation {
        .init(id: playlist.id.rawValue, title: playlist.name,
              queue: personalQueuePresentation, playback: playback)
    }

    func play(_ song: Song, from scope: LibraryScope) async {
        guard song.playParameters != nil else { problem = .itemUnavailable; return }
        if scope == .catalog, !canPlayCatalog { problem = .needsSubscription; return }
        let played = await replaceQueue(ApplicationMusicPlayer.Queue(for: [song]), origin: .picked(song.title))
        if played {
            remember(.init(kind: scope == .catalog ? .catalogSong : .librarySong, id: song.id.rawValue,
                           title: song.title, subtitle: song.artistName, pickedAt: .now))
        }
    }

    func play(_ playlist: Playlist, asRecommendation: Bool = false) async {
        guard canPlayCatalog else { problem = .needsSubscription; return }
        let origin: WorkoutMusicOrigin = asRecommendation ? .recommendation(playlist.name) : .picked(playlist.name)
        let played = await replaceQueue(ApplicationMusicPlayer.Queue(for: [playlist]), origin: origin)
        if played, !asRecommendation {
            remember(.init(kind: .catalogPlaylist, id: playlist.id.rawValue, title: playlist.name,
                           subtitle: playlist.curatorName, pickedAt: .now))
        }
    }

    /// Plays a curated 01 Mix. Unavailable until 01 supplies catalog song IDs.
    func play(_ mix: WorkoutMusicMix) async {
        let ids = (WorkoutMusicMixCatalog.songIDs[mix] ?? []).map { MusicItemID($0) }
        guard hasAccess, !isBusy, !ids.isEmpty else { return }
        guard canPlayCatalog else { problem = .needsSubscription; return }
        isBusy = true
        problem = nil
        let fetched: [Song]
        do {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids)
            let response = try await request.response()
            fetched = ids.compactMap { id in response.items.first { $0.id == id } }
        } catch {
            isBusy = false
            problem = WorkoutMusicProblem.classify(error)
            return
        }
        isBusy = false
        guard !fetched.isEmpty else { problem = .itemUnavailable; return }
        await replaceQueue(ApplicationMusicPlayer.Queue(for: fetched), origin: .mix(mix))
    }

    func playLastPick() async {
        guard let pick = lastPick, hasAccess, !isBusy else { return }
        isBusy = true
        problem = nil
        let queue: ApplicationMusicPlayer.Queue?
        do {
            switch pick.kind {
            case .librarySong:
                var request = MusicLibraryRequest<Song>()
                request.filter(matching: \.id, equalTo: MusicItemID(pick.id))
                queue = try await request.response().items.first.map { ApplicationMusicPlayer.Queue(for: [$0]) }
            case .catalogSong:
                guard canPlayCatalog else { isBusy = false; problem = .needsSubscription; return }
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(pick.id))
                queue = try await request.response().items.first.map { ApplicationMusicPlayer.Queue(for: [$0]) }
            case .catalogPlaylist:
                guard canPlayCatalog else { isBusy = false; problem = .needsSubscription; return }
                let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(pick.id))
                queue = try await request.response().items.first.map { ApplicationMusicPlayer.Queue(for: [$0]) }
            }
        } catch {
            isBusy = false
            problem = WorkoutMusicProblem.classify(error)
            return
        }
        isBusy = false
        guard let queue else { problem = .itemUnavailable; return }
        await replaceQueue(queue, origin: .lastPick(pick.title))
    }

    func forgetLastPick() {
        lastPick = nil
        UserDefaults.standard.removeObject(forKey: WorkoutMusicLastPick.storageKey)
    }

    private func remember(_ pick: WorkoutMusicLastPick) {
        lastPick = pick
        UserDefaults.standard.set(pick.encoded, forKey: WorkoutMusicLastPick.storageKey)
    }

    /// Opt-in. Results are fetched when shown and never stored.
    func setRecommendationsEnabled(_ enabled: Bool) async {
        recommendationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.recommendationsKey)
        recommendations = []
        recommendationProblem = nil
        if enabled { await refreshRecommendations() }
    }

    func refreshRecommendations() async {
        guard recommendationsEnabled, hasAccess else { recommendations = []; return }
        guard canPlayCatalog else {
            recommendations = []
            recommendationProblem = "Apple Music picks need an Apple Music subscription."
            return
        }
        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = 4
            let response = try await request.response()
            guard recommendationsEnabled, hasAccess else { return }
            var seen = Set<MusicItemID>()
            recommendations = response.recommendations.flatMap { Array($0.playlists) }
                .filter { seen.insert($0.id).inserted }
                .prefix(3).map { $0 }
            recommendationProblem = recommendations.isEmpty ? "Apple Music has no picks for you right now." : nil
        } catch {
            recommendations = []
            recommendationProblem = "Apple Music picks aren't available right now."
        }
    }

    /// Returns true only when the new queue actually started playing.
    @discardableResult
    private func replaceQueue(_ queue: ApplicationMusicPlayer.Queue, origin newOrigin: WorkoutMusicOrigin?,
                              personalPlaylist: WorkoutPersonalPlaylistSelection? = nil) async -> Bool {
        guard hasAccess, !isBusy else { return false }
        let previous = snapshot()
        var played = false
        await perform {
            self.source = .application
            self.personalSelection = nil
            self.origin = newOrigin
            self.application.queue = queue
            self.applyHistoryPreference()
            self.bindPlayer()
            let personalPlaybackEpoch = self.personalFreshness.epoch
            do {
                try await self.application.play()
                if var selection = personalPlaylist {
                    guard self.personalFreshness.acceptsPlayback(epoch: personalPlaybackEpoch,
                        in: self.personalContext, cancelled: Task.isCancelled) else {
                        self.restore(previous)
                        return
                    }
                    selection.queueEntryIDs = Array(self.application.queue.entries).map(\.id)
                    self.personalSelection = selection
                }
                played = true
                self.undoState = previous.current == nil ? nil : previous
                self.canUndo = previous.current != nil
                self.undoTitle = previous.current?.title
            } catch {
                // Check freshness before restore/rebind changes the epoch. A stale
                // personal failure must not republish an obsolete playback problem.
                let stalePersonalFailure = personalPlaylist != nil
                    && !self.personalFreshness.acceptsPlayback(epoch: personalPlaybackEpoch,
                        in: self.personalContext, cancelled: Task.isCancelled)
                // Restore the prior queue without claiming playback resumed after failure.
                self.restore(previous)
                if stalePersonalFailure { return }
                throw error
            }
        }
        return played
    }

    func undoVibe() async {
        guard let previous = undoState, !isBusy else { return }
        await perform {
            self.application.pause()
            self.restore(previous)
            if previous.wasPlaying { try await self.player.play() }
            self.undoState = nil
            self.canUndo = false
            self.undoTitle = nil
        }
    }

    func chooseLastSetSong(_ song: Song?) {
        guard hasAccess else { return }
        lastSetSong = song
        lastSetStarted = false
    }

    /// Call after a new workout start succeeds. A selection made on its ready
    /// screen can carry over; restoring a session uses the default reset policy.
    /// Playback itself carries on, and repeated calls for one session do nothing.
    func prepareForWorkout(sessionID: UUID, preservingReadySelection: Bool = false) {
        guard workoutSessionID != sessionID else { return }
        workoutSessionID = sessionID
        if !preservingReadySelection { lastSetSong = nil }
        lastSetStarted = false
        finalSetSessionID = nil
    }

    func finishWorkout() {
        lastSetSong = nil
        lastSetStarted = false
        finalSetSessionID = nil
    }

    /// Host calls once when the actual final planned set becomes current, not on set completion.
    func beginFinalSet(sessionID: UUID) async {
        guard finalSetSessionID != sessionID, let song = lastSetSong, hasAccess, !isBusy else { return }
        // Mark the attempt before suspending, preventing duplicate insertion on host redraws.
        finalSetSessionID = sessionID
        await perform {
            if self.currentEntry == nil {
                self.source = .application
                self.origin = .picked(song.title)
                self.application.queue = ApplicationMusicPlayer.Queue(for: [song])
                self.applyHistoryPreference()
                self.bindPlayer()
            } else if self.source == .application {
                try await self.application.queue.insert(song, position: .afterCurrentEntry)
                try await self.application.skipToNextEntry()
            } else {
                try await self.system.queue.insert(song, position: .afterCurrentEntry)
                try await self.system.skipToNextEntry()
            }
            try await self.player.play()
            if self.finalSetSessionID == sessionID, self.lastSetSong?.id == song.id {
                self.lastSetStarted = true
            }
        }
    }

    func clearProblem() { problem = nil }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        defer { isBusy = false; refreshPlayback() }
        do { try await operation() }
        catch { problem = WorkoutMusicProblem.classify(error) }
    }

    private func snapshot() -> QueueSnapshot {
        QueueSnapshot(source: source, origin: origin, entries: Array(application.queue.entries), current: currentEntry,
                      time: player.playbackTime, wasPlaying: isPlaying,
                      personalSelection: personalSelection)
    }

    private func restore(_ snapshot: QueueSnapshot) {
        source = snapshot.source
        origin = snapshot.origin
        if source == .application {
            application.queue = ApplicationMusicPlayer.Queue(snapshot.entries, startingAt: snapshot.current)
            applyHistoryPreference()
            application.playbackTime = snapshot.time
        }
        bindPlayer()
        personalSelection = hasAccess && source == .application ? snapshot.personalSelection : nil
        if personalQueuePresentation == nil { personalSelection = nil }
    }

    private func applyHistoryPreference() {
        if #available(iOS 26.4, *) {
            application.queue.affectsListeningHistory = !keepOutOfHistory
        }
    }

    private func bindPlayer() {
        invalidatePersonalLibrary()
        if personalQueuePresentation == nil { personalSelection = nil }
        subscriptions.removeAll()
        player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in await Task.yield(); self?.refreshPlayback() }
        }.store(in: &subscriptions)
        if source == .application {
            application.queue.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in await Task.yield(); self?.refreshPlayback() }
            }.store(in: &subscriptions)
        } else {
            system.queue.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in await Task.yield(); self?.refreshPlayback() }
            }.store(in: &subscriptions)
        }
    }

    private func refreshPlayback() {
        guard hasAccess else { return }
        playbackStatus = player.state.playbackStatus
        currentEntry = source == .application ? application.queue.currentEntry : system.queue.currentEntry
        if case .song(let song)? = currentEntry?.item { currentDuration = song.duration } else { currentDuration = nil }
        if source == .application, let currentEntry,
           let index = application.queue.entries.firstIndex(where: { $0.id == currentEntry.id }) {
            upcoming = Array(application.queue.entries.dropFirst(index + 1).prefix(3))
        } else { upcoming = [] }
        // Drop personal attribution when its observed queue/current entry no longer
        // matches. Never derive a song position from a library playlist's tracks.
        if personalQueuePresentation == nil { personalSelection = nil }
        // What the Music app holds, shown on "Keep what's playing". Read only.
        systemNowPlaying = system.queue.currentEntry.map { .init(title: $0.title, artist: $0.subtitle) }
        systemIsPlaying = system.state.playbackStatus == .playing
    }
}
