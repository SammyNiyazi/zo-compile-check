import PhotosUI
import SwiftUI
import UIKit
import AVFoundation

struct ProgressPhotosView: View {
    @Bindable var repository: ProgressPhotoRepository
    let initialLabel: ProgressPhotoLabel
    let onShare: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selectedRecord: ProgressPhotoRecord?
    @State private var presentedComparison: ComparisonRoute?
    @State private var pendingComparison: ComparisonRequest?
    @State private var comparisonTask: Task<Void, Never>?
    @State private var modalRevision = UUID()
    @State private var captureActivityID: UUID?
    @State private var sharingUnavailable = false
    @Environment(\.photoComparisonShareHostAuthority) private var photoShareAuthority
    @Environment(\.zeroOneRootShareCoordinator) private var shareCoordinator

    private var captureIsActive: Bool { captureActivityID != nil }

    private struct ComparisonRequest {
        let id: UUID
        let first: ProgressPhotoRecord
        let second: ProgressPhotoRecord
        let authority: PhotoComparisonShareHostAuthority
        let coordinator: ZeroOneRootShareCoordinator
        let rootRequest: ZeroOneRootShareCoordinator.Request
        let hostRevision: UUID
        let modalRevision: UUID
    }

    private struct ComparisonRoute: Identifiable {
        let presentation: PhotoComparisonShareHostAuthority.Presentation
        let authority: PhotoComparisonShareHostAuthority
        let coordinator: ZeroOneRootShareCoordinator
        let rootRequest: ZeroOneRootShareCoordinator.Request
        var id: UUID { presentation.id }
    }
    @Environment(\.calendar) private var shareCalendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        repository: ProgressPhotoRepository,
        initialLabel: ProgressPhotoLabel = .progress,
        onShare: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)? = nil
    ) {
        self.repository = repository
        self.initialLabel = initialLabel
        self.onShare = onShare
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var tertiaryInk: Color { contrast == .increased ? theme.textSecondary : theme.textTertiary }

    var body: some View {
        let expectedRecord = selectedRecord
        let expectedModalRevision = modalRevision
        let expectedComparison = presentedComparison
        let expectedPendingID = pendingComparison?.id
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                privacyHeader

                if !repository.isAvailable {
                    unavailableRepositoryState
                } else if repository.entries.isEmpty {
                    emptyState
                } else {
                    ProgressPhotoComparisonView(repository: repository, onShare: comparisonShareCallback)
                    if repository.entries.count == 1 {
                        Text("Add another photo to compare two dates.")
                            .zoText(.body)
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    timeline
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.xl)
            .padding(.top, ZOSpace.l)
            .padding(.bottom, ZOSpace.x4)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if repository.isAvailable {
                ProgressPhotoCaptureButton(repository: repository, initialLabel: initialLabel, presentation: .primary,
                    onCaptureActivity: captureActivityChanged)
                    .disabled(pendingComparison != nil || presentedComparison != nil || selectedRecord != nil)
                    .padding(.horizontal, ZOSpace.xl).padding(.vertical, ZOSpace.m)
                    .background(theme.backgroundPrimary)
            }
        }
        .navigationTitle("Before and after")
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .sheet(item: selectedRecordBinding(expected: expectedRecord, revision: expectedModalRevision)) { record in
            Group {
                ProgressPhotoDetailView(repository: repository, record: record)
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .sheet(item: comparisonPresentationBinding(expected: expectedComparison)) { route in
            PhotoComparisonShareView(source: route.presentation.source, sourceVersion: route.id,
                freshSource: { expected in
                    freshComparisonSource(expected, for: route)
                }, lifetime: route.presentation.lifetime)
                .environment(\.calendar, shareCalendar)
                .environment(\.zeroOneLocalization, localization)
                .environment(\.locale, localization.locale)
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
                .zoSheet(theme)
        }
        .alert(localization.string("Comparison not available"), isPresented: $sharingUnavailable) {
            Button(localization.string("OK"), role: .cancel) { }
        } message: {
            Text(verbatim: localization.string("These saved photos changed or are unavailable. Open the comparison again."))
        }
        .onDisappear {
            // An owned sheet can cover this view. Root pre-teardown hooks own
            // ancestor removal; a cover must keep its retained permit alive.
            if let expectedComparison, presentedComparison?.id != expectedComparison.id {
                expectedComparison.authority.close(expectedComparison.presentation)
            }
            guard selectedRecord == nil, presentedComparison == nil, !captureIsActive else { return }
            if pendingComparison?.id == expectedPendingID { cancelPendingComparison() }
            if modalRevision == expectedModalRevision { modalRevision = UUID() }
        }
        .task {
            presentReviewStateIfNeeded()
        }
    }

    @MainActor private var comparisonShareCallback: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)? {
        if let onShare { return onShare }
        guard let authority = photoShareAuthority, let coordinator = shareCoordinator else { return nil }
        let expectedModalRevision = modalRevision
        return { first, second in
            guard modalRevision == expectedModalRevision,
                  photoShareAuthority === authority, shareCoordinator === coordinator else { return }
            presentComparison(first: first, second: second, authority: authority, coordinator: coordinator)
        }
    }

    @MainActor private func presentComparison(first: ProgressPhotoRecord, second: ProgressPhotoRecord,
        authority: PhotoComparisonShareHostAuthority, coordinator: ZeroOneRootShareCoordinator) {
        guard pendingComparison == nil, presentedComparison == nil, selectedRecord == nil, !captureIsActive,
              let rootRequest = coordinator.beginRequest() else { return }
        // Capture the original root ticket and selected host revision before
        // starting the task. A resumed audit never obtains a replacement ticket.
        let request = ComparisonRequest(id: UUID(), first: first, second: second,
            authority: authority, coordinator: coordinator, rootRequest: rootRequest,
            hostRevision: authority.revision, modalRevision: modalRevision)
        pendingComparison = request
        comparisonTask = Task { @MainActor in
            defer {
                if pendingComparison?.id == request.id {
                    pendingComparison = nil
                    comparisonTask = nil
                }
            }
            guard comparisonRequestIsCurrent(request), authority.revision == request.hostRevision else { return }
            let presentation = await coordinator.preparePhoto(first: first, second: second,
                host: authority, request: rootRequest)
            guard let presentation else {
                if comparisonRequestIsCurrent(request) { sharingUnavailable = true }
                return
            }
            // Successful preparation intentionally configures the host and
            // advances its revision. The coordinator checked the captured
            // selection across every await; the retained token checks setup.
            guard comparisonRequestIsCurrent(request),
                  presentation.source.first.record == first, presentation.source.second.record == second,
                  presentation.lifetime.allows(presentation.id) else {
                authority.close(presentation)
                return
            }
            presentedComparison = ComparisonRoute(presentation: presentation, authority: authority,
                coordinator: coordinator, rootRequest: rootRequest)
        }
    }

    @MainActor private func comparisonRequestIsCurrent(_ request: ComparisonRequest) -> Bool {
        !Task.isCancelled && pendingComparison?.id == request.id
            && photoShareAuthority === request.authority && shareCoordinator === request.coordinator
            && request.coordinator.isCurrent(request.rootRequest) && modalRevision == request.modalRevision
            && selectedRecord == nil && presentedComparison == nil && !captureIsActive
            && repository.isAvailable && repository.entries.contains(request.first)
            && repository.entries.contains(request.second)
    }

    @MainActor private func cancelPendingComparison() {
        comparisonTask?.cancel()
        pendingComparison = nil
        comparisonTask = nil
    }

    @MainActor private func freshComparisonSource(_ expected: PhotoComparisonShareSource,
        for route: ComparisonRoute) -> PhotoComparisonShareSnapshot? {
        guard presentedComparison?.id == route.id, photoShareAuthority === route.authority,
              shareCoordinator === route.coordinator, route.coordinator.isCurrent(route.rootRequest) else {
            route.authority.close(route.presentation)
            return nil
        }
        return route.authority.freshSource(expected, for: route.presentation)
    }

    @MainActor private func comparisonPresentationBinding(expected: ComparisonRoute?) -> Binding<ComparisonRoute?> {
        Binding(get: { presentedComparison }, set: { replacement in
            guard presentedComparison?.id == expected?.id else { return }
            if let current = presentedComparison, current.id != replacement?.id {
                current.authority.close(current.presentation)
            }
            if presentedComparison?.id != replacement?.id { modalRevision = UUID() }
            presentedComparison = replacement
        })
    }

    @MainActor private func selectedRecordBinding(expected: ProgressPhotoRecord?, revision: UUID) -> Binding<ProgressPhotoRecord?> {
        Binding(get: { selectedRecord }, set: { replacement in
            setSelectedRecord(replacement, expected: expected, revision: revision)
        })
    }

    @MainActor private func setSelectedRecord(_ replacement: ProgressPhotoRecord?,
        expected: ProgressPhotoRecord?, revision: UUID) {
        guard selectedRecord == expected, modalRevision == revision, selectedRecord != replacement else { return }
        cancelPendingComparison()
        shareCoordinator?.revokeBeforeRouteChange()
        modalRevision = UUID()
        selectedRecord = replacement
    }

    @MainActor private func captureActivityChanged(_ event: ProgressPhotoCaptureActivity) {
        switch event {
        case .began(let id):
            guard captureActivityID != id else { return }
            cancelPendingComparison()
            shareCoordinator?.revokeBeforeRouteChange()
            modalRevision = UUID()
            captureActivityID = id
        case .ended(let id):
            guard captureActivityID == id else { return }
            modalRevision = UUID()
            captureActivityID = nil
        }
    }

    private var privacyHeader: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Label("Only on this iPhone. Never synced.", systemImage: "lock")
                .zoText(.caption).labelStyle(ZOIconLabelStyle())

                .foregroundStyle(secondaryInk)

            Text("Before and after")
                .zoText(.display)

                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text("Your own photos, on your own timeline. Choose two dates to compare.")
                .zoText(.body)
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xl) {
            Spacer(minLength: 36)

            Image(systemName: "photo.on.rectangle.angled")
                .zoIcon(ZOIcon.feature)
                .foregroundStyle(theme.textPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("Start a private timeline.")
                    .zoText(.title)
                    .foregroundStyle(theme.textPrimary)

                Text("Save a photo when it is useful to compare your own progress over time.")
                    .zoText(.body)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }


            Text("No upload or analysis. Only photos you choose or take.")
                .zoText(.caption)
                .foregroundStyle(tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        let expectedRecord = selectedRecord
        let expectedRevision = modalRevision
        return VStack(alignment: .leading, spacing: ZOSpace.l) {
            HStack(alignment: .center) {
                Text("Your photos")
                    .zoText(.caption)

                    .foregroundStyle(secondaryInk)

                Spacer()


            }

            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : [GridItem(.flexible(), spacing: ZOSpace.s), GridItem(.flexible(), spacing: ZOSpace.s)],
                spacing: ZOSpace.s
            ) {
                ForEach(repository.entries) { record in
                    Button {
                        setSelectedRecord(record, expected: expectedRecord, revision: expectedRevision)
                    } label: {
                        ProgressPhotoTimelineTile(repository: repository, record: record)
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingComparison != nil || presentedComparison != nil || captureIsActive)
                    .accessibilityHint("Opens the full private photo.")
                }
            }
        }
    }

    private var unavailableRepositoryState: some View {
        ContentUnavailableView(
            "Progress photos unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("01 could not read the private local photo log. No files were removed.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    @MainActor
    private func presentReviewStateIfNeeded() {
        #if DEBUG
        let state = ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_PROGRESS_PHOTO_STATE"]?.lowercased()
        if state == "detail" || state == "delete" || state == "unavailable" {
            setSelectedRecord(repository.entries.first, expected: selectedRecord, revision: modalRevision)
        }
        #endif
    }
}

private struct ProgressPhotoTimelineTile: View {
    let repository: ProgressPhotoRepository
    let record: ProgressPhotoRecord

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var tertiaryInk: Color { contrast == .increased ? theme.textSecondary : theme.textTertiary }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            ZStack {
                theme.surfaceSecondary

                if let data = repository.thumbnailData(for: record),
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                } else {
                    VStack(spacing: ZOSpace.s) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .zoIcon(ZOIcon.row)
                        Text("Unavailable")
                            .zoText(.caption)
                    }
                    .foregroundStyle(secondaryInk)
                }
            }
            .frame(height: 188)
            .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))

            Text(LocalizedStringKey(record.label.title))
                .zoText(.caption)

                .foregroundStyle(secondaryInk)

            Text(record.createdAt, format: .dateTime.day().month(.abbreviated).year())
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum ProgressPhotoCapturePresentation {
    case primary
    case compact
    case completion
}

