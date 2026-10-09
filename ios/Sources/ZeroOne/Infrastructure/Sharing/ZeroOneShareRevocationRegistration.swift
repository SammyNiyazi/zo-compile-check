/// A retained synchronous invalidation capability, never permission to export.
/// Immutable Sendable storage needs no callback lock or actor hop. The supplied
/// invalidator must revoke only thread-safe retained permits, complete before
/// returning, and remain safe for repeated/concurrent calls. It must not read UI
/// state, mutate the owner, await, enqueue revocation, or re-enter registration.
final class ZeroOneShareRevocationRegistration: Sendable {
    private let invalidator: @Sendable () -> Void

    init(invalidator: @escaping @Sendable () -> Void) {
        self.invalidator = invalidator
    }

    func revokeBeforeChange() {
        invalidator()
    }
}
