import Foundation
import XCTest
@testable import ZeroOne

final class SharePayloadTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 100_000)

    func testPrivacyStartsWithNoRouteOrBodyWeight() {
        let privacy = ZOSharePrivacy()
        XCTAssertFalse(privacy.showRoute)
        XCTAssertTrue(privacy.hideRouteEndpoints)
        XCTAssertFalse(privacy.showBodyWeight)
    }

    func testWorkoutUsesSavedSetsAndNeverPresentsTargetAsElapsedTime() {
        let entry = workout([set(18, reps: 10), set(18, reps: 9)])
        let original = entry
        let payload = ZOSharePayload.make(source: .workout(entry, acknowledgedHistory: [entry]), privacy: .init(), localization: .english)
        XCTAssertEqual(payload.metrics.first(where: { $0.id == "sets" })?.value, "2")
        XCTAssertEqual(payload.metrics.first(where: { $0.id == "volume" })?.value, "342")
        XCTAssertFalse(payload.metrics.contains { $0.id == "time" || $0.label == "min" })
        XCTAssertNil(payload.best)
        XCTAssertEqual(entry, original)
    }

    func testHiddenLoadsLeaveNoVolumeBestOrUnitInAccessibility() {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        var privacy = ZOSharePrivacy(); privacy.showLoads = false
        let payload = ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [before, now]), privacy: privacy, localization: .english)
        XCTAssertNil(payload.best)
        XCTAssertFalse(payload.metrics.contains { $0.id == "volume" })
        XCTAssertFalse(payload.accessibilityDescription(layout: .best, localization: .english).contains("kg"))
    }

    func testUnknownSideTimedAndMixedUnitsDoNotInventVolume() {
        let unknown = CompletedSet(load: Load(18), reps: 10, completedAt: date, isPerSide: nil)
        let timed = CompletedSet(load: Load(18), reps: 0, completedAt: date, durationSeconds: 30, isPerSide: false)
        for sets in [[unknown], [timed], [set(18, reps: 10), set(40, reps: 10, unit: .pounds)]] {
            let payload = ZOSharePayload.make(source: .workout(workout(sets), acknowledgedHistory: []), privacy: .init(), localization: .english)
            XCTAssertFalse(payload.metrics.contains { $0.id == "volume" })
        }
    }

    func testNewBestRequiresKnownPriorSameModeEvidence() throws {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        let source = ZOShareSource.workout(now, acknowledgedHistory: [before, now])
        XCTAssertNotNil(ZOSharePayload.make(source: source, privacy: .init(), localization: .english).best)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        json.removeValue(forKey: "exercises")
        let unknown = try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [unknown, now]), privacy: .init(), localization: .english).best)
    }

    func testTimerOnlyOutdoorKeepsDistancePaceRouteAbsent() {
        let checkpoint = OutdoorActivityCheckpoint(kind: .walk, trackingMode: .timerOnly, startedAt: date,
            checkpointedAt: date + 60, confirmedActiveSeconds: 60, phase: .readyToSave, finishedAt: date + 60)
        let record = OutdoorActivityRecord(checkpoint: checkpoint, finishedAt: date + 60)
        let payload = ZOSharePayload.make(source: .outdoor(record), privacy: .init(), localization: .english)
        XCTAssertTrue(payload.isOutdoor)
        XCTAssertNil(payload.distance)
        XCTAssertTrue(payload.route.isEmpty)
        XCTAssertFalse(payload.metrics.contains { $0.id == "pace" || $0.id == "steps" })
        XCTAssertEqual(payload.metrics.first(where: { $0.id == "time" })?.value, "1:00")
    }

    func testActualOutdoorRouteExcludedUntilExplicitOptIn() {
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 35, maximumGapSeconds: 30, maximumPlausibleSpeedMetersPerSecond: 15, maximumFutureSeconds: 5)
        for index in 0...10 {
            let point = fix(index)
            _ = route.ingest(point, receivedAt: point.timestamp, policy: policy)
        }
        let checkpoint = OutdoorActivityCheckpoint(kind: .run, startedAt: date, checkpointedAt: date + 100,
            confirmedActiveSeconds: 100, phase: .readyToSave, finishedAt: date + 100, route: route)
        let record = OutdoorActivityRecord(checkpoint: checkpoint, finishedAt: date + 100)
        let hidden = ZOSharePayload.make(source: .outdoor(record), privacy: .init(), localization: .english)
        XCTAssertTrue(hidden.route.isEmpty)
        XCTAssertFalse(hidden.accessibilityDescription(layout: .stats, localization: .english).contains("Route"))
        var privacy = ZOSharePrivacy(); privacy.showRoute = true
        let shown = ZOSharePayload.make(source: .outdoor(record), privacy: privacy, localization: .english)
        XCTAssertFalse(shown.route.isEmpty)
        XCTAssertFalse(shown.showsEndpoints)
        XCTAssertEqual(record.route, route)
    }

    func testEndpointTrimmingRemovesFixesBeforeProjection() {
        let points = (0...10).map(fix)
        let full = segment(points)
        let expected = ZOShareRoute.project([segment(Array(points[2...8]))], trimEndpoints: false)
        XCTAssertEqual(ZOShareRoute.project([full], trimEndpoints: true), expected)
        XCTAssertTrue(ZOShareRoute.project([segment(Array(points[0...3]))], trimEndpoints: true).isEmpty)
    }

    func testGpsGapsStaySeparateAndNormalizedPointsNeverContainCoordinates() {
        let routes = ZOShareRoute.project([segment((0...4).map(fix)), segment((7...10).map(fix))], trimEndpoints: false)
        XCTAssertEqual(routes.count, 2)
        XCTAssertTrue(routes.flatMap { $0 }.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    func testRecapUsesCalendarWindowAndOmittedPrivateFacts() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = date
        let early = workout([set(12, reps: 10)], at: start - 1)
        let included = workout([set(18, reps: 10)], at: start + 60)
        let excluded = workout([set(24, reps: 10)], at: start + 14 * 86400)
        let facts = try XCTUnwrap(ZOShareRecapFacts(start: start, acknowledgedHistory: [early, included, excluded], calendar: calendar,
            nameAndNumber: "Private name · No. 0127", bodyWeightChange: Load(-0.8)))
        var privacy = ZOSharePrivacy(); privacy.showName = false
        let payload = ZOSharePayload.make(source: .first14Days(facts), privacy: privacy, localization: .english)
        XCTAssertEqual(facts.workouts, 1); XCTAssertEqual(facts.sets, 1)
        XCTAssertEqual(facts.trainingDays.filter(\.trained).count, 1)
        XCTAssertEqual(payload.trainingDays.count, 14)
        XCTAssertNil(payload.nameAndNumber); XCTAssertNil(payload.bodyWeightChange)
        XCTAssertFalse(payload.accessibilityDescription(layout: .recap, localization: .english).contains("Private"))
        XCTAssertEqual(payload.metrics.first(where: { $0.id == "bests" })?.value, "1")
        privacy.showBodyWeight = true
        XCTAssertNotNil(ZOSharePayload.make(source: .first14Days(facts), privacy: privacy, localization: .english).bodyWeightChange)
    }

    func testRecapRejectsDuplicateSavedIDsAndEmptyActualWindow() {
        let entry = workout([set(18, reps: 10)])
        XCTAssertNil(ZOShareRecapFacts(start: date, acknowledgedHistory: [entry, entry], calendar: .current))
        XCTAssertNil(ZOShareRecapFacts(start: date + 10, acknowledgedHistory: [entry], calendar: .current))
    }

    func testNewerIncomparableOccurrencesNeverFallBackToOlderBestEvidence() {
        let before = workout([set(12, reps: 10)], at: date - 200)
        let now = workout([set(18, reps: 10)])
        let unknown = CompletedSet(load: Load(14), reps: 10, completedAt: date, isPerSide: nil)
        let perSide = CompletedSet(load: Load(14), reps: 10, completedAt: date, isPerSide: true)
        let timed = CompletedSet(load: Load(14), reps: 0, completedAt: date, durationSeconds: 30, isPerSide: false)
        for sets in [[set(14, reps: 9)], [set(14, reps: 10, unit: .pounds)], [unknown], [perSide], [timed]] {
            let newer = workout(sets, at: date - 100)
            let payload = ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [before, newer, now]), privacy: .init(), localization: .english)
            XCTAssertNil(payload.best)
        }
    }

    func testHeavierLoadAtFewerRepsCannotBecomeBestAgainstHigherRepHistory() {
        let before = workout([set(12, reps: 12)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        XCTAssertNil(ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [before, now]), privacy: .init(), localization: .english).best)
    }

    func testCrossedPriorLoadAndRepsCannotBecomeBestViaDominanceFiltering() {
        let before = workout([set(30, reps: 6), set(12, reps: 10)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        XCTAssertNil(ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [before, now]), privacy: .init(), localization: .english).best)
    }

    func testBestUsesHeaviestComparableSetAndRejectsEqualOrLowerLoad() {
        let before = workout([set(12, reps: 10), set(20, reps: 10)], at: date - 100)
        for load in [18.0, 20.0] {
            let now = workout([set(load, reps: 10)])
            XCTAssertNil(ZOSharePayload.make(source: .workout(now, acknowledgedHistory: [before, now]), privacy: .init(), localization: .english).best)
        }
        let now = workout([set(22, reps: 10), set(24, reps: 10)])
        XCTAssertEqual(ZOShareBestEvidence.evaluate(entry: now, history: [before, now])?.first?.set.load.value, 24)
    }

    func testBestRejectsDuplicateHistoryAndSimultaneousOrConflictingRecords() throws {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        let simultaneous = workout([set(12, reps: 10)])
        for history in [[before, before, now], [before, simultaneous, now]] {
            XCTAssertNil(ZOShareBestEvidence.evaluate(entry: now, history: history))
        }
        let conflict = try replacing(now, key: "title", with: "Different saved source")
        XCTAssertNil(ZOShareBestEvidence.evaluate(entry: now, history: [before, conflict]))
        XCTAssertNil(ZOShareBestEvidence.evaluate(entry: now, history: [before]))
    }

    func testReusedPerformedSetIdentityCannotEstablishBestOrRecapCounts() {
        let shared = set(18, reps: 10)
        let before = workout([shared], at: date - 100)
        let now = workout([shared])
        XCTAssertNil(ZOShareBestEvidence.evaluate(entry: now, history: [before, now]))
        XCTAssertNil(ZOShareRecapFacts(start: date - 100, acknowledgedHistory: [before, now], calendar: .current))
    }

    func testRecapBestCountRequiresComparableHistoryBeforeWindowAndHidesWithLoads() throws {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let first = workout([set(18, reps: 10)], at: date + 10)
        let second = workout([set(20, reps: 10)], at: date + 100)
        let supported = try XCTUnwrap(ZOShareRecapFacts(start: date, acknowledgedHistory: [before, first, second], calendar: .current))
        XCTAssertEqual(supported.priorBestCount, 2)
        let withoutBaseline = try XCTUnwrap(ZOShareRecapFacts(start: date, acknowledgedHistory: [first, second], calendar: .current))
        XCTAssertNil(withoutBaseline.priorBestCount)
        var privacy = ZOSharePrivacy(); privacy.showLoads = false
        let hidden = ZOSharePayload.make(source: .first14Days(supported), privacy: privacy, localization: .english)
        XCTAssertFalse(hidden.metrics.contains { $0.id == "bests" })
        XCTAssertTrue(hidden.lifts.isEmpty)
    }

    func testRecapUnknownNewestAndIntermediateModeChangesBarCountsAndLiftComparisons() throws {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let first = workout([set(18, reps: 10)], at: date + 10)
        let changed = workout([set(19, reps: 10, unit: .pounds)], at: date + 50)
        let last = workout([set(20, reps: 10)], at: date + 100)
        let facts = try XCTUnwrap(ZOShareRecapFacts(start: date, acknowledgedHistory: [before, first, changed, last], calendar: .current))
        XCTAssertNil(facts.priorBestCount)
        XCTAssertTrue(facts.lifts.isEmpty)
    }

    func testRecapSavedPoundsAndOptInWeightKeepTheirUnitLabels() throws {
        let first = workout([set(18, reps: 10, unit: .pounds)], at: date + 10)
        let last = workout([set(20, reps: 10, unit: .pounds)], at: date + 100)
        let facts = try XCTUnwrap(ZOShareRecapFacts(start: date, acknowledgedHistory: [first, last], calendar: .current, bodyWeightChange: Load(-2, unit: .pounds)))
        var privacy = ZOSharePrivacy(); privacy.showBodyWeight = true
        let payload = ZOSharePayload.make(source: .first14Days(facts), privacy: privacy, localization: .english)
        XCTAssertEqual(payload.lifts.first?.values, "18 → 20 lb")
        XCTAssertEqual(payload.bodyWeightChange, "-2 lb")
        XCTAssertTrue(payload.lifts.allSatisfy { $0.startFraction.isFinite && $0.currentFraction.isFinite })
    }

    func testClockRoundsAtSecondBoundaryAndRejectsNonrepresentableValues() {
        XCTAssertEqual(ZOSharePayload.clock(59.5), "1:00")
        XCTAssertEqual(ZOSharePayload.clock(3599.5), "1:00:00")
        XCTAssertEqual(ZOSharePayload.clock(0.5), "0:01")
        for seconds in [0, -1, 0.1, .nan, .infinity, Double(Int.max), Double.greatestFiniteMagnitude] {
            XCTAssertNil(ZOSharePayload.clock(seconds))
        }
        XCTAssertNotNil(ZOSharePayload.clock(Double(Int.max).nextDown))
    }

    func testRecapAndBestRejectInconsistentCountsAndFutureSetTimestamps() throws {
        let before = workout([set(12, reps: 10)], at: date - 100)
        let now = workout([set(18, reps: 10)])
        let mismatch = try replacing(now, key: "completedSetCount", with: 2)
        XCTAssertNil(ZOShareRecapFacts(start: date, acknowledgedHistory: [mismatch], calendar: .current))
        XCTAssertNil(ZOShareBestEvidence.evaluate(entry: mismatch, history: [before, mismatch]))
        let future = try replacing(now, key: "completedAt", with: date.timeIntervalSinceReferenceDate - 10)
        XCTAssertNil(ZOShareBestEvidence.evaluate(entry: future, history: [before, future]))
    }

    private func replacing(_ entry: WorkoutHistoryEntry, key: String, with value: Any) throws -> WorkoutHistoryEntry {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json[key] = value
        return try JSONDecoder().decode(WorkoutHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func set(_ load: Double, reps: Int, unit: LoadUnit = .kilograms) -> CompletedSet {
        CompletedSet(load: Load(load, unit: unit), reps: reps, completedAt: date, isPerSide: false)
    }
    private func workout(_ sets: [CompletedSet], at completedAt: Date? = nil) -> WorkoutHistoryEntry {
        let savedAt = completedAt ?? date
        let savedSets = sets.map { CompletedSet(id: $0.id, load: $0.load, reps: $0.reps, rir: $0.rir, completedAt: savedAt,
            durationSeconds: $0.durationSeconds, isPerSide: $0.isPerSide, executionTarget: $0.executionTarget) }
        let plan = ExercisePlan(name: "Goblet squat", targetLoad: Load(18), targetReps: RepRange(8, 12),
            plannedSetCount: max(1, sets.count), restSeconds: 60, previousPerformance: [])
        return WorkoutHistoryEntry(session: WorkoutSession(title: "Actual saved session", targetDurationMinutes: 45,
            exercises: [WorkoutExercise(plan: plan, completedSets: savedSets)], completedAt: savedAt))
    }
    private func fix(_ index: Int) -> OutdoorRouteFix {
        OutdoorRouteFix(latitude: 0.001 * Double(index), longitude: 0.0001 * Double(index % 2),
            timestamp: date + Double(index * 10), horizontalAccuracyMeters: 5)
    }
    private func segment(_ points: [OutdoorRouteFix]) -> OutdoorRouteSegment {
        var value = OutdoorRouteSegment(firstPoint: points[0]); for point in points.dropFirst() { value.append(point) }; return value
    }
}