enum ProgressPhotoCaptureActivity {
    case began(UUID)
    case ended(UUID)
}

struct ProgressPhotoCaptureButton: View {
    @Bindable var repository: ProgressPhotoRepository
    let initialLabel: ProgressPhotoLabel
    let presentation: ProgressPhotoCapturePresentation
    var onCaptureActivity: (ProgressPhotoCaptureActivity) -> Void = { _ in }

    @State private var captureFlowID: UUID?
    @State private var endedLibraryFlowID: UUID?
    @State private var showsLibrary = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openURL) private var openURL
    @Environment(\.photoComparisonShareHostAuthority) private var photoShareAuthority
    @State private var selectedItem: PhotosPickerItem?
    @State private var draft: ProgressPhotoDraft?
    @State private var errorMessage: String?
    @State private var showsCamera = false
    @State private var pendingCameraData: Data?
    @State private var cameraCaptureFailed = false
    @State private var canOpenCameraSettings = false
    @State private var isPreparing = false
    @State private var isRequestingCamera = false
    @State private var cameraRequest: Task<Void, Never>?
    @State private var capturedPose: ProgressPhotoPose?
    @State private var libraryAfterCamera = false

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        let expectedFlowID = captureFlowID
        captureControls
        .onChange(of: selectedItem) { _, item in
            guard let item, selectedItem == item, let flowID = captureFlowID else { return }
            Task { await prepare(item, flowID: flowID) }
        }
        .fullScreenCover(isPresented: cameraPresentationBinding(expected: expectedFlowID),
            onDismiss: { prepareCapturedPhoto(flowID: expectedFlowID) }) {
            // Proof 47: the 01 camera, with the last photo in the same pose as a ghost.
            ProgressCameraView(ghost: { pose in
                guard let record = ProgressPhotoPoseStore().ghost(for: pose, in: repository.entries),
                      let data = repository.imageData(for: record), let image = UIImage(data: data) else { return nil }
                return (image, record.createdAt)
            }, onUse: { data, pose in
                guard captureFlowID == expectedFlowID, expectedFlowID != nil else { return }
                pendingCameraData = data
                capturedPose = pose
                showsCamera = false
            }, onLibrary: {
                guard captureFlowID == expectedFlowID, expectedFlowID != nil else { return }
                pendingCameraData = nil
                libraryAfterCamera = true
                showsCamera = false
            }, onCancel: {
                guard captureFlowID == expectedFlowID, expectedFlowID != nil else { return }
                pendingCameraData = nil
                showsCamera = false
            })
            .zeroOneTheme(theme)
        }
        .sheet(item: draftPresentationBinding(expected: expectedFlowID, draftID: draft?.id), onDismiss: {
            guard captureFlowID == expectedFlowID else { return }
            selectedItem = nil
            finishCaptureActivityIfIdle(expectedFlowID)
        }) { draft in
            Group {
                ProgressPhotoReviewView(
                    draft: draft,
                    onSave: { resolvedDraft in
                        guard captureFlowID == expectedFlowID, self.draft?.id == draft.id else { return false }
                        do {
                            photoShareAuthority?.revokeAll(before: .photoMutation)
                            let saved = try repository.save(resolvedDraft)
                            if let pose = capturedPose { ProgressPhotoPoseStore().set(pose, for: saved.id) }
                            capturedPose = nil
                            self.draft = nil
                            return true
                        } catch {
                            return false
                        }
                    },
                    onCancel: {
                        guard captureFlowID == expectedFlowID, self.draft?.id == draft.id else { return }
                        self.draft = nil
                    }
                )
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
        .alert(
            "Photo not available",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    guard captureFlowID == expectedFlowID else { return }
                    if !$0 {
                        errorMessage = nil
                        finishCaptureActivityIfIdle(expectedFlowID)
                    }
                }
            )
        ) {
            if canOpenCameraSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(localization.string(errorMessage ?? "The selected photo could not be prepared."))
        }
        .task {
            await prepareReviewFixtureIfNeeded()
        }
        .onDisappear {
            guard captureFlowID == expectedFlowID, !showsCamera, !showsLibrary, draft == nil else { return }
            cameraRequest?.cancel()
            // A canceled permission task ends its own exact flow in defer.
            finishCaptureActivityIfIdle(expectedFlowID)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch presentation {
        case .primary:
            HStack {
                Text("Take progress photo")
                Spacer()
                Image(systemName: "camera")
            }
        case .compact:
            Label("Take photo", systemImage: "camera")
                .zoText(.section).labelStyle(ZOIconLabelStyle())
                .foregroundStyle(theme.textPrimary)
                .frame(minHeight: 44)
        case .completion:
            HStack {
                Image(systemName: "camera")
                Text("Take progress photo")
                Spacer()
                Image(systemName: "chevron.right")
                    .zoIcon(ZOIcon.row)
            }
        }
    }

    @ViewBuilder
    private var captureControls: some View {
        if case .compact = presentation {
            HStack(spacing: ZOSpace.s) { cameraControl; libraryControl }
                .disabled(isRequestingCamera || isPreparing)
        } else {
            VStack(spacing: ZOSpace.s) { cameraControl; libraryControl }
                .disabled(isRequestingCamera || isPreparing)
        }
    }

    private var libraryControl: some View {
        let expectedFlowID = captureFlowID
        return Button {
            guard captureFlowID == nil else { return }
            _ = beginCaptureActivity()
            showsLibrary = true
        } label: {
            if case .compact = presentation {
                Image(systemName: "photo")
                    .foregroundStyle(secondaryInk)
                    .frame(width: 44, height: 44)
            } else {
                Label("Choose from Photos", systemImage: "photo")
                    .zoText(.body).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(secondaryInk)
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose from Photos")
        .photosPicker(isPresented: libraryPresentationBinding(expected: expectedFlowID),
            selection: librarySelectionBinding(expected: expectedFlowID), matching: .images)
    }

    @ViewBuilder
    private var cameraControl: some View {
        switch presentation {
        case .primary:
            Button(action: requestCamera) { label }
                .buttonStyle(ZOButtonStyle(.primary))
        case .compact:
            Button(action: requestCamera) { label }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Take progress photo")
        case .completion:
            Button(action: requestCamera) { label }
                .buttonStyle(ZOButtonStyle(.secondary))
        }
    }

    private func requestCamera() {
        guard captureFlowID == nil, !isRequestingCamera, !isPreparing else { return }
        let flowID = beginCaptureActivity()
        canOpenCameraSettings = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "A camera is not available on this device. You can choose a photo from Photos instead."
            return
        }
        isRequestingCamera = true
        cameraRequest = Task { @MainActor in
            defer {
                if captureFlowID == flowID {
                    isRequestingCamera = false
                    cameraRequest = nil
                    finishCaptureActivityIfIdle(flowID)
                }
            }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard !Task.isCancelled, captureFlowID == flowID else { return }
            guard allowed else {
                canOpenCameraSettings = AVCaptureDevice.authorizationStatus(for: .video) == .denied
                errorMessage = "Camera access is off. You can change access in Settings or choose a photo from Photos."
                return
            }
            pendingCameraData = nil
            cameraCaptureFailed = false
            showsCamera = true
        }
    }

    @MainActor private func beginCaptureActivity() -> UUID {
        if let captureFlowID { return captureFlowID }
        let id = UUID()
        endedLibraryFlowID = nil
        onCaptureActivity(.began(id))
        captureFlowID = id
        return id
    }

    @MainActor private func finishCaptureActivityIfIdle(_ expected: UUID?) {
        guard let expected, captureFlowID == expected, !isRequestingCamera, !isPreparing,
              !showsCamera, !showsLibrary, draft == nil, selectedItem == nil, pendingCameraData == nil,
              errorMessage == nil else { return }
        captureFlowID = nil
        onCaptureActivity(.ended(expected))
    }

    @MainActor private func cameraPresentationBinding(expected: UUID?) -> Binding<Bool> {
        Binding(get: { showsCamera }, set: { replacement in
            guard let expected, captureFlowID == expected else { return }
            showsCamera = replacement
        })
    }

    @MainActor private func draftPresentationBinding(expected: UUID?, draftID: UUID?) -> Binding<ProgressPhotoDraft?> {
        Binding(get: { draft }, set: { replacement in
            guard let expected, captureFlowID == expected, draft?.id == draftID else { return }
            draft = replacement
        })
    }

    @MainActor private func libraryPresentationBinding(expected: UUID?) -> Binding<Bool> {
        Binding(get: { showsLibrary }, set: { replacement in
            guard captureFlowID == expected, expected != nil else { return }
            showsLibrary = replacement
            if !replacement {
                endedLibraryFlowID = expected
                finishCaptureActivityIfIdle(expected)
            }
        })
    }

    @MainActor private func librarySelectionBinding(expected: UUID?) -> Binding<PhotosPickerItem?> {
        Binding(get: { selectedItem }, set: { replacement in
            // Native dismissal and selection writes can arrive in either order.
            // A late result may restart only its just-ended flow, never a newer one.
            guard let expected, captureFlowID == expected
                || (captureFlowID == nil && endedLibraryFlowID == expected) else { return }
            if replacement != nil, captureFlowID == nil { _ = beginCaptureActivity() }
            selectedItem = replacement
        })
    }

    private func prepareCapturedPhoto(flowID: UUID?) {
        guard let flowID, captureFlowID == flowID else { return }
        if cameraCaptureFailed {
            cameraCaptureFailed = false
            errorMessage = "The captured photo could not be prepared. Nothing was saved."
        }
        guard let data = pendingCameraData else {
            if libraryAfterCamera {
                // "Choose from library" inside the camera continues this same flow.
                libraryAfterCamera = false
                showsLibrary = true
                return
            }
            finishCaptureActivityIfIdle(flowID)
            return
        }
        Task { await prepare(data, flowID: flowID) }
    }

    @MainActor
    private func prepare(_ item: PhotosPickerItem, flowID: UUID) async {
        guard captureFlowID == flowID, selectedItem == item, !isPreparing else { return }
        canOpenCameraSettings = false
        isPreparing = true
        defer {
            if captureFlowID == flowID {
                isPreparing = false
                finishCaptureActivityIfIdle(flowID)
            }
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ProgressPhotoStoreError.invalidImage
            }
            guard !Task.isCancelled, captureFlowID == flowID, selectedItem == item else { return }
            let prepared = try await repository.makeDraft(from: data, label: initialLabel)
            guard !Task.isCancelled, captureFlowID == flowID, selectedItem == item else { return }
            draft = prepared
        } catch {
            guard captureFlowID == flowID, selectedItem == item else { return }
            errorMessage = "The selected photo could not be prepared. No local file was created."
            selectedItem = nil
        }
    }

    @MainActor
    private func prepare(_ data: Data, flowID: UUID) async {
        guard captureFlowID == flowID, !isPreparing else { return }
        isPreparing = true
        pendingCameraData = nil
        defer {
            if captureFlowID == flowID {
                isPreparing = false
                finishCaptureActivityIfIdle(flowID)
            }
        }
        do {
            let prepared = try await repository.makeDraft(from: data, label: initialLabel)
            guard !Task.isCancelled, captureFlowID == flowID else { return }
            draft = prepared
        } catch {
            guard captureFlowID == flowID else { return }
            errorMessage = "The captured photo could not be prepared. Nothing was saved."
        }
    }

    @MainActor
    private func prepareReviewFixtureIfNeeded() async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_PROGRESS_PHOTO_STATE"]?.lowercased() == "review",
              draft == nil,
              let data = ProgressPhotoReviewFixtures.sourceImageData() else { return }
        let flowID = beginCaptureActivity()
        isPreparing = true
        defer {
            if captureFlowID == flowID {
                isPreparing = false
                finishCaptureActivityIfIdle(flowID)
            }
        }
        let prepared = try? await repository.makeDraft(
            from: data,
            label: initialLabel,
            createdAt: ProgressPhotoReviewFixtures.primaryDate
        )
        guard !Task.isCancelled, captureFlowID == flowID else { return }
        draft = prepared
        #endif
    }
}

