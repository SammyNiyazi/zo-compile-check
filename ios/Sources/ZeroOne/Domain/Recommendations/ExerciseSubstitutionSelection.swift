import Foundation

enum ExerciseSubstitutionSelectionError: Error, Equatable {
    case unavailable, activeState, context, symptoms, noAlternative, stale, confirmation
    var messageKey: String {
        switch self {
        case .unavailable: "Current exercise, profile or recovery records could not be verified. Reopen the swap review."
        case .activeState: "Only the current unstarted exercise can be changed after warm-up."
        case .context: "Confirm your equipment, experience and movement exclusions in Profile before choosing an alternative."
        case .symptoms: "Review the reported pain or illness before choosing a replacement exercise."
        case .noAlternative: "No authored alternative meets your confirmed equipment, exclusions, experience and available demonstration. Keep or skip this exercise."
        case .stale: "The exercise, inputs, profile, recovery context or available demonstration changed. Review the alternatives again."
        case .confirmation: "Confirm that these equipment and movement answers still apply today."
        }
    }
}

struct ExerciseSubstitutionContext: Equatable {
    let profile: ZeroOneUserProfile
    let assessment: WellbeingAssessment
}

/// Numeric drafts are local execution state, not evidence of performed work.
struct WorkoutSubstitutionInput: Codable, Equatable, Sendable {
    let loadDraft: String
    let repsDraft: String
    let durationDraft: String
    let load: Double
    let reps: Int
    let rir: Int?

    var isValid: Bool {
        load.isFinite && load >= 0 && (1 ... 50).contains(reps)
            && (rir.map { (0 ... 5).contains($0) } ?? true)
            && [loadDraft, repsDraft, durationDraft].allSatisfy { $0.count <= 80 }
    }
}

struct ExerciseSubstitutionCandidate: Equatable {
    let definition: ExerciseDefinition
    let videoID: String
    let target: WorkingSetPrescription
}

struct ExerciseSubstitutionReview: Equatable {
    let policyVersion: String
    let offeredAt: Date
    let timeZoneID: String
    let session: WorkoutSession
    let input: WorkoutSubstitutionInput
    let context: ExerciseSubstitutionContext
    let candidates: [ExerciseSubstitutionCandidate]
}

/// Explicit seed teaching conventions. Metadata equipment families cannot
/// establish the required stations, supports, side count or target mode.
enum ExerciseSubstitutionCuration {
    struct Requirements {
        let equipment: Set<ZeroOneEquipmentItem>
        let auxiliary: Set<StarterEquipmentRequirement>
        let group: StarterMovementGroup
    }

    static func requirements(for id: ExerciseID) -> Requirements? {
        switch id {
        case ExerciseIDs.barbellBackSquat: .init(equipment: [.barbell], auxiliary: [], group: .kneeDominant)
        case ExerciseIDs.barbellBenchPress: .init(equipment: [.barbell, .bench], auxiliary: [], group: .pushing)
        case ExerciseIDs.dumbbellBenchPress: .init(equipment: [.dumbbells, .bench], auxiliary: [], group: .pushing)
        case ExerciseIDs.inclineDumbbellPress: .init(equipment: [.dumbbells, .bench], auxiliary: [.inclineBench], group: .pushing)
        case ExerciseIDs.chestSupportedRow: .init(equipment: [.dumbbells, .bench], auxiliary: [.inclineBench], group: .pulling)
        case ExerciseIDs.dumbbellCurl, ExerciseIDs.dumbbellHammerCurl: .init(equipment: [.dumbbells], auxiliary: [], group: .pulling)
        case ExerciseIDs.dumbbellInclineCurl: .init(equipment: [.dumbbells, .bench], auxiliary: [.inclineBench], group: .pulling)
        case ExerciseIDs.dumbbellOverheadTricepsExtension: .init(equipment: [.dumbbells, .bench], auxiliary: [], group: .pushing)
        case ExerciseIDs.latPulldown: .init(equipment: [.machines], auxiliary: [.latPulldown], group: .pulling)
        case ExerciseIDs.assistedPullUp: .init(equipment: [.machines], auxiliary: [.assistedPullUp], group: .pulling)
        case ExerciseIDs.lyingLegCurl: .init(equipment: [.machines], auxiliary: [.lyingLegCurl], group: .kneeFlexion)
        case ExerciseIDs.legExtension: .init(equipment: [.machines], auxiliary: [.legExtension], group: .kneeDominant)
        case ExerciseIDs.hipThrust: .init(equipment: [.barbell, .bench], auxiliary: [], group: .hipDominant)
        case ExerciseIDs.pushUp: .init(equipment: [], auxiliary: [], group: .pushing)
        default: nil
        }
    }

    static func target(for definition: ExerciseDefinition) -> WorkingSetPrescription? {
        guard requirements(for: definition.id) != nil else { return nil }
        return .init(unit: .repetitions, lowerBound: definition.defaultRepRange.lowerBound,
            upperBound: definition.defaultRepRange.upperBound, perSide: false)
    }

    static func authoredAlternativeIDs(for plan: ExercisePlan) -> [ExerciseID] {
        guard let source = ExerciseLibrary.exercise(id: plan.exerciseID) else { return [] }
        // An exact seed identity in a custom/starter plan can use its authored
        // alternatives. MOV-only variations never borrow another seed's list.
        let ids = source.resolvedAlternativeIDs
        return plan.alternativeExerciseIDs.isEmpty ? ids : ids.filter { plan.alternativeExerciseIDs.contains($0) }
    }
}

