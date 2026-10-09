import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Root retains the real ProgressPhotoPersisting instance and provides a fresh
/// read. Nil is an unavailable capability, never permission to use cached data.
typealias PhotoComparisonShareFreshSource = @MainActor (PhotoComparisonShareSource) async -> PhotoComparisonShareSnapshot?

@MainActor
struct PhotoComparisonShareView: View {
    let source: PhotoComparisonShareSource
    let sourceVersion: UUID
    let freshSource: PhotoComparisonShareFreshSource?
    let lifetime: PhotoComparisonShareLifetime?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var options = PhotoComparisonShareOptions()
    @State private var generation = PhotoComparisonShareGeneration()
    @State private var reviewed: PhotoComparisonShareReview?
    @State private var nativeReview: PhotoComparisonShareReview?
    @State private var file = PhotoComparisonSharePNGDocument()
    @State private var showsFiles = false
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var isVisible = false
    @State private var notice: String?

    init(
        source: PhotoComparisonShareSource,
        sourceVersion: UUID,
        freshSource: PhotoComparisonShareFreshSource? = nil,
        lifetime: PhotoComparisonShareLifetime? = nil
    ) {
        self.source = source
        self.sourceVersion = sourceVersion
        self.freshSource = freshSource
        self.lifetime = lifetime
    }

    private var input: PhotoComparisonShareRenderInput {
        .init(source: source, sourceVersion: sourceVersion, options: options,
              localization: localization, calendar: calendar,
              themeID: theme.id, designTheme: theme.designTheme,
              scheme: theme.colorScheme, accent: theme.accentPreference)
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var canAct: Bool {
        freshSource != nil && lifetime?.allows(sourceVersion) == true
            && !busy && nativeReview == nil && !showsFiles
            && scenePhase == .active && reviewed?.input == input
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    preview
                    if reviewed?.input == input { sourceFacts }
                    privacyChoices
                    Text(verbatim: localization.string("Only this image is shared. Choose where it goes."))
                        .zoText(.caption).foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if freshSource == nil || lifetime?.allows(sourceVersion) != true {
                        Text(verbatim: localization.string("Sharing is unavailable until these saved photos can be checked."))
                            .zoText(.body).foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice {
                        Text(verbatim: localization.string(notice))
                            .zoText(.body).foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(ZOSpace.xl)
            }
            .scrollIndicators(.hidden)
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .navigationTitle(localization.string("Share privately"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localization.string("Close")) {
                        lifetime?.invalidate()
                        invalidateReview()
                        dismiss()
                    }
                }
            }
        }
        .task(id: input) { prepareReview() }
        .onChange(of: input) { prepareReview() }
        .onAppear { isVisible = true }
        .onDisappear {
            // A system destination may cover the composer. Keep its reviewed
            // raster while cancelling pending work. Root dismissal/scene/source
            // changes still revoke the local supply gate.
            if nativeReview == nil && !showsFiles {
                lifetime?.invalidate()
                isVisible = false
                invalidateReview()
            } else {
                operation?.cancel()
                operation = nil
                busy = false
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                invalidateReview()
            } else if isVisible {
                prepareReview()
            }
        }
        .sheet(item: $nativeReview) { review in
            PhotoComparisonShareActivitySheet(data: review.raster.pngData,
                permit: PhotoComparisonShareExportPermit(reviewedPNG: review.raster.pngData,
                    rootLifetime: lifetime, rootVersion: review.input.sourceVersion,
                    localLifetime: review.delivery, ticket: review.ticket))
        }
        .fileExporter(isPresented: $showsFiles, document: file, contentType: .png,
                      defaultFilename: "01-photo-comparison") { [submitted = file] result in
            guard submitted.isAuthorized, let review = reviewed,
                  submitted.ticket == review.ticket, accepts(review) else { return }
            file = PhotoComparisonSharePNGDocument()
            switch result {
            case .success:
                setNotice("Image saved.")
            case let .failure(error):
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                    setNotice("The image action could not be completed. Your saved photos are kept.")
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let review = reviewed, review.input == input,
           let image = UIImage(data: review.raster.pngData) {
            // Preview the actual frozen export, never a second SwiftUI poster.
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: 420)
                .clipShape(RoundedRectangle(cornerRadius: ZORadius.card))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(localization.string("Reviewed photo comparison image"))
                .accessibilityHint(localization.string("This is the image supplied to your chosen destination."))
        } else {
            Text(verbatim: localization.string("The comparison image is unavailable. Your saved photos are kept."))
                .zoText(.body).foregroundStyle(secondaryInk)
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(ZOSpace.l)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
        }
    }

    private var sourceFacts: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            fact(source.first.record, title: source.hasStrictChronology ? "Before" : "First photo")
            fact(source.second.record, title: source.hasStrictChronology ? "After" : "Second photo")
        }
        .padding(ZOSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
    }

