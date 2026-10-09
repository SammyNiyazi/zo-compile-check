import Foundation
import Observation

struct CustomWorkoutItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let videoID: String
    /// When present, the authored identity is authoritative. Media never substitutes it.
    let authoredExerciseID: ExerciseID?
    var sets: Int
    var reps: Int
    var restSeconds: Int
    var targetLoad: Double
    var loadUnit: LoadUnit
    var durationSeconds: Int?
    var perSide: Bool?
    // Optional bounds preserve authored ranges without changing older scalar items.
    var repUpperBound: Int?
    var durationUpperBound: Int?

    var prescription: WorkingSetPrescription {
        WorkingSetPrescription(unit: durationSeconds == nil ? .repetitions : .seconds,
            lowerBound: durationSeconds ?? reps,
            upperBound: durationSeconds == nil ? (repUpperBound ?? reps) : (durationUpperBound ?? durationSeconds ?? reps),
            perSide: perSide == true)
    }

    var prescriptionText: String {
        prescription.displayText
    }

    var resolvedExerciseID: ExerciseID? {
        if let authoredExerciseID {
            return ExerciseLibrary.exercise(id: authoredExerciseID)?.id
        }
        return MoveKitExerciseCatalog.workoutExerciseID(for: videoID)
    }

    var authoredDefinition: ExerciseDefinition? {
        authoredExerciseID.flatMap { ExerciseLibrary.exercise(id: $0) }
    }

    var mediaExercise: MoveKitExercise? {
        if let authoredExerciseID {
            guard authoredDefinition != nil,
                  let match = MoveKitExerciseCatalog.match(for: authoredExerciseID),
                  match.relationship == .exact else { return nil }
            return match.exercise
        }
        return MoveKitExerciseCatalog.exercise(for: videoID)
    }

    var displayName: String {
        if authoredExerciseID != nil { return authoredDefinition?.name ?? "Unavailable exercise" }
        return mediaExercise?.name ?? "Unavailable exercise"
    }

    var equipmentIdentifiers: [String] {
        if authoredExerciseID != nil { return authoredDefinition?.equipmentIdentifiers ?? [] }
        return mediaExercise.map { [$0.equipment] } ?? []
    }

    func replacing(with exercise: MoveKitExercise) -> CustomWorkoutItem {
        let preserveTargets = isStructurallyValid && prescription.isValid
        let sameEquipment = authoredExerciseID == nil && mediaExercise?.equipment == exercise.equipment
        let sameIdentity = resolvedExerciseID != nil
            && resolvedExerciseID == MoveKitExerciseCatalog.workoutExerciseID(for: exercise.id)
        return CustomWorkoutItem(id: id, videoID: exercise.id,
            sets: preserveTargets ? sets : 3, reps: preserveTargets ? reps : 10,
            restSeconds: preserveTargets ? restSeconds : 90,
            targetLoad: (sameEquipment || sameIdentity) && CustomWorkoutBuilderValidation.loadError(for: self) == nil ? targetLoad : 0,
            loadUnit: loadUnit,
            durationSeconds: preserveTargets ? durationSeconds : nil,
            perSide: preserveTargets ? perSide : nil,
            repUpperBound: preserveTargets ? repUpperBound : nil,
            durationUpperBound: preserveTargets ? durationUpperBound : nil)
    }

    init(
        id: UUID = UUID(), videoID: String, sets: Int = 3, reps: Int = 10,
        restSeconds: Int = 90, targetLoad: Double = 0, loadUnit: LoadUnit = .kilograms,
        durationSeconds: Int? = nil, perSide: Bool? = nil,
        repUpperBound: Int? = nil, durationUpperBound: Int? = nil,
        authoredExerciseID: ExerciseID? = nil
    ) {
        self.id = id
        self.videoID = videoID
        self.authoredExerciseID = authoredExerciseID
        self.sets = sets
        self.reps = reps
        self.restSeconds = restSeconds
        self.targetLoad = targetLoad
        self.loadUnit = loadUnit
        self.durationSeconds = durationSeconds
        self.perSide = perSide
        self.repUpperBound = repUpperBound
        self.durationUpperBound = durationUpperBound
    }

    var isStructurallyValid: Bool {
        (1 ... 12).contains(sets) && (1 ... 50).contains(reps)
            && (0 ... 600).contains(restSeconds)
            && targetLoad.isFinite && (0 ... 2_000).contains(targetLoad)
            && (durationSeconds.map { (1 ... 86_400).contains($0) } ?? true)
            && (repUpperBound.map { (reps ... 50).contains($0) } ?? true)
            && (durationUpperBound.map { durationSeconds != nil && $0 >= (durationSeconds ?? 0) && $0 <= 86_400 } ?? true)
            && (authoredExerciseID.map { !$0.rawValue.isEmpty } ?? !videoID.isEmpty)
    }

    var isValid: Bool {
        isStructurallyValid && resolvedExerciseID != nil
    }
}