struct ExerciseSubstitutionSelector {
    static let policyVersion = "exercise-substitution-v2"

    func review(session: WorkoutSession, input: WorkoutSubstitutionInput,
                context: ExerciseSubstitutionContext, availableVideoIDs: Set<String>,
                at now: Date, calendar: Calendar = .current) throws -> ExerciseSubstitutionReview {
        guard !session.isComplete, !session.requiresWarmUp,
              let current = session.currentExercise, current.completedSets.isEmpty else {
            throw ExerciseSubstitutionSelectionError.activeState
        }
        guard input.isValid, now.timeIntervalSinceReferenceDate.isFinite,
              context.profile.isCompatible, context.assessment.isCurrent(at: now, calendar: calendar),
              context.assessment.unavailableSources.isEmpty,
              context.assessment.energyTargetReview?.hasBoundSource ?? true,
              context.assessment.recommendations.allSatisfy({ $0.policyVersion == WellbeingRecommendationEngine.policyVersion }) else {
            throw ExerciseSubstitutionSelectionError.unavailable
        }
        guard !context.assessment.recommendations.contains(where: { $0.kind == .symptoms || $0.demand == .pauseForSymptoms }) else {
            throw ExerciseSubstitutionSelectionError.symptoms
        }
        let profile = context.profile
        let preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
        guard let equipment = profile.availableEquipment, !equipment.isEmpty,
              !equipment.contains(.none) || equipment.count == 1,
              let constraint = profile.trainingConstraint, constraint != .notSure,
              constraint != .movementSensitivity || !preferences.blockedGroups.isEmpty || !preferences.blockedExerciseIDs.isEmpty else {
            throw ExerciseSubstitutionSelectionError.context
        }
        let available = equipment.subtracting([.none])
        let novice = profile.trainingExperience == nil || profile.trainingExperience == .notSure
            || profile.trainingExperience == .startingOut || profile.trainingExperience == .returning
        var candidates: [ExerciseSubstitutionCandidate] = []
        for id in ExerciseSubstitutionCuration.authoredAlternativeIDs(for: current.plan) {
            guard id != current.plan.exerciseID, let definition = ExerciseLibrary.exercise(id: id),
                  let requirements = ExerciseSubstitutionCuration.requirements(for: id),
                  let target = ExerciseSubstitutionCuration.target(for: definition),
                  requirements.equipment.isSubset(of: available),
                  requirements.auxiliary.isSubset(of: preferences.confirmedEquipment),
                  !preferences.blockedGroups.contains(requirements.group), !preferences.blockedExerciseIDs.contains(id),
                  !novice || definition.difficulty == .beginner,
                  let match = MoveKitExerciseCatalog.match(for: id), match.relationship == .exact,
                  availableVideoIDs.contains(match.exercise.id) else { continue }
            guard !candidates.contains(where: { $0.definition.id == id }) else { continue }
            candidates.append(.init(definition: definition, videoID: match.exercise.id, target: target))
        }
        candidates.sort { lhs, rhs in
            let left = [preferences.preferredVideoIDs.contains(lhs.videoID) ? 0 : 1, preferences.familiarVideoIDs.contains(lhs.videoID) ? 0 : 1]
            let right = [preferences.preferredVideoIDs.contains(rhs.videoID) ? 0 : 1, preferences.familiarVideoIDs.contains(rhs.videoID) ? 0 : 1]
            return left == right ? lhs.definition.id.rawValue < rhs.definition.id.rawValue : left.lexicographicallyPrecedes(right)
        }
        guard !candidates.isEmpty else { throw ExerciseSubstitutionSelectionError.noAlternative }
        return .init(policyVersion: Self.policyVersion, offeredAt: now, timeZoneID: calendar.timeZone.identifier,
            session: session, input: input, context: context, candidates: candidates)
    }

    func revalidated(_ presented: ExerciseSubstitutionReview, selected id: ExerciseID,
                     session: WorkoutSession, input: WorkoutSubstitutionInput, context: ExerciseSubstitutionContext,
                     availableVideoIDs: Set<String>, confirmedAt: Date?, at now: Date,
                     calendar: Calendar = .current) throws -> ExerciseSubstitutionCandidate {
        guard let confirmedAt, confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              confirmedAt >= presented.offeredAt, confirmedAt <= now,
              now.timeIntervalSince(confirmedAt) <= 600 else { throw ExerciseSubstitutionSelectionError.confirmation }
        guard presented.policyVersion == Self.policyVersion, presented.offeredAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, presented.offeredAt <= now,
              now.timeIntervalSince(presented.offeredAt) <= 600, presented.timeZoneID == calendar.timeZone.identifier,
              calendar.isDate(presented.offeredAt, inSameDayAs: now), presented.session == session,
              presented.input == input, presented.context.profile == context.profile else {
            throw ExerciseSubstitutionSelectionError.stale
        }
        let fresh = try review(session: session, input: input, context: context, availableVideoIDs: availableVideoIDs, at: now, calendar: calendar)
        guard fresh.context.assessment.recommendations == presented.context.assessment.recommendations,
              fresh.context.assessment.energyTargetReview?.sourceFingerprint
                == presented.context.assessment.energyTargetReview?.sourceFingerprint,
              fresh.candidates == presented.candidates,
              let candidate = fresh.candidates.first(where: { $0.definition.id == id }) else {
            throw ExerciseSubstitutionSelectionError.stale
        }
        return candidate
    }
}
