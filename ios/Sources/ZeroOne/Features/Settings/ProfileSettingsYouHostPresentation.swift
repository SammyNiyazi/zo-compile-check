import Foundation

/// Maps the existing host's currently observed, acknowledged local state.
/// Its history input must be the full unfiltered WorkoutHistoryRepository.surfaceState.
/// This boundary does not claim a fresh disk reread, allocate a card or grant access.
enum ProfileSettingsYouHostPresentation {
    struct Capabilities: Equatable {
        let personalDetails: Bool
        let bodyWeight: Bool
        let photo: Bool
    }

    static func capabilities(profileAvailable: Bool, weightAvailable: Bool,
                             photoAvailable: Bool, accountBusy: Bool) -> Capabilities {
        .init(personalDetails: profileAvailable && !accountBusy,
              bodyWeight: weightAvailable && !accountBusy,
              photo: photoAvailable && !accountBusy)
    }

    static func snapshot(asOf: Date, calendar: Calendar, displayName: String?, profileAvailable: Bool,
                         historyState: WorkoutHistorySurfaceState, bodyWeightEntries: [BodyWeightEntry]?,
                         bodyWeightUnitRawValue: String?, themeRawValue: String?) -> ProfileSettingsYouSnapshot {
        .init(asOf: asOf, displayName: profileAvailable ? displayName : nil,
              card: nil, month: observedMonth(state: historyState, asOf: asOf, calendar: calendar),
              bodyWeight: observedWeight(entries: bodyWeightEntries, asOf: asOf, unitRawValue: bodyWeightUnitRawValue),
              edition: edition(themeRawValue: themeRawValue))
    }

    static func edition(themeRawValue: String?) -> ProfileSettingsYouEdition {
        switch DesignThemePreference.storedValue(themeRawValue) {
        case .core: .onyx
        case .retro: .neon
        case .freak: .chrome
        case .princess: .pink
        }
    }

    /// AppRoot passes the repository's complete observed surface directly.
    /// Unavailable never becomes empty; no entitlement/global/social/goal facts follow.
    static func observedMonth(state: WorkoutHistorySurfaceState, asOf: Date,
                              calendar: Calendar) -> ProfileSettingsYouMonth? {
        let observedEntries: [WorkoutHistoryEntry]?
        switch state {
        case .unavailable: observedEntries = nil
        case .empty: observedEntries = []
        case let .entries(items): observedEntries = items.map(\.sourceEntry)
        }
        // Same shape/time checks as the reviewed factory, with an explicit narrower
        // observed-surface contract. No fresh persistence authority is manufactured.
        return ProfileSettingsYouPresentation.recordedMonth(history: observedEntries, asOf: asOf, calendar: calendar)
    }

    static func observedWeight(entries: [BodyWeightEntry]?, asOf: Date,
                               unitRawValue: String?) -> ProfileSettingsYouWeight? {
        guard let entries, asOf.timeIntervalSinceReferenceDate.isFinite,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({
                  $0.recordedAt.timeIntervalSinceReferenceDate.isFinite
                      && NSDecimalNumber(decimal: $0.kilograms).doubleValue.isFinite
                      && (0.5...1_000).contains(NSDecimalNumber(decimal: $0.kilograms).doubleValue)
              }),
              let latest = entries.filter({ $0.recordedAt <= asOf }).sorted(by: {
                  if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
                  return $0.id.uuidString < $1.id.uuidString
              }).first else { return nil }
        // Uses BodyWeightScreen's existing resolver/conversion, including its kg fallback.
        let unit = unitRawValue.flatMap(BodyWeightUnit.init(rawValue:)) ?? .kilograms
        return ProfileSettingsYouWeight(value: unit.displayedValue(for: latest.kilograms),
                                        unit: unit == .kilograms ? .kilograms : .pounds)
    }
}
