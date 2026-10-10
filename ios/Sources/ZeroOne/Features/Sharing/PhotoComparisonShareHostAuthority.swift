import Foundation
import Observation
import SwiftUI

/// A reference capability, never an asynchronous closure inside EnvironmentValues.
/// Root retains the same actual store used by its repository, including custom URLs.
/// Unknown fixture stores and missing audited readiness remain export-closed.
@MainActor
@Observable
final class PhotoComparisonShareHostAuthority {
    struct Presentation: Identifiable {
        let id: UUID
        let source: PhotoComparisonShareSource
        let lifetime: PhotoComparisonShareLifetime
    }

    enum Transition {
        case selection, photoMutation, route, account, readiness, hostDismissal
    }

    private let store: (any ProgressPhotoPersisting)?
    private var readiness: (@MainActor () -> Bool)?
    private var retained: [UUID: Presentation] = [:]
    private struct RegistryBinding {
        let registry: ZeroOneSharePermitRegistry
        let generation: ZeroOneSharePermitRegistry.Generation
    }
    private var registryBinding: RegistryBinding?
    private var registrations: [UUID: PhotoComparisonShareRegistration] = [:]
    private(set) var revision = UUID()

    init(store: (any ProgressPhotoPersisting)?) { self.store = store }

    var isInstalled: Bool { store != nil && readiness != nil && registryBinding != nil }

    /// Root may call this only after its source/account/host pre-transition audit
    /// is complete. It is deliberately not installed by this candidate packet.
    func installAuditedReadiness(_ readiness: @escaping @MainActor () -> Bool) {
        revokeAll(before: .readiness)
        self.readiness = readiness
    }

    /// Retain only Root's exact captured generation. This installs neither
    /// readiness nor registry admission; missing or closed coverage stays closed.
    func installSharePermitRegistry(_ registry: ZeroOneSharePermitRegistry,
                                   for generation: ZeroOneSharePermitRegistry.Generation) {
        revokeAll(before: .readiness)
        registryBinding = RegistryBinding(registry: registry, generation: generation)
    }

    func revokeAll(before transition: Transition) {
        registrations.values.forEach { $0.invalidate() }
        retained.values.forEach { $0.lifetime.invalidate() }
        registrations.removeAll()
        retained.removeAll()
        revision = UUID()
    }

    func close(_ presentation: Presentation) {
        // Retained documents keep this same token even after route removal.
        presentation.lifetime.invalidate()
        registrations[presentation.id]?.invalidate()
        retained[presentation.id]?.lifetime.invalidate()
        registrations.removeValue(forKey: presentation.id)
        retained.removeValue(forKey: presentation.id)
    }

    func prepare(first: ProgressPhotoRecord, second: ProgressPhotoRecord) throws -> Presentation? {
        guard let store, let binding = registryBinding, readiness?() == true, store.isAvailable else { return nil }
        let capturedRevision = revision
        let records = try store.loadRecords()
        var originals: [UUID: Data] = [:]
        for record in [first, second] {
            guard let bytes = store.data(at: record.imageRelativePath, for: record) else {
                throw PhotoComparisonShareError.unreadableImage
            }
            originals[record.id] = bytes
        }
        let source = try PhotoComparisonShareAuthority.capture(first: first, second: second,
            snapshot: .init(records: records, originalImageData: originals))
        // Two throwing manifest/master-byte passes bind the captured source.
        _ = try PhotoComparisonShareAuthority.read(store: store, source: source)
        guard revision == capturedRevision, readiness?() == true, store.isAvailable else { return nil }
        let version = UUID()
        let presentation = Presentation(id: version, source: source,
            lifetime: PhotoComparisonShareLifetime(sourceVersion: version))
        guard let registration = PhotoComparisonShareRegistration.acquire(
            lifetime: presentation.lifetime, sourceVersion: version,
            registry: binding.registry, generation: binding.generation) else { return nil }
        // Readiness can itself synchronously change owners. Check identity,
        // revision and the permanent token AFTER that final callback.
        guard readiness?() == true, store.isAvailable, revision == capturedRevision,
              registryBinding?.registry === binding.registry,
              registryBinding?.generation == binding.generation,
              binding.registry.currentGeneration == binding.generation,
              presentation.lifetime.allows(version) else {
            registration.invalidate()
            return nil
        }
        registrations[version] = registration
        retained[version] = presentation
        return presentation
    }

    func freshSource(_ expected: PhotoComparisonShareSource, for presentation: Presentation) -> PhotoComparisonShareSnapshot? {
        guard let store, let binding = registryBinding, let retainedPresentation = retained[presentation.id],
              retainedPresentation.source == expected, presentation.source == expected,
              retainedPresentation.lifetime === presentation.lifetime,
              readiness?() == true,
              isCurrentRegistration(for: presentation, binding: binding) else {
            close(presentation)
            return nil
        }
        let capturedRevision = revision
        guard let snapshot = try? PhotoComparisonShareAuthority.read(store: store, source: expected),
              revision == capturedRevision, retained[presentation.id]?.source == expected,
              retained[presentation.id]?.lifetime === presentation.lifetime,
              readiness?() == true,
              isCurrentRegistration(for: presentation, binding: binding) else {
            close(presentation)
            return nil
        }
        guard revision == capturedRevision else {
            close(presentation)
            return nil
        }
        return snapshot
    }

    private func isCurrentRegistration(for presentation: Presentation, binding: RegistryBinding) -> Bool {
        registryBinding?.registry === binding.registry
            && registryBinding?.generation == binding.generation
            && registrations[presentation.id]?.lifetime === presentation.lifetime
            && registrations[presentation.id]?.isCurrent == true
    }
}

private struct PhotoComparisonShareHostAuthorityKey: EnvironmentKey {
    static let defaultValue: PhotoComparisonShareHostAuthority? = nil
}

extension EnvironmentValues {
    var photoComparisonShareHostAuthority: PhotoComparisonShareHostAuthority? {
        get { self[PhotoComparisonShareHostAuthorityKey.self] }
        set { self[PhotoComparisonShareHostAuthorityKey.self] = newValue }
    }
}