    private func fact(_ record: ProgressPhotoRecord, title: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(verbatim: localization.string(title)).zoText(.section).foregroundStyle(theme.textPrimary)
            Text(verbatim: PhotoComparisonShareRenderer.date(record.createdAt,
                localization: localization, calendar: calendar))
                .zoText(.caption).foregroundStyle(secondaryInk)
            Text(verbatim: localization.string(record.label.title))
                .zoText(.caption).foregroundStyle(secondaryInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var privacyChoices: some View {
        VStack(spacing: ZOSpace.m) {
            Toggle(localization.string("Include photo dates"), isOn: $options.includeDates)
            Toggle(localization.string("Include photo labels"), isOn: $options.includeLabels)
        }
        .zoText(.body).foregroundStyle(theme.textPrimary)
        .toggleStyle(ZOToggleStyle())
        .disabled(busy || nativeReview != nil || showsFiles)
    }

    private var actions: some View {
        VStack(spacing: ZOSpace.s) {
            Button { export(.photos) } label: {
                Label(localization.string("Save image"), systemImage: "photo")
            }.buttonStyle(ZOButtonStyle(.secondary, wide: true, isLoading: busy))
            Button { export(.files) } label: {
                Label(localization.string("Save to Files"), systemImage: "folder")
            }.buttonStyle(ZOButtonStyle(.secondary, wide: true))
            Button { export(.share) } label: {
                Label(localization.string("Share"), systemImage: "square.and.arrow.up")
            }.buttonStyle(ZOButtonStyle(.primary, wide: true))
        }.disabled(!canAct)
    }

    private func prepareReview() {
        if let review = reviewed, review.input == input,
           review.delivery.allows(review.ticket), scenePhase == .active { return }
        invalidateReview()
        guard scenePhase == .active, !Task.isCancelled else { return }
        do {
            let captured = input
            let raster = try PhotoComparisonShareRenderer.render(source: captured.source,
                options: captured.options, localization: captured.localization,
                calendar: captured.calendar, theme: theme)
            guard captured == input, !Task.isCancelled else { return }
            reviewed = .init(id: UUID(), raster: raster, input: captured, ticket: generation.revision,
                delivery: PhotoComparisonShareLifetime(sourceVersion: generation.revision))
        } catch {
            setNotice("The comparison image is unavailable. Your saved photos are kept.")
        }
    }

    private func invalidateReview() {
        reviewed?.delivery.invalidate()
        nativeReview?.delivery.invalidate()
        generation.invalidate()
        operation?.cancel()
        operation = nil
        busy = false
        reviewed = nil
        nativeReview = nil
        showsFiles = false
        file = PhotoComparisonSharePNGDocument()
    }

    private func accepts(_ review: PhotoComparisonShareReview) -> Bool {
        review.input == input && isVisible && lifetime?.allows(sourceVersion) == true
            && review.delivery.allows(review.ticket) && generation.accepts(review.ticket,
            sourceVersion: review.input.sourceVersion, currentSourceVersion: sourceVersion,
            isActive: scenePhase == .active, isCancelled: Task.isCancelled)
    }

    private func authorize(_ review: PhotoComparisonShareReview) async -> Bool {
        guard accepts(review), let freshSource else { return false }
        let current = await freshSource(review.input.source)
        guard accepts(review), !Task.isCancelled else { return false }
        do {
            try PhotoComparisonShareAuthority.validate(review.input.source, current: current)
            return true
        } catch {
            invalidateReview()
            setNotice("These saved photos changed or are unavailable. Open the comparison again.")
            return false
        }
    }

    private enum Destination { case photos, files, share }

    private func export(_ destination: Destination) {
        guard canAct, let review = reviewed, accepts(review) else { return }
        notice = nil
        busy = true
        operation = Task { @MainActor in
            defer {
                // An obsolete operation must not clear a newer task's state.
                if generation.revision == review.ticket { busy = false; operation = nil }
            }
            guard await authorize(review) else { return }
            do {
                switch destination {
                case .share:
                    guard await authorize(review) else { return }
                    nativeReview = review
                case .files:
                    guard await authorize(review) else { return }
                    guard let lifetime else { return }
                    file = PhotoComparisonSharePNGDocument(data: review.raster.pngData,
                        rootLifetime: lifetime, rootVersion: review.input.sourceVersion,
                        localLifetime: review.delivery, ticket: review.ticket)
                    showsFiles = true
                case .photos:
                    guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String,
                          !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setNotice("Save to Photos is unavailable. You can save to Files.")
                        return
                    }
                    let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    let permission = existing == .notDetermined
                        ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : existing
                    // A permission dialog can suspend and change the lifecycle.
                    guard await authorize(review) else { return }
                    guard permission == .authorized || permission == .limited else {
                        setNotice("Photo access is off. You can change access in Settings or save to Files.")
                        return
                    }
                    try Task.checkCancellation()
                    // No await between final authority and submission. Only the
                    // reviewed raster is supplied, never a photo-store write.
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo,
                            data: review.raster.pngData, options: nil)
                    }
                    // OS writes already submitted cannot be rolled back.
                    if accepts(review) { setNotice("Image saved.") }
                }
            } catch is CancellationError {
                // Cancellation is silent and never becomes a successful save.
            } catch {
                if accepts(review) {
                    setNotice("The image action could not be completed. Your saved photos are kept.")
                }
            }
        }
    }

    private func setNotice(_ key: String) {
        notice = key
        UIAccessibility.post(notification: .announcement, argument: localization.string(key))
    }
}

