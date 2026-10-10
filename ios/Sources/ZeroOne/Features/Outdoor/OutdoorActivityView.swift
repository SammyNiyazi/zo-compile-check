import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct OutdoorActivityView: View {
    let model: OutdoorActivityViewModel
    var profileInitial = "01"
    var onShare: ((OutdoorActivityRecord) -> Void)? = nil
    var canExportSavedRecord: (@MainActor (OutdoorActivityRecord) async -> Bool)? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneRootShareCoordinator) private var rootShareCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showsFinishConfirmation = false
    @State private var showsHistory = false
    @State private var celebratedRecordIDs: Set<UUID> = []
    @State private var tickRecordID: UUID?
    @State private var burstRecordID: UUID?

    private var historyBinding: Binding<Bool> {
        Binding(get: { showsHistory }, set: { next in
            rootShareCoordinator?.revokeBeforeRouteChange()
            showsHistory = next
        })
    }

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.xxl) {
                    if model.surface != .setup && model.surface != .summary
                        && model.surface != .recording && model.surface != .paused
                        && model.surface != .interrupted { heading }
                    switch model.surface {
                    case .setup: setup
                    case .requestingPermission: requestingPermission
                    case .locationUnavailable: locationUnavailable
                    case .recording, .paused, .interrupted: activity
                    case .saving: saving
                    case .storageBlocked: storageBlocked
                    case .summary: summary
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ZOSpace.xl)
                .padding(.top, ZOSpace.xl)
                .padding(.bottom, ZOSpace.l)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .zoThemeScreenSurface()
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { primaryControls }
            .navigationTitle(activityName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localization.string(model.hasUnfinishedSession ? "Close view" : "Done")) {
                        rootShareCoordinator?.revokeBeforeRouteChange()
                        if model.surface == .summary { model.closeSummary() }
                        dismiss()
                    }
                    .foregroundStyle(theme.textPrimary)
                }
            }
            .toolbarBackground(theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .confirmationDialog(
                localization.string(model.selectedKind == .walk ? "outdoor.design.finish.walk" : "outdoor.design.finish.run"),
                isPresented: $showsFinishConfirmation,
                titleVisibility: .visible
            ) {
                Button("Finish and save") { Task { await finishActivity() } }
                Button(localization.string(model.surface == .recording ? "Keep recording" : "outdoor.design.keep.activity"), role: .cancel) { }
            } message: {
                Text("Confirmed active time, measured route distance, and available activity steps will be saved.")
            }
            .sheet(isPresented: historyBinding) {
                Group {
                    OutdoorActivityHistoryView(repository: model.historyRepository, onShare: onShare,
                                               canExportSavedRecord: canExportSavedRecord)
                    .zeroOneTheme(theme)
                    .preferredColorScheme(theme.colorScheme)
                }
                .zoSheet(theme)
            }
            .task { await model.load() }
        }
        .zeroOneTheme(theme)
        .preferredColorScheme(theme.colorScheme)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(activityName)
                .zoThemeText(.display)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(localization.string(subtitle))
                .zoThemeText(.body)
                .foregroundStyle(secondaryInk)
        }
    }

    private var activityName: String { localization.string(model.selectedKind == .walk ? "Walk" : "Run") }

    private var subtitle: String {
        switch model.surface {
        case .setup: "Your route. Your pace. Your progress."
        case .requestingPermission: "Waiting for your location choice."
        case .locationUnavailable: "You can still record time and available steps."
        case .recording: model.isRecordingWithoutGPS ? "Recording without a route" : "Your route is being recorded."
        case .paused: "Paused. Nothing is measured until you resume."
        case .interrupted: "Ready to recover your last confirmed session."
        case .saving: "Saving on this iPhone."
        case .storageBlocked: "Your last confirmed activity is still here."
        case .summary: "Done. You showed up."
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            if let message = model.message {
                Text(localization.string(message))
                    .zoThemeText(.caption)
                    .foregroundStyle(theme.warningPrimary)
            }
            Text("outdoor.design.ready")
                .zoThemeText(.display)
                .foregroundStyle(theme.textPrimary)
            Text("outdoor.design.ready.detail")
                .zoThemeText(.body)
                .foregroundStyle(secondaryInk)
            emptyRoute
            HStack(alignment: .top, spacing: 10) {
                ZOAppIcon("location", size: ZOIcon.row).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("outdoor.design.precise.title").zoThemeText(.section)
                    Text("outdoor.design.precise.detail").zoThemeText(.caption).foregroundStyle(secondaryInk)
                }
            }
            .padding(ZOSpace.l)
            .foregroundStyle(theme.textPrimary)
            .zoThemeCardSurface()
            DisclosureGroup("Location and privacy") {
                Text("Precise Location measures distance and draws your route. Without it, you can record time and available steps. Steps are optional.")
                Text("Your route stays on this iPhone. Delete it separately from the saved activity whenever you choose.")
            }
            .zoThemeText(.caption)
            .foregroundStyle(secondaryInk)
            Button("Past walks and runs") { historyBinding.wrappedValue = true }
                .buttonStyle(ZOButtonStyle(.secondary))
                .frame(minHeight: 44)
        }
    }

    private var requestingPermission: some View {
        stateCard(
            icon: "location.circle",
            title: "Choose location access",
            detail: "Use Precise Location to draw your route and measure distance. The activity clock has not started yet."
        )
    }

    private var locationUnavailable: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            stateCard(icon: "location.slash", title: locationIssueTitle, detail: locationIssueDetail)
            if model.locationReadiness == .denied || model.locationReadiness == .reducedAccuracy
                || model.locationReadiness == .servicesDisabled {
                Button("Open Location Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(ZOButtonStyle(.secondary))
                .accessibilityHint("Opens iPhone Settings to change location access for 01.")
            }
        }
    }

    private var locationIssueTitle: String {
        switch model.locationReadiness {
        case .denied: "Location not allowed"
        case .restricted: "Location is restricted"
        case .reducedAccuracy: "Precise Location is off"
        case .servicesDisabled: "Location Services are off"
        default: "Location is unavailable"
        }
    }

    private var locationIssueDetail: String {
        "Enable precise location to record a route and distance, or record without a route. Available activity steps can still be counted without GPS."
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            if let message = model.message {
                Text(localization.string(message))
                    .zoThemeText(.caption)
                    .foregroundStyle(theme.warningPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ZOSpace.m)
                    .zoThemeCardSurface(background: theme.surfaceSecondary)
            }
            if model.surface != .recording || model.isRecordingWithoutGPS {
                Text(localization.string(statusLabel)).zoThemeText(.caption).foregroundStyle(secondaryInk)
            }
            Text("outdoor.design.time").zoThemeText(.caption).foregroundStyle(secondaryInk)
            Text(formattedDuration(model.displaySeconds))
                .zoThemeText(.timer)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .accessibilityLabel(localization.format("outdoor.design.active.time.accessibility", .text(formattedDuration(model.displaySeconds))))

            let metricLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: ZOSpace.m))
            metricLayout {
                metric(localization.string("outdoor.design.distance"), value: distanceText, unit: distanceText == "—" ? "" : "km")
                metric(localization.string("outdoor.design.pace"), value: paceText, unit: paceText == "—" ? "" : "/km")
            }
            if let checkpoint = model.checkpoint, checkpoint.steps.hasIncompleteCoverage {
                Text(localization.string(checkpoint.steps.recordedSteps == nil
                     ? "Steps unavailable. Your activity continues."
                     : "Step count is partial until the active interval can be reconciled."))
                    .zoThemeText(.caption)
                    .foregroundStyle(secondaryInk)
            }

            if let checkpoint = model.checkpoint, checkpoint.trackingMode == .route,
               !model.isRecordingWithoutGPS {
                routeMap(checkpoint.route)
            } else if let route = model.checkpoint?.route, !route.segments.isEmpty {
                routeMap(route)
            } else {
                stateCard(
                    icon: "map",
                    title: "No route being drawn",
                    detail: "Recording without a route does not access GPS or estimate distance."
                )
            }

            if model.checkpoint?.route.hasMissingLocationCoverage == true {
                Text("GPS gap: the route is split here. Distance covers only measured sections.")
                    .zoThemeText(.caption)
                    .foregroundStyle(theme.warningPrimary)
            }
            metric(localization.string("outdoor.design.steps"), value: OutdoorPresentation.steps(model.checkpoint?.steps.recordedSteps, locale: localization.locale), unit: "")
        }
    }

    private var statusLabel: String {
        switch model.surface {
        case .recording: model.isRecordingWithoutGPS ? "RECORDING WITHOUT ROUTE" : "RECORDING ROUTE"
        case .paused: "PAUSED"
        case .interrupted: "RECOVERY NEEDED"
        default: "OUTDOOR ACTIVITY"
        }
    }

    private var distanceText: String {
        OutdoorPresentation.distance(model.checkpoint?.route.recordedDistanceMeters, locale: localization.locale)
    }

    private var paceText: String {
        OutdoorPresentation.pace(seconds: model.displaySeconds,
                                 meters: model.checkpoint?.route.recordedDistanceMeters,
                                 hasGPSGap: model.checkpoint?.route.hasMissingLocationCoverage ?? true)
    }

    private func routeMap(_ route: OutdoorRouteAccumulator, height: CGFloat = 300) -> some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(route.segments) { segment in
                if segment.points.count >= 2 {
                    MapPolyline(coordinates: segment.presentationPoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                else if let point = segment.presentationPoints.first {
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
            if model.surface == .recording && !model.isRecordingWithoutGPS {
                UserAnnotation {
                    Text(profileInitial)
                        .zoThemeText(.caption)
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(theme.accentFill, in: Circle())
                        .overlay { Circle().stroke(theme.surfacePrimary, lineWidth: 3) }
                        .accessibilityLabel("Your current location")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .mapControls { MapCompass() }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if route.segments.isEmpty {
            Text(localization.string("FINDING GPS"))
                .zoThemeText(.caption)
                .padding(ZOSpace.s)
                .background(theme.surfacePrimary, in: Capsule())
                .padding(ZOSpace.m)
            }
        }
        .accessibilityLabel(localization.format("outdoor.design.route.sections", .integer(route.segments.count)))
    }

    private var saving: some View {
        stateCard(icon: "arrow.down.doc", title: "Saving your activity", detail: "Keeping your confirmed time and measured route on this iPhone.")
    }

    private var storageBlocked: some View {
        stateCard(
            icon: "exclamationmark.arrow.triangle.2.circlepath",
            title: "Save needs another try",
            detail: model.message ?? "Recording stopped to protect your last confirmed activity. Retry the local save before starting anything else."
        )
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let record = model.finishedRecord {
                VStack(spacing: 12) {
                    OutdoorSavedTick(plays: tickRecordID == record.id)
                    Text(localization.string(record.kind == .walk ? "outdoor.design.walk.saved" : "outdoor.design.run.saved"))
                        .zoThemeText(.display).foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(savedDateRange(record))
                        .zoThemeText(.body).foregroundStyle(secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                if let route = record.route, !route.segments.isEmpty {
                    routeMap(route, height: 180)
                } else {
                    Text("outdoor.design.no.saved.route").zoThemeText(.caption).foregroundStyle(secondaryInk)
                }
                OutdoorThemeSummaryFacts(seconds: record.confirmedActiveSeconds,
                                    meters: record.recordedDistanceMeters, steps: record.recordedSteps)
                Text(localization.format("outdoor.design.saved.line", .text(formattedDuration(record.confirmedActiveSeconds))))
                    .zoProofText(.section, size: 17, lineHeight: 26, weight: 500)
                    .foregroundStyle(theme.textPrimary)
                if record.hasIncompleteStepCoverage {
                    Text(localization.string(record.recordedSteps == nil
                         ? "Steps were unavailable for this activity."
                         : "Step count is partial because some active time was not measured."))
                        .zoThemeText(.caption)
                        .foregroundStyle(secondaryInk)
                }
                if record.hasMissingLocationCoverage {
                    Text("Part of this route had no reliable GPS. No missing distance was estimated.")
                        .zoThemeText(.caption)
                        .foregroundStyle(theme.warningPrimary)
                }
            }
        }
        .overlay(alignment: .top) {
            if let record = model.finishedRecord, burstRecordID == record.id {
                OutdoorSavedBurst().frame(height: 200)
            }
        }
    }

    @ViewBuilder
    private var primaryControls: some View {
        VStack(spacing: ZOSpace.s) {
            switch model.surface {
            case .setup:
                Button { Task { await model.startWithRoute() } } label: {
                    HStack(spacing: 8) {
                        ZOAppIcon("01.jog", size: ZOIcon.inline).accessibilityHidden(true)
                        Text(localization.string(model.selectedKind == .walk ? "outdoor.design.start.walk" : "outdoor.design.start.run"))
                    }.frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 56)
                }.buttonStyle(ZOButtonStyle(.primary))
                Button("outdoor.design.without.route") { Task { await model.startTimeOnly() } }
                    .buttonStyle(ZOButtonStyle(.quiet))
            case .requestingPermission, .saving:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 56)
            case .locationUnavailable:
                primaryButton("Record without route", systemImage: "timer") { await model.startTimeOnly() }
                Button("Try location again") { Task { await model.startWithRoute() } }
                    .zoThemeText(.section)
                    .frame(maxWidth: .infinity, minHeight: 44)
            case .recording:
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Button { Task { await model.pause() } } label: {
                        Label("outdoor.design.pause", systemImage: "pause").labelStyle(ZOIconLabelStyle())
                            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 48)
                    }.buttonStyle(ZOButtonStyle(.secondary))
                    Button(localization.string(model.selectedKind == .walk ? "outdoor.design.end.walk" : "outdoor.design.end.run")) {
                        showsFinishConfirmation = true
                    }.frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 48).buttonStyle(ZOButtonStyle(.destructive))
                }
            case .paused, .interrupted:
                primaryButton(model.selectedKind == .walk ? "outdoor.design.resume.walk" : "outdoor.design.resume.run", systemImage: "arrow.right") {
                    await model.startWithRoute()
                }
                Button("Finish") { showsFinishConfirmation = true }
                    .zoThemeText(.section)
                    .foregroundStyle(secondaryInk)
                    .frame(minHeight: 44)
            case .storageBlocked:
                primaryButton("Retry save", systemImage: "arrow.clockwise") { await model.retryStorage() }
            case .summary:
                primaryButton("Done", systemImage: "checkmark") {
                    rootShareCoordinator?.revokeBeforeRouteChange()
                    model.closeSummary()
                    dismiss()
                }
                if let record = model.finishedRecord {
                    if let canExportSavedRecord {
                        SavedOutdoorShareButton(record: record, canExport: canExportSavedRecord)
                    } else if let onShare {
                        Button("Share") { onShare(record) }
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, ZOSpace.xl)
        .padding(.top, ZOSpace.m)
        .padding(.bottom, ZOSpace.s)
        .frame(maxWidth: .infinity)
        .background(theme.backgroundPrimary)
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: {
            Label(localization.string(title), systemImage: systemImage)
                .zoThemeText(.primaryButton).labelStyle(ZOIconLabelStyle())
                .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 56)
        }
        .buttonStyle(ZOButtonStyle(.primary))
    }

    private func metric(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(label)
                .zoThemeText(.caption)

                .foregroundStyle(secondaryInk)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .zoThemeText(.metric)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).zoProofText(.body, size: 15, lineHeight: 20, weight: 500).foregroundStyle(secondaryInk)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func stateCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Image(systemName: icon)
                .zoIcon(ZOIcon.feature)
                .accessibilityHidden(true)
                .foregroundStyle(theme.textPrimary)
            Text(localization.string(title))
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
            Text(localization.string(detail))
                .zoThemeText(.body)
                .foregroundStyle(secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        OutdoorPresentation.duration(seconds)
    }

    private func savedDateRange(_ record: OutdoorActivityRecord) -> String {
        let crossesDay = OutdoorPresentation.crossesCalendarDay(start: record.startedAt,
                                                                end: record.finishedAt,
                                                                calendar: calendar)
        let full: Date.FormatStyle = .dateTime.weekday(.wide).year().month().day().hour().minute()
        let start = OutdoorPresentation.date(record.startedAt, style: crossesDay ? full : .dateTime.weekday(.wide).hour().minute(),
                                             locale: localization.locale, calendar: calendar)
        let end = OutdoorPresentation.date(record.finishedAt, style: crossesDay ? full : .dateTime.hour().minute(),
                                           locale: localization.locale, calendar: calendar)
        return localization.format("outdoor.design.date.range", .text(start), .text(end))
    }

    private func finishActivity() async {
        let requestedID = model.checkpoint?.id
        await model.finish()
        guard model.surface == .summary,
              OutdoorPresentation.celebrates(finishedID: model.finishedRecord?.id,
                                            requestedID: requestedID,
                                            alreadyCelebrated: celebratedRecordIDs),
              let id = model.finishedRecord?.id else { return }
        celebratedRecordIDs.insert(id)
        tickRecordID = id
        if !reduceMotion { burstRecordID = id }
    }

    /// Empty decorative canvas, with no Core Location subscription before Start.
    private var emptyRoute: some View {
        Canvas { context, size in
            var grid = Path()
            for fraction in [0.25, 0.7] {
                grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(grid, with: .color(theme.surfaceTertiary), lineWidth: 8)
        }
        .frame(height: 220)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("outdoor.design.empty.route")
    }
}
