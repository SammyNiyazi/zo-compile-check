import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ZeroOne

@MainActor
final class ProgressPhotoTests: XCTestCase {
    func testRecordSchemaContainsOnlyLockedFields() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000049")!
        let paths = LocalProgressPhotoStore.relativePaths(for: id)
        let record = ProgressPhotoRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 49),
            label: .postWorkout,
            imageRelativePath: paths.image,
            thumbnailRelativePath: paths.thumbnail
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["id", "createdAt", "label", "imageRelativePath", "thumbnailRelativePath"])
        )
        XCTAssertEqual(object["label"] as? String, "postWorkout")
    }

    func testLocalSaveUsesPrivateRelativePathsAndStripsSourceMetadata() async throws {
        let fixture = try makeFixture()
        let root = temporaryRoot()
        let repository = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))

        let draft = try await repository.makeDraft(
            from: fixture,
            label: .progress,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let record = try repository.save(draft)

        XCTAssertFalse(record.imageRelativePath.hasPrefix("/"))
        XCTAssertFalse(record.thumbnailRelativePath.hasPrefix("/"))
        XCTAssertTrue(record.imageRelativePath.hasSuffix("/master.jpg"))
        XCTAssertTrue(record.thumbnailRelativePath.hasSuffix("/thumbnail.jpg"))
        XCTAssertFalse(record.imageRelativePath.contains(".."))
        XCTAssertNotNil(repository.imageData(for: record))
        XCTAssertNotNil(repository.thumbnailData(for: record))

        let imageData = try XCTUnwrap(repository.imageData(for: record))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
    }

    func testRepositoryRestoresTimelineAcrossInstances() async throws {
        let root = temporaryRoot()
        let store = LocalProgressPhotoStore(rootURL: root)
        let first = ProgressPhotoRepository(store: store)
        let draft = try await first.makeDraft(
            from: makeFixture(),
            label: .postWorkout,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let saved = try first.save(draft)

        let restored = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))

        XCTAssertEqual(restored.entries, [saved])
        XCTAssertNotNil(restored.imageData(for: saved))
        XCTAssertNotNil(restored.thumbnailData(for: saved))
    }

    func testStoreRejectsAnyPathOutsideItsOwnedRecordDirectory() throws {
        let root = temporaryRoot()
        let id = UUID()
        let invalid = ProgressPhotoRecord(
            id: id,
            createdAt: .now,
            label: .progress,
            imageRelativePath: "../outside.jpg",
            thumbnailRelativePath: id.uuidString.lowercased() + "/thumbnail.jpg"
        )
        let store = LocalProgressPhotoStore(rootURL: root)

        XCTAssertThrowsError(
            try store.save(invalid, imageData: Data([1]), thumbnailData: Data([2]))
        ) { error in
            XCTAssertEqual(error as? ProgressPhotoStoreError, .invalidOwnedPath)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("outside.jpg").path
            )
        )
    }

    func testDeleteRemovesOnlyOwnedFilesDirectoryAndRecord() async throws {
        let root = temporaryRoot()
        let repository = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))
        let draft = try await repository.makeDraft(from: makeFixture(), label: .progress)
        let record = try repository.save(draft)
        let recordDirectory = root.appendingPathComponent(record.id.uuidString.lowercased())
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)

        try repository.delete(record)

        XCTAssertTrue(repository.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testMissingFileKeepsUnavailableRecordWithoutCrashOrAutomaticDeletion() async throws {
        let root = temporaryRoot()
        let repository = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))
        let draft = try await repository.makeDraft(from: makeFixture(), label: .progress)
        let record = try repository.save(draft)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(record.imageRelativePath)
        )

        let restored = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))

        XCTAssertEqual(restored.entries, [record])
        XCTAssertNil(restored.imageData(for: record))
        XCTAssertNotNil(restored.thumbnailData(for: record))
    }

    func testPreparingThenCancellingReviewCreatesNoRecordOrLocalFile() async throws {
        let root = temporaryRoot()
        let repository = ProgressPhotoRepository(store: LocalProgressPhotoStore(rootURL: root))

        _ = try await repository.makeDraft(from: makeFixture(), label: .progress)

        XCTAssertTrue(repository.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPostWorkoutPhotoSaveDoesNotMutateWorkoutOrHistory() async throws {
        var completedSession = singleSetSession()
        let exercise = try XCTUnwrap(completedSession.currentExercise)
        _ = try completedSession.completeCurrentSet(
            load: exercise.plan.targetLoad,
            reps: exercise.plan.targetReps.upperBound,
            rir: 2,
            at: Date(timeIntervalSince1970: 300)
        )
        let historyStore = TestWorkoutHistoryStore()
        let history = WorkoutHistoryRepository(store: historyStore)
        try history.record(completedSession)
        let historyBefore = history.entries
        let completedAtBefore = completedSession.completedAt
        let setCountBefore = completedSession.completedSetCount

        let photos = ProgressPhotoRepository(
            store: LocalProgressPhotoStore(rootURL: temporaryRoot())
        )
        let draft = try await photos.makeDraft(from: makeFixture(), label: .postWorkout)
        _ = try photos.save(draft)

        XCTAssertEqual(completedSession.completedAt, completedAtBefore)
        XCTAssertEqual(completedSession.completedSetCount, setCountBefore)
        XCTAssertEqual(history.entries, historyBefore)
        XCTAssertEqual(photos.entries.first?.label, .postWorkout)
    }

    func testBodyWeightPersistsLocallyAndRetryDoesNotDuplicateReading() throws {
        let root = temporaryRoot()
        let first = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let reading = BodyWeightEntry(
            id: UUID(),
            recordedAt: Date(timeIntervalSince1970: 1_000),
            kilograms: Decimal(string: "72.4")!
        )

        try first.save(reading)
        try first.save(reading)
        let restored = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))

        XCTAssertEqual(first.entries, [reading])
        XCTAssertEqual(restored.entries, [reading])
    }

    func testBodyWeightRetryRejectsChangedValueForSameEntryID() throws {
        let repository = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: temporaryRoot()))
        let id = UUID()
        let first = BodyWeightEntry(id: id, recordedAt: .now, kilograms: 72)
        try repository.save(first)

        XCTAssertThrowsError(try repository.save(BodyWeightEntry(
            id: id, recordedAt: first.recordedAt, kilograms: 73
        ))) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .conflictingEntry)
        }
        XCTAssertEqual(repository.entries, [first])
    }

    func testUnreadableBodyWeightFileIsNotReplaced() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("entries.json")
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: file)
        let repository = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))

        XCTAssertFalse(repository.isAvailable)
        XCTAssertThrowsError(try repository.save(BodyWeightEntry(
            id: UUID(), recordedAt: .now, kilograms: 70
        )))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)

        try Data("[]".utf8).write(to: file)
        repository.reload()
        XCTAssertTrue(repository.isAvailable)
        XCTAssertTrue(repository.entries.isEmpty)
    }

    func testFailedBodyWeightWriteDoesNotCreateVisibleReading() {
        let repository = BodyWeightRepository(store: FailingBodyWeightStore())
        let reading = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 70)

        XCTAssertThrowsError(try repository.save(reading))
        XCTAssertTrue(repository.entries.isEmpty)
    }

    func testBodyWeightCorrectionKeepsStableIDAndPersistsDateChange() throws {
        let root = temporaryRoot()
        let repository = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let original = BodyWeightEntry(id: UUID(), recordedAt: Date(timeIntervalSince1970: 1_000), kilograms: 70)
        let revised = BodyWeightEntry(id: original.id, recordedAt: Date(timeIntervalSince1970: 2_000), kilograms: 71)
        try repository.save(original)

        try repository.replace(original, with: revised)
        try repository.replace(original, with: revised)

        XCTAssertEqual(repository.entries, [revised])
        XCTAssertEqual(BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root)).entries, [revised])
    }

    func testStaleBodyWeightCorrectionDoesNotOverwriteNewerValue() throws {
        let root = temporaryRoot()
        let first = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let original = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 70)
        try first.save(original)
        let stale = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let revised = BodyWeightEntry(id: original.id, recordedAt: original.recordedAt, kilograms: 71)
        try first.replace(original, with: revised)

        XCTAssertThrowsError(try stale.replace(original, with: BodyWeightEntry(
            id: original.id, recordedAt: original.recordedAt, kilograms: 72
        ))) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .conflictingEntry)
        }
        XCTAssertEqual(stale.entries, [revised])
    }

    func testStaleBodyWeightDeleteDoesNotRemoveCorrectedReading() throws {
        let root = temporaryRoot()
        let first = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let original = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 70)
        try first.save(original)
        let stale = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let revised = BodyWeightEntry(id: original.id, recordedAt: original.recordedAt, kilograms: 71)
        try first.replace(original, with: revised)

        XCTAssertThrowsError(try stale.delete(original)) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .conflictingEntry)
        }
        XCTAssertEqual(stale.entries, [revised])
        XCTAssertEqual(BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root)).entries, [revised])
    }

    func testInvalidBodyWeightCorrectionLeavesOriginalUnchanged() throws {
        let repository = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: temporaryRoot()))
        let original = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 70)
        try repository.save(original)

        XCTAssertThrowsError(try repository.replace(original, with: BodyWeightEntry(
            id: original.id, recordedAt: original.recordedAt, kilograms: -1
        ))) { error in
            XCTAssertEqual(error as? BodyWeightStoreError, .invalidValue)
        }
        XCTAssertEqual(repository.entries, [original])
    }

    func testBodyWeightDeleteRemovesOnlySelectedReadingAndRetryIsSafe() throws {
        let root = temporaryRoot()
        let repository = BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root))
        let first = BodyWeightEntry(id: UUID(), recordedAt: Date(timeIntervalSince1970: 1_000), kilograms: 70)
        let keep = BodyWeightEntry(id: UUID(), recordedAt: Date(timeIntervalSince1970: 2_000), kilograms: 71)
        try repository.save(first)
        try repository.save(keep)
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)

        try repository.delete(first)
        try repository.delete(first)

        XCTAssertEqual(repository.entries, [keep])
        XCTAssertEqual(BodyWeightRepository(store: LocalBodyWeightStore(rootURL: root)).entries, [keep])
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testFailedBodyWeightCorrectionAndDeleteKeepOriginal() {
        let original = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 70)
        let repository = BodyWeightRepository(store: FailingBodyWeightStore(initial: [original]))

        XCTAssertThrowsError(try repository.replace(original, with: BodyWeightEntry(
            id: original.id, recordedAt: original.recordedAt, kilograms: 71
        )))
        XCTAssertThrowsError(try repository.delete(original))
        XCTAssertEqual(repository.entries, [original])
    }

    func testBodyWeightTrendUsesLatestReadingPerDayAndSevenDayWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 9, day: day, hour: hour
            )))
        }
        let entries = [
            BodyWeightEntry(id: UUID(), recordedAt: try date(18, 9), kilograms: 77),
            BodyWeightEntry(id: UUID(), recordedAt: try date(22, 9), kilograms: 80),
            BodyWeightEntry(id: UUID(), recordedAt: try date(25, 8), kilograms: 81),
            BodyWeightEntry(id: UUID(), recordedAt: try date(25, 18), kilograms: 82),
            BodyWeightEntry(id: UUID(), recordedAt: try date(26, 8), kilograms: 83)
        ]

        let trend = BodyWeightTrend(entries: entries, now: try date(26, 12), calendar: calendar)

        XCTAssertEqual(trend.latest?.kilograms, 83)
        XCTAssertEqual(trend.lastThirtyDays.count, 4)
        XCTAssertEqual(trend.rollingAverages.count, 4)
        XCTAssertTrue(trend.latestDiffersFromPriorAverage)
        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(trend.averageChangeAfterLatestKilograms)).doubleValue,
            (80 + 82 + 83) / 3.0 - (80 + 82) / 2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(trend.sevenDayAverageKilograms)).doubleValue,
            (80 + 82 + 83) / 3.0,
            accuracy: 0.0001
        )
        XCTAssertNil(trend.fourWeekChangeKilograms)
    }

    func testBodyWeightFourWeekViewComparesDailyAveragesAndIgnoresOlderSameDayReading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int, _ hour: Int = 9) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour
            )))
        }
        func reading(_ month: Int, _ day: Int, _ value: String, hour: Int = 9) throws -> BodyWeightEntry {
            BodyWeightEntry(id: UUID(), recordedAt: try date(month, day, hour), kilograms: Decimal(string: value)!)
        }
        let entries = [
            try reading(8, 23, "70"), try reading(8, 27, "70"), try reading(8, 29, "70"),
            try reading(9, 10, "71"), try reading(9, 12, "71"),
            try reading(9, 20, "70.6"), try reading(9, 24, "70.7"),
            try reading(9, 26, "90", hour: 8), try reading(9, 26, "70.8", hour: 18)
        ]

        let trend = BodyWeightTrend(entries: entries, now: try date(9, 26, 20), calendar: calendar)

        XCTAssertEqual(trend.latest?.kilograms, Decimal(string: "70.8"))
        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(trend.fourWeekChangeKilograms)).doubleValue,
            0.7,
            accuracy: 0.0001
        )
        XCTAssertTrue(BodyWeightDirection.gain.context(for: Decimal(string: "0.7")!).contains("direction you chose"))
        XCTAssertTrue(BodyWeightDirection.none.context(for: Decimal(string: "0.2")!).contains("steady"))
    }

    func testBodyWeightFourWeekViewWaitsForHistoricalCoverageAndRecentReading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12)))
        }
        let entries = try (19 ... 26).map { day in
            BodyWeightEntry(id: UUID(), recordedAt: try date(day), kilograms: 70)
        }

        XCTAssertNil(BodyWeightTrend(entries: entries, now: try date(26), calendar: calendar)
            .fourWeekChangeKilograms)
        let staleNow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        XCTAssertNil(BodyWeightTrend(entries: entries, now: staleNow, calendar: calendar)
            .fourWeekChangeKilograms)
    }

    func testBodyWeightFourWeekViewUsesTwoReadingsInEachWindowWithoutEightTotalDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func reading(_ month: Int, _ day: Int, _ kilograms: Int) throws -> BodyWeightEntry {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: 9
            )))
            return BodyWeightEntry(id: UUID(), recordedAt: date, kilograms: Decimal(kilograms))
        }
        let entries = [
            try reading(8, 23, 70), try reading(8, 27, 72),
            try reading(9, 21, 74), try reading(9, 26, 76)
        ]
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 12
        )))

        let trend = BodyWeightTrend(entries: entries, now: now, calendar: calendar)

        XCTAssertEqual(trend.fourWeekChangeKilograms, 4)
        XCTAssertNil(BodyWeightTrend(entries: Array(entries.dropFirst()), now: now, calendar: calendar)
            .fourWeekChangeKilograms)
    }

    func testBodyWeightPoundsRoundTrip() {
        let kilograms = Decimal(string: "72.4")!
        let pounds = BodyWeightUnit.pounds.displayedValue(for: kilograms)
        let restored = BodyWeightUnit.pounds.kilograms(from: Decimal(pounds))

        XCTAssertEqual(NSDecimalNumber(decimal: restored).doubleValue, 72.4, accuracy: 0.001)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroOneProgressPhotoTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeFixture() throws -> Data {
        let size = CGSize(width: 1_200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.95, green: 0.90, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(x: 180, y: 150, width: 840, height: 500))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8566,
                kCGImagePropertyGPSLongitude: 2.3522
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "source-only-note"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "source-camera"
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func singleSetSession() -> WorkoutSession {
        WorkoutSession(
            title: "Test Session",
            exercises: [
                WorkoutExercise(
                    plan: ExercisePlan(
                        name: "Test Press",
                        targetLoad: Load(40),
                        targetReps: RepRange(8, 8),
                        plannedSetCount: 1,
                        restSeconds: 60,
                        previousPerformance: []
                    )
                )
            ]
        )
    }
}

private struct FailingBodyWeightStore: BodyWeightPersisting {
    let initial: [BodyWeightEntry]

    init(initial: [BodyWeightEntry] = []) {
        self.initial = initial
    }

    func load() throws -> [BodyWeightEntry] { initial }
    func save(_ entries: [BodyWeightEntry]) throws {
        throw BodyWeightStoreError.verificationFailed
    }
}

@MainActor
final class ProgressJourneyTests: XCTestCase {
    func testWeekCountsOnlySavedSessionsAndKeepsPartialWork() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 21, hour: 12
        )))
        let friday = try XCTUnwrap(calendar.date(byAdding: .day, value: 4, to: monday))
        let priorSunday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: monday))
        let now = try XCTUnwrap(calendar.date(byAdding: .day, value: 5, to: monday))
        let week = ProgressWeekSnapshot(
            entries: [
                try item(at: friday, reps: [8], plannedSets: 3),
                try item(at: monday, reps: [8, 8, 8], plannedSets: 3),
                try item(at: priorSunday, reps: [8], plannedSets: 3)
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(week.workoutCount, 2)
        XCTAssertEqual(week.savedSetCount, 4)
        XCTAssertEqual(week.sessions.map(\.endedEarly), [true, false])
    }

    func testLoadReviewUsesSavedTopRangeSetsAndExactSource() throws {
        let fixture = try WorkoutProgressionTestFixture()
        let reviews = ProgressLoadReview.available(for: fixture.session,
            entries: [WorkoutHistoryDisplayItem(entry: fixture.entry)], progressionReviews: [fixture.review], asOf: fixture.now)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(review.sourceSessionID, fixture.entry.id)
        XCTAssertEqual(review.upgrade.opportunity.previousLoad, Load(40))
        XCTAssertEqual(review.upgrade.opportunity.suggestedLoad, Load(42.5))
        XCTAssertEqual(review.upgrade.completedSets.map(\.reps), [10, 10])
    }

    func testLoadReviewDoesNotInventUpgradeFromLowerSession() throws {
        let saved = try session(at: Date(timeIntervalSince1970: 1_000), reps: [8, 7, 8])
        let entry = WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: saved))

        XCTAssertTrue(ProgressLoadReview.available(for: saved, entries: [entry]).isEmpty)
    }

    func testLoadReviewStopsAtNewerUnknownExerciseDetails() throws {
        let saved = try session(at: Date(timeIntervalSince1970: 1_000), reps: [8, 8, 8])
        let later = try session(at: Date(timeIntervalSince1970: 2_000), reps: [8, 8, 8])
        let encoded = try JSONEncoder().encode(WorkoutHistoryEntry(session: later))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "exercises")
        let unknown = try JSONDecoder().decode(
            WorkoutHistoryEntry.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        let entries = [
            WorkoutHistoryDisplayItem(entry: unknown),
            WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(session: saved))
        ]

        XCTAssertTrue(ProgressLoadReview.available(for: saved, entries: entries).isEmpty)
    }

    func testBodyWeightChartMaintainsCalmMinimumSpan() {
        let now = Date(timeIntervalSince1970: 10_000)
        let trend = BodyWeightTrend(entries: [
            BodyWeightEntry(id: UUID(), recordedAt: now, kilograms: 70),
            BodyWeightEntry(id: UUID(), recordedAt: now.addingTimeInterval(-86_400), kilograms: 70.2)
        ], now: now, calendar: .current)

        let kilograms = trend.chartDomain(for: .kilograms)
        let pounds = trend.chartDomain(for: .pounds)
        XCTAssertNotNil(kilograms)
        XCTAssertNotNil(pounds)
        XCTAssertGreaterThanOrEqual((kilograms?.upperBound ?? 0) - (kilograms?.lowerBound ?? 0), 4)
        XCTAssertGreaterThanOrEqual((pounds?.upperBound ?? 0) - (pounds?.lowerBound ?? 0), 9)
    }

    private func item(at date: Date, reps: [Int], plannedSets: Int) throws -> WorkoutHistoryDisplayItem {
        WorkoutHistoryDisplayItem(entry: WorkoutHistoryEntry(
            session: try session(at: date, reps: reps, plannedSets: plannedSets)
        ))
    }

    private func session(
        at date: Date,
        reps: [Int],
        plannedSets: Int = 3
    ) throws -> WorkoutSession {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell Bench Press",
            targetLoad: Load(40),
            targetReps: RepRange(6, 8),
            plannedSetCount: plannedSets,
            restSeconds: 0,
            previousPerformance: []
        )
        var result = WorkoutSession(title: "Bench", exercises: [WorkoutExercise(plan: plan)])
        for (index, count) in reps.enumerated() {
            _ = try result.completeCurrentSet(
                load: Load(40), reps: count,
                at: date.addingTimeInterval(Double(index))
            )
            result.skipRest()
        }
        if !result.isComplete {
            XCTAssertTrue(result.finishEarly(at: date.addingTimeInterval(10)))
        }
        return result
    }
}

private final class TestWorkoutHistoryStore: WorkoutHistoryPersisting {
    private var stored: [WorkoutHistoryEntry] = []

    func load() -> [WorkoutHistoryEntry] { stored }

    func save(_ entries: [WorkoutHistoryEntry]) {
        stored = entries
    }
}
