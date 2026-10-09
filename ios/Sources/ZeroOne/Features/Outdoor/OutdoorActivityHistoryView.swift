import CoreLocation
import MapKit
import SwiftUI

/// Local-only history. Route geometry can be removed without erasing measured totals.
struct OutdoorActivityHistoryView: View {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneRootShareCoordinator) private var rootShareCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var records: [OutdoorActivityRecord] = []
    @State private var selectedRecord: OutdoorActivityRecord?
    @State private var selectedRecordRevision = UUID()
    @State private var routeToDelete: OutdoorActivityRecord?
    @State private var activityToDelete: OutdoorActivityRecord?
    @State private var showsStorageError = false
    @State private var storageErrorText = ""
    @State private var loadState: LoadState = .loading
    @State private var showsLoadingPlaceholder = false
    @State private var latestReadID = UUID()

    private enum LoadState { case loading, ready, unavailable }

    private let repository: OutdoorActivityRepository
    private let onShare: ((OutdoorActivityRecord) -> Void)?
    private let canExportSavedRecord: (@MainActor (OutdoorActivityRecord) async -> Bool)?

    init(repository: OutdoorActivityRepository, onShare: ((OutdoorActivityRecord) -> Void)? = nil,
         canExportSavedRecord: (@MainActor (OutdoorActivityRecord) async -> Bool)? = nil) {
        self.repository = repository
        self.onShare = onShare
        self.canExportSavedRecord = canExportSavedRecord
    }

    private struct SelectionSnapshot {
        let record: OutdoorActivityRecord?
        let revision: UUID
    }

    private var selectionSnapshot: SelectionSnapshot {
        SelectionSnapshot(record: selectedRecord, revision: selectedRecordRevision)
    }

    private func isCurrentSelection(_ expected: SelectionSnapshot) -> Bool {
        selectedRecordRevision == expected.revision && selectedRecord == expected.record
    }

    @discardableResult
    private func replaceSelectedRecord(_ next: OutdoorActivityRecord?, expected: SelectionSnapshot) -> Bool {
        guard isCurrentSelection(expected) else { return false }
        rootShareCoordinator?.revokeBeforeRouteChange()
        selectedRecordRevision = UUID()
        selectedRecord = next
        return true
    }

    private func selectedRecordBinding(expected: SelectionSnapshot) -> Binding<OutdoorActivityRecord?> {
        Binding(get: { selectedRecord }, set: { next in
            replaceSelectedRecord(next, expected: expected)
        })
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        let capturedSelection = selectionSnapshot
        NavigationStack {
            Group {
                if loadState == .loading {
                    if showsLoadingPlaceholder { historyPlaceholder }
                } else if loadState == .unavailable && records.isEmpty {
                    VStack(spacing: 12) {
                        ZOAppIcon("exclamationmark.triangle", size: ZOIcon.feature).accessibilityHidden(true)
                        Text("outdoor.design.history.error.title").zoThemeText(.title)
                        Text("outdoor.design.history.error.detail").zoThemeText(.body).foregroundStyle(secondaryInk)
                        Button("outdoor.design.retry") { Task { await reload() } }
                            .buttonStyle(ZOButtonStyle(.primary))
                            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 56)
                    }.padding(ZOSpace.xl)
                } else if records.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No outdoor activities yet")
                        } icon: {
                            ZOAppIcon("01.jog", size: ZOIcon.feature)
                        }
                    } description: {
                        Text("Your saved walks and runs will appear here.")
                    }
                } else {
                    VStack(spacing: 0) {
                        if loadState == .unavailable {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("outdoor.design.history.stale").zoThemeText(.body)
                                Button("outdoor.design.retry") { Task { await reload() } }
                                    .buttonStyle(ZOButtonStyle(.secondary))
                            }
                            .padding(ZOSpace.l)
                            .foregroundStyle(theme.textPrimary)
                            .background(theme.surfaceSecondary)
                        }
                    List(records) { record in
                        Button { replaceSelectedRecord(record, expected: capturedSelection) } label: {
                            let rowLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                : AnyLayout(HStackLayout(spacing: ZOSpace.m))
                            rowLayout {
                                OutdoorRouteThumbnail(route: record.route)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localization.string(record.kind == .walk ? "Walk" : "Run"))
                                        .zoThemeText(.section)
                                    Text(OutdoorPresentation.date(record.startedAt, style: .dateTime.weekday(.abbreviated).month().day().hour().minute(),
                                                                  locale: localization.locale, calendar: calendar))
                                        .zoThemeText(.caption)
                                        .foregroundStyle(secondaryInk)
                                }
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(distance(record.recordedDistanceMeters))
                                        .zoThemeText(.section)
                                    Text(duration(record.confirmedActiveSeconds))
                                        .zoThemeText(.caption)
                                        .foregroundStyle(secondaryInk)
                                    Text(steps(record.recordedSteps))
                                        .zoThemeText(.caption)
                                        .foregroundStyle(secondaryInk)
                                }
                            }
                            .foregroundStyle(theme.textPrimary)
                            .frame(minHeight: 58)
                        }
                        .disabled(loadState != .ready)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(contrast == .increased
                            ? ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme) : theme.strokeSubtle)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    }
                }
            }
            .zoThemeScreenSurface()
            .background(theme.backgroundPrimary)
            .navigationTitle("outdoor.design.history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { rootShareCoordinator?.revokeBeforeRouteChange(); dismiss() }
                }
            }
            .sheet(item: selectedRecordBinding(expected: capturedSelection)) { record in
                Group {
                    detail(record, selection: capturedSelection)
                    .zeroOneTheme(theme)
                    .preferredColorScheme(theme.colorScheme)
                }
                .zoSheet(theme)
            }
            .alert("Could not update history", isPresented: $showsStorageError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(localization.string(storageErrorText))
            }
            .task {
                let placeholder = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard loadState == .loading, !Task.isCancelled else { return }
                    showsLoadingPlaceholder = true
                }
                defer { placeholder.cancel() }
                await reload()
            }
        }
    }

    private func detail(_ record: OutdoorActivityRecord, selection: SelectionSnapshot) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text(OutdoorPresentation.date(record.startedAt, style: .dateTime.weekday(.wide).year().month().day().hour().minute(),
                                                                  locale: localization.locale, calendar: calendar))
                        .zoThemeText(.caption).foregroundStyle(secondaryInk)
                    if record.hasIncompleteStepCoverage {
                        Text(localization.string(record.recordedSteps == nil
                             ? "Steps were unavailable for this activity."
                             : "Step count is partial because some active time was not measured."))
                            .zoThemeText(.caption)
                            .foregroundStyle(secondaryInk)
                    }
                    if record.hasMissingLocationCoverage {
                        Text("GPS was unavailable for part of this activity. The route has gaps; no missing distance was invented.")
                            .zoThemeText(.caption)
                            .foregroundStyle(theme.warningPrimary)
                    }
                    if let route = record.route, !route.segments.isEmpty {
                        Map(initialPosition: .automatic) {
                            ForEach(route.segments) { segment in
                                if segment.points.count >= 2 {
                                    MapPolyline(coordinates: segment.presentationPoints.map {
                                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                    })
                                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                                } else if let point = segment.points.first {
                                    Marker("Recorded point", coordinate: CLLocationCoordinate2D(
                                        latitude: point.latitude, longitude: point.longitude
                                    )).tint(theme.textPrimary)
                                }
                                if segment.endsAtUserPause == true, let point = segment.points.last {
                                    Annotation("Paused here", coordinate: CLLocationCoordinate2D(
                                        latitude: point.latitude, longitude: point.longitude
                                    )) {
                                        Image(systemName: "pause.fill")
                                            .zoIcon(ZOIcon.inline)
                                            .foregroundStyle(theme.textPrimary)
                                            .frame(width: 30, height: 30)
                                            .background(theme.surfacePrimary, in: Circle())
                                            .overlay { Circle().stroke(theme.textPrimary, lineWidth: 2) }
                                            .accessibilityLabel("Route paused here. Paused travel is excluded.")
                                    }
                                }
                            }
                        }
                        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(localization.format("outdoor.design.saved.route.sections", .integer(route.segments.count)))
                    } else {
                        Text(localization.string(record.routeDeletedAt == nil ? "No route was recorded." : "Route map deleted. Time and measured distance were kept."))
                            .zoThemeText(.body)
                            .foregroundStyle(secondaryInk)
                    }
                    OutdoorThemeSummaryFacts(seconds: record.confirmedActiveSeconds,
                                        meters: record.recordedDistanceMeters, steps: record.recordedSteps)
                    if let route = record.route, !route.segments.isEmpty {
                        Button("Delete route, keep activity") { routeToDelete = record }
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .frame(minHeight: 44)
                    }
                    Button("Delete entire activity", role: .destructive) { activityToDelete = record }
                        .buttonStyle(ZOButtonStyle(.destructive))
                        .frame(minHeight: 44)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(ZOSpace.xl)
                .frame(maxWidth: .infinity)
            }
            .zoThemeScreenSurface()
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .navigationTitle(localization.string(record.kind == .walk ? "Walk" : "Run"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if loadState == .ready {
                    if let canExportSavedRecord {
                        ToolbarItem(placement: .topBarLeading) {
                            SavedOutdoorShareButton(record: record, canExport: canExportSavedRecord)
                        }
                    } else if let onShare {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Share") { onShare(record) }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { replaceSelectedRecord(nil, expected: selection) }
                }
            }
            .confirmationDialog(
                "Delete this route map?",
                isPresented: Binding(
                    get: { routeToDelete != nil },
                    set: { if !$0 { routeToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete route only", role: .destructive) {
                    guard let record = routeToDelete else { return }
                    routeToDelete = nil
                    Task { await deleteRoute(record.id, selection: selection) }
                }
                Button("Keep route", role: .cancel) { routeToDelete = nil }
            } message: {
                Text("Your time and measured distance remain in the activity summary. Route points cannot be restored from 01 after deletion.")
            }
            .confirmationDialog(
                "Delete this activity?",
                isPresented: Binding(
                    get: { activityToDelete != nil },
                    set: { if !$0 { activityToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete activity", role: .destructive) {
                    guard let record = activityToDelete else { return }
                    activityToDelete = nil
                    Task { await deleteActivity(record.id, selection: selection) }
                }
                Button("Keep activity", role: .cancel) { activityToDelete = nil }
            } message: {
                Text("This removes the walk or run and its route from local 01 history. This cannot be undone.")
            }
            .alert("Could not update history", isPresented: $showsStorageError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(localization.string(storageErrorText))
            }
        }
    }

    private var historyPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { _ in
                HStack(spacing: ZOSpace.m) {
                    RoundedRectangle(cornerRadius: 12).fill(theme.surfaceSecondary)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 8).fill(theme.surfaceSecondary).frame(height: 20)
                        RoundedRectangle(cornerRadius: 8).fill(theme.surfaceSecondary).frame(height: 14)
                    }
                }.padding(ZOSpace.l)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private func reload(expectedSelection: SelectionSnapshot? = nil) async {
        let requestID = UUID()
        latestReadID = requestID
        do {
            let result = try await repository.loadRecords()
            guard requestID == latestReadID, !Task.isCancelled,
                  expectedSelection.map({ isCurrentSelection($0) }) ?? true else { return }
            records = result
            loadState = .ready
            showsLoadingPlaceholder = false
        } catch {
            guard requestID == latestReadID, !Task.isCancelled,
                  expectedSelection.map({ isCurrentSelection($0) }) ?? true else { return }
            loadState = .unavailable
            showsLoadingPlaceholder = false
            storageErrorText = "Saved activities could not be read. The existing files were not replaced."
            showsStorageError = true
        }
    }

    private func deleteRoute(_ id: UUID, selection: SelectionSnapshot) async {
        do {
            let updated = try await repository.deleteRoute(for: id, at: .now)
            // The actor's actual source-write revocation remains unconditional.
            guard !Task.isCancelled, selection.record?.id == id,
                  isCurrentSelection(selection) else { return }
            guard replaceSelectedRecord(updated, expected: selection) else { return }
            let afterReplacement = selectionSnapshot
            await reload(expectedSelection: afterReplacement)
            guard !Task.isCancelled, isCurrentSelection(afterReplacement) else { return }
        } catch {
            guard !Task.isCancelled, selection.record?.id == id,
                  isCurrentSelection(selection) else { return }
            storageErrorText = "The route was not removed. Your existing history has been kept."
            showsStorageError = true
        }
    }

    private func deleteActivity(_ id: UUID, selection: SelectionSnapshot) async {
        do {
            _ = try await repository.deleteSession(id)
            guard !Task.isCancelled, selection.record?.id == id,
                  isCurrentSelection(selection) else { return }
            guard replaceSelectedRecord(nil, expected: selection) else { return }
            let afterReplacement = selectionSnapshot
            await reload(expectedSelection: afterReplacement)
            guard !Task.isCancelled, isCurrentSelection(afterReplacement) else { return }
        } catch {
            guard !Task.isCancelled, selection.record?.id == id,
                  isCurrentSelection(selection) else { return }
            storageErrorText = "The activity was not removed. Your existing history has been kept."
            showsStorageError = true
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        OutdoorPresentation.duration(seconds)
    }

    private func distance(_ meters: Double?) -> String {
        let value = OutdoorPresentation.distance(meters, locale: localization.locale)
        return value == "—" ? value : value + " km"
    }

    private func steps(_ count: Int?) -> String {
        let value = OutdoorPresentation.steps(count, locale: localization.locale)
        guard value != "—" else { return localization.string("Steps unavailable") }
        return localization.format("outdoor.design.step.count", .text(value))
    }
}