struct CustomWorkout: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var items: [CustomWorkoutItem]
    var updatedAt: Date
    /// Optional so workouts saved before builder warm-up choices still decode.
    var warmUpLength: WorkoutWarmUpLength?

    init(
        id: UUID = UUID(), name: String = "My session", items: [CustomWorkoutItem] = [],
        updatedAt: Date = .now, warmUpLength: WorkoutWarmUpLength? = nil
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.updatedAt = updatedAt
        self.warmUpLength = warmUpLength
    }

    var isStructurallyValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 60
            && (1 ... 50).contains(items.count)
            && Set(items.map(\.id)).count == items.count
            && items.allSatisfy(\.isStructurallyValid)
    }

    var isValid: Bool {
        isStructurallyValid && items.allSatisfy(\.isValid)
    }

    func makeSession(previousHistory: [WorkoutHistoryEntry] = [], asOf: Date = .now,
                     warmUpLengthOverride: WorkoutWarmUpLength? = nil,
                     loadChoices: [WorkoutLoadChoice] = [],
                     progressionReviews: [WorkoutProgressionReview] = [],
                     progressionAllowed: Bool = true) -> WorkoutSession? {
        guard isValid else { return nil }
        let plans = items.compactMap { item -> ExercisePlan? in
            guard let exerciseID = item.resolvedExerciseID else { return nil }
            let definition = item.authoredDefinition ?? ExerciseLibrary.exercise(id: exerciseID)
            return ExercisePlan(
                id: item.id,
                exerciseID: exerciseID,
                name: item.displayName,
                targetLoad: Load(item.targetLoad, unit: item.loadUnit),
                targetReps: RepRange(item.reps, item.repUpperBound ?? item.reps),
                plannedSetCount: item.sets,
                restSeconds: TimeInterval(item.restSeconds),
                previousPerformance: [],
                sourcePrescription: "Custom session",
                coachingCue: definition?.shortCoachingCue,
                painGuardrail: item.authoredDefinition?.painGuardrail,
                equipmentIdentifiers: item.equipmentIdentifiers,
                alternativeExerciseIDs: item.authoredDefinition?.resolvedAlternativeIDs ?? [],
                unresolvedAlternativeNames: item.authoredDefinition?.unresolvedAlternativeNames ?? [],
                targetPrescription: item.prescription
            )
        }
        guard plans.count == items.count, let first = plans.first else { return nil }
        let fullWarmUp = WorkoutWarmUp(estimatedMinutes: 5, steps: [
            "Move easily for 3 to 5 minutes, gradually increasing your pace.",
            "Practice \(first.name) at an easy effort before your working sets.",
            "Start when the movement feels controlled. Stop or adjust if it causes pain."
        ])
        let warmUp = fullWarmUp.configured(for: warmUpLengthOverride ?? warmUpLength ?? .full, at: asOf)
        let engine = WorkoutProgressionEngine(reviews: progressionReviews, asOf: asOf)
        let resolvedPlans = plans.map { plan in
            let proposed = engine.plan(plan, using: previousHistory, allowIncrease: progressionAllowed)
            guard progressionAllowed else { return proposed }
            return WorkoutLoadChoiceResolver().apply(to: proposed, choices: loadChoices, history: previousHistory, engine: engine)
        }
        guard let estimate = WorkoutTimeEstimator().estimate(plans: resolvedPlans, warmUp: warmUp) else { return nil }
        return WorkoutSession(
            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
            customWorkoutID: id,
            targetDurationMinutes: estimate.maximumMinutes,
            warmUp: warmUp,
            exercises: resolvedPlans.map { WorkoutExercise(plan: $0) }
        )
    }
}

