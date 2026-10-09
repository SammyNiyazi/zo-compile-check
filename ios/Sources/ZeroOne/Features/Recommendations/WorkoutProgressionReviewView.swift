import SwiftUI

/// Functional review UI only. Final visual design remains founder-owned.
struct WorkoutProgressionReviewSection: View {
    let plans: [ExercisePlan]
    var sourceSessionID: UUID? = nil
    @Environment(\.zeroOneWorkoutProgression) private var authority
    @State private var selected: WorkoutProgressionReviewRequest?

    var body: some View {
        if let authority {
            let requests = plans.compactMap { authority.reviewRequest(for: $0, sourceSessionID: sourceSessionID) }
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Review your next load").zoText(.section)
                    Text("Confirm how the saved sets felt and the smallest available weight increase.")
                        .zoText(.label).foregroundStyle(.secondary)
                    ForEach(requests) { request in
                        Button { selected = request } label: {
                            HStack {
                                Text(verbatim: request.plan.name)
                                Spacer()
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(ZOButtonStyle(.secondary))
                    }
                }
                .sheet(item: $selected) { request in
                    Group {
                        WorkoutProgressionReviewView(authority: authority, request: request)
                    }
                    .zoSheet()
                }
            }
        }
    }
}

struct WorkoutProgressionReviewView: View {
    let authority: WorkoutProgressionAuthority
    let request: WorkoutProgressionReviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: WorkoutProgressionReviewSnapshot
    @State private var controlled: CheckInAnswer
    @State private var painFree: CheckInAnswer
    @State private var moreResistance: CheckInAnswer
    @State private var increment: String
    @State private var errorKey: String?

    init(authority: WorkoutProgressionAuthority, request: WorkoutProgressionReviewRequest) {
        self.authority = authority
        self.request = request
        let snapshot = authority.reviews.snapshot
        let existing = snapshot.reviews.first { $0.sourceSessionID == request.source.id && $0.occurrenceID == request.occurrence.id }
        let sameEvidence = existing?.sourceFingerprint == WorkoutProgressionEvidence.fingerprint(request.source)
            && existing?.planFingerprint == WorkoutProgressionEvidence.planFingerprint(request.plan)
        let review = sameEvidence ? existing : nil
        _baseline = State(initialValue: snapshot)
        _controlled = State(initialValue: CheckInAnswer(review?.controlledMovement))
        _painFree = State(initialValue: CheckInAnswer(review?.painFree))
        _moreResistance = State(initialValue: CheckInAnswer(review?.higherValueMeansMoreResistance))
        _increment = State(initialValue: review?.availableIncrement.map { String($0.value) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: request.plan.name).zoText(.section)
                    Text(request.source.completedAt, format: .dateTime.day().month().year())
                    Text("This reviews saved work. It does not change your recorded sets.")
                }
                Section("Saved sets") {
                    Picker("Was the movement controlled?", selection: $controlled) {
                        ForEach(CheckInAnswer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Were these sets pain-free?", selection: $painFree) {
                        ForEach(CheckInAnswer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Unreported effort or an unfinished workout cannot earn a higher load.")
                        .zoText(.caption).foregroundStyle(.secondary)
                }
                Section("Next-session equipment") {
                    TextField("Smallest available increase", text: $increment).keyboardType(.decimalPad)
                    Text(verbatim: request.plan.targetLoad.unit.rawValue)
                    Picker("Does a higher number mean more resistance?", selection: $moreResistance) {
                        ForEach(CheckInAnswer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Enter the increase for the same load you log. On assisted machines, a higher number can mean less resistance.")
                        .zoText(.caption).foregroundStyle(.secondary)
                }
                if let errorKey { Text(LocalizedStringResource(stringLiteral: errorKey)).foregroundStyle(.red) }
                Button("Save review", action: save).disabled(!authority.reviews.isAvailable)
            }
            .navigationTitle("Next load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func save() {
        let entered = increment.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = entered.isEmpty ? nil : Double(entered.replacingOccurrences(of: ",", with: "."))
        guard entered.isEmpty || amount.map({ $0.isFinite && $0 > 0 && $0 <= 20 }) == true,
              let sourceHash = WorkoutProgressionEvidence.fingerprint(request.source),
              let planHash = WorkoutProgressionEvidence.planFingerprint(request.plan) else {
            errorKey = "Enter a positive available increase, or leave it unreported."
            return
        }
        let now = Date()
        let review = WorkoutProgressionReview(id: UUID(), sourceSessionID: request.source.id,
            occurrenceID: request.occurrence.id, exerciseID: request.plan.exerciseID,
            sourceFingerprint: sourceHash, planFingerprint: planHash, reviewedAt: now,
            controlledMovement: controlled.value, painFree: painFree.value,
            availableIncrement: amount.map { Load($0, unit: request.plan.targetLoad.unit) },
            higherValueMeansMoreResistance: moreResistance.value)
        do {
            try authority.save(review, request: request, replacing: baseline, at: now)
            dismiss()
        } catch {
            errorKey = "The saved work or review changed. Close and reopen this review before trying again."
        }
    }
}
