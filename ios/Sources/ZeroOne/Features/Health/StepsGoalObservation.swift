import Foundation

/// Valid visible facts from a successful foreground query. This is newly observed
/// attainment, never the physical time a person walked across a threshold.
struct StepsGoalObservation: Equatable, Sendable {
    struct Context: Hashable, Sendable {
        let calendar: Calendar
        let day: DateInterval
        let goal: Int
    }

    let context: Context
    let readAt: Date
    let steps: Int

    init?(calendar: Calendar, now: Date, goal: Int?, readingDayStart: Date?,
          readAt: Date?, steps: Int?, isAvailable: Bool) {
        guard isAvailable, let goal, goal > 0, let steps, steps >= 0,
              let readAt, readAt <= now, let readingDayStart,
              let day = calendar.dateInterval(of: .day, for: now),
              readingDayStart == day.start, readAt >= day.start, readAt < day.end else { return nil }
        context = Context(calendar: calendar, day: day, goal: goal)
        self.readAt = readAt
        self.steps = steps
    }

    var attained: Bool { steps >= context.goal }
    var progress: Double { min(1, Double(steps) / Double(context.goal)) }
}

/// Pure retained presentation gate. A ticket surrounds an actual awaited query,
/// so failure/recovery is inspected even if SwiftUI coalesces rendered states.
/// The owning view invalidates it on disappearance, scene/context or source gaps.
struct StepsGoalObservationGate {
    struct Ticket {
        fileprivate let id: UUID
        fileprivate let before: StepsGoalObservation?
        fileprivate let mayCelebrate: Bool
    }

    struct Attainment {
        let id: UUID
        let context: StepsGoalObservation.Context
        let fromProgress: Double
        /// Health query-at timestamp, not its completion or physical crossing time.
        let observedReadAt: Date
    }

    private var baseline: StepsGoalObservation?
    private var pending: UUID?
    private var attainedContexts: Set<StepsGoalObservation.Context> = []

    mutating func begin(_ current: StepsGoalObservation?, allowCelebration: Bool) -> Ticket {
        let id = UUID()
        let continuous = baseline == current && current != nil
        // A changed or initially loaded snapshot seeds facts without earning a win.
        baseline = current
        if let current, current.attained { attainedContexts.insert(current.context) }
        pending = id
        return Ticket(id: id, before: current, mayCelebrate: allowCelebration && continuous)
    }

    mutating func complete(_ ticket: Ticket, with after: StepsGoalObservation?) -> Attainment? {
        guard pending == ticket.id else { return nil }
        pending = nil
        guard let after else { baseline = nil; return nil }
        let wasAttained = attainedContexts.contains(after.context)
        if after.attained { attainedContexts.insert(after.context) }
        guard let before = ticket.before, before.context == after.context,
              after.readAt > before.readAt else {
            // Recovery/new-day/clock regression has no qualifying predecessor.
            if let before = ticket.before, before.context == after.context {
                baseline = after == before ? before : nil
            }
            else { baseline = after }
            return nil
        }
        baseline = after
        guard ticket.mayCelebrate, !wasAttained, !before.attained, after.attained else { return nil }
        return Attainment(id: UUID(), context: after.context,
                          fromProgress: before.progress, observedReadAt: after.readAt)
    }

    /// Retain known attained contexts through gaps so returning/correction cannot
    /// replay the same observed achievement. No persisted goal policy is created.
    mutating func invalidate() {
        baseline = nil
        pending = nil
    }
}
