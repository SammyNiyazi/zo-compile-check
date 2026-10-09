import Foundation

/// Broad exclusions reported by the person, not a diagnosis or rehabilitation plan.
enum StarterMovementGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case kneeDominant, hipDominant, pushing, pulling, core, kneeFlexion

    var titleKey: String {
        switch self {
        case .kneeDominant: "Squats and lunges"
        case .hipDominant: "Hinges and hip extensions"
        case .pushing: "Pushing movements"
        case .pulling: "Pulling movements"
        case .core: "Core movements"
        case .kneeFlexion: "Leg curls"
        }
    }
}

/// A general equipment category does not confirm these particular stations/supports.
enum StarterEquipmentRequirement: String, Codable, CaseIterable, Hashable, Sendable {
    case inclineBench, stableRowSupport, bandAnchor, cableRowHandle, singleCableHandle, dualCableStation
    case legPress, chestPress, seatedRow, legCurl, tBarRow
    case latPulldown, assistedPullUp, lyingLegCurl, legExtension

    var equipment: ZeroOneEquipmentItem {
        switch self {
        case .inclineBench, .stableRowSupport: .bench
        case .bandAnchor: .bands
        case .cableRowHandle, .singleCableHandle, .dualCableStation: .cables
        case .legPress, .chestPress, .seatedRow, .legCurl, .tBarRow, .latPulldown, .assistedPullUp, .lyingLegCurl, .legExtension: .machines
        }
    }

    var titleKey: String {
        switch self {
        case .inclineBench: "Adjustable incline bench"
        case .stableRowSupport: "Stable bench support for one-arm rows"
        case .bandAnchor: "Secure anchor for resistance bands"
        case .cableRowHandle: "Handle for a two-handed cable row"
        case .singleCableHandle: "Single cable handle"
        case .dualCableStation: "Two adjustable cable pulleys with handles"
        case .legPress: "Leg press machine"
        case .chestPress: "Chest press machine"
        case .seatedRow: "Seated row machine"
        case .legCurl: "Seated leg curl machine"
        case .tBarRow: "Plate-loaded T-bar row machine"
        case .latPulldown: "Lat pulldown station"
        case .assistedPullUp: "Assisted pull-up machine"
        case .lyingLegCurl: "Lying leg curl machine"
        case .legExtension: "Leg extension machine"
        }
    }
}

struct StarterSelectionPreferences: Codable, Equatable, Sendable {
    var blockedGroups: Set<StarterMovementGroup> = []
    var blockedExerciseIDs: Set<ExerciseID> = []
    var confirmedEquipment: Set<StarterEquipmentRequirement> = []
    var familiarVideoIDs: Set<String> = []
    var preferredVideoIDs: Set<String> = []

    var isValid: Bool {
        blockedExerciseIDs.count <= 100 && familiarVideoIDs.count <= 100 && preferredVideoIDs.count <= 100
            && blockedExerciseIDs.allSatisfy { !$0.rawValue.isEmpty && $0.rawValue.count <= 160 }
            && familiarVideoIDs.union(preferredVideoIDs).allSatisfy { !$0.isEmpty && $0.count <= 160 }
    }
}

struct StarterExerciseCandidate: Equatable, Sendable {
    let videoID: String
    let group: StarterMovementGroup
    let difficulty: ExerciseDifficulty
    let equipment: Set<ZeroOneEquipmentItem>
    let additionalEquipment: Set<StarterEquipmentRequirement>
    let goalTags: Set<TrainingGoalTag>
    /// This is an authored target convention for the starter, not a guess about
    /// how repetitions were counted in somebody's older workout.
    let perSide: Bool
}

enum StarterSelectionIssue: String, Codable, Equatable, Hashable, Sendable {
    case equipmentNotReported, equipmentConflict, equipmentNeedsConfirmation
    case missingPulling, excludedCoverage, closeTrainingDays

    var messageKey: String {
        switch self {
        case .equipmentNotReported: "Equipment is not set. This draft uses movements that need no equipment."
        case .equipmentConflict: "The saved equipment answers conflict. This draft uses movements that need no equipment."
        case .equipmentNeedsConfirmation: "Some exercises were excluded until their equipment or support is confirmed."
        case .missingPulling: "This draft has no supported pulling exercise. Core work does not replace pulling work."
        case .excludedCoverage: "Your movement exclusions leave gaps in this draft. It is not a complete balanced programme."
        case .closeTrainingDays: "Your chosen days are kept. Adjacent full-body sessions may need less volume or a recovery day after you review how you feel."
        }
    }
}

struct StarterExerciseSelection: Codable, Equatable, Sendable {
    let videoIDs: [String]
    let exerciseIDs: [ExerciseID]
    let groups: [StarterMovementGroup]
    let issues: [StarterSelectionIssue]
}

