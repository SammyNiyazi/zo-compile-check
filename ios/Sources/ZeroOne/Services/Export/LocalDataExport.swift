import Foundation

struct LocalDataExportSelection: Codable, Equatable {
    var workouts = true
    var mealsAndWater = true
    var bodyWeight = false
    var outdoorActivities = true
    var routes = false
    var goalsAndPreferences = true
    var hasSelection: Bool { workouts || mealsAndWater || bodyWeight || outdoorActivities || goalsAndPreferences }

    enum CodingKeys: String, CodingKey { case workouts, mealsAndWater, bodyWeight, outdoorActivities, routes, goalsAndPreferences }
    init(workouts: Bool = true, mealsAndWater: Bool = true, bodyWeight: Bool = false,
         outdoorActivities: Bool = true, routes: Bool = false, goalsAndPreferences: Bool = true) {
        self.workouts = workouts; self.mealsAndWater = mealsAndWater; self.bodyWeight = bodyWeight
        self.outdoorActivities = outdoorActivities; self.routes = routes
        self.goalsAndPreferences = goalsAndPreferences
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workouts = try values.decode(Bool.self, forKey: .workouts)
        mealsAndWater = try values.decode(Bool.self, forKey: .mealsAndWater)
        bodyWeight = try values.decode(Bool.self, forKey: .bodyWeight)
        // Older exports never included outdoor data. Do not imply they did.
        outdoorActivities = try values.decodeIfPresent(Bool.self, forKey: .outdoorActivities) ?? false
        routes = try values.decodeIfPresent(Bool.self, forKey: .routes) ?? false
        goalsAndPreferences = try values.decodeIfPresent(Bool.self, forKey: .goalsAndPreferences) ?? false
    }
}

/// An export projection, never a modified storage record or restore payload.
struct OutdoorActivityExport: Codable, Equatable {
    let id: UUID
    let kind: OutdoorActivityKind
    let trackingMode: OutdoorTrackingMode
    let startedAt: Date
    let finishedAt: Date
    let confirmedActiveSeconds: TimeInterval
    let recordedDistanceMeters: Double?
    let hasMissingLocationCoverage: Bool
    let recordedSteps: Int?
    let hasIncompleteStepCoverage: Bool
    let routeStatus: String
    let routeSegments: [OutdoorRouteSegment]?

    init(_ record: OutdoorActivityRecord, includeRoute: Bool) {
        id = record.id; kind = record.kind; trackingMode = record.trackingMode
        startedAt = record.startedAt; finishedAt = record.finishedAt
        confirmedActiveSeconds = record.confirmedActiveSeconds
        recordedDistanceMeters = record.recordedDistanceMeters
        hasMissingLocationCoverage = record.hasMissingLocationCoverage
        recordedSteps = record.recordedSteps
        hasIncompleteStepCoverage = record.hasIncompleteStepCoverage
        routeSegments = includeRoute ? record.route?.segments : nil
        if !includeRoute { routeStatus = "not selected" }
        else if record.routeDeletedAt != nil { routeStatus = "previously deleted" }
        else if record.route?.segments.isEmpty != false { routeStatus = "no recorded coordinates" }
        else { routeStatus = "included; segments preserve recorded gaps" }
    }
}

/// A selected snapshot of the app-owned records supported by local export.
/// No restore contract is implied by this format.
struct LocalDataExportPackage: Codable, Equatable {
    static let currentSchemaVersion = 6

    let schemaVersion: Int
    let exportedAt: Date
    let workoutHistoryProvenance: String
    let bodyWeightProvenance: String
    let bodyWeightStoredUnit: String
    let completedWorkouts: [WorkoutHistoryEntry]
    let bodyWeightReadings: [BodyWeightEntry]
    // Optional for decoding previously exported version-one files.
    let selection: LocalDataExportSelection?
    let meals: [NutritionEntry]?
    let waterSnapshot: HydrationStoredState?
    let coverageNotes: [String]?
    let outdoorActivities: [OutdoorActivityExport]?
    let goalsAndPreferences: LocalSettingsExport?

    init(exportedAt: Date, completedWorkouts: [WorkoutHistoryEntry], bodyWeightReadings: [BodyWeightEntry],
         selection: LocalDataExportSelection, meals: [NutritionEntry]?, waterSnapshot: HydrationStoredState?,
         outdoorActivities: [OutdoorActivityExport]?, goalsAndPreferences: LocalSettingsExport?) {
        schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        workoutHistoryProvenance = selection.workouts
            ? "app-owned completed workout history" : "not selected; workout history was not read"
        bodyWeightProvenance = selection.bodyWeight
            ? "app-owned local body weight records; original input source unknown"
            : "not selected; body weight records were not read"
        bodyWeightStoredUnit = BodyWeightUnit.kilograms.rawValue
        self.completedWorkouts = completedWorkouts
        self.bodyWeightReadings = bodyWeightReadings
        self.selection = selection
        self.meals = meals
        self.waterSnapshot = waterSnapshot
        self.outdoorActivities = outdoorActivities
        self.goalsAndPreferences = goalsAndPreferences
        coverageNotes = [
            "Selected app-owned sources were read sequentially, not as a cross-store transaction.",
            "Rest evidence records countdown transitions only, including known pauses, skips, recovery and failed-save restarts. Missing journals, unobserved gaps and omitted transitions remain unknown; no physical rest duration is inferred.",
            "Programme provenance retains authored session/occurrence slots and authored, effective and start-prescription fingerprints where captured. Older records remain unknown and are never identified from titles. Adapted execution retains its original start source.",
            "Meal values retain reported origins, consumed portions and reference-value bases where recorded. Missing fields remain unknown. Manually reported labels/databases are not independently verified; recipe or ingredient safety is not established.",
            "Portion-scaled calories are rounded to whole kilocalories. Reference values remain in foodEvidence; unknown macros are not replaced with zero. Grams, milliliters and servings are never interconverted.",
            "Water includes only the latest persisted daily snapshot. No historical water log is implied.",
            "Outdoor data includes saved activities only, not an active or unsaved session. Coordinates are included only when routes are explicitly selected.",
            "Selected settings include saved profile/training preferences, daily step/food goals and the current appearance and accent preferences. Other settings and unsaved drafts are not included.",
            "Photos, raw HealthKit data, permissions, credentials and subscription state are not included.",
            "This is a readable export, not a backup or supported restore package."
        ]
    }
}

