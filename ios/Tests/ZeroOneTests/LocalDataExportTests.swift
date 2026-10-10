import Foundation
import XCTest
@testable import ZeroOne

final class LocalDataExportTests: XCTestCase {
    func testAccentExportRoundTripAndOlderSettingsRemainReadable() throws {
        let settings = try LocalSettingsExport(profile: nil, dailyGoals: .empty,
                                               appearancePreference: "dark", accentPreference: "pink")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(LocalSettingsExport.self, from: data), settings)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        older.removeValue(forKey: "accentPreference")
        let restored = try JSONDecoder().decode(LocalSettingsExport.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(restored.accentPreference)
        XCTAssertEqual(restored.appearancePreference, "dark")
    }

    func testVersionedRoundTripPreservesRecordedWorkoutAndBodyWeight() throws {
        let workout = completedWorkout()
        let weight = BodyWeightEntry(
            id: UUID(), recordedAt: Date(timeIntervalSinceReferenceDate: 7_000.125),
            kilograms: Decimal(string: "82.375")!
        )
        let exportedAt = Date(timeIntervalSinceReferenceDate: 8_000.5)
        let data = try makeExport(
            historyStore: TestHistoryStore(entries: [workout]),
            bodyWeightStore: TestBodyWeightStore(entries: [weight])
        ).createJSON(selection: .init(workouts: true, mealsAndWater: false, bodyWeight: true, outdoorActivities: false, goalsAndPreferences: false), exportedAt: exportedAt)
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)