private struct ProgressPhotoReviewView: View {
    let draft: ProgressPhotoDraft
    let onSave: (ProgressPhotoDraft) -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selectedLabel: ProgressPhotoLabel
    @State private var saveFailed = false

    init(
        draft: ProgressPhotoDraft,
        onSave: @escaping (ProgressPhotoDraft) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedLabel = State(initialValue: draft.label)
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.xl) {
                    if let image = UIImage(data: draft.imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text("Date")
                            .zoText(.caption)
                            .foregroundStyle(secondaryInk)
                        Text(draft.createdAt, format: .dateTime.day().month(.wide).year())
                            .zoText(.title)
                    }

                    ZOSegmentedControl("Photo label", selection: $selectedLabel, options: ProgressPhotoLabel.allCases.map { label in ZOSegment(value: label, label: Text(LocalizedStringKey(label.title))) })

                    Text("Saving creates a private display copy and thumbnail. The selected library item and its metadata are not retained.")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZOSpace.xl)
            }
            .alert("Photo not saved", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("01 could not save this photo locally. Your draft is still here to retry or cancel.")
            }
            .navigationTitle("Review photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var resolvedDraft = draft
                        resolvedDraft.label = selectedLabel
                        if onSave(resolvedDraft) { dismiss() } else { saveFailed = true }
                    }
                    .fontWeight(.semibold)
                }
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
        }
    }
}

