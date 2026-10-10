import SwiftUI
import UniformTypeIdentifiers

struct OutdoorHistoryTransferJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= OutdoorHistoryTransferDecoder.maximumFileBytes else { throw OutdoorHistoryTransferError.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct LocalOutdoorHistoryTransferView: View {
    let coordinator: OutdoorHistoryTransferCoordinator
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var showsPicker = false
    @State private var selectedURL: URL?
    @State private var reviewedFileName: String?
    @State private var reviewedFileID: UUID?
    @State private var isReading = false
    @State private var showsReadingStatus = false
    @State private var reviewedRows = Set<UUID>()
    @State private var acknowledgesRoutes = false
    @State private var confirmsImport = false
    @State private var exportDocument: OutdoorHistoryTransferJSONDocument?
    @State private var showsExporter = false
    @State private var status: Message?
    @State private var isFailure = false

    private enum Message {
        case text(String)
        case confirmed(OutdoorHistoryTransferResult)
    }

    var body: some View {
        List {
            LocalDataScreenHeading(title: "Transfer walks and runs", symbol: "01.jog")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section("Outdoor history transfer") {
                Text("Transfer complete saved walks and runs between your own devices using an 01 outdoor-history JSON file.")
                Text("Full recorded route coordinates, accuracy, times, step intervals and gap boundaries are included. Deleted routes remain deleted. Review the private location data before exporting or importing.")
                    .foregroundStyle(theme.textSecondary)
                Text("Older general JSON exports omit facts needed for this transfer and cannot be imported here. Active or recoverable walks and runs must be resolved first.")
                    .foregroundStyle(theme.textSecondary)
                Text("01 reads and writes locally. You choose the export destination in Files; choosing a cloud folder may store this private file with that provider. No routes are shared by 01.")
                    .foregroundStyle(theme.textSecondary)
                ZOBanner(message: localization.string("Private, and not encrypted. Anyone with the file can read it. Keep it somewhere safe."), symbol: "lock")
                Button("Review saved outdoor history for export") { run { _ = try await coordinator.prepareExport() } }
                    .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    .disabled(blocksPreparation)
                Button("Choose outdoor-history JSON") {
                    run {
                        try await coordinator.discardReview()
                        showsPicker = true
                    }
                }
                .buttonStyle(ZOButtonStyle(coordinator.review == nil ? .primary : .secondary, wide: true))
                .disabled(blocksPreparation)
                if coordinator.review != nil {
                    Button(localization.string(coordinator.needsReconciliation ? "Check saved state and discard review" : "Discard review")) {
                        run { try await coordinator.discardReview() }
                    }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .disabled(busy)
                }
                if isReading && showsReadingStatus {
                    Text(localization.string("Reading selected file…"))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityLabel(localization.string("Loading"))
                }
            }
            .listRowBackground(theme.surfacePrimary)
            if let review = coordinator.review {
                if review.mode == .importing {
                    LocalDataImportPreviewCard(fileName: reviewedFileID == review.id ? reviewedFileName : nil, foundTitle: "Outdoor records found", found: review.records.count,
                        addedTitle: "New outdoor records", added: review.appendedCount,
                        skippedTitle: "Identical rows skipped", skipped: review.skippedCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                reviewSection(review)
                Section {
                    Toggle("I understand this transfer includes any recorded route coordinates", isOn: $acknowledgesRoutes)
                        .toggleStyle(ZOToggleStyle())
                    if review.mode == .importing {
                        Toggle("I want to add these reviewed outdoor records", isOn: $confirmsImport)
                            .toggleStyle(ZOToggleStyle())
                        if coordinator.needsReconciliation {
                            Text("An earlier write may have saved records. Checking saved history performs no further write. Discarding also checks saved state first and does not undo saved records.")
                                .foregroundStyle(theme.textSecondary)
                            Button("Check saved history without writing") { reconcile(review) }
                                .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                                .disabled(busy)
                        } else {
                            Button("Import reviewed outdoor history") { confirmImport(review) }
                                .buttonStyle(ZOButtonStyle(.primary))
                                .disabled(!canConfirm(review) || !confirmsImport)
                        }
                    } else {
                        Button("Save reviewed outdoor-history JSON to Files") { confirmExport(review) }
                            .buttonStyle(ZOButtonStyle(.primary))
                            .disabled(!canConfirm(review))
                    }
                }
                .listRowBackground(theme.surfacePrimary)
            }
            if let status {
                Section {
                    ZOBanner(message: messageText(status), symbol: isFailure ? "exclamationmark.circle" : "info.circle",
                        kind: isFailure ? .error : .information)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                    .listRowBackground(theme.surfacePrimary)
            }
        }
        .navigationTitle("Transfer walks and runs")
        .zoText(.body)
        .foregroundStyle(theme.textPrimary)
        .listStyle(.insetGrouped)
        .listSectionSpacing(ZOSpace.xl)
        .environment(\.defaultMinListRowHeight, ZOSpace.rowMinHeight)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .zoThemeScreenSurface()
        .modifier(LocalDataReadStatusDelay(isReading: isReading, isVisible: $showsReadingStatus))
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): selectedURL = urls.first
            case .failure: failed(OutdoorHistoryTransferError.invalidFile)
            }
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "01-outdoor-history") { result in
            switch result {
            case .success:
                status = .text("The reviewed outdoor-history JSON file was saved to your chosen destination.")
                isFailure = false
            case .failure:
                status = .text("The export file was not confirmed at its destination. Saved app history was kept.")
                isFailure = true
            }
            exportDocument = nil
        }
        .task(id: selectedURL) {
            guard let url = selectedURL else { return }
            isReading = true
            resetAcknowledgement()
            exportDocument = nil
            status = nil
            defer { isReading = false; selectedURL = nil }
            let read = Task.detached(priority: .userInitiated) { try WorkoutHistoryImportFile.read(url) }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                try Task.checkCancellation()
                let prepared = try await coordinator.prepareImport(data: data)
                reviewedFileID = prepared.id
                reviewedFileName = url.lastPathComponent
                isFailure = false
            } catch is CancellationError {
                status = .text("File review cancelled. No import was attempted.")
                isFailure = false
            } catch { failed(error) }
        }
    }

