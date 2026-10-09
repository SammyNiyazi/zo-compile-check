import SwiftUI
import UserNotifications
import UIKit

struct SmartNotificationsView: View {
    @Bindable var notes: SmartNoteCenter
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var selectedNote: SmartNoteCandidate?
    @State private var showsReminderEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            // Proof 46: the app's promise is the title, in every permission
            // state, then what the permission currently allows.
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("A note only when it changes your next move.")
                        .zoThemeText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("At most one a day by default. Most days, nothing.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    permissionStatus
                }
                .padding(.top, ZOSpace.s)
                if notes.authorization == .notDetermined {
                    // Shown before any iOS permission request, as before.
                    NotificationBenefitExamples()
                } else {
                    DisclosureGroup("What you could see") {
                        NotificationBenefitExamples()
                    }
                    .zoText(.label)
                }
            }

            if let receipt = notes.loadChoiceUndo {
                NotificationThemeGroup(title: "From your notification") {
                    Text("\(receipt.selectedLoad.displayText) chosen for next time")
                    .zoText(.section).modifier(NotificationThemeRow())
                    Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .modifier(NotificationThemeRow(showsSeparator: true))
                    Button("Undo load choice") { Task { await notes.undoLastLoadChoice() } }
                        .zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                        .disabled(!notes.storageAvailable)
                        .accessibilityIdentifier("notes.undoLoadChoice")
                    Button("Keep choice") { notes.dismissLoadChoiceUndo() }
                        .zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                        .disabled(!notes.storageAvailable)
                    Text("Undo restores the previous choice only if no newer decision or workout has replaced it.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .modifier(NotificationThemeRow(showsSeparator: true))
                }
            }

            if let message = notes.actionMessage {
                NotificationThemeGroup() {
                    Text(message).accessibilityIdentifier("notes.actionResult")
                        .zoText(.body).modifier(NotificationThemeRow())
                    Button("Dismiss") { notes.actionMessage = nil }
                        .zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                }
            }
            if let error = notes.errorMessage {
                NotificationThemeGroup() {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(theme.textPrimary)
                        .modifier(NotificationThemeRow())
                    Button("Try again") { Task { await notes.retry() } }
                        .zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                }
            }

            NotificationThemeGroup(topSpacing: 14) {
                Toggle("Allow notes from 01", isOn: preference(\.enabled))
                    .zoText(.section)
                    .disabled(!notes.canDeliver)
                    .accessibilityIdentifier("notes.enabled")
                    .modifier(NotificationThemeRow())
            }
            // Proof 56 "Training day": the one reminder most people want. Local
            // only; the host builds it from the saved schedule (Sammy, 9 Oct).
            NotificationThemeGroup(title: "Training days", footer: "On your planned training days, at this time. Nothing on a day you have already trained.") {
                Toggle("Training-day reminder", isOn: trainingReminderOn)
                    .zoText(.section).modifier(NotificationThemeRow())
                    .accessibilityIdentifier("notes.trainingReminder")
                if notes.preferences.trainingReminderMinute != nil {
                    DatePicker("Reminder time", selection: trainingReminderTime, displayedComponents: .hourAndMinute)
                        .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                }
            }

            NotificationThemeGroup(title: "What gets through", footer: "Turning off a kind changes notifications only. Your plan and History stay yours.") {
                ForEach(SmartNoteKind.allCases.sorted { $0.priority < $1.priority }) { kind in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(kind.title, isOn: kindEnabled(kind))
                            .zoText(.section)
                        Text(kind.detail).zoText(.caption).foregroundStyle(theme.textSecondary)
                        if notes.preferences.enabledKinds.contains(kind) {
                            Toggle("Fewer like this", isOn: fewer(kind))
                                .zoText(.label)
                                .accessibilityLabel("Fewer \(kind.title) notes")
                        }
                    }.modifier(NotificationThemeRow(showsSeparator:
                        kind != SmartNoteKind.allCases.sorted { $0.priority < $1.priority }.first))
                }
            }

            NotificationThemeGroup(title: "Your boundaries") {
                // Proof 46: limits as compact segmented controls. The values
                // are the existing ones; nothing new is offered.
                limitRow("At most a day", selection: preference(\.dailyLimit), values: [1, 2])
                    .zoText(.section).modifier(NotificationThemeRow())
                limitRow("At most a week", selection: preference(\.weeklyLimit), values: [2, 4])
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                Toggle("Keep rest days quiet", isOn: preference(\.protectRestDays))
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                Toggle("Quiet hours", isOn: preference(\.quietHoursEnabled))
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                if notes.preferences.quietHoursEnabled {
                    DatePicker("From", selection: time(\.quietStartMinute), displayedComponents: .hourAndMinute)
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                    DatePicker("Until", selection: time(\.quietEndMinute), displayedComponents: .hourAndMinute)
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                    Text(notes.preferences.quietStartMinute == notes.preferences.quietEndMinute
                         ? "Matching times make the whole day quiet."
                         : "A note waits until quiet hours end, and only arrives if it is still useful.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .modifier(NotificationThemeRow(showsSeparator: true))
                }
                if notes.preferences.consecutiveDismissals >= 3 {
                    Text("Fewer notes for now. You cleared the last three, so 01 will schedule at most two a week.")
                        .zoText(.label).modifier(NotificationThemeRow(showsSeparator: true))
                    Button("Back to four a week") {
                        Task { await notes.updatePreferences { $0.consecutiveDismissals = 0; $0.weeklyLimit = 4 } }
                    }.zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                }
            }

            NotificationThemeGroup(title: "Voice & privacy") {
                Toggle("Direct voice", isOn: preference(\.directVoice))
                    .zoText(.section).modifier(NotificationThemeRow())
                Text("Shorter, more direct wording. Plans that move always get a neutral note.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .modifier(NotificationThemeRow(showsSeparator: true))
                Toggle("Include workout details in notifications", isOn: preference(\.showDetails))
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                Text("Off means the notification only says ‘A note from 01’. iPhone preview settings add another layer of privacy.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .modifier(NotificationThemeRow(showsSeparator: true))
            }

            NotificationThemeGroup(title: "Considered on this iPhone") {
                Button("Choose a workout reminder", systemImage: "plus") { showsReminderEditor = true }
                    .zoText(.section).buttonStyle(NotificationThemeRowButtonStyle())
                if notes.snapshot.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Nothing needs to change.", systemImage: "moon")
                            .zoText(.section).labelStyle(ZOIconLabelStyle())
                        Text("No upcoming note is ready. 01 won't invent a reason to interrupt.")
                            .zoText(.label).foregroundStyle(theme.textSecondary)
                    }.modifier(NotificationThemeRow(showsSeparator: true))
                }
                ForEach(notes.snapshot.candidates) { note in
                    Button { selectedNote = note } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title).zoText(.section)
                            Text(decisionLabel(note)).zoText(.caption).foregroundStyle(theme.textSecondary)
                            Label("Why this?", systemImage: "arrow.up.right").zoText(.caption).labelStyle(ZOIconLabelStyle())
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(NotificationThemeRow(showsSeparator: true))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Read the sources and what 01 didn't know.")
                }
            }

            NotificationThemeGroup(footer: "No streaks. No promotions. No location. Your training times and recorded workouts, with reasons you can inspect.") {
                NavigationLink {
                    SmartNoteLogView(records: notes.snapshot.records)
                } label: {
                    HStack(spacing: ZOSpace.m) {
                        Label("Scheduled, seen & held back", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.forward").zoIcon(ZOIcon.inline)
                            .foregroundStyle(theme.textTertiary).accessibilityHidden(true)
                    }.zoText(.section).modifier(NotificationThemeRow()).contentShape(Rectangle())
                }
                Text("Works on this iPhone without internet. Decisions refresh when 01 opens or your plan changes. Focus and iOS control delivery.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .modifier(NotificationThemeRow(showsSeparator: true))
            }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 6)
            .padding(.bottom, ZOSpace.screenMargin)
        }
        .tint(theme.textPrimary)
        .foregroundStyle(theme.textPrimary)
        .zoThemeScreenSurface()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedNote) { note in
            Group {
                NavigationStack { SmartNoteReasonView(note: note, notes: notes) }
                .presentationDetents([.medium, .large])
            }
            .zoSheet()
        }
        .sheet(isPresented: $showsReminderEditor) {
            Group {
                NavigationStack { SmartWorkoutReminderEditor(notes: notes) }
            }
            .zoSheet()
        }
        .task { await notes.reconcile() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notes.reconcile() } }
        }
    }

    @ViewBuilder private var permissionStatus: some View {
        if notes.authorization == .denied {
            Label("Off in iPhone Settings", systemImage: "bell.slash").zoText(.section).labelStyle(ZOIconLabelStyle())
            Text("Your choices below are kept. Allow notifications in Settings when you're ready.")
                .zoText(.label).foregroundStyle(theme.textSecondary)
            Button("Open iPhone Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }.buttonStyle(ZOButtonStyle(.secondary)).frame(minHeight: 44)
        } else if notes.authorization == .notDetermined {
            Text("Your training times and the workouts you log. Never your location.")
                .zoText(.label).foregroundStyle(theme.textSecondary)
            Button("Turn on notes") { Task { await notes.enable(quietly: false) } }
                .buttonStyle(ZOButtonStyle(.primary)).frame(minHeight: 44)
                .accessibilityIdentifier("notes.requestPermission")
            Button("Deliver quietly first") { Task { await notes.enable(quietly: true) } }
                .buttonStyle(ZOButtonStyle(.quiet))
                .frame(minHeight: 44)
        } else {
            Label(notes.authorization == .provisional ? "Quiet permission granted" : "Permission granted", systemImage: "bell.badge")
                .zoText(.section).labelStyle(ZOIconLabelStyle())
            Text(notes.preferences.enabled ? "Within your limits. Nothing during a workout." : "Notes are paused. Your choices are kept.")
                .zoText(.label).foregroundStyle(theme.textSecondary)
        }
    }

    /// Proof `.zo-group-t`: 13 pt semibold, ink 2, sentence case.
    private func groupTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
            .textCase(nil)
            .foregroundStyle(theme.textSecondary)
    }

    /// A label with the existing limit values as a compact segmented control.
    private func limitRow(_ title: LocalizedStringKey, selection: Binding<Int>, values: [Int]) -> some View {
        HStack(spacing: ZOSpace.m) {
            Text(title).zoText(.section)
            Spacer(minLength: ZOSpace.s)
            ZOSegmentedControl(title, selection: selection,
                               options: values.map { ZOSegment(value: $0, label: Text(verbatim: $0.formatted())) })
                .frame(maxWidth: 120)
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<SmartNotePreferences, Value>) -> Binding<Value> {
        Binding(get: { notes.preferences[keyPath: keyPath] }, set: { value in
            Task { await notes.updatePreferences { $0[keyPath: keyPath] = value } }
        })
    }
    private func kindEnabled(_ kind: SmartNoteKind) -> Binding<Bool> {
        Binding(get: { notes.preferences.enabledKinds.contains(kind) }, set: { enabled in
            Task { await notes.updatePreferences {
                if enabled { $0.enabledKinds.insert(kind) } else { $0.enabledKinds.remove(kind) }
            } }
        })
    }
    private func fewer(_ kind: SmartNoteKind) -> Binding<Bool> {
        Binding(get: { notes.preferences.fewerKinds.contains(kind) }, set: { enabled in
            Task { await notes.updatePreferences {
                if enabled { $0.fewerKinds.insert(kind) } else { $0.fewerKinds.remove(kind) }
            } }
        })
    }
    private func time(_ keyPath: WritableKeyPath<SmartNotePreferences, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = notes.preferences[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { value in
            let minutes = Calendar.current.component(.hour, from: value) * 60 + Calendar.current.component(.minute, from: value)
            Task { await notes.updatePreferences { $0[keyPath: keyPath] = minutes } }
        })
    }
    /// Off is nil; turning it on starts at 18:00, the time drawn in proof 56.
    private var trainingReminderOn: Binding<Bool> {
        Binding(get: { notes.preferences.trainingReminderMinute != nil }, set: { on in
            Task { await notes.updatePreferences { $0.trainingReminderMinute = on ? ($0.trainingReminderMinute ?? 18 * 60) : nil } }
        })
    }
    private var trainingReminderTime: Binding<Date> {
        Binding(get: {
            let minutes = notes.preferences.trainingReminderMinute ?? 18 * 60
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { value in
            let minutes = Calendar.current.component(.hour, from: value) * 60 + Calendar.current.component(.minute, from: value)
            Task { await notes.updatePreferences { $0.trainingReminderMinute = minutes } }
        })
    }
    private func decisionLabel(_ note: SmartNoteCandidate) -> String {
        guard let decision = notes.decisions.first(where: { $0.candidate.id == note.id }) else { return "Checking your limits" }
        guard let date = decision.deliveryDate else { return decision.reason }
        return "Eligible for " + date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct SmartNoteReasonView: View {
    let note: SmartNoteCandidate
    let notes: SmartNoteCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            NotificationThemeGroup(topSpacing: 0) {
                Text(note.title).zoThemeText(.title)
                    .fixedSize(horizontal: false, vertical: true).modifier(NotificationThemeRow())
                Text(note.body).zoText(.body)
                    .fixedSize(horizontal: false, vertical: true).modifier(NotificationThemeRow(showsSeparator: true))
            }
            NotificationThemeGroup(title: "What 01 used") {
                ForEach(Array(note.reasons.enumerated()), id: \.element) { index, reason in
                    Text(reason).zoText(.body).fixedSize(horizontal: false, vertical: true)
                        .modifier(NotificationThemeRow(showsSeparator: index > 0))
                }
            }
            if !note.unknowns.isEmpty {
                NotificationThemeGroup(title: "What 01 didn't know") {
                    ForEach(Array(note.unknowns.enumerated()), id: \.element) { index, unknown in
                        Text(unknown).zoText(.body).fixedSize(horizontal: false, vertical: true)
                            .modifier(NotificationThemeRow(showsSeparator: index > 0))
                    }
                }
            }
            NotificationThemeGroup {
                Button("Cancel this reminder") {
                    Task {
                        await notes.cancelReminder(note.id)
                        if notes.errorMessage == nil { dismiss() }
                    }
                }.zoText(.section).buttonStyle(NotificationThemeRowButtonStyle())
                Button("Stop \(note.kind.title.lowercased()) notes") {
                    Task {
                        await notes.updatePreferences { $0.enabledKinds.remove(note.kind) }
                        if notes.errorMessage == nil { dismiss() }
                    }
                }.zoText(.section).buttonStyle(NotificationThemeRowButtonStyle(showsSeparator: true))
                Text("Your plan and History won't change.").zoText(.caption).foregroundStyle(theme.textSecondary)
                    .modifier(NotificationThemeRow(showsSeparator: true))
            }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 6).padding(.bottom, ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary).tint(theme.textPrimary)
        .navigationTitle("Why this note?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct SmartWorkoutReminderEditor: View {
    let notes: SmartNoteCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @State private var programmeID = WorkoutProgrammeLibrary.recommendedID
    @State private var sessionID = ""
    @State private var start = Date().addingTimeInterval(2 * 3600)
    @State private var windowEnd = Date().addingTimeInterval(4 * 3600)
    @State private var saving = false
    private var programme: WorkoutProgramme? { WorkoutProgrammeLibrary.programme(id: programmeID) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            NotificationThemeGroup(footer: "This saves a reminder on this iPhone. It doesn't change your programme or calendar, and never starts a workout for you.", topSpacing: 0) {
                Text("Choose a real training time. 01 will consider one note 45 minutes before it, respecting your quiet hours and limits.")
                    .zoText(.label).modifier(NotificationThemeRow())
                Picker("Programme", selection: $programmeID) {
                    ForEach(WorkoutProgrammeLibrary.all) { item in Text(item.title).tag(item.id) }
                }.zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                if let programme {
                    Picker("Session", selection: $sessionID) {
                        Text("Choose a session").tag("")
                        ForEach(programme.sessions) { Text($0.title).tag($0.id) }
                    }.zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                    Text("About \(programme.durationMinutes) minutes").zoText(.caption)
                        .modifier(NotificationThemeRow(showsSeparator: true))
                }
                DatePicker("Start", selection: $start, in: Date()...)
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
                DatePicker("Free until", selection: $windowEnd, in: start...)
                    .zoText(.section).modifier(NotificationThemeRow(showsSeparator: true))
            }
            if let error = notes.errorMessage {
                NotificationThemeGroup { Text(error).modifier(NotificationThemeRow()) }
            }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 0).padding(.bottom, ZOSpace.xxl)
        }
        .scrollDismissesKeyboard(.immediately)
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary).tint(theme.textPrimary)
        .navigationTitle("Workout reminder").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let programme else { return }
                    saving = true
                    Task {
                        let saved = await notes.addWorkoutReminder(programme: programme, sessionID: sessionID, start: start, windowEnd: windowEnd)
                        saving = false
                        if saved { dismiss() }
                    }
                }.disabled(saving || sessionID.isEmpty || !notes.storageAvailable)
            }
        }
        .onChange(of: programmeID) { sessionID = "" }
    }
}

