import Foundation

/// Sleep (proof 19): last night's stages, the week, bedtimes and nights over the
/// person's own goal. Values are what Apple Health recorded; 01 never scores recovery.
enum SleepStage: String, Codable, Sendable { case awake, core, deep, rem, asleep }

struct SleepSegment: Equatable, Sendable {
    let stage: SleepStage
    let start: Date
    let end: Date
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct SleepNight: Equatable, Sendable {
    /// The day the person woke up on.
    let wakeDay: Date
    let segments: [SleepSegment]

    var asleep: [SleepSegment] { segments.filter { $0.stage != .awake } }
    var hasData: Bool { !asleep.isEmpty }

    /// Overlapping samples from several sources count once.
    var asleepSeconds: TimeInterval {
        let ordered = asleep.sorted { $0.start < $1.start }
        guard var current = ordered.first.map({ DateInterval(start: $0.start, end: max($0.start, $0.end)) }) else { return 0 }
        var total: TimeInterval = 0
        for segment in ordered.dropFirst() {
            if segment.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, segment.end))
            } else {
                total += current.duration
                current = DateInterval(start: segment.start, end: max(segment.start, segment.end))
            }
        }
        return total + current.duration
    }

    var fellAsleep: Date? { asleep.map(\.start).min() }
    var wokeUp: Date? { asleep.map(\.end).max() }
}

struct SleepWeek: Equatable, Sendable {
    /// Seven nights, oldest first, the last one is last night.
    let nights: [SleepNight]

    var lastNight: SleepNight? { nights.last }
    private var recorded: [SleepNight] { nights.filter(\.hasData) }

    var averageSeconds: TimeInterval? {
        let recorded = recorded
        guard !recorded.isEmpty else { return nil }
        return recorded.reduce(0) { $0 + $1.asleepSeconds } / Double(recorded.count)
    }

    func nightsOver(goalMinutes: Int) -> (met: Int, recorded: Int) {
        (recorded.filter { $0.asleepSeconds >= Double(goalMinutes) * 60 }.count, recorded.count)
    }

    /// Earliest and latest time they fell asleep, as minutes after noon so that
    /// 23:10 and 00:20 compare the right way round.
    func bedtimeRange(calendar: Calendar) -> (earliest: Date, latest: Date)? {
        let times = recorded.compactMap(\.fellAsleep)
        func afterNoon(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return ((parts.hour ?? 0) * 60 + (parts.minute ?? 0) + 12 * 60) % (24 * 60)
        }
        guard let earliest = times.min(by: { afterNoon($0) < afterNoon($1) }),
              let latest = times.max(by: { afterNoon($0) < afterNoon($1) }) else { return nil }
        return (earliest, latest)
    }

    /// Groups raw samples into the seven nights ending on `today`. A sample belongs
    /// to the night whose window (18:00 the evening before to 12:00) holds its start.
    static func make(samples: [SleepSegment], today: Date, calendar: Calendar) -> SleepWeek {
        let todayStart = calendar.startOfDay(for: today)
        let nights: [SleepNight] = (0 ..< 7).reversed().compactMap { back in
            guard let wakeDay = calendar.date(byAdding: .day, value: -back, to: todayStart),
                  let windowStart = calendar.date(byAdding: .hour, value: -6, to: wakeDay),
                  let windowEnd = calendar.date(byAdding: .hour, value: 12, to: wakeDay) else { return nil }
            let inWindow = samples.filter { $0.start >= windowStart && $0.start < windowEnd && $0.end > $0.start }
                .sorted { $0.start < $1.start }
            return SleepNight(wakeDay: wakeDay, segments: inWindow)
        }
        return SleepWeek(nights: nights)
    }
}

enum SleepGoal {
    static let key = "01.sleep.goalMinutes"
    /// 7 h 30 until the person picks their own; 01 does not prescribe sleep.
    static let defaultMinutes = 450
    static let range = 300 ... 600
}

protocol SleepHistoryReading {
    func readSleepWeek(endingAt date: Date) async throws -> SleepWeek
}
