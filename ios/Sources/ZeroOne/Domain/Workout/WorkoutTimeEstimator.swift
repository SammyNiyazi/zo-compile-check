import Foundation

/// A planning range, not a promise of completion time. Defaults are explicit
/// product heuristics until actual timing can calibrate them for a person.
struct WorkoutTimeEstimate: Equatable, Sendable {
    let minimumSeconds: TimeInterval
    let maximumSeconds: TimeInterval

    var maximumMinutes: Int { Int(ceil(maximumSeconds / 60)) }

    func fitsWithin(minutes: Int) -> Bool {
        minutes > 0 && maximumSeconds <= Double(minutes) * 60
    }
}

struct WorkoutTimeEstimator: Sendable {
    static let policyVersion = "workout-time-v1"

    func estimate(for session: WorkoutSession) -> WorkoutTimeEstimate? {
        estimate(plans: session.exercises.map(\.plan), warmUp: session.warmUp)
    }

    func estimate(plans: [ExercisePlan], warmUp: WorkoutWarmUp?) -> WorkoutTimeEstimate? {
        guard !plans.isEmpty, plans.count <= 50 else { return nil }
        let warmUpMinutes = warmUp?.length == WorkoutWarmUpLength.none ? 0 : (warmUp?.estimatedMinutes ?? 0)
        guard (0 ... 60).contains(warmUpMinutes) else { return nil }
        var minimum = Double(warmUpMinutes) * 60
        var maximum = minimum

        for (index, plan) in plans.enumerated() {
            guard (1 ... 100).contains(plan.plannedSetCount), plan.prescription.isValid,
                  plan.restSeconds.isFinite, (0 ... 3_600).contains(plan.restSeconds) else { return nil }
            let prescription = plan.prescription
            let sides = prescription.perSide ? 2.0 : 1.0
            let sets = Double(plan.plannedSetCount)
            // Rep pace varies; timed work is its actual authored duration range.
            let lowerPace = prescription.unit == .seconds ? 1.0 : 2.0
            let upperPace = prescription.unit == .seconds ? 1.0 : 4.0
            minimum += Double(prescription.lowerBound) * lowerPace * sides * sets
            maximum += Double(prescription.upperBound) * upperPace * sides * sets
            // The execution flow rests between sets and between exercises, but
            // not after the final working set of the whole workout.
            let restCount = plan.plannedSetCount - (index == plans.count - 1 ? 1 : 0)
            minimum += Double(restCount) * plan.restSeconds
            maximum += Double(restCount) * plan.restSeconds
        }
        minimum += Double(plans.count - 1) * 30
        maximum += Double(plans.count - 1) * 60
        guard minimum.isFinite, maximum.isFinite, maximum >= minimum,
              maximum <= Double(Int.max) / 2 else { return nil }
        return WorkoutTimeEstimate(minimumSeconds: minimum, maximumSeconds: maximum)
    }
}
