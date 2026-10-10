import Foundation

/// Retains the exact registry handle and permanent presentation token. Acquisition
/// never opens admission. Root must supply its already audited captured generation.
/// This object owns no UI or authority callbacks; release invalidates before removal.
final class PhotoComparisonShareRegistration: Sendable {
    let lifetime: PhotoComparisonShareLifetime
    private let sourceVersion: UUID
    private let registry: ZeroOneSharePermitRegistry
    private let generation: ZeroOneSharePermitRegistry.Generation
    private let handle: ZeroOneSharePermitRegistry.Registration

    private init(lifetime: PhotoComparisonShareLifetime, sourceVersion: UUID,
                 registry: ZeroOneSharePermitRegistry,
                 generation: ZeroOneSharePermitRegistry.Generation,
                 handle: ZeroOneSharePermitRegistry.Registration) {
        self.lifetime = lifetime
        self.sourceVersion = sourceVersion
        self.registry = registry
        self.generation = generation
        self.handle = handle
    }

    static func acquire(lifetime: PhotoComparisonShareLifetime, sourceVersion: UUID,
                        registry: ZeroOneSharePermitRegistry,
                        generation: ZeroOneSharePermitRegistry.Generation) -> PhotoComparisonShareRegistration? {
        guard let handle = registry.register(lifetime, for: generation) else { return nil }
        let registration = PhotoComparisonShareRegistration(lifetime: lifetime,
            sourceVersion: sourceVersion, registry: registry, generation: generation, handle: handle)
        guard registration.isCurrent else {
            registration.invalidate()
            return nil
        }
        return registration
    }

    var isCurrent: Bool {
        registry.currentGeneration == generation && lifetime.allows(sourceVersion)
    }

    /// Repeated/concurrent removal uses the exact immutable handle. The actual
    /// token is invalidated before either registry or route may release retention.
    func invalidate() {
        lifetime.invalidate()
        registry.remove(handle)
    }

    deinit { invalidate() }
}