/// Product policy starter-selection-v1. It covers the explicitly authored starter
/// pool, not every licensed clip. Difficulty/requirements below are conservative
/// curation; they are not derived from an animation's broad equipment label.
enum StarterExerciseSelector {
    static let policyVersion = "starter-selection-v1"

    static func select(
        preferred: [String], candidates: [StarterExerciseCandidate] = catalogue,
        profile: ZeroOneUserProfile, availableVideoIDs: Set<String>, count: Int
    ) -> StarterExerciseSelection? {
        let preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
        guard profile.isCompatible, preferences.isValid, (3...6).contains(count),
              Set(preferred).count == preferred.count,
              Set(candidates.map(\.videoID)).count == candidates.count,
              profile.trainingConstraint != .movementSensitivity
                || !preferences.blockedGroups.isEmpty || !preferences.blockedExerciseIDs.isEmpty else { return nil }
        let reportedEquipment = profile.availableEquipment ?? []
        let equipment: Set<ZeroOneEquipmentItem> = reportedEquipment.contains(.none) ? [] : reportedEquipment
        let novice = profile.trainingExperience == nil || profile.trainingExperience == .notSure
            || profile.trainingExperience == .startingOut || profile.trainingExperience == .returning
        let eligible = candidates.filter { candidate in
            guard availableVideoIDs.contains(candidate.videoID),
                  let identity = MoveKitExerciseCatalog.workoutExerciseID(for: candidate.videoID),
                  !preferences.blockedExerciseIDs.contains(identity),
                  !preferences.blockedGroups.contains(candidate.group),
                  candidate.equipment.isSubset(of: equipment),
                  candidate.additionalEquipment.isSubset(of: preferences.confirmedEquipment),
                  !novice || candidate.difficulty == .beginner else { return false }
            // Exact seed metadata may add restrictions; variations never borrow it.
            if let seedID = MoveKitExerciseCatalog.exactSeedExerciseID(for: candidate.videoID) {
                guard let definition = ExerciseLibrary.exercise(id: seedID),
                      !novice || definition.difficulty == .beginner else { return false }
            }
            return true
        }
        let preferredOrder = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($0.element, $0.offset) })
        let goalTag: TrainingGoalTag? = switch profile.trainingGoal {
        case .buildStrength: .strength
        case .buildMuscle: .hypertrophy
        case .moveBetter: .stability
        default: nil
        }
        func ranked(_ pool: [StarterExerciseCandidate]) -> [StarterExerciseCandidate] {
            pool.sorted { lhs, rhs in
                // Lexicographic priorities, not fabricated confidence percentages.
                func priority(_ value: StarterExerciseCandidate) -> [Int] {
                    [preferences.preferredVideoIDs.contains(value.videoID) ? 0 : 1,
                     preferences.familiarVideoIDs.contains(value.videoID) ? 0 : 1,
                     preferredOrder[value.videoID] == nil ? 1 : 0,
                     goalTag.map { value.goalTags.contains($0) ? 0 : 1 } ?? 0,
                     preferredOrder[value.videoID] ?? Int.max]
                }
                let left = priority(lhs), right = priority(rhs)
                return left == right ? lhs.videoID < rhs.videoID : left.lexicographicallyPrecedes(right)
            }
        }
        var selected: [StarterExerciseCandidate] = []
        for group in [StarterMovementGroup.kneeDominant, .pushing, .pulling, .hipDominant, .core] {
            guard selected.count < count else { break }
            if let candidate = ranked(eligible.filter { $0.group == group }).first { selected.append(candidate) }
        }
        for candidate in ranked(eligible) where selected.count < count {
            if !selected.contains(where: { $0.videoID == candidate.videoID }),
               selected.filter({ $0.group == candidate.group }).count < 2 {
                selected.append(candidate)
            }
        }
        guard selected.count >= 3 else { return nil }
        var issues: [StarterSelectionIssue] = []
        if reportedEquipment.isEmpty { issues.append(.equipmentNotReported) }
        if reportedEquipment.contains(.none), reportedEquipment.count > 1 { issues.append(.equipmentConflict) }
        if candidates.contains(where: {
            $0.equipment.isSubset(of: equipment) && !$0.additionalEquipment.isSubset(of: preferences.confirmedEquipment)
                && availableVideoIDs.contains($0.videoID)
        }) { issues.append(.equipmentNeedsConfirmation) }
        if !selected.contains(where: { $0.group == .pulling }) { issues.append(.missingPulling) }
        let foundationalGroups: Set<StarterMovementGroup> = [.kneeDominant, .pushing, .pulling, .hipDominant]
        if (!preferences.blockedGroups.isEmpty || !preferences.blockedExerciseIDs.isEmpty),
           !foundationalGroups.isSubset(of: Set(selected.map(\.group))) { issues.append(.excludedCoverage) }
        return StarterExerciseSelection(videoIDs: selected.map(\.videoID),
            exerciseIDs: selected.compactMap { MoveKitExerciseCatalog.workoutExerciseID(for: $0.videoID) },
            groups: selected.map(\.group), issues: issues)
    }

    static let catalogue: [StarterExerciseCandidate] = {
        func item(_ id: String, _ group: StarterMovementGroup,
                  _ equipment: Set<ZeroOneEquipmentItem> = [], _ difficulty: ExerciseDifficulty = .beginner,
                  _ additional: Set<StarterEquipmentRequirement> = []) -> StarterExerciseCandidate {
            .init(videoID: id, group: group, difficulty: difficulty, equipment: equipment,
                  additionalEquipment: additional, goalTags: group == .core ? [.stability] : [.strength, .hypertrophy],
                  perSide: ["bodyweight-reverse-lunge", "bird-dog", "dead-bug", "dumbbell-single-arm-row",
                    "dumbbell-row-unilateral", "kickstand-dumbbell-romanian-deadlift", "kettlebell-single-arm-row",
                    "cable-standing-single-arm-chest-press", "cable-single-arm-neutral-grip-row"].contains(id))
        }
        return [
            item("bodyweight-squat", .kneeDominant), item("bodyweight-reverse-lunge", .kneeDominant),
            item("push-up", .pushing), item("bodyweight-knee-push-ups", .pushing),
            item("diamond-push-ups", .pushing, [], .intermediate),
            item("glute-bridge", .hipDominant), item("frog-pump", .hipDominant),
            item("bird-dog", .core), item("dead-bug", .core),
            item("barbell-squat", .kneeDominant, [.barbell], .intermediate),
            item("barbell-floor-press", .pushing, [.barbell], .intermediate),
            item("barbell-overhead-press", .pushing, [.barbell], .intermediate),
            item("barbell-bent-over-row", .pulling, [.barbell], .intermediate),
            item("barbell-bent-over-row-overhand", .pulling, [.barbell], .intermediate),
            item("barbell-romanian-deadlift", .hipDominant, [.barbell], .intermediate),
            item("dumbbell-goblet-squat", .kneeDominant, [.dumbbells]),
            item("dumbbell-front-squat", .kneeDominant, [.dumbbells], .intermediate),
            item("floor-press", .pushing, [.dumbbells]),
            item("dumbbell-single-arm-row", .pulling, [.dumbbells, .bench], .beginner, [.stableRowSupport]),
            item("dumbbell-row-unilateral", .pulling, [.dumbbells, .bench], .beginner, [.stableRowSupport]),
            item("dumbbell-deadlift", .hipDominant, [.dumbbells], .intermediate),
            item("kickstand-dumbbell-romanian-deadlift", .hipDominant, [.dumbbells], .intermediate),
            item("chest-supported-dumbbell-row", .pulling, [.dumbbells, .bench], .beginner, [.inclineBench]),
            item("dumbbell-bench-press", .pushing, [.dumbbells, .bench]),
            item("kettlebell-goblet-squat", .kneeDominant, [.kettlebells]),
            item("kettlebell-row", .pulling, [.kettlebells], .intermediate),
            item("kettlebell-single-arm-row", .pulling, [.kettlebells], .intermediate),
            item("kettlebell-romanian-deadlift", .hipDominant, [.kettlebells], .intermediate),
            item("kettlebell-sumo-deadlift", .hipDominant, [.kettlebells], .intermediate),
            item("machine-leg-press", .kneeDominant, [.machines], .beginner, [.legPress]),
            item("machine-chest-press", .pushing, [.machines], .beginner, [.chestPress]),
            item("machine-neutral-row", .pulling, [.machines], .beginner, [.seatedRow]),
            item("machine-plate-loaded-t-bar-row", .pulling, [.machines], .intermediate, [.tBarRow]),
            item("seated-leg-curl", .kneeFlexion, [.machines], .beginner, [.legCurl]),
            item("cable-chest-press", .pushing, [.cables], .beginner, [.dualCableStation]),
            item("cable-standing-single-arm-chest-press", .pushing, [.cables], .beginner, [.singleCableHandle]),
            item("cable-row-bar-standing-row", .pulling, [.cables], .beginner, [.cableRowHandle]),
            item("cable-single-arm-neutral-grip-row", .pulling, [.cables], .beginner, [.singleCableHandle]),
            item("band-squat", .kneeDominant, [.bands]),
            item("band-overhead-press", .pushing, [.bands], .intermediate),
            item("band-row", .pulling, [.bands], .beginner, [.bandAnchor]),
            item("band-romanian-deadlift", .hipDominant, [.bands], .intermediate),
            item("band-leg-curl", .kneeFlexion, [.bands, .bench], .beginner, [.bandAnchor])
        ]
    }()
}