enum CustomWorkoutBuilderValidation {
    static func nameError(for workout: CustomWorkout, among saved: [CustomWorkout]) -> String? {
        let name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give this workout a name." }
        if name.count > 40 { return "Use 40 characters or fewer." }
        if saved.contains(where: {
            $0.id != workout.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(name) == .orderedSame
        }) { return "A workout with this name already exists." }
        return nil
    }

    static func loadError(for item: CustomWorkoutItem) -> String? {
        let quarters = item.targetLoad * 4
        let maximum = item.loadUnit == .pounds ? 880.0 : 400.0
        guard item.targetLoad.isFinite, item.targetLoad >= 0,
              item.targetLoad == 0 || (item.targetLoad >= 0.25 && item.targetLoad <= maximum
                  && abs(quarters.rounded() - quarters) < 0.000_001) else {
            return "Use 0.25 to \(Int(maximum)) \(item.loadUnit.rawValue) in 0.25 steps, or leave load empty."
        }
        return nil
    }

    static func exercisesError(for workout: CustomWorkout) -> String? {
        if workout.items.isEmpty { return "Add at least one exercise." }
        if workout.items.count > 50 { return "Use 50 exercises or fewer." }
        if Set(workout.items.map(\.id)).count != workout.items.count {
            return "An exercise row is duplicated. Remove it and add the exercise again."
        }
        if workout.items.contains(where: { !$0.isStructurallyValid }) {
            return "Check sets, reps or duration, rest and load for each exercise."
        }
        if workout.items.contains(where: { $0.resolvedExerciseID == nil }) {
            return "An exercise is unavailable in the library. Replace or remove it."
        }
        return nil
    }
}

enum ProgrammeSessionCustomizationError: Error, Equatable {
    case unavailableSession
    case unavailableExercise(String)
    case unsupportedPrescription(String)

    var message: String {
        switch self {
        case .unavailableSession:
            return "This session could not be matched to its authored programme. Reopen the programme and try again."
        case let .unavailableExercise(name):
            return "\(name) has no known authored definition in the library. This session cannot be copied completely yet."
        case let .unsupportedPrescription(name):
            return "\(name)'s target cannot be copied exactly into the editor. The original programme is still available."
        }
    }
}

