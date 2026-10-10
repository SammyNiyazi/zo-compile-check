import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class DietTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let zone = TimeZone(secondsFromGMT: 0)!

    @MainActor private final class MemoryStore: DietTrackerPersisting {
        var value = DietTrackerSnapshot.empty
        var failRead = false
        var failSave = false
        var discardSave = false
        var saves = 0
        func load() throws -> DietTrackerSnapshot {
            if failRead { throw DietTrackerError.storeUnavailable }
            return value
        }
        func save(_ candidate: DietTrackerSnapshot, replacing baseline: DietTrackerSnapshot) throws {
            saves += 1
            if failSave { throw DietTrackerError.saveFailed }
            guard value == baseline else { throw DietTrackerError.storeChanged }
            if !discardSave { value = candidate }
        }
    }

    private func draft(times: [DietTrackerTime] = []) -> DietTrackerDraft {
        var value = DietTrackerDraft()
        value.name = "User tracker"; value.kind = .medicine
        value.dose = "Entered instructions, not advice"; value.times = times
        return value
    }

    private func day(_ date: Date? = nil, zone: TimeZone? = nil) throws -> DietTrackerDay {
        try DietTrackerDay(containing: date ?? now, timeZone: zone ?? self.zone)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func object(_ value: DietTrackerSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: DietTrackerStorageCodec.encode(value)) as? [String: Any])
    }

    func testNewRepositoryIsEmptyAndNeverSeedsProofMedicines() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        XCTAssertEqual(repo.snapshot, .empty)
        XCTAssertEqual(repo.availability, .available)
        XCTAssertTrue(try repo.checklist(for: day()).isEmpty)
        XCTAssertEqual(store.saves, 0)
    }

    func testDraftRetainsExactUserDoseAndReminderPreferences() throws {
        var input = draft(); input.name = "  My entry  "
        input.dose = "  My exact text\n"; input.kind = .supplement
        input.remindMe = false; input.remindAgainIfNotLogged = true
        let value = try input.validated(id: UUID(), at: now)
        XCTAssertEqual(value.name, "My entry")
        XCTAssertEqual(value.dose, input.dose)
        XCTAssertEqual(value.kind, .supplement)
        XCTAssertFalse(value.remindMe); XCTAssertTrue(value.remindAgainIfNotLogged)
    }

    func testInvalidNameClockAndDuplicateTimesDoNotWrite() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        var value = draft(); value.name = " \n"
        XCTAssertThrowsError(try repo.add(value, at: now))
        value = draft(times: [.init(hour: 24, minute: 0)])
        XCTAssertThrowsError(try repo.add(value, at: now))
        value = draft(times: [.init(hour: .max, minute: .min)])
        XCTAssertThrowsError(try repo.add(value, at: now)) { error in
            XCTAssertEqual(error as? DietTrackerError, .invalidEntry)
        }
        value = draft(times: [.init(hour: 8, minute: 0), .init(hour: 8, minute: 0)])
        XCTAssertThrowsError(try repo.add(value, at: now))
        XCTAssertEqual(store.saves, 0); XCTAssertEqual(repo.snapshot, .empty)
    }

    func testScheduledTimesAreSeparateOccurrencesAndRepeatedTapIsIdempotent() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        let early = DietTrackerTime(hour: 7, minute: 30), late = DietTrackerTime(hour: 19, minute: 0)
        _ = try repo.add(draft(times: [late, early]), at: now)
        let rows = try repo.checklist(for: day())
        XCTAssertEqual(rows.map { $0.time?.id }, [early.id, late.id])
        let log = try repo.log(rows[0], at: now)
        XCTAssertEqual(try repo.log(rows[0], at: now.addingTimeInterval(1)), log)
        XCTAssertEqual(repo.snapshot.completions.count, 1)
        let after = try repo.checklist(for: day())
        XCTAssertTrue(after[0].isCompleted); XCTAssertFalse(after[1].isCompleted)
    }

    func testUntimedTrackerHasExactlyOneExplicitDailyOccurrence() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        _ = try repo.add(draft(), at: now)
        let rows = try repo.checklist(for: day())
        XCTAssertEqual(rows.count, 1); XCTAssertNil(rows[0].time)
        let log = try repo.log(rows[0], at: now)
        XCTAssertNil(log.scheduledTime)
        XCTAssertTrue(try repo.checklist(for: day())[0].isCompleted)
    }

    func testUndoRemovesOnlyTheIdentifiedOccurrence() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        _ = try repo.add(draft(times: [.init(hour: 8, minute: 0), .init(hour: 12, minute: 0)]), at: now)
        let rows = try repo.checklist(for: day())
        let a = try repo.log(rows[0], at: now), b = try repo.log(rows[1], at: now)
        try repo.undo(a)
        XCTAssertEqual(repo.snapshot.completions, [b])
        XCTAssertThrowsError(try repo.undo(a))
    }

    func testNextDayAndStaleOpenChecklistDoNotReplayCompletion() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        _ = try repo.add(draft(), at: now)
        let today = try day(), row = try repo.checklist(for: today)[0]
        _ = try repo.log(row, at: now)
        let tomorrow = try day(today.end.addingTimeInterval(1))
        XCTAssertFalse(try repo.checklist(for: tomorrow)[0].isCompleted)
        XCTAssertThrowsError(try repo.log(row, at: tomorrow.start))
        XCTAssertEqual(repo.snapshot.completions.count, 1)
    }

    func testDSTDayIntervalsUseActualCalendarRatherThan86400() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ny
        let spring = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let fall = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let short = try day(spring, zone: ny), long = try day(fall, zone: ny)
        XCTAssertEqual(short.end.timeIntervalSince(short.start), 23 * 3_600)
        XCTAssertEqual(long.end.timeIntervalSince(long.start), 25 * 3_600)
        XCTAssertTrue(short.isValid); XCTAssertTrue(long.isValid)
    }

    func testTimezoneChangeProjectsActualLogInstantAndRetainsOriginalContext() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        _ = try repo.add(draft(), at: now)
        let originalDay = try day(), row = try repo.checklist(for: originalDay)[0]
        let log = try repo.log(row, at: now)
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let other = try day(now, zone: tokyo), otherRow = try repo.checklist(for: other)[0]
        XCTAssertTrue(otherRow.isCompleted)
        XCTAssertEqual(otherRow.completions[0].day, originalDay)
        XCTAssertEqual(try repo.log(otherRow, at: now), log)
        XCTAssertEqual(repo.snapshot.completions.count, 1)
    }

    func testArchiveRetainsLogsAndRestoreShowsSameActualCompletion() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        let tracker = try repo.add(draft(), at: now)
        let log = try repo.log(try repo.checklist(for: day())[0], at: now)
        try repo.setArchived(true, tracker: tracker, at: now)
        XCTAssertTrue(try repo.checklist(for: day()).isEmpty)
        XCTAssertEqual(repo.snapshot.completions, [log])
        let archived = try XCTUnwrap(repo.archivedTrackers.first)
        try repo.setArchived(false, tracker: archived, at: now)
        XCTAssertTrue(try repo.checklist(for: day())[0].isCompleted)
    }

    func testEditKeepsIdentityAndEarlierLoggedDoseDetails() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        let tracker = try repo.add(draft(), at: now)
        let log = try repo.log(try repo.checklist(for: day())[0], at: now)
        var input = DietTrackerDraft(tracker: tracker); input.dose = "My corrected text"
        let edited = try repo.update(input, at: now.addingTimeInterval(-1))
        XCTAssertEqual(edited.id, tracker.id); XCTAssertNotEqual(edited.revision, tracker.revision)
        XCTAssertEqual(edited.createdAt, tracker.createdAt)
        XCTAssertEqual(repo.snapshot.completions[0], log)
        XCTAssertTrue(try repo.checklist(for: day())[0].hasEarlierDetails)
        XCTAssertThrowsError(try repo.update(input, at: now))
    }

    func testRemovedTimeLogsRemainFactsButDoNotCompleteNewSlot() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        let tracker = try repo.add(draft(times: [.init(hour: 8, minute: 0)]), at: now)
        let log = try repo.log(try repo.checklist(for: day())[0], at: now)
        var input = DietTrackerDraft(tracker: tracker); input.times = [.init(hour: 9, minute: 0)]
        _ = try repo.update(input, at: now)
        XCTAssertFalse(try repo.checklist(for: day())[0].isCompleted)
        XCTAssertEqual(repo.snapshot.completions, [log])
    }

    func testDeleteRemovesOnlySelectedTrackerAndItsLogs() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        let a = try repo.add(draft(), at: now), b = try repo.add(draft(), at: now)
        let rows = try repo.checklist(for: day())
        _ = try repo.log(rows[0], at: now); let kept = try repo.log(rows[1], at: now)
        try repo.delete(a)
        XCTAssertEqual(repo.snapshot.trackers, [b]); XCTAssertEqual(repo.snapshot.completions, [kept])
    }

    func testFailedWriteAndDiscardedWriteNeverPublishGhostCompletion() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        _ = try repo.add(draft(), at: now)
        let row = try repo.checklist(for: day())[0]
        store.failSave = true
        XCTAssertThrowsError(try repo.log(row, at: now))
        XCTAssertTrue(repo.snapshot.completions.isEmpty)
        store.failSave = false; store.discardSave = true
        XCTAssertThrowsError(try repo.log(row, at: now))
        XCTAssertFalse(try repo.checklist(for: day())[0].isCompleted)
        XCTAssertEqual(repo.lastError, .saveFailed)
    }

    func testUnavailableReadCannotBeTreatedAsEmptyOrOverwriteStorage() throws {
        let store = MemoryStore(); store.failRead = true
        let repo = DietTrackerRepository(store: store)
        XCTAssertEqual(repo.availability, .unavailable)
        XCTAssertThrowsError(try repo.add(draft(), at: now))
        XCTAssertThrowsError(try repo.checklist(for: day()))
        XCTAssertEqual(store.saves, 0)
        store.failRead = false; try repo.reload()
        XCTAssertEqual(repo.availability, .available)
    }

    func testTwoActualFileOwnersRejectStaleStateAndReloadSafely() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDietTrackerStore(directory: root)
        let first = DietTrackerRepository(store: store), stale = DietTrackerRepository(store: store)
        let tracker = try first.add(draft(), at: now)
        XCTAssertThrowsError(try stale.add(draft(), at: now)) { XCTAssertEqual($0 as? DietTrackerError, .storeChanged) }
        XCTAssertEqual(try store.load().trackers, [tracker])
        try stale.reload(); XCTAssertEqual(stale.snapshot, first.snapshot)
    }

    func testActualFileRoundTripPersistsChecklistArchiveAndUndo() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDietTrackerStore(directory: root), repo = DietTrackerRepository(store: store)
        let tracker = try repo.add(draft(times: [.init(hour: 8, minute: 0)]), at: now)
        let log = try repo.log(try repo.checklist(for: day())[0], at: now)
        let relaunched = DietTrackerRepository(store: FileDietTrackerStore(directory: root))
        XCTAssertEqual(relaunched.snapshot, repo.snapshot)
        XCTAssertTrue(try relaunched.checklist(for: day())[0].isCompleted)
        try relaunched.undo(log)
        try relaunched.setArchived(true, tracker: tracker, at: now)
        let readback = try store.load()
        XCTAssertTrue(readback.completions.isEmpty); XCTAssertTrue(readback.trackers[0].isArchived)
    }

    func testCorruptActualFileRemainsByteExactAfterRejectedSave() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diet-trackers.json"), corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        let store = FileDietTrackerStore(directory: root)
        XCTAssertThrowsError(try store.save(.empty, replacing: .empty))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(DietTrackerRepository(store: store).availability, .unavailable)
    }

    func testStrictCodecRejectsUnknownFutureAndDuplicateEscapedKeys() throws {
        let bytes = try DietTrackerStorageCodec.encode(.empty)
        var root = try object(.empty); root["version"] = 2
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
        root = try object(.empty); root["futureField"] = true
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
        for key in ["version", "vers\\u0069on"] {
            var duplicate = Data(("{\"" + key + "\":1,").utf8); duplicate.append(bytes.dropFirst())
            XCTAssertThrowsError(try DietTrackerStorageCodec.decode(duplicate))
        }
        XCTAssertEqual(try DietTrackerStorageCodec.decode(bytes), .empty)
    }

    func testStrictCodecRejectsNestedUnknownClockAndAmbiguousIdentifiers() throws {
        let tracker = try draft(times: [.init(hour: 8, minute: 0)]).validated(id: UUID(), at: now)
        let value = DietTrackerSnapshot(version: 1, trackers: [tracker], completions: [])
        var root = try object(value), list = try XCTUnwrap(root["trackers"] as? [[String: Any]])
        var slots = try XCTUnwrap(list[0]["times"] as? [[String: Any]])
        slots[0]["futureClock"] = 1; list[0]["times"] = slots; root["trackers"] = list
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
        XCTAssertThrowsError(try DietTrackerStorageCodec.encode(.init(version: 1, trackers: [tracker, tracker], completions: [])))
    }

    func testDeletingTrackersDoesNotTouchOtherStorageFiles() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let food = root.appendingPathComponent("food.json"), water = root.appendingPathComponent("water.json")
        let foodBytes = Data("unrelated-food".utf8), waterBytes = Data("unrelated-water".utf8)
        try foodBytes.write(to: food); try waterBytes.write(to: water)
        let repo = DietTrackerRepository(store: FileDietTrackerStore(directory: root))
        let tracker = try repo.add(draft(), at: now); try repo.delete(tracker)
        XCTAssertEqual(try Data(contentsOf: food), foodBytes)
        XCTAssertEqual(try Data(contentsOf: water), waterBytes)
    }

    func testStaleOccurrenceCannotLogAnEditedDose() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        let tracker = try repo.add(draft(), at: now)
        let stale = try repo.checklist(for: day())[0]
        var input = DietTrackerDraft(tracker: tracker); input.dose = "New user text"
        _ = try repo.update(input, at: now)
        XCTAssertThrowsError(try repo.log(stale, at: now)) { XCTAssertEqual($0 as? DietTrackerError, .entryChanged) }
        XCTAssertTrue(repo.snapshot.completions.isEmpty)
    }

    func testFailedArchiveAndDeletePreserveVisibleStateAndLogs() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        let tracker = try repo.add(draft(), at: now)
        _ = try repo.log(try repo.checklist(for: day())[0], at: now)
        let baseline = repo.snapshot; store.failSave = true
        XCTAssertThrowsError(try repo.setArchived(true, tracker: tracker, at: now))
        XCTAssertEqual(repo.snapshot, baseline)
        XCTAssertThrowsError(try repo.delete(tracker))
        XCTAssertEqual(repo.snapshot, baseline); XCTAssertEqual(store.value, baseline)
    }

    func testReloadFailureRetainsLastReadableFactsAndDisablesChanges() throws {
        let store = MemoryStore(), repo = DietTrackerRepository(store: store)
        _ = try repo.add(draft(), at: now)
        let baseline = repo.snapshot; store.failRead = true
        XCTAssertThrowsError(try repo.reload())
        XCTAssertEqual(repo.snapshot, baseline)
        XCTAssertEqual(repo.availability, .unavailable)
        XCTAssertThrowsError(try repo.add(draft(), at: now))
        store.failRead = false; try repo.reload()
        XCTAssertEqual(repo.snapshot, baseline); XCTAssertEqual(repo.availability, .available)
    }

    func testMalformedDayOrphanLogAndRepeatedOccurrenceRejectStrictly() throws {
        let repo = DietTrackerRepository(store: MemoryStore())
        _ = try repo.add(draft(), at: now)
        _ = try repo.log(try repo.checklist(for: day())[0], at: now)
        let baseline = try object(repo.snapshot)
        var root = baseline, logs = try XCTUnwrap(root["completions"] as? [[String: Any]])
        var context = try XCTUnwrap(logs[0]["day"] as? [String: Any])
        context["timeZoneIdentifier"] = "Invalid/NotAZone"; logs[0]["day"] = context; root["completions"] = logs
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
        root = baseline; logs = try XCTUnwrap(root["completions"] as? [[String: Any]])
        logs[0]["trackerID"] = UUID().uuidString; root["completions"] = logs
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
        root = baseline; logs = try XCTUnwrap(root["completions"] as? [[String: Any]])
        var repeated = logs[0]; repeated["id"] = UUID().uuidString
        logs.append(repeated); root["completions"] = logs
        XCTAssertThrowsError(try DietTrackerStorageCodec.decode(JSONSerialization.data(withJSONObject: root)))
    }
}
