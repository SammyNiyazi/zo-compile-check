import Foundation

struct ProgressPhotoPair: Equatable {
    let first: ProgressPhotoRecord
    let second: ProgressPhotoRecord

    /// Selections keep identity. Deleted selections fall back to two distinct surviving records.
    static func resolve(records: [ProgressPhotoRecord], firstID: UUID?, secondID: UUID?) -> Self? {
        let ordered = records.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        guard let first = ordered.first(where: { $0.id == firstID }) ?? ordered.first,
              let second = ordered.first(where: { $0.id == secondID && $0.id != first.id })
                ?? ordered.last(where: { $0.id != first.id }) else { return nil }
        return Self(first: first, second: second)
    }

    /// Sharing must retain the chosen identities; visual fallback is not authorization.
    static func selected(records: [ProgressPhotoRecord], firstID: UUID?, secondID: UUID?) -> Self? {
        guard let firstID, let secondID, firstID != secondID else { return nil }
        let firstMatches = records.filter { $0.id == firstID }
        let secondMatches = records.filter { $0.id == secondID }
        guard firstMatches.count == 1, secondMatches.count == 1 else { return nil }
        return Self(first: firstMatches[0], second: secondMatches[0])
    }

    /// Check exact presented versions and both full image copies before handing off.
    /// This is the repository's current observation; the root still owns a fresh store gate.
    func validatedForSharing(
        records: [ProgressPhotoRecord],
        isAvailable: Bool,
        isReadable: (ProgressPhotoRecord) -> Bool
    ) -> Self? {
        guard isAvailable,
              let current = Self.selected(records: records, firstID: first.id, secondID: second.id),
              current == self,
              isReadable(current.first), isReadable(current.second) else { return nil }
        return current
    }

    func labelKey(firstSlot: Bool) -> String {
        guard first.createdAt != second.createdAt else { return firstSlot ? "First photo" : "Second photo" }
        return firstSlot == (first.createdAt < second.createdAt) ? "Earlier photo" : "Later photo"
    }
}
