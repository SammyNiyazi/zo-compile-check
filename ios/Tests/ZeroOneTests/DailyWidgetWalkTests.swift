import Foundation
import XCTest
@testable import ZeroOne

final class DailyWidgetWalkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testLatestWalkChoosesSavedWalkNotNewerRunOrFutureRecord() {
        let older = record(.walk, finishedAt: now.addingTimeInterval(-100))
        let latest = record(.walk, finishedAt: now.addingTimeInterval(-50))
        let run = record(.run, finishedAt: now)
        let future = record(.walk, finishedAt: now.addingTimeInterval(100))
        XCTAssertEqual(DailyWidgetProjection.latestSavedWalk(from: [run, older, future, latest], at: now)?.finishedAt, latest.finishedAt)
        XCTAssertNil(DailyWidgetProjection.latestSavedWalk(from: [run, future], at: now))
    }

    func testRemovingWalkSelectsPreviousAndDeletingRouteKeepsTotals() {
        let previous = record(.walk, finishedAt: now.addingTimeInterval(-100))
        var latest = record(.walk, finishedAt: now)
        let before = DailyWidgetProjection.latestSavedWalk(from: [previous, latest], at: now)
        latest.route = nil
        latest.routeDeletedAt = now
        XCTAssertEqual(DailyWidgetProjection.latestSavedWalk(from: [previous, latest], at: now), before)
        XCTAssertEqual(DailyWidgetProjection.latestSavedWalk(from: [previous], at: now)?.finishedAt, previous.finishedAt)
        XCTAssertNil(DailyWidgetProjection.latestSavedWalk(from: [], at: now))
    }

    func testTotalsPayloadHasNoRecordIdentityLocationOrGeometry() throws {
        let walk = DailyWidgetSnapshot.Walk(finishedAt: now, activeSeconds: 900, distanceMeters: 1_500, distanceIncomplete: true)
        let data = try JSONEncoder().encode(walk)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["finishedAt", "activeSeconds", "distanceMeters", "distanceIncomplete", "usesMiles"])
        XCTAssertEqual(try JSONDecoder().decode(DailyWidgetSnapshot.Walk.self, from: data), walk)
        XCTAssertTrue(walk.isValid(at: now))
        XCTAssertFalse(walk.isValid(at: now.addingTimeInterval(-1)))
    }

    func testDistanceUsesPreferredUnitAndMissingIsNeverZero() {
        let walk = DailyWidgetSnapshot.Walk(finishedAt: now, activeSeconds: 3_900, distanceMeters: 1_609.344, distanceIncomplete: true)
        XCTAssertEqual(walk.durationText, "1 h 5 min")
        XCTAssertTrue(walk.distanceText.hasSuffix("km"))
        XCTAssertEqual(walk.usingMiles(true).distanceText, "\(1.0.formatted(.number.precision(.fractionLength(0 ... 2)))) mi")
        let noGPS = DailyWidgetSnapshot.Walk(finishedAt: now, activeSeconds: 30, distanceMeters: nil, distanceIncomplete: true)
        XCTAssertEqual(noGPS.distanceText, "Distance unavailable")
        XCTAssertEqual(noGPS.durationText, "Under 1 min")
    }

    func testWaterOverlayKeepsLatestWalkAndLegacySnapshotDecodes() throws {
        let walk = DailyWidgetProjection.latestSavedWalk(from: [record(.walk, finishedAt: now)], at: now)
        let start = Calendar.current.startOfDay(for: now)
        let base = DailyWidgetSnapshot(generatedAt: now, dayStart: start, steps: .missing(.needsConnection),
            eatenKilocalories: .reading(0, at: now), burnedKilocalories: .missing(.needsConnection),
            waterMilliliters: .reading(500, at: now), waterGoalMilliliters: 2_500, latestWalk: walk)
        let transaction = HydrationTransactionState(state: .init(date: now, currentMilliliters: 750, goalMilliliters: 2_500, dayStart: start))
        let water = try XCTUnwrap(DailyWidgetWaterState(transaction: transaction, at: now))
        XCTAssertEqual(water.displaySnapshot(base: base, at: now).latestWalk, walk)
        XCTAssertEqual(DailyWidgetWaterState.unavailableSnapshot(base: base, at: now).latestWalk, walk)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json.removeValue(forKey: "latestWalk")
        let legacy = try JSONDecoder().decode(DailyWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.latestWalk)
        XCTAssertTrue(legacy.isValid)
    }

    private func record(_ kind: OutdoorActivityKind, finishedAt: Date) -> OutdoorActivityRecord {
        let checkpoint = OutdoorActivityCheckpoint(kind: kind, trackingMode: .timerOnly,
            startedAt: finishedAt.addingTimeInterval(-900), checkpointedAt: finishedAt,
            confirmedActiveSeconds: 900, phase: .readyToSave, finishedAt: finishedAt)
        return OutdoorActivityRecord(checkpoint: checkpoint, finishedAt: finishedAt)
    }
}
