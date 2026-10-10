import MusicKit
import SwiftUI
import UIKit

// MARK: - Pure deck copy (no MusicKit types, so it is testable)

/// The inline note above the deck's controls. Every problem is explained in place; nothing uses an alert.
struct WorkoutMusicDeckNote: Equatable {
    enum Action: Equatable { case useLibrary, tryAppleMusic, retry, chooseAnother }

    let title: String
    let detail: String
    let actions: [Action]

    init?(problem: WorkoutMusicProblem?, playback: WorkoutMusicPlayback, canBecomeSubscriber: Bool) {
        switch problem {
        case .needsSubscription?:
            title = "What still works"
            detail = "Your Apple Music subscription isn't active on this iPhone, so catalog songs can't play. Songs in your own library still can."
            actions = canBecomeSubscriber ? [.useLibrary, .tryAppleMusic] : [.useLibrary]
        case .offline?:
            title = "Can't reach Apple Music"
            detail = "No connection, so the next song can't load. Downloaded songs in your library still play. Your workout saves on this iPhone."
            actions = [.retry]
        case .catalogCheckFailed?:
            title = "Couldn't check Apple Music"
            detail = "01 couldn't confirm your Apple Music subscription. Songs in your library still play."
            actions = [.retry]
        case .itemUnavailable?:
            title = "This music isn't available"
            detail = "It may not be available where you are, or it was removed from Apple Music. Choose something else."
            actions = [.chooseAnother]
        case .playbackFailed?:
            title = "Music couldn't play"
            detail = "Try again, or choose something else. Your workout isn't affected."
            actions = [.retry, .chooseAnother]
        case nil:
            // Status alone never tells 01 why iOS paused playback, so the note doesn't guess.
            guard playback == .interrupted else { return nil }
            title = "Music interrupted"
            detail = "iOS paused the music. You choose when it comes back. Your workout and rest timer aren't affected."
            actions = []
        }
    }
}

/// "Where this came from" and "Why this?" for the now-playing card.
struct WorkoutMusicSourceNote: Equatable {
    let line: String
    let why: String

    init?(origin: WorkoutMusicOrigin?, lastSetActive: Bool) {
        if lastSetActive {
            line = "Your last-set track, chosen by you"
            why = "You chose this song for your final set. It was queued next when the set began."
            return
        }
        guard let origin else { return nil }
        line = origin.line
        why = origin.why
    }
}

extension WorkoutMusicMix {
    var isReady: Bool { WorkoutMusicMixCatalog.isAvailable(self) }

    var accessibilityDescription: String {
        "01 Mix \(name). \(character). Energy \(energy) of 3." + (isReady ? "" : " Not available yet.")
    }
}

// MARK: - Lane

/// Place directly under the workout progress rail, outside the persistent Log set/rest dock.
/// One row in the same place whatever the state. An explicit tap opens the music sheet.
struct WorkoutMusicLane: View {
    @Environment(\.zeroOneLocalization) private var localization
    let music: WorkoutMusicStore
    var context: WorkoutMusicContext? = nil
    var musicNamespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false
    @AccessibilityFocusState private var laneFocused: Bool


    private var allowsSpatialMotion: Bool {
        !reduceMotion && !voiceOverEnabled && !typeSize.isAccessibilitySize
    }

    var body: some View {
        let lane = music.lane
        let personalLane = WorkoutPersonalMusicLanePresentation(lane: lane, access: music.access,
            problem: music.problem, lastSetActive: music.lastSetStarted,
            track: music.currentTrack, queue: music.personalQueuePresentation, localization: localization)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: toggleDeck) {
                    HStack(spacing: 10) {
                        MusicLaneGlyph(glyph: lane.glyph, artwork: music.currentEntry?.artwork)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: personalLane?.title ?? WorkoutOwnMusicCopy.title(for: lane, access: music.access, problem: music.problem, hasTrack: music.currentTrack != nil, localization: localization))
                                .zoText(.section)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            // Larger text drops the second line; the lane keeps one place and one height class.
                            if !typeSize.isAccessibilitySize {
                                Text(verbatim: personalLane?.subtitle ?? WorkoutOwnMusicCopy.subtitle(for: lane, access: music.access, problem: music.problem, hasTrack: music.currentTrack != nil, localization: localization, track: music.currentTrack, playback: music.playback, lastSetActive: music.lastSetStarted)).zoText(.caption).lineLimit(1).opacity(0.72)
                            }
                        }
                        .contentTransition(.opacity)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(personalLane?.accessibilityLabel ?? WorkoutOwnMusicCopy.accessibilityLabel(for: lane, track: music.currentTrack, localization: localization))
                .accessibilityValue(localization.string(isExpanded ? "Expanded" : "Collapsed"))
                .accessibilityHint(localization.string(isExpanded ? "Closes music controls" : "Opens music controls"))
                .accessibilityFocused($laneFocused)

