import CoreLocation
import Foundation
import Observation
import UIKit

enum OutdoorActivitySurface: Equatable {
    case setup
    case requestingPermission
    case locationUnavailable
    case recording
    case paused
    case interrupted
    case saving
    case storageBlocked
    case summary
}

/// Owns the outdoor flow for the life of the app root, not the presented screen.
/// Closing the screen does not silently end an activity or its location session.
@MainActor
@Observable
final class OutdoorActivityViewModel {
    private(set) var surface: OutdoorActivitySurface = .setup
    private(set) var checkpoint: OutdoorActivityCheckpoint?
    private(set) var finishedRecord: OutdoorActivityRecord?
    private(set) var latestSavedWalk: DailyWidgetSnapshot.Walk?
    @ObservationIgnored private var latestWalkRefreshID = UUID()
    private(set) var selectedKind: OutdoorActivityKind = .walk
    private(set) var locationReadiness: OutdoorLocationReadiness = .needsPermission
    private(set) var displaySeconds: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var isRecordingWithoutGPS = false
    private(set) var message: String?

    @ObservationIgnored private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    @ObservationIgnored private let repository: OutdoorActivityRepository
    @ObservationIgnored private let recorder: OutdoorActivityRecorder
    @ObservationIgnored private let location: OutdoorLocationService
    @ObservationIgnored private let onConfirmedStartOrResume: () -> Void
    @ObservationIgnored private let steps = OutdoorStepService()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var locationPump: Task<Void, Never>?
    @ObservationIgnored private var activeAnchor: ContinuousClock.Instant?
    @ObservationIgnored private var activeBaseline: TimeInterval = 0
    @ObservationIgnored private var isChangingSession = false

    var hasUnfinishedSession: Bool { checkpoint != nil || surface == .storageBlocked }

    /// Read-only sharing gate. Starting or saving can suspend before refresh
    /// installs the checkpoint, so checkpoint absence alone is insufficient.
    var canShareSavedRecords: Bool {
        guard isLoaded, !isChangingSession, checkpoint == nil else { return false }
        switch surface {
        case .setup, .locationUnavailable, .summary: return true
        case .requestingPermission, .recording, .paused, .interrupted, .saving, .storageBlocked: return false
        }
    }

    /// History deletion and transfer share the recorder's serial journal owner.
    var historyRepository: OutdoorActivityRepository { repository }

    init(
        repository: OutdoorActivityRepository = OutdoorActivityRepository(),
        location: OutdoorLocationService? = nil,
        onConfirmedStartOrResume: @escaping () -> Void = {}
    ) {
        self.repository = repository
        recorder = OutdoorActivityRecorder(repository: repository)
        self.location = location ?? OutdoorLocationService()
        self.onConfirmedStartOrResume = onConfirmedStartOrResume
    }

