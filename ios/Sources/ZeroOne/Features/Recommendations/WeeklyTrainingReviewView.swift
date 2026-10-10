import SwiftUI

struct WeeklyTrainingReviewView: View {
    let schedule: WorkoutProgrammeSchedule
    let onPrepare: @MainActor (WeeklyTrainingChange, ReportedTrainingWeekdays) async throws -> WeeklyTrainingProposal
    let onApply: @MainActor (WeeklyTrainingProposal) async throws -> WorkoutProgrammeSchedule
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneLocalization) private var localization
    @State private var availableDays: Set<Int>
    @State private var confirmedAt: Date?
    @State private var confirmsAvailability = false
    @State private var proposal: WeeklyTrainingProposal?
    @State private var acceptedSchedule: WorkoutProgrammeSchedule?
    @State private var isChecking = false
    @State private var errorKey: String?

    init(schedule: WorkoutProgrammeSchedule,
         onPrepare: @escaping @MainActor (WeeklyTrainingChange, ReportedTrainingWeekdays) async throws -> WeeklyTrainingProposal,
         onApply: @escaping @MainActor (WeeklyTrainingProposal) async throws -> WorkoutProgrammeSchedule) {
        self.schedule = schedule
        self.onPrepare = onPrepare
        self.onApply = onApply
        _availableDays = State(initialValue: Set(schedule.weekdays))
    }

    private var calendar: Calendar {
        var value = Calendar.current
        value.locale = localization.locale
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if let acceptedSchedule {
                    Section("Weekly plan saved") {
                        Text(verbatim: names(Set(acceptedSchedule.weekdays)))
                        Text("This preferred rhythm stays until you change it. You can review it again when recovery improves.")
                        Button("Done") { dismiss() }
                    }
                } else {
                    Section("Days that usually fit") {
                        Text("Confirm your available weekdays. 01 will only suggest days you mark here.")
                        ForEach((0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }, id: \.self) { day in
                            Toggle(calendar.weekdaySymbols[day - 1], isOn: Binding(get: { availableDays.contains(day) }, set: {
                                if $0 { availableDays.insert(day) } else { availableDays.remove(day) }
                                confirmsAvailability = false
                                confirmedAt = nil
                                proposal = nil
                            }))
                        }
                        Toggle("These days usually fit my week", isOn: $confirmsAvailability)
                            .onChange(of: confirmsAvailability) { _, confirmed in
                                confirmedAt = confirmed ? .now : nil
                                proposal = nil
                            }
                    }
                    Section("Review an option") {
                        ForEach(WeeklyTrainingChange.allCases, id: \.self) { change in
                            Button(localization.string(change.titleKey)) { prepare(change) }
                                .disabled(confirmedAt == nil || availableDays.isEmpty || isChecking)
                        }
                    }
                    if let proposal {
                        Section("Proposed weekly rhythm") {
                            Text(localization.format("Current: %1$@", .text(names(Set(proposal.originalSchedule.weekdays)))))
                            Text(localization.format("Proposed: %1$@", .text(names(proposal.proposedWeekdays))))
                            ForEach(proposal.concerns) { concern in
                                Text(localization.string(concern.message.titleKey)).zoText(.section)
                                Text(localization.string(concern.message.detailKey))
                            }
                            Text("Spacing shows calendar days, not measured recovery time or a guarantee that training is safe.")
                            Text("Fewer days keep the session order and sets per session. The rotation takes longer; weekly exposure changes.")
                            Text("Existing appointments and Calendar bookings stay as they are. Review them separately if they no longer fit.")
                            Text("This changes your preferred weekly rhythm until you change it again. It does not start, skip or record a workout.")
                            Button("Apply weekly plan") { apply(proposal) }.disabled(isChecking)
                            Button("Keep current weekly plan") { self.proposal = nil }.disabled(isChecking)
                        }
                    }
                    if let errorKey { Text(localization.string(errorKey)).foregroundStyle(.red) }
                    if isChecking { ProgressView("Checking current records") }
                }
            }
            .disabled(isChecking)
            .navigationTitle("Review your training week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(isChecking) } }
        }
        .interactiveDismissDisabled(isChecking)
    }

    private func names(_ days: Set<Int>) -> String {
        (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter { days.contains($0) }
            .map { calendar.weekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    private func prepare(_ change: WeeklyTrainingChange) {
        guard !isChecking, let confirmedAt else { return }
        let availability = ReportedTrainingWeekdays(weekdays: availableDays, confirmedAt: confirmedAt,
            timeZoneID: calendar.timeZone.identifier)
        isChecking = true
        errorKey = nil
        Task { @MainActor in
            defer { isChecking = false }
            do { proposal = try await onPrepare(change, availability) }
            catch let error as WeeklyTrainingPlanningError { proposal = nil; errorKey = error.messageKey }
            catch { proposal = nil; errorKey = WeeklyTrainingPlanningError.unavailable.messageKey }
        }
    }

    private func apply(_ proposed: WeeklyTrainingProposal) {
        guard !isChecking else { return }
        isChecking = true
        errorKey = nil
        Task { @MainActor in
            defer { isChecking = false }
            do { acceptedSchedule = try await onApply(proposed); proposal = nil }
            catch let error as WeeklyTrainingPlanningError { errorKey = error.messageKey }
            catch { errorKey = WeeklyTrainingPlanningError.unavailable.messageKey }
        }
    }
}
