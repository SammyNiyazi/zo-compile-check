import Foundation

/// Observed timer transitions only. A countdown does not measure physical rest,
/// sleep, recovery or the time spent performing the next set.
struct WorkoutRestTimerObservation: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumEvents = 512
    let version: Int
    let afterSetID: UUID
    private(set) var events: [WorkoutRestTimerEvent]
    private(set) var hasOmittedTransitions: Bool

    init(afterSetID: UUID, at date: Date, deadline: Date?) {
        version = Self.currentVersion
        self.afterSetID = afterSetID
        events = [.init(kind: deadline == nil ? .notScheduled : .started,
            observedAt: date, deadline: deadline,
            remainingSeconds: deadline.map { max(0, $0.timeIntervalSince(date)) })]
        hasOmittedTransitions = false
    }

    var isClosed: Bool { events.last?.kind.isTerminal == true }
    var hasUnobservedGap: Bool {
        hasOmittedTransitions || events.contains { event in
            [.recovered, .restartedAfterSaveFailure, .restartedWhilePaused, .clockDiscontinuity].contains(event.kind)
                || (event.kind == .expired && event.deadline.map({ event.observedAt > $0 }) == true)
        }
    }
    var isPaused: Bool {
        guard !isClosed else { return false }
        let kind = events.last(where: { [.started, .paused, .extendedWhilePaused, .resumed, .restartedAfterSaveFailure, .restartedWhilePaused].contains($0.kind) })?.kind
        return kind == .paused || kind == .extendedWhilePaused || kind == .restartedWhilePaused
    }
    var precisePausedRemainingSeconds: TimeInterval? {
        guard isPaused else { return nil }
        return events.last(where: { $0.remainingSeconds != nil })?.remainingSeconds
    }

    mutating func record(_ kind: WorkoutRestTimerEvent.Kind, at date: Date,
                         deadline: Date?, remainingSeconds: TimeInterval? = nil) {
        guard (!isClosed || kind == .restartedWhilePaused), date.timeIntervalSinceReferenceDate.isFinite else { return }
        if let previous = events.last, date < previous.observedAt {
            append(.init(kind: .clockDiscontinuity, observedAt: date, deadline: nil, remainingSeconds: nil))
        }
        append(.init(kind: kind, observedAt: date, deadline: deadline, remainingSeconds: remainingSeconds))
    }

    private mutating func append(_ event: WorkoutRestTimerEvent) {
        events.append(event)
        if events.count > Self.maximumEvents {
            // Keep the origin and the latest endpoint; lost middle transitions
            // explicitly prevent this journal being treated as complete coverage.
            events.remove(at: 1)
            hasOmittedTransitions = true
        }
    }

    func isValid(for setID: UUID, completedAt: Date) -> Bool {
        guard version == Self.currentVersion, afterSetID == setID,
              (1...Self.maximumEvents).contains(events.count),
              events.first?.observedAt == completedAt,
              events.first?.kind == .started || events.first?.kind == .notScheduled,
              events.allSatisfy(\.isValid) else { return false }
        var paused = false
        var closed = false
        var deadline: Date?
        var pausedRemaining: TimeInterval?
        func sameSeconds(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 0.000_001 }
        for (index, event) in events.enumerated() {
            // Missing transitions may include clock/state changes. Keep the raw
            // bounded facts without claiming a complete temporal reconstruction.
            if hasOmittedTransitions { continue }
            if index > 0, event.observedAt < events[index - 1].observedAt,
               event.kind != .clockDiscontinuity { return false }
            if closed && event.kind != .restartedWhilePaused && event.kind != .clockDiscontinuity { return false }
            switch event.kind {
            case .started:
                if index != 0 { return false }
                deadline = event.deadline
            case .paused:
                guard !paused, event.deadline == deadline, let deadline, let remaining = event.remainingSeconds,
                      sameSeconds(remaining, max(0, deadline.timeIntervalSince(event.observedAt))) else { return false }
                paused = true
                pausedRemaining = event.remainingSeconds
            case .resumed:
                guard paused, event.remainingSeconds == pausedRemaining else { return false }
                paused = false
                deadline = event.deadline
                pausedRemaining = nil
            case .restartedAfterSaveFailure:
                paused = false
                deadline = event.deadline
                pausedRemaining = nil
            case .restartedWhilePaused:
                guard closed, event.deadline == nil else { return false }
                closed = false
                paused = true
                pausedRemaining = event.remainingSeconds
                deadline = nil
            case .notScheduled:
                if index != 0 { return false }
                closed = true
            case .expired:
                guard !paused, event.deadline == deadline, let deadline, event.observedAt >= deadline else { return false }
                closed = true
            case .extended, .shortened:
                guard let remaining = event.remainingSeconds else { return false }
                if paused {
                    guard event.deadline == deadline else { return false }
                    pausedRemaining = remaining
                } else {
                    guard let updated = event.deadline,
                          sameSeconds(remaining, max(0, updated.timeIntervalSince(event.observedAt))) else { return false }
                    deadline = updated
                }
            case .extendedWhilePaused:
                guard paused, event.deadline == deadline else { return false }
                pausedRemaining = event.remainingSeconds
            case .skipped, .handoffAcknowledged, .workoutEnded:
                guard event.deadline == deadline else { return false }
                closed = true
            case .recovered:
                guard event.deadline == deadline else { return false }
            case .clockDiscontinuity: break
            }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey { case version, afterSetID, events, hasOmittedTransitions }
    init(from decoder: Decoder) throws {
        try RestTimerCodingKey.rejectUnknown(decoder, allowed: ["version", "afterSetID", "events", "hasOmittedTransitions"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        afterSetID = try values.decode(UUID.self, forKey: .afterSetID)
        events = try values.decode([WorkoutRestTimerEvent].self, forKey: .events)
        hasOmittedTransitions = try values.decode(Bool.self, forKey: .hasOmittedTransitions)
    }
}

struct WorkoutRestTimerEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case started, paused, resumed, extended, extendedWhilePaused, shortened
        case skipped, expired, handoffAcknowledged, workoutEnded, notScheduled
        case recovered, restartedAfterSaveFailure, restartedWhilePaused, clockDiscontinuity
        var isTerminal: Bool {
            [.skipped, .expired, .handoffAcknowledged, .workoutEnded, .notScheduled].contains(self)
        }
    }
    let kind: Kind
    let observedAt: Date
    let deadline: Date?
    let remainingSeconds: TimeInterval?

    init(kind: Kind, observedAt: Date, deadline: Date?, remainingSeconds: TimeInterval?) {
        self.kind = kind
        self.observedAt = observedAt
        self.deadline = deadline
        self.remainingSeconds = remainingSeconds
    }

    var isValid: Bool {
        func validDate(_ date: Date) -> Bool {
            let value = date.timeIntervalSinceReferenceDate
            return value.isFinite && (-62_000_000_000...100_000_000_000).contains(value)
        }
        guard validDate(observedAt), deadline.map(validDate) ?? true,
              remainingSeconds.map({ $0.isFinite && (0...604_800).contains($0) }) ?? true else { return false }
        switch kind {
        case .started, .resumed, .restartedAfterSaveFailure:
            guard let deadline, let remainingSeconds else { return false }
            return remainingSeconds > 0 && abs(deadline.timeIntervalSince(observedAt) - remainingSeconds) < 0.000_001
        case .restartedWhilePaused: return deadline == nil && remainingSeconds.map({ $0 > 0 }) == true
        case .paused: return remainingSeconds != nil
        case .expired: return deadline != nil
        case .notScheduled, .clockDiscontinuity: return deadline == nil && remainingSeconds == nil
        case .extended, .extendedWhilePaused, .shortened: return remainingSeconds != nil
        case .skipped, .handoffAcknowledged, .workoutEnded, .recovered: return true
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, observedAt, deadline, remainingSeconds }
    init(from decoder: Decoder) throws {
        try RestTimerCodingKey.rejectUnknown(decoder, allowed: ["kind", "observedAt", "deadline", "remainingSeconds"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        deadline = try values.decodeIfPresent(Date.self, forKey: .deadline)
        remainingSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .remainingSeconds)
    }
}

private struct RestTimerCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported rest-timer observation fields."))
        }
    }
}
