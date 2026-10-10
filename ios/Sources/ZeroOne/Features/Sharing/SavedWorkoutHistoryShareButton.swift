import SwiftUI

/// Both the selected record and all history used by the poster are acknowledged.
/// The root supplies fresh authority; a standalone preview has none by default.
struct SavedWorkoutHistoryShareSnapshot: Identifiable, Equatable {
    let entry: WorkoutHistoryEntry
    let acknowledgedHistory: [WorkoutHistoryEntry]
    let authorityGeneration: UUID
    var id: UUID { entry.id }
}

@MainActor
final class SavedWorkoutHistoryShareAuthority: Equatable {
    private var generation = UUID()
    private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private var resolver: (@MainActor (WorkoutHistoryEntry, UUID) async -> SavedWorkoutHistoryShareSnapshot?)?
    private var exporter: (@MainActor (SavedWorkoutHistoryShareSnapshot) async -> Bool)?

    nonisolated static func == (lhs: SavedWorkoutHistoryShareAuthority, rhs: SavedWorkoutHistoryShareAuthority) -> Bool {
        lhs === rhs
    }

    /// This capability revokes retained permits synchronously; it never grants export.
    /// Replacement/removal revokes old and incoming permits before changing ownership.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    /// Root must verify the exact nonnil installed capability before granting export.
    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    func install(
        resolve: @escaping @MainActor (WorkoutHistoryEntry, UUID) async -> SavedWorkoutHistoryShareSnapshot?,
        canExport: @escaping @MainActor (SavedWorkoutHistoryShareSnapshot) async -> Bool
    ) {
        revoke()
        resolver = resolve
        exporter = canExport
    }

    func revoke() {
        shareRevocationRegistration?.revokeBeforeChange()
        generation = UUID()
        resolver = nil
        exporter = nil
    }

    func resolve(_ entry: WorkoutHistoryEntry) async -> SavedWorkoutHistoryShareSnapshot? {
        guard !Task.isCancelled, let resolver else { return nil }
        let captured = generation
        let result = await resolver(entry, captured)
        guard !Task.isCancelled, generation == captured,
              result?.authorityGeneration == captured else { return nil }
        return result
    }

    func canExport(_ snapshot: SavedWorkoutHistoryShareSnapshot) async -> Bool {
        guard !Task.isCancelled, snapshot.authorityGeneration == generation, let exporter else { return false }
        let captured = generation
        let allowed = await exporter(snapshot)
        return !Task.isCancelled && allowed && generation == captured
    }
}

private struct SavedWorkoutHistoryShareAuthorityKey: EnvironmentKey {
    static let defaultValue: SavedWorkoutHistoryShareAuthority? = nil
}

extension EnvironmentValues {
    var savedWorkoutHistoryShareAuthority: SavedWorkoutHistoryShareAuthority? {
        get { self[SavedWorkoutHistoryShareAuthorityKey.self] }
        set { self[SavedWorkoutHistoryShareAuthorityKey.self] = newValue }
    }
}

/// The detail that is actually on screen presents the composer itself. Root's
/// outer Profile sheet never tries to present over its History child.
@MainActor
struct SavedWorkoutHistoryShareButton: View {
    let entry: WorkoutHistoryEntry
    let authority: SavedWorkoutHistoryShareAuthority

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneRootShareCoordinator) private var rootShareCoordinator
    @State private var presentedShare: Presentation?
    @State private var preparation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var showsUnavailable = false

    private struct Presentation: Identifiable {
        let snapshot: SavedWorkoutHistoryShareSnapshot
        let permit: ZeroOneRootSharePresentation
        let coordinator: ZeroOneRootShareCoordinator
        let request: ZeroOneRootShareCoordinator.Request
        var id: UUID { permit.id }
    }

    var body: some View {
        let capturedPresentation = presentedShare
        Button { prepare() } label: {
            Label(localization.string("Share saved workout"), systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(ZOButtonStyle(.round))
        .disabled(preparation != nil)
        .accessibilityIdentifier("history.saved.share")
        .sheet(item: presentationBinding(expected: capturedPresentation)) { presentation in
            let acknowledged = presentation.snapshot
            ZOShareComposer(
                source: .workout(acknowledged.entry, acknowledgedHistory: acknowledged.acknowledgedHistory),
                localization: localization,
                canExport: { await authorize(presentation) },
                sourceVersion: presentation.permit.id,
                exportLifetime: presentation.permit.lifetime
            )
            .zeroOneTheme(theme)
            .preferredColorScheme(theme.colorScheme)
            .zoSheet(theme)
        }
        .alert(localization.string("Sharing unavailable"), isPresented: $showsUnavailable) {
            Button(localization.string("OK"), role: .cancel) { }
        } message: {
            Text(verbatim: localization.string("Your saved workout could not be verified. Try again when your activity has finished saving."))
        }
        .onChange(of: entry) { _, _ in
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
            // An old nil callback can close only the presentation it captured.
            guard presentedShare?.id == expected?.id else { return }
            if let old = presentedShare { old.coordinator.close(old.permit) }
            presentedShare = next
        })
    }

    private func isCurrent(_ presentation: Presentation) -> Bool {
        !Task.isCancelled && entry == presentation.snapshot.entry
            && presentedShare?.id == presentation.id
            && rootShareCoordinator === presentation.coordinator
            && presentation.coordinator.isCurrent(presentation.request)
    }

    private func authorize(_ presentation: Presentation) async -> Bool {
        guard isCurrent(presentation) else { return false }
        guard await presentation.coordinator.authorize(presentation.permit),
              isCurrent(presentation) else { return false }
        guard await authority.canExport(presentation.snapshot),
              isCurrent(presentation) else { return false }
        guard await presentation.coordinator.authorize(presentation.permit) else { return false }
        return isCurrent(presentation)
    }

    private func prepare() {
        guard preparation == nil, presentedShare == nil,
              let coordinator = rootShareCoordinator,
              let request = coordinator.beginRequest() else { showsUnavailable = true; return }
        let expected = entry
        let capturedGeneration = UUID()
        generation = capturedGeneration
        preparation = Task { @MainActor in
            // Clear only this preparation after a superseded route ticket returns.
            defer { if generation == capturedGeneration { preparation = nil } }
            @MainActor func pendingIsCurrent() -> Bool {
                !Task.isCancelled && generation == capturedGeneration && entry == expected
                    && rootShareCoordinator === coordinator && coordinator.isCurrent(request)
                    && presentedShare == nil
            }
            let snapshot = await authority.resolve(expected)
            guard pendingIsCurrent() else { return }
            guard let snapshot, snapshot.entry == expected else {
                preparation = nil; showsUnavailable = true; return
            }
            let sourceAllowed = await authority.canExport(snapshot)
            guard pendingIsCurrent() else { return }
            guard sourceAllowed else { preparation = nil; showsUnavailable = true; return }
            let permit = await coordinator.prepareWorkout(snapshot.entry,
                acknowledgedHistory: snapshot.acknowledgedHistory, request: request)
            guard let permit else {
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            // Every acquired stale lease is explicitly released, even on cancellation.
            guard pendingIsCurrent() else { coordinator.close(permit); return }
            guard await coordinator.authorize(permit), pendingIsCurrent() else {
                coordinator.close(permit)
                if pendingIsCurrent() { preparation = nil; showsUnavailable = true }
                return
            }
            let stillSourceAllowed = await authority.canExport(snapshot)
            guard pendingIsCurrent(), stillSourceAllowed else {
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
            presentedShare = Presentation(snapshot: snapshot, permit: permit, coordinator: coordinator, request: request)
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