                accessory(lane)
            }
            .padding(ZOSpace.xs)
            .foregroundStyle(lane.isInverted ? theme.surfacePrimary : theme.textPrimary)
            .background { laneBackground(inverted: lane.isInverted) }
            .clipShape(.rect(cornerRadius: typeSize.isAccessibilitySize ? ZORadius.card : 26))
            .animation(ZOMotion.crossfade(), value: lane)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Music")
            .modifier(WorkoutMusicLaneJoin(namespace: musicNamespace,
                enabled: allowsSpatialMotion))


        }
        .tint(theme.textPrimary)
        .sheet(isPresented: $isExpanded, onDismiss: { laneFocused = true }) {
            NavigationStack {
                ScrollView {
                    WorkoutMusicDeck(music: music, context: context, close: closeDeck)
                        .padding(ZOSpace.cardPadding)
                }
                .scrollIndicators(.hidden)
                .background(theme.surfacePrimary)
            }
            .zoSheet()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: lane.isInverted) { old, new in !old && new }
        .task(id: music.authorization) { await music.observe() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await music.refreshAccess() } }
        }
        .onChange(of: music.playback) { old, new in
            if new == .interrupted, old != .interrupted { announce(localization.string("Music interrupted.")) }
        }
    }

    @ViewBuilder
    private func accessory(_ lane: WorkoutMusicLanePresentation) -> some View {
        switch lane.accessory {
        case .transport(let isPlaying):
            MusicTransportButton(label: isPlaying ? "Pause music" : "Play music",
                                 symbol: isPlaying ? "pause.fill" : "play.fill",
                                 enabled: music.canControl) {
                await music.togglePlayback()
            }
            MusicTransportButton(label: "Next song", symbol: "forward.end.fill", enabled: music.canControl) {
                await music.skip(forward: true)
                announceCurrentSong(music)
            }
        case .action(let action):
            if let title = lane.actionLabel {
                Button(localization.string(title)) { perform(action) }
                    .zoText(.label)
                    .padding(.horizontal, ZOSpace.l)
                    .frame(minHeight: ZOSpace.hitTarget)
                    .background(lane.isInverted ? theme.surfacePrimary.opacity(0.2) : theme.surfaceSecondary, in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(music.isBusy)
            }
        case .none:
            EmptyView()
        }
    }

    /// The last-set track reveals the inverted lane from leading to trailing; Reduce Motion crossfades.
    private func laneBackground(inverted: Bool) -> some View {
        ZStack(alignment: .leading) {
            theme.surfacePrimary
            theme.textPrimary
                .scaleEffect(x: reduceMotion || inverted ? 1 : 0, y: 1, anchor: .leading)
                .opacity(reduceMotion && !inverted ? 0 : 1)
                .animation(reduceMotion ? ZOMotion.crossfade() : ZOMotion.carry(ZOMotion.shape),
                           value: inverted)
        }
    }

    private func perform(_ action: WorkoutMusicLanePresentation.Action) {
        switch action {
        case .connect, .choose:
            // Connect opens the explanation first; only its Connect button asks iOS.
            if !isExpanded { toggleDeck() }
        case .settings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .retry:
            Task { await music.retry() }
        }
    }

    private func toggleDeck() {
        let opening = !isExpanded
        if opening { music.recordControlsOpened() }
        let animation: Animation = !allowsSpatialMotion
            ? ZOMotion.crossfade(panel: true)
            : (opening ? ZOMotion.land(ZOMotion.quick) : ZOMotion.leave(ZOMotion.quick))
        withAnimation(animation) { isExpanded = opening }
        if !opening { laneFocused = true }
    }

    private func closeDeck() {
        withAnimation(!allowsSpatialMotion ? ZOMotion.crossfade(panel: true) : ZOMotion.leave(ZOMotion.quick)) {
            isExpanded = false
        }
        laneFocused = true
    }
}

// MARK: - Standalone and ready screen

