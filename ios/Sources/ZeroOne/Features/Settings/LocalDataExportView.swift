import SwiftUI
import UniformTypeIdentifiers

/// The prepared JSON or ZIP stays in memory until a Files destination is chosen.
/// ZIP staging is protected and cleaned by LocalDataExportArchive before presentation.
struct LocalDataExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .zip] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum LocalDataExportFormat: String, CaseIterable, Identifiable {
    case json, csv
    var id: String { rawValue }
    var title: String { self == .json ? "JSON" : "CSV files (ZIP)" }
    var contentType: UTType { self == .json ? .json : .zip }
}

@MainActor
struct LocalDataExportView: View {
    /// Host supplies a readback-verified export of only the selected sources.
    let makeJSON: @MainActor (LocalDataExportSelection) async throws -> Data

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var understandsPrivacy = false
    @State private var showsFilesPicker = false
    @State private var document: LocalDataExportDocument?
    @State private var statusMessage: String?
    @State private var isFailure = false
    @State private var selection = LocalDataExportSelection()
    @State private var isPreparing = false
    @State private var format = LocalDataExportFormat.json

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Take your data with you.")
                    .zoThemeText(.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                exportGroup("Include") {
                    VStack(spacing: 0) {
                        exportChoice("Completed workouts and recorded sets", isOn: $selection.workouts)
                        Divider().overlay(theme.strokeSubtle)
                        exportChoice("Meals and water", isOn: $selection.mealsAndWater)
                        Divider().overlay(theme.strokeSubtle)
                        exportChoice("Saved walks and runs", isOn: $selection.outdoorActivities)
                        Divider().overlay(theme.strokeSubtle)
                        exportChoice("Include route coordinates", isOn: $selection.routes)
                            .disabled(!selection.outdoorActivities)
                        Divider().overlay(theme.strokeSubtle)
                        exportChoice("Body-weight readings", isOn: $selection.bodyWeight)
                        Divider().overlay(theme.strokeSubtle)
                        exportChoice("Goals and preferences", isOn: $selection.goalsAndPreferences)
                    }
                    .disabled(isPreparing)
                    .padding(.horizontal, 16)
                    .zoThemeCardSurface()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Body weight is off unless you choose it. Selected records keep their saved values, units and dates. Water includes only the latest stored daily snapshot, not a historical log.")
                        Text("Routes are off unless chosen and may reveal where you live or train. Only saved walks and runs are included. Photos, voice data, raw HealthKit data and credentials are excluded. Selecting body weight can include readings you copied from Apple Health into 01.")
                        Text("Goals and preferences includes your saved display name, training choices, units, daily step/food goals, appearance and accent. Other settings and unsaved drafts are not included.")
                    }
                    .zoThemeText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if !selection.hasSelection {
                        Text("Choose at least one thing to export.")
                            .zoThemeText(.caption)
                            .foregroundStyle(theme.destructivePrimary)
                    }
                }

                exportGroup("Format") {
                    ZOSegmentedControl("Export format", selection: $format, options:
                        LocalDataExportFormat.allCases.map { value in
                            ZOSegment(value: value, label: Text(verbatim: localization.string(value.title)))
                        })
                        .disabled(isPreparing)
                    Text("CSV gives you separate spreadsheet tables in one ZIP, plus the exact JSON snapshot. If routes are selected and available, the ZIP includes a GPX track file.")
                        .zoThemeText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ZOAppIcon("lock", size: 20)
                            .accessibilityHidden(true)
                        Text("Private, and not encrypted")
                            .zoThemeText(.section)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("This export is private and unencrypted. Anyone who gets a copy can read the records you selected. Choose a trusted Files location and protect any copy you share.")
                        .zoThemeText(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("01 does not upload this file automatically. Workout history, meals and body-weight readings can be imported from an 01 JSON export after review, one category at a time. Complete outdoor history uses a separate transfer under Your data. This general export cannot restore outdoor activities or routes. ZIP, water and settings cannot be restored.")
                        .zoThemeText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand this file contains private records", isOn: $understandsPrivacy)
                        .toggleStyle(ZOToggleStyle())
                        .tint(theme.textPrimary)
                        .disabled(isPreparing)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: theme.designTheme == .freak ? .circular : .continuous))

                if isPreparing { ProgressView("Preparing selected records…") }
                if let statusMessage {
                    Text(localization.string(statusMessage))
                        .zoThemeText(.caption)
                        .foregroundStyle(isFailure ? theme.destructivePrimary : theme.textSecondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button { isPreparing = true } label: {
                HStack(spacing: 8) {
                    ZOAppIcon("download", size: 16).accessibilityHidden(true)
                    Text("Save export to Files")
                }
            }
            .buttonStyle(ZOButtonStyle(.primary, wide: true))
            .disabled(isPreparing || !understandsPrivacy || !selection.hasSelection)
            .accessibilityHint("Prepares the selected records, then asks where to save them in Files.")
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, 12)
            .background(theme.backgroundPrimary)
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(theme.textPrimary)
        .zoThemeScreenSurface()
        .task(id: isPreparing) {
            if isPreparing { await prepareExport() }
        }
        .onChange(of: selection) { _, _ in
            if !selection.outdoorActivities { selection.routes = false }
            understandsPrivacy = false
            document = nil
            statusMessage = nil
        }
        .onChange(of: format) { _, _ in
            understandsPrivacy = false
            document = nil
            statusMessage = nil
        }
        .fileExporter(
            isPresented: $showsFilesPicker,
            document: document,
            contentTypes: [format.contentType],
            defaultFilename: "01-local-data-export",
            onCompletion: { result in
                document = nil
                switch result {
                case .success:
                    isFailure = false
                    statusMessage = "Export saved to the Files location you chose."
                    understandsPrivacy = false
                case .failure:
                    isFailure = true
                    statusMessage = "Export was not saved. Your data is unchanged. Choose a location and try again."
                }
            },
            onCancellation: {
                document = nil
                isFailure = false
                statusMessage = "Export cancelled. Your data is unchanged."
            }
        )
    }

    private func exportChoice(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(verbatim: localization.string(title))
                .zoThemeText(.section)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        }
        .toggleStyle(ZOToggleStyle())
        .frame(minHeight: 56)
    }

    private func exportGroup<Content: View>(_ title: String,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: localization.string(title))
                .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            content()
        }
    }

    private func prepareExport() async {
        defer { isPreparing = false }
        guard understandsPrivacy, selection.hasSelection else { return }
        statusMessage = nil
        isFailure = false
        do {
            let json = try await makeJSON(selection)
            try Task.checkCancellation()
            guard !json.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            let data: Data
            if format == .csv {
                let job = Task.detached(priority: .userInitiated) { try LocalDataExportArchive.make(from: json) }
                data = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            } else { data = json }
            try Task.checkCancellation()
            document = LocalDataExportDocument(data: data)
            showsFilesPicker = true
        } catch is CancellationError {
            document = nil
        } catch LocalDataExportArchiveError.cleanupFailed {
            document = nil
            isFailure = true
            statusMessage = "Nothing was shared, but a temporary private export could not be removed. Your original records are unchanged."
        } catch {
            document = nil
            guard !Task.isCancelled else { return }
            isFailure = true
            statusMessage = "Export could not be prepared from local records. Nothing was saved or shared; try again later."
        }
    }
}
