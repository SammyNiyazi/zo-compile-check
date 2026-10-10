import AVFoundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Local image composition only. The optional Club action is an explicit
/// integration capability, never a fake post or an automatically active service.
@MainActor
struct ZOShareComposer: View {
    let source: ZOShareSource
    let localization: AppLocalization
    /// Re-read saved state and active-session gates at action boundaries. Outdoor
    /// stores are actors, so this capability is asynchronous and fails closed.
    var canExport: @MainActor () async -> Bool = { false }
    var postToClub: (@MainActor (ZOShareExport) async throws -> Void)? = nil
    /// Root/leaf retains and revokes this exact presentation/source revision
    /// BEFORE source changes or host teardown. Existing callers default closed.
    var sourceVersion: UUID? = nil
    var exportLifetime: ZOShareExportLifetime? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var size: ZOShareSize = .story
    @State private var layout: ZOShareLayout = .stats
    @State private var privacy = ZOSharePrivacy()
    @State private var photo: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoGeneration = UUID()
    @State private var photoRevision = UUID()
    @State private var operationGeneration = ZOShareExportGeneration()
    @State private var reviewLifetime: ZOShareExportLifetime?
    @State private var isVisible = false
    @State private var operationKind: OperationKind?
    @State private var presentation: Presentation?
    @State private var notice: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var showsFiles = false
    @State private var file: ZOSharePNGDocument?
    @State private var asksClubConfirmation = false
    @State private var openPermissionSettings = false

    private enum Presentation: Identifiable {
        case camera, share(ZOShareExport, ZOShareExportPermit)
        var id: String { switch self { case .camera: "camera"; case .share: "share" } }
    }

    private enum OperationKind: Equatable { case camera, export }

    private struct ReviewInput: Equatable {
        let payload: ZOSharePayload
        let size: ZOShareSize
        let layout: ZOShareLayout
        let privacy: ZOSharePrivacy
        let photoRevision: UUID
        let localization: AppLocalization
        let reduceMotion: Bool
        let sourceVersion: UUID?
        let themeID: ZeroOneThemeID
        let designTheme: ZOTheme
        let scheme: ColorScheme
        let accent: AccentPreference
    }

    private var reviewInput: ReviewInput {
        .init(payload: payload, size: size, layout: selectedLayout, privacy: privacy,
              photoRevision: photoRevision, localization: localization, reduceMotion: reduceMotion,
              sourceVersion: sourceVersion, themeID: theme.id, designTheme: theme.designTheme,
              scheme: theme.colorScheme, accent: theme.accentPreference)
    }

    private struct SourceAuthority: Equatable {
        let version: UUID?
        let lifetimeIdentity: ObjectIdentifier?
    }

    private var sourceAuthority: SourceAuthority {
        .init(version: sourceVersion, lifetimeIdentity: exportLifetime.map { ObjectIdentifier($0) })
    }

    private var hasCameraContext: Bool {
        if case .some(.camera) = presentation { return true }
        return operationKind == .camera
    }

