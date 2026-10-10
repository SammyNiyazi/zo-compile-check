import Foundation
import XCTest
@testable import ZeroOne

final class OutdoorRouteTests: XCTestCase {
    private let policy = OutdoorRouteAcceptancePolicy(
        maximumHorizontalAccuracyMeters: 35,
        maximumGapSeconds: 30,
        maximumPlausibleSpeedMetersPerSecond: 15,
        maximumFutureSeconds: 5
    )

    func testDistanceUsesOnlyAcceptedPointsWithinOneSegment() {
        let start = Date(timeIntervalSince1970: 1_000)
        var route = OutdoorRouteAccumulator()

        XCTAssertEqual(route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy), .startedSegment)
        XCTAssertNil(route.recordedDistanceMeters)

        let next = start.addingTimeInterval(20)
        let outcome = route.ingest(fix(0, 0.001, at: next), receivedAt: next, policy: policy)
        guard case let .extendedSegment(meters) = outcome else {
            return XCTFail("Second usable point should extend the segment")
        }
        XCTAssertGreaterThan(meters, 100)
        XCTAssertLessThan(meters, 120)
        XCTAssertEqual(route.segments.count, 1)
        XCTAssertEqual(route.recordedDistanceMeters, meters)
        XCTAssertFalse(route.hasMissingLocationCoverage)
    }

    func testUserPauseStartsANewSegmentWithoutConnectingDistance() {
        let start = Date(timeIntervalSince1970: 2_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)
        route.ingest(fix(0, 0.001, at: start.addingTimeInterval(20)),
                     receivedAt: start.addingTimeInterval(20), policy: policy)
        let beforePause = route.recordedDistanceMeters

        route.breakForUserPause()
        let resume = start.addingTimeInterval(200)
        XCTAssertEqual(
            route.ingest(fix(0, 0.01, at: resume), receivedAt: resume, policy: policy),
            .startedSegment
        )

        XCTAssertEqual(route.segments.count, 2)
        XCTAssertEqual(route.recordedDistanceMeters, beforePause)
        XCTAssertFalse(route.hasMissingLocationCoverage)
    }

    func testGPSGapSplitsLineAndMarksDistanceIncomplete() {
        let start = Date(timeIntervalSince1970: 3_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)
        let later = start.addingTimeInterval(90)

        XCTAssertEqual(route.ingest(fix(0, 0.002, at: later), receivedAt: later, policy: policy), .startedSegment)
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertNil(route.recordedDistanceMeters)
        XCTAssertTrue(route.hasMissingLocationCoverage)
    }

    func testReportedSignalLossStartsTheNextFixInANewSegment() {
        let start = Date(timeIntervalSince1970: 3_500)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)
        route.noteLocationGap()

        let returnTime = start.addingTimeInterval(10)
        XCTAssertEqual(
            route.ingest(fix(0, 0.001, at: returnTime), receivedAt: returnTime, policy: policy),
            .startedSegment
        )
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertNil(route.recordedDistanceMeters)
        XCTAssertTrue(route.hasMissingLocationCoverage)
    }

    func testBadAccuracyAndImplausibleJumpNeverAddDistance() {
        let start = Date(timeIntervalSince1970: 4_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)

        let inaccurateTime = start.addingTimeInterval(5)
        XCTAssertEqual(
            route.ingest(fix(0, 0.001, at: inaccurateTime, accuracy: -1),
                         receivedAt: inaccurateTime, policy: policy),
            .rejected(.invalidAccuracy)
        )
        let restart = start.addingTimeInterval(10)
        XCTAssertEqual(route.ingest(fix(0, 0.001, at: restart), receivedAt: restart, policy: policy), .startedSegment)

        let jumpTime = restart.addingTimeInterval(1)
        XCTAssertEqual(
            route.ingest(fix(0, 0.1, at: jumpTime), receivedAt: jumpTime, policy: policy),
            .rejected(.implausibleJump)
        )
        XCTAssertNil(route.recordedDistanceMeters)
        XCTAssertTrue(route.hasMissingLocationCoverage)
        XCTAssertEqual(route.segments.count, 2)
    }

    func testDuplicateAndOutOfOrderSamplesDoNotBreakAValidLine() {
        let start = Date(timeIntervalSince1970: 5_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)

        XCTAssertEqual(route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy), .rejected(.outOfOrder))
        XCTAssertEqual(
            route.ingest(fix(0, 0.001, at: start.addingTimeInterval(-1)), receivedAt: start, policy: policy),
            .rejected(.outOfOrder)
        )
        let next = start.addingTimeInterval(20)
        guard case .extendedSegment = route.ingest(fix(0, 0.001, at: next), receivedAt: next, policy: policy) else {
            return XCTFail("Ordered point after duplicate should extend the original segment")
        }
        XCTAssertEqual(route.segments.count, 1)
        XCTAssertFalse(route.hasMissingLocationCoverage)
    }

    func testFutureAndInvalidCoordinatesAreRejected() {
        let start = Date(timeIntervalSince1970: 6_000)
        var route = OutdoorRouteAccumulator()
        XCTAssertEqual(
            route.ingest(fix(91, 0, at: start), receivedAt: start, policy: policy),
            .rejected(.invalidCoordinate)
        )
        XCTAssertEqual(
            route.ingest(fix(0, 0, at: start.addingTimeInterval(10)), receivedAt: start, policy: policy),
            .rejected(.futureSample)
        )
        XCTAssertTrue(route.segments.isEmpty)
    }

    func testRouteCheckpointRoundTripPreservesGapsAndDistance() throws {
        let start = Date(timeIntervalSince1970: 7_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)
        route.ingest(fix(0, 0.001, at: start.addingTimeInterval(20)),
                     receivedAt: start.addingTimeInterval(20), policy: policy)
        route.noteLocationGap()

        let restored = try JSONDecoder().decode(OutdoorRouteAccumulator.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(restored, route)
        XCTAssertTrue(restored.hasMissingLocationCoverage)
    }

    func testPauseEndpointSurvivesCheckpointAndResumeWithoutBridging() throws {
        let start = Date(timeIntervalSince1970: 8_000)
        var route = OutdoorRouteAccumulator()
        route.ingest(fix(0, 0, at: start), receivedAt: start, policy: policy)
        route.ingest(fix(0, 0.001, at: start + 20), receivedAt: start + 20, policy: policy)
        let distance = route.recordedDistanceMeters
        let endpoint = route.segments[0].points.last
        route.breakForUserPause()
        route = try JSONDecoder().decode(OutdoorRouteAccumulator.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(route.segments[0].endsAtUserPause, true)
        XCTAssertEqual(route.segments[0].points.last, endpoint)
        XCTAssertEqual(route.ingest(fix(0, 0.1, at: start + 200), receivedAt: start + 200, policy: policy), .startedSegment)
        XCTAssertEqual(route.recordedDistanceMeters, distance)
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertNil(route.segments[1].endsAtUserPause)
        XCTAssertTrue(route.isInternallyConsistent)
    }

    func testLegacySegmentWithoutPauseMetadataDecodes() throws {
        let segment = OutdoorRouteSegment(firstPoint: fix(0, 0, at: Date(timeIntervalSince1970: 9_000)))
        let data = try JSONEncoder().encode(segment)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "endsAtUserPause")
        let restored = try JSONDecoder().decode(OutdoorRouteSegment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.points, segment.points)
        XCTAssertNil(restored.endsAtUserPause)
    }

    func testPresentationRemovesSmallZigzagsWithoutChangingDistanceOrRawFixes() {
        let start = Date(timeIntervalSince1970: 10_000)
        var route = OutdoorRouteAccumulator()
        for index in 0..<7 {
            let point = fix(index % 2 == 0 ? 0 : 0.00001, Double(index) * 0.0001, at: start + Double(index * 10))
            route.ingest(point, receivedAt: point.timestamp, policy: policy)
        }
        let raw = route.segments[0].points
        let distance = route.recordedDistanceMeters
        let drawn = route.segments[0].presentationPoints
        XCTAssertEqual(drawn, [raw[0], raw[6]])
        XCTAssertEqual(route.segments[0].points, raw)
        XCTAssertEqual(route.recordedDistanceMeters, distance)
        XCTAssertTrue(route.isInternallyConsistent)
    }

    func testPresentationKeepsARealCornerAndGPSGapDoesNotInventPauseMarker() {
        let start = Date(timeIntervalSince1970: 11_000)
        var segment = OutdoorRouteSegment(firstPoint: fix(0, 0, at: start))
        segment.append(fix(0, 0.001, at: start + 20))
        segment.append(fix(0.001, 0.001, at: start + 40))
        XCTAssertEqual(segment.presentationPoints, segment.points)
        var route = OutdoorRouteAccumulator()
        route.ingest(segment.points[0], receivedAt: start, policy: policy)
        route.noteLocationGap()
        XCTAssertNil(route.segments[0].endsAtUserPause)
    }

    private func fix(
        _ latitude: Double,
        _ longitude: Double,
        at timestamp: Date,
        accuracy: Double = 5
    ) -> OutdoorRouteFix {
        OutdoorRouteFix(
            latitude: latitude,
            longitude: longitude,
            timestamp: timestamp,
            horizontalAccuracyMeters: accuracy
        )
    }
}
