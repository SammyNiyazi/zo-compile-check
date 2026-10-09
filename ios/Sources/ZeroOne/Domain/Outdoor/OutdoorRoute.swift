import CoreLocation
import Foundation

struct OutdoorRouteFix: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracyMeters: Double
}

struct OutdoorRouteSegment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    private(set) var points: [OutdoorRouteFix]
    // Optional so existing checkpoints/history decode without inventing pause markers.
    private(set) var endsAtUserPause: Bool?

    init(id: UUID = UUID(), firstPoint: OutdoorRouteFix) {
        self.id = id
        points = [firstPoint]
    }

    mutating func append(_ point: OutdoorRouteFix) {
        points.append(point)
    }

    mutating func markUserPause() {
        endsAtUserPause = true
    }

    /// Straighten small GPS zigzags for display only. Retained vertices are real
    /// fixes; raw points and measured distance are never rewritten or road-snapped.
    var presentationPoints: [OutdoorRouteFix] {
        guard points.count > 2 else { return points }
        let origin = points[0]
        let metersPerDegree = 111_195.0
        let longitudeScale = cos(origin.latitude * .pi / 180) * metersPerDegree
        let positions = points.map { point -> (x: Double, y: Double) in
            let delta = (point.longitude - origin.longitude + 540)
                .truncatingRemainder(dividingBy: 360) - 180
            return (delta * longitudeScale, (point.latitude - origin.latitude) * metersPerDegree)
        }
        var retained: Set<Int> = [0, points.count - 1]
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            let a = positions[first]
            let b = positions[last]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var farthest = first
            var maximumSquared = 16.0 // Four metres, presentation only.
            for index in (first + 1)..<last {
                let p = positions[index]
                let fraction = lengthSquared > 0
                    ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
                let offsetX = p.x - (a.x + fraction * dx)
                let offsetY = p.y - (a.y + fraction * dy)
                let squared = offsetX * offsetX + offsetY * offsetY
                if squared > maximumSquared {
                    maximumSquared = squared
                    farthest = index
                }
            }
            if farthest != first {
                retained.insert(farthest)
                ranges.append((first, farthest))
                ranges.append((farthest, last))
            }
        }
        return retained.sorted().map { points[$0] }
    }
}

struct OutdoorRouteAcceptancePolicy: Equatable, Sendable {
    let maximumHorizontalAccuracyMeters: Double
    let maximumGapSeconds: TimeInterval
    let maximumPlausibleSpeedMetersPerSecond: Double
    let maximumFutureSeconds: TimeInterval

    // These are inputs, not claimed universal GPS thresholds. Tune them with real-device evidence.
    init(
        maximumHorizontalAccuracyMeters: Double,
        maximumGapSeconds: TimeInterval,
        maximumPlausibleSpeedMetersPerSecond: Double,
        maximumFutureSeconds: TimeInterval
    ) {
        precondition(maximumHorizontalAccuracyMeters > 0)
        precondition(maximumGapSeconds > 0)
        precondition(maximumPlausibleSpeedMetersPerSecond > 0)
        precondition(maximumFutureSeconds >= 0)
        self.maximumHorizontalAccuracyMeters = maximumHorizontalAccuracyMeters
        self.maximumGapSeconds = maximumGapSeconds
        self.maximumPlausibleSpeedMetersPerSecond = maximumPlausibleSpeedMetersPerSecond
        self.maximumFutureSeconds = maximumFutureSeconds
    }
}

enum OutdoorRouteRejection: Equatable, Sendable {
    case invalidCoordinate
    case invalidAccuracy
    case futureSample
    case outOfOrder
    case implausibleJump
    case outsideActiveInterval
}

enum OutdoorRouteSampleOutcome: Equatable, Sendable {
    case startedSegment
    case extendedSegment(meters: Double)
    case rejected(OutdoorRouteRejection)
}

private enum OutdoorRouteBreak: String, Codable, Equatable, Sendable {
    case userPause
    case locationGap
}

struct OutdoorRouteAccumulator: Codable, Equatable, Sendable {
    private(set) var segments: [OutdoorRouteSegment] = []
    private(set) var totalRecordedMeters: Double = 0
    private(set) var hasMissingLocationCoverage = false
    private(set) var hasMeasuredInterval = false
    private var pendingBreak: OutdoorRouteBreak?