    private var selectedLayout: ZOShareLayout { source.isRecap ? .recap : (layoutOptions.contains(layout) ? layout : .stats) }
    private var payload: ZOSharePayload { ZOSharePayload.make(source: source, privacy: privacy, localization: localization) }
    private var layoutOptions: [ZOShareLayout] {
        source.layouts.filter { option in
            option != .recap && (option != .best || payload.best != nil)
                && ((option != .route && option != .sticker) || source.hasRoute)
        }
    }
    private var hasName: Bool {
        if case let .first14Days(facts) = source { return facts.nameAndNumber?.isEmpty == false }
        return false
    }
    private var hasBodyWeight: Bool {
        if case let .first14Days(facts) = source { return facts.bodyWeightChange != nil }
        return false
    }
    private var hasLoads: Bool {
        if case let .workout(entry, _) = source {
            return (entry.exercises ?? []).flatMap(\.completedSets).contains { !$0.isTimed && $0.load.value.isFinite && $0.load.value > 0 }
        }
        return false
    }
    private var hasPrivacyControls: Bool { source.isOutdoor ? source.hasRoute : (source.isRecap ? hasName || hasBodyWeight : hasLoads) }
    private var heading: String {
        if source.isRecap { return "Share my 14 days" }
        if case let .outdoor(record) = source { return record.kind == .run ? "Share your run" : "Share your walk" }
        return "Share your workout"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    preview
                    sizes.padding(.top, ZOSpace.m)
                    if !layoutOptions.isEmpty { layouts.padding(.top, ZOSpace.s + 2 * ZOStroke.hairline) }
                    if hasPrivacyControls { privacyControls.padding(.top, source.isOutdoor ? ZOSpace.s + 2 * ZOStroke.hairline : ZOSpace.m) }
                    if !source.isRecap { photoControls.padding(.top, ZOSpace.m) }
                    saveControls.padding(.top, ZOSpace.m)
                    if let notice {
                        Text(verbatim: localization.string(notice)).zoText(.body)
                            .foregroundStyle(theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.updatesFrequently).padding(.top, ZOSpace.m)
                    }
                    if openPermissionSettings {
                        Button(localization.string("Open Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(ZOButtonStyle(.secondary, wide: true)).padding(.top, ZOSpace.m)
                    }
                }.padding(.horizontal, ZOSpace.screenMargin).padding(.top, ZOSpace.xs).padding(.bottom, ZOSpace.m)
            }
            .background(theme.backgroundPrimary)
            .disabled(busy)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            }
            .background(theme.backgroundPrimary)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $presentation, onDismiss: {
            // A delayed dismissal callback cannot revoke a newer operation or
            // destination that started after the old binding became nil.
            if presentation == nil && !busy && !showsFiles && !asksClubConfirmation {
                revokeReview(cancelOperation: false)
            }
        }) { item in
            switch item {
            case .camera:
                let cameraTicket = operationGeneration.revision
                let cameraVersion = sourceVersion
                let cameraLifetime = exportLifetime
                InAppStillCamera { result in
                    guard operationGeneration.revision == cameraTicket,
                          sourceContextIsCurrent(cameraVersion, lifetime: cameraLifetime) else { return }
                    presentation = nil
                    switch result {
                    case let .captured(data): preparePhoto(data)
                    case .cancelled: break
                    case .failed: setNotice("The photo could not be prepared. Your choices are kept.")
                    }
                }.ignoresSafeArea().preferredColorScheme(.dark)
            case let .share(export, permit):
                ZOShareActivitySheet(export: export, permit: permit)
            }
        }
        .fileExporter(isPresented: $showsFiles, document: file, contentType: .png, defaultFilename: "01-share") { [submitted = file] result in
            guard let submitted, let permit = submitted.permit,
                  retainedExportIsCurrent(permit) else { return }
            file = nil
            switch result {
            case .success: setNotice("Image saved.")
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { setNotice("The image could not be saved. Your choices are kept.") }
            }
            revokeReview(cancelOperation: false)
        }
        .confirmationDialog(localization.string("Post this image to Club?"), isPresented: $asksClubConfirmation, titleVisibility: .visible) {
            Button(localization.string("Post to Club")) { perform(.club) }
            Button(localization.string("Cancel"), role: .cancel) {}
        } message: { Text(verbatim: localization.string("Only the image you have reviewed will be supplied to Club.")) }
        .task(id: selectedPhoto) {
            guard let selectedPhoto, !busy else { return }
            let generation = photoGeneration
            let expectedVersion = sourceVersion
            let expectedLifetime = exportLifetime
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self), !Task.isCancelled,
                      !busy, generation == photoGeneration,
                      sourceContextIsCurrent(expectedVersion, lifetime: expectedLifetime) else { return }
                preparePhoto(data)
            } catch {
                if !Task.isCancelled && !busy && generation == photoGeneration,
                   sourceContextIsCurrent(expectedVersion, lifetime: expectedLifetime) {
                    setNotice("The photo could not be prepared. Your choices are kept.")
                }
            }
        }
        .onAppear { isVisible = true }
        .onChange(of: reviewInput) { revokeReview(cancelOperation: !hasCameraContext) }
        .onChange(of: sourceAuthority) {
            photoGeneration = UUID()
            revokeReview()
            presentation = nil
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                revokeReview(cancelOperation: !hasCameraContext)
            }
        }
        .onDisappear {
            if presentation == nil && !showsFiles {
                isVisible = false
                photoGeneration = UUID()
                exportLifetime?.invalidate()
                revokeReview()
            } else {
                // Child destination cover and actual root removal are distinct.
                // Root must revoke its retained token before real host teardown.
                operation?.cancel()
            }
        }
    }

    private var header: some View {
        HStack(spacing: ZOSpace.m) {
            Button { photoGeneration = UUID(); exportLifetime?.invalidate(); revokeReview(); dismiss() } label: { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                .buttonStyle(ZOButtonStyle(.round)).accessibilityLabel(localization.string("Close"))
            Text(verbatim: localization.string(heading)).zoText(.section)
                .foregroundStyle(theme.textPrimary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget).accessibilityHidden(true)
        }.padding(.horizontal, ZOSpace.screenMargin).padding(.top, ZOSpace.xs).frame(minHeight: 52)
            .background(theme.backgroundPrimary)
    }

    private var preview: some View {
        let preferredWidth: CGFloat = size == .story ? (source.isRecap || source.isOutdoor ? 226 : 236)
            : (size == .post ? 268 : (size == .square ? 300 : 353))
        let previewHeight: CGFloat = source.isRecap || source.isOutdoor ? 404 : 420
        return
        GeometryReader { geometry in
            let width = max(0, min(geometry.size.width, min(preferredWidth, previewHeight * size.aspectRatio)))
            let scale = width / 300
            ZOSharePoster(payload: payload, layout: selectedLayout, size: size, photo: photo, localization: localization)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: width / size.aspectRatio, alignment: .topLeading)
                .background {
                    if selectedLayout == .sticker { ZOShareCheckerboard() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: previewHeight)
    }

    private var sizes: some View {
        let gap = ZOSpace.s - 2 * ZOStroke.hairline
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: dynamicTypeSize.isAccessibilitySize ? 2 : source.sizes.count)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(source.sizes) { option in
                Button { size = option } label: {
                    VStack(spacing: ZOSpace.xs) {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(.foreground, lineWidth: 1.5)
                            .frame(width: option == .story ? 13 : (option == .post ? 16 : (option == .square ? 18 : 24)),
                                height: option == .story ? 23 : (option == .post ? 20 : (option == .square ? 18 : 13.5)))
                            .frame(height: 24).accessibilityHidden(true)
                        Text(verbatim: localization.string(option.label)).zoProofText(.caption, size: 12, lineHeight: 16, weight: 500)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                    }.padding(.vertical, gap).frame(maxWidth: .infinity, minHeight: 52, alignment: .bottom)
                }.buttonStyle(ZOShareSizeButtonStyle(selected: size == option))
                    .accessibilityLabel(localization.string(option.label))
                    .accessibilityValue("\(Int(option.pixels.width)) × \(Int(option.pixels.height))")
                    .accessibilityAddTraits(size == option ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(localization.string("Card size"))
    }

    @ViewBuilder private var layouts: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: ZOSpace.s) { layoutButtons }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZOSpace.s) { layoutButtons }.fixedSize(horizontal: true, vertical: false)
                ScrollView(.horizontal) { HStack(spacing: ZOSpace.s) { layoutButtons } }.scrollIndicators(.hidden)
            }.frame(maxWidth: .infinity)
        }
    }

    private var layoutButtons: some View {
        ForEach(layoutOptions) { option in
                Button { layout = option } label: { Text(verbatim: localization.string(option.label)).fixedSize(horizontal: false, vertical: true) }
                    .buttonStyle(ZOChipStyle(isSelected: layout == option))
                    .disabled(option == .best && payload.best == nil || (option == .route || option == .sticker) && payload.route.isEmpty)
        }
    }

    private var privacyControls: some View {
        VStack(spacing: 0) {
            if source.isOutdoor {
                if source.hasRoute {
                    privacyToggle("Show route", isOn: $privacy.showRoute)
                    if privacy.showRoute {
                        privacyToggle("Hide where I start and finish", isOn: $privacy.hideRouteEndpoints,
                            help: "The first and last 200 m of the route", separated: true)
                        if payload.route.isEmpty {
                            Text(verbatim: localization.string("This route is too short to show with both ends hidden.")).zoText(.caption).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, ZOSpace.s)
                        }
                    }
                }
            } else if source.isRecap {
                if hasName { privacyToggle("Show my name and number", isOn: $privacy.showName) }
                if hasBodyWeight {
                    privacyToggle("Show body weight change", isOn: $privacy.showBodyWeight, separated: hasName)
                }
            } else {
                privacyToggle("Show loads", isOn: $privacy.showLoads)
            }
        }.toggleStyle(ZOToggleStyle()).padding(.horizontal, ZOSpace.l)
            .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
            .onChange(of: privacy) {
                if layout == .best && payload.best == nil { layout = .stats }
                if (layout == .route || layout == .sticker) && payload.route.isEmpty { layout = .stats }
                notice = nil
            }
    }

    private func privacyToggle(_ title: String, isOn: Binding<Bool>, help: String? = nil, separated: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(verbatim: localization.string(title)).zoText(.label)
                if let help { Text(verbatim: localization.string(help)).zoText(.caption).foregroundStyle(theme.textSecondary) }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2 * ZOStroke.hairline).frame(minHeight: ZOSpace.x4)
        .overlay(alignment: .top) { if separated { Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline) } }
    }

    private var photoControls: some View {
        VStack(spacing: ZOSpace.s) {
            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                Label { Text(verbatim: localization.string("Choose photo")) } icon: { Image(systemName: "photo").zoIcon(ZOIcon.inline) }
            }.buttonStyle(ZOButtonStyle(.secondary, wide: true)).disabled(busy)
            if photo != nil {
                Button(localization.string("Remove photo")) { photoGeneration = UUID(); photoRevision = UUID(); selectedPhoto = nil; photo = nil }
                    .buttonStyle(ZOButtonStyle(.quiet)).disabled(busy)
            }
        }
    }

    private var dock: some View {
        VStack(spacing: ZOSpace.s) {
            let row = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ZOSpace.s)) : AnyLayout(HStackLayout(spacing: ZOSpace.s))
            row {
                if source.isRecap || selectedLayout == .sticker {
                    Button { perform(.photos) } label: {
                        Label { Text(verbatim: localization.string(selectedLayout == .sticker ? "Save sticker" : "Save image")) }
                            icon: { Image(systemName: "arrow.down.to.line").zoIcon(ZOIcon.inline) }
                    }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                } else {
                    Button { requestCamera() } label: {
                        Label { Text(verbatim: localization.string("New photo")) } icon: { Image(systemName: "camera").zoIcon(ZOIcon.inline) }
                    }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                }
                if postToClub != nil {
                    Button(localization.string("Post to Club")) { asksClubConfirmation = true }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                }
            }
            Button(localization.string("Share")) { perform(.share) }.buttonStyle(ZOButtonStyle(.primary, isLoading: busy))
        }.disabled(busy).padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m).background(theme.backgroundPrimary)
    }

    @ViewBuilder private var saveControls: some View {
        if !source.isRecap && selectedLayout != .sticker {
            Menu(localization.string("Save image")) {
                Button(localization.string("Save to Photos")) { perform(.photos) }
                Button(localization.string("Save to Files")) { perform(.files) }
            }.zoText(.caption).frame(maxWidth: .infinity, minHeight: ZOSpace.hitTarget)
        } else {
            Button(localization.string("Save to Files")) { perform(.files) }.buttonStyle(ZOButtonStyle(.quiet))
        }
    }

    private enum Action { case share, photos, files, club }

    private func perform(_ action: Action) {
        guard !busy, presentation == nil, !showsFiles else { return }
        guard let sourceVersion, exportLifetime?.allows(sourceVersion) == true else {
            setNotice("This saved record is no longer available to share.")
            return
        }
        revokeReview()
        photoGeneration = UUID()
        let ticket = operationGeneration.revision
        let localLifetime = ZOShareExportLifetime(sourceVersion: ticket)
        reviewLifetime = localLifetime
        let permit = ZOShareExportPermit(root: exportLifetime, sourceVersion: sourceVersion,
            review: localLifetime, reviewVersion: ticket)
        busy = true; notice = nil; openPermissionSettings = false
        operationKind = .export
        // Capture only the reviewed, privacy-filtered projection for this action.
        let reviewed = payload, selectedSize = size, selectedLayout = selectedLayout, selectedImage = photo
        let expectedInput = reviewInput
        operation = Task { @MainActor in
            defer { finishOperation(ticket) }
            do {
                guard await exportIsAvailable(permit, expectedInput: expectedInput) else { return }
                try Task.checkCancellation()
                let export = try ZOShareRenderer.render(payload: reviewed, layout: selectedLayout, size: selectedSize, photo: selectedImage, localization: localization, reduceMotion: reduceMotion)
                switch action {
                case .share:
                    guard await exportIsAvailable(permit, expectedInput: expectedInput) else { return }
                    presentation = .share(export, permit)
                case .files:
                    guard await exportIsAvailable(permit, expectedInput: expectedInput) else { return }
                    file = ZOSharePNGDocument(data: export.pngData, permit: permit); showsFiles = true
                case .photos:
                    guard (Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)?.isEmpty == false else {
                        setNotice("Save to Photos is unavailable. You can save to Files."); return
                    }
                    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    let authorization = status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
                    guard await exportIsAvailable(permit, expectedInput: expectedInput) else { return }
                    guard authorization == .authorized || authorization == .limited else {
                        openPermissionSettings = true
                        setNotice("Photo access is off. You can change access in Settings or save to Files."); return
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: export.pngData, options: nil)
                    }
                    // A completed Photos write cannot be rolled back by sheet cancellation.
                    if retainedExportIsCurrent(permit), !Task.isCancelled { setNotice("Image saved.") }
                case .club:
                    guard let postToClub, await exportIsAvailable(permit, expectedInput: expectedInput) else { return }
                    try await postToClub(export)
                    if retainedExportIsCurrent(permit), !Task.isCancelled { setNotice("Image posted to Club.") }
                }
            } catch is CancellationError {} catch {
                if retainedExportIsCurrent(permit), !Task.isCancelled { setNotice("The image action could not be completed. Your choices are kept.") }
            }
        }
    }

    private func exportIsAvailable(_ permit: ZOShareExportPermit, expectedInput: ReviewInput) async -> Bool {
        guard retainedExportIsCurrent(permit), reviewInput == expectedInput, !Task.isCancelled else { return false }
        let available = await canExport()
        guard retainedExportIsCurrent(permit), reviewInput == expectedInput, !Task.isCancelled else { return false }
        if !available {
            revokeReview()
            setNotice("This saved record is no longer available to share.")
        }
        return available
    }

    private func retainedExportIsCurrent(_ permit: ZOShareExportPermit) -> Bool {
        guard let ticket = permit.reviewVersion else { return false }
        return permit.isAuthorized && permit.sourceVersion == sourceVersion
            && operationGeneration.accepts(ticket, isActive: isVisible && scenePhase == .active,
                                           isCancelled: false)
    }

    private func finishOperation(_ ticket: UUID) {
        guard operationGeneration.revision == ticket else { return }
        busy = false
        operation = nil
        operationKind = nil
    }

    private func sourceContextIsCurrent(_ version: UUID?, lifetime: ZOShareExportLifetime?) -> Bool {
        guard version == sourceVersion, lifetime === exportLifetime else { return false }
        // Unwired previews retain their original photo/camera controls; they
        // still cannot export. A supplied revoked authority blocks stale reads.
        guard let lifetime else { return true }
        guard let version else { return false }
        return lifetime.allows(version)
    }

    private func revokeReview(cancelOperation: Bool = true) {
        reviewLifetime?.invalidate()
        reviewLifetime = nil
        if case .some(.share(_, _)) = presentation { presentation = nil }
        file = nil
        showsFiles = false
        asksClubConfirmation = false
        if cancelOperation {
            operationGeneration.invalidate()
            operation?.cancel()
            operation = nil
            operationKind = nil
            busy = false
        }
    }

    private func requestCamera() {
        guard !busy, presentation == nil, !showsFiles else { return }
        revokeReview()
        let ticket = operationGeneration.revision
        let expectedVersion = sourceVersion
        let expectedLifetime = exportLifetime
        photoGeneration = UUID()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            setNotice("A camera is not available. You can choose a photo instead."); return
        }
        busy = true; openPermissionSettings = false
        operationKind = .camera
        operation = Task { @MainActor in
            defer { finishOperation(ticket) }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : status == .authorized
            guard !Task.isCancelled, operationGeneration.revision == ticket,
                  sourceContextIsCurrent(expectedVersion, lifetime: expectedLifetime) else { return }
            if allowed { presentation = .camera }
            else { openPermissionSettings = true; setNotice("Camera access is off. You can change access in Settings or choose a photo.") }
        }
    }

    private func preparePhoto(_ data: Data) {
        guard !busy else { return }
        guard data.count <= 32 * 1024 * 1024,
              let input = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            setNotice("The photo could not be prepared. Your choices are kept."); return
        }
        // Rasterized pixels only: never forwards the selected asset's GPS/EXIF.
        photoGeneration = UUID()
        photoRevision = UUID()
        photo = UIImage(cgImage: decoded)
        notice = nil
    }

    private func setNotice(_ text: String) {
        notice = text
        UIAccessibility.post(notification: .announcement, argument: localization.string(text))
    }
}

