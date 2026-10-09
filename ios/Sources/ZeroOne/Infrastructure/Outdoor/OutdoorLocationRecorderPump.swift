import Foundation

enum OutdoorLocationPumpResult: Equatable, Sendable {
    case stopped
    case pausedForLocationLoss(OutdoorLocationStopReason)
    case recorderNotActive
    case storageBlocked
}

/// Drains one Core Location stream in order. The service owns the sensor; this
/// pump owns the recorder write order and never treats an unacknowledged fix as saved.
struct OutdoorLocationRecorderPump: Sendable {
    let recorder: OutdoorActivityRecorder
    let policy: OutdoorRouteAcceptancePolicy

    /// The recorder must already have acknowledged Start after the user's explicit
    /// choice and permission flow. A mismatched owner never starts the sensor.
    func startAndRun(
        for sessionID: UUID,
        using service: OutdoorLocationService,
        onRecorderChange: @escaping @Sendable () async -> Void = {}
    ) async throws -> OutdoorLocationPumpResult {
        guard !Task.isCancelled else { return .stopped }
        guard case let .recording(checkpoint) = await recorder.state(),
              checkpoint.id == sessionID else { return .recorderNotActive }
        guard !Task.isCancelled else { return .stopped }
        let events = try await service.startRoute(for: sessionID)
        guard case let .recording(current) = await recorder.state(),
              current.id == sessionID else {
            await service.stopRoute(for: sessionID)
            _ = await service.takeStopReason(for: sessionID)
            return .recorderNotActive
        }
        return await run(
            for: sessionID,
            events: events,
            stopLocation: { await service.stopRoute(for: sessionID) },
            takeStopReason: { await service.takeStopReason(for: sessionID) },
            onRecorderChange: onRecorderChange
        )
    }

    func run(
        for sessionID: UUID,
        events: AsyncStream<OutdoorLocationEvent>,
        stopLocation: @escaping () async -> Void,
        takeStopReason: @escaping () async -> OutdoorLocationStopReason?,
        onRecorderChange: @escaping @Sendable () async -> Void = {}
    ) async -> OutdoorLocationPumpResult {
        for await event in events {
            guard !Task.isCancelled else {
                await stopLocation()
                _ = await takeStopReason()
                return .stopped
            }
            guard case let .recording(checkpoint) = await recorder.state(),
                  checkpoint.id == sessionID else {
                await stopLocation()
                _ = await takeStopReason()
                return .recorderNotActive
            }

            do {
                switch event {
                case let .fix(fix, receivedAt):
                    _ = try await recorder.ingestLocation(fix, receivedAt: receivedAt, policy: policy)
                case .gap:
                    try await recorder.noteLocationGap(at: Date())
                }
                await onRecorderChange()
            } catch OutdoorRecorderError.notRecording, OutdoorRecorderError.noActivity {
                // An explicit Pause/Finish can win after the state check.
                await stopLocation()
                _ = await takeStopReason()
                return .recorderNotActive
            } catch {
                // The recorder freezes a failed write. Stop the producer immediately:
                // more fixes cannot safely be retained in memory or called a route.
                await stopLocation()
                _ = await takeStopReason()
                return .storageBlocked
            }
        }

        guard !Task.isCancelled else {
            await stopLocation()
            _ = await takeStopReason()
            return .stopped
        }
        let reason = await takeStopReason() ?? .requested
        guard reason.requiresRecordingPause else { return .stopped }
        guard case let .recording(checkpoint) = await recorder.state(),
              checkpoint.id == sessionID else { return .recorderNotActive }
        do {
            try await recorder.noteLocationGap(at: Date())
            _ = try await recorder.pause(at: Date(), isUserInitiated: false)
            await onRecorderChange()
            return .pausedForLocationLoss(reason)
        } catch {
            await stopLocation()
            _ = await takeStopReason()
            return .storageBlocked
        }
    }
}
