import Foundation
import XCTest
@testable import ZeroOne

/// Authored source coverage only until run on the native test target.
/// Uses real codecs, projections and isolated file stores; does not emulate ActivityKit.
@MainActor
final class WidgetThemeTransportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testDefaultSnapshotKeepsVersionOneAndExistingEncoderKeys() throws {
        var inputs = dailyInputs()
        inputs.language = nil
        let value = inputs.snapshot(at: now, calendar: calendar)
        let json = try object(value)
        XCTAssertEqual(value.version, 1)
        XCTAssertNil(value.designThemeIdentifier)
        XCTAssertEqual(value.displayTheme, .core)
        XCTAssertEqual(Set(json.keys), Set([
            "version", "generatedAt", "dayStart", "steps", "eatenKilocalories",
            "burnedKilocalories", "waterMilliliters", "waterGoalMilliliters",
            "latestWalk", "stepGoal", "foodGoalKilocalories", "accentPreference"
        ]))
        XCTAssertEqual(try decode(DailyWidgetSnapshot.self, json), value)
    }

    func testDefaultActivityPayloadKeepsExistingKeysAndAttributeIdentity() throws {
        let projection = WorkoutActivityProjector.project(workoutSnapshot(), at: now, accent: .pink)
        XCTAssertNil(projection.state.designThemeIdentifier)
        XCTAssertEqual(projection.state.displayTheme, .core)
        XCTAssertEqual(Set(try object(projection.state).keys), Set([
            "exerciseName", "currentSet", "plannedSetsForExercise", "completedSets",
            "totalSets", "phase", "restEndsAt", "accentPreference", "restTotalSeconds"
        ]))
        let attributes = WorkoutActivityAttributes(sessionID: projection.sessionID,
            workoutTitle: projection.workoutTitle)
        XCTAssertEqual(Set(try object(attributes).keys), Set(["sessionID", "workoutTitle"]))
        let decoded = try decode(WorkoutActivityAttributes.self, object(attributes))
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.workoutTitle, projection.workoutTitle)
    }

    func testDailyAbsentNullAndMalformedThemeMetadataKeepAllFacts() throws {
        let base = dailyInputs().snapshot(at: now, calendar: calendar)
        let legacy = try object(base)
        XCTAssertEqual(try decode(DailyWidgetSnapshot.self, legacy), base)
        for raw in malformedMetadata {
            var json = legacy
            json["designThemeIdentifier"] = raw
            let decoded = try decode(DailyWidgetSnapshot.self, json)
            XCTAssertEqual(decoded, base, "Theme tolerance must not replace recorded facts.")
            XCTAssertNil(decoded.designThemeIdentifier)
            XCTAssertEqual(decoded.displayTheme, .core)
            XCTAssertTrue(decoded.isValid)
            XCTAssertFalse(try object(decoded).keys.contains("designThemeIdentifier"))
        }
    }

    func testActivityAbsentNullAndMalformedThemeMetadataKeepAllFacts() throws {
        let base = activityProjection().state
        let legacy = try object(base)
        XCTAssertEqual(try decode(WorkoutActivityAttributes.ContentState.self, legacy), base)
        for raw in malformedMetadata {
            var json = legacy
            json["designThemeIdentifier"] = raw
            let decoded = try decode(WorkoutActivityAttributes.ContentState.self, json)
            XCTAssertEqual(decoded, base)
            XCTAssertNil(decoded.designThemeIdentifier)
            XCTAssertEqual(decoded.displayTheme, .core)
            XCTAssertFalse(try object(decoded).keys.contains("designThemeIdentifier"))
        }
    }

    func testUnknownRawThemeRoundTripsWithoutLosingFactsOrForwardMetadata() throws {
        let unknown = "future-display-theme"
        let daily = dailyInputs().snapshot(at: now, calendar: calendar)
        var dailyJSON = try object(daily)
        dailyJSON["designThemeIdentifier"] = unknown
        let decodedDaily = try decode(DailyWidgetSnapshot.self, dailyJSON)
        XCTAssertEqual(decodedDaily.displayTheme, .core)
        XCTAssertEqual(decodedDaily.designThemeIdentifier, unknown)
        XCTAssertEqual(try object(decodedDaily)["designThemeIdentifier"] as? String, unknown)
        XCTAssertEqual(try decode(DailyWidgetSnapshot.self, object(decodedDaily)), decodedDaily)
        var expectedDaily = daily
        expectedDaily.designThemeIdentifier = unknown
        XCTAssertEqual(decodedDaily, expectedDaily)

        let activity = activityProjection().state
        var activityJSON = try object(activity)
        activityJSON["designThemeIdentifier"] = unknown
        let decodedActivity = try decode(WorkoutActivityAttributes.ContentState.self, activityJSON)
        XCTAssertEqual(decodedActivity.displayTheme, .core)
        XCTAssertEqual(decodedActivity.designThemeIdentifier, unknown)
        XCTAssertEqual(try object(decodedActivity)["designThemeIdentifier"] as? String, unknown)
        XCTAssertEqual(try decode(WorkoutActivityAttributes.ContentState.self,
            object(decodedActivity)), decodedActivity)
        var expectedActivity = activity
        expectedActivity.designThemeIdentifier = unknown
        XCTAssertEqual(decodedActivity, expectedActivity)
    }

    func testThemeToleranceDoesNotRelaxDailyFactDecoding() throws {
        let legacy = try object(dailyInputs().snapshot(at: now, calendar: calendar))
        let invalidFacts: [(String, Any)] = [
            ("version", "one"), ("generatedAt", "not-a-date"), ("steps", "not-a-metric"),
            ("waterGoalMilliliters", [1]), ("accentPreference", 9)
        ]
        for (key, raw) in invalidFacts {
            var json = legacy
            json[key] = raw
            json["designThemeIdentifier"] = ["wrong": "type"]
            XCTAssertThrowsError(try decode(DailyWidgetSnapshot.self, json), key)
        }
        var missing = legacy
        missing.removeValue(forKey: "dayStart")
        missing["designThemeIdentifier"] = NSNull()
        XCTAssertThrowsError(try decode(DailyWidgetSnapshot.self, missing))
    }

    func testThemeToleranceDoesNotRelaxActivityFactDecoding() throws {
        let legacy = try object(activityProjection().state)
        let invalidFacts: [(String, Any)] = [
            ("currentSet", "two"), ("phase", "future-phase"), ("restEndsAt", ["bad": 1]),
            ("pausedRestSeconds", [40]), ("accentPreference", false)
        ]
        for (key, raw) in invalidFacts {
            var json = legacy
            json[key] = raw
            json["designThemeIdentifier"] = 7
            XCTAssertThrowsError(try decode(WorkoutActivityAttributes.ContentState.self, json), key)
        }
        var missing = legacy
        missing.removeValue(forKey: "exerciseName")
        missing["designThemeIdentifier"] = NSNull()
        XCTAssertThrowsError(try decode(WorkoutActivityAttributes.ContentState.self, missing))
    }

    func testAllThemesComposeAfterDailyProjectionAndSurviveCodecWithUnchangedFacts() throws {
        let originalInputs = dailyInputs()
        let base = originalInputs.snapshot(at: now, calendar: calendar)
        XCTAssertTrue(base.isValid)
        XCTAssertEqual(base.steps.value, 1_234)
        XCTAssertEqual(base.steps.asOf, now.addingTimeInterval(-30))
        XCTAssertEqual(base.eatenKilocalories.value, 800)
        XCTAssertEqual(base.burnedKilocalories.value, 350)
        XCTAssertTrue(base.burnedKilocalories.isStale)
        XCTAssertEqual(base.waterMilliliters.value, 750)
        XCTAssertEqual(base.latestWalk?.usesMiles, true)
        for theme in ZOTheme.allCases {
            var inputs = originalInputs
            inputs.designTheme = theme
            XCTAssertNotEqual(inputs, originalInputs, "The existing equality observer must see metadata changes.")
            let projected = inputs.snapshot(at: now, calendar: calendar)
            XCTAssertEqual(projected, base.usingDesignTheme(theme))
            XCTAssertEqual(projected.displayTheme, theme)
            let decoded = try decode(DailyWidgetSnapshot.self, object(projected))
            XCTAssertEqual(decoded, projected)
            var facts = decoded
            facts.designThemeIdentifier = nil
            XCTAssertEqual(facts, base, "Only presentation metadata may change.")
        }
        XCTAssertNil(originalInputs.designTheme)
        XCTAssertNil(base.designThemeIdentifier)
    }

    func testAllThemesPreserveWorkoutPhaseCountdownPausedAndSessionFacts() throws {
        let projections = [
            activityProjection(),
            WorkoutActivityProjector.project(workoutSnapshot(isPaused: true), at: now, accent: .pink, language: .english),
            WorkoutActivityProjector.project(workoutSnapshot(), at: now.addingTimeInterval(61), accent: .pink, language: .english),
            WorkoutActivityProjector.project(workoutSnapshot(), phase: .saving, at: now, accent: .pink, language: .english)
        ]
        XCTAssertEqual(projections.map { $0.state.phase }, [.rest, .paused, .awaitingNextSet, .saving])
        XCTAssertEqual(projections[0].staleDate, now.addingTimeInterval(60))
        XCTAssertEqual(projections[1].state.pausedRestSeconds, 40)
        XCTAssertNil(projections[1].staleDate)
        for base in projections {
            for theme in ZOTheme.allCases {
                let themed = base.usingDesignTheme(theme)
                XCTAssertEqual(themed.sessionID, sessionID)
                XCTAssertEqual(themed.workoutTitle, base.workoutTitle)
                XCTAssertEqual(themed.staleDate, base.staleDate)
                XCTAssertEqual(themed.state.displayTheme, theme)
                let decoded = try decode(WorkoutActivityAttributes.ContentState.self, object(themed.state))
                XCTAssertEqual(decoded, themed.state)
                var facts = decoded
                facts.designThemeIdentifier = base.state.designThemeIdentifier
                XCTAssertEqual(facts, base.state)
                XCTAssertEqual(base.state.designThemeIdentifier, nil)
            }
        }
    }

    func testThemeOnlyChangeUpdatesSameActivityThenBecomesUnchanged() {
        let base = activityProjection()
        var states = Set<WorkoutActivityAttributes.ContentState>()
        for theme in ZOTheme.allCases {
            let themed = base.usingDesignTheme(theme)
            states.insert(themed.state)
            XCTAssertEqual(WorkoutActivityDecision.decide(desired: themed,
                existingSessionID: base.sessionID, existingState: base.state), .update)
            XCTAssertEqual(WorkoutActivityDecision.decide(desired: themed,
                existingSessionID: themed.sessionID, existingState: themed.state), .unchanged)
            XCTAssertEqual(WorkoutActivityDecision.decide(desired: themed,
                existingSessionID: nil, existingState: nil), .request)
        }
        XCTAssertEqual(states.count, 4, "Hashable state must retain distinct transported identifiers.")
        XCTAssertEqual(WorkoutActivityDecision.decide(desired: nil,
            existingSessionID: base.sessionID, existingState: base.state), .endAll)
    }

    func testThemeOnlyPublishingVerifiesFreshFileReadReloadsOnceAndIsIdempotent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDailyWidgetSnapshotStore(directory: directory)
        var reloads = 0
        let publisher = DailyWidgetPublisher(store: store, reload: { reloads += 1 })
        let base = dailyInputs().snapshot(at: now, calendar: calendar)
        XCTAssertTrue(publisher.publish(base))
        XCTAssertEqual(reloads, 1)
        for (index, theme) in ZOTheme.allCases.enumerated() {
            let themed = base.usingDesignTheme(theme)
            XCTAssertTrue(publisher.publish(themed))
            XCTAssertNil(publisher.lastError)
            XCTAssertEqual(try FileDailyWidgetSnapshotStore(directory: directory).load(), themed)
            XCTAssertEqual(reloads, index + 2)
            XCTAssertTrue(publisher.publish(themed))
            XCTAssertEqual(reloads, index + 2)
            var facts = try XCTUnwrap(store.load())
            facts.designThemeIdentifier = nil
            XCTAssertEqual(facts, base)
        }
    }

    func testPublisherFailsClosedWithoutContainerOrOnRealFilesystemWriteFailure() throws {
        let value = dailyInputs().snapshot(at: now, calendar: calendar).usingDesignTheme(.freak)
        var reloads = 0
        let unavailable = FileDailyWidgetSnapshotStore(directory: nil)
        let unavailablePublisher = DailyWidgetPublisher(store: unavailable, reload: { reloads += 1 })
        XCTAssertFalse(unavailablePublisher.publish(value))
        XCTAssertNotNil(unavailablePublisher.lastError)
        XCTAssertThrowsError(try unavailable.load())
        XCTAssertEqual(reloads, 0)

        let blockedDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data("occupied by a file".utf8).write(to: blockedDirectory)
        let publisher = DailyWidgetPublisher(store: FileDailyWidgetSnapshotStore(directory: blockedDirectory),
            reload: { reloads += 1 })
        XCTAssertFalse(publisher.publish(value))
        XCTAssertNotNil(publisher.lastError)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(try Data(contentsOf: blockedDirectory), Data("occupied by a file".utf8))
    }

    func testThemeMetadataCannotMakeInvalidSchemaOrFactsAcceptableToFileStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileDailyWidgetSnapshotStore(directory: directory)
        let baseline = try object(dailyInputs().snapshot(at: now, calendar: calendar))
        var future = baseline
        future["version"] = 999
        var negative = baseline
        var metric = try XCTUnwrap(negative["waterMilliliters"] as? [String: Any])
        metric["value"] = -1
        negative["waterMilliliters"] = metric
        for var json in [future, negative] {
            json["designThemeIdentifier"] = "princess"
            let decoded = try decode(DailyWidgetSnapshot.self, json)
            XCTAssertEqual(decoded.displayTheme, .princess)
            XCTAssertFalse(decoded.isValid)
            XCTAssertThrowsError(try store.save(decoded))
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("daily.json"))
            XCTAssertThrowsError(try store.load())
        }
    }

    private var malformedMetadata: [Any] { [NSNull(), 7, true, ["retro"], ["theme": "retro"]] }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WidgetThemeTransport-" + UUID().uuidString)
    }

    private func dailyInputs() -> DailyWidgetInputs {
        let day = calendar.startOfDay(for: now)
        return DailyWidgetInputs(
            steps: StepsDayReading(readAt: now.addingTimeInterval(-30), dayStart: day,
                totalSteps: 1_234, distanceMeters: 900, hours: []),
            stepsStatus: .connected, stepsFailed: false,
            health: HealthContext(todaySteps: 1_000, todayActiveEnergyKilocalories: 350,
                mostRecentWorkout: nil, lastNightSleepDurationSeconds: nil,
                refreshedAt: now.addingTimeInterval(-60), dayStart: day),
            healthStatus: .connected, healthIsStale: true,
            meals: [NutritionEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                title: "Recorded meal", calories: 800, proteinGrams: nil, carbohydrateGrams: nil,
                fatGrams: nil, loggedAt: now.addingTimeInterval(-90))],
            nutritionAvailable: true, water: HydrationState(currentMilliliters: 750),
            waterDayStart: day, hydrationAvailable: true,
            latestWalk: DailyWidgetSnapshot.Walk(finishedAt: now.addingTimeInterval(-120),
                activeSeconds: 900, distanceMeters: 1_609.344, distanceIncomplete: true).usingMiles(true),
            goals: DailyGoals(steps: 8_000, foodKilocalories: 2_000), accent: .pink, language: .english)
    }

    private func workoutSnapshot(isPaused: Bool = false) -> ActiveWorkoutSnapshot {
        let plan = ExercisePlan(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            exerciseID: ExerciseIDs.barbellBenchPress, name: "Barbell Bench Press",
            targetLoad: Load(80), targetReps: RepRange(6, 8), plannedSetCount: 3,
            restSeconds: 90, previousPerformance: [])
        let recordedSet = CompletedSet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            load: Load(80), reps: 8, rir: 2, completedAt: now.addingTimeInterval(-30))
        let session = WorkoutSession(id: sessionID, title: "Recorded strength session",
            exercises: [WorkoutExercise(plan: plan, completedSets: [recordedSet])],
            restEndsAt: now.addingTimeInterval(60), activeRestDuration: 90)
        return ActiveWorkoutSnapshot(session: session, enteredLoadValue: 80, enteredReps: 8,
            enteredRIR: 2, isPaused: isPaused, pausedRemainingRestSeconds: isPaused ? 40 : nil,
            pendingAdaptation: nil, sessionBeforeAdaptation: nil, lastSetGuidance: nil)
    }

    private func activityProjection() -> WorkoutActivityProjection {
        WorkoutActivityProjector.project(workoutSnapshot(), at: now, accent: .pink, language: .english)
    }
}
