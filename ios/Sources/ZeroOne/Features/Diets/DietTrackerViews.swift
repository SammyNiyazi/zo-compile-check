import SwiftUI
import UIKit

@MainActor
struct DietTrackersView: View {
    let model: DietTrackerFeatureModel
    var remindersAvailable = false

    @State private var editor: TrackerEditorSeed?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(localization.string("Trackers")).zoThemeHeading(.title, context: .headRowDisplay)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: ZOSpace.s)
                    Button { openEditor(nil) } label: {
                        Label(localization.string("Add"), systemImage: "plus").labelStyle(ZOIconLabelStyle())
                    }
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .disabled(model.repository.availability != .available)
                    .accessibilityLabel(localization.string("Add tracker"))
                }
                DietTrackerChecklistView(model: model)
                if !model.repository.activeTrackers.isEmpty {
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        Text(localization.string("Your trackers")).zoText(.section)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(model.repository.activeTrackers) { tracker in
                            trackerRow(tracker, archived: false)
                        }
                    }
                    .padding(ZOSpace.l).zoThemeCardSurface()
                }
                if !model.repository.archivedTrackers.isEmpty {
                    DisclosureGroup(localization.string("Archived trackers")) {
                        VStack(spacing: ZOSpace.m) {
                            ForEach(model.repository.archivedTrackers) { tracker in
                                trackerRow(tracker, archived: true)
                            }
                        }
                        .padding(.top, ZOSpace.m)
                    }
                    .zoText(.body)
                    .padding(ZOSpace.l).zoThemeCardSurface()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.bottom, ZOSpace.x4)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(theme.textPrimary)
        .sheet(item: $editor) { seed in
            DietTrackerEditorView(draft: seed.draft, isEditing: seed.draft.original != nil,
                saveError: model.errorMessage, remindersAvailable: remindersAvailable,
                requiresSavedDataReview: model.requiresSavedDataReview, onSave: model.save)
                .zoSheet(theme)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    private func openEditor(_ tracker: DietTracker?) {
        model.beginEditor()
        editor = TrackerEditorSeed(draft: tracker.map(DietTrackerDraft.init(tracker:)) ?? DietTrackerDraft())
    }

    private func trackerRow(_ tracker: DietTracker, archived: Bool) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(alignment: .top) {
                Button { openEditor(tracker) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tracker.name).zoText(.section)
                        Text(localization.string(DietTrackerPresentation.kindTitle(tracker.kind)))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.repository.availability != .available)
                .accessibilityLabel(localization.format("Edit tracker %1$@", .text(tracker.name)))
                Button(localization.string(archived ? "Restore" : "Archive")) {
                    _ = model.setArchived(!archived, tracker: tracker)
                }
                .buttonStyle(ZOButtonStyle(.quiet))
                .disabled(model.repository.availability != .available)
            }
            if !tracker.dose.isEmpty {
                Text(tracker.dose).zoText(.body).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tracker.times.isEmpty {
                Text(tracker.times.sorted { $0.minuteOfDay < $1.minuteOfDay }
                    .map(DietTrackerPresentation.timeLabel).joined(separator: " · "))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct TrackerEditorSeed: Identifiable {
        let id = UUID()
        let draft: DietTrackerDraft
    }
}

/// Shared by real Today content and the Trackers section. Each row represents
/// one scheduled UUID (or the one untimed civil-day slot), never a whole medicine.
@MainActor
struct DietTrackerChecklistView: View {
    let model: DietTrackerFeatureModel
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                Text(localization.string("Today's trackers")).zoText(.section)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ZOSpace.s)
                if let checklist = model.checklist {
                    Text(localization.format("%1$lld of %2$lld", .integer(checklist.filter(\.isCompleted).count), .integer(checklist.count)))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            if let error = model.errorMessage ?? model.repository.lastError?.errorDescription {
                Text(localization.string(error)).zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                if model.repository.availability == .available {
                    Button(localization.string("Reload trackers")) { model.refresh() }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
            }
            if let checklist = model.checklist {
                if checklist.isEmpty {
                    Text(localization.string("No trackers yet. Add what you want to keep a log of."))
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(checklist) { occurrence in occurrenceRow(occurrence) }
                }
            } else {
                Text(localization.string("Tracker storage is unavailable. Your saved data has not been replaced."))
                    .zoText(.body).foregroundStyle(theme.textSecondary)
                Button(localization.string("Reload trackers")) { model.refresh() }
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityIdentifier("diets.tracker.checklist")
        .task(id: model.observationEpoch) {
            // Use the actual civil-day end, including23/25-hour days. Scene and
            // significant-time changes restart this observation, not a dose log.
            guard let end = model.day?.end else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            model.refresh(reloadStorage: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.refresh(reloadStorage: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    private func occurrenceRow(_ occurrence: DietTrackerOccurrence) -> some View {
        Button { _ = model.toggle(occurrence) } label: {
            HStack(alignment: .center, spacing: ZOSpace.m) {
                Image(systemName: occurrence.isCompleted ? "checkmark.circle.fill" : "circle")
                    .zoIcon(ZOIcon.row)
                    .foregroundStyle(occurrence.isCompleted ? theme.textPrimary : theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(occurrence.tracker.name).zoText(.label)
                    let detail = DietTrackerPresentation.detail(occurrence)
                    if !detail.isEmpty {
                        Text(detail).zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    if occurrence.hasEarlierDetails {
                        Text(localization.string("The saved log keeps the earlier details."))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    if occurrence.completions.count > 1 {
                        Text(localization.format("%1$lld saved logs", .integer(occurrence.completions.count)))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(localization.string(occurrence.isCompleted ? "Undo log" : "Log"))
                    .zoText(.label)
            }
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.repository.availability != .available)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.format(occurrence.isCompleted ? "Undo latest log for %1$@, %2$@" : "Log %1$@, %2$@",
            .text(occurrence.tracker.name), .text(DietTrackerPresentation.detail(occurrence))))
        .accessibilityValue(localization.string(occurrence.isCompleted ? "Logged" : "Not logged"))
        .accessibilityIdentifier("diets.tracker.occurrence.\(occurrence.tracker.id).\(occurrence.time?.id.uuidString ?? "untimed")")
    }
}