private struct SmartNoteLogView: View {
    let records: [SmartNoteRecord]
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            NotificationThemeGroup(topSpacing: 0) {
                Text("The last 14 days, stored only on this iPhone. Scheduled means iOS accepted a request, not that you saw it.")
                    .zoText(.label).foregroundStyle(theme.textSecondary)
                    .modifier(NotificationThemeRow())
            }
            if records.isEmpty {
                ContentUnavailableView("Nothing sent yet", systemImage: "bell.slash", description: Text("Silence is a useful choice too."))
            }
            if !records.isEmpty {
            NotificationThemeGroup {
            ForEach(Array(records.sorted { $0.date > $1.date }.enumerated()), id: \.element.id) { index, record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.kind.title).zoText(.section)
                    Text(record.outcome.rawValue.capitalized).zoText(.label)
                    Text(record.reason).zoText(.label)
                    Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }.modifier(NotificationThemeRow(showsSeparator: index > 0))
                    .accessibilityElement(children: .combine)
            }
            }
            }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 6).padding(.bottom, ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary).navigationTitle("Notes on this iPhone")
    }
}

/// Explicit .zo-list ownership: one shared surface around the real group.
/// Header/content gap12 is the effective direct-sibling gap in proof46.
private struct NotificationThemeGroup<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    var topSpacing: CGFloat? = nil
    @ViewBuilder let content: Content
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                    .textCase(nil).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, ZOSpace.xs).padding(.bottom, ZOSpace.m)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, ZOSpace.l)
                .zoThemeCardSurface()
            if let footer {
                Text(footer).zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZOSpace.xs).padding(.top, ZOSpace.m)
            }
        }
        .padding(.top, topSpacing ?? (title == nil ? ZOSpace.m : 22))
        .accessibilityElement(children: .contain)
    }
}

