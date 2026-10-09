import Foundation

struct OutdoorStepSnapshot: Equatable, Sendable {
    let intervalID: UUID
    let sampleStartedAt: Date
    let sampleEndedAt: Date
    let cumulativeSteps: Int
    let isFinal: Bool
}

struct OutdoorStepInterval: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var lastSampleAt: Date?
    var latestCumulativeSteps: Int?
    var isFinal = false
}

/// CMPedometer counts are cumulative from one interval's start. Each update
/// replaces its prior value; only disjoint user-active intervals are summed.
struct OutdoorStepAccumulator: Codable, Equatable, Sendable {
    private(set) var intervals: [OutdoorStepInterval] = []
    private(set) var hasClockDiscontinuity = false

    var activeInterval: OutdoorStepInterval? {
        guard let last = intervals.last, last.endedAt == nil else { return nil }
        return last
    }

    var recordedSteps: Int? {
        var total: Int?
        for interval in intervals {
            guard let count = interval.latestCumulativeSteps else { continue }
            let (sum, overflow) = (total ?? 0).addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    var hasIncompleteCoverage: Bool {
        hasClockDiscontinuity || intervals.contains { !$0.isFinal }
    }

    var isInternallyConsistent: Bool {
        guard Set(intervals.map(\.id)).count == intervals.count else { return false }
        var priorEnd: Date?
        var total = 0
        for (index, interval) in intervals.enumerated() {
            guard interval.startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
            if let priorEnd, interval.startedAt < priorEnd { return false }
            if let end = interval.endedAt {
                guard end.timeIntervalSinceReferenceDate.isFinite, end >= interval.startedAt else { return false }
                priorEnd = end
            } else if index != intervals.count - 1 || interval.isFinal {
                return false
            }
            if let count = interval.latestCumulativeSteps {
                guard count >= 0, interval.lastSampleAt != nil else { return false }
                let (sum, overflow) = total.addingReportingOverflow(count)
                guard !overflow else { return false }
                total = sum
            } else if interval.lastSampleAt != nil || interval.isFinal {
                return false
            }
            if let sampleAt = interval.lastSampleAt {
                guard sampleAt.timeIntervalSinceReferenceDate.isFinite,
                      sampleAt >= interval.startedAt,
                      sampleAt <= (interval.endedAt ?? .distantFuture) else { return false }
            }
            if interval.isFinal, interval.endedAt == nil { return false }
        }
        return true
    }

    @discardableResult
    mutating func begin(at date: Date, id: UUID = UUID()) -> UUID? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              activeInterval == nil else { return nil }
        if let end = intervals.last?.endedAt, date < end {
            hasClockDiscontinuity = true
            return nil
        }
        intervals.append(OutdoorStepInterval(id: id, startedAt: date))
        return id
    }

    mutating func close(at date: Date) {
        guard let index = intervals.indices.last, intervals[index].endedAt == nil else { return }
        let start = intervals[index].startedAt
        if date < start || !date.timeIntervalSinceReferenceDate.isFinite {
            hasClockDiscontinuity = true
            intervals[index].endedAt = start
            intervals[index].lastSampleAt = nil
            intervals[index].latestCumulativeSteps = nil
        } else {
            intervals[index].endedAt = date
            if let lastSampleAt = intervals[index].lastSampleAt, lastSampleAt > date {
                // A wall-clock change can put a live sample beyond the close
                // boundary. Keep the interval but do not claim that sample.
                hasClockDiscontinuity = true
                intervals[index].lastSampleAt = nil
                intervals[index].latestCumulativeSteps = nil
                intervals[index].isFinal = false
            }
        }
    }

    /// A late live callback is rejected after Close. A final query for exactly
    /// the closed interval may replace the last live estimate before Finish.
    @discardableResult
    mutating func ingest(_ snapshot: OutdoorStepSnapshot) -> Bool {
        guard let index = intervals.firstIndex(where: { $0.id == snapshot.intervalID }),
              !intervals[index].isFinal,
              snapshot.cumulativeSteps >= 0,
              snapshot.sampleStartedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.sampleEndedAt.timeIntervalSinceReferenceDate.isFinite,
              abs(snapshot.sampleStartedAt.timeIntervalSince(intervals[index].startedAt)) <= 1,
              snapshot.sampleEndedAt >= intervals[index].startedAt,
              snapshot.sampleEndedAt <= (intervals[index].endedAt ?? .distantFuture),
              snapshot.sampleEndedAt >= (intervals[index].lastSampleAt ?? intervals[index].startedAt) else {
            return false
        }
        if snapshot.isFinal {
            guard intervals[index].endedAt != nil else { return false }
        } else {
            guard intervals[index].endedAt == nil else { return false }
            if let prior = intervals[index].latestCumulativeSteps,
               snapshot.cumulativeSteps < prior { return false }
        }
        var total = snapshot.cumulativeSteps
        for (otherIndex, interval) in intervals.enumerated() where otherIndex != index {
            guard let count = interval.latestCumulativeSteps else { continue }
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return false }
            total = sum
        }
        let prior = intervals[index]
        intervals[index].lastSampleAt = snapshot.sampleEndedAt
        intervals[index].latestCumulativeSteps = snapshot.cumulativeSteps
        intervals[index].isFinal = snapshot.isFinal
        return intervals[index] != prior
    }
}
