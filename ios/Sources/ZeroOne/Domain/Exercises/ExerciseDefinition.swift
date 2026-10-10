import Foundation

struct ExerciseID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    init(exerciseName: String) {
        rawValue = exerciseName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

enum ExerciseCategory: String, CaseIterable, Codable, Sendable {
    case chest
    case back
    case shoulders
    case arms
    case legs
    case core
}

enum MuscleGroup: String, CaseIterable, Codable, Sendable {
    case chest
    case upperChest
    case lats
    case upperBack
    case rearDelts
    case frontDelts
    case sideDelts
    case biceps
    case triceps
    case forearms
    case quadriceps
    case hamstrings
    case glutes
    case adductors
    case calves
    case abdominals
}

enum ExerciseEquipment: String, CaseIterable, Codable, Sendable {
    case barbell
    case dumbbells
    case cable
    case machine
    case bodyweight
}

enum MovementPattern: String, CaseIterable, Codable, Sendable {
    case horizontalPush
    case inclinePush
    case verticalPush
    case horizontalPull
    case verticalPull
    case shoulderAbduction
    case elbowFlexion
    case elbowExtension
    case squat
    case lunge
    case hinge
    case kneeFlexion
    case kneeExtension
    case hipExtension
    case plantarFlexion
    case trunkFlexion
    case kneeDominant
    case ankleExtension
    case upperBackPull
    case antiExtensionCore
    case unilateralSquat
    case lowImpactConditioning
}

enum TrainingGoalTag: String, CaseIterable, Codable, Sendable {
    case hypertrophy
    case strength
    case skill
    case stability
}

enum ExerciseDifficulty: String, CaseIterable, Codable, Sendable {
    case beginner
    case intermediate
    case advanced
}

enum WorkoutTemplateTag: String, CaseIterable, Codable, Sendable {
    case upperA
    case upperB
    case lowerA
    case lowerB
    case fullBodyA
    case fullBodyB
    case push
    case pull
    case legs
    case beginnerFullBody
    case dumbbellOnly
    case machinesOnly
    case shortSession
}

struct RIRRange: Equatable, Codable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init(_ lowerBound: Int, _ upperBound: Int) {
        precondition((0 ... 5).contains(lowerBound), "RIR must be between zero and five.")
        precondition(upperBound >= lowerBound && upperBound <= 5, "Invalid RIR range.")
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

struct ExerciseDefinition: Identifiable, Equatable, Sendable {
    let id: ExerciseID
    let name: String
    let category: ExerciseCategory
    let primaryMuscleGroup: MuscleGroup
    let secondaryMuscleGroups: Set<MuscleGroup>
    let equipment: Set<ExerciseEquipment>
    let movementPattern: MovementPattern
    let trainingGoalTags: Set<TrainingGoalTag>
    let difficulty: ExerciseDifficulty
    let defaultRepRange: RepRange
    let defaultRIRRange: RIRRange
    let shortCoachingCue: String
    let heroImageName: String?
    let cardImageName: String?
    let thumbnailImageName: String?
    let workoutTags: Set<WorkoutTemplateTag>
    let equipmentIdentifiers: [String]
    let primaryMuscleNames: [String]
    let secondaryMuscleNames: [String]
    let alternativeNames: [String]
    let painGuardrail: String
    let visualReferenceKey: String
    let visualReferenceStatus: String
    let evidenceReferenceKeys: [String]

    var resolvedAlternativeIDs: [ExerciseID] {
        alternativeNames.compactMap { ExerciseLibrary.exercise(named: $0)?.id }
    }

    var unresolvedAlternativeNames: [String] {
        alternativeNames.filter { ExerciseLibrary.exercise(named: $0) == nil }
    }

    func imageName(for level: ExerciseVisualLevel) -> String? {
        switch level {
        case .hero:
            heroImageName ?? cardImageName ?? thumbnailImageName
        case .card:
            cardImageName ?? heroImageName ?? thumbnailImageName
        case .thumbnail:
            thumbnailImageName ?? cardImageName ?? heroImageName
        }
    }
}

enum ExerciseVisualLevel: String, CaseIterable, Codable, Sendable {
    case hero
    case card
    case thumbnail
}
