import SwiftUI
import UIKit

/// Reads only 01-owned display copies. Dates are facts; no weight, pose or reminder is inferred.
struct ProgressPhotoComparisonView: View {
    let repository: ProgressPhotoRepository
    let onShare: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.photoComparisonShareHostAuthority) private var photoShareAuthority
    @State private var earlierID: UUID?
    @State private var laterID: UUID?
    @State private var split = 0.5
    @State private var sharingUnavailable = false

    init(
        repository: ProgressPhotoRepository,
        onShare: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)? = nil
    ) {
        self.repository = repository
        self.onShare = onShare
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    private var records: [ProgressPhotoRecord] {
        repository.entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var pair: ProgressPhotoPair? {
        ProgressPhotoPair.resolve(records: records, firstID: earlierID, secondID: laterID)
    }
    private var selectedPair: ProgressPhotoPair? {
        ProgressPhotoPair.selected(records: records, firstID: earlierID, secondID: laterID)
    }
    private func readable(_ record: ProgressPhotoRecord) -> Bool {
        guard let data = repository.imageData(for: record) else { return false }
        return UIImage(data: data) != nil
    }
    private var shareablePair: ProgressPhotoPair? {
        guard onShare != nil else { return nil }
        return selectedPair?.validatedForSharing(records: records,
            isAvailable: repository.isAvailable, isReadable: readable)
    }
    private func dateDescription(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide).year().hour().minute().second()
        style.locale = localization.locale
        style.calendar = calendar
        style.timeZone = timeZone
        return date.formatted(style)
    }
    private func photoDescription(_ record: ProgressPhotoRecord, first: Bool) -> String {
        localization.format("%1$@, %2$@, %3$@",
            .text(localization.string(photoLabel(first: first))),
            .text(dateDescription(record.createdAt)),
            .text(localization.string(record.label.title)))
    }
    private func photoLabel(first: Bool) -> String {
        pair?.labelKey(firstSlot: first) ?? (first ? "First photo" : "Second photo")
    }

    var body: some View {
        if let pair {
            let earlier = pair.first
            let later = pair.second
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                if earlier.id == later.id {
                    Text("Choose two different photos to compare.").zoText(.body).foregroundStyle(secondaryInk)
                } else if let firstData = repository.imageData(for: earlier), let firstImage = UIImage(data: firstData),
                          let lastData = repository.imageData(for: later), let lastImage = UIImage(data: lastData) {
                    GeometryReader { geometry in
                        ZStack {
                            photo(firstImage, size: geometry.size)
                            photo(lastImage, size: geometry.size)
                                .mask(alignment: .trailing) {
                                    Rectangle().frame(width: geometry.size.width * (1 - split))
                                }
                            HStack {
                                dateChip(earlier.createdAt)
                                Spacer(minLength: ZOSpace.s)
                                dateChip(later.createdAt)
                            }.padding(ZOSpace.s).frame(maxHeight: .infinity, alignment: .bottom)
                                .accessibilityHidden(true)
                            Rectangle().fill(ZOColor.resolved(ZOColor.inkPrimary, in: .dark)).frame(width: 2)
                                .position(x: geometry.size.width * split, y: geometry.size.height / 2)
                            HStack(spacing: 0) {
                                Image(systemName: "chevron.left").zoIcon(14)
                                Image(systemName: "chevron.right").zoIcon(14)
                            }
                            .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .light))
                            .frame(width: 44, height: 44).background(ZOColor.resolved(ZOColor.inkPrimary, in: .dark), in: Circle())
                            .position(x: geometry.size.width * split, y: geometry.size.height / 2)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard geometry.size.width > 0 else { return }
                            split = min(1, max(0, value.location.x / geometry.size.width))
                        })
                    }
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.card))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localization.format("Photo comparison: %1$@; %2$@",
                        .text(photoDescription(earlier, first: true)), .text(photoDescription(later, first: false))))
                    .accessibilityHint("Swipe up or down to adjust the comparison.")
                    .accessibilityValue(localization.format("%1$@ %2$lld percent, %3$@ %4$lld percent",
                        .text(localization.string(photoLabel(first: true))), .integer(Int(split * 100)),
                        .text(localization.string(photoLabel(first: false))), .integer(Int((1 - split) * 100))))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: split = min(1, split + 0.1)
                        case .decrement: split = max(0, split - 0.1)
                        @unknown default: break
                        }
                    }
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark",
                        description: Text("One of these private image files could not be read. Choose another photo."))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: ZOSpace.m) { selection(earlier, first: true); selection(later, first: false) }
                    VStack(alignment: .leading, spacing: ZOSpace.m) { selection(earlier, first: true); selection(later, first: false) }
                }
                Text("Drag the handle to compare. Choose a date to change either photo.")
                    .zoText(.caption).foregroundStyle(secondaryInk)
            }
            .onAppear {
                // Capture the actual default pair once. Deletion may change the visual
                // fallback, but cannot silently authorize a different pair for sharing.
                if earlierID == nil && laterID == nil {
                    earlierID = pair.first.id
                    laterID = pair.second.id
                }
            }
            .toolbar {
                if let shareablePair {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { share(shareablePair) } label: {
                            Image(systemName: "square.and.arrow.up")
                                .zoIcon(ZOIcon.row)
                                .foregroundStyle(theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(theme.surfaceSecondary, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share privately")
                        .accessibilityHint("Opens sharing for these two selected private photos.")
                    }
                }
            }
            .alert("Comparison not available", isPresented: $sharingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("These selected photos can no longer be shared. Choose two saved photos again.")
            }
        }
    }

    private func share(_ presented: ProgressPhotoPair) {
        guard let onShare, selectedPair == presented,
              let confirmed = presented.validatedForSharing(records: records,
                isAvailable: repository.isAvailable, isReadable: readable) else {
            sharingUnavailable = true
            return
        }
        onShare(confirmed.first, confirmed.second)
    }

    private func dateChip(_ date: Date) -> some View {
        Text(date, format: .dateTime.day().month(.abbreviated).year()).zoText(.caption)
            .foregroundStyle(ZOColor.resolved(ZOColor.inkPrimary, in: .dark))
            .padding(.horizontal, ZOSpace.s).padding(.vertical, ZOSpace.xs)
            .background(ZOColor.resolved(ZOColor.scrim, in: .dark), in: Capsule())
    }

    private func photo(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
    }

    private func selection(_ record: ProgressPhotoRecord, first: Bool) -> some View {
        Menu {
            ForEach(records) { option in
                Button(dateDescription(option.createdAt) + " · " + localization.string(option.label.title)) {
                    photoShareAuthority?.revokeAll(before: .selection)
                    if first { earlierID = option.id } else { laterID = option.id }
                }
                .disabled(option.id == (first ? pair?.second.id : pair?.first.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(photoLabel(first: first))).zoText(.caption).foregroundStyle(secondaryInk)
                Text(record.createdAt, format: .dateTime.day().month(.abbreviated).year()).zoText(.section)
                Text(LocalizedStringKey(record.label.title)).zoText(.caption).foregroundStyle(secondaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain).foregroundStyle(theme.textPrimary)
        .accessibilityLabel(photoDescription(record, first: first))
        .accessibilityHint("Choose a saved private photo")
    }
}
