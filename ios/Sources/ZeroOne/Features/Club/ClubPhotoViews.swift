import PhotosUI
import SwiftUI

/// A Club photo thumbnail (640 px file): loaded once per iPhone from the cache, tap for the full photo.
@MainActor
struct ClubPhotoThumb: View {
    let club: ClubStore
    let key: ClubPhotoKey
    var onOpen: () -> Void = {}
    @Environment(\.zeroOneTheme) private var theme
    @State private var image: UIImage?

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                theme.surfaceSecondary
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo"))
        .task(id: key) { image = await club.photo(key, thumbnail: true, maxSide: 640) }
    }
}

/// One to four photos under a post: one wide, or a two-column grid.
@MainActor
struct ClubPhotoGrid: View {
    let club: ClubStore
    let photos: [ClubPhotoKey]
    @State private var opened: Int?

    var body: some View {
        Group {
            if photos.count == 1 {
                ClubPhotoThumb(club: club, key: photos[0]) { opened = 0 }
                    .aspectRatio(4 / 3, contentMode: .fit)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, key in
                        ClubPhotoThumb(club: club, key: key) { opened = index }
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fullScreenCover(item: Binding(get: { opened.map(ClubPhotoViewer.Start.init) }, set: { opened = $0?.index })) { start in
            ClubPhotoViewer(club: club, photos: photos, index: start.index)
        }
    }
}

/// Full photos (1600 px files), swipe between them. Downloaded only when opened.
@MainActor
struct ClubPhotoViewer: View {
    struct Start: Identifiable { let index: Int; var id: Int { index } }

    let club: ClubStore
    let photos: [ClubPhotoKey]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { offset, key in
                    ClubFullPhoto(club: club, key: key).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel(Text("Close"))
            .padding()
        }
    }
}

@MainActor
private struct ClubFullPhoto: View {
    let club: ClubStore
    let key: ClubPhotoKey
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) { image = await club.photo(key, thumbnail: false, maxSide: 1600) }
    }
}

enum ClubPhotoPicking {
    /// The picked photo's original bytes; they are shrunk and stripped before anything is uploaded.
    static func data(_ item: PhotosPickerItem) async -> Data? {
        try? await item.loadTransferable(type: Data.self)
    }
}
