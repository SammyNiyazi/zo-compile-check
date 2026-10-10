import SwiftUI

/// Functional acceptance flow. Final visual design remains founder-owned.
struct WorkoutDemandProposalView: View {
    let proposal: WorkoutDemandAdaptationProposal
    let isChecking: Bool
    let error: WorkoutDemandAdaptationError?
    let onApply: () -> Void
    let onKeepOriginal: () -> Void
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        NavigationStack {
            Form {
                Section("Current check-in") {
                    ForEach(proposal.concerns) { concern in
                        Text(localization.string(concern.message.titleKey)).zoText(.section)
                        Text(localization.string(concern.message.detailKey))
                    }
                }
                Section("Proposed workout") {
                    Text(localization.string(proposal.change.titleKey)).zoText(.section)
                    ForEach(Array(proposal.originalSession.exercises.enumerated()), id: \.element.id) { index, original in
                        let changed = proposal.adaptedSession.exercises[index].plan
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: original.plan.name).zoText(.section)
                            Text(localization.format("Working sets: %1$lld → %2$lld",
                                .integer(original.plan.plannedSetCount), .integer(changed.plannedSetCount)))
                            Text(localization.format("Prescribed rest: %1$@ → %2$@ seconds",
                                .text(original.plan.restSeconds.formatted(.number.locale(localization.locale))),
                                .text(changed.restSeconds.formatted(.number.locale(localization.locale)))))
                        }
                    }
                    Text("Load, rep and timed targets, exercise order and warm-up are kept.")
                        .zoText(.caption).foregroundStyle(.secondary)
                }
                Section("Estimated time") {
                    Text(localization.format("Before: %1$lld–%2$lld min · Proposed: %3$lld–%4$lld min",
                        .integer(Int(ceil(proposal.originalEstimate.minimumSeconds / 60))), .integer(proposal.originalEstimate.maximumMinutes),
                        .integer(Int(ceil(proposal.adaptedEstimate.minimumSeconds / 60))), .integer(proposal.adaptedEstimate.maximumMinutes)))
                    Text("Longer rests can take more time. This estimate does not promise a fit to your original time window.")
                        .zoText(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Only this active workout changes. Your saved programme, template and training days stay the same.")
                    Text("Resting today remains a choice. Longer rests do not reduce the working sets or establish that training is safe.")
                    Text("You can undo this adjustment before logging a working set.")
                    if let error { Text(localization.string(error.messageKey)).foregroundStyle(.red) }
                    Button("Apply to this workout", action: onApply).disabled(isChecking)
                    if isChecking { ProgressView("Checking current records") }
                    Button("Keep this workout", action: onKeepOriginal).disabled(isChecking)
                }
            }
            .navigationTitle("Review workout adjustment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onKeepOriginal).disabled(isChecking)
                }
            }
        }
        .interactiveDismissDisabled(isChecking)
    }
}
