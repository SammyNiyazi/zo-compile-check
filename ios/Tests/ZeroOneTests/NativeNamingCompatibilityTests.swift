import XCTest
import UIKit
@testable import ZeroOne

final class NativeNamingCompatibilityTests: XCTestCase {
    func testLegacyProgrammeIDsDecodeAndEncodeWithoutChangingStoredIdentity() throws {
        let pairs: [(String, WorkoutProgrammeID)] = [
            ("PRG-SLICK-START-3", .zeroOneStart),
            ("PRG-SLICK-BUILD-4", .zeroOneBuild),
            ("PRG-SLICK-CONSIST-3", .zeroOneConsistency)
        ]
        for (raw, expected) in pairs {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(WorkoutProgrammeID.self, from: data), expected)
            XCTAssertEqual(try JSONEncoder().encode(expected), data)
            XCTAssertNotNil(WorkoutProgrammeLibrary.programme(id: expected))
        }
    }

    func testDefaultSelectionAndScheduleKeysReadInstalledData() throws {
        let suite = "01.naming.compatibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("PRG-SLICK-BUILD-4", forKey: "slick.selectedProgramme")
        let selection = UserDefaultsWorkoutProgrammeSelectionStore(defaults: defaults)
        XCTAssertEqual(selection.loadSelectedID(), .zeroOneBuild)
        selection.saveSelectedID(.zeroOneConsistency)
        XCTAssertEqual(defaults.string(forKey: "slick.selectedProgramme"), "PRG-SLICK-CONSIST-3")

        let payload = Data(#"{"programmeID":"PRG-SLICK-START-3","weekdays":[2,4,6],"confirmedAt":0}"#.utf8)
        defaults.set(payload, forKey: "slick.workoutProgrammeSchedule.v1")
        let store = UserDefaultsWorkoutProgrammeScheduleStore(defaults: defaults)
        let schedule = try XCTUnwrap(store.load())
        XCTAssertEqual(schedule.programmeID, .zeroOneStart)
        XCTAssertEqual(schedule.weekdays, [2,4,6])
        try store.save(schedule)
        let roundtrip = try XCTUnwrap(defaults.data(forKey: "slick.workoutProgrammeSchedule.v1"))
        XCTAssertEqual(try JSONDecoder().decode(WorkoutProgrammeSchedule.self, from: roundtrip), schedule)
    }

    func testDefaultProfileAndHistoryKeysDoNotHideCorruptInstalledData() throws {
        let suite = "01.naming.compatibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unreadable = Data("existing unreadable record".utf8)
        defaults.set(unreadable, forKey: "slick.userProfile")
        defaults.set(unreadable, forKey: "slick.workoutHistory")
        XCTAssertThrowsError(try UserDefaultsZeroOneUserProfileStore(defaults: defaults).loadForExport())
        XCTAssertThrowsError(try UserDefaultsWorkoutHistoryStore(defaults: defaults).load())
        XCTAssertEqual(defaults.data(forKey: "slick.userProfile"), unreadable)
        XCTAssertEqual(defaults.data(forKey: "slick.workoutHistory"), unreadable)
    }

    func testDefaultWorkoutDirectoryKeepsInstalledLocation() throws {
        let url = try WorkoutPersistenceFiles.file("history.json", directory: nil)
        XCTAssertTrue(url.path.hasSuffix("/Slick/Workouts/history.json"))
    }

    func testDefaultPhotoAndWeightDirectoriesStillReadExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let unreadable = Data("existing unreadable record".utf8)
        for relative in ["Slick/ProgressPhotos/records.json", "Slick/BodyWeight/entries.json"] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try unreadable.write(to: file)
        }
        let manager = NamingTestFileManager(support: root)
        let photos = LocalProgressPhotoStore(fileManager: manager)
        XCTAssertFalse(photos.isAvailable)
        XCTAssertThrowsError(try photos.loadRecords())
        XCTAssertThrowsError(try LocalBodyWeightStore(fileManager: manager).load())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Slick/BodyWeight/entries.json")), unreadable)
    }

    func testRenamedBundledResourcesResolve() throws {
        let seed = try TrainingSeedLoader().load()
        XCTAssertTrue(seed.programmeTemplates.contains { $0.id == "PRG-SLICK-START-3" })
        XCTAssertNotNil(UIImage(named: "ZeroOneWordmark"))
        XCTAssertNotNil(UIImage(named: "ZeroOneSplashLogo"))
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.the01.ios")
    }
}

private final class NamingTestFileManager: FileManager, @unchecked Sendable {
    let support: URL
    init(support: URL) { self.support = support; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [support] : super.urls(for: directory, in: domainMask)
    }
}