private struct ProgressPhotoDetailView: View {
    @Environment(\.photoComparisonShareHostAuthority) private var photoShareAuthority
    @Bindable var repository: ProgressPhotoRepository
    let record: ProgressPhotoRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsDeleteConfirmation = false
    @State private var deletionError = false

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.xl) {
                    if let data = repository.imageData(for: record),
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))
                    } else {
                        ContentUnavailableView(
                            "Photo unavailable",
                            systemImage: "photo.badge.exclamationmark",
                            description: Text("The local record remains, but its private image file could not be read.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }

                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text(LocalizedStringKey(record.label.title))
                            .zoText(.caption)

                            .foregroundStyle(secondaryInk)
                        Text(record.createdAt, format: .dateTime.day().month(.wide).year())
                            .zoText(.title)
                            .foregroundStyle(theme.textPrimary)
                    }

                    Button("Delete photo", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .buttonStyle(ZOButtonStyle(.secondary))
                }
                .padding(ZOSpace.xl)
            }
            .navigationTitle("Progress photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
        }
        .confirmationDialog(
            "Delete this private photo?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Photo", role: .destructive) {
                do {
                    photoShareAuthority?.revokeAll(before: .photoMutation)
                    try repository.delete(record)
                    dismiss()
                } catch {
                    deletionError = true
                }
            }
            Button("Keep Photo", role: .cancel) {}
        } message: {
            Text("This removes the 01-owned display copy and thumbnail from this iPhone.")
        }
        .alert("Photo not deleted", isPresented: $deletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("01 could not safely remove the local files. The record was kept.")
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_PROGRESS_PHOTO_STATE"]?.lowercased() == "delete" {
                try? await Task.sleep(for: .milliseconds(350))
                showsDeleteConfirmation = true
            }
            #endif
        }
    }
}