        XCTAssertEqual(package.schemaVersion, LocalDataExportPackage.currentSchemaVersion)
        XCTAssertEqual(package.exportedAt, exportedAt)
        XCTAssertEqual(package.completedWorkouts, [workout])
        XCTAssertEqual(package.bodyWeightReadings, [weight])
        XCTAssertEqual(package.bodyWeightStoredUnit, "kg")
        XCTAssertEqual(package.completedWorkouts[0].exercises?[0].completedSets[0].load.unit, .pounds)
        XCTAssertEqual(package.completedWorkouts[0].exercises?[0].completedSets[0].load.value, 42.125)
        XCTAssertEqual(package.completedWorkouts[0].exercises?[0].completedSets[0].rir, 0)
        XCTAssertEqual(package.completedWorkouts[0].exercises?[0].completedSets[0].completedAt,
                       Date(timeIntervalSinceReferenceDate: 6_000.25))
        XCTAssertTrue(package.bodyWeightProvenance.contains("original input source unknown"))
    }

    func testLegacySummaryKeepsUnknownExerciseAndWarmUpDetails() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [[
            "id": id.uuidString,
            "title": "Legacy summary",
            "completedAt": 1_234.125,
            "completedSetCount": 3,
            "plannedSetCount": 4,
            "wasAdapted": false
        ]])
        let legacy = try JSONDecoder().decode([WorkoutHistoryEntry].self, from: data)
        let exported = try makeExport(
            historyStore: TestHistoryStore(entries: legacy), bodyWeightStore: TestBodyWeightStore()
        ).createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])
        let entry = try XCTUnwrap(
            JSONDecoder().decode(LocalDataExportPackage.self, from: exported).completedWorkouts.first
        )

        XCTAssertEqual(entry, legacy[0])
        XCTAssertNil(entry.exercises)
        XCTAssertNil(entry.warmUp)
        XCTAssertNil(entry.programmeID)
    }

    func testMissingFilesExportAnExplicitEmptySnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try makeExport(
            historyStore: FileWorkoutHistoryStore(directory: root, legacyStore: TestHistoryStore()),
            bodyWeightStore: LocalBodyWeightStore(rootURL: root.appendingPathComponent("BodyWeight"))
        ).createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)

        XCTAssertTrue(package.completedWorkouts.isEmpty)
        XCTAssertTrue(package.bodyWeightReadings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnreadableHistoryOrBodyWeightFailsWithoutProducingJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.json")
        let bodyRoot = root.appendingPathComponent("BodyWeight")
        let bodyURL = bodyRoot.appendingPathComponent("entries.json")
        try FileManager.default.createDirectory(at: bodyRoot, withIntermediateDirectories: true)
        try Data("invalid history".utf8).write(to: historyURL)
        try Data("invalid body weight".utf8).write(to: bodyURL)

        let export = makeExport(
            historyStore: FileWorkoutHistoryStore(directory: root, legacyStore: TestHistoryStore()),
            bodyWeightStore: LocalBodyWeightStore(rootURL: bodyRoot)
        )
        XCTAssertThrowsError(try export.createJSON(selection: .init(workouts: true, mealsAndWater: false, bodyWeight: true, outdoorActivities: false, goalsAndPreferences: false))) { error in
            XCTAssertEqual(error as? LocalDataExportError, .workoutHistoryUnavailable)
        }
        try FileManager.default.removeItem(at: historyURL)
        XCTAssertThrowsError(try export.createJSON(selection: .init(workouts: true, mealsAndWater: false, bodyWeight: true, outdoorActivities: false, goalsAndPreferences: false))) { error in
            XCTAssertEqual(error as? LocalDataExportError, .bodyWeightUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: bodyURL), Data("invalid body weight".utf8))
    }

    func testDuplicateSourceIdentifiersFailClosedAndScopeStaysLimited() throws {
        let workout = completedWorkout()
        let weight = BodyWeightEntry(id: UUID(), recordedAt: .now, kilograms: 80)
        XCTAssertThrowsError(try makeExport(
            historyStore: TestHistoryStore(entries: [workout, workout]),
            bodyWeightStore: TestBodyWeightStore(entries: [weight])
        ).createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])) { error in
            XCTAssertEqual(error as? LocalDataExportError, .duplicateSourceIdentifier)
        }
        XCTAssertThrowsError(try makeExport(
            historyStore: TestHistoryStore(entries: [workout]),
            bodyWeightStore: TestBodyWeightStore(entries: [weight, weight])
        ).createJSON(selection: .init(workouts: true, mealsAndWater: false, bodyWeight: true, outdoorActivities: false, goalsAndPreferences: false))) { error in
            XCTAssertEqual(error as? LocalDataExportError, .duplicateSourceIdentifier)
        }

        let data = try makeExport(
            historyStore: TestHistoryStore(entries: [workout]),
            bodyWeightStore: TestBodyWeightStore(entries: [weight])
        ).createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), [
            "schemaVersion", "exportedAt", "workoutHistoryProvenance", "bodyWeightProvenance",
            "bodyWeightStoredUnit", "completedWorkouts", "bodyWeightReadings", "selection", "meals", "coverageNotes", "outdoorActivities"
        ])
    }

    func testBodyWeightIsNotReadWithoutExplicitSelection() throws {
        let weight = ExportWeightSpy()
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: weight)
        let data = try export.createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        XCTAssertEqual(weight.reads, 0)
        XCTAssertEqual(package.selection?.bodyWeight, false)
        XCTAssertTrue(package.bodyWeightReadings.isEmpty)
        XCTAssertThrowsError(try export.createJSON(selection: .init(workouts: false, mealsAndWater: false, bodyWeight: true, outdoorActivities: false, goalsAndPreferences: false)))
        XCTAssertEqual(weight.reads, 1)
    }

    func testSelectedMealsAndWaterPreserveSavedValuesAndExcludeOtherSources() throws {
        let meal = NutritionEntry(id: UUID(), title: "Lunch", calories: 420,
            proteinGrams: 32.5, carbohydrateGrams: nil, fatGrams: 12.75,
            loggedAt: Date(timeIntervalSinceReferenceDate: 12_000.25))
        let water = HydrationStoredState(date: meal.loggedAt, currentMilliliters: 750,
            goalMilliliters: 2_500, dayStart: Date(timeIntervalSinceReferenceDate: 0))
        let nutrition = ExportNutritionStore(entries: [meal])
        let hydration = ExportHydrationStore(state: water)
        let weight = ExportWeightSpy()
        let data = try LocalDataExport(historyStore: TestHistoryStore(isAvailable: false),
            bodyWeightStore: weight, nutritionStore: nutrition, hydrationStore: hydration)
            .createJSON(selection: .init(workouts: false, mealsAndWater: true, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false))
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        XCTAssertEqual(package.meals, [meal])
        XCTAssertEqual(package.waterSnapshot, water)
        XCTAssertTrue(package.completedWorkouts.isEmpty)
        XCTAssertEqual(weight.reads, 0)
        XCTAssertTrue(package.coverageNotes?.contains(where: { $0.contains("No historical water log") }) == true)
    }

    func testNoSelectionAndUnavailableSelectedSourcesFailClosed() throws {
        let nutrition = ExportNutritionStore()
        let hydration = ExportHydrationStore()
        let export = LocalDataExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore(),
            nutritionStore: nutrition, hydrationStore: hydration)
        XCTAssertThrowsError(try export.createJSON(selection: .init(workouts: false, mealsAndWater: false, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false))) {
            XCTAssertEqual($0 as? LocalDataExportError, .nothingSelected)
        }
        XCTAssertEqual(nutrition.reads, 0)
        XCTAssertEqual(hydration.reads, 0)
        nutrition.isAvailable = false
        XCTAssertThrowsError(try export.createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])) {
            XCTAssertEqual($0 as? LocalDataExportError, .nutritionUnavailable)
        }
        nutrition.isAvailable = true
        hydration.isAvailable = false
        XCTAssertThrowsError(try export.createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])) {
            XCTAssertEqual($0 as? LocalDataExportError, .hydrationUnavailable)
        }
        XCTAssertNoThrow(try export.createJSON(selection: .init(workouts: true, mealsAndWater: false, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false)))
    }

    func testSchemaOneExportStillDecodesWithoutInventingCoverage() throws {
        let data = try makeExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore()).createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["schemaVersion"] = 1
        for key in ["selection", "meals", "waterSnapshot", "coverageNotes", "outdoorActivities"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(LocalDataExportPackage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.selection)
        XCTAssertNil(decoded.meals)
        XCTAssertNil(decoded.coverageNotes)
    }

    func testOutdoorSummaryDoesNotEncodeCoordinatesWithoutOptIn() throws {
        let record = outdoorRecord()
        XCTAssertTrue(record.isValid)
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore())
        let data = try export.createJSON(selection: .init(workouts: false, mealsAndWater: false, goalsAndPreferences: false), outdoorRecords: [record])
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        let summary = try XCTUnwrap(package.outdoorActivities?.first)
        XCTAssertEqual(summary.id, record.id)
        XCTAssertEqual(summary.recordedDistanceMeters, record.recordedDistanceMeters)
        XCTAssertEqual(summary.recordedSteps, record.recordedSteps)
        XCTAssertEqual(summary.hasMissingLocationCoverage, record.hasMissingLocationCoverage)
        XCTAssertNil(summary.routeSegments)
        XCTAssertEqual(summary.routeStatus, "not selected")
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("latitude"))
        XCTAssertFalse(json.contains("longitude"))
        XCTAssertFalse(json.contains("routeSegments"))
        XCTAssertEqual(record.route?.segments.count, 2)
    }

    func testExplicitRouteExportPreservesSegmentsAndDoesNotRecreateDeletedRoutes() throws {
        let record = outdoorRecord()
        var deleted = record
        deleted.route = nil
        deleted.routeDeletedAt = record.finishedAt
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore())
        let selection = LocalDataExportSelection(workouts: false, mealsAndWater: false, routes: true, goalsAndPreferences: false)
        let data = try export.createJSON(selection: selection, outdoorRecords: [record])
        let included = try XCTUnwrap(JSONDecoder().decode(LocalDataExportPackage.self, from: data).outdoorActivities?.first)
        XCTAssertEqual(included.routeSegments, record.route?.segments)
        XCTAssertEqual(included.routeSegments?.count, 2)
        let deletedData = try export.createJSON(selection: selection, outdoorRecords: [deleted])
        let removed = try XCTUnwrap(JSONDecoder().decode(LocalDataExportPackage.self, from: deletedData).outdoorActivities?.first)
        XCTAssertNil(removed.routeSegments)
        XCTAssertEqual(removed.routeStatus, "previously deleted")
        XCTAssertEqual(removed.recordedDistanceMeters, record.recordedDistanceMeters)
    }

    func testOutdoorFailureDoesNotBecomeEmptySuccessAndLegacySelectionStaysExcluded() throws {
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore())
        XCTAssertThrowsError(try export.createJSON(selection: .init(goalsAndPreferences: false))) {
            XCTAssertEqual($0 as? LocalDataExportError, .outdoorUnavailable)
        }
        let record = outdoorRecord()
        XCTAssertThrowsError(try export.createJSON(selection: .init(goalsAndPreferences: false), outdoorRecords: [record, record])) {
            XCTAssertEqual($0 as? LocalDataExportError, .outdoorUnavailable)
        }
        XCTAssertThrowsError(try export.createJSON(selection: .init(outdoorActivities: false, routes: true, goalsAndPreferences: false))) {
            XCTAssertEqual($0 as? LocalDataExportError, .invalidRouteSelection)
        }
        let legacy = Data(#"{"workouts":true,"mealsAndWater":true,"bodyWeight":false}"#.utf8)
        let selection = try JSONDecoder().decode(LocalDataExportSelection.self, from: legacy)
        XCTAssertFalse(selection.outdoorActivities)
        XCTAssertFalse(selection.routes)
        XCTAssertNoThrow(try export.createJSON(selection: selection))
    }

    func testSettingsExportAllowlistExcludesBodyWeightDraftAndInternalIDs() throws {
        var profile = ZeroOneUserProfile()
        profile.displayName = "Sample person"
        profile.preferredTrainingDays = [.friday, .monday]
        profile.preferredWeightUnit = .pounds
        profile.startingBodyWeight = 183.75
        profile.startingBodyWeightEntryID = UUID()
        profile.firstWeekDraftWorkoutIDs = [UUID()]
        let settings = try LocalSettingsExport(profile: profile,
            dailyGoals: DailyGoals(steps: 8_000, foodKilocalories: nil), appearancePreference: "dark")
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: ExportWeightSpy())
        let selection = LocalDataExportSelection(workouts: false, mealsAndWater: false, outdoorActivities: false)
        let data = try export.createJSON(selection: selection, settings: settings)
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        XCTAssertEqual(package.goalsAndPreferences, settings)
        XCTAssertEqual(settings.profile?.preferredTrainingDaysMondayZeroBased, [0, 4])
        XCTAssertEqual(settings.profile?.preferredWeightUnit, "lb")
        XCTAssertEqual(settings.dailyGoals.steps, 8_000)
        XCTAssertNil(settings.dailyGoals.foodKilocalories)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["startingBodyWeight", "firstWeekDraftWorkoutIDs", "onboardingComplete", "183.75"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertTrue(package.bodyWeightReadings.isEmpty)
    }

    func testUnselectedSettingsOmittedAndSelectedMissingSettingsFail() throws {
        let export = makeExport(historyStore: TestHistoryStore(), bodyWeightStore: TestBodyWeightStore())
        XCTAssertThrowsError(try export.createJSON(outdoorRecords: [])) {
            XCTAssertEqual($0 as? LocalDataExportError, .settingsUnavailable)
        }
        let settings = try LocalSettingsExport(profile: nil, dailyGoals: .empty, appearancePreference: "light")
        let selection = LocalDataExportSelection(mealsAndWater: false, outdoorActivities: false, goalsAndPreferences: false)
        let data = try export.createJSON(selection: selection, settings: settings)
        let package = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        XCTAssertNil(package.goalsAndPreferences)
        XCTAssertThrowsError(try LocalSettingsExport(profile: nil,
            dailyGoals: DailyGoals(steps: -1, foodKilocalories: nil), appearancePreference: "light"))
        XCTAssertThrowsError(try LocalSettingsExport(profile: nil, dailyGoals: .empty, appearancePreference: "invalid"))
    }

    func testProfileExportReadPreservesCorruptAndIncompatibleData() throws {
        let suite = "LocalDataExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.profile"
        let store = UserDefaultsZeroOneUserProfileStore(defaults: defaults, key: key)
        XCTAssertNil(try store.loadForExport())
        let corrupt = Data("not profile JSON".utf8)
        defaults.set(corrupt, forKey: key)
        XCTAssertThrowsError(try store.loadForExport())
        XCTAssertNil(store.load())
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
        var profile = ZeroOneUserProfile()
        profile.version = 99
        let incompatible = try JSONEncoder().encode(profile)
        defaults.set(incompatible, forKey: key)
        XCTAssertThrowsError(try store.loadForExport())
        XCTAssertEqual(defaults.data(forKey: key), incompatible)
        defaults.set("wrong storage type", forKey: key)
        XCTAssertThrowsError(try store.loadForExport())
        XCTAssertEqual(defaults.string(forKey: key), "wrong storage type")
    }

    @MainActor
    func testProfileAndGoalsExportUseFreshSavedValuesNotCachedState() throws {
        let suite = "LocalDataExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileStore = UserDefaultsZeroOneUserProfileStore(defaults: defaults)
        let goalsStore = UserDefaultsDailyGoalsStore(defaults: defaults)
        let profileRepository = ZeroOneUserProfileRepository(store: profileStore)
        let goalsRepository = DailyGoalsRepository(store: goalsStore)
        var changed = ZeroOneUserProfile()
        changed.displayName = "Updated"
        profileStore.save(changed)
        try goalsStore.save(DailyGoals(steps: 9_000, foodKilocalories: 2_200))
        XCTAssertEqual(try profileRepository.profileForExport()?.displayName, "Updated")
        XCTAssertEqual(try goalsRepository.valueForExport().steps, 9_000)
        XCTAssertNil(profileRepository.profile.displayName)
        XCTAssertNil(goalsRepository.value.steps)
    }

    private func outdoorRecord() -> OutdoorActivityRecord {
        let date = Date(timeIntervalSinceReferenceDate: 20_000)
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 20,
            maximumGapSeconds: 30, maximumPlausibleSpeedMetersPerSecond: 20, maximumFutureSeconds: 1)
        for offset in [0, 10, 100] {
            let time = date.addingTimeInterval(Double(offset))
            _ = route.ingest(OutdoorRouteFix(latitude: 43, longitude: 27 + Double(offset) * 0.00001,
                timestamp: time, horizontalAccuracyMeters: 5), receivedAt: time, policy: policy)
        }
        let end = date.addingTimeInterval(120)
        return OutdoorActivityRecord(checkpoint: OutdoorActivityCheckpoint(kind: .walk,
            startedAt: date, checkpointedAt: end, confirmedActiveSeconds: 120,
            phase: .readyToSave, finishedAt: end, route: route), finishedAt: end)
    }

    private func makeExport(historyStore: any WorkoutHistoryPersisting,
                            bodyWeightStore: any BodyWeightPersisting) -> LocalDataExport {
        LocalDataExport(historyStore: historyStore, bodyWeightStore: bodyWeightStore,
            nutritionStore: ExportNutritionStore(), hydrationStore: ExportHydrationStore())
    }

    private func completedWorkout() -> WorkoutHistoryEntry {
        let completedSet = CompletedSet(
            id: UUID(), load: Load(42.125, unit: .pounds), reps: 9, rir: 0,
            completedAt: Date(timeIntervalSinceReferenceDate: 6_000.25)
        )
        let plan = ExercisePlan(
            name: "Bench press", targetLoad: Load(42.125, unit: .pounds),
            targetReps: RepRange(8, 10), plannedSetCount: 1, restSeconds: 90,
            previousPerformance: []
        )
        let session = WorkoutSession(
            title: "Completed session", exercises: [WorkoutExercise(plan: plan, completedSets: [completedSet])],
            completedAt: Date(timeIntervalSinceReferenceDate: 6_100.75)
        )
        return WorkoutHistoryEntry(session: session)
    }
}

