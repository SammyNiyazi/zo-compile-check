import Foundation

/// Explicit allowlist. Never encode ZeroOneUserProfile wholesale: it also holds
/// body-weight drafts, onboarding markers and internal plan IDs.
struct LocalProfilePreferencesExport: Codable, Equatable {
    let displayName: String?
    let initialsTone: String?
    let trainingGoal: String?
    let trainingGoals: [String]?
    let trainingExperience: String?
    let weeklyAvailability: String?
    let equipmentAccess: String?
    let trainingConstraint: String?
    let trainingSport: String?
    let availableEquipment: [String]?
    let preferredTrainingDaysMondayZeroBased: [Int]?
    let preferredSessionMinutes: Int?
    let preferredWeightUnit: String?
    let preferredDistanceUnit: String?

    init(_ profile: ZeroOneUserProfile) {
        displayName = profile.displayName
        initialsTone = profile.initialsTone?.rawValue
        trainingGoal = profile.trainingGoal?.rawValue
        trainingGoals = profile.selectedTrainingGoals.isEmpty ? nil : profile.selectedTrainingGoals.map(\.rawValue)
        trainingExperience = profile.trainingExperience?.rawValue
        weeklyAvailability = profile.weeklyAvailability?.rawValue
        equipmentAccess = profile.equipmentAccess?.rawValue
        trainingConstraint = profile.trainingConstraint?.rawValue
        trainingSport = profile.trainingSport?.rawValue
        availableEquipment = profile.availableEquipment?.map(\.rawValue).sorted()
        preferredTrainingDaysMondayZeroBased = profile.preferredTrainingDays?.map(\.rawValue).sorted()
        preferredSessionMinutes = profile.preferredSessionMinutes
        preferredWeightUnit = profile.preferredWeightUnit?.rawValue
        preferredDistanceUnit = profile.preferredDistanceUnit?.rawValue
    }
}

struct LocalSettingsExport: Codable, Equatable {
    let profile: LocalProfilePreferencesExport?
    let dailyGoals: DailyGoals
    let appearancePreference: String
    let accentPreference: String?

    init(profile: ZeroOneUserProfile?, dailyGoals: DailyGoals, appearancePreference: String,
         accentPreference: String = AccentPreference.yellow.rawValue) throws {
        guard profile?.isCompatible ?? true, dailyGoals.isValid,
              AppearancePreference(rawValue: appearancePreference) != nil,
              AccentPreference(rawValue: accentPreference) != nil else {
            throw LocalDataExportError.settingsUnavailable
        }
        self.profile = profile.map(LocalProfilePreferencesExport.init)
        self.dailyGoals = dailyGoals
        self.appearancePreference = appearancePreference
        self.accentPreference = accentPreference
    }
}
