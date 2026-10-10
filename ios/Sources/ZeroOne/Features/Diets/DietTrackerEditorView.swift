import SwiftUI

/// Owns one unsaved editor draft. The caller saves through the actual repository
/// and returns true only after acknowledgement; a failed save leaves the draft open.
struct DietTrackerEditorView: View {
    let isEditing: Bool
    let saveError: String?
    let isSaving: Bool
    let remindersAvailable: Bool
    let requiresSavedDataReview: Bool
    let onSave: (DietTrackerDraft) -> Bool

    @State private var draft: DietTrackerDraft
    @State private var timeChoice = Date.now
    @State private var showsTimePicker = false
    @State private var timeError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    init(draft: DietTrackerDraft, isEditing: Bool, saveError: String?,
         isSaving: Bool = false, remindersAvailable: Bool = false,
         requiresSavedDataReview: Bool = false,
         onSave: @escaping (DietTrackerDraft) -> Bool) {
        // Intentional one-time editor seed, never a mirror of changing parent inputs.
        _draft = State(initialValue: draft)
        self.isEditing = isEditing
        self.saveError = saveError
        self.isSaving = isSaving
        self.remindersAvailable = remindersAvailable
        self.requiresSavedDataReview = requiresSavedDataReview
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZOSpace.m) {
                Button { dismiss() } label: { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                    .buttonStyle(ZOButtonStyle(.round))
                    .accessibilityLabel(localization.string("Cancel"))
                    .disabled(isSaving)
                Text(localization.string(isEditing ? "Edit tracker" : "New tracker"))
                    .zoThemeHeading(.section, context: .headRowDisplay)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(ZOSpace.screenMargin)

            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    ZOSegmentedControl("Tracker kind", selection: $draft.kind, options:
                        DietTrackerKind.allCases.map {
                            ZOSegment(value: $0, label: Text(localization.string(DietTrackerPresentation.kindTitle($0))))
                        })
                    .accessibilityIdentifier("diets.tracker.kind")

                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        fieldLabel("Name")
                        TextField(localization.string("Tracker name"), text: $draft.name)
                            .zoText(.section)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("diets.tracker.name")
                        Divider().overlay(theme.strokeSubtle)
                        fieldLabel("Dose")
                        TextField(localization.string("Your own instructions, optional"), text: $draft.dose, axis: .vertical)
                            .zoText(.section)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("diets.tracker.dose")
                    }
                    .padding(ZOSpace.l)
                    .zoThemeCardSurface()

                    timesSection
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        Toggle(localization.string("Remind me"), isOn: $draft.remindMe)
                        Divider().overlay(theme.strokeSubtle)
                        Toggle(isOn: $draft.remindAgainIfNotLogged) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(localization.string("Remind again if not logged"))
                                Text(localization.string("After 15 minutes, once"))
                                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                            }
                        }
                        // Retain independently authored preferences when reminders are off.
                        // No scheduler or permission state is synthesized by the editor.
                        if !remindersAvailable {
                            Text(localization.string("Reminder preferences are saved. Notifications are not connected yet."))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(ZOToggleStyle())
                    .zoText(.body)
                    .tint(theme.accentFill)
                    .padding(ZOSpace.l)
                    .zoThemeCardSurface()

                    Label(localization.string("01 keeps your log. It does not give medical advice; follow your clinician's plan."), systemImage: "info.circle")
                        .zoText(.caption)
                        .labelStyle(ZOIconLabelStyle())
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = saveError ?? timeError {
                        Text(localization.string(error))
                            .zoText(.body)
                            .foregroundStyle(theme.textPrimary)
                            .accessibilityAddTraits(.updatesFrequently)
                            .accessibilityIdentifier("diets.tracker.save-error")
                    }
                    if requiresSavedDataReview {
                        Button(localization.string("Review saved trackers")) { dismiss() }
                            .buttonStyle(ZOButtonStyle(.secondary))
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.x3)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(theme.textPrimary)
        .zoThemeScreenSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                timeError = nil
                if onSave(draft) { dismiss() }
            } label: {
                Text(localization.string(isSaving ? "Saving…" : saveError == nil ? "Save tracker" : "Retry save"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .disabled(isSaving || requiresSavedDataReview || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("diets.tracker.save")
            .padding(ZOSpace.screenMargin)
            .background(theme.backgroundPrimary)
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showsTimePicker) {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text(localization.string("Add a time")).zoThemeText(.title)
                DatePicker(localization.string("Time"), selection: $timeChoice, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, localization.locale)
                HStack {
                    Button(localization.string("Cancel")) { showsTimePicker = false }
                        .buttonStyle(ZOButtonStyle(.secondary))
                    Button(localization.string("Add")) { addChosenTime() }
                        .buttonStyle(ZOButtonStyle(.primary))
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
            .presentationDetents([.medium, .large])
            .zoSheet(theme)
        }
    }

    private func fieldLabel(_ key: String) -> some View {
        Text(localization.string(key)).zoText(.caption).foregroundStyle(theme.textSecondary)
    }

    private var timesSection: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            fieldLabel("Times")
            ScrollView(.horizontal) {
                HStack(spacing: ZOSpace.s) {
                    ForEach(draft.times.sorted { $0.minuteOfDay < $1.minuteOfDay }) { time in
                        Button {
                            draft.times.removeAll { $0.id == time.id }
                            timeError = nil
                        } label: {
                            Label(DietTrackerPresentation.timeLabel(time), systemImage: "xmark")
                                .labelStyle(ZOIconLabelStyle())
                        }
                        .buttonStyle(ZOChipStyle(isSelected: true))
                        .accessibilityLabel(localization.format("Remove time %1$@", .text(DietTrackerPresentation.timeLabel(time))))
                    }
                    Button { showsTimePicker = true } label: {
                        Label(localization.string("Add"), systemImage: "plus").labelStyle(ZOIconLabelStyle())
                    }
                    .buttonStyle(ZOChipStyle(isSelected: false))
                    .disabled(draft.times.count >= 64)
                    .accessibilityLabel(localization.string("Add a time"))
                }
            }
            .scrollIndicators(.hidden)
            if draft.times.isEmpty {
                Text(localization.string("No set time. One checklist entry each day."))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func addChosenTime() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: timeChoice)
        guard let hour = components.hour, let minute = components.minute else { return }
        do {
            draft.times = try DietTrackerPresentation.addingTime(hour: hour, minute: minute, to: draft.times)
            timeError = nil
            showsTimePicker = false
        } catch {
            timeError = error.localizedDescription
            showsTimePicker = false
        }
    }
}
