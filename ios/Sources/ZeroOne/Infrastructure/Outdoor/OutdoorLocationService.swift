import CoreLocation
import Foundation
import UIKit

enum OutdoorLocationReadiness: Equatable {
    case missingUsageDescription
    case missingBackgroundMode
    case servicesDisabled
    case needsPermission
    case denied
    case restricted
    case reducedAccuracy
    case ready
}

struct OutdoorLocationConfiguration: Equatable {
    let hasWhenInUsePurpose: Bool
    let hasBackgroundMode: Bool

    init(infoDictionary: [String: Any]) {
        let purpose = infoDictionary["NSLocationWhenInUseUsageDescription"] as? String
        hasWhenInUsePurpose = !(purpose?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let modes = infoDictionary["UIBackgroundModes"] as? [String] ?? []
        hasBackgroundMode = modes.contains("location")
    }

    func readiness(
        servicesEnabled: Bool,
        authorization: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> OutdoorLocationReadiness {
        guard hasWhenInUsePurpose else { return .missingUsageDescription }
        guard hasBackgroundMode else { return .missingBackgroundMode }
        guard servicesEnabled else { return .servicesDisabled }
        switch authorization {
        case .notDetermined:
            return .needsPermission
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorizedWhenInUse, .authorizedAlways:
            return accuracy == .fullAccuracy ? .ready : .reducedAccuracy
        @unknown default:
            return .denied
        }
    }
}

enum OutdoorLocationEvent: Sendable {
    case fix(OutdoorRouteFix, receivedAt: Date)
    case gap
}

enum OutdoorLocationStopReason: Equatable, Sendable {
    case requested
    case authorizationLost
    case accuracyReduced
    case servicesDisabled
    case sensorFailure
    case bufferOverflow

    var requiresRecordingPause: Bool { self != .requested }
}

enum OutdoorLocationServiceError: Error, Equatable {
    case notReady(OutdoorLocationReadiness)
    case alreadyTracking
    case notForeground
}

/// One foreground-started Core Location stream per explicit outdoor session.
/// No location services are started by initialization or by viewing a screen.
@MainActor
final class OutdoorLocationService: NSObject, CLLocationManagerDelegate {
    private let configuration: OutdoorLocationConfiguration
    private let permissionManager: CLLocationManager
    private var trackingManager: CLLocationManager?
    private var continuation: AsyncStream<OutdoorLocationEvent>.Continuation?
    private var activeSessionID: UUID?
    private var activeStreamID: UUID?
    private var activeSince: Date?
    private var endReasons: [UUID: OutdoorLocationStopReason] = [:]

    var onReadinessChange: ((OutdoorLocationReadiness) -> Void)?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        configuration = OutdoorLocationConfiguration(infoDictionary: infoDictionary)
        permissionManager = CLLocationManager()
        super.init()
        permissionManager.delegate = self
    }

    var readiness: OutdoorLocationReadiness {
        configuration.readiness(
            servicesEnabled: CLLocationManager.locationServicesEnabled(),
            authorization: permissionManager.authorizationStatus,
            accuracy: permissionManager.accuracyAuthorization
        )
    }

    /// Call only after the user chooses to start a route, before starting the recorder clock.
    /// The UI observes `onReadinessChange` for the user's eventual decision.
    @discardableResult
    func requestPermissionForOutdoorStart() -> OutdoorLocationReadiness {
        let current = readiness
        if current == .needsPermission {
            permissionManager.requestWhenInUseAuthorization()
        }
        return current
    }

    func startRoute(for sessionID: UUID) throws -> AsyncStream<OutdoorLocationEvent> {
        guard trackingManager == nil else { throw OutdoorLocationServiceError.alreadyTracking }
        let current = readiness
        guard current == .ready else { throw OutdoorLocationServiceError.notReady(current) }
        guard UIApplication.shared.applicationState == .active else {
            throw OutdoorLocationServiceError.notForeground
        }

        let streamID = UUID()
        let stream = AsyncStream<OutdoorLocationEvent>(bufferingPolicy: .bufferingOldest(128)) {
            self.continuation = $0
            $0.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.stopRoute(for: sessionID, streamID: streamID)
                }
            }
        }
        let manager = CLLocationManager()
        trackingManager = manager
        activeSessionID = sessionID
        activeStreamID = streamID
        activeSince = Date()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = 5
        // The configuration guard above is essential: without the location background mode,
        // assigning true is a fatal Core Location configuration error.
        manager.allowsBackgroundLocationUpdates = true
        manager.delegate = self
        manager.startUpdatingLocation()
        return stream
    }

    func stopRoute(for sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        endRoute(reason: .requested)
    }

    private func stopRoute(for sessionID: UUID, streamID: UUID) {
        guard activeStreamID == streamID else { return }
        stopRoute(for: sessionID)
    }

    /// Read once after the event stream finishes. A non-requested end means the recorder
    /// should mark missing coverage and pause, rather than silently run a timer forever.
    func takeStopReason(for sessionID: UUID) -> OutdoorLocationStopReason? {
        endReasons.removeValue(forKey: sessionID)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === permissionManager || manager === trackingManager else { return }
        let current = readiness
        onReadinessChange?(current)
        guard trackingManager != nil, current != .ready else { return }
        switch current {
        case .reducedAccuracy:
            endRoute(reason: .accuracyReduced)
        case .servicesDisabled:
            endRoute(reason: .servicesDisabled)
        default:
            endRoute(reason: .authorizationLost)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === trackingManager, let activeSince else { return }
        for location in locations where location.timestamp >= activeSince {
            let fix = OutdoorRouteFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp,
                horizontalAccuracyMeters: location.horizontalAccuracy
            )
            emit(.fix(fix, receivedAt: Date()))
            guard manager === trackingManager else { return }
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard manager === trackingManager else { return }
        emit(.gap)
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard manager === trackingManager else { return }
        emit(.gap)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === trackingManager else { return }
        if let locationError = error as? CLError, locationError.code == .locationUnknown {
            emit(.gap)
        } else {
            endRoute(reason: .sensorFailure)
        }
    }

    private func emit(_ event: OutdoorLocationEvent) {
        guard let continuation else { return }
        if case .dropped = continuation.yield(event) {
            // A dropped fix makes the route discontinuous. Stop the stream so the
            // consumer drains prior fixes, records the gap, and pauses the session.
            endRoute(reason: .bufferOverflow)
        }
    }

    private func endRoute(reason: OutdoorLocationStopReason) {
        guard let sessionID = activeSessionID else { return }
        let manager = trackingManager
        trackingManager = nil
        activeSessionID = nil
        activeStreamID = nil
        activeSince = nil
        manager?.stopUpdatingLocation()
        manager?.allowsBackgroundLocationUpdates = false
        manager?.delegate = nil
        endReasons[sessionID] = reason
        continuation?.finish()
        continuation = nil
    }
}
