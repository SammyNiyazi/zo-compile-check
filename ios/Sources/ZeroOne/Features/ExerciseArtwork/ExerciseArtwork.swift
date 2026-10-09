import SwiftUI

struct ExerciseArtwork: Equatable, Sendable {
    let exerciseID: ExerciseID
    let exerciseName: String
    let level: ExerciseVisualLevel
    let assetName: String?
    let approvalStatus: ExerciseVisualApprovalStatus
    let fallbackLabel: String?
    let category: ExerciseCategory?
    let coachingCue: String?

    init(
        exerciseID: ExerciseID,
        exerciseName: String,
        level: ExerciseVisualLevel
    ) {
        let definition = ExerciseLibrary.exercise(id: exerciseID, fallbackName: exerciseName)
        self.exerciseID = exerciseID
        self.exerciseName = definition?.name ?? exerciseName
        self.level = level
        let catalogEntry = ExerciseVisualCatalog.entry(for: definition?.id ?? exerciseID)
        assetName = catalogEntry?.assets.resolvedName(for: level)
        approvalStatus = catalogEntry?.status ?? .pending
        fallbackLabel = approvalStatus == .pending
            ? ExerciseVisualCatalogEntry.pendingLabel
            : nil
        category = definition?.category
        coachingCue = definition?.shortCoachingCue
    }

    init(exerciseName: String, level: ExerciseVisualLevel = .hero) {
        self.init(
            exerciseID: ExerciseID(exerciseName: exerciseName),
            exerciseName: exerciseName,
            level: level
        )
    }

    var isAvailable: Bool {
        approvalStatus != .pending && assetName != nil
    }

    var accessibilityDescription: String {
        "Exercise demonstration poster for \(exerciseName)."
    }
}

struct ZeroOneExerciseArtwork: View {
    let artwork: ExerciseArtwork
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let assetName = artwork.assetName {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artwork.accessibilityDescription)
        .accessibilityHidden(!artwork.isAvailable)
    }
}

struct ZeroOneExerciseVisualSlot: View {
    let artwork: ExerciseArtwork
    var height: CGFloat
    var showsCue = false
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZeroOneExerciseArtwork(artwork: artwork)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()

            LinearGradient(
                colors: [.clear, theme.backgroundPrimary.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            if showsCue, let cue = artwork.coachingCue {
                HStack(alignment: .top, spacing: 9) {
                    Rectangle()
                        .fill(theme.brandGradientPrimary)
                        .frame(width: 2, height: 30)

                    Text(cue)
                        .zoText(.label)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                }
                .padding(14)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
    }
}