/// Standalone destination or ready-screen content. Does not start a workout or play automatically.
struct WorkoutMusicView: View {
    let music: WorkoutMusicStore
    var context: WorkoutMusicContext? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MusicSelection?
    @State private var showsOffer = false


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your music.")
                        .zoText(.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("From your Apple Music library. Your workout works the same without it.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }

                if music.access != .authorized {
                    MusicAccessPanel(music: music)
                } else {
                    MusicProblemBanner(music: music, selection: $selection, showsOffer: $showsOffer)
                    if let entry = music.currentEntry {
                        MusicNowPlaying(music: music, entry: entry)
                            .padding(ZOSpace.cardPadding)
                            .background(theme.surfacePrimary, in: ZORadius.cardShape)
                    }
                    MusicLibrarySearchButton { selection = .personalPlaylists }
                    MusicSourceRows(music: music, selection: $selection, inWorkout: false)
                    MusicExternalPlayerNote()
                    DisclosureGroup("More music options") {
                        VStack(alignment: .leading, spacing: ZOSpace.l) {
                            MusicRecommendations(music: music)
                            MusicWorkoutOptions(music: music, selection: $selection)
                        }
                        .padding(.top, ZOSpace.m)
                    }
                    .zoText(.section)
                }
            }
            .padding(ZOSpace.screenMargin)
        }
        .background(theme.backgroundPrimary)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
        .navigationTitle("Music")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selection) { sheetSelection in
            Group {
                if sheetSelection == .personalPlaylists {
                    MusicPersonalPlaylistSelectionView(music: music) {
                        MusicSelectionView(music: music, selection: .song)
                    }
                } else {
                    MusicSelectionView(music: music, selection: sheetSelection)
                }
            }
            .zoSheet()
        }
        .musicSubscriptionOffer(isPresented: $showsOffer, options: .playMusicOffer)
        .task(id: music.authorization) { await music.observe() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await music.refreshAccess() } }
        }
    }
}

// MARK: - Deck

/// The workout music sheet. Opened only by an explicit tap.
private struct WorkoutMusicDeck: View {
    let music: WorkoutMusicStore
    let context: WorkoutMusicContext?
    let close: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @State private var selection: MusicSelection?
    @State private var showsOffer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Music").zoText(.caption)
                Spacer()
                Button("Done", action: close)
                    .frame(minHeight: ZOSpace.hitTarget)
                    .accessibilityLabel("Close music controls")
            }
            if music.access != .authorized {
                MusicAccessPanel(music: music)
            } else {
                MusicProblemBanner(music: music, selection: $selection, showsOffer: $showsOffer)
                let catalogBlocked = music.problem == .needsSubscription
                if let entry = music.currentEntry, !catalogBlocked {
                    MusicNowPlaying(music: music, entry: entry)
                } else if music.currentEntry == nil, !catalogBlocked {
                    Text("Your music.").zoText(.title)
                }
                MusicLibrarySearchButton { selection = .personalPlaylists }
                MusicSourceRows(music: music, selection: $selection, inWorkout: true)
                MusicExternalPlayerNote()
                DisclosureGroup("More music options") {
                    MusicWorkoutOptions(music: music, selection: $selection)
                        .padding(.top, ZOSpace.m)
                }
                .zoText(.section)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
        .sheet(item: $selection) { sheetSelection in
            Group {
                if sheetSelection == .personalPlaylists {
                    MusicPersonalPlaylistSelectionView(music: music) {
                        MusicSelectionView(music: music, selection: .song)
                    }
                } else {
                    MusicSelectionView(music: music, selection: sheetSelection)
                }
            }
            .zoSheet()
        }
        .musicSubscriptionOffer(isPresented: $showsOffer, options: .playMusicOffer)
    }
}

private extension MusicSubscriptionOffer.Options {
    static var playMusicOffer: Self {
        var options = Self.default
        options.messageIdentifier = .playMusic
        return options
    }
}

// MARK: - Deck sections

