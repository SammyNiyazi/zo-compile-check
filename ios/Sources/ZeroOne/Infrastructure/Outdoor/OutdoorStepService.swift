import CoreMotion
import Foundation
import UIKit

/// Optional phone pedometer for one explicitly started outdoor activity.
/// A live callback is cumulative for its interval; the recorder replaces the
/// previous estimate instead of adding callbacks together.
@MainActor
final class OutdoorStepService {
    private struct ActiveInterval: Sendable {
        let id: UUID
        let generation: UUID
        let startedAt: Date
    }

    private let pedometer = CMPedometer()
    private var active: ActiveInterval?
    private var pendingQueries: [UUID: CheckedContinuation<OutdoorStepSnapshot?, Never>] = [:]
    private var onSnapshot: (@MainActor (OutdoorStepSnapshot) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var liveQueryID: UUID?

    @discardableResult
    func start(
        interval: OutdoorStepInterval,
        onSnapshot: @escaping @MainActor (OutdoorStepSnapshot) -> Void
    ) -> Bool {
        _ = stop()
        guard interval.endedAt == nil,
              CMPedometer.isStepCountingAvailable(),
              Self.motionPurposeIsConfigured,
              Self.motionAuthorizationAllowsRequest else { return false }

        let generation = UUID()
        active = ActiveInterval(id: interval.id, generation: generation, startedAt: interval.startedAt)
        self.onSnapshot = onSnapshot
        pedometer.startUpdates(from: interval.startedAt) { [weak self] data, error in
            guard error == nil,
                  let data,
                  let count = Self.stepCount(from: data),
                  data.startDate.timeIntervalSinceReferenceDate.isFinite,
                  data.endDate.timeIntervalSinceReferenceDate.isFinite else { return }
            let snapshot = OutdoorStepSnapshot(
                intervalID: interval.id,
                sampleStartedAt: data.startDate,
                sampleEndedAt: data.endDate,
                cumulativeSteps: count,
                isFinal: false
            )
            Task { @MainActor [weak self] in
                guard self?.active?.generation == generation else { return }
                onSnapshot(snapshot)
            }
        }
        // Core Motion controls live delivery cadence. Query its real cached count
        // while foregrounded to reconcile delayed callbacks, never predict steps.
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.refreshLiveSnapshot()
            }
        }
        foregroundTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard !Task.isCancelled else { return }
                self?.refreshLiveSnapshot()
            }
        }
        return true
    }

    private func refreshLiveSnapshot() {
        guard let active, liveQueryID == nil,
              UIApplication.shared.applicationState == .active,
              CMPedometer.authorizationStatus() == .authorized else { return }
        let requestID = UUID()
        liveQueryID = requestID
        pedometer.queryPedometerData(from: active.startedAt, to: .now) { [weak self] data, error in
            let snapshot: OutdoorStepSnapshot?
            if error == nil, let data, let count = Self.stepCount(from: data) {
                snapshot = OutdoorStepSnapshot(
                    intervalID: active.id,
                    sampleStartedAt: data.startDate,
                    sampleEndedAt: data.endDate,
                    cumulativeSteps: count,
                    isFinal: false
                )
            } else {
                snapshot = nil
            }
            Task { @MainActor [weak self] in
                guard let self, self.liveQueryID == requestID,
                      self.active?.generation == active.generation else { return }
                self.liveQueryID = nil
                if let snapshot { self.onSnapshot?(snapshot) }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.liveQueryID == requestID else { return }
            self?.liveQueryID = nil
        }
    }

    /// Invalidates even an already-queued callback before stopping updates.
    @discardableResult
    func stop() -> UUID? {
        guard let active else { return nil }
        self.active = nil
        onSnapshot = nil
        liveQueryID = nil
        refreshTask?.cancel()
        refreshTask = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        pedometer.stopUpdates()
        return active.id
    }

    /// Query the closed active interval once to reconcile background-delayed
    /// live callbacks. The timeout means optional steps cannot hold Finish.
    func finalSnapshot(for interval: OutdoorStepInterval) async -> OutdoorStepSnapshot? {
        guard let endedAt = interval.endedAt,
              endedAt >= interval.startedAt,
              CMPedometer.isStepCountingAvailable(),
              Self.motionPurposeIsConfigured,
              Self.motionAuthorizationAllowsRequest else { return nil }

        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            pendingQueries[requestID] = continuation
            pedometer.queryPedometerData(from: interval.startedAt, to: endedAt) { [weak self] data, error in
                let snapshot: OutdoorStepSnapshot?
                if error == nil, let data, let count = Self.stepCount(from: data) {
                    snapshot = OutdoorStepSnapshot(
                        intervalID: interval.id,
                        sampleStartedAt: data.startDate,
                        sampleEndedAt: data.endDate,
                        cumulativeSteps: count,
                        isFinal: true
                    )
                } else {
                    snapshot = nil
                }
                Task { @MainActor [weak self] in
                    self?.completeQuery(requestID, with: snapshot)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.completeQuery(requestID, with: nil)
            }
        }
    }

    private func completeQuery(_ requestID: UUID, with snapshot: OutdoorStepSnapshot?) {
        pendingQueries.removeValue(forKey: requestID)?.resume(returning: snapshot)
    }

    private static var motionPurposeIsConfigured: Bool {
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String
        return !(purpose?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static var motionAuthorizationAllowsRequest: Bool {
        switch CMPedometer.authorizationStatus() {
        case .notDetermined, .authorized: true
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    nonisolated private static func stepCount(from data: CMPedometerData) -> Int? {
        let value = data.numberOfSteps.int64Value
        guard value >= 0 else { return nil }
        return Int(exactly: value)
    }
}
