import SwiftUI

struct ProgrammeVolumeReviewView: View {
    let initialChange: ProgrammeVolumeChange
    let onPrepare: @MainActor (ProgrammeVolumeChange) async throws -> ProgrammeVolumeProposal
    let onApply: @MainActor (ProgrammeVolumeProposal) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    @State private var change = ProgrammeVolumeChange.ease
    @State private var proposal: ProgrammeVolumeProposal?
    @State private var errorKey: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text("Review future programme sets").zoText(.display)
                    Picker("Programme option", selection: $change) {
                        ForEach(ProgrammeVolumeChange.allCases, id: \.self) { option in
                            Text(localization.string(option.titleKey)).tag(option)
                        }
                    }
                    .onChange(of: change) { _, _ in proposal = nil; errorKey = nil }
                    Text("Only future preset sessions change. Exercise order, targets, rest, training days and appointments stay. The change remains until you review it again.")
                        .foregroundStyle(theme.textSecondary)
                    Button("Review this programme option") { Task { await prepare() } }
                    if let proposal {
                        if let before = proposal.before {
                            Text(localization.format("%1$lld to %2$lld working sets per full rotation",
                                .integer(before.totalSetsPerRotation), .integer(proposal.after.totalSetsPerRotation)))
                                .zoText(.section)
                        } else {
                            Text("The old adjustment no longer matches this programme. Its previous set counts are unknown. Removing it uses the current authored counts and may increase training demand.")
                            Text(localization.format("Current authored working sets per full rotation: %1$lld", .integer(proposal.after.totalSetsPerRotation)))
                                .zoText(.section)
                        }
                        if proposal.weeklyTrainingDays != nil {
                            Text("Average planned weekly exposure").zoText(.title)
                        } else {
                            Text("Planned sets per full rotation").zoText(.title)
                            Text("Weekly averages are unavailable without a verified matching training schedule. These counts cover one full rotation. This review does not change or repair calendar records.")
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                        Text("Primary and supporting-muscle sets are separate. These are planned counts, not measured stimulus or an optimal target. Muscle rows overlap; do not add them.")
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                        Text("Counts follow each plan's set convention; per-side work is not converted. Warm-up is excluded, conditioning is separate, and completed work is not changed.")
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                        let names = Set(proposal.before?.rows.map(\.muscle) ?? []).union(proposal.after.rows.map(\.muscle)).sorted()
                        ForEach(names, id: \.self) { name in
                            let before = proposal.before?.rows.first { $0.muscle == name }
                            let after = proposal.after.rows.first { $0.muscle == name }
                            VStack(alignment: .leading, spacing: ZOSpace.s) {
                                Text(verbatim: localization.string(name)).zoText(.section)
                                Text(localization.format("Primary sets: %1$@ to %2$@", .text(priorValue(before?.primarySets ?? 0, proposal: proposal)),
                                    .text(displayedCount(after?.primarySets ?? 0, in: proposal.after, proposal: proposal))))
                                Text(localization.format("Supporting sets: %1$@ to %2$@", .text(priorValue(before?.supportingSets ?? 0, proposal: proposal)),
                                    .text(displayedCount(after?.supportingSets ?? 0, in: proposal.after, proposal: proposal))))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        Text(localization.format("Conditioning work sets per rotation: %1$@ to %2$lld",
                            .text(priorCount(proposal.before?.conditioningSets)), .integer(proposal.after.conditioningSets)))
                        Text(localization.format("Unclassified work sets per rotation: %1$@ to %2$lld",
                            .text(priorCount(proposal.before?.unclassifiedSets)), .integer(proposal.after.unclassifiedSets)))
                        if let days = proposal.weeklyTrainingDays {
                            Text(localization.format("Saved training days per week: %1$lld", .integer(days)))
                            Text("The weekly average assumes the saved training-day count and every session in the rotation. It is not a dated workout forecast or a record of completed work.")
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                    if let errorKey { Text(localization.string(errorKey)).foregroundStyle(theme.destructivePrimary) }
                    if isChecking { ProgressView("Checking current records") }
                }.padding(ZOSpace.xl)
            }.disabled(isChecking)
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("Programme sets").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(isChecking) } }
            .safeAreaInset(edge: .bottom) {
                Button("Apply to future programme sessions") { Task { await apply() } }
                    .buttonStyle(ZOButtonStyle(.primary)).disabled(isChecking || proposal == nil)
                    .padding(ZOSpace.l).background(theme.backgroundPrimary)
            }
        }.onAppear { change = initialChange }
        .interactiveDismissDisabled(isChecking)
        .preferredColorScheme(theme.colorScheme)
    }

    private func displayedCount(_ sets: Int, in summary: ProgrammeVolumeSummary, proposal: ProgrammeVolumeProposal) -> String {
        guard let days = proposal.weeklyTrainingDays else { return sets.formatted(.number.locale(localization.locale)) }
        return summary.weeklyAverage(sets, days: days)
            .formatted(.number.precision(.fractionLength(1)).locale(localization.locale))
    }
    private func priorValue(_ sets: Int, proposal: ProgrammeVolumeProposal) -> String {
        guard let before = proposal.before else { return localization.string("Unknown") }
        return displayedCount(sets, in: before, proposal: proposal)
    }
    private func priorCount(_ count: Int?) -> String {
        count.map { $0.formatted(.number.locale(localization.locale)) } ?? localization.string("Unknown")
    }
    @MainActor private func prepare() async {
        guard !isChecking else { return }; isChecking = true; defer { isChecking = false }
        proposal = nil; errorKey = nil
        do { proposal = try await onPrepare(change) }
        catch let error as ProgrammeVolumeError { errorKey = error.messageKey }
        catch { errorKey = ProgrammeVolumeError.unavailable.messageKey }
    }
    @MainActor private func apply() async {
        guard !isChecking, let proposal else { return }; isChecking = true; defer { isChecking = false }
        do { try await onApply(proposal); dismiss() }
        catch let error as ProgrammeVolumeError { self.proposal = nil; errorKey = error.messageKey }
        catch { self.proposal = nil; errorKey = ProgrammeVolumeError.unavailable.messageKey }
    }
}
