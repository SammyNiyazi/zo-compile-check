import Foundation

/// Local continuous time, never a wall-clock estimate or cross-launch clock claim.
struct WorkoutElapsedClockReading: Codable, Equatable, Sendable {
    let continuityID: UUID
    let seconds: TimeInterval
    let observedAt: Date

    var isValid: Bool {
        seconds.isFinite && seconds >= 0 && observedAt.timeIntervalSinceReferenceDate.isFinite
    }

    init(continuityID: UUID, seconds: TimeInterval, observedAt: Date) {
        self.continuityID = continuityID
        self.seconds = seconds
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case continuityID, seconds, observedAt
    }

    init(from decoder: Decoder) throws {
        try ElapsedEvidenceCodingKey.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        continuityID = try values.decode(UUID.self, forKey: .continuityID)
        seconds = try values.decode(TimeInterval.self, forKey: .seconds)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        guard isValid else { throw WorkoutPersistenceError.invalidSnapshot }
    }
}

/// The UUID identifies this exact origin. Recreating a VM does not create a clock origin.
/// ContinuousClock includes sleep; its values are intentionally not compared across launches.
struct WorkoutElapsedClock {
    let read: () -> WorkoutElapsedClockReading
    private static let origin = (id: UUID(), instant: ContinuousClock.now)

    static var continuous: Self {
        Self {
            let origin = Self.origin
            let duration = origin.instant.duration(to: ContinuousClock.now).components
            return WorkoutElapsedClockReading(continuityID: origin.id,
                seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                observedAt: .now)
        }
    }
}

/// Session time including warm-up, rest and background time, less intentional pauses.
/// This is not exercise effort. Only an explicitly accepted new start creates evidence.
struct WorkoutElapsedEvidence: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, paused, stopped }

    let version: Int
    let sessionID: UUID
    let acceptedStart: WorkoutElapsedClockReading
    let lastTransition: WorkoutElapsedClockReading
    let accumulatedPauseSeconds: TimeInterval
    let state: State

    static func started(sessionID: UUID, at reading: WorkoutElapsedClockReading) -> Self? {
        guard reading.isValid else { return nil }
        return Self(version: 1, sessionID: sessionID, acceptedStart: reading,
            lastTransition: reading, accumulatedPauseSeconds: 0, state: .running)
    }

    var isValid: Bool {
        version == 1 && acceptedStart.isValid && lastTransition.isValid
            && acceptedStart.continuityID == lastTransition.continuityID
            && lastTransition.seconds >= acceptedStart.seconds
            && accumulatedPauseSeconds.isFinite && accumulatedPauseSeconds >= 0
            && accumulatedPauseSeconds <= lastTransition.seconds - acceptedStart.seconds
    }

    func matches(sessionID: UUID, isPaused: Bool, isComplete: Bool) -> Bool {
        isValid && self.sessionID == sessionID
            && (state == .paused) == isPaused && (state == .stopped) == isComplete
    }

    func elapsed(at reading: WorkoutElapsedClockReading) -> TimeInterval? {
        guard isValid, reading.isValid,
              reading.continuityID == acceptedStart.continuityID,
              reading.seconds >= lastTransition.seconds else { return nil }
        let endpoint = state == .running ? reading.seconds : lastTransition.seconds
        let elapsed = endpoint - acceptedStart.seconds - accumulatedPauseSeconds
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return elapsed
    }

    func transitioning(to next: State, at reading: WorkoutElapsedClockReading) -> Self? {
        guard elapsed(at: reading) != nil, state != .stopped, next != state else { return nil }
        let paused = accumulatedPauseSeconds
            + (state == .paused ? reading.seconds - lastTransition.seconds : 0)
        let result = Self(version: version, sessionID: sessionID, acceptedStart: acceptedStart,
            lastTransition: reading, accumulatedPauseSeconds: paused, state: next)
        return result.isValid ? result : nil
    }

    private init(version: Int, sessionID: UUID, acceptedStart: WorkoutElapsedClockReading,
                 lastTransition: WorkoutElapsedClockReading, accumulatedPauseSeconds: TimeInterval,
                 state: State) {
        self.version = version
        self.sessionID = sessionID
        self.acceptedStart = acceptedStart
        self.lastTransition = lastTransition
        self.accumulatedPauseSeconds = accumulatedPauseSeconds
        self.state = state
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, sessionID, acceptedStart, lastTransition, accumulatedPauseSeconds, state
    }

    init(from decoder: Decoder) throws {
        try ElapsedEvidenceCodingKey.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        acceptedStart = try values.decode(WorkoutElapsedClockReading.self, forKey: .acceptedStart)
        lastTransition = try values.decode(WorkoutElapsedClockReading.self, forKey: .lastTransition)
        accumulatedPauseSeconds = try values.decode(TimeInterval.self, forKey: .accumulatedPauseSeconds)
        state = try values.decode(State.self, forKey: .state)
        guard isValid else { throw WorkoutPersistenceError.invalidSnapshot }
    }
}

private struct ElapsedEvidenceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported session elapsed evidence fields."))
        }
    }
}
