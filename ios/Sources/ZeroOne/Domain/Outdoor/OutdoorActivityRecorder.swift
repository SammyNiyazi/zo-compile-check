import Foundation

enum OutdoorRecorderState: Equatable, Sendable {
    case idle
    case recording(OutdoorActivityCheckpoint)
    case paused(OutdoorActivityCheckpoint)
    case interrupted(OutdoorActivityCheckpoint)
    case savePending(OutdoorActivityCheckpoint)
    case storageBlocked(OutdoorActivityCheckpoint)
}

enum OutdoorRecorderError: Error, Equatable {
    case busy
    case alreadyActive
    case noActivity
    case notRecording
    case notResumable
    case storageRetryRequired
    case clockRegression
    case invalidCheckpoint
}

/// Controls a single explicit outdoor activity. Sensor adapters may only feed this actor
/// while it reports `.recording`; they must stop when a storage operation fails.
/// App-level ownership against an active strength workout remains a separate prerequisite.
actor OutdoorActivityRecorder {
    private var shareRevocationRegistration: ZeroOneShareRevocationRegistration?
    private let repository: OutdoorActivityRepository
    private var checkpoint: OutdoorActivityCheckpoint?
    private var activeSince: ContinuousClock.Instant?
    private var blockedCandidate: OutdoorActivityCheckpoint?
    private var operationInFlight = false
    private var waitingOperations: [CheckedContinuation<Void, Never>] = []

    init(repository: OutdoorActivityRepository = OutdoorActivityRepository()) {
        self.repository = repository
    }

    /// Synchronous invalidation only; this capability never grants export.
    /// Retire old and distinct incoming permits before replacing/removing it.
    func installShareRevocationRegistration(_ registration: ZeroOneShareRevocationRegistration?) {
        shareRevocationRegistration?.revokeBeforeChange()
        if shareRevocationRegistration !== registration { registration?.revokeBeforeChange() }
        shareRevocationRegistration = registration
    }

    func isShareRevocationRegistered(_ registration: ZeroOneShareRevocationRegistration?) -> Bool {
        guard let registration else { return false }
        return shareRevocationRegistration === registration
    }

    /// Current pending authority, not a persisted checkpoint or cached VM mirror.
    var canShareSavedRecords: Bool {
        !operationInFlight && checkpoint == nil && blockedCandidate == nil
    }

    func state() -> OutdoorRecorderState {
        if let blockedCandidate { return .storageBlocked(blockedCandidate) }
        guard let checkpoint else { return .idle }
        switch checkpoint.phase {
        case .recording:
            return activeSince == nil ? .interrupted(checkpoint) : .recording(checkpoint)
        case .paused:
            return .paused(checkpoint)
        case .readyToSave:
            return .savePending(checkpoint)
        }
    }

    /// Restores only the last acknowledged checkpoint. Active time after it is unknown.
    func restore() async throws -> OutdoorRecorderState {
        await beginOperation()
        defer { endOperation() }
        guard checkpoint == nil, blockedCandidate == nil else { return state() }
        checkpoint = try await repository.loadCheckpoint()
        activeSince = nil
        return state()
    }

    @discardableResult
    func start(
        kind: OutdoorActivityKind,
        trackingMode: OutdoorTrackingMode = .route,
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws -> OutdoorActivityCheckpoint {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        guard checkpoint == nil, blockedCandidate == nil else { throw OutdoorRecorderError.alreadyActive }
        guard try await repository.loadCheckpoint() == nil else { throw OutdoorRecorderError.alreadyActive }
        var initial = OutdoorActivityCheckpoint(
            kind: kind,
            trackingMode: trackingMode,
            startedAt: wallTime,
            checkpointedAt: wallTime,
            confirmedActiveSeconds: 0,
            phase: .recording
        )
        _ = initial.steps.begin(at: wallTime)
        guard initial.isValid else { throw OutdoorRecorderError.invalidCheckpoint }
        try await repository.saveCheckpoint(initial)
        checkpoint = initial
        activeSince = monotonic
        return initial
    }

    /// A caller can checkpoint periodically even before the first usable GPS fix.
    @discardableResult
    func heartbeat(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws -> OutdoorActivityCheckpoint {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        var proposed = try activeProposal(at: wallTime, monotonic: monotonic)
        proposed.revision += 1
        try await persist(proposed, activeSince: monotonic)
        return proposed
    }

    @discardableResult
    func ingestLocation(
        _ fix: OutdoorRouteFix,
        receivedAt: Date,
        monotonic: ContinuousClock.Instant? = nil,
        policy: OutdoorRouteAcceptancePolicy
    ) async throws -> OutdoorRouteSampleOutcome {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        var proposed = try activeProposal(at: receivedAt, monotonic: monotonic)
        guard proposed.trackingMode == .route else { throw OutdoorRecorderError.notRecording }
        // A callback from an old sensor stream must not consume the pending
        // pause break or draw travel recorded before this explicit Resume.
        if let interval = proposed.steps.activeInterval, fix.timestamp < interval.startedAt {
            return .rejected(.outsideActiveInterval)
        }
        let outcome = proposed.route.ingest(fix, receivedAt: receivedAt, policy: policy)
        if case .rejected(.futureSample) = outcome { return outcome }
        if case .rejected(.outOfOrder) = outcome { return outcome }
        proposed.revision += 1
        try await persist(proposed, activeSince: monotonic)
        return outcome
    }

    func noteLocationGap(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        var proposed = try activeProposal(at: wallTime, monotonic: monotonic)
        proposed.route.noteLocationGap()
        proposed.revision += 1
        try await persist(proposed, activeSince: monotonic)
    }

    /// Accept only a cumulative count for this session's matching active interval,
    /// or a final query for its just-closed interval. A stale/late callback is ignored.
    @discardableResult
    func ingestSteps(
        _ snapshot: OutdoorStepSnapshot,
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws -> Bool {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        guard blockedCandidate == nil, let current = checkpoint else {
            throw OutdoorRecorderError.noActivity
        }
        let proposedAnchor: ContinuousClock.Instant?
        var proposed: OutdoorActivityCheckpoint
        switch current.phase {
        case .recording:
            proposed = try activeProposal(at: wallTime, monotonic: monotonic)
            proposedAnchor = monotonic
        case .paused where snapshot.isFinal:
            proposed = current
            proposed.checkpointedAt = wallTime
            proposedAnchor = nil
        default:
            return false
        }
        guard proposed.steps.ingest(snapshot) else { return false }
        proposed.revision += 1
        try await persist(proposed, activeSince: proposedAnchor)
        return true
    }

    @discardableResult
    func pause(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil,
        isUserInitiated: Bool = true
    ) async throws -> OutdoorActivityCheckpoint {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        var proposed = try activeProposal(at: wallTime, monotonic: monotonic)
        proposed.phase = .paused
        proposed.steps.close(at: wallTime)
        proposed.route.breakForUserPause(markEndpoint: isUserInitiated)
        proposed.revision += 1
        try await persist(proposed, activeSince: nil)
        return proposed
    }

    @discardableResult
    func resume(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws -> OutdoorActivityCheckpoint {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        guard blockedCandidate == nil else { throw OutdoorRecorderError.storageRetryRequired }
        guard var proposed = checkpoint else { throw OutdoorRecorderError.noActivity }
        switch proposed.phase {
        case .paused:
            proposed.route.breakForUserPause(markEndpoint: false)
        case .recording where activeSince == nil:
            // A process interruption has unobserved route coverage.
            proposed.route.noteLocationGap()
            proposed.steps.close(at: proposed.checkpointedAt)
        default:
            throw OutdoorRecorderError.notResumable
        }
        _ = proposed.steps.begin(at: wallTime)
        proposed.phase = .recording
        proposed.checkpointedAt = wallTime
        proposed.revision += 1
        try await persist(proposed, activeSince: monotonic)
        return proposed
    }

    @discardableResult
    func finish(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant? = nil
    ) async throws -> OutdoorFinishResult {
        await beginOperation()
        defer { endOperation() }
        let monotonic = monotonic ?? .now
        guard blockedCandidate == nil else { throw OutdoorRecorderError.storageRetryRequired }
        guard var proposed = checkpoint else { throw OutdoorRecorderError.noActivity }
        switch proposed.phase {
        case .recording:
            // A restored recording has no live clock anchor. Finish only the
            // last acknowledged interval; never invent time while the app was gone.
            if let activeSince {
                proposed.confirmedActiveSeconds += try elapsedSeconds(from: activeSince, to: monotonic)
                proposed.steps.close(at: wallTime)
            } else {
                proposed.route.noteLocationGap()
                proposed.steps.close(at: proposed.checkpointedAt)
            }
        case .paused:
            break
        case .readyToSave:
            return try await completeFinish(proposed)
        }
        proposed.phase = .readyToSave
        proposed.finishedAt = wallTime
        proposed.checkpointedAt = wallTime
        proposed.revision += 1
        guard proposed.isValid else { throw OutdoorRecorderError.invalidCheckpoint }
        return try await completeFinish(proposed)
    }

    /// Retries one frozen failed write. Recording never resumes automatically after it.
    @discardableResult
    func retryStorage(at wallTime: Date) async throws -> OutdoorRecorderState {
        await beginOperation()
        defer { endOperation() }
        guard let proposed = blockedCandidate ?? checkpoint else { throw OutdoorRecorderError.noActivity }
        if proposed.phase == .readyToSave {
            _ = try await completeFinish(proposed)
            return state()
        }
        guard blockedCandidate != nil else { throw OutdoorRecorderError.storageRetryRequired }
        try await repository.saveCheckpoint(proposed)
        checkpoint = proposed
        blockedCandidate = nil
        activeSince = nil
        if proposed.phase == .recording {
            var paused = proposed
            paused.phase = .paused
            paused.checkpointedAt = wallTime
            paused.revision += 1
            paused.route.noteLocationGap()
            paused.steps.close(at: proposed.checkpointedAt)
            try await persist(paused, activeSince: nil)
        }
        return state()
    }

    private func activeProposal(
        at wallTime: Date,
        monotonic: ContinuousClock.Instant
    ) throws -> OutdoorActivityCheckpoint {
        guard blockedCandidate == nil else { throw OutdoorRecorderError.storageRetryRequired }
        guard var proposed = checkpoint, proposed.phase == .recording,
              let activeSince else { throw OutdoorRecorderError.notRecording }
        proposed.confirmedActiveSeconds += try elapsedSeconds(from: activeSince, to: monotonic)
        proposed.checkpointedAt = wallTime
        guard proposed.isValid else { throw OutdoorRecorderError.invalidCheckpoint }
        return proposed
    }

    private func elapsedSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) throws -> TimeInterval {
        guard end >= start else { throw OutdoorRecorderError.clockRegression }
        let components = start.duration(to: end).components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds.isFinite, seconds >= 0 else { throw OutdoorRecorderError.clockRegression }
        return seconds
    }

    private func persist(
        _ proposed: OutdoorActivityCheckpoint,
        activeSince newAnchor: ContinuousClock.Instant?
    ) async throws {
        guard proposed.isValid else { throw OutdoorRecorderError.invalidCheckpoint }
        do {
            try await repository.saveCheckpoint(proposed)
            checkpoint = proposed
            activeSince = newAnchor
            blockedCandidate = nil
        } catch {
            blockedCandidate = proposed
            activeSince = nil
            throw error
        }
    }

    private func completeFinish(_ proposed: OutdoorActivityCheckpoint) async throws -> OutdoorFinishResult {
        // Freeze in-memory recording before the first storage suspension point.
        checkpoint = proposed
        activeSince = nil
        do {
            let result = try await repository.finish(proposed)
            checkpoint = nil
            activeSince = nil
            blockedCandidate = nil
            return result
        } catch {
            blockedCandidate = proposed
            activeSince = nil
            throw error
        }
    }

    /// Actor isolation alone is insufficient while a repository write suspends.
    /// Queue writers in arrival order instead of dropping a genuine sensor update
    /// or misreporting normal GPS/step overlap as a storage failure.
    /// The default monotonic instant is sampled after acquiring the gate; explicit
    /// instants remain available for deterministic clock-regression tests.
    private func beginOperation() async {
        shareRevocationRegistration?.revokeBeforeChange()
        if operationInFlight {
            await withCheckedContinuation { continuation in
                waitingOperations.append(continuation)
            }
        }
        // A queued operation may acquire a different registration after its await.
        shareRevocationRegistration?.revokeBeforeChange()
        operationInFlight = true
    }

    private func endOperation() {
        shareRevocationRegistration?.revokeBeforeChange()
        if waitingOperations.isEmpty {
            operationInFlight = false
        } else {
            // Retain the gate while handing ownership to the next queued writer.
            waitingOperations.removeFirst().resume()
        }
    }
}
