import CoreText
import SwiftUI
import UIKit

/// Host opens the exact reference through its normal active-workout/recovery ownership gate.
/// The callback opens a preview; it must not replace an active workout or automatically Start.
struct WorkoutScheduleView: View {
    let repository: WorkoutAppointmentRepository
    let calendarCoordinator: AppointmentCalendarCoordinator
    let options: [SchedulingWorkoutOption]
    let onOpenWorkout: (ScheduledWorkoutReference, UUID) -> Void

    @State private var editor: AppointmentEditorSeed?
    @State private var recoveryConfirmation: WorkoutAppointment?
    @State private var calendarReview: AppointmentCalendarReview?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    init(
        repository: WorkoutAppointmentRepository,
        calendarCoordinator: AppointmentCalendarCoordinator,
        programmes: [WorkoutProgramme],
        customWorkouts: [CustomWorkout],
        onOpenWorkout: @escaping (ScheduledWorkoutReference, UUID) -> Void
    ) {
        self.repository = repository
        self.calendarCoordinator = calendarCoordinator
        options = SchedulingWorkoutOption.available(programmes: programmes, customWorkouts: customWorkouts)
        self.onOpenWorkout = onOpenWorkout
    }

    var body: some View {
        List {
            Section {
                Text("Schedule a workout on this iPhone. Calendar copies and alerts are optional. A scheduled time never counts as a completed workout.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.backgroundPrimary)
            if let message = repository.errorMessage {
                Section {
                    Text(message)
                    Button("Retry schedule recovery") { repository.reload() }
                }
            }
            if let message = calendarCoordinator.errorMessage {
                Section { Text(message) }
            }
            if repository.appointments.isEmpty, repository.isAvailable {
                Section { Text("No appointments yet. Choose a workout and a time that suits you.") }
            }
            ForEach(repository.appointments.sorted {
                if $0.startsAt != $1.startsAt { return $0.startsAt < $1.startsAt }
                return $0.id.uuidString < $1.id.uuidString
            }) { appointment in
                Section {
                    appointmentRow(appointment)
                }
                .listRowBackground(theme.surfacePrimary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.backgroundPrimary)
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("Workout schedule")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let first = options.first {
                        editor = AppointmentEditorSeed(appointment: WorkoutAppointment(
                            reference: first.reference, title: first.title,
                            startsAt: Date(timeIntervalSince1970: floor(Date.now.addingTimeInterval(3_600).timeIntervalSince1970 / 60) * 60)
                        ), expectedRevision: nil)
                    }
                } label: {
                    Image(systemName: "plus").zoIcon(ZOIcon.row)
                }
                .buttonStyle(ZOButtonStyle(.round))
                .accessibilityLabel("Add")
                .disabled(options.isEmpty || !repository.isAvailable || calendarCoordinator.isBusy)
            }
        }
        .sheet(item: $editor) { seed in
            Group {
                NavigationStack {
                    WorkoutAppointmentEditor(repository: repository, options: options, seed: seed)
                }
            }
            .zoSheet()
        }
        .confirmationDialog(
            "Review Calendar change",
            isPresented: Binding(get: { calendarReview != nil }, set: { if !$0 { calendarReview = nil } }),
            titleVisibility: .visible
        ) {
            Button(calendarReview?.removeCopy == true ? "Remove the owned Calendar copy" : "Save this Calendar copy") {
                if let review = calendarReview {
                    Task { await calendarCoordinator.applyCalendarChange(id: review.appointment.id, removeCopy: review.removeCopy) }
                }
                calendarReview = nil
            }
        } message: {
            if let review = calendarReview {
                Text("\(review.appointment.title)\n\(AppointmentDatePresentation.text(review.appointment.startsAt, zone: .current))\nReserved \(review.appointment.durationMinutes) minutes.\n\(review.removeCopy ? "Only the saved 01-owned event is removed." : "The copy uses your default writable Calendar. Its provider may sync it. Calendar alerts follow iPhone settings.")\n01 requests Calendar access to manage only its own saved event identifiers.")
            }
        }
        .confirmationDialog(
            "Have you checked Calendar and removed the uncertain 01 copy?",
            isPresented: Binding(get: { recoveryConfirmation != nil }, set: { if !$0 { recoveryConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("I checked and removed the Calendar copy", role: .destructive) {
                if let appointment = recoveryConfirmation {
                    _ = calendarCoordinator.confirmUncertainCopyRemoved(id: appointment.id)
                }
                recoveryConfirmation = nil
            }
        } message: {
            Text("01 cannot find an event whose identifier was never confirmed. Check Calendar first to avoid a duplicate. This clears only the local recovery marker.")
        }
    }

    /// Proof 41's appointment: the date tile, the workout and its time, then
    /// the existing status, Calendar facts and actions, each its own control.
    @ViewBuilder
    private func appointmentRow(_ appointment: WorkoutAppointment) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(spacing: ZOSpace.m) {
                WorkoutAppointmentDateTile(tile: WorkoutSchedulePresentation.dateTile(
                    for: appointment.startsAt, zone: TimeZone.current, locale: localization.locale))
                VStack(alignment: .leading, spacing: 2) {
                    Text(appointment.title).zoText(.section)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AppointmentDatePresentation.text(appointment.startsAt, zone: TimeZone.current))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            Text(localization.string(statusText(appointment))).zoText(.label)
            Text("Reserved \(appointment.durationMinutes) minutes · created in \(appointment.timeZoneIdentifier)")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            if appointment.preparedSessionID != nil {
                Text("Workout launch awaiting recovery. This does not record a start or completion. Reopen the workout to recover its exact saved session, or cancel this appointment to abandon its pending intent.")
                    .zoText(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(appointment.calendarMessage).zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if appointment.status == .scheduled {
                if options.contains(where: { $0.reference == appointment.reference }) {
                    Button("Open workout") { onOpenWorkout(appointment.reference, appointment.id) }
                        .buttonStyle(ZOButtonStyle(.primary))
                } else {
                    Text("This workout is no longer available. Edit the appointment to choose another workout.")
                        .zoText(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: ZOSpace.s) {
                    Button("Edit appointment") {
                        editor = AppointmentEditorSeed(appointment: appointment, expectedRevision: appointment.revision)
                    }
                    .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    .disabled(appointment.preparedSessionID != nil || appointment.calendarLink?.operation != nil || appointment.calendarLink?.creationUncertain == true)
                    Button("Cancel appointment", role: .destructive) {
                        _ = repository.cancel(id: appointment.id, expectedRevision: appointment.revision)
                    }
                    .buttonStyle(ZOButtonStyle(.destructive, wide: true))
                    .disabled(appointment.calendarLink?.operation != nil)
                }
            }
            if appointment.calendarLink?.creationUncertain == true
                || (appointment.calendarLink?.operation != nil && appointment.calendarLink?.eventIdentifier == nil) {
                Button("Recover uncertain Calendar copy") { recoveryConfirmation = appointment }
                    .buttonStyle(ZOButtonStyle(.quiet))
            } else {
                if appointment.status != .cancelled {
                    Button(appointment.calendarLink?.eventIdentifier == nil ? "Add to Apple Calendar" : "Confirm or update Calendar copy") {
                        calendarReview = AppointmentCalendarReview(appointment: appointment, removeCopy: false)
                    }
                    .buttonStyle(ZOButtonStyle(.quiet))
                }
                if appointment.calendarLink?.eventIdentifier != nil {
                    Button("Remove Calendar copy", role: .destructive) {
                        calendarReview = AppointmentCalendarReview(appointment: appointment, removeCopy: true)
                    }
                    .buttonStyle(ZOButtonStyle(.quiet))
                }
            }
            Text("Calendar uses your default writable calendar. Its provider may sync the copy. 01 reads only its saved event identifiers to update or remove its own copies.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ZOSpace.xs)
        .disabled(!repository.isAvailable || calendarCoordinator.isBusy)
    }

    private func statusText(_ appointment: WorkoutAppointment) -> String {
        switch appointment.status {
        case .completed: "Completed workout linked to saved History"
        case .cancelled: "Cancelled locally"
        case .scheduled: appointment.startsAt < .now ? "Scheduled time passed; no completion recorded" : "Scheduled"
        }
    }
}

private struct AppointmentEditorSeed: Identifiable {
    let appointment: WorkoutAppointment
    let expectedRevision: Int?
    var id: UUID { appointment.id }
}

private struct AppointmentCalendarReview {
    let appointment: WorkoutAppointment
    let removeCopy: Bool
}

private struct WorkoutAppointmentEditor: View {
    let repository: WorkoutAppointmentRepository
    let options: [SchedulingWorkoutOption]
    let expectedRevision: Int?
    /// Intentional one-time editor draft; keeps its stable appointment ID after failed saves.
    @State private var draft: WorkoutAppointment
    @State private var daySelectionError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    init(repository: WorkoutAppointmentRepository, options: [SchedulingWorkoutOption], seed: AppointmentEditorSeed) {
        self.repository = repository
        self.options = options
        expectedRevision = seed.expectedRevision
        _draft = State(initialValue: seed.appointment)
    }

    private var zone: TimeZone { TimeZone(identifier: draft.timeZoneIdentifier) ?? .current }
    private var repeatedInstants: [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: draft.startsAt)
        return AppointmentWallTime.instants(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, timeZone: zone)
    }

    private var canSave: Bool {
        daySelectionError == nil && repository.isAvailable
            && options.contains(where: { $0.reference == draft.reference })
    }

    private func save() {
        guard canSave, let option = options.first(where: { $0.reference == draft.reference }) else { return }
        draft.title = option.title
        if repository.save(draft, expectedRevision: expectedRevision) { dismiss() }
    }

    /// Proof 41's "Schedule a workout": the workout, the day as chips, the
    /// time large with 5 minute steps, the exact date and time, the reserved
    /// length and the optional Calendar alert, then Save in the dock. Every
    /// write is the existing save; a repeated hour still asks which instant.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("Workout").zoText(.caption).foregroundStyle(theme.textSecondary)
                    Picker("Session", selection: $draft.reference) {
                        if !options.contains(where: { $0.reference == draft.reference }) {
                            Text("Unavailable: \(draft.title)").tag(draft.reference)
                        }
                        ForEach(options) { option in Text(option.title).tag(option.reference) }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.textPrimary)
                }
                .padding(ZOSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))

                ScrollView(.horizontal) {
                    HStack(spacing: ZOSpace.s) {
                        ForEach(WorkoutSchedulePresentation.dayChoices(now: .now, zone: zone), id: \.self) { day in
                            let isSelected = calendarInZone.isDate(draft.startsAt, inSameDayAs: day)
                            Button(dayChipTitle(day)) {
                                if let moved = WorkoutSchedulePresentation.moving(draft.startsAt, toDay: day, zone: zone) {
                                    draft.startsAt = moved
                                    daySelectionError = nil
                                } else {
                                    let message = localization.string("This time doesn't exist on that day because the clocks change. Choose another time or day. Your appointment hasn't changed.")
                                    daySelectionError = message
                                    UIAccessibility.post(notification: .announcement, argument: message)
                                }
                            }
                            .buttonStyle(ZOChipStyle(isSelected: isSelected))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)

                if let daySelectionError {
                    Text(verbatim: daySelectionError)
                        .zoText(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("schedule.daySelectionError")
                }

                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    HStack(spacing: ZOSpace.m) {
                        Text(draft.startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
                            .locale(localization.locale)))
                            // Proof `.zo-time`: 56/60 at 700 in the app's own face.
                            .font(Font(CTFontCreateCopyWithAttributes(ZOTextStyle.display.ctFont(for: .large), 56, nil, nil))
                                .monospacedDigit())
                            .tracking(-1.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        Button { draft.startsAt = draft.startsAt.addingTimeInterval(-300) } label: {
                            Image(systemName: "minus").zoIcon(ZOIcon.row)
                        }
                        .buttonStyle(ZOButtonStyle(.step))
                        .accessibilityLabel("Five minutes earlier")
                        Button { draft.startsAt = draft.startsAt.addingTimeInterval(300) } label: {
                            Image(systemName: "plus").zoIcon(ZOIcon.row)
                        }
                        .buttonStyle(ZOButtonStyle(.step))
                        .accessibilityLabel("Five minutes later")
                    }
                    DatePicker("Exact date and time", selection: $draft.startsAt, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, zone)
                        .zoText(.label)
                    Text(AppointmentDatePresentation.text(draft.startsAt, zone: zone))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                    Text("Time zone: \(draft.timeZoneIdentifier). Travel changes the local display, not this appointment's instant.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if repeatedInstants.count == 2 {
                        Picker("Repeated hour", selection: $draft.startsAt) {
                            ForEach(repeatedInstants, id: \.self) { instant in
                                Text(AppointmentDatePresentation.text(instant, zone: zone)).tag(instant)
                            }
                        }
                        .tint(theme.textPrimary)
                    }
                    Button("Display in my current time zone") { draft.timeZoneIdentifier = TimeZone.current.identifier }
                        .buttonStyle(ZOButtonStyle(.quiet))
                        .padding(.leading, -ZOSpace.m)
                    ZOStepper("Reserve \(draft.durationMinutes) minutes", value: $draft.durationMinutes, in: 5 ... 240, step: 5)
                }
                .padding(ZOSpace.cardPadding)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))

                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Toggle("Alert at appointment time in Calendar", isOn: $draft.calendarAlarmEnabled)
                        .zoText(.section)
                        .tint(theme.textPrimary)
                    Text("This only sets an alert if you add or update the Apple Calendar copy after saving. Calendar access is requested when you tap the Calendar action. iPhone settings control alert delivery.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZOSpace.cardPadding)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))

                if let message = repository.errorMessage {
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(message).zoText(.label)
                        Button("Retry schedule recovery") { repository.reload() }
                            .buttonStyle(ZOButtonStyle(.secondary))
                    }
                }
                Text("A planned time never counts as a workout. Only a finished one does.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
        }
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .navigationTitle(expectedRevision == nil ? "Schedule workout" : "Edit appointment")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft.startsAt) { _, _ in daySelectionError = nil }
        .onChange(of: draft.timeZoneIdentifier) { _, _ in daySelectionError = nil }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark").zoIcon(ZOIcon.row) }
                    .buttonStyle(ZOButtonStyle(.round))
                    .accessibilityLabel("Close")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(localization.format("Save for %1$@", .text(draft.startsAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone).locale(localization.locale)))), action: save)
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(!canSave)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
    }

    private var calendarInZone: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = localization.locale
        return calendar
    }

    private func dayChipTitle(_ day: Date) -> String {
        switch WorkoutSchedulePresentation.relativeDay(of: day, now: .now, zone: zone) {
        case .today: localization.string("Today")
        case .tomorrow: localization.string("Tomorrow")
        case .other: day.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day().locale(localization.locale))
        }
    }
}

private enum AppointmentDatePresentation {
    static func text(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "−" : "+"
        let absolute = abs(offset)
        return "\(formatter.string(from: date)) · UTC\(sign)\(String(format: "%02d:%02d", absolute / 3_600, (absolute % 3_600) / 60))"
    }
}