private struct MusicAccessPanel: View {
    @Environment(\.zeroOneLocalization) private var localization
    let music: WorkoutMusicStore
    @Environment(\.openURL) private var openURL
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch music.access {
            case .notDetermined:
                Text("Train to your own music.").zoText(.title)
                VStack(alignment: .leading, spacing: 10) {
                    bullet("play.fill", "Play Apple Music without leaving the workout.")
                    bullet("forward.end.fill", "Skip, pause or change the music between sets.")
                    bullet("flag.checkered", "Save one song for your last set.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What 01 can see").zoText(.label)
                    Text("Connecting lets 01 play Apple Music and show what's playing. 01 reads your library only when you search it to choose music, and never reads your listening history unless you turn on Apple Music picks.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Button {
                    Task { await music.connect() }
                } label: {
                    Text("Connect Apple Music")
                        .zoText(.section)
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(music.isBusy)
                Text("Music from other apps still plays alongside 01.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            case .denied:
                Text("Apple Music is off for 01").zoText(.title)
                Text("You turned off access. To use Apple Music in workouts, allow it in Settings. Music from other apps still plays alongside 01; control it from Control Center.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: ZOSpace.hitTarget)
            case .restricted:
                Text("Apple Music is restricted on this iPhone").zoText(.title)
                Text("Screen Time or a device profile limits music access. 01 can't change that. Your workout works the same without it.")
            case .notConfigured:
                Text("Music is unavailable in this version").zoText(.title)
                Text("You can keep training with music from another app.")
            case .authorized:
                EmptyView()
            }
        }
        .zoText(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.cardPadding)
        .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.card))
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).zoIcon(ZOIcon.row).accessibilityHidden(true)
            Text(verbatim: localization.string(text))
        }
    }
}

private struct MusicProblemBanner: View {
    @Environment(\.zeroOneLocalization) private var localization
    let music: WorkoutMusicStore
    @Binding var selection: MusicSelection?
    @Binding var showsOffer: Bool
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        if let note = WorkoutMusicDeckNote(problem: music.problem, playback: music.playback,
                                           canBecomeSubscriber: music.canBecomeSubscriber) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: localization.string(note.title)).zoText(.label)
                Text(verbatim: localization.string(note.detail)).zoText(.body).foregroundStyle(theme.textSecondary)
                if !note.actions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { buttons(note.actions) }
                        VStack(alignment: .leading, spacing: 8) { buttons(note.actions) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.control))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func buttons(_ actions: [WorkoutMusicDeckNote.Action]) -> some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .useLibrary:
                MusicCapsuleButton(title: "Use my library", prominent: true) { selection = .song }
            case .tryAppleMusic:
                MusicCapsuleButton(title: "Try Apple Music", prominent: false) { showsOffer = true }
            case .retry:
                MusicCapsuleButton(title: "Retry", prominent: true) { Task { await music.retry() } }
                    .disabled(music.isBusy)
            case .chooseAnother:
                MusicCapsuleButton(title: "Choose something else", prominent: false) {
                    music.clearProblem()
                    selection = .song
                }
            }
        }
    }
}

private struct MusicNowPlaying: View {
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    let music: WorkoutMusicStore
    let entry: MusicPlayer.Queue.Entry
    @State private var showsWhy = false