private struct ZOShareSizeButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.zeroOneTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(selected ? theme.backgroundPrimary : theme.textSecondary)
            .background(selected ? theme.textPrimary : (configuration.isPressed ? theme.surfaceSecondary : theme.surfacePrimary),
                in: RoundedRectangle(cornerRadius: ZORadius.control))
            .overlay { if !selected { RoundedRectangle(cornerRadius: ZORadius.control).strokeBorder(ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme), lineWidth: ZOStroke.hairline) } }
    }
}

private struct ZOShareCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            for row in 0...Int(size.height / 8) {
                for column in 0...Int(size.width / 8) {
                    context.fill(Path(CGRect(x: CGFloat(column * 8), y: CGFloat(row * 8), width: 8, height: 8)),
                        with: .color(Color(zoHex: (row + column).isMultiple(of: 2) ? 0x4A4A47 : 0x3A3A38)))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct ZOSharePNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let data: Data
    let permit: ZOShareExportPermit?
    // Compatible data initializer is export-closed without an explicit permit.
    init(data: Data, permit: ZOShareExportPermit? = nil) { self.data = data; self.permit = permit }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        permit = nil
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // This may run off-main after a picker wait. No actor or view reads.
        guard let permit else { throw ZOShareExportAuthorizationError.unavailable }
        return FileWrapper(regularFileWithContents: try permit.authorizedData(data))
    }
}

private struct ZOShareActivitySheet: UIViewControllerRepresentable {
    let export: ZOShareExport
    let permit: ZOShareExportPermit
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Share raster pixels only. No private source, source URL or route data.
        UIActivityViewController(activityItems: [ZOSharePNGActivityItem(data: export.pngData,
            permit: permit)], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Supplies the same reviewed PNG bytes to the system share sheet and declares
/// their format, including a Sticker's alpha channel. Recipient behavior still
/// needs native acceptance because an external app can transform an image.
private final class ZOSharePNGActivityItem: NSObject, UIActivityItemSource {
    let data: Data
    let permit: ZOShareExportPermit
    init(data: Data, permit: ZOShareExportPermit) { self.data = data; self.permit = permit; super.init() }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { Data() }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Checks after completed revocation deny. A request already authorized
        // at an earlier decision point may finish while revocation takes place.
        try? permit.authorizedData(data)
    }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.png.identifier }
}
