import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class WorkoutHistoryPresentationTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompleteRecordDrawsEveryPlannedSetAsSaved() {
        let presentation = present(session(sets: [(2, 2), (1, 1)]))

        XCTAssertEqual(presentation.status, .complete)
        XCTAssertEqual(presentation.detail, .sets)
        XCTAssertEqual(presentation.grid.map(\.isSaved), [true, true, true])
        XCTAssertEqual(presentation.grid.map(\.startsGroup), [true, false, true])
        XCTAssertEqual(presentation.unassignedOpenSetCount, 0)
        XCTAssertEqual(presentation.exercises.map(\.statusText), ["2 of 2", "1 of 1"])
        XCTAssertEqual(presentation.statusDetail, "All 3 sets saved")
        XCTAssertEqual(presentation.gridAccessibilityLabel, "3 of 3 working sets saved")
        XCTAssertEqual(presentation.loadUnitNote, "Loads in kg.")
    }

    func testPartialRecordKeepsUnloggedSetsInTheirOwnExercise() throws {
        let presentation = present(session(sets: [(3, 2), (2, 0)]))
        let first = presentation.exercises[0]

        XCTAssertEqual(presentation.status, .partial)
        XCTAssertEqual(presentation.grid.map(\.isSaved), [true, true, false, false, false])
        XCTAssertEqual(presentation.grid.map(\.startsGroup), [true, false, false, true, false])
        XCTAssertEqual(presentation.unassignedOpenSetCount, 0)
        // Rows list only saved sets; unlogged sets are shown by the grid.
        XCTAssertEqual(first.sets.count, 2)
        XCTAssertEqual(first.statusText, "2 of 3")
        // One unit across the session: chips drop it and the note states it.
        XCTAssertEqual(first.text(for: try XCTUnwrap(first.sets.first)), "60 × 8")
        XCTAssertEqual(
            first.accessibilityLabel,
            "\(first.name), 2 of 3. Set 1, 60 kg, 8 repetitions. Set 2, 60 kg, 8 repetitions."
        )
        XCTAssertEqual(presentation.exercises[1].statusText, "0 of 2")
        XCTAssertTrue(presentation.exercises[1].sets.isEmpty)
        XCTAssertEqual(
            presentation.exercises[1].accessibilityLabel, "\(presentation.exercises[1].name), 0 of 2. Not logged."
        )
        XCTAssertEqual(
            presentation.statusDetail,
            "2 of 5 sets saved. Ended early; every logged set is kept."
        )
    }

    func testMixedUnitsKeepUnitsOnEverySet() throws {
        let kilograms = session(sets: [(1, 1)])
        let pounds = WorkoutExercise(
            plan: ExercisePlan(
                name: "History test pounds", targetLoad: Load(45, unit: .pounds), targetReps: RepRange(8, 8),
                plannedSetCount: 1, restSeconds: 90, previousPerformance: []
            ),
            completedSets: [CompletedSet(load: Load(45, unit: .pounds), reps: 8, completedAt: savedAt)]
        )
        let presentation = present(WorkoutSession(
            title: kilograms.title, exercises: kilograms.exercises + [pounds], completedAt: savedAt
        ))

        XCTAssertNil(presentation.loadUnitNote)
        XCTAssertEqual(presentation.exercises[1].text(for: try XCTUnwrap(presentation.exercises[1].sets.first)), "45 lb × 8")
    }

    func testRepeatedExerciseOccurrencesStaySeparate() {
        let lift = ExerciseID(exerciseName: "History test lift")
        let presentation = present(session(sets: [(2, 2), (2, 1)], exerciseIDs: [lift, lift]))

        XCTAssertEqual(presentation.exercises.map(\.id), [0, 1])
        XCTAssertEqual(presentation.exercises.map(\.savedCount), [2, 1])
        XCTAssertEqual(Set(presentation.grid.map(\.id)).count, presentation.grid.count)
    }

    func testNewRecordsRoundTripThePlannedCountPerExercise() throws {
        let entry = WorkoutHistoryEntry(session: session(sets: [(3, 2), (2, 2)]))

        XCTAssertEqual(entry.exercises?.map(\.plannedSetCount), [3, 2])
        XCTAssertEqual(try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONEncoder().encode(entry)), entry)
    }

    func testOlderExerciseRecordKeepsPlannedAllocationUnknown() throws {
        let entry = try legacyEntry(from: session(sets: [(3, 2), (2, 1)]), shape: .withoutPlannedCounts)
        let presentation = WorkoutHistoryPresentation(entry: WorkoutHistoryDisplayItem(entry: entry))

        XCTAssertEqual(entry.exercises?.map(\.plannedSetCount), [nil, nil])
        XCTAssertEqual(entry.plannedSetCount, 5)
        XCTAssertEqual(presentation.status, .partial)
        XCTAssertEqual(presentation.exercises.map(\.plannedCount), [nil, nil])
        XCTAssertEqual(presentation.exercises.map(\.statusText), ["2 sets saved", "1 set saved"])
        XCTAssertEqual(presentation.exercises.map(\.sets.count), [2, 1])
        // Unlogged sets are counted, never assigned to an exercise.
        XCTAssertEqual(presentation.grid.map(\.isSaved), [true, true, true, false, false])
        XCTAssertEqual(presentation.grid.map(\.startsGroup), [true, false, true, true, false])
        XCTAssertEqual(presentation.unassignedOpenSetCount, 2)
    }

    func testSummaryOnlyRecordShowsSavedCountsWithoutInventedDetail() throws {
        let entry = try legacyEntry(from: session(sets: [(3, 2), (1, 1)]), shape: .summaryOnly)
        let presentation = WorkoutHistoryPresentation(entry: WorkoutHistoryDisplayItem(entry: entry))

        XCTAssertEqual(presentation.detail, .summaryOnly)
        XCTAssertNil(presentation.loadUnitNote)
        XCTAssertTrue(presentation.exercises.isEmpty)
        XCTAssertEqual(presentation.grid.map(\.isSaved), [true, true, true, false])
        XCTAssertEqual(presentation.grid.filter(\.startsGroup).count, 1)
        XCTAssertEqual(presentation.unassignedOpenSetCount, 0)
        XCTAssertEqual(presentation.warmUp, .notRecorded)
        XCTAssertEqual(presentation.statusDetail, "3 of 4 sets saved. Ended early; every logged set is kept.")
        XCTAssertEqual(presentation.gridAccessibilityLabel, "3 of 4 working sets saved")
    }

    func testSessionWithoutSavedSetsDrawsOnlyOpenSegments() {
        let presentation = present(session(sets: [(2, 0)]))

        XCTAssertEqual(presentation.status, .partial)
        XCTAssertEqual(presentation.detail, .noSavedSets)
        XCTAssertEqual(presentation.grid.map(\.isSaved), [false, false])
        XCTAssertNil(presentation.loadUnitNote)
        XCTAssertEqual(presentation.exercises.map(\.statusText), ["0 of 2"])
    }

    func testWarmUpOutcomeReflectsOnlyTheRecordedStatus() {
        let pending = WorkoutWarmUp(estimatedMinutes: 5, steps: ["Row", "Hinge"])
        var completed = pending
        completed.resolve(as: .completed, at: savedAt)
        var partial = pending
        partial.resolve(as: .partial, at: savedAt)
        let skipped = pending.configured(for: .none, at: savedAt)

        XCTAssertEqual(WorkoutHistoryPresentation.WarmUpOutcome(completed), .completed)
        XCTAssertEqual(WorkoutHistoryPresentation.WarmUpOutcome(partial), .partial)
        XCTAssertEqual(WorkoutHistoryPresentation.WarmUpOutcome(skipped), .skipped)
        XCTAssertEqual(WorkoutHistoryPresentation.WarmUpOutcome(pending), .notRecorded)
        XCTAssertEqual(WorkoutHistoryPresentation.WarmUpOutcome(nil), .notRecorded)
        XCTAssertEqual(present(session(sets: [(1, 1)], warmUp: skipped)).warmUp, .skipped)
    }

    func testAdaptedRecordSaysSoWithoutOtherClaims() {
        let presentation = present(session(sets: [(1, 1)], isAdapted: true))

        XCTAssertEqual(presentation.countText, "1 of 1 set · Adapted")
        XCTAssertEqual(
            presentation.statusDetail,
            "1 of 1 set saved. Plan adapted for this session."
        )
        XCTAssertEqual(
            presentation.listAccessibilityLabel(title: "Push", dateText: "Today"),
            "Push. Complete. 1 of 1 set saved. Today. Adapted plan."
        )
    }

    func testRetryAfterOlderExerciseRecordLeavesStoredDataUntouched() throws {
        let completed = session(sets: [(3, 2), (2, 1)])
        let legacy = try legacyEntry(from: completed, shape: .withoutPlannedCounts)
        let store = PresentationTestHistoryStore(entries: [legacy])
        let history = WorkoutHistoryRepository(store: store)

        XCTAssertEqual(try history.record(completed), .alreadyRecorded)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.entries, [legacy])
        XCTAssertEqual(history.entries.first?.exercises?.map(\.plannedSetCount), [nil, nil])
    }

    func testRetryWithDifferentRecordedPlannedCountStillConflicts() throws {
        let completed = session(sets: [(3, 2)])
        let changed = try legacyEntry(from: completed, shape: .plannedCount(4))
        let store = PresentationTestHistoryStore(entries: [changed])
        let history = WorkoutHistoryRepository(store: store)

        XCTAssertThrowsError(try history.record(completed))
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.entries, [changed])

        let saved = try XCTUnwrap(WorkoutHistoryEntry(session: completed).exercises?.first)
        let unknown = try XCTUnwrap(legacyEntry(from: completed, shape: .withoutPlannedCounts).exercises?.first)
        XCTAssertTrue(unknown.hasSameRecordedSets(as: saved))
        XCTAssertFalse(try XCTUnwrap(changed.exercises?.first).hasSameRecordedSets(as: saved))
    }

    // MARK: - Helpers

    private enum LegacyShape {
        case withoutPlannedCounts
        case summaryOnly
        case plannedCount(Int)
    }

    private func present(_ session: WorkoutSession) -> WorkoutHistoryPresentation {
        WorkoutHistoryPresentation(entry: WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: session)))
    }

    private func session(
        sets: [(planned: Int, saved: Int)],
        exerciseIDs: [ExerciseID]? = nil,
        warmUp: WorkoutWarmUp? = nil,
        isAdapted: Bool = false
    ) -> WorkoutSession {
        let exercises = sets.enumerated().map { index, counts -> WorkoutExercise in
            let name = "History test lift \(index)"
            let plan = ExercisePlan(
                exerciseID: exerciseIDs?[index] ?? ExerciseID(exerciseName: name),
                name: name,
                targetLoad: Load(60),
                targetReps: RepRange(8, 8),
                plannedSetCount: counts.planned,
                restSeconds: 90,
                previousPerformance: []
            )
            return WorkoutExercise(plan: plan, completedSets: (0 ..< counts.saved).map { offset in
                CompletedSet(load: Load(60), reps: 8, completedAt: savedAt.addingTimeInterval(Double(offset) * 60))
            })
        }
        return WorkoutSession(
            title: "History test", isAdapted: isAdapted, warmUp: warmUp,
            exercises: exercises, completedAt: savedAt
        )
    }

    /// Rewrites an encoded record into the shape older app versions stored.
    private func legacyEntry(from session: WorkoutSession, shape: LegacyShape) throws -> WorkoutHistoryEntry {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkoutHistoryEntry(session: session))
        ) as? [String: Any])
        switch shape {
        case .summaryOnly:
            json.removeValue(forKey: "exercises")
        case .withoutPlannedCounts, .plannedCount:
            let exercises = try XCTUnwrap(json["exercises"] as? [[String: Any]])
            json["exercises"] = exercises.map { exercise in
                var older = exercise
                if case let .plannedCount(count) = shape {
                    older["plannedSetCount"] = count
                } else {
                    older.removeValue(forKey: "plannedSetCount")
                }
                return older
            }
        }
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

private final class PresentationTestHistoryStore: WorkoutHistoryPersisting {
    private(set) var entries: [WorkoutHistoryEntry]
    private(set) var saveCount = 0

    init(entries: [WorkoutHistoryEntry]) {
        self.entries = entries
    }

    func load() -> [WorkoutHistoryEntry] {
        entries
    }

    func save(_ entries: [WorkoutHistoryEntry]) throws {
        self.entries = entries
        saveCount += 1
    }
}