    var body: some View {
        let note = WorkoutMusicSourceNote(origin: music.origin, lastSetActive: music.lastSetStarted)
        let personalQueue = music.lastSetStarted ? nil : music.personalQueuePresentation
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                MusicArtwork(artwork: entry.artwork, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .zoText(.section)
                        .contentTransition(.opacity)
                    if let subtitle = entry.subtitle {
                        Text(subtitle).zoText(.body).foregroundStyle(theme.textSecondary)
                    }
                    if note != nil || personalQueue != nil {
                        Text(verbatim: personalQueue.map { WorkoutPersonalMusicCopy.originLine($0, localization: localization) }
                             ?? WorkoutMusicOriginCopy.line(origin: music.origin, lastSetActive: music.lastSetStarted, localization: localization)).zoText(.caption).foregroundStyle(theme.textSecondary)
                        if let personalQueue {
                            Text(verbatim: WorkoutPersonalMusicCopy.queueLine(personalQueue, localization: localization))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                        Button(localization.string(showsWhy ? "Hide why" : "Why this?")) {
                            withAnimation(ZOMotion.crossfade()) { showsWhy.toggle() }
                        }
                        .zoText(.caption)
                        .frame(minHeight: ZOSpace.hitTarget)
                        .accessibilityValue(localization.string(showsWhy ? "Expanded" : "Collapsed"))
                    }
                }
            }
            if showsWhy, note != nil || personalQueue != nil {
                Text(verbatim: personalQueue != nil ? WorkoutPersonalMusicCopy.why(localization: localization)
                     : WorkoutMusicOriginCopy.why(origin: music.origin, lastSetActive: music.lastSetStarted, localization: localization)).zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            MusicProgress(music: music)
            HStack(spacing: 24) {
                Spacer()
                MusicTransportButton(label: "Previous song", symbol: "backward.end.fill", enabled: music.canControl) {
                    await music.skip(forward: false)
                    announceCurrentSong(music)
                }
                MusicTransportButton(label: music.isPlaying ? "Pause music" : "Play music",
                                     symbol: music.isPlaying ? "pause.fill" : "play.fill",
                                     enabled: music.canControl) {
                    await music.togglePlayback()
                }
                MusicTransportButton(label: "Next song", symbol: "forward.end.fill", enabled: music.canControl) {
                    await music.skip(forward: true)
                    announceCurrentSong(music)
                }
                Spacer()
            }
            if music.source == .system {
                Text("Up next lives in the Music app. 01 can see only the current song.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else if let next = music.upcoming.first {
                HStack(spacing: 10) {
                    MusicArtwork(artwork: next.artwork, size: 32)
                    Text("Up next · \(next.title)").zoText(.body).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(ZOMotion.crossfade(), value: entry.id)
    }
}

/// Updates once per second while the controls are open; nothing animates while they are closed.
private struct MusicProgress: View {
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    let music: WorkoutMusicStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = music.playbackTime
            let duration = music.currentDuration
            VStack(spacing: 4) {
                if let fraction = WorkoutMusicTime.fraction(elapsed, of: duration) {
                    ProgressView(value: fraction)
                }
                HStack {
                    Text(WorkoutMusicTime.clock(elapsed))
                    Spacer()
                    if let duration {
                        Text("-" + WorkoutMusicTime.clock(duration - elapsed))
                    }
                }
                .zoText(.caption).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(duration.map { localization.format("%1$@ of %2$@", .text(WorkoutMusicTime.clock(elapsed)), .text(WorkoutMusicTime.clock($0))) }
                                ?? WorkoutMusicTime.clock(elapsed))
        }
    }
}

/// Your music, the Music app's queue, and (on the ready screen) your last pick.
private struct MusicSourceRows: View {
    @Environment(\.zeroOneLocalization) private var localization
    let music: WorkoutMusicStore
    @Binding var selection: MusicSelection?
    let inWorkout: Bool
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            MusicRow(title: localization.string("Your music"),
                     detail: localization.string(music.canPlayCatalog ? "Search your library, or songs and playlists in Apple Music" : "Search songs from your library"),
                     note: localization.string("Your library is read when you search it."),
                     trailing: "Choose") {
                selection = .personalPlaylists
            }
            if let now = music.systemNowPlaying, music.source != .system {
                Divider()
                MusicRow(title: localization.string(inWorkout ? "Back to the Music app" : "Keep what's playing"),
                         detail: [now.title, now.artist].compactMap { $0 }.joined(separator: " · "),
                         note: localization.string(music.systemIsPlaying ? "Playing now in the Music app" : "In the Music app"),
                         trailing: "Use") {
                    music.keepWhatsPlaying()
                }
            }
            if !inWorkout, let pick = music.lastPick {
                Divider()
                MusicRow(title: pick.title,
                         detail: localization.format("Your last pick in 01 · %1$@", .text(pick.pickedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(localization.locale)))),
                         note: localization.string("Remembered by 01 on this iPhone because you picked it"),
                         trailing: "Play") {
                    Task { await music.playLastPick() }
                }
                Button("Forget last pick") { music.forgetLastPick() }
                    .zoText(.caption)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.card))
        .disabled(music.isBusy)
    }
}