enum LocalDataExportError: Error, Equatable {
    case workoutHistoryUnavailable
    case bodyWeightUnavailable
    case duplicateSourceIdentifier
    case verificationFailed
    case nothingSelected
    case nutritionUnavailable
    case hydrationUnavailable
    case outdoorUnavailable
    case invalidRouteSelection
    case settingsUnavailable
}

/// Creates JSON in memory only. The caller chooses whether and where to share it.
struct LocalDataExport {
    private let historyStore: any WorkoutHistoryPersisting
    private let bodyWeightStore: any BodyWeightPersisting
    private let nutritionStore: any NutritionPersisting
    private let hydrationStore: any HydrationPersisting

    init(
        historyStore: any WorkoutHistoryPersisting = FileWorkoutHistoryStore(),
        bodyWeightStore: any BodyWeightPersisting = LocalBodyWeightStore(),
        nutritionStore: any NutritionPersisting = UserDefaultsNutritionStore(),
        hydrationStore: any HydrationPersisting = UserDefaultsHydrationStore()
    ) {
        self.historyStore = historyStore
        self.bodyWeightStore = bodyWeightStore
        self.nutritionStore = nutritionStore
        self.hydrationStore = hydrationStore
    }

    func createJSON(selection: LocalDataExportSelection = .init(), exportedAt: Date = .now,
                    outdoorRecords: [OutdoorActivityRecord]? = nil, settings: LocalSettingsExport? = nil) throws -> Data {
        guard selection.hasSelection else { throw LocalDataExportError.nothingSelected }
        guard !selection.goalsAndPreferences || settings != nil else { throw LocalDataExportError.settingsUnavailable }
        guard !selection.routes || selection.outdoorActivities else { throw LocalDataExportError.invalidRouteSelection }
        let outdoor: [OutdoorActivityExport]?
        if selection.outdoorActivities {
            guard let outdoorRecords, outdoorRecords.allSatisfy(\.isValid),
                  Self.hasUniqueIDs(outdoorRecords.map(\.id)) else { throw LocalDataExportError.outdoorUnavailable }
            outdoor = outdoorRecords.sorted {
                $0.finishedAt == $1.finishedAt ? $0.id.uuidString < $1.id.uuidString : $0.finishedAt > $1.finishedAt
            }.map { OutdoorActivityExport($0, includeRoute: selection.routes) }
        } else { outdoor = nil }
        let workouts: [WorkoutHistoryEntry]
        do {
            if selection.workouts {
                guard historyStore.isAvailable else { throw LocalDataExportError.workoutHistoryUnavailable }
                workouts = try historyStore.load()
            } else { workouts = [] }
        } catch {
            throw LocalDataExportError.workoutHistoryUnavailable
        }

        let readings: [BodyWeightEntry]
        do {
            if selection.bodyWeight { readings = try bodyWeightStore.load() }
            else { readings = [] }
        } catch {
            throw LocalDataExportError.bodyWeightUnavailable
        }

        var meals: [NutritionEntry]?
        var water: HydrationStoredState?
        if selection.mealsAndWater {
            do {
                meals = try nutritionStore.loadVerified()
                try FoodBodyWeightImportDecoder.validateMeals(meals ?? [], requireUniqueIDs: false)
            } catch { throw LocalDataExportError.nutritionUnavailable }
            if let transactional = hydrationStore as? any HydrationTransactionalPersisting {
                do { water = try transactional.readTransaction().state }
                catch { throw LocalDataExportError.hydrationUnavailable }
            } else {
                guard hydrationStore.isAvailable else { throw LocalDataExportError.hydrationUnavailable }
                water = hydrationStore.load()
                guard hydrationStore.isAvailable else { throw LocalDataExportError.hydrationUnavailable }
            }
        }
        guard Self.hasUniqueIDs(workouts.map(\.id)), Self.hasUniqueIDs(readings.map(\.id)),
              Self.hasUniqueIDs((meals ?? []).map(\.id)) else {
            throw LocalDataExportError.duplicateSourceIdentifier
        }
        do { try WorkoutHistoryImportDecoder.validate(workouts) }
        catch { throw LocalDataExportError.workoutHistoryUnavailable }

        let package = LocalDataExportPackage(
            exportedAt: exportedAt,
            completedWorkouts: workouts.sorted(by: WorkoutHistoryEntry.newestFirst),
            bodyWeightReadings: readings.sorted {
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            },
            selection: selection,
            meals: meals?.sorted {
                $0.loggedAt == $1.loggedAt ? $0.id.uuidString < $1.id.uuidString : $0.loggedAt > $1.loggedAt
            }, waterSnapshot: water, outdoorActivities: outdoor,
            goalsAndPreferences: selection.goalsAndPreferences ? settings : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(package)
        guard try JSONDecoder().decode(LocalDataExportPackage.self, from: data) == package else {
            throw LocalDataExportError.verificationFailed
        }
        return data
    }

    private static func hasUniqueIDs(_ identifiers: [UUID]) -> Bool {
        Set(identifiers).count == identifiers.count
    }
}