/// An inset1 separator has no layout height or hit/VoiceOver target.
private struct NotificationThemeRow: ViewModifier {
    var showsSeparator = false
    @Environment(\.zeroOneTheme) private var theme

    func body(content: Content) -> some View {
        content.padding(.vertical, ZOSpace.s)
            .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if showsSeparator {
                    Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

/// Geometry lives inside the Button label; actions and enabled state stay native.
private struct NotificationThemeRowButtonStyle: ButtonStyle {
    var showsSeparator = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(NotificationThemeRow(showsSeparator: showsSeparator))
    }
}

/// Illustrative notification content, shown before any iOS permission request.
/// This view neither schedules a note nor changes notification preferences.
private struct NotificationBenefitExamples: View {
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHAT YOU COULD SEE")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            example(
                title: "Your workout fits at 18:00",
                message: "A reminder before the training time you chose. Open 01 to review your session."
            )
            Text("Choose a training time below. A reminder is considered 45 minutes before it, respecting your quiet hours and limits.")
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
            example(
                title: "Bench press: ready for 65 kg",
                message: "You saved 4 sets at 62.5 kg, each with at least 8 reps. 01's progression rule suggests 65 kg next time. Your choice."
            )
            Text("Progress notes use your saved sets. You review the suggestion before any next-load choice changes.")
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
            Text("Examples with workout details enabled. Details are off by default: the preview says “01” and “A note from 01. Open to review your options.” You can change that below. Your notes depend on your training and choices, and iPhone preview settings also control the Lock Screen.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 8)
    }

    private func example(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("ZeroOneWordmark")
                    .resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(theme.backgroundPrimary)
                    .padding(5)
                    .frame(width: 28, height: 28)
                    .background(theme.textPrimary, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text("01").zoText(.caption)
                Spacer()
                Text("EXAMPLE").zoText(.mini)
                    .foregroundStyle(theme.textSecondary)
            }
            Text(title).zoText(.section)
            Text(message).zoText(.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example notification. \(title). \(message)")
    }
}