private struct PhotoComparisonShareRenderInput: Equatable {
    let source: PhotoComparisonShareSource
    let sourceVersion: UUID
    let options: PhotoComparisonShareOptions
    let localization: AppLocalization
    let calendar: Calendar
    let themeID: ZeroOneThemeID
    let designTheme: ZOTheme
    let scheme: ColorScheme
    let accent: AccentPreference
}

private struct PhotoComparisonShareReview: Identifiable {
    let id: UUID
    let raster: PhotoComparisonShareRaster
    let input: PhotoComparisonShareRenderInput
    let ticket: UUID
    let delivery: PhotoComparisonShareLifetime
}

@MainActor
enum PhotoComparisonShareRenderer {
    static func render(source: PhotoComparisonShareSource, options: PhotoComparisonShareOptions,
                       localization: AppLocalization, calendar: Calendar,
                       theme: ZeroOneThemeTokens) throws -> PhotoComparisonShareRaster {
        guard source.first.record.id != source.second.record.id else {
            throw PhotoComparisonShareError.duplicateIdentity
        }
        try PhotoComparisonShareAuthority.validate(source, current: .init(
            records: [source.first.record, source.second.record],
            originalImageData: [source.first.record.id: source.first.imageData,
                                source.second.record.id: source.second.imageData]))
        let first = try decode(source.first.imageData)
        let second = try decode(source.second.imageData)
        let content = PhotoComparisonSharePrint(source: source, options: options,
            first: first, second: second, localization: localization, calendar: calendar)
            .environment(\.zeroOneTheme, theme)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, localization.locale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3.6
        renderer.isOpaque = true
        guard let pixels = renderer.cgImage, pixels.width == 1080, pixels.height == 1350 else {
            throw PhotoComparisonShareError.unreadableImage
        }
        // Create a new PNG from rendered pixels. Never copy original EXIF/GPS,
        // filenames, metadata dictionaries or original image URLs.
        let encoded = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw PhotoComparisonShareError.unreadableImage
        }
        CGImageDestinationAddImage(output, pixels, nil)
        guard CGImageDestinationFinalize(output) else { throw PhotoComparisonShareError.unreadableImage }
        return .init(pngData: encoded as Data, pixelWidth: pixels.width, pixelHeight: pixels.height)
    }

    private static func decode(_ data: Data) throws -> UIImage {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary),
              image.width > 0, image.height > 0 else { throw PhotoComparisonShareError.unreadableImage }
        return UIImage(cgImage: image)
    }

    static func date(_ date: Date, localization: AppLocalization, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Deliberate static comparison, 4:5 like proof21. No pose alignment, inferred
/// body measurement, gain, duration claim, or interactive slider is exported.
@MainActor
private struct PhotoComparisonSharePrint: View {
    let source: PhotoComparisonShareSource
    let options: PhotoComparisonShareOptions
    let first: UIImage
    let second: UIImage
    let localization: AppLocalization
    let calendar: Calendar
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("01").zoText(.section)
                Spacer()
                Text(verbatim: localization.string("Photo comparison")).zoText(.caption)
            }
            HStack(alignment: .top, spacing: 8) {
                column(source.first.record, image: first,
                    heading: source.hasStrictChronology ? "Before" : "First photo")
                column(source.second.record, image: second,
                    heading: source.hasStrictChronology ? "After" : "Second photo")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 300, height: 375, alignment: .topLeading)
        .foregroundStyle(theme.textPrimary)
        .background(theme.backgroundPrimary)
        .clipped()
    }

    private func column(_ record: ProgressPhotoRecord, image: UIImage, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localization.string(heading)).zoText(.caption)
                .frame(height: 36, alignment: .bottomLeading)
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: 134, height: 220)
                .background(theme.surfaceSecondary)
            if options.includeDates {
                Text(verbatim: PhotoComparisonShareRenderer.date(record.createdAt,
                    localization: localization, calendar: calendar)).zoText(.mini)
            }
            if options.includeLabels {
                Text(verbatim: localization.string(record.label.title)).zoText(.mini)
            }
        }.frame(width: 134, alignment: .leading)
    }
}

