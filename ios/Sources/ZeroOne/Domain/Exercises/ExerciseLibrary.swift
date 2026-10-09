import Foundation

enum ExerciseIDs {
    static let barbellBackSquat: ExerciseID = "EX-BARBELL-BACK-SQUAT"
    static let gobletSquat: ExerciseID = "EX-GOBLET-SQUAT"
    static let legPress: ExerciseID = "EX-LEG-PRESS"
    static let romanianDeadlift: ExerciseID = "EX-ROMANIAN-DEADLIFT"
    static let lyingLegCurl: ExerciseID = "EX-LYING-LEG-CURL"
    static let legExtension: ExerciseID = "EX-LEG-EXTENSION"
    static let standingCalfRaise: ExerciseID = "EX-STANDING-CALF-RAISE"
    static let barbellBenchPress: ExerciseID = "EX-BARBELL-BENCH-PRESS"
    static let dumbbellBenchPress: ExerciseID = "EX-DUMBBELL-BENCH-PRESS"
    static let inclineDumbbellPress: ExerciseID = "EX-INCLINE-DUMBBELL-PRESS"
    static let latPulldown: ExerciseID = "EX-LAT-PULLDOWN"
    static let seatedCableRow: ExerciseID = "EX-SEATED-CABLE-ROW"
    static let chestSupportedRow: ExerciseID = "EX-CHEST-SUPPORTED-ROW"
    static let facePull: ExerciseID = "EX-FACE-PULL"
    static let overheadPress: ExerciseID = "EX-OVERHEAD-PRESS"
    static let cableLateralRaise: ExerciseID = "EX-CABLE-LATERAL-RAISE"
    static let dumbbellCurl: ExerciseID = "EX-DUMBBELL-CURL"
    static let dumbbellHammerCurl: ExerciseID = "EX-DUMBBELL-HAMMER-CURL"
    static let dumbbellInclineCurl: ExerciseID = "EX-DUMBBELL-INCLINE-CURL"
    static let dumbbellOverheadTricepsExtension: ExerciseID = "EX-DUMBBELL-OVERHEAD-TRICEPS-EXTENSION"
    static let cableTricepsPressdown: ExerciseID = "EX-CABLE-TRICEPS-PRESSDOWN"
    static let plank: ExerciseID = "EX-PLANK"
    static let deadBug: ExerciseID = "EX-DEAD-BUG"
    static let splitSquat: ExerciseID = "EX-SPLIT-SQUAT"
    static let hipThrust: ExerciseID = "EX-HIP-THRUST"
    static let assistedPullUp: ExerciseID = "EX-ASSISTED-PULL-UP"
    static let pushUp: ExerciseID = "EX-PUSH-UP"
    static let inclineWalk: ExerciseID = "EX-INCLINE-WALK"

    // Compatibility aliases for existing offline workout fixtures.
    static let backSquat = barbellBackSquat
    static let seatedLegCurl = lyingLegCurl
    static let seatedDumbbellShoulderPress = overheadPress
    static let tricepsPushdown = cableTricepsPressdown
    static let cableCrunch = deadBug
}

enum ExerciseLibrary {
    private static let seed = TrainingSeedRepository.shared

    static let all: [ExerciseDefinition] = seed.exercises.map(makeDefinition)

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let byNormalizedName = Dictionary(
        uniqueKeysWithValues: all.map { (ExerciseID(exerciseName: $0.name), $0) }
    )

    private static let aliases: [ExerciseID: ExerciseID] = [
        ExerciseID(exerciseName: "Back Squat"): ExerciseIDs.barbellBackSquat,
        ExerciseID(exerciseName: "Chest-Supported Row"): ExerciseIDs.chestSupportedRow,
        ExerciseID(exerciseName: "Triceps Pushdown"): ExerciseIDs.cableTricepsPressdown,
        ExerciseID(exerciseName: "Pull-Up"): ExerciseIDs.assistedPullUp
    ]

    static func exercise(id: ExerciseID) -> ExerciseDefinition? {
        byID[id]
    }

    static func exercise(named name: String) -> ExerciseDefinition? {
        let normalizedName = ExerciseID(exerciseName: name)
        if let exact = byNormalizedName[normalizedName] {
            return exact
        }
        return aliases[normalizedName].flatMap { byID[$0] }
    }

    static func exercise(id: ExerciseID, fallbackName: String) -> ExerciseDefinition? {
        exercise(id: id) ?? exercise(named: fallbackName)
    }

    static func exercises(tagged template: WorkoutTemplateTag) -> [ExerciseDefinition] {
        all.filter { $0.workoutTags.contains(template) }
    }