enum ProgrammeSessionCustomization {
    /// A new editable value, with no repository mutation, history lookup or set data.
    /// Preview units are preferences; preview loads and performance are never copied.
    static func makeCopy(
        programme: WorkoutProgramme,
        previewSession: WorkoutSession,
        warmUpLength: WorkoutWarmUpLength
    ) throws -> CustomWorkout {
        guard previewSession.programmeID == programme.id, !previewSession.isComplete,
              previewSession.completedSetCount == 0,
              let authored = programme.sessions.first(where: {
                  $0.title == previewSession.title
                      && $0.exercisePlans.map(\.exerciseID) == previewSession.exercises.map { $0.plan.exerciseID }
              }) else { throw ProgrammeSessionCustomizationError.unavailableSession }

        let items = try authored.exercisePlans.enumerated().map { index, plan in
            guard ExerciseLibrary.exercise(id: plan.exerciseID) != nil else {
                throw ProgrammeSessionCustomizationError.unavailableExercise(plan.name)
            }
            let match = MoveKitExerciseCatalog.match(for: plan.exerciseID)
            let videoID = match?.relationship == .exact ? (match?.exercise.id ?? "") : ""
            let target = plan.prescription
            let unit = previewSession.exercises[index].plan.targetLoad.unit
            guard target.isValid, plan.restSeconds.isFinite,
                  plan.restSeconds.rounded() == plan.restSeconds,
                  (0 ... 600).contains(plan.restSeconds),
                  plan.targetLoad.value == 0 || unit == plan.targetLoad.unit else {
                throw ProgrammeSessionCustomizationError.unsupportedPrescription(plan.name)
            }
            let item = CustomWorkoutItem(videoID: videoID,
                sets: plan.plannedSetCount,
                reps: target.unit == .repetitions ? target.lowerBound : 1,
                restSeconds: Int(plan.restSeconds), targetLoad: plan.targetLoad.value, loadUnit: unit,
                durationSeconds: target.unit == .seconds ? target.lowerBound : nil,
                perSide: target.perSide ? true : nil,
                repUpperBound: target.unit == .repetitions && target.upperBound != target.lowerBound ? target.upperBound : nil,
                durationUpperBound: target.unit == .seconds && target.upperBound != target.lowerBound ? target.upperBound : nil,
                authoredExerciseID: plan.exerciseID)
            guard item.isValid, CustomWorkoutBuilderValidation.loadError(for: item) == nil else {
                throw ProgrammeSessionCustomizationError.unsupportedPrescription(plan.name)
            }
            return item
        }
        let copy = CustomWorkout(name: String(authored.title.prefix(35)) + " copy", items: items,
                                 warmUpLength: warmUpLength)
        guard copy.isValid else { throw ProgrammeSessionCustomizationError.unavailableSession }
        return copy
    }
}

/// The editor's recoverable copy is separate from the confirmed workout store.
/// Existing saved workouts and sessions keep their original encoding.
struct CustomWorkoutDraft: Codable, Equatable, Sendable {
    var workout: CustomWorkout
    var editedAt: Date

    init(workout: CustomWorkout, editedAt: Date = .now) {
        self.workout = workout
        self.editedAt = editedAt
    }
}

struct UserDefaultsCustomWorkoutDraftStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.customWorkoutDraft.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> CustomWorkoutDraft? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else { throw CustomWorkoutStoreError.unavailable }
        return try JSONDecoder().decode(CustomWorkoutDraft.self, from: data)
    }

    func save(_ draft: CustomWorkoutDraft?) throws {
        _ = try load() // Never overwrite a corrupt draft silently.
        if let draft {
            let data = try JSONEncoder().encode(draft)
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
        } else {
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else { throw WorkoutPersistenceError.verificationFailed }
        }
    }
}

enum CustomWorkoutStoreError: Error {
    case unavailable
    case invalidWorkout
}

protocol CustomWorkoutPersisting {
    func load() throws -> [CustomWorkout]
    func save(_ workouts: [CustomWorkout]) throws
}

struct UserDefaultsCustomWorkoutStore: CustomWorkoutPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "slick.customWorkouts.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [CustomWorkout] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data else { throw CustomWorkoutStoreError.unavailable }
        let workouts = try JSONDecoder().decode([CustomWorkout].self, from: data)
        guard Set(workouts.map(\.id)).count == workouts.count,
              workouts.allSatisfy(\.isStructurallyValid) else { throw CustomWorkoutStoreError.invalidWorkout }
        return workouts
    }

    func save(_ workouts: [CustomWorkout]) throws {
        _ = try load() // Never overwrite an unreadable existing payload.
        guard Set(workouts.map(\.id)).count == workouts.count,
              workouts.allSatisfy(\.isStructurallyValid) else { throw CustomWorkoutStoreError.invalidWorkout }
        // Persistence must preserve existing records even if their media catalog
        // is temporarily unavailable. The repository validates newly edited plans.
        let data = try JSONEncoder().encode(workouts)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw WorkoutPersistenceError.verificationFailed }
    }
}

@MainActor
@Observable
final class CustomWorkoutRepository {
    private(set) var workouts: [CustomWorkout]
    private(set) var isAvailable: Bool
    private(set) var draft: CustomWorkoutDraft?
    private(set) var isDraftAvailable: Bool
    private let store: any CustomWorkoutPersisting
    private let draftStore: UserDefaultsCustomWorkoutDraftStore

