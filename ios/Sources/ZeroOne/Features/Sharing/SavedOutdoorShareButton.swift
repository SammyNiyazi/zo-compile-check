import SwiftUI

/// The actual summary/detail presenter owns this sheet. A parent modal does not
/// try to present over its own history/detail child. Both preparation and export
/// require the root's fresh saved-record authority.
@MainActor
struct SavedOutdoorShareButton: View {
    let record: OutdoorActivityRecord
    let canExport: @MainActor (OutdoorActivityRecord) async -> Bool

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneRootShareCoordinator) private var rootShareCoordinator
    @State private var presentedShare: Presentation?
    @State private var preparation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var showsUnavailable = false

    private struct Presentation: Identifiable {
        let record: OutdoorActivityRecord
        let permit: ZeroOneRootSharePresentation
        let coordinator: ZeroOneRootShareCoordinator
        let request: ZeroOneRootShareCoordinator.Request
        var id: UUID { permit.id }
    }

    var body: some View {
        let capturedPresentation = presentedShare
        Button { prepare() } label: {
            Text("Share")
        }
        .buttonStyle(ZOButtonStyle(.quiet))
        .frame(minHeight: 44)
        .disabled(preparation != nil)
        .accessibilityIdentifier("outdoor.saved.share")
        .sheet(item: presentationBinding(expected: capturedPresentation)) { presentation in
            ZOShareComposer(source: .outdoor(presentation.record), localization: localization,
                            canExport: { await authorize(presentation) },
                            sourceVersion: presentation.permit.id,
                            exportLifetime: presentation.permit.lifetime)
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
                .zoSheet(theme)
        }
        .alert("Sharing unavailable", isPresented: $showsUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("sharing.outdoor.saved.unavailable.detail")
        }
        .onChange(of: record) { _, _ in
            cancelPreparation()
            if let capturedPresentation { close(capturedPresentation) }
        }
        .onDisappear {
            cancelPreparation()
            if let capturedPresentation { close(capturedPresentation) }
        }
    }

    private func presentationBinding(expected: Presentation?) -> Binding<Presentation?> {
        Binding(get: { presentedShare }, set: { next in
            guard presentedShare?.id == expected?.id else { return }
            if let old = presentedShare { old.coordinator.close(old.permit) }
            presentedShare = next
        })
    }

    private func isCurrent(_ presentation: Presentation) -> Bool {
        !Task.isCancelled && record == presentation.record
            && presentedShare?.id == presentation.id
            && rootShareCoordinator === presentation.coordinator
            && presentation.coordinator.isCurrent(presentation.request)
    }

    private func authorize(_ presentation: Presentation) async -> Bool {
        guard isCurrent(presentation) else { return false }
        guard await presentation.coordinator.authorize(presentation.permit),
              isCurrent(presentation) else { return false }
        guard await canExport(presentation.record), isCurrent(presentation) else { return false }
        guard await presentation.coordinator.authorize(presentation.permit) else { return false }
        return isCurrent(presentation)
    }

    private func prepare() {
        guard preparation == nil, presentedShare == nil,
              let coordinator = rootShareCoordinator,
              let request = coordinator.beginRequest() else { showsUnavailable = true; return }
        let capturedRecord = record
        let capturedGeneration = UUID()
        generation = capturedGeneration
        preparation = Task { @MainActor in
            // Clear only this preparation after a superseded route ticket returns.
            defer { if generation == capturedGeneration { preparation = nil } }
            @MainActor func pendingIsCurrent() -> Bool {
                !Task.isCancelled && generation == capturedGeneration && record == capturedRecord
                    && rootShareCoordinator === coordinator && coordinator.isCurrent(request)
                    && presentedShare == nil
            }
            let allowed = await canExport(capturedRecord)
            guard pendingIsCurrent() else { return }
            guard allowed else { preparation = nil; showsUnavailable = true; return }
            let permit = await coordinator.prepareOutdoor(capturedRecord, request: request)
            guard let permit else {
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            guard pendingIsCurrent() else { coordinator.close(permit); return }
            guard await coordinator.authorize(permit), pendingIsCurrent() else {
                coordinator.close(permit)
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            let stillAllowed = await canExport(capturedRecord)
            guard pendingIsCurrent(), stillAllowed else {
                coordinator.close(permit)
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            guard await coordinator.authorize(permit), pendingIsCurrent() else {
                coordinator.close(permit)
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            preparation = nil
            presentedShare = Presentation(record: capturedRecord, permit: permit, coordinator: coordinator, request: request)
        }
    }

    private func close(_ presentation: Presentation) {
        presentation.coordinator.close(presentation.permit)
        guard presentedShare?.id == presentation.id else { return }
        presentedShare = nil
    }

    private func cancelPreparation() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
    }
}