    var recordedDistanceMeters: Double? {
        hasMeasuredInterval ? totalRecordedMeters : nil
    }

    // A decoded checkpoint must not trust its stored distance or geometry blindly.
    var isInternallyConsistent: Bool {
        guard totalRecordedMeters.isFinite, totalRecordedMeters >= 0 else { return false }
        guard Set(segments.map(\.id)).count == segments.count else { return false }

        var previousTimestamp: Date?
        var calculatedMeters = 0.0
        var containsMeasuredInterval = false
        for segment in segments {
            guard !segment.points.isEmpty else { return false }
            for (index, point) in segment.points.enumerated() {
                guard point.latitude.isFinite, point.longitude.isFinite,
                      (-90.0 ... 90.0).contains(point.latitude),
                      (-180.0 ... 180.0).contains(point.longitude),
                      point.horizontalAccuracyMeters.isFinite,
                      point.horizontalAccuracyMeters >= 0,
                      point.timestamp.timeIntervalSinceReferenceDate.isFinite else { return false }
                if let previousTimestamp, point.timestamp <= previousTimestamp { return false }
                previousTimestamp = point.timestamp
                if index > 0 {
                    let prior = segment.points[index - 1]
                    calculatedMeters += CLLocation(latitude: prior.latitude, longitude: prior.longitude)
                        .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                    containsMeasuredInterval = true
                }
            }
        }
        guard containsMeasuredInterval == hasMeasuredInterval else { return false }
        return abs(calculatedMeters - totalRecordedMeters) <= max(0.01, calculatedMeters * 0.000_000_001)
    }

    mutating func breakForUserPause(markEndpoint: Bool = true) {
        if markEndpoint, !segments.isEmpty { segments[segments.count - 1].markUserPause() }
        pendingBreak = .userPause
    }

    mutating func noteLocationGap() {
        hasMissingLocationCoverage = true
        pendingBreak = .locationGap
    }

    @discardableResult
    mutating func ingest(
        _ fix: OutdoorRouteFix,
        receivedAt: Date,
        policy: OutdoorRouteAcceptancePolicy
    ) -> OutdoorRouteSampleOutcome {
        guard fix.latitude.isFinite,
              fix.longitude.isFinite,
              (-90.0 ... 90.0).contains(fix.latitude),
              (-180.0 ... 180.0).contains(fix.longitude) else {
            noteLocationGap()
            return .rejected(.invalidCoordinate)
        }

        guard fix.horizontalAccuracyMeters.isFinite,
              fix.horizontalAccuracyMeters >= 0,
              fix.horizontalAccuracyMeters <= policy.maximumHorizontalAccuracyMeters else {
            noteLocationGap()
            return .rejected(.invalidAccuracy)
        }

        guard fix.timestamp <= receivedAt.addingTimeInterval(policy.maximumFutureSeconds) else {
            return .rejected(.futureSample)
        }

        guard let previous = segments.last?.points.last else {
            appendNewSegment(startingAt: fix)
            return .startedSegment
        }

        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else {
            return .rejected(.outOfOrder)
        }

        if pendingBreak != nil {
            appendNewSegment(startingAt: fix)
            return .startedSegment
        }

        if elapsed > policy.maximumGapSeconds {
            noteLocationGap()
            appendNewSegment(startingAt: fix)
            return .startedSegment
        }

        let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            .distance(from: CLLocation(latitude: fix.latitude, longitude: fix.longitude))
        let uncertainty = previous.horizontalAccuracyMeters + fix.horizontalAccuracyMeters
        guard distance - uncertainty <= policy.maximumPlausibleSpeedMetersPerSecond * elapsed else {
            noteLocationGap()
            return .rejected(.implausibleJump)
        }

        segments[segments.count - 1].append(fix)
        totalRecordedMeters += distance
        hasMeasuredInterval = true
        return .extendedSegment(meters: distance)
    }

    private mutating func appendNewSegment(startingAt fix: OutdoorRouteFix) {
        segments.append(OutdoorRouteSegment(firstPoint: fix))
        pendingBreak = nil
    }
}
