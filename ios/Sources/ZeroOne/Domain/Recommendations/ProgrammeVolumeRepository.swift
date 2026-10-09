import Foundation
import Observation

struct ProgrammeVolumeSnapshot: Codable, Equatable {
    let version: Int
    var revisions: [ProgrammeVolumeRevision]
    static let empty = Self(version: 1, revisions: [])
    func isValid(at now: Date) -> Bool {
        version == 1 && now.timeIntervalSinceReferenceDate.isFinite && revisions.count <= 30
            && Set(revisions.map(\.programmeID)).count == revisions.count
            && revisions.allSatisfy { $0.isValid && $0.acceptedAt <= now }
    }
}

protocol ProgrammeVolumePersisting {
    func load() throws -> ProgrammeVolumeSnapshot
    func save(_ snapshot: ProgrammeVolumeSnapshot) throws
}

struct UserDefaultsProgrammeVolumeStore: ProgrammeVolumePersisting {
    let defaults: UserDefaults
    let key: String
    init(defaults: UserDefaults = .standard, key: String = "zeroone.programmeVolume.v1") {
        self.defaults = defaults; self.key = key
    }
    func load() throws -> ProgrammeVolumeSnapshot {
        guard let data = defaults.data(forKey: key) else {
            guard defaults.object(forKey: key) == nil else { throw ProgrammeVolumeError.unavailable }
            return .empty
        }
        return try JSONDecoder().decode(ProgrammeVolumeSnapshot.self, from: data)
    }
    func save(_ snapshot: ProgrammeVolumeSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw ProgrammeVolumeError.unavailable }
    }
}

@MainActor @Observable final class ProgrammeVolumeRepository {
    private let store: any ProgrammeVolumePersisting
    private(set) var snapshot = ProgrammeVolumeSnapshot.empty
    private(set) var isAvailable = false
    init(store: any ProgrammeVolumePersisting = UserDefaultsProgrammeVolumeStore()) {
        self.store = store; reload()
    }
    @discardableResult func reload(at now: Date = .now) -> Bool {
        do { snapshot = try verified(at: now); isAvailable = true; return true }
        catch { isAvailable = false; return false }
    }
    func revision(for id: WorkoutProgrammeID) throws -> ProgrammeVolumeRevision? {
        guard isAvailable else { throw ProgrammeVolumeError.unavailable }
        return snapshot.revisions.first { $0.programmeID == id }
    }
    func effective(_ programme: WorkoutProgramme) throws -> WorkoutProgramme {
        try ProgrammeVolumeSource.effective(programme, revision: revision(for: programme.id))
    }
    /// Fresh collection, source-qualified proposal, acknowledged readback. This
    /// synchronous host path is not an atomic cross-process compare-and-swap.
    func accept(_ presented: ProgrammeVolumeProposal, context: ProgrammeVolumeContext,
                at now: Date, calendar: Calendar = .current) throws {
        let current: ProgrammeVolumeSnapshot
        do { current = try verified(at: now) }
        catch { isAvailable = false; throw ProgrammeVolumeError.unavailable }
        guard current.revisions.first(where: { $0.programmeID == context.programme.id }) == context.revision else {
            snapshot = current; isAvailable = true; throw ProgrammeVolumeError.stale
        }
        let proposal = try ProgrammeVolumePlanner().revalidated(presented, context: context, at: now, calendar: calendar)
        var updated = current
        updated.revisions.removeAll { $0.programmeID == context.programme.id }
        if proposal.change == .ease {
            updated.revisions.append(.init(programmeID: context.programme.id, baseline: proposal.baseline,
                policyVersion: ProgrammeVolumePlanner.policyVersion, acceptedAt: now))
        }
        updated.revisions.sort { $0.programmeID.rawValue < $1.programmeID.rawValue }
        do {
            try store.save(updated)
            guard try verified(at: now) == updated else { throw ProgrammeVolumeError.unavailable }
            snapshot = updated; isAvailable = true
        } catch {
            // The underlying write may have happened. Never claim unchanged state.
            isAvailable = false; throw ProgrammeVolumeError.saveNotConfirmed
        }
    }
    private func verified(at now: Date) throws -> ProgrammeVolumeSnapshot {
        let value = try store.load()
        guard value.isValid(at: now) else { throw ProgrammeVolumeError.unavailable }
        return value
    }
}
