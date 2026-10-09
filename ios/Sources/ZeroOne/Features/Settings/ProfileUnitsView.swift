import SwiftUI

struct ZeroOneProfileUnitSelection: Equatable, Sendable {
    let weight: ZeroOneWeightPreference
    let distance: ZeroOneDistancePreference

    static func validated(weightRawValue: String, distanceRawValue: String) -> Self? {
        guard let weight = ZeroOneWeightPreference(rawValue: weightRawValue),
              let distance = ZeroOneDistancePreference(rawValue: distanceRawValue) else {
            return nil
        }
        return Self(weight: weight, distance: distance)
    }

    static func resolved(
        profile: ZeroOneUserProfile,
        bodyWeightUnitRawValue: String?,
        locale: Locale = .current
    ) -> Self {
        let bodyWeightPreference = bodyWeightUnitRawValue.flatMap(ZeroOneWeightPreference.init(rawValue:))
        return Self(
            weight: profile.preferredWeightUnit ?? bodyWeightPreference ?? ZeroOneOnboardingUnitDefaults.weight(for: locale),
            distance: profile.preferredDistanceUnit ?? ZeroOneOnboardingUnitDefaults.distance(for: locale)
        )
    }

    var bodyWeightUnitRawValue: String {
        switch weight {
        case .kilograms: BodyWeightUnit.kilograms.rawValue
        case .pounds: BodyWeightUnit.pounds.rawValue
        }
    }

    func applying(to profile: ZeroOneUserProfile, previousWeight: ZeroOneWeightPreference) -> ZeroOneUserProfile {
        var updated = profile
        if previousWeight != weight, let current = profile.startingBodyWeight, current.isFinite {
            let source: UnitMass = previousWeight == .kilograms ? .kilograms : .pounds
            let destination: UnitMass = weight == .kilograms ? .kilograms : .pounds
            updated.startingBodyWeight = Measurement(value: current, unit: source)
                .converted(to: destination).value
        }
        updated.preferredWeightUnit = weight
        updated.preferredDistanceUnit = distance
        return updated
    }
}

struct ProfileUnitsView: View {
    @Bindable var profileRepository: ZeroOneUserProfileRepository
    @AppStorage("slick.bodyWeightUnit") private var bodyWeightUnitRawValue = BodyWeightUnit.kilograms.rawValue
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @State private var draftWeight: ZeroOneWeightPreference
    @State private var draftDistance: ZeroOneDistancePreference
    @State private var saveError: String?
    private let originalWeight: ZeroOneWeightPreference

    init(
        profileRepository: ZeroOneUserProfileRepository,
        locale: Locale = .current,
        bodyWeightUnitRawValue: String? = UserDefaults.standard.string(forKey: "slick.bodyWeightUnit")
    ) {
        self.profileRepository = profileRepository
        let selection = ZeroOneProfileUnitSelection.resolved(
            profile: profileRepository.profile,
            bodyWeightUnitRawValue: bodyWeightUnitRawValue,
            locale: locale
        )
        _draftWeight = State(initialValue: selection.weight)
        _draftDistance = State(initialValue: selection.distance)
        originalWeight = selection.weight
    }

    private var draftSelection: ZeroOneProfileUnitSelection {
        ZeroOneProfileUnitSelection(weight: draftWeight, distance: draftDistance)
    }

    private var hasChanges: Bool {
        profileRepository.profile.preferredWeightUnit != draftWeight
            || profileRepository.profile.preferredDistanceUnit != draftDistance
            || bodyWeightUnitRawValue != draftSelection.bodyWeightUnitRawValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            ProfilePersistenceNotice(repository: profileRepository)
            // Proof 46: Weight and Distance as segmented controls under their
            // group titles, then the promise about sets already logged.
            SettingsThemeGroup(title: "Weight", hasCard: false) {
                ZOSegmentedControl("Weight", selection: $draftWeight, options: ZeroOneWeightPreference.allCases.map { unit in ZOSegment(value: unit, label: Text(localization.string(unit.title))) })
                .accessibilityIdentifier("profile.units.weight")
            }
            // First group: proof scroll top6 + group margin22; a visible notice already supplies the group gap.
            .padding(.top, profileRepository.saveError == nil ? 22 : 0)

            SettingsThemeGroup(title: "Distance", hasCard: false) {
                VStack(alignment: .leading, spacing: 10) {
                ZOSegmentedControl("Distance", selection: $draftDistance, options: ZeroOneDistancePreference.allCases.map { unit in ZOSegment(value: unit, label: Text(localization.string(unit.title))) })
                .accessibilityIdentifier("profile.units.distance")

            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("Sets you already logged keep the unit they were logged in.")
                Text("Weight also controls how the Body weight screen displays readings. Distance is saved for distance-based experiences; changing it does not create or convert route history.")
            }
            .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }

            SettingsThemeGroup(title: "Recorded data stays recorded") {
                Text("Existing workout sets keep the unit and value recorded with each set.")
                Text("Body-weight readings remain stored canonically in kilograms. This preference changes only their display.")
            }
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)

            SettingsThemeGroup(title: "Language", isList: true) {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    HStack(spacing: ZOSpace.m) {
                        LabeledContent("App language") {
                            Text(verbatim: localization.language.nativeName)
                                .zoProofText(.body, size: 15, lineHeight: 20).foregroundStyle(theme.textSecondary)
                        }.zoText(.section).frame(maxWidth: .infinity)
                        Image(systemName: "chevron.forward").zoIcon(ZOIcon.inline)
                            .foregroundStyle(theme.textTertiary).accessibilityHidden(true)
                    }.modifier(SettingsThemeListRow()).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.units.language")
            }

            if let saveError {
                Text(saveError)
                    .foregroundStyle(theme.destructivePrimary)
                    .accessibilityAddTraits(.updatesFrequently)

            }
            }.padding(.horizontal, ZOSpace.screenMargin).padding(.top, 6).padding(.bottom, ZOSpace.screenMargin)
        }
        .navigationTitle("Units & language")
        .navigationBarTitleDisplayMode(.inline)

        .foregroundStyle(theme.textPrimary)
        .zoThemeScreenSurface()
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Units & language").zoText(.section) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!hasChanges)
            }
        }
    }

    private func save() {
        let selection = draftSelection
        let previousWeight = profileRepository.profile.preferredWeightUnit ?? originalWeight
        guard profileRepository.updateVerified({ profile in
            profile = selection.applying(to: profile, previousWeight: previousWeight)
        }) else {
            saveError = "Couldn't save your unit preferences on this iPhone. Try again; your choices are still here."
            return
        }

        bodyWeightUnitRawValue = selection.bodyWeightUnitRawValue
        guard UserDefaults.standard.string(forKey: "slick.bodyWeightUnit") == selection.bodyWeightUnitRawValue else {
            saveError = "Your training preferences saved, but Body Weight display did not update. Retry to finish."
            return
        }
        saveError = nil
        dismiss()
    }
}

/// Proof `.zo-group-t`: 13 pt semibold in the secondary ink, sentence case.
/// Shared by the settings screens in this folder.
struct SettingsGroupTitle: View {
    private let title: LocalizedStringKey
    @Environment(\.zeroOneTheme) private var theme

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .zoText(.caption)
            .fontWeight(.semibold)
            .textCase(nil)
            .foregroundStyle(theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}
