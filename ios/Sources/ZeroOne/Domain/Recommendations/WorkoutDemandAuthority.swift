import Foundation
import Observation

/// The host owns fresh store reads, including asynchronous outdoor history.
/// Rendering a cached assessment cannot authorise an active prescription change.
@MainActor @Observable
final class WorkoutDemandAuthority {
    @ObservationIgnored private var source: (@MainActor (Date, Calendar) async -> WellbeingAssessment?)?

    func install(source: @escaping @MainActor (Date, Calendar) async -> WellbeingAssessment?) {
        self.source = source
    }

    func assessment(at now: Date = .now, calendar: Calendar = .current) async -> WellbeingAssessment? {
        guard now.timeIntervalSinceReferenceDate.isFinite, let source else { return nil }
        let result = await source(now, calendar)
        guard result?.isCurrent(at: now, calendar: calendar) == true else { return nil }
        return result
    }
}
