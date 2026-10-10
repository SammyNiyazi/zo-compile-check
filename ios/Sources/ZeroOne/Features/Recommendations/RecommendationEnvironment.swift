import SwiftUI

private struct ProgressionRecommendationPermissionKey: EnvironmentKey {
    static let defaultValue = true
}

private struct WorkoutProgressionAuthorityKey: EnvironmentKey {
    static let defaultValue: WorkoutProgressionAuthority? = nil
}

private struct WellbeingAssessmentKey: EnvironmentKey {
    static let defaultValue: WellbeingAssessment? = nil
}

private struct WorkoutDemandAuthorityKey: EnvironmentKey {
    static let defaultValue: WorkoutDemandAuthority? = nil
}

private struct ExerciseSubstitutionAuthorityKey: EnvironmentKey {
    static let defaultValue: ExerciseSubstitutionAuthority? = nil
}

extension EnvironmentValues {
    var zeroOneExerciseSubstitutionAuthority: ExerciseSubstitutionAuthority? {
        get { self[ExerciseSubstitutionAuthorityKey.self] }
        set { self[ExerciseSubstitutionAuthorityKey.self] = newValue }
    }
    var zeroOneWorkoutDemandAuthority: WorkoutDemandAuthority? {
        get { self[WorkoutDemandAuthorityKey.self] }
        set { self[WorkoutDemandAuthorityKey.self] = newValue }
    }
    var zeroOneWellbeingAssessment: WellbeingAssessment? {
        get { self[WellbeingAssessmentKey.self] }
        set { self[WellbeingAssessmentKey.self] = newValue }
    }
    var zeroOneWorkoutProgression: WorkoutProgressionAuthority? {
        get { self[WorkoutProgressionAuthorityKey.self] }
        set { self[WorkoutProgressionAuthorityKey.self] = newValue }
    }
    var zeroOneProgressionAllowed: Bool {
        get { self[ProgressionRecommendationPermissionKey.self] }
        set { self[ProgressionRecommendationPermissionKey.self] = newValue }
    }
}
