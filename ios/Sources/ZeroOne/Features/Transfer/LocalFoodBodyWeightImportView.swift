import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LocalFoodBodyWeightImportView: View {
    let coordinator: FoodBodyWeightImportCoordinator
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
    @State private var reviewedRows = Set<Int>()
    @State private var confirmsCategory = false

    private enum Message {
        case text(String)
        case confirmed(FoodBodyWeightImportResult)
    }

    var body: some View {
        List {
            LocalDataScreenHeading(title: coordinator.category == .meals ? "Import food records" : "Import body weight",
                symbol: coordinator.category == .meals ? "fork.knife" : "scalemass")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section(localization.string(coordinator.category.title)) {
                Text("Choose an 01 JSON export from Files. Review every row before adding this category to this iPhone.")
                Text("Existing records are kept. Identical identifiers and values are skipped. A conflicting identifier blocks the entire chosen category.")
                Text("Each category is imported separately. Water snapshots, workouts, outdoor activities, routes and settings are skipped here. Signing in does not sync these records.")
                    .foregroundStyle(theme.textSecondary)
                Text("The selected file is read locally and is never uploaded. Imported food does not write to Apple Health.")
                    .foregroundStyle(theme.textSecondary)
                if coordinator.category == .bodyWeight {
                    Text("Stored values remain in kilograms. The original input source stays unknown.")
                        .foregroundStyle(theme.textSecondary)
                }
                Button("Choose JSON export") { startReview() }
                    .buttonStyle(ZOButtonStyle(coordinator.review == nil ? .primary : .secondary, wide: true))
                    .disabled(isReading || coordinator.needsReconciliation)
                if coordinator.review != nil {
                    Button("Discard review") {
                        coordinator.discardReview()
                        resetAcknowledgement()
                        status = .text("The review was discarded. Saved records have been kept.")
                        isFailure = false
                    }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .disabled(isReading)
                }
                if coordinator.needsReconciliation {
                    Text("An earlier write may have saved records. Check saved records without writing again, or start a fresh review to compare every row again. Discarding does not undo a saved write.")
                        .foregroundStyle(theme.textSecondary)
                    Button("Start a fresh file review") { startReview() }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                        .disabled(isReading)
                }
                if isReading && showsReadingStatus {
                    Text(localization.string("Reading selected file…"))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityLabel(localization.string("Loading"))
                }
            }
            .listRowBackground(theme.surfacePrimary)
            if let review = coordinator.review {
                LocalDataImportPreviewCard(fileName: reviewedFileID == review.id ? reviewedFileName : nil, foundTitle: review.category == .meals ? "Food records found" : "Body-weight readings found",
                    found: review.meals.count + review.weights.count,
                    addedTitle: "New records", added: review.appendedCount,
                    skippedTitle: "Identical records skipped", skipped: review.skippedCount)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                reviewSection(review)
                Section {
                    Toggle("I want to add this reviewed category", isOn: $confirmsCategory)
                        .toggleStyle(ZOToggleStyle())
                    if coordinator.needsReconciliation {
                        Button("Check saved records without writing") { reconcile(review) }
                            .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                            .disabled(isReading)
                    } else {
                        Button("Import reviewed records") { confirm(review) }
                            .buttonStyle(ZOButtonStyle(.primary))
                            .disabled(!confirmsCategory || !allRowsReviewed(review) || isReading)
                            .accessibilityHint("Checks fresh saved state before adding the complete reviewed category.")
                    }
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
        .navigationTitle(localization.string(coordinator.category == .meals ? "Import food records" : "Import body weight"))
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
            case .failure:
                status = .text("The file could not be opened. No import was attempted.")
                isFailure = true
            }
        }
        .task(id: selectedURL) {
            guard let url = selectedURL else { return }
            isReading = true
            status = nil
            resetAcknowledgement()
            defer { isReading = false; selectedURL = nil }
            // Reuse the existing bounded/security-scoped file reader unchanged.
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
                status = .text((error as? FoodBodyWeightImportError)?.errorDescription
                    ?? (error as? WorkoutHistoryImportError)?.errorDescription
                    ?? "The file could not be reviewed. No import was attempted.")
                isFailure = true
            }
        }
    }

    private func reviewSection(_ review: FoodBodyWeightImportReview) -> some View {
        Section("Review every row") {
            LabeledContent("Export version", value: String(review.schemaVersion))
            LabeledContent("Exported", value: timestamp(review.exportedAt))
            LabeledContent("New records", value: String(review.appendedCount))
            LabeledContent("Identical records skipped", value: String(review.skippedCount))
            if !review.skippedCategories.isEmpty {
                Text(localization.format("Other selected or present categories skipped: %1$@.",
                    .text(review.skippedCategories.map { localization.string($0) }.joined(separator: ", "))))
                    .foregroundStyle(theme.textSecondary)
            }
            if review.category == .meals {
                ForEach(review.meals.indices, id: \.self) { index in
                    let entry = review.meals[index]
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(entry.title).zoText(.section)
                        Text(timestamp(entry.loggedAt))
                        Text("\(entry.calories) kcal")
                        Text(localization.format("Protein: %1$@", .text(macro(entry.proteinGrams))))
                        Text(localization.format("Carbohydrates: %1$@", .text(macro(entry.carbohydrateGrams))))
                        Text(localization.format("Fat: %1$@", .text(macro(entry.fatGrams))))
                        sourceDetails(id: entry.id, date: entry.loggedAt)
                        acknowledgement(index)
                    }
                }
            } else {
                ForEach(review.weights.indices, id: \.self) { index in
                    let entry = review.weights[index]
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(NSDecimalNumber(decimal: entry.kilograms).stringValue + " kg").zoText(.section)
                        Text(timestamp(entry.recordedAt))
                        Text("Original input source unknown").foregroundStyle(theme.textSecondary)
                        sourceDetails(id: entry.id, date: entry.recordedAt)
                        acknowledgement(index)
                    }
                }
            }
        }
        .listRowBackground(theme.surfacePrimary)
    }

    private func sourceDetails(id: UUID, date: Date) -> some View {
        DisclosureGroup("Stored identifier and time") {
            Text(id.uuidString).textSelection(.enabled)
            Text(localization.format("Seconds since 2001-01-01 UTC: %1$@", .text(String(date.timeIntervalSinceReferenceDate))))
                .textSelection(.enabled)
        }
    }
    private func macro(_ value: Double?) -> String {
        value.map { String($0) + " g" } ?? localization.string("Unknown")
    }
    private func acknowledgement(_ index: Int) -> some View {
        Toggle("I reviewed this row", isOn: Binding(
            get: { reviewedRows.contains(index) },
            set: { checked in
                if checked { reviewedRows.insert(index) } else { reviewedRows.remove(index) }
            }
        )).toggleStyle(ZOToggleStyle())
    }
    private func allRowsReviewed(_ review: FoodBodyWeightImportReview) -> Bool {
        reviewedRows.count == review.meals.count + review.weights.count
    }
    private func resetAcknowledgement() { reviewedRows = []; confirmsCategory = false }
    private func startReview() {
        coordinator.discardReview()
        resetAcknowledgement()
        status = nil
        showsPicker = true
    }
    private func confirm(_ review: FoodBodyWeightImportReview) {
        do { succeeded(try coordinator.confirm(reviewID: review.id)) }
        catch { failed(error) }
    }
    private func reconcile(_ review: FoodBodyWeightImportReview) {
        do {
            if let result = try coordinator.reconcile(reviewID: review.id) { succeeded(result) }
            else {
                resetAcknowledgement()
                status = .text("Saved records are unchanged. Choose the file again for a fresh review before retrying.")
                isFailure = false
            }
        } catch { failed(error) }
    }
    private func succeeded(_ result: FoodBodyWeightImportResult) {
        resetAcknowledgement()
        status = .confirmed(result)
        isFailure = false
    }
    private func failed(_ error: Error) {
        status = .text((error as? FoodBodyWeightImportError)?.errorDescription
            ?? "Import is blocked until saved records can be checked.")
        isFailure = true
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(localization.locale))
    }

    private func messageText(_ message: Message) -> String {
        switch message {
        case .text(let key): localization.string(key)
        case .confirmed(let result): localization.format(
            "%1$@ confirmed: %2$lld added, %3$lld identical rows skipped. Other categories were kept.",
            .text(localization.string(result.category.title)), .integer(result.appendedCount), .integer(result.skippedCount))
        }
    }
}