    init(
        store: any CustomWorkoutPersisting = UserDefaultsCustomWorkoutStore(),
        draftStore: UserDefaultsCustomWorkoutDraftStore = UserDefaultsCustomWorkoutDraftStore()
    ) {
        self.store = store
        self.draftStore = draftStore
        do {
            let loaded = try Self.readValidated(from: store)
            workouts = loaded
            isAvailable = true
        } catch {
            workouts = []
            isAvailable = false
        }
        do {
            draft = try draftStore.load()
            isDraftAvailable = true
        } catch {
            draft = nil
            isDraftAvailable = false
        }
    }

    @discardableResult
    func keepDraft(_ workout: CustomWorkout) -> Bool {
        guard isDraftAvailable else { return false }
        let proposed = CustomWorkoutDraft(workout: workout)
        do {
            try draftStore.save(proposed)
            draft = proposed
            return true
        } catch {
            isDraftAvailable = false
            return false
        }
    }

    /// An explicit recovery read. Never replaces unreadable saved workouts with
    /// an empty collection, writes storage, or discards the separate editor draft.
    @discardableResult
    func reload() -> Bool {
        do {
            let loaded = try Self.readValidated(from: store)
            workouts = loaded
            isAvailable = true
            return true
        } catch {
            isAvailable = false
            return false
        }
    }

    @discardableResult
    func discardDraft() -> Bool {
        guard isDraftAvailable else { return false }
        do {
            try draftStore.save(nil)
            draft = nil
            return true
        } catch {
            isDraftAvailable = false
            return false
        }
    }

    @discardableResult
    func save(_ workout: CustomWorkout) -> Bool {
        guard isAvailable, workout.isValid else { return false }
        var saved = workout
        saved.name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.updatedAt = .now
        let updated = (workouts.filter { $0.id != saved.id } + [saved])
            .sorted { $0.updatedAt > $1.updatedAt }
        return persist(updated)
    }

    /// Save a generated plan in one store write and confirm the whole collection.
    /// A partial readback is never reported as a successfully saved plan.
    @discardableResult
    func saveTogether(_ proposed: [CustomWorkout]) -> Bool {
        guard isAvailable, !proposed.isEmpty,
              Set(proposed.map(\.id)).count == proposed.count,
              proposed.allSatisfy(\.isValid) else { return false }
        let saved = proposed.map { workout -> CustomWorkout in
            var copy = workout
            copy.name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.updatedAt = .now
            return copy
        }
        let ids = Set(saved.map(\.id))
        let updated = (workouts.filter { !ids.contains($0.id) } + saved)
            .sorted { $0.updatedAt > $1.updatedAt }
        return persist(updated)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard isAvailable, workouts.contains(where: { $0.id == id }) else { return false }
        let updated = workouts.filter { $0.id != id }
        return persist(updated)
    }

    /// All app-owned mutations run synchronously on MainActor. Compare against
    /// the collection the caller observed, then confirm the entire result rather
    /// than just the edited IDs. This is not a cross-process/cloud transaction.
    private func persist(_ proposed: [CustomWorkout]) -> Bool {
        do {
            let current = try Self.readValidated(from: store)
            guard current == workouts else {
                workouts = current
                return false
            }
            try store.save(proposed)
        } catch {
            // A storage error may occur after bytes landed. Read exactly once
            // below; never retry the mutation or silently append the proposal.
        }
        guard let confirmed = try? Self.readValidated(from: store) else {
            isAvailable = false
            return false
        }
        workouts = confirmed
        return confirmed == proposed
    }

    private static func readValidated(from store: any CustomWorkoutPersisting) throws -> [CustomWorkout] {
        let loaded = try store.load()
        guard Set(loaded.map(\.id)).count == loaded.count,
              loaded.allSatisfy(\.isStructurallyValid) else {
            throw CustomWorkoutStoreError.invalidWorkout
        }
        return loaded
    }
}