    /// Complete both actual owner installations before Root may grant a permit.
    /// Concurrent/out-of-order installation is checked by exact identity on both sides.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) async {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
        await recorder.installShareRevocationRegistration(registration)
    }

    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) async -> Bool {
        guard let registration, shareRevocationRegistration === registration else { return false }
        let registered = await recorder.isShareRevocationRegistered(registration)
        return registered && shareRevocationRegistration === registration
    }

    /// Root still needs this VM gate, exact persisted checks and retained permits.
    func confirmsRecorderShareReadiness() async -> Bool {
        await recorder.canShareSavedRecords
    }

    func open(_ kind: OutdoorActivityKind) {
        shareRevocationRegistration?.revokeBeforeChange()
        if checkpoint == nil {
            selectedKind = kind
            shareRevocationRegistration?.revokeBeforeChange(); finishedRecord = nil
            if surface == .summary { shareRevocationRegistration?.revokeBeforeChange(); surface = .setup }
        }
    }

    func load() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard !isLoaded else { return }
        location.onReadinessChange = { [weak self] readiness in
            guard let self else { return }
            self.locationReadiness = readiness
            if self.surface == .requestingPermission, readiness != .needsPermission {
                if readiness == .ready {
                    Task { await self.startOrResumeRoute() }
                } else {
                    self.shareRevocationRegistration?.revokeBeforeChange(); self.surface = .locationUnavailable
                }
            }
        }
        locationReadiness = location.readiness
        do {
            _ = try await recorder.restore()
            await refresh()
        } catch {
            message = "Your previous outdoor activity could not be loaded. Its data has been kept; try again later."
            shareRevocationRegistration?.revokeBeforeChange(); surface = .storageBlocked
        }
        shareRevocationRegistration?.revokeBeforeChange(); isLoaded = true
        await refreshLatestWalk()
    }

    /// Fresh acknowledged records for an explicitly requested local export.
    func savedRecordsForExport() async throws -> [OutdoorActivityRecord] {
        try await repository.loadRecords()
    }

    /// Read only acknowledged history. Never expose route geometry to widgets.
    func refreshLatestWalk(clearCached: Bool = false) async {
        let requestID = UUID()
        latestWalkRefreshID = requestID
        if clearCached { latestSavedWalk = nil }
        let records = try? await repository.loadRecords()
        guard requestID == latestWalkRefreshID else { return }
        latestSavedWalk = DailyWidgetProjection.latestSavedWalk(from: records ?? [], at: .now)
    }

    /// Called by the Start or Resume button, never by opening the screen.
    func startWithRoute() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard isLoaded, surface == .setup || surface == .paused || surface == .interrupted
                || surface == .locationUnavailable, !isChangingSession else { return }
        if checkpoint?.trackingMode == .timerOnly {
            await startTimeOnly()
            return
        }
        message = nil
        locationReadiness = location.readiness
        switch locationReadiness {
        case .ready:
            await startOrResumeRoute()
        case .needsPermission:
            shareRevocationRegistration?.revokeBeforeChange(); surface = .requestingPermission
            _ = location.requestPermissionForOutdoorStart()
        default:
            shareRevocationRegistration?.revokeBeforeChange(); surface = .locationUnavailable
        }
    }

    /// The explicit fallback never starts Core Location and never invents distance.
    func startTimeOnly() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard isLoaded, surface == .setup || surface == .locationUnavailable
                || surface == .paused || surface == .interrupted, !isChangingSession else { return }
        shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = true
        defer { shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = false }
        message = nil
        do {
            let current: OutdoorActivityCheckpoint
            if let checkpoint {
                current = try await recorder.resume(at: .now)
                if checkpoint.trackingMode == .route {
                    try await recorder.noteLocationGap(at: .now)
                }
            } else {
                current = try await recorder.start(kind: selectedKind, trackingMode: .timerOnly, at: .now)
            }
            isRecordingWithoutGPS = true
            await refresh()
            if surface == .recording { onConfirmedStartOrResume() }
            startTicker()
            startStepUpdates(for: current)
        } catch {
            await handleStorageError(error)
        }
    }

    func pause() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let checkpoint, surface == .recording, !isChangingSession else { return }
        shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = true
        defer { shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = false }
        let pausedAt = Date()
        // Cancel the old consumer before stopping its producer. Drain its in-flight
        // write before Pause so a buffered old stream cannot reappear after Resume.
        let oldPump = locationPump
        locationPump = nil
        oldPump?.cancel()
        location.stopRoute(for: checkpoint.id)
        let stepIntervalID = steps.stop()
        let oldTicker = ticker
        ticker?.cancel()
        ticker = nil
        await oldPump?.value
        await oldTicker?.value
        do {
            let paused = try await recorder.pause(at: pausedAt)
            await refresh()
            if let stepIntervalID {
                await finalizeSteps(for: paused, intervalID: stepIntervalID)
            }
        } catch {
            await handleStorageError(error)
        }
    }

    func finish() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard let checkpoint, surface == .recording || surface == .paused
                || surface == .interrupted, !isChangingSession else { return }
        shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = true
        defer { shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = false }
        let wasRecording = surface == .recording
        let finishedAt = Date()
        let oldPump = locationPump
        locationPump = nil
        oldPump?.cancel()
        location.stopRoute(for: checkpoint.id)
        let stepIntervalID = steps.stop()
        let oldTicker = ticker
        ticker?.cancel()
        ticker = nil
        shareRevocationRegistration?.revokeBeforeChange(); surface = .saving
        await oldPump?.value
        await oldTicker?.value
        do {
            if wasRecording, let stepIntervalID {
                let paused = try await recorder.pause(at: finishedAt, isUserInitiated: false)
                await finalizeSteps(for: paused, intervalID: stepIntervalID)
                guard surface != .storageBlocked else { return }
            }
            let result = try await recorder.finish(at: finishedAt)
            switch result {
            case let .saved(record), let .alreadySaved(record):
                shareRevocationRegistration?.revokeBeforeChange(); finishedRecord = record
            }
            self.shareRevocationRegistration?.revokeBeforeChange(); self.checkpoint = nil
            activeAnchor = nil
            shareRevocationRegistration?.revokeBeforeChange(); surface = .summary
        } catch {
            await handleStorageError(error)
        }
    }

    func retryStorage() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard surface == .storageBlocked else { return }
        do {
            _ = try await recorder.retryStorage(at: .now)
            await refresh()
            if case .idle = await recorder.state(),
               let latest = try await repository.loadRecords().first {
                shareRevocationRegistration?.revokeBeforeChange(); finishedRecord = latest
                shareRevocationRegistration?.revokeBeforeChange(); surface = .summary
            }
        } catch {
            message = "Still unable to save. Your last confirmed activity data has been kept on this iPhone."
        }
    }

    func closeSummary() {
        shareRevocationRegistration?.revokeBeforeChange()
        guard surface == .summary else { return }
        shareRevocationRegistration?.revokeBeforeChange(); finishedRecord = nil
        displaySeconds = 0
        isRecordingWithoutGPS = false
        message = nil
        shareRevocationRegistration?.revokeBeforeChange(); surface = .setup
    }

    func refreshReadiness() {
        shareRevocationRegistration?.revokeBeforeChange()
        locationReadiness = location.readiness
        if surface == .locationUnavailable, locationReadiness == .ready {
            shareRevocationRegistration?.revokeBeforeChange(); surface = checkpoint == nil ? .setup : .paused
        }
    }

    private func startOrResumeRoute() async {
        shareRevocationRegistration?.revokeBeforeChange()
        guard !isChangingSession else { return }
        shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = true
        defer { shareRevocationRegistration?.revokeBeforeChange(); isChangingSession = false }
        guard location.readiness == .ready else {
            locationReadiness = location.readiness
            shareRevocationRegistration?.revokeBeforeChange(); surface = .locationUnavailable
            return
        }
        do {
            let current: OutdoorActivityCheckpoint
            if checkpoint != nil {
                current = try await recorder.resume(at: .now)
            } else {
                current = try await recorder.start(kind: selectedKind, at: .now)
            }
            isRecordingWithoutGPS = false
            await refresh()
            if surface == .recording { onConfirmedStartOrResume() }
            startTicker()
            startStepUpdates(for: current)
            let pump = OutdoorLocationRecorderPump(
                recorder: recorder,
                policy: OutdoorRouteAcceptancePolicy(
                    maximumHorizontalAccuracyMeters: 50,
                    maximumGapSeconds: 15,
                    maximumPlausibleSpeedMetersPerSecond: selectedKind == .run ? 10 : 6,
                    maximumFutureSeconds: 2
                )
            )
            locationPump = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await pump.startAndRun(
                        for: current.id,
                        using: self.location,
                        onRecorderChange: { [weak self] in await self?.refresh() }
                    )
                    if case let .pausedForLocationLoss(reason) = result {
                        self.message = self.message(for: reason)
                    } else if result == .storageBlocked {
                        self.message = "The route could not be saved. Recording has stopped; retry the local save."
                    }
                } catch {
                    // Starting Core Location can race a permission or foreground change.
                    // Keep the acknowledged activity, mark the route gap, and pause it.
                    if case let .recording(active) = await self.recorder.state(), active.id == current.id {
                        do {
                            try await self.recorder.noteLocationGap(at: .now)
                            _ = try await self.recorder.pause(at: .now, isUserInitiated: false)
                        } catch { self.message = "Unable to save the location interruption." }
                    }
                    self.message = "Location became unavailable. Your activity is paused."
                }
                await self.refresh()
            }
        } catch {
            await handleStorageError(error)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var secondsSinceCheckpoint = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.surface == .recording else { return }
                self.updateDisplayedTime()
                secondsSinceCheckpoint += 1
                if secondsSinceCheckpoint >= 10 {
                    secondsSinceCheckpoint = 0
                    do {
                        _ = try await self.recorder.heartbeat(at: .now)
                        await self.refresh()
                    } catch {
                        await self.handleStorageError(error)
                        return
                    }
                }
            }
        }
    }

    private func refresh() async {
        shareRevocationRegistration?.revokeBeforeChange()
        let wasSaving = surface == .saving
        switch await recorder.state() {
        case .idle:
            _ = steps.stop()
            shareRevocationRegistration?.revokeBeforeChange(); checkpoint = nil
            activeAnchor = nil
            if surface != .summary { shareRevocationRegistration?.revokeBeforeChange(); surface = .setup }
        case let .recording(current):
            shareRevocationRegistration?.revokeBeforeChange(); checkpoint = current
            selectedKind = current.kind
            if current.trackingMode == .timerOnly { isRecordingWithoutGPS = true }
            activeBaseline = current.confirmedActiveSeconds
            activeAnchor = .now
            displaySeconds = activeBaseline
            if !wasSaving { shareRevocationRegistration?.revokeBeforeChange(); surface = .recording }
        case let .paused(current):
            let stoppedIntervalID = steps.stop()
            shareRevocationRegistration?.revokeBeforeChange(); checkpoint = current
            selectedKind = current.kind
            if current.trackingMode == .timerOnly { isRecordingWithoutGPS = true }
            activeAnchor = nil
            displaySeconds = current.confirmedActiveSeconds
            if !wasSaving { shareRevocationRegistration?.revokeBeforeChange(); surface = .paused }
            ticker?.cancel()
            ticker = nil
            if let stoppedIntervalID {
                Task { [weak self] in
                    await self?.finalizeSteps(for: current, intervalID: stoppedIntervalID)
                }
            }
        case let .interrupted(current):
            _ = steps.stop()
            shareRevocationRegistration?.revokeBeforeChange(); checkpoint = current
            selectedKind = current.kind
            if current.trackingMode == .timerOnly { isRecordingWithoutGPS = true }
            activeAnchor = nil
            displaySeconds = current.confirmedActiveSeconds
            shareRevocationRegistration?.revokeBeforeChange(); surface = .interrupted
        case let .savePending(current), let .storageBlocked(current):
            _ = steps.stop()
            shareRevocationRegistration?.revokeBeforeChange(); checkpoint = current
            activeAnchor = nil
            displaySeconds = current.confirmedActiveSeconds
            shareRevocationRegistration?.revokeBeforeChange(); surface = .storageBlocked
            ticker?.cancel()
            ticker = nil
        }
    }

    private func updateDisplayedTime() {
        guard let activeAnchor else { return }
        let duration = activeAnchor.duration(to: .now).components
        displaySeconds = activeBaseline + Double(duration.seconds)
            + Double(duration.attoseconds) / 1_000_000_000_000_000_000
    }

    private func handleStorageError(_ error: Error) async {
        shareRevocationRegistration?.revokeBeforeChange()
        if let checkpoint { location.stopRoute(for: checkpoint.id) }
        _ = steps.stop()
        ticker?.cancel()
        ticker = nil
        await refresh()
        if surface == .setup {
            message = "Could not start this activity. Nothing was recorded; please try again."
            return
        }
        message = "Could not save this activity change. Recording is stopped; retry the local save."
        if surface != .storageBlocked { shareRevocationRegistration?.revokeBeforeChange(); surface = .storageBlocked }
    }

    private func message(for reason: OutdoorLocationStopReason) -> String {
        switch reason {
        case .requested: "Location recording stopped."
        case .authorizationLost, .accuracyReduced, .servicesDisabled:
            "Precise location is unavailable. Your activity is paused and no distance has been guessed."
        case .sensorFailure, .bufferOverflow:
            "GPS was interrupted. Your activity is paused and the route has a visible gap."
        }
    }

    private func startStepUpdates(for current: OutdoorActivityCheckpoint) {
        guard let interval = current.steps.activeInterval else { return }
        steps.start(interval: interval) { [weak self] snapshot in
            Task { [weak self] in
                await self?.ingestStepSnapshot(snapshot)
            }
        }
    }

    private func ingestStepSnapshot(_ snapshot: OutdoorStepSnapshot) async {
        guard !isChangingSession, surface == .recording,
              checkpoint?.steps.activeInterval?.id == snapshot.intervalID else { return }
        do {
            if try await recorder.ingestSteps(snapshot, at: .now) {
                await refresh()
            }
        } catch OutdoorRecorderError.noActivity, OutdoorRecorderError.notRecording {
            // A callback cannot revive an interval closed by Pause or Finish.
        } catch {
            await handleStorageError(error)
        }
    }

    private func finalizeSteps(for checkpoint: OutdoorActivityCheckpoint, intervalID: UUID) async {
        guard let interval = checkpoint.steps.intervals.first(where: { $0.id == intervalID }),
              interval.endedAt != nil,
              let snapshot = await steps.finalSnapshot(for: interval) else { return }
        for attempt in 0..<2 {
            do {
                if try await recorder.ingestSteps(snapshot, at: .now), surface != .saving {
                    await refresh()
                }
                return
            } catch OutdoorRecorderError.busy {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch OutdoorRecorderError.noActivity, OutdoorRecorderError.notRecording {
                return
            } catch {
                await handleStorageError(error)
                return
            }
        }
    }
}