private struct TestHistoryStore: WorkoutHistoryPersisting {
    var entries: [WorkoutHistoryEntry] = []
    var isAvailable = true

    func load() throws -> [WorkoutHistoryEntry] { entries }
    func save(_ entries: [WorkoutHistoryEntry]) throws { XCTFail("Export must not write workout history") }
}

private struct TestBodyWeightStore: BodyWeightPersisting {
    var entries: [BodyWeightEntry] = []

    func load() throws -> [BodyWeightEntry] { entries }
    func save(_ entries: [BodyWeightEntry]) throws { XCTFail("Export must not write body weight") }
}

private final class ExportWeightSpy: BodyWeightPersisting {
    var reads = 0
    func load() throws -> [BodyWeightEntry] { reads += 1; throw CocoaError(.fileReadCorruptFile) }
    func save(_ entries: [BodyWeightEntry]) throws { XCTFail("Export must not write") }
}

private final class ExportNutritionStore: NutritionPersisting {
    var entries: [NutritionEntry]
    var isAvailable = true
    var reads = 0
    init(entries: [NutritionEntry] = []) { self.entries = entries }
    func load() -> [NutritionEntry] { reads += 1; return entries }
    func save(_ entries: [NutritionEntry]) { XCTFail("Export must not write") }
}

private final class ExportHydrationStore: HydrationPersisting {
    var state: HydrationStoredState?
    var isAvailable = true
    var reads = 0
    init(state: HydrationStoredState? = nil) { self.state = state }
    func load() -> HydrationStoredState? { reads += 1; return state }
    func save(_ state: HydrationStoredState) { XCTFail("Export must not write") }
}