#if DEBUG
enum ProgressPhotoReviewFixtures {
    static let primaryDate = Date(timeIntervalSince1970: 1_787_990_400)

    @MainActor
    static func repository(state: String?) -> ProgressPhotoRepository {
        let store = ReviewProgressPhotoStore()
        guard let state, state != "empty", state != "review", state != "completion" else {
            return ProgressPhotoRepository(store: store)
        }

        if let sourceData = sourceImageData(),
           let encoded = try? ProgressPhotoImageEncoder.encode(sourceData) {
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000490")!
            let paths = LocalProgressPhotoStore.relativePaths(for: id)
            let record = ProgressPhotoRecord(
                id: id,
                createdAt: primaryDate,
                label: state == "unavailable" ? .postWorkout : .progress,
                imageRelativePath: paths.image,
                thumbnailRelativePath: paths.thumbnail
            )
            store.seed(
                record,
                imageData: state == "unavailable" ? nil : encoded.imageData,
                thumbnailData: state == "unavailable" ? nil : encoded.thumbnailData
            )
        }
        return ProgressPhotoRepository(store: store)
    }

    static func sourceImageData() -> Data? {
        let size = CGSize(width: 900, height: 1_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 2 / 255, green: 2 / 255, blue: 2 / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(red: 255 / 255, green: 254 / 255, blue: 42 / 255, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 180, y: 240, width: 540, height: 540))

            UIColor(red: 23 / 255, green: 23 / 255, blue: 23 / 255, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 350, y: 340, width: 200, height: 200))
            context.fill(CGRect(x: 390, y: 520, width: 120, height: 390))

