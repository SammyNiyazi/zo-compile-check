import Foundation

struct ZeroOneTrainingSeed: Decodable, Sendable {
    let schemaVersion: String
    let status: String
    let scope: String
    let sourcePolicy: TrainingSeedSourcePolicy
    let evidenceRecords: [EvidenceRecord]
    let exercises: [TrainingExerciseRecord]
    let programmeTemplates: [TrainingProgrammeRecord]
    let effortMeter: TrainingEffortMeter
    let codexIntegrationContract: TrainingSeedIntegrationContract

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case scope
        case sourcePolicy = "source_policy"
        case evidenceRecords = "evidence_records"
        case exercises
        case programmeTemplates = "programme_templates"
        case effortMeter = "effort_meter"
        case codexIntegrationContract = "codex_integration_contract"
    }
}

struct TrainingSeedSourcePolicy: Decodable, Sendable {
    let exerciseTaxonomySeed: String
    let exerciseTaxonomyLicense: String
    let productVisualPolicy: String

    enum CodingKeys: String, CodingKey {
        case exerciseTaxonomySeed = "exercise_taxonomy_seed"
        case exerciseTaxonomyLicense = "exercise_taxonomy_license"
        case productVisualPolicy = "product_visual_policy"
    }
}

struct EvidenceRecord: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let type: String
    let title: String
    let year: Int
    let url: String
    let use: String
}

struct TrainingExerciseRecord: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let equipment: [String]
    let pattern: String
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let level: String
    let cue: String
    let substitutions: [String]
    let painGuardrail: String
    let visualSeed: TrainingVisualSeed

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case equipment
        case pattern
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
        case level
        case cue
        case substitutions
        case painGuardrail = "pain_guardrail"
        case visualSeed = "visual_seed"
    }
}

struct TrainingVisualSeed: Decodable, Equatable, Sendable {
    let datasetLookup: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case datasetLookup = "dataset_lookup"
        case status
    }
}

struct TrainingProgrammeRecord: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let experienceBand: String
    let goalSupport: [String]
    let schedule: String
    let durationWeeks: Int
    let baseRules: TrainingProgrammeRules
    let sessions: [TrainingProgrammeSessionRecord]
    let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case experienceBand = "experience_band"
        case goalSupport = "goal_support"
        case schedule
        case durationWeeks = "duration_weeks"
        case baseRules = "base_rules"
        case sessions
        case evidenceIDs = "evidence_ids"
    }
}

struct TrainingProgrammeRules: Decodable, Equatable, Sendable {
    let setsPerExercise: String
    let targetRIR: String
    let restSeconds: String
    let progression: String

    enum CodingKeys: String, CodingKey {
        case setsPerExercise = "sets_per_exercise"
        case targetRIR = "target_rir"
        case restSeconds = "rest_seconds"
        case progression
    }
}

struct TrainingProgrammeSessionRecord: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let items: [TrainingProgrammeItemRecord]
}

struct TrainingProgrammeItemRecord: Decodable, Equatable, Sendable {
    let exerciseID: String
    let sets: String
    let target: String

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        exerciseID = try container.decode(String.self)
        sets = try container.decode(String.self)
        target = try container.decode(String.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A programme item must contain exercise ID, sets, and target."
            )
        }
    }
}

struct TrainingEffortMeter: Decodable, Sendable {
    let modes: [String: String]
    let hardStops: [String]

    enum CodingKeys: String, CodingKey {
        case modes
        case hardStops = "hard_stops"
    }
}

struct TrainingSeedIntegrationContract: Decodable, Sendable {
    let useNow: [String]
    let doNotDo: [String]
    let nextRequiredAssets: [String]

    enum CodingKeys: String, CodingKey {
        case useNow = "use_now"
        case doNotDo = "do_not_do"
        case nextRequiredAssets = "next_required_assets"
    }
}

enum TrainingSeedError: Error, Equatable {
    case resourceMissing
    case unsupportedSchema(String)
    case invalidExerciseCount(Int)
    case invalidProgrammeCount(Int)
    case invalidEvidenceCount(Int)
    case duplicateIdentifier(String)
    case unknownExerciseReference(String)
    case unknownEvidenceReference(String)
}

struct TrainingSeedLoader {
    private final class BundleAnchor {}

    func load(bundle: Bundle = Bundle(for: BundleAnchor.self)) throws -> ZeroOneTrainingSeed {
        let resourceURL = bundle.url(
            forResource: "01-training-seed-v0.1",
            withExtension: "json"
        ) ?? bundle.url(
            forResource: "01-training-seed-v0.1",
            withExtension: "json",
            subdirectory: "Fixtures"
        )

        guard let resourceURL else {
            throw TrainingSeedError.resourceMissing
        }

        let seed = try JSONDecoder().decode(
            ZeroOneTrainingSeed.self,
            from: Data(contentsOf: resourceURL)
        )
        try validate(seed)
        return seed
    }

    func validate(_ seed: ZeroOneTrainingSeed) throws {
        guard seed.schemaVersion == "0.1.0" else {
            throw TrainingSeedError.unsupportedSchema(seed.schemaVersion)
        }
        guard seed.exercises.count == 28 else {
            throw TrainingSeedError.invalidExerciseCount(seed.exercises.count)
        }
        guard seed.programmeTemplates.count == 5 else {
            throw TrainingSeedError.invalidProgrammeCount(seed.programmeTemplates.count)
        }
        guard seed.evidenceRecords.count == 6 else {
            throw TrainingSeedError.invalidEvidenceCount(seed.evidenceRecords.count)
        }

        try validateUnique(seed.exercises.map(\.id))
        try validateUnique(seed.programmeTemplates.map(\.id))
        try validateUnique(seed.evidenceRecords.map(\.id))

        let exerciseIDs = Set(seed.exercises.map(\.id))
        let evidenceIDs = Set(seed.evidenceRecords.map(\.id))

        for programme in seed.programmeTemplates {
            for item in programme.sessions.flatMap(\.items) where !exerciseIDs.contains(item.exerciseID) {
                throw TrainingSeedError.unknownExerciseReference(item.exerciseID)
            }
            for evidenceID in programme.evidenceIDs where !evidenceIDs.contains(evidenceID) {
                throw TrainingSeedError.unknownEvidenceReference(evidenceID)
            }
        }
    }

    private func validateUnique(_ identifiers: [String]) throws {
        var seen = Set<String>()
        for identifier in identifiers where !seen.insert(identifier).inserted {
            throw TrainingSeedError.duplicateIdentifier(identifier)
        }
    }
}

enum TrainingSeedRepository {
    static let shared: ZeroOneTrainingSeed = {
        do {
            return try TrainingSeedLoader().load()
        } catch {
            preconditionFailure("Bundled 01 training seed is invalid: \(error)")
        }
    }()
}
