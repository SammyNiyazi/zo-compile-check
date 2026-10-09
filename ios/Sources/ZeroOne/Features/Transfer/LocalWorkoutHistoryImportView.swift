import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LocalWorkoutHistoryImportView: View {
    let coordinator: WorkoutHistoryImportCoordinator
    /// Refresh app-owned history and programme/source associations after verified
    /// persistence. A failed refresh is reported separately from the saved import.
    let didConfirm: @MainActor ([WorkoutHistoryEntry]) throws -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var showsPicker = false
    @State private var selectedURL: URL?
    @State private var reviewedFileName: String?
    @State private var reviewedFileID: UUID?
    @State private var isReading = false
    @State private var showsReadingStatus = false
    @State private var status: Message?
    @State private var isFailure = false
    @State private var reviewed = false

    private enum Message {
        case text(String)
        case confirmed(added: Int, skipped: Int)
    }
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    var body: some View {
        List {
            LocalDataScreenHeading(title: "Import workout history", symbol: "dumbbell")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section("Workout history transfer") {
                Text("Choose an 01 JSON export from Files to review completed workouts and recorded sets on this iPhone. Existing history is kept. Identical records are skipped; conflicting records block the whole import.")
                Text("This imports workout history only. Meals, water, body weight, outdoor activities, routes and settings are not restored. Signing in does not sync these records.")
                    .foregroundStyle(theme.textSecondary)
                Text("The file contains private records. 01 reads it locally and does not upload it.")
                    .foregroundStyle(theme.textSecondary)
                Button("Choose JSON export") {
                    coordinator.discardReview()
                    reviewed = false
                    showsPicker = true
                }
                    .buttonStyle(ZOButtonStyle(coordinator.review == nil ? .primary : .secondary, wide: true))
                    .disabled(isReading || coordinator.needsReconciliation)
                if coordinator.needsReconciliation {
                    Button("Start a fresh file review") {
                        coordinator.discardReview()
                        reviewed = false
                        status = .text("The previous confirmation was left unconfirmed. Choose the export again to check all records against saved history.")
                        isFailure = false
                        showsPicker = true
                    }
                    .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    Text("A fresh review keeps any saved records and checks duplicates again. It does not undo a previous write.")
                        .foregroundStyle(theme.textSecondary)
                }
                if isReading && showsReadingStatus {
                    Text(localization.string("Reading selected file…"))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityLabel(localization.string("Loading"))
                }
            }
            .listRowBackground(theme.surfacePrimary)

            if let review = coordinator.review {
                LocalDataImportPreviewCard(fileName: reviewedFileID == review.id ? reviewedFileName : nil, foundTitle: "Workouts found", found: review.records.count,
                    addedTitle: "New workouts", added: review.appendedCount,
                    skippedTitle: "Identical workouts skipped", skipped: review.skippedCount)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                reviewSection(review)
                Section {
                    Toggle("I reviewed these records and want to add them", isOn: $reviewed)
                        .toggleStyle(ZOToggleStyle())
                    Button(localization.string(coordinator.needsReconciliation ? "Retry and check saved history" : "Import reviewed workout history")) {
                        confirm(review)
                    }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .disabled(!reviewed || isReading)
                    .accessibilityHint("Checks fresh saved history before appending the complete reviewed collection.")
                }
                .listRowBackground(theme.surfacePrimary)
            }
            if let status {
                Section {
                    ZOBanner(message: messageText(status), symbol: isFailure ? "exclamationmark.circle" : "info.circle", kind: isFailure ? .error : .information)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .listRowBackground(theme.surfacePrimary)
            }
        }
        .navigationTitle("Import workout history")
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
            case .success(let urls):
                selectedURL = urls.first
            case .failure:
                status = .text("The file could not be opened. No import was attempted.")
                isFailure = true
            }
        }
        .task(id: selectedURL) {
            guard let url = selectedURL else { return }
            isReading = true
            reviewed = false
            status = nil
            defer { isReading = false; selectedURL = nil }
            let read = Task.detached(priority: .userInitiated) { try WorkoutHistoryImportFile.read(url) }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                try Task.checkCancellation()
                let prepared = try coordinator.prepare(data: data)
                reviewedFileID = prepared.id
                reviewedFileName = url.lastPathComponent
                isFailure = false
            } catch is CancellationError {
                status = .text("File review cancelled. No import was attempted.")
                isFailure = false
            } catch {
                status = .text((error as? WorkoutHistoryImportError)?.errorDescription
                    ?? "The file could not be reviewed. No import was attempted.")
                isFailure = true
            }
        }
    }

    private func reviewSection(_ review: WorkoutHistoryImportReview) -> some View {
        Section("Review before import") {
            LabeledContent("Export version", value: "\(review.schemaVersion)")
            LabeledContent("Exported", value: timestamp(review.exportedAt))
            LabeledContent("New workouts", value: "\(review.appendedCount)")
            LabeledContent("Identical workouts skipped", value: "\(review.skippedCount)")
            if review.summaryOnlyCount > 0 {
                Text(localization.format("%1$lld older workouts have summaries only. Missing exercise details stay unknown.", .integer(review.summaryOnlyCount)))
                    .foregroundStyle(theme.textSecondary)
            }
            if review.legacyEffortCount > 0 {
                Text(localization.format("%1$lld sets contain older effort values outside today's input range. Their original values are preserved.", .integer(review.legacyEffortCount)))
                    .foregroundStyle(theme.textSecondary)
            }
            if !review.untouchedCategories.isEmpty {
                Text(localization.format("Also present in this file, left untouched: %1$@.",
                    .text(review.untouchedCategories.map { localization.string($0) }.joined(separator: ", "))))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(review.records) { entry in
                DisclosureGroup {
                    if let exercises = entry.exercises {
                        ForEach(exercises) { exercise in
                            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                                Text(ExerciseLibrary.exercise(id: exercise.exerciseID)?.name ?? exercise.exerciseID.rawValue)
                                    .zoText(.section)
                                if let prescription = exercise.targetPrescription {
                                    Text(localization.format("Saved target: %1$@", .text(workoutCopy.prescription(prescription))))
                                }
                                ForEach(exercise.completedSets) { set in
                                    Text(localization.format("%1$@, %2$@, %3$@",
                                        .text(workoutCopy.load(set.load)), .text(workoutCopy.performance(set)),
                                        .text(set.rir.map { localization.format("recorded RIR %1$lld", .integer($0)) }
                                            ?? localization.string("effort unknown"))))
                                }
                                if exercise.completedSets.isEmpty { Text("No recorded sets") }
                            }
                        }
                    } else { Text("Exercise details were not recorded.") }
                } label: {
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text(entry.title).zoText(.section)
                        Text(timestamp(entry.completedAt))
                        Text(localization.format("%1$lld recorded / %2$lld planned sets", .integer(entry.completedSetCount), .integer(entry.plannedSetCount)))
                    }
                }
            }
        }
        .listRowBackground(theme.surfacePrimary)
    }

    private func confirm(_ review: WorkoutHistoryImportReview) {
        do {
            let result = try coordinator.confirm(reviewID: review.id)
            reviewed = false
            do {
                try didConfirm(result.confirmedEntries)
                isFailure = false
                status = .confirmed(added: result.appendedCount, skipped: result.skippedCount)
            } catch {
                isFailure = true
                status = .text("Workout history was saved and verified, but the app could not refresh its history display. Close this screen and reopen History. Other data was left untouched.")
            }
        } catch {
            isFailure = true
            status = .text((error as? WorkoutHistoryImportError)?.errorDescription
                ?? "Import is blocked until saved workout state can be checked.")
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(localization.locale))
    }

    private func messageText(_ message: Message) -> String {
        switch message {
        case .text(let key): localization.string(key)
        case .confirmed(let added, let skipped): localization.format(
            "Workout history confirmed: %1$lld added, %2$lld identical records skipped. Other data was left untouched.",
            .integer(added), .integer(skipped))
        }
    }
}