    private static func makeDefinition(_ record: TrainingExerciseRecord) -> ExerciseDefinition {
        let programmeContext = programmeContext(for: record.id)
        let prescription = programmeContext.first?.item
        let rirRange = parsedRange(programmeContext.first?.rules.targetRIR ?? "2-3", fallback: 2 ... 3)
        let repRange = parsedRange(prescription?.target ?? "8-12", fallback: 8 ... 12)
        let exerciseID = ExerciseID(rawValue: record.id)
        let visualAssets = ExerciseVisualCatalog.entry(for: exerciseID)?.assets ?? .pending

        return ExerciseDefinition(
            id: exerciseID,
            name: record.name,
            category: category(for: record),
            primaryMuscleGroup: muscleGroup(for: record.primaryMuscles.first),
            secondaryMuscleGroups: Set(record.secondaryMuscles.map { muscleGroup(for: $0) }),
            equipment: Set(record.equipment.map(equipmentFamily)),
            movementPattern: movementPattern(record.pattern),
            trainingGoalTags: trainingGoalTags(programmeContext.flatMap { $0.goals }),
            difficulty: ExerciseDifficulty(rawValue: record.level) ?? .beginner,
            defaultRepRange: RepRange(repRange.lowerBound, repRange.upperBound),
            defaultRIRRange: RIRRange(
                min(5, rirRange.lowerBound),
                min(5, rirRange.upperBound)
            ),
            shortCoachingCue: record.cue,
            heroImageName: visualAssets.hero,
            cardImageName: visualAssets.card,
            thumbnailImageName: visualAssets.thumbnail,
            workoutTags: workoutTags(programmeContext.map(\.sessionName)),
            equipmentIdentifiers: record.equipment,
            primaryMuscleNames: record.primaryMuscles,
            secondaryMuscleNames: record.secondaryMuscles,
            alternativeNames: record.substitutions,
            painGuardrail: record.painGuardrail,
            visualReferenceKey: record.visualSeed.datasetLookup,
            visualReferenceStatus: record.visualSeed.status,
            evidenceReferenceKeys: programmeContext.flatMap(\.evidenceIDs).uniqued()
        )
    }

    private static func programmeContext(for exerciseID: String) -> [(
        item: TrainingProgrammeItemRecord,
        rules: TrainingProgrammeRules,
        goals: [String],
        sessionName: String,
        evidenceIDs: [String]
    )] {
        seed.programmeTemplates.flatMap { programme in
            programme.sessions.flatMap { session in
                session.items
                    .filter { $0.exerciseID == exerciseID }
                    .map {
                        ($0, programme.baseRules, programme.goalSupport, session.name, programme.evidenceIDs)
                    }
            }
        }
    }

    private static func parsedRange(_ value: String, fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        let numbers = value
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        guard let lower = numbers.first else { return fallback }
        return lower ... max(lower, numbers.dropFirst().first ?? lower)
    }

    private static func category(for record: TrainingExerciseRecord) -> ExerciseCategory {
        switch record.pattern {
        case "horizontal_push", "incline_push": .chest
        case "vertical_pull", "horizontal_pull", "upper_back_pull": .back
        case "vertical_push", "shoulder_abduction": .shoulders
        case "elbow_flexion", "elbow_extension": .arms
        case "anti_extension_core": .core
        default: .legs
        }
    }

    private static func muscleGroup(for value: String?) -> MuscleGroup {
        switch value {
        case "pectoralis major": .chest
        case "latissimus dorsi": .lats
        case "mid back", "upper back", "upper trapezius", "rotator cuff": .upperBack
        case "posterior deltoid": .rearDelts
        case "anterior deltoid", "shoulders": .frontDelts
        case "lateral deltoid": .sideDelts
        case "biceps", "brachialis": .biceps
        case "triceps": .triceps
        case "forearms": .forearms
        case "quadriceps": .quadriceps
        case "hamstrings": .hamstrings
        case "gluteus maximus": .glutes
        case "adductors": .adductors
        case "gastrocnemius", "soleus", "calves": .calves
        default: .abdominals
        }
    }

    private static func equipmentFamily(_ value: String) -> ExerciseEquipment {
        if value.contains("barbell") || value == "rack" { return .barbell }
        if value.contains("dumbbell") || value.contains("kettlebell") { return .dumbbells }
        if value.contains("cable") || value == "rope" { return .cable }
        if value.contains("bodyweight") { return .bodyweight }
        return .machine
    }

    private static func movementPattern(_ value: String) -> MovementPattern {
        switch value {
        case "horizontal_push": .horizontalPush
        case "incline_push": .inclinePush
        case "vertical_push": .verticalPush
        case "horizontal_pull": .horizontalPull
        case "vertical_pull": .verticalPull
        case "shoulder_abduction": .shoulderAbduction
        case "elbow_flexion": .elbowFlexion
        case "elbow_extension": .elbowExtension
        case "squat": .squat
        case "knee_dominant": .kneeDominant
        case "hinge": .hinge
        case "knee_flexion": .kneeFlexion
        case "knee_extension": .kneeExtension
        case "ankle_extension": .ankleExtension
        case "upper_back_pull": .upperBackPull
        case "anti_extension_core": .antiExtensionCore
        case "unilateral_squat": .unilateralSquat
        case "hip_extension": .hipExtension
        case "low_impact_conditioning": .lowImpactConditioning
        default: .stabilityFallback
        }
    }

    private static func trainingGoalTags(_ values: [String]) -> Set<TrainingGoalTag> {
        var tags = Set<TrainingGoalTag>()
        if values.contains("muscle_gain") { tags.insert(.hypertrophy) }
        if values.contains("strength_support") { tags.insert(.strength) }
        if values.contains("general_fitness") || values.contains("consistency") { tags.insert(.stability) }
        return tags.isEmpty ? [.stability] : tags
    }

    private static func workoutTags(_ sessionNames: [String]) -> Set<WorkoutTemplateTag> {
        var tags = Set<WorkoutTemplateTag>()
        for name in sessionNames {
            let normalized = name.lowercased()
            if normalized.contains("upper") { tags.insert(.upperA) }
            if normalized.contains("lower") { tags.insert(.lowerA) }
            if normalized.contains("full body") || normalized.contains("strength") {
                tags.insert(.fullBodyA)
                tags.insert(.beginnerFullBody)
            }
        }
        return tags
    }
}

private extension MovementPattern {
    static let stabilityFallback: MovementPattern = .antiExtensionCore
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