    private var busy: Bool { isReading || coordinator.isBusy }
    private var blocksPreparation: Bool { busy || coordinator.needsReconciliation }
    private func canConfirm(_ review: OutdoorHistoryTransferReview) -> Bool {
        !busy && acknowledgesRoutes && reviewedRows.count == review.records.count
    }
    private func resetAcknowledgement() { reviewedRows = []; acknowledgesRoutes = false; confirmsImport = false }

    private func reviewSection(_ review: OutdoorHistoryTransferReview) -> some View {
        Section("Review every saved record") {
            LabeledContent("Transfer version", value: String(review.package.schemaVersion))
            LabeledContent("Exported", value: timestamp(review.package.exportedAt))
            LabeledContent("Recorded coordinate fixes", value: String(review.coordinateCount))
            LabeledContent("Previously deleted routes", value: String(review.deletedRouteCount))
            if review.mode == .importing {
                LabeledContent("New outdoor records", value: String(review.appendedCount))
                LabeledContent("Identical rows skipped", value: String(review.skippedCount))
                Text("Workouts, food, water, body weight, photos and settings are not included in this transfer.")
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(review.rows) { row in
                let record = row.record
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(localization.string(record.kind == .walk ? "Walk" : "Run")).zoText(.section)
                    Text(timestamp(record.startedAt))
                    Text(localization.format("Confirmed active seconds: %1$@", .text(String(record.confirmedActiveSeconds))))
                    Text(localization.format("Recorded distance: %1$@", .text(record.recordedDistanceMeters.map { String($0) + " m" } ?? localization.string("Unknown"))))
                    Text(localization.format("Recorded steps: %1$@", .text(record.recordedSteps.map(String.init) ?? localization.string("Unknown"))))
                    if let deletedAt = record.routeDeletedAt {
                        Text(localization.format("Route deleted: %1$@", .text(timestamp(deletedAt))))
                    } else {
                        Text(localization.format("Route segments: %1$lld", .integer(record.route?.segments.count ?? 0)))
                    }
                    if record.hasMissingLocationCoverage { Text("Location coverage has recorded gaps.") }
                    if record.hasIncompleteStepCoverage { Text("Step coverage is incomplete.") }
                    DisclosureGroup("Recorded route and step details") {
                        Text(record.id.uuidString).textSelection(.enabled)
                        Text(localization.format("Record version: %1$lld; tracking mode: %2$@", .integer(record.version), .text(record.trackingMode.rawValue)))
                        Text(localization.format("Started seconds since 2001-01-01 UTC: %1$@", .text(String(record.startedAt.timeIntervalSinceReferenceDate))))
                        Text(localization.format("Finished seconds since 2001-01-01 UTC: %1$@", .text(String(record.finishedAt.timeIntervalSinceReferenceDate))))
                        if let deletedAt = record.routeDeletedAt {
                            Text(localization.format("Route deleted seconds since 2001-01-01 UTC: %1$@", .text(String(deletedAt.timeIntervalSinceReferenceDate))))
                        }
                        if let route = record.route {
                            Text(localization.format("Raw route metres: %1$@; measured interval: %2$@; location gaps: %3$@",
                                .text(String(route.totalRecordedMeters)), .text(boolean(route.hasMeasuredInterval)),
                                .text(boolean(route.hasMissingLocationCoverage))))
                        }
                        Text(localization.format("Step clock discontinuity: %1$@", .text(boolean(record.steps.hasClockDiscontinuity))))
                        ForEach(record.route?.segments ?? []) { segment in
                            DisclosureGroup(localization.format("Segment %1$@", .text(segment.id.uuidString))) {
                                Text(localization.format("Pause endpoint: %1$@", .text(segment.endsAtUserPause.map(boolean) ?? localization.string("Unknown"))))
                                // Validated raw timestamps are unique and immutable.
                                ForEach(segment.points, id: \.timestamp) { point in
                                    Text(localization.format("%1$@, %2$@; accuracy %3$@ m; time %4$@",
                                        .text(String(point.latitude)), .text(String(point.longitude)),
                                        .text(String(point.horizontalAccuracyMeters)), .text(String(point.timestamp.timeIntervalSinceReferenceDate))))
                                }
                            }
                        }
                        ForEach(record.steps.intervals) { interval in
                            VStack(alignment: .leading) {
                                Text(localization.format("%1$@: %2$@; %3$@", .text(interval.id.uuidString),
                                    .text(interval.latestCumulativeSteps.map(String.init) ?? localization.string("Unknown")),
                                    .text(localization.string(interval.isFinal ? "Final" : "Incomplete"))))
                                Text(localization.format("Started: %1$@; ended: %2$@; last sample: %3$@",
                                    .text(String(interval.startedAt.timeIntervalSinceReferenceDate)),
                                    .text(interval.endedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? localization.string("Unknown")),
                                    .text(interval.lastSampleAt.map { String($0.timeIntervalSinceReferenceDate) } ?? localization.string("Unknown"))))
                            }
                        }
                    }
                    Toggle("I reviewed this outdoor record", isOn: Binding(get: { reviewedRows.contains(row.id) }, set: { value in
                        if value { reviewedRows.insert(row.id) } else { reviewedRows.remove(row.id) }
                    })).toggleStyle(ZOToggleStyle())
                }
            }
        }
        .listRowBackground(theme.surfacePrimary)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        resetAcknowledgement()
        exportDocument = nil
        status = nil
        Task { do { try await operation(); isFailure = false } catch { failed(error) } }
    }
    private func confirmImport(_ review: OutdoorHistoryTransferReview) {
        Task {
            do { succeeded(try await coordinator.confirmImport(reviewID: review.id, acknowledgesRouteData: acknowledgesRoutes)) }
            catch { failed(error) }
        }
    }
    private func confirmExport(_ review: OutdoorHistoryTransferReview) {
        Task {
            do {
                let data = try await coordinator.confirmExport(reviewID: review.id, acknowledgesRouteData: acknowledgesRoutes)
                exportDocument = OutdoorHistoryTransferJSONDocument(data: data)
                showsExporter = true
                isFailure = false
            } catch { failed(error) }
        }
    }
    private func reconcile(_ review: OutdoorHistoryTransferReview) {
        Task {
            do {
                if let result = try await coordinator.reconcile(reviewID: review.id) { succeeded(result) }
                else { status = .text("Saved outdoor history is unchanged. Start a fresh review before retrying."); isFailure = false; resetAcknowledgement() }
            } catch { failed(error) }
        }
    }
    private func succeeded(_ result: OutdoorHistoryTransferResult) {
        resetAcknowledgement()
        status = .confirmed(result)
        isFailure = false
    }
    private func failed(_ error: Error) {
        status = .text((error as? OutdoorHistoryTransferError)?.errorDescription
            ?? (error as? WorkoutHistoryImportError)?.errorDescription ?? "Outdoor transfer could not be confirmed. Saved records have been kept.")
        isFailure = true
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(localization.locale))
    }
    private func boolean(_ value: Bool) -> String { localization.string(value ? "Yes" : "No") }
    private func messageText(_ message: Message) -> String {
        switch message {
        case .text(let key): localization.string(key)
        case .confirmed(let result): localization.format("Outdoor history confirmed: %1$lld added, %2$lld identical rows skipped.",
            .integer(result.appendedCount), .integer(result.skippedCount))
        }
    }
}
