import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class SavedWorkoutHistoryShareAuthorityTests: XCTestCase {
    func testUninstalledCapabilityCannotResolveOrExport() async {
        let authority = SavedWorkoutHistoryShareAuthority()
        let entry = savedEntry()
        let result = await authority.resolve(entry)
        let allowed = await authority.canExport(snapshot(entry, generation: UUID()))
        XCTAssertNil(result)
        XCTAssertFalse(allowed)
    }

    func testRevocationDuringSuspendedResolutionRejectsOldResult() async {
        let authority = SavedWorkoutHistoryShareAuthority()
        let entry = savedEntry()
        authority.install(resolve: { expected, generation in
            await Task.yield()
            authority.revoke()
            return self.snapshot(expected, generation: generation)
        }, canExport: { _ in true })
        let result = await authority.resolve(entry)
        XCTAssertNil(result)
    }

    func testRevocationDuringSuspendedExportRejectsOldApproval() async throws {
        let authority = SavedWorkoutHistoryShareAuthority()
        install(authority, exporter: { _ in
            await Task.yield()
            authority.revoke()
            return true
        })
        let resolved = await authority.resolve(savedEntry())
        let saved = try XCTUnwrap(resolved)
        let allowed = await authority.canExport(saved)
        XCTAssertFalse(allowed)
    }

    func testReopenedProfileCannotAuthorizeAnOldSnapshotWithIdenticalRecords() async throws {
        let authority = SavedWorkoutHistoryShareAuthority()
        install(authority, exporter: { _ in true })
        let entry = savedEntry()
        let first = await authority.resolve(entry)
        let old = try XCTUnwrap(first)
        var calls = 0
        install(authority, exporter: { _ in calls += 1; return true })
        let allowed = await authority.canExport(old)
        XCTAssertFalse(allowed)
        XCTAssertEqual(calls, 0)
        let next = await authority.resolve(entry)
        let current = try XCTUnwrap(next)
        XCTAssertEqual(old.entry, current.entry)
        XCTAssertNotEqual(old.authorityGeneration, current.authorityGeneration)
    }

    func testCurrentSnapshotStillRequiresRootFreshnessApproval() async throws {
        let authority = SavedWorkoutHistoryShareAuthority()
        install(authority, exporter: { _ in false })
        let resolved = await authority.resolve(savedEntry())
        let saved = try XCTUnwrap(resolved)
        let allowed = await authority.canExport(saved)
        XCTAssertFalse(allowed)
    }

    func testCurrentGenerationWithRootApprovalCanExport() async throws {
        let authority = SavedWorkoutHistoryShareAuthority()
        install(authority, exporter: { _ in true })
        let resolved = await authority.resolve(savedEntry())
        let saved = try XCTUnwrap(resolved)
        let allowed = await authority.canExport(saved)
        XCTAssertTrue(allowed)
    }

    private func install(_ authority: SavedWorkoutHistoryShareAuthority,
                         exporter: @escaping @MainActor (SavedWorkoutHistoryShareSnapshot) async -> Bool) {
        authority.install(resolve: { expected, generation in
            self.snapshot(expected, generation: generation)
        }, canExport: exporter)
    }

    private func snapshot(_ entry: WorkoutHistoryEntry, generation: UUID) -> SavedWorkoutHistoryShareSnapshot {
        .init(entry: entry, acknowledgedHistory: [entry], authorityGeneration: generation)
    }

    private func savedEntry() -> WorkoutHistoryEntry {
        let savedAt = Date(timeIntervalSince1970: 1)
        let plan = ExercisePlan(name: "Goblet squat", targetLoad: Load(18), targetReps: RepRange(8, 12),
            plannedSetCount: 1, restSeconds: 60, previousPerformance: [])
        let set = CompletedSet(load: Load(18), reps: 8, rir: 2, completedAt: savedAt)
        return WorkoutHistoryEntry(session: WorkoutSession(title: "Saved", targetDurationMinutes: 45,
            exercises: [WorkoutExercise(plan: plan, completedSets: [set])], completedAt: savedAt))
    }
}
