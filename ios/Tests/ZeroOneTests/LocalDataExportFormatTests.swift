import Foundation
import XCTest
@testable import ZeroOne

final class LocalDataExportFormatTests: XCTestCase {
    func testCSVQuotesFormulaTextAndRetainsExactSnapshot() throws {
        let title = "=SUM(1,2)\n\"hello\""
        let meal = NutritionEntry(id: UUID(), title: title, calories: 420,
            proteinGrams: 0, carbohydrateGrams: nil, fatGrams: nil,
            loggedAt: Date(timeIntervalSinceReferenceDate: 1234.125))
        let data = try snapshot(selection: .init(workouts: false, outdoorActivities: false, goalsAndPreferences: false), meals: [meal])
        let files = try LocalDataExportFiles.make(from: data)
        XCTAssertEqual(Set(files.keys), ["snapshot.json", "meals.csv", "water.csv", "README.txt"])
        XCTAssertEqual(files["snapshot.json"], data)
        let csv = String(decoding: try XCTUnwrap(files["meals.csv"]), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\n\"\"hello\"\"\""))
        XCTAssertTrue(csv.contains("2001-01-01T00:20:34.125Z"))
        XCTAssertTrue(csv.contains("\"0\""))
        XCTAssertTrue(csv.contains("\"fatGrams\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        let decoded = try JSONDecoder().decode(LocalDataExportPackage.self, from: data)
        XCTAssertEqual(decoded.meals?.first?.title, title)
        XCTAssertNil(decoded.meals?.first?.fatGrams)
    }

    func testEmptySelectedWorkoutTablesKeepHeadersAndDoNotAddUnselectedFiles() throws {
        let data = try snapshot(selection: .init(mealsAndWater: false, outdoorActivities: false, goalsAndPreferences: false))
        let files = try LocalDataExportFiles.make(from: data)
        XCTAssertEqual(Set(files.keys), ["snapshot.json", "workouts.csv", "exercises.csv", "sets.csv", "README.txt"])
        let sets = String(decoding: try XCTUnwrap(files["sets.csv"]), as: UTF8.self)
        XCTAssertTrue(sets.contains("\"exerciseOccurrenceID\""))
        XCTAssertTrue(sets.contains("\"load.unit\""))
        XCTAssertEqual(sets.components(separatedBy: "\r\n").count, 2)
        XCTAssertNil(files["routes.gpx"])
        XCTAssertNil(files["body-weight.csv"])
    }

    func testGPXRequiresOptInAndPreservesSegmentBreaks() throws {
        let record = routeRecord()
        let selection = LocalDataExportSelection(workouts: false, mealsAndWater: false, routes: true, goalsAndPreferences: false)
        let data = try snapshot(selection: selection, outdoor: [OutdoorActivityExport(record, includeRoute: true)])
        let files = try LocalDataExportFiles.make(from: data)
        let gpx = try XCTUnwrap(files["routes.gpx"])
        let reader = ExportGPXReader()
        let parser = XMLParser(data: gpx)
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        XCTAssertEqual(reader.trackCount, 1)
        XCTAssertEqual(reader.segmentCount, 2)
        XCTAssertEqual(reader.pointCount, 3)
        XCTAssertEqual(reader.latitudes, ["43.0", "43.0", "43.0"])

        var withoutRoutes = selection
        withoutRoutes.routes = false
        let privateData = try snapshot(selection: withoutRoutes, outdoor: [OutdoorActivityExport(record, includeRoute: false)])
        XCTAssertNil(try LocalDataExportFiles.make(from: privateData)["routes.gpx"])
        // Even an inconsistent input cannot accidentally widen route consent.
        let mismatched = try snapshot(selection: withoutRoutes, outdoor: [OutdoorActivityExport(record, includeRoute: true)])
        XCTAssertThrowsError(try LocalDataExportFiles.make(from: mismatched))
    }

    func testGPXCoordinatesUsePlainDecimalWithoutLosingDoublePrecision() {
        for value in [0.000001, -0.000001, 1e-20, -1e-20, Double.leastNonzeroMagnitude, 180, -0.0] {
            let text = LocalDataExportFiles.coordinate(value)
            XCTAssertFalse(text.lowercased().contains("e"))
            XCTAssertEqual(Double(text), value)
        }
        XCTAssertEqual(LocalDataExportFiles.coordinate(0.000001), "0.000001")
        XCTAssertEqual(LocalDataExportFiles.coordinate(-1e-20), "-0.00000000000000000001")
    }

    func testNativeArchiveHasZIPHeaderAndRemovesItsStagingDirectory() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("01-export-test-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let data = try snapshot(selection: .init(mealsAndWater: false, outdoorActivities: false, goalsAndPreferences: false))
        let zip = try LocalDataExportArchive.make(from: data, temporaryDirectory: directory)
        XCTAssertTrue(zip.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func snapshot(selection: LocalDataExportSelection, meals: [NutritionEntry]? = nil,
                          outdoor: [OutdoorActivityExport]? = nil) throws -> Data {
        try JSONEncoder().encode(LocalDataExportPackage(exportedAt: Date(timeIntervalSinceReferenceDate: 2000),
            completedWorkouts: [], bodyWeightReadings: [], selection: selection, meals: meals,
            waterSnapshot: nil, outdoorActivities: outdoor, goalsAndPreferences: nil))
    }

    private func routeRecord() -> OutdoorActivityRecord {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        var route = OutdoorRouteAccumulator()
        let policy = OutdoorRouteAcceptancePolicy(maximumHorizontalAccuracyMeters: 20,
            maximumGapSeconds: 30, maximumPlausibleSpeedMetersPerSecond: 20, maximumFutureSeconds: 1)
        for offset in [0, 10, 100] {
            let time = start.addingTimeInterval(Double(offset))
            _ = route.ingest(OutdoorRouteFix(latitude: 43, longitude: 27 + Double(offset) * 0.00001,
                timestamp: time, horizontalAccuracyMeters: 5), receivedAt: time, policy: policy)
        }
        let end = start.addingTimeInterval(120)
        return OutdoorActivityRecord(checkpoint: OutdoorActivityCheckpoint(kind: .run,
            startedAt: start, checkpointedAt: end, confirmedActiveSeconds: 120,
            phase: .readyToSave, finishedAt: end, route: route), finishedAt: end)
    }
}

private final class ExportGPXReader: NSObject, XMLParserDelegate {
    var trackCount = 0
    var segmentCount = 0
    var pointCount = 0
    var latitudes = [String]()
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "trk": trackCount += 1
        case "trkseg": segmentCount += 1
        case "trkpt": pointCount += 1; latitudes.append(attributes["lat"] ?? "")
        default: break
        }
    }
}
