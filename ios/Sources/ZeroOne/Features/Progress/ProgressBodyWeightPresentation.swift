import Foundation

/// Qualifies display evidence without changing storage, units or the trend's calendar windows.
struct BodyWeightObservationPresentation {
    enum State: Equatable { case unavailable, empty, futureOnly, observed }
    let state: State
    /// Nil means storage could not confirm its retained readings; [] means confirmed empty/currently future-only.
    let observedEntries: [BodyWeightEntry]?
    let futureCount: Int?

    init(entries: [BodyWeightEntry], isAvailable: Bool, now: Date) {
        guard isAvailable else {
            state = .unavailable
            observedEntries = nil
            futureCount = nil
            return
        }
        let observed = entries.filter { $0.recordedAt <= now }
        observedEntries = observed
        futureCount = entries.count - observed.count
        state = entries.isEmpty ? .empty : (observed.isEmpty ? .futureOnly : .observed)
    }
}

/// Presentation uses the exact existing save parser, including its unit-dependent accepted range.
enum BodyWeightReadingInputPresentation: Equatable {
    case empty, invalid, valid

    init(text: String, unit: BodyWeightUnit) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else {
            self = BodyWeightInput.kilograms(text, unit: unit) == nil ? .invalid : .valid
        }
    }
}