/// Opt-in only. Fetched when shown and never stored.
private struct MusicRecommendations: View {
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    let music: WorkoutMusicStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { music.recommendationsEnabled },
                set: { enabled in Task { await music.setRecommendationsEnabled(enabled) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Music picks for me").zoText(.section)
                    Text("Uses your Apple Music listening. Off until you turn it on. 01 fetches them each time and doesn't store them.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            if music.recommendationsEnabled {
                ForEach(music.recommendations) { playlist in
                    Button {
                        Task { await music.play(playlist, asRecommendation: true) }
                    } label: {
                        HStack(spacing: 12) {
                            MusicArtwork(artwork: playlist.artwork, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).zoText(.section)
                                Text("From Apple Music").zoText(.caption).foregroundStyle(theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Text("Play").zoText(.label)
                        }
                        .frame(minHeight: ZOSpace.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(music.isBusy)
                }
                if let problem = music.recommendationProblem {
                    Text(verbatim: localization.string(problem)).zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .task { if music.recommendationsEnabled { await music.refreshRecommendations() } }
    }
}

/// Last-set track and Recently Played.
private struct MusicWorkoutOptions: View {
    @Environment(\.zeroOneLocalization) private var localization
    @Bindable var music: WorkoutMusicStore
    @Binding var selection: MusicSelection?
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicRow(title: localization.string("Last-set track"),
                     detail: music.lastSetSong.map { localization.format("“%1$@” starts when your final set begins", .text($0.title)) }
                        ?? localization.string("Save one song for your final set"),
                     note: nil,
                     trailing: music.lastSetSong == nil ? "Choose" : "Change") {
                selection = .lastSet
            }
            if music.lastSetSong != nil {
                Button("Remove last-set track") { music.chooseLastSetSong(nil) }
                    .zoText(.caption)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if WorkoutMusicStore.canKeepOutOfHistory, music.source == .application {
                Divider()
                Toggle(isOn: $music.keepOutOfHistory) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep out of Recently Played").zoText(.section)
                        Text("Workout music won't show in your Apple Music history.")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .padding(.vertical, 10)
            } else if music.source == .system {
                Divider()
                Text("Recently Played follows your Music app settings.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 12)
        .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.card))
        .disabled(music.isBusy)
    }
}

// MARK: - Choosing music

private enum MusicSelection: Identifiable {
    case song, lastSet, personalPlaylists
    var id: String {
        switch self { case .song: "song"; case .lastSet: "lastSet"; case .personalPlaylists: "personalPlaylists" }
    }
    var title: String { self == .lastSet ? "Last-set track" : "Your music" }
}

private struct MusicSelectionView: View {
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    let music: WorkoutMusicStore
    let selection: MusicSelection
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: WorkoutMusicStore.LibraryScope = .library

    /// Playlists can be the soundtrack; the last-set track is always one song.
    private var includesPlaylists: Bool { selection == .song && scope == .catalog }

    var body: some View {
        NavigationStack {
            List {
                ZOSegmentedControl("Source", selection: $scope, options: WorkoutMusicStore.LibraryScope.allCases.map { ZOSegment(value: $0, label: Text(verbatim: localization.string($0.rawValue))) })
                if music.isSearching { ProgressView("Finding music…") }
                if let problem = music.searchProblem {
                    Text(verbatim: localization.string(problem)).foregroundStyle(theme.textSecondary)
                    Button("Try again") {
                        Task { await music.search(query, scope: scope, includePlaylists: includesPlaylists) }
                    }
                    .disabled(music.isSearching)
                }
                if music.problem != nil { Text(verbatim: localization.string(music.lane.title)).foregroundStyle(theme.textSecondary) }
                if !music.isSearching, music.songs.isEmpty, music.playlists.isEmpty, music.searchProblem == nil {
                    Text(verbatim: localization.string(scope == .catalog && query.isEmpty
                         ? "Search Apple Music to get started."
                         : "No music found. Try another search or add songs in Music."))
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(music.songs) { song in
                    Button {
                        Task {
                            if selection == .lastSet {
                                music.chooseLastSetSong(song)
                                dismiss()
                            } else {
                                await music.play(song, from: scope)
                                if music.problem == nil { dismiss() }
                            }
                        }
                    } label: {
                        HStack {
                            MusicArtwork(artwork: song.artwork, size: 44)
                            VStack(alignment: .leading) {
                                Text(song.title).zoText(.section)
                                Text(song.artistName).zoText(.caption).foregroundStyle(theme.textSecondary)
                            }
                        }
                        .frame(minHeight: ZOSpace.hitTarget)
                    }
                    .disabled(music.isBusy || song.playParameters == nil)
                }
                if includesPlaylists {
                    ForEach(music.playlists) { playlist in
                        Button {
                            Task {
                                await music.play(playlist)
                                if music.problem == nil { dismiss() }
                            }
                        } label: {
                            HStack {
                                MusicArtwork(artwork: playlist.artwork, size: 44)
                                VStack(alignment: .leading) {
                                    Text(playlist.name).zoText(.section)
                                    Text("Apple Music playlist").zoText(.caption).foregroundStyle(theme.textSecondary)
                                }
                            }
                            .frame(minHeight: ZOSpace.hitTarget)
                        }
                        .disabled(music.isBusy)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surfacePrimary)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle(localization.string(selection.title))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(verbatim: localization.string(includesPlaylists ? "Search songs and playlists" : "Search songs")))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(scope.rawValue)|\(query)") {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await music.search(query, scope: scope, includePlaylists: includesPlaylists)
            }
        }
    }
}

// MARK: - Shared pieces

/// The host animates its actual route change with this timing. Only the lane row
/// participates, so an expanded deck never covers or carries the workout dock.
enum WorkoutMusicJoinTransition {
    static let duration: TimeInterval = 0.480

    static func animation(spatialMotion: Bool) -> Animation {
        spatialMotion ? ZOMotion.carry(ZOMotion.beat) : ZOMotion.crossfade()
    }
}

private struct WorkoutMusicLaneJoin: ViewModifier {
    let namespace: Namespace.ID?
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let namespace {
            content.matchedGeometryEffect(id: "workoutMusicLane", in: namespace)
        } else {
            content
        }
    }
}

private struct MusicLibrarySearchButton: View {
    let action: () -> Void
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Button(action: action) {
            Label("Search your library", systemImage: "magnifyingglass")
                .labelStyle(ZOIconLabelStyle())
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight, alignment: .leading)
                .padding(.horizontal, ZOSpace.l)
                .background(theme.surfaceSecondary, in: ZORadius.cardShape)
                .overlay { ZORadius.cardShape.stroke(theme.strokeSubtle, lineWidth: ZOStroke.hairline) }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your library search. Music starts only after you choose a result.")
    }
}

private struct MusicExternalPlayerNote: View {
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        Text("Using Spotify or another app? Just play it there. Other apps keep their own controls in Control Center.")
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MusicRow: View {
    @Environment(\.zeroOneTheme) private var theme
    let title: String
    let detail: String
    let note: String?
    let trailing: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).zoText(.section)
                    Text(verbatim: detail).zoText(.caption).foregroundStyle(theme.textSecondary)
                    if let note {
                        Text(verbatim: note).zoText(.mini).foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Text(LocalizedStringKey(trailing)).zoText(.label)
            }
            .padding(.vertical, 12)
            .frame(minHeight: ZOSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MusicNotice: View {
    @Environment(\.zeroOneTheme) private var theme
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).zoText(.label)
            Text(detail).zoText(.caption).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MusicCapsuleButton: View {
    @Environment(\.zeroOneLocalization) private var localization
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(localization.string(title), action: action)
            .buttonStyle(ZOButtonStyle(prominent ? .ink : .secondary))
    }
}

private struct MusicLaneGlyph: View {
    @Environment(\.zeroOneTheme) private var theme
    let glyph: WorkoutMusicLanePresentation.Glyph
    let artwork: Artwork?

    var body: some View {
        Group {
            switch glyph {
            case .playing, .paused:
                MusicArtwork(artwork: artwork, size: 40)
            default:
                Image(systemName: symbol)
                    .zoIcon(ZOIcon.row)
                    .frame(width: 40, height: 40)
                    .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.small))
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch glyph {
        case .note, .playing, .paused: "music.note"
        case .noteOff: "speaker.slash"
        case .lock: "lock"
        case .cloudOff: "icloud.slash"
        case .interrupted: "pause.circle"
        }
    }
}

private struct MusicTransportButton: View {
    @Environment(\.zeroOneLocalization) private var localization
    let label: String
    let symbol: String
    let enabled: Bool
    let action: () async -> Void

    var body: some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).zoIcon(ZOIcon.row).frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(localization.string(label))
    }
}

private struct MusicArtwork: View {
    @Environment(\.zeroOneTheme) private var theme
    let artwork: Artwork?
    let size: CGFloat

    var body: some View {
        Image(systemName: "music.note")
            .zoIcon(ZOIcon.row)
            .foregroundStyle(theme.textPrimary)
            .frame(width: size, height: size)
            .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.small))
        .accessibilityHidden(true)
    }
}

/// Announces only the person's own skips, never automatic track changes during a set.
@MainActor
private func announceCurrentSong(_ music: WorkoutMusicStore) {
    guard let track = music.currentTrack else { return }
    announce([track.title, track.artist].compactMap { $0 }.joined(separator: ", "))
}

@MainActor
private func announce(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}
