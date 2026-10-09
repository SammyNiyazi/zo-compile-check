import MusicKit
import SwiftUI

/// Presented only from the person's explicit Your music / library search tap.
/// Appearance reads the already-authorized library; it never connects or plays.
struct MusicPersonalPlaylistSelectionView<SongPicker: View>: View {
    let music: WorkoutMusicStore
    @ViewBuilder let songPicker: () -> SongPicker
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showsSongPicker = false

    private struct RequestKey: Equatable {
        let query: String
        let songsPresented: Bool
    }

    // Invalidate in the binding setter, before the debounced replacement task.
    // An old result cannot be tapped during the debounce interval.
    private var searchText: Binding<String> {
        Binding(get: { query }, set: { value in
            guard value != query else { return }
            music.invalidatePersonalLibrary()
            query = value
        })
    }

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Your music.").zoText(.title)
                    Text("From your Apple Music library. Your workout works the same without it.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                .padding(.vertical, ZOSpace.m)
                .listRowSeparator(.hidden)
                .listRowBackground(theme.surfacePrimary)

                if music.access != .authorized {
                    Text(verbatim: localization.string(music.lane.title))
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                } else {
                    if music.isSearchingPersonalLibrary {
                        ProgressView("Finding music…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let problem = music.personalLibraryProblem {
                        Text(verbatim: localization.string(problem))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    if music.personalLibraryPresentation.state == .empty {
                        Text("No playlists found. Try another search or add playlists in Music.")
                            .zoText(.body).foregroundStyle(theme.textSecondary)
                    }
                    if music.personalLibraryPresentation.state == .idle {
                        Text("Refresh to load your playlists.")
                            .zoText(.body).foregroundStyle(theme.textSecondary)
                    }
                    ForEach(music.personalPlaylists) { playlist in
                        let token = music.personalLibrarySelectionToken
                        MusicPersonalPlaylistRow(
                            presentation: music.personalPlaylistPresentation(playlist),
                            enabled: music.canChoosePersonalPlaylist(playlist, token: token)) {
                            Task {
                                if await music.playPersonalPlaylist(playlist, token: token) { dismiss() }
                            }
                        }
                        .listRowBackground(theme.surfacePrimary)
                    }
                    Button("Refresh playlists") {
                        music.invalidatePersonalLibrary()
                        Task { await music.searchPersonalPlaylists(query) }
                    }
                    .zoText(.label)
                    .frame(minHeight: ZOSpace.hitTarget)
                    .disabled(music.isSearchingPersonalLibrary || music.isBusy)
                }
                if let problem = music.problem {
                    Text(verbatim: localization.string(WorkoutMusicLanePresentation(.init(
                        access: music.access, problem: problem)).title))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                Button("Search songs and Apple Music") {
                    music.invalidatePersonalLibrary()
                    showsSongPicker = true
                }
                .zoText(.label)
                .frame(minHeight: ZOSpace.hitTarget)
                .disabled(music.isBusy)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.surfacePrimary)
            .foregroundStyle(theme.textPrimary)
            .tint(theme.textPrimary)
            .navigationTitle(localization.string("Music"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: searchText, prompt: Text(verbatim: localization.string("Search your library")))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: RequestKey(query: query, songsPresented: showsSongPicker)) {
                guard !showsSongPicker else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await music.searchPersonalPlaylists(query)
            }
            .onDisappear { music.invalidatePersonalLibrary() }
            .sheet(isPresented: $showsSongPicker) {
                // The existing song/catalog/last-set selection implementation
                // remains in WorkoutMusicViews.swift; only its visibility changes.
                songPicker().zoSheet()
            }
        }
    }
}

private struct MusicPersonalPlaylistRow: View {
    let presentation: WorkoutPersonalPlaylistPresentation
    let enabled: Bool
    let action: () -> Void
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZOSpace.m) {
                Image(systemName: "music.note")
                    .zoIcon(ZOIcon.row)
                    .frame(width: 40, height: 40)
                    .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.small))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text(verbatim: presentation.title).zoText(.section)
                    Text(verbatim: localization.string(presentation.state == .paused
                        ? "In your library · Paused" : "In your library"))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: ZOSpace.s)
                if presentation.state == .playing {
                    Text("Playing").zoText(.mini)
                        .padding(.horizontal, ZOSpace.s).padding(.vertical, ZOSpace.xs)
                        .foregroundStyle(theme.surfacePrimary)
                        .background(theme.textPrimary, in: Capsule())
                } else {
                    Image(systemName: "play.fill").zoIcon(ZOIcon.inline).accessibilityHidden(true)
                }
            }
            .frame(minHeight: ZOSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityHint(localization.string("Plays this playlist from your library."))
    }
}