/// The system may retain a document snapshot while the picker is open. Both
/// leases must still be valid at its actual serialization boundary.
private struct PhotoComparisonSharePNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let data: Data
    let rootLifetime: PhotoComparisonShareLifetime?
    let rootVersion: UUID?
    let localLifetime: PhotoComparisonShareLifetime?
    let ticket: UUID?
    let permit: PhotoComparisonShareExportPermit

    init(data: Data = Data(), rootLifetime: PhotoComparisonShareLifetime? = nil,
         rootVersion: UUID? = nil, localLifetime: PhotoComparisonShareLifetime? = nil,
         ticket: UUID? = nil) {
        self.data = data
        self.rootLifetime = rootLifetime
        self.rootVersion = rootVersion
        self.localLifetime = localLifetime
        self.ticket = ticket
        self.permit = PhotoComparisonShareExportPermit(reviewedPNG: data,
            rootLifetime: rootLifetime, rootVersion: rootVersion,
            localLifetime: localLifetime, ticket: ticket)
    }
    init(configuration: ReadConfiguration) throws {
        // This export-only document cannot authorize an imported file.
        self.init()
        throw PhotoComparisonShareError.unavailable
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: try permit.authorizedData(data))
    }

    var isAuthorized: Bool {
        (try? permit.authorizedData(data)) != nil
    }
}

@MainActor
private struct PhotoComparisonShareActivitySheet: UIViewControllerRepresentable {
    let data: Data
    let permit: PhotoComparisonShareExportPermit

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [PhotoComparisonSharePNGItem(data: data,
            permit: permit)], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class PhotoComparisonSharePNGItem: NSObject, UIActivityItemSource {
    let data: Data
    let permit: PhotoComparisonShareExportPermit

    init(data: Data, permit: PhotoComparisonShareExportPermit) {
        self.data = data
        self.permit = permit
        super.init()
    }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        // System type negotiation receives no original or review pixels.
        Data()
    }
    func activityViewController(_ controller: UIActivityViewController,
        itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        try? permit.authorizedData(data)
    }
    func activityViewController(_ controller: UIActivityViewController,
        dataTypeIdentifierForActivityType type: UIActivity.ActivityType?) -> String {
        UTType.png.identifier
    }
}