            UIColor.white.withAlphaComponent(0.86).setFill()
            context.fill(CGRect(x: 110, y: 1_030, width: 680, height: 4))
        }.jpegData(compressionQuality: 0.95)
    }
}

private final class ReviewProgressPhotoStore: ProgressPhotoPersisting {
    private var records: [ProgressPhotoRecord] = []
    private var files: [String: Data] = [:]

    var isAvailable: Bool { true }

    func loadRecords() throws -> [ProgressPhotoRecord] { records }

    func save(_ record: ProgressPhotoRecord, imageData: Data, thumbnailData: Data) throws {
        records.removeAll { $0.id == record.id }
        records.append(record)
        files[record.imageRelativePath] = imageData
        files[record.thumbnailRelativePath] = thumbnailData
    }

    func delete(_ record: ProgressPhotoRecord) throws {
        files.removeValue(forKey: record.imageRelativePath)
        files.removeValue(forKey: record.thumbnailRelativePath)
        records.removeAll { $0.id == record.id }
    }

    func data(at relativePath: String, for record: ProgressPhotoRecord) -> Data? {
        files[relativePath]
    }

    func seed(_ record: ProgressPhotoRecord, imageData: Data?, thumbnailData: Data?) {
        records = [record]
        files[record.imageRelativePath] = imageData
        files[record.thumbnailRelativePath] = thumbnailData
    }
}
#endif
