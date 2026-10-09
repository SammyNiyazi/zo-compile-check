import AVFoundation
import Observation
import SwiftUI
import UIKit

struct MoveKitExercise: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let videoResource: String
    let posterResource: String
    let equipment: String
    let muscleFocus: String
    let sets: String
    let reps: String
    let rest: String

    var bundledVideoURL: URL? {
        Bundle.main.url(forResource: videoResource, withExtension: "mp4", subdirectory: "ExerciseVideos")
            ?? Bundle.main.url(forResource: videoResource, withExtension: "mp4")
    }

    /// Metadata membership alone is not proof that its demo was packaged.
    static var availableVideoIDs: Set<String> {
        Set(all.filter { $0.bundledVideoURL != nil }.map(\.id))
    }

    @MainActor var bundledPosterImage: UIImage? {
        UIImage(named: posterResource) ?? (
            Bundle.main.url(forResource: posterResource, withExtension: "jpg", subdirectory: "ExerciseVideos")
                ?? Bundle.main.url(forResource: posterResource, withExtension: "jpg")
        ).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// The licensed catalog is generated from the canonical 412-item metadata. Keep the
    /// first shipped demonstrations' reviewed copy and poster choices when merging it.
    static let all: [MoveKitExercise] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "ExerciseVideos")
                ?? Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let packaged = try? JSONDecoder().decode([MoveKitExercise].self, from: data),
              packaged.count == 412,
              Set(packaged.map(\.id)).count == packaged.count else {
            return curated
        }
        let curatedIDs = Set(curated.map(\.id))
        return curated + packaged
            .filter { !curatedIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private static let curated: [MoveKitExercise] = [
        .init(id: "dumbbell-goblet-squat", name: "Dumbbell goblet squat", videoResource: "dumbbell-goblet-squat", posterResource: "ExerciseGobletSquat01", equipment: "Dumbbell", muscleFocus: "Glutes and quadriceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-bench-press", name: "Dumbbell bench press", videoResource: "dumbbell-bench-press", posterResource: "ExerciseDumbbellBenchPress01", equipment: "Dumbbells", muscleFocus: "Chest", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "barbell-bench-press", name: "Barbell bench press", videoResource: "barbell-bench-press", posterResource: "ExerciseBarbellBenchPress01", equipment: "Barbell", muscleFocus: "Chest", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "barbell-squat", name: "Barbell back squat", videoResource: "barbell-squat", posterResource: "barbell-squat", equipment: "Barbell and rack", muscleFocus: "Quadriceps and glutes", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "machine-leg-extension", name: "Machine leg extension", videoResource: "machine-leg-extension", posterResource: "machine-leg-extension", equipment: "Leg extension machine", muscleFocus: "Quadriceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-incline-bench-press", name: "Incline dumbbell press", videoResource: "dumbbell-incline-bench-press", posterResource: "dumbbell-incline-bench-press", equipment: "Dumbbells and incline bench", muscleFocus: "Chest and shoulders", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "machine-assisted-pull-up", name: "Assisted pull-up", videoResource: "machine-assisted-pull-up", posterResource: "machine-assisted-pull-up", equipment: "Assisted pull-up machine", muscleFocus: "Back and biceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "barbell-romanian-deadlift", name: "Barbell Romanian deadlift", videoResource: "barbell-romanian-deadlift", posterResource: "barbell-romanian-deadlift", equipment: "Barbell", muscleFocus: "Hamstrings and glutes", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "cable-low-single-arm-lateral-raise", name: "Single-arm low-cable lateral raise", videoResource: "cable-low-single-arm-lateral-raise", posterResource: "cable-low-single-arm-lateral-raise", equipment: "Cable machine", muscleFocus: "Shoulders", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-goblet-split-squat", name: "Dumbbell goblet split squat", videoResource: "dumbbell-goblet-split-squat", posterResource: "dumbbell-goblet-split-squat", equipment: "Dumbbell", muscleFocus: "Quadriceps and glutes", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "lying-leg-curl", name: "Lying leg curl", videoResource: "lying-leg-curl", posterResource: "lying-leg-curl", equipment: "Leg curl machine", muscleFocus: "Hamstrings", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "lat-pulldown", name: "Lat pulldown", videoResource: "lat-pulldown", posterResource: "lat-pulldown", equipment: "Cable machine", muscleFocus: "Back", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "chest-supported-dumbbell-row", name: "Chest-supported dumbbell row", videoResource: "chest-supported-dumbbell-row", posterResource: "chest-supported-dumbbell-row", equipment: "Dumbbells and incline bench", muscleFocus: "Back", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "barbell-hip-thrust", name: "Barbell hip thrust", videoResource: "barbell-hip-thrust", posterResource: "barbell-hip-thrust", equipment: "Barbell and bench", muscleFocus: "Glutes", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "push-up", name: "Push-up", videoResource: "push-up", posterResource: "push-up", equipment: "Bodyweight", muscleFocus: "Chest and triceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "incline-treadmill-walk", name: "Incline treadmill walk", videoResource: "incline-treadmill-walk", posterResource: "incline-treadmill-walk", equipment: "Treadmill", muscleFocus: "Glutes and quadriceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-curl", name: "Dumbbell curl", videoResource: "dumbbell-curl", posterResource: "ExerciseDumbbellCurl01", equipment: "Dumbbells", muscleFocus: "Biceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-hammer-curl", name: "Dumbbell hammer curl", videoResource: "dumbbell-hammer-curl", posterResource: "ExerciseDumbbellHammerCurl01", equipment: "Dumbbells", muscleFocus: "Biceps and brachialis", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-incline-curl", name: "Dumbbell incline curl", videoResource: "dumbbell-incline-curl", posterResource: "ExerciseDumbbellInclineCurl01", equipment: "Dumbbells and incline bench", muscleFocus: "Biceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "dumbbell-seated-overhead-tricep-extension", name: "Seated dumbbell overhead triceps extension", videoResource: "dumbbell-seated-overhead-tricep-extension", posterResource: "ExerciseDumbbellOverheadTricepsExtension01", equipment: "Dumbbell", muscleFocus: "Triceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "cable-rope-pushdown", name: "Cable rope pushdown", videoResource: "cable-rope-pushdown", posterResource: "ExerciseCableRopePushdown01", equipment: "Cable and rope handle", muscleFocus: "Triceps", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        // Equipment and primary muscle for these newer clips come from the exact-slug 2026-09-23 exercise manifest.
        .init(id: "arnold-press", name: "Arnold press", videoResource: "arnold-press", posterResource: "arnold-press", equipment: "Dumbbell", muscleFocus: "Shoulders", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "barbell-bent-over-row", name: "Barbell bent over row", videoResource: "barbell-bent-over-row", posterResource: "barbell-bent-over-row", equipment: "Barbell", muscleFocus: "Back", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "band-high-face-pull", name: "Band high face pull", videoResource: "band-high-face-pull", posterResource: "band-high-face-pull", equipment: "Band", muscleFocus: "Shoulders", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "abdominals-stretch-variation-three", name: "Abdominals stretch variation three", videoResource: "abdominals-stretch-variation-three", posterResource: "abdominals-stretch-variation-three", equipment: "Bodyweight", muscleFocus: "Core", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout"),
        .init(id: "abdominals-stretch-variation-four", name: "Abdominals stretch variation four", videoResource: "abdominals-stretch-variation-four", posterResource: "abdominals-stretch-variation-four", equipment: "Stability Ball", muscleFocus: "Core", sets: "Follow your workout", reps: "Follow your workout", rest: "Follow your workout")
    ]
}

enum MoveKitExerciseRelationship: Equatable, Sendable {
    case exact
    case variation(String)

    var label: String {
        switch self {
        case .exact:
            return "Exercise video"
        case let .variation(description):
            return description
        }
    }
}

struct MoveKitExerciseMatch: Equatable, Sendable {
    let exercise: MoveKitExercise
    let relationship: MoveKitExerciseRelationship
}

enum MoveKitExerciseCatalog {
    private static let byID = Dictionary(uniqueKeysWithValues: MoveKitExercise.all.map { ($0.id, $0) })

    /// Programme imagery only. Do not change workout/history exercise identities
    /// or imply that an illustrative machine variation is an exact substitution.
    static func programmePoster(for exerciseID: ExerciseID) -> MoveKitExerciseMatch? {
        if exerciseID == ExerciseIDs.legPress {
            return variation("machine-leg-press", label: "Machine leg-press variation")
        }
        return match(for: exerciseID)
    }

    /// Every category used by the licensed catalog has a visible filter path.
    static let muscleFilters = [
        "Chest", "Back", "Shoulders", "Biceps", "Triceps", "Core", "Glutes",
        "Quadriceps", "Hamstrings", "Calves", "Forearms", "Trapezius",
        "Lower Back", "Adductors", "Tibialis", "Neck"
    ]
    static let equipmentFilters = [
        "Barbell", "Dumbbell", "Cable", "Machine", "Kettlebell", "Band",
        "Bodyweight", "Stability Ball", "Bicycle", "Weight Plate", "Sled",
        "Battle Ropes", "Bench", "Wrist Roller", "Treadmill"
    ]

    static func exercise(for videoID: String) -> MoveKitExercise? {
        byID[videoID]
    }

    private static let exactSeedIDByVideo: [String: ExerciseID] = {
        var matches: [String: ExerciseID] = [:]
        for definition in ExerciseLibrary.all {
            guard let match = match(for: definition.id), match.relationship == .exact else { continue }
            // Keep the first authored identity if seed aliases teach the same clip.
            if matches[match.exercise.id] == nil { matches[match.exercise.id] = definition.id }
        }
        return matches
    }()

    /// Keep exact seed IDs where known; every other licensed clip gets a stable,
    /// namespaced identity so custom workouts never borrow another exercise's history.
    static func workoutExerciseID(for videoID: String) -> ExerciseID? {
        guard byID[videoID] != nil else { return nil }
        return exactSeedExerciseID(for: videoID) ?? ExerciseID(rawValue: "MOV-\(videoID)")
    }

    /// A clip can display saved-work history only when it teaches the exact seed exercise.
    /// Related variations must never inherit another movement's logged sets.
    static func exactSeedExerciseID(for videoID: String) -> ExerciseID? {
        exactSeedIDByVideo[videoID]
    }

    /// Only offer authored plan alternatives with an exact bundled demo.
    /// A related-movement clip is not enough to teach a different exercise.
    static func substitutes(for plan: ExercisePlan) -> [ExerciseDefinition] {
        ExerciseSubstitutionCuration.authoredAlternativeIDs(for: plan).compactMap { id in
            guard id != plan.exerciseID,
                  let definition = ExerciseLibrary.exercise(id: id),
                  let match = match(for: id),
                  match.relationship == .exact, MoveKitExercise.availableVideoIDs.contains(match.exercise.id) else { return nil }
            return definition
        }
    }

    static func filter(
        query: String,
        muscle: String?,
        equipment: String?,
        in exercises: [MoveKitExercise] = MoveKitExercise.all
    ) -> [MoveKitExercise] {
        search(query, in: exercises).filter { exercise in
            let muscleMatches = muscle.map {
                exercise.muscleFocus.localizedCaseInsensitiveContains($0)
            } ?? true
            let equipmentMatches = equipment.map {
                exercise.equipment.localizedCaseInsensitiveContains($0)
            } ?? true
            return muscleMatches && equipmentMatches
        }
    }

    static func search(
        _ query: String,
        in exercises: [MoveKitExercise] = MoveKitExercise.all
    ) -> [MoveKitExercise] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return exercises }
        let aliases: [String: [String]] = [
            "ohp": ["overhead press"], "rdl": ["romanian deadlift"],
            "pullup": ["pull up", "pull ups"], "pullups": ["pull up", "pull ups"],
            "abs": ["abdominals", "core"]
        ]
        let phrase = terms.map { aliases[$0]?.first ?? $0 }.joined(separator: " ")
        return exercises.filter { exercise in
            let fields = normalized("\(exercise.name) \(exercise.muscleFocus) \(exercise.equipment) \(exercise.id)")
            return terms.allSatisfy { term in
                fields.contains(term) || (aliases[term]?.contains { fields.contains($0) } ?? false)
            }
        }.sorted { left, right in
            let leftName = normalized(left.name)
            let rightName = normalized(right.name)
            let leftRank = leftName == phrase ? 0 : leftName.hasPrefix(phrase) ? 1 : leftName.contains(phrase) ? 2 : 3
            let rightRank = rightName == phrase ? 0 : rightName.hasPrefix(phrase) ? 1 : rightName.contains(phrase) ? 2 : 3
            if leftRank != rightRank { return leftRank < rightRank }
            let nameOrder = left.name.localizedStandardCompare(right.name)
            return nameOrder == .orderedSame ? left.id < right.id : nameOrder == .orderedAscending
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    static func match(for exerciseID: ExerciseID) -> MoveKitExerciseMatch? {
        switch exerciseID.rawValue {
        case "EX-GOBLET-SQUAT":
            return variation("dumbbell-goblet-squat", label: "Dumbbell goblet-squat variation")
        case "EX-DUMBBELL-BENCH-PRESS":
            return exact("dumbbell-bench-press")
        case "EX-BARBELL-BENCH-PRESS":
            return exact("barbell-bench-press")
        case "EX-BARBELL-BACK-SQUAT":
            return exact("barbell-squat")
        case "EX-LEG-EXTENSION":
            return exact("machine-leg-extension")
        case "EX-INCLINE-DUMBBELL-PRESS":
            return exact("dumbbell-incline-bench-press")
        case "EX-ASSISTED-PULL-UP":
            return exact("machine-assisted-pull-up")
        case "EX-ROMANIAN-DEADLIFT":
            return variation("barbell-romanian-deadlift", label: "Barbell Romanian deadlift variation")
        case "EX-CABLE-LATERAL-RAISE":
            return variation("cable-low-single-arm-lateral-raise", label: "Single-arm low-cable variation")
        case "EX-SPLIT-SQUAT":
            return variation("dumbbell-goblet-split-squat", label: "Goblet-loaded split-squat variation")
        case "EX-LYING-LEG-CURL":
            return exact("lying-leg-curl")
        case "EX-LAT-PULLDOWN":
            return exact("lat-pulldown")
        case "EX-CHEST-SUPPORTED-ROW":
            return exact("chest-supported-dumbbell-row")
        case "EX-HIP-THRUST":
            return exact("barbell-hip-thrust")
        case "EX-PUSH-UP":
            return exact("push-up")
        case "EX-INCLINE-WALK":
            return exact("incline-treadmill-walk")
        case "EX-DUMBBELL-CURL":
            return exact("dumbbell-curl")
        case "EX-DUMBBELL-HAMMER-CURL":
            return exact("dumbbell-hammer-curl")
        case "EX-DUMBBELL-INCLINE-CURL":
            return exact("dumbbell-incline-curl")
        case "EX-DUMBBELL-OVERHEAD-TRICEPS-EXTENSION":
            return exact("dumbbell-seated-overhead-tricep-extension")
        case "EX-CABLE-TRICEPS-PRESSDOWN":
            return variation("cable-rope-pushdown", label: "Rope-handle pressdown variation")
        case "arnold-press":
            return exact("arnold-press")
        case "band-high-face-pull":
            return exact("band-high-face-pull")
        case "barbell-bent-over-row":
            return exact("barbell-bent-over-row")
        case "abdominals-stretch-variation-three":
            return exact("abdominals-stretch-variation-three")
        case "abdominals-stretch-variation-four":
            return exact("abdominals-stretch-variation-four")
        case "EX-FACE-PULL":
            return variation("band-high-face-pull", label: "Band face-pull variation")
        case "EX-OVERHEAD-PRESS":
            return variation("arnold-press", label: "Arnold-press variation")
        default:
            if exerciseID.rawValue.hasPrefix("MOV-") {
                return exact(String(exerciseID.rawValue.dropFirst(4)))
            }
            return nil
        }
    }

    private static func exact(_ id: String) -> MoveKitExerciseMatch? {
        guard let exercise = byID[id] else { return nil }
        return MoveKitExerciseMatch(exercise: exercise, relationship: .exact)
    }

    private static func variation(_ id: String, label: String) -> MoveKitExerciseMatch? {
        guard let exercise = byID[id] else { return nil }
        return MoveKitExerciseMatch(exercise: exercise, relationship: .variation(label))
    }
}

struct MoveKitExerciseGuide: View {
    let match: MoveKitExerciseMatch
    let plan: ExercisePlan

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    /// Proof 39: the licensed loop on top, cropped like `.zo-media.pose`, the
    /// name, the muscles as words, today's prescription and the cue. A
    /// variation clip says so, and then only the planned exercise's own
    /// muscles are named, never the clip's equipment.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MoveKitVideoPlayer(exercise: match.exercise)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                    role: .card).resolvedRadius, style: .continuous))

            if case .variation = match.relationship {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.string(match.relationship.label))
                        .zoText(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textPrimary)
                    Text("Use this clip for the movement pattern. Match your prescribed equipment and coaching cue below.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, ZOSpace.s)
            }

            Text(plan.name)
                .zoThemeHeading(.display, context: .directScrollDisplay)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)

            if !tags.isEmpty {
                ExerciseWordTags(tags: tags)
                    .padding(.top, ZOSpace.s)
            }

            let metadataLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
                : AnyLayout(HStackLayout(alignment: .top, spacing: ZOSpace.s))
            metadataLayout {
                metadata(title: "Sets", value: plan.plannedSetCount.formatted())
                metadata(title: plan.isTimed ? "Duration" : "Reps", value: workoutCopy.prescription(plan.prescription))
                metadata(title: "Rest", value: workoutCopy.quantity(Int(plan.restSeconds), .seconds))
            }
            .padding(ZOSpace.cardPadding)
            .zoThemeCardSurface()
            .padding(.top, ZOSpace.l)

            if let cue = plan.coachingCue, !cue.isEmpty {
                ExerciseDetailSubhead(title: "How to do it")
                ExerciseCueList(cues: [cue])
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tags: [String] {
        switch match.relationship {
        case .exact:
            return ExerciseDetailPresentation.tags(muscleFocus: match.exercise.muscleFocus,
                                                   equipment: match.exercise.equipment)
        case .variation:
            let names = ExerciseLibrary.exercise(id: plan.exerciseID).map {
                ($0.primaryMuscleNames + $0.secondaryMuscleNames).joined(separator: ", ")
            } ?? ""
            return ExerciseDetailPresentation.tags(muscleFocus: names, equipment: nil)
        }
    }

    private func metadata(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localization.string(title))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Proof `.zo-weekhead`: a section title, 22 pt above and 8 pt below, with an
/// optional trailing caption.
struct ExerciseDetailSubhead: View {
    let title: String
    var trailing: String? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
            Text(localization.string(title))
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ZOSpace.s)
            if let trailing {
                Text(trailing)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, ZOSpace.s)
    }
}

/// Proof `.zo-tags`: words as badges, wrapping, 6 pt apart.
struct ExerciseWordTags: View {
    let tags: [String]

    var body: some View {
        ExerciseTagFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                ZOBadge(text: tag)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Proof `.zo-cues`: numbered 28 pt discs on surface 2, 17/24 text, 12 pt
/// between cues.
struct ExerciseCueList: View {
    let cues: [String]

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            ForEach(Array(cues.enumerated()), id: \.offset) { index, cue in
                HStack(alignment: .top, spacing: 10) {
                    Text((index + 1).formatted())
                        .zoText(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textPrimary)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(theme.surfaceSecondary, in: Circle())
                        .accessibilityHidden(cues.count == 1)
                    Text(cue)
                        .zoText(.body)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Wraps tags onto as many lines as they need.
struct ExerciseTagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = rows(for: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct FlowRow {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [FlowRow] {
        var result: [FlowRow] = []
        var current = FlowRow()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                result.append(current)
                current = FlowRow()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { result.append(current) }
        return result
    }
}

struct MoveKitExerciseCarousel: View {
    enum Style { case preview, full }
    let style: Style
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedIndex = 0

    private var exercise: MoveKitExercise { MoveKitExercise.all[selectedIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MOVEKIT EXERCISES")
                        .zoText(.caption)

                        .foregroundStyle(theme.accentForeground)
                    Group {
                        if style == .preview {
                            Text(exercise.name).zoText(.section)
                        } else {
                            Text(exercise.name).zoThemeText(.title)
                        }
                    }
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(selectedIndex + 1)/\(MoveKitExercise.all.count)")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            MoveKitVideoPlayer(exercise: exercise)
                .id(exercise.id)
                .frame(maxWidth: .infinity)
                .aspectRatio(1936.0 / 1072.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme,
                    role: .card, radius: ZORadius.control).resolvedRadius, style: .continuous))

            Text("Movement preview only. Follow your workout for sets, reps, and load.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                selectedIndex = (selectedIndex + 1) % MoveKitExercise.all.count
            } label: {
                HStack {
                    Text("Next exercise")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(ZOButtonStyle(.primary))
            .accessibilityHint("Shows the next supplied MoveKit exercise.")
        }
        .padding(style == .preview ? ZOSpace.m : ZOSpace.l)
        .zoThemeCardSurface()
    }

}

/// How a demonstration fills its frame. `.fit` is the existing letterboxed
/// default; `.cover` fills and crops with a vertical focus (0 is the top,
/// 0.5 the centre), as proof `.zo-media.pose` frames posters at 42%.
enum MoveKitMediaPresentation: Equatable, Sendable {
    case fit
    case cover(focusY: CGFloat)
}

private struct MoveKitMediaFraming: ViewModifier {
    static let aspect: CGFloat = 1936.0 / 1072.0
    let presentation: MoveKitMediaPresentation

    func body(content: Content) -> some View {
        switch presentation {
        case .fit:
            content.aspectRatio(Self.aspect, contentMode: .fit)
        case let .cover(focusY):
            Color.clear
                .overlay {
                    GeometryReader { proxy in
                        let frame = proxy.size
                        let filled = frame.width / max(1, frame.height) > Self.aspect
                            ? CGSize(width: frame.width, height: frame.width / Self.aspect)
                            : CGSize(width: frame.height * Self.aspect, height: frame.height)
                        content
                            .frame(width: filled.width, height: filled.height)
                            .position(x: frame.width / 2,
                                      y: frame.height / 2 + (filled.height - frame.height) * (0.5 - focusY))
                    }
                }
                .clipped()
        }
    }
}

struct MoveKitVideoPlayer: View {
    let exercise: MoveKitExercise
    let playbackAllowed: Bool
    let presentation: MoveKitMediaPresentation
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = InlineExercisePlayback()
    @State private var isVisible = false
    @State private var isPlaying = true
    @State private var playbackRate: Float = 1
    @State private var systemAutoplayEnabled = false
    @State private var userRequestedPlayback = false

    init(exercise: MoveKitExercise, playbackAllowed: Bool = true,
         presentation: MoveKitMediaPresentation = .fit) {
        self.exercise = exercise
        self.playbackAllowed = playbackAllowed
        self.presentation = presentation
    }

    var body: some View {
        ZStack {
            if let poster = posterImage {
                Image(uiImage: poster)
                    .resizable()
                    .modifier(MoveKitMediaFraming(presentation: presentation))
            }
            if showsVideoLayer && playback.isReady && !playback.didFail {
                InlineExerciseVideoSurface(player: playback.player)
                    .modifier(MoveKitMediaFraming(presentation: presentation))
                    .allowsHitTesting(false)
            } else if videoURL == nil || playback.didFail {
                VStack(spacing: ZOSpace.s) {
                    Image(systemName: "video.slash")
                        .zoIcon(ZOIcon.row)
                    Text(playback.didFail ? "Video couldn't play" : "Exercise video unavailable")
                        .zoText(.section)
                    Text("Your workout can continue.")
                        .zoText(.caption)
                }
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfacePrimary.opacity(0.92))
            }
        }
        // README decision 69 (Sammy, 5 Oct): nothing on top of the animation,
        // the whole frame shows, spare room in the posters' studio grey.
        // Tapping the animation itself plays, pauses or retries it.
        .contentShape(Rectangle())
        .onTapGesture { toggleDemonstration() }
        .background(presentation == .fit ? Color(zoHex: 0xECECEA) : theme.surfacePrimary)
        .onAppear {
            isVisible = true
            refreshAutoplayPreference()
        }
        .onChange(of: exercise.videoResource) { _, _ in
            userRequestedPlayback = false
            playbackRate = 1
            playback.reset()
            refreshAutoplayPreference()
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced {
                userRequestedPlayback = false
            }
            refreshAutoplayPreference()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshAutoplayPreference() }
            else { playback.pause() }
        }
        .onChange(of: playbackAllowed) { _, _ in refreshAutoplayPreference() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.videoAutoplayStatusDidChangeNotification
        )) { _ in refreshAutoplayPreference() }
        .onDisappear {
            isVisible = false
            playback.pause()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(videoURL != nil ? .isButton : [])
        .accessibilityHint(videoURL == nil ? "" : playback.didFail ? "Double-tap to retry the video."
            : isVideoPlaying ? "Double-tap to pause." : "Double-tap to play.")
        .accessibilityLabel(playback.didFail
            ? "Video failed to play for \(exercise.name). Your workout can continue."
            : videoURL == nil
            ? "No video demonstration available for \(exercise.name)"
            : !showsVideoLayer
                ? "Still demonstration of \(exercise.name). \(reduceMotion ? "Animation is off for Reduce Motion." : "Autoplay is off. Press Play to view motion.")"
                : isVideoPlaying
                    ? "Looping demonstration of \(exercise.name)"
                    : "Paused demonstration of \(exercise.name)")
    }

    private func toggleDemonstration() {
        guard videoURL != nil else { return }
        if playback.didFail {
            playback.reset()
            isPlaying = true
            userRequestedPlayback = true
        } else if !showsVideoLayer {
            userRequestedPlayback = true
            isPlaying = true
        } else {
            isPlaying.toggle()
        }
        refreshAutoplayPreference()
    }

    private var showsVideoLayer: Bool {
        videoURL != nil && ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: reduceMotion,
            systemAutoplayEnabled: systemAutoplayEnabled,
            userRequestedPlayback: userRequestedPlayback
        )
    }

    private var isVideoPlaying: Bool {
        isVisible && playbackAllowed && scenePhase == .active && isPlaying && showsVideoLayer && !playback.didFail
    }

    private var videoURL: URL? {
        exercise.bundledVideoURL
    }

    private var posterImage: UIImage? {
        exercise.bundledPosterImage
    }

    private func refreshAutoplayPreference() {
        let autoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
        systemAutoplayEnabled = autoplayEnabled
        let shouldPlay = ExerciseVideoPlaybackPolicy.shouldPlay(
            reduceMotion: reduceMotion,
            systemAutoplayEnabled: autoplayEnabled,
            userRequestedPlayback: userRequestedPlayback,
            isPlaying: isPlaying,
            didFail: playback.didFail,
            sceneActive: scenePhase == .active,
            isVisible: isVisible,
            playbackAllowed: playbackAllowed
        )
        if shouldPlay, let videoURL {
            playback.play(url: videoURL, rate: playbackRate)
        } else {
            playback.pause()
        }
    }
}

enum ExerciseVideoPlaybackPolicy {
    static func showsVideo(
        reduceMotion: Bool,
        systemAutoplayEnabled: Bool,
        userRequestedPlayback: Bool
    ) -> Bool {
        userRequestedPlayback || (!reduceMotion && systemAutoplayEnabled)
    }

    static func shouldPlay(
        reduceMotion: Bool,
        systemAutoplayEnabled: Bool,
        userRequestedPlayback: Bool,
        isPlaying: Bool,
        didFail: Bool,
        sceneActive: Bool,
        isVisible: Bool,
        playbackAllowed: Bool
    ) -> Bool {
        // Retained navigation/tab content can receive foreground and accessibility
        // notifications after disappearing. Neither is permission to play offscreen.
        isVisible && playbackAllowed && sceneActive && isPlaying && !didFail && showsVideo(
            reduceMotion: reduceMotion,
            systemAutoplayEnabled: systemAutoplayEnabled,
            userRequestedPlayback: userRequestedPlayback
        )
    }
}

@MainActor
@Observable
final class InlineExercisePlayback {
    private(set) var player = AVQueuePlayer()
    private(set) var isReady = false
    private(set) var didFail = false

    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var looperStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var failedToEndObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var looper: AVPlayerLooper?

    init() {
        observePlayer()
    }

    private func observePlayer() {
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeCurrentItem() }
        }
        let activeGeneration = generation
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            Task { @MainActor [weak self] in self?.markFailed(generation: activeGeneration) }
        }
    }

    deinit {
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
    }

    func play(url: URL, rate: Float = 1) {
        do {
            try WorkoutAudioSessionController.shared.prepareForSilentPlayback()
        } catch {
            markFailed(generation: generation)
            return
        }
        if currentURL != url {
            reset()
            currentURL = url
            player.isMuted = true
            let newLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            looper = newLooper
            let activeGeneration = generation
            looperStatusObservation = newLooper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                Task { @MainActor [weak self] in self?.markFailed(generation: activeGeneration) }
            }
            observeCurrentItem()
        }
        guard !didFail else { return }
        player.defaultRate = rate
        player.play()
    }

    func pause() { player.pause() }

    func reset() {
        generation += 1
        currentItemObservation = nil
        playerStatusObservation = nil
        looperStatusObservation = nil
        itemStatusObservation = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
        player.pause()
        looper = nil
        player.removeAllItems()
        player = AVQueuePlayer()
        observePlayer()
        currentURL = nil
        isReady = false
        didFail = false
    }

    private func observeCurrentItem() {
        itemStatusObservation = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
        guard let item = player.currentItem else { return }
        let activeGeneration = generation
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor [weak self] in self?.markReady(generation: activeGeneration) }
            case .failed:
                Task { @MainActor [weak self] in self?.markFailed(generation: activeGeneration) }
            default:
                break
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markFailed(generation: activeGeneration) }
        }
    }

    private func markReady(generation: Int) {
        guard generation == self.generation, !didFail else { return }
        isReady = true
    }

    private func markFailed(generation: Int) {
        guard generation == self.generation else { return }
        isReady = false
        didFail = true
        player.pause()
    }
}

private struct InlineExerciseVideoSurface: UIViewRepresentable {
    let player: AVQueuePlayer

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        playerLayer.isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
