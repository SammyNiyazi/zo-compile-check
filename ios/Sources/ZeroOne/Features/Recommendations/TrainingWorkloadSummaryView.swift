import SwiftUI

/// The same assessment is presented in Progress and the recovery review.
/// Final visual-system ownership stays with the founder's design package.
struct TrainingWorkloadSummaryView: View {
    let assessment: TrainingWorkloadAssessment
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded workload").zoText(.section)
            Text("Last seven days, including today").zoText(.label).foregroundStyle(.secondary)
            if let current = assessment.currentStrength, let previous = assessment.previousStrength {
                row("Working sets", current: current.recordedSetCount, previous: previous.recordedSetCount)
                Text(localization.format("Effort reported for %1$lld of %2$lld repetition sets.",
                    .integer(current.effortReportedSetCount), .integer(current.repetitionSetCount)))
                    .zoText(.caption).foregroundStyle(.secondary)
                Text(localization.format("%1$lld sets reported 0 or 1 repetitions in reserve.", .integer(current.lowReserveSetCount)))
                    .zoText(.caption).foregroundStyle(.secondary)
                if current.summaryOnlySessionCount > 0 || previous.summaryOnlySessionCount > 0 {
                    Text("Some workouts have counts only; their effort is unknown.").zoText(.caption)
                }
            } else { Text("Strength records unavailable").zoText(.label) }
            if let current = assessment.currentOutdoor, let previous = assessment.previousOutdoor {
                row("Recorded run minutes", current: Int(current.runs.unpausedSeconds / 60), previous: Int(previous.runs.unpausedSeconds / 60))
                row("Recorded walk minutes", current: Int(current.walks.unpausedSeconds / 60), previous: Int(previous.walks.unpausedSeconds / 60))
                Text("Run and walk time is unpaused recorder time, not measured moving time or intensity.")
                    .zoText(.caption).foregroundStyle(.secondary)
                if [current.runs, current.walks, previous.runs, previous.walks].contains(where: {
                    $0.partialDistanceSessionCount > 0 || $0.unknownDistanceSessionCount > 0
                }) {
                    Text("Some routes are partial or have no recorded distance. No pace comparison is made.").zoText(.caption)
                }
                if current.runs.clockDiscrepancySessionCount + current.walks.clockDiscrepancySessionCount
                    + previous.runs.clockDiscrepancySessionCount + previous.walks.clockDiscrepancySessionCount > 0 {
                    Text("Unpaused time is retained where wall-clock timestamps disagree. Those records are excluded from training-day screening.")
                        .zoText(.caption)
                }
            } else { Text("Run and walk records unavailable").zoText(.label) }
            if assessment.excludedStrengthRecordCount > 0 || assessment.excludedOutdoorRecordCount > 0 {
                Text("Conflicting, invalid or future records were left out.").zoText(.caption)
            }
            if assessment.hasRepeatedComparableDecline {
                Text("Repeated decline in comparable saved repetitions").zoText(.label)
                Text("Review recovery and whether your exercise conditions changed. This pattern alone does not establish poor recovery.")
                    .zoText(.caption).foregroundStyle(.secondary)
            }
            Text("Strength-session duration and actual rest are not recorded.").zoText(.caption).foregroundStyle(.secondary)
            Text("These are saved records, not a complete account of your activity. Today's window is unfinished.")
                .zoText(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: LocalizedStringKey, current: Int, previous: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).zoText(.label)
            Text(localization.format("%1$lld now · %2$lld previous", .integer(current), .integer(previous)))
                .zoText(.label).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
