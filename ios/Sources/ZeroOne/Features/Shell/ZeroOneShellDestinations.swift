import CoreText
import SwiftUI
import UIKit
import os

@MainActor
struct SocialHomeView: View {
    @Environment(\.zeroOneTheme) private var theme
    let history: WorkoutHistoryRepository
    let isWorkoutActive: Bool
    let workoutStateAvailable: Bool
    @State private var section: SocialSection = .following
    @State private var selectedWorkout: WorkoutHistoryEntry?
    @Environment(ZeroOneAccountStore.self) private var account
    /// Club core v1 (Sammy, 10 Oct): the real Club when this build has the account service.
    @State private var club: ClubStore?

    private var composeAvailability: SocialComposeAvailability {
        if !workoutStateAvailable { return .unavailable }
        return isWorkoutActive ? .workoutActive : .ready
    }

    private var shareableSessions: [WorkoutHistoryEntry] {
        history.entries.filter { entry in
            entry.exercises?.contains(where: { !$0.completedSets.isEmpty }) == true
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ZOSpace.l) {
                    SocialHeader()
                    HStack(spacing: 0) {
                        ForEach(SocialSection.allCases) { item in
                            Button {
                                withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.24)) {
                                    section = item
                                }
                            } label: {
                                VStack(spacing: ZOSpace.s) {
                                    Text(item.rawValue)
                                        .zoText(.section)
                                    Rectangle()
                                        .fill(section == item ? theme.textPrimary : .clear)
                                        .frame(height: 2)
                                }
                                .foregroundStyle(section == item ? theme.textPrimary : theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(section == item ? .isSelected : [])
                        }
                    }
                    if section == .following {
                        if let club, account.isConfigured {
                            ClubFeedSection(club: club, history: history)
                        }
                        followingContent
                    } else if section == .clubs {
                        // Sammy, 9 Oct: the Club runs locally until its service is live.
                        LocalCrewSection(history: history)
                    } else {
                        SocialServiceGate(section: section)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.m)
                .padding(.bottom, ZOSpace.x4)
            }
            .scrollIndicators(.hidden)
        }
        .zoThemeScreenSurface()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if club == nil { club = ClubStore.live(account: account) }
            club?.accountChanged(to: account.identity?.id)
        }
        .onChange(of: account.identity?.id) { _, id in
            club?.accountChanged(to: id)
            Task { await club?.refresh(history: history.entries) }
        }
        .fullScreenCover(item: $selectedWorkout) { workout in
            Group {
                SocialComposeView(workout: workout, history: history.entries)
                .zeroOneTheme(theme)
            }
            .zoSheet(theme)
        }
        .task {
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["ZERO_ONE_REVIEW_SOCIAL_STATE"] == "preview",
               environment["ZERO_ONE_REVIEW_HISTORY_STATE"] == "completed",
               composeAvailability == .ready, history.availability == .available {
                selectedWorkout = shareableSessions.first
            }
            #endif
        }
    }

    @ViewBuilder
    private var followingContent: some View {
        if !account.isConfigured { SocialServiceGate(section: .following) }
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("SHARE FROM YOUR HISTORY")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            if composeAvailability == .workoutActive {
                Text("Finish your active workout before making a share image. Your saved sessions stay here.")
                    .foregroundStyle(theme.textSecondary)
            } else if composeAvailability == .unavailable {
                Text("Workout state is unavailable, so sharing is paused to protect your session. No data was changed.")
                    .foregroundStyle(theme.textSecondary)
            } else if history.availability == .unavailable {
                Text("Workout History is unavailable. No session data was changed.")
                    .foregroundStyle(theme.textSecondary)
            } else if shareableSessions.isEmpty {
                Text("Finish a workout to make a share image from your saved sets.")
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(shareableSessions.prefix(8)) { entry in
                    Button { selectedWorkout = entry } label: {
                        SocialSavedSessionRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

}

private enum SocialComposeAvailability: Equatable {
    case ready
    case workoutActive
    case unavailable
}

private enum SocialSection: String, CaseIterable, Identifiable {
    case following = "Following"
    case discover = "Discover"
    case clubs = "Clubs"

    var id: String { rawValue }
}

private struct SocialHeader: View {
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("Social")
                .zoThemeHeading(.display, context: .headRowDisplay)
                .foregroundStyle(theme.textPrimary)
            Text("Your numbers tell the story. You choose what leaves the app.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SocialServiceGate: View {
    let section: SocialSection
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Image(systemName: section == .clubs ? "person.3" : "person.2")
                .zoIcon(ZOIcon.feature)
                .foregroundStyle(theme.accentForeground)
                .accessibilityHidden(true)
            Text(section == .clubs ? "Clubs need a real community." : "The people you choose, when Social is ready.")
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
            Text("Following, posts and clubs need accounts, a secure service and human moderation. They are not live yet. You can make a share image from a saved workout now.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }
}

private struct SocialSavedSessionRow: View {
    let entry: WorkoutHistoryEntry
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        HStack(spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(entry.title)
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                Text("\(entry.completedSetCount) saved sets · \(entry.completedAt.formatted(.dateTime.day().month().year()))")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: ZOSpace.s)
            Image(systemName: "arrow.up.right")
                .foregroundStyle(theme.accentForeground)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, ZOSpace.m)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.control))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose sets and preview an image to share outside 01.")
    }
}

enum SocialLoadVisibility: String, CaseIterable, Identifiable {
    case exact = "Exact load"
    case change = "Change only"
    case repsOnly = "Reps only"

    var id: String { rawValue }
}

struct SocialShareBlock {
    let id: UUID
    let exerciseID: ExerciseID
    let name: String
    let sets: [CompletedSet]

    var repsSummary: String {
        sets.map { $0.isTimed ? $0.performanceText : "\($0.reps)\($0.isPerSide == true ? " per side" : "")" }
            .joined(separator: " · ")
    }
}

struct SocialSharePreview {
    let workoutTitle: String
    let completedAt: Date
    let headline: String
    let note: String
    let visibility: SocialLoadVisibility
    let chips: [String]
    let blocks: [SocialShareBlock]

    var selectedSetCount: Int { blocks.reduce(0) { $0 + $1.sets.count } }
}

/// Local image sharing only. No post, follower or server state is inferred.
struct SocialShareDraft {
    let workout: WorkoutHistoryEntry
    var selectedSetIDs: Set<UUID>
    var visibility: SocialLoadVisibility = .exact
    var showComparison = true
    var showPR = true
    var headlineOverride = ""
    var note = ""

    init(workout: WorkoutHistoryEntry) {
        self.workout = workout
        selectedSetIDs = Set(
            workout.exercises?.first(where: { !$0.completedSets.isEmpty })?
                .completedSets.map(\.id) ?? []
        )
    }

    var canPreview: Bool { !selectedSetIDs.isEmpty }

    var warnsAboutTypedLoad: Bool {
        visibility != .exact
            && (headlineOverride + " " + note).range(
                of: #"\b\d+([.,]\d+)?\s*(kg|lb)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
    }

    mutating func toggleExercise(_ exercise: WorkoutHistoryExercise) {
        let ids = Set(exercise.completedSets.map(\.id))
        if ids.isSubset(of: selectedSetIDs) {
            selectedSetIDs.subtract(ids)
        } else {
            selectedSetIDs.formUnion(ids)
        }
    }

    mutating func toggleSet(_ setID: UUID) {
        if !selectedSetIDs.insert(setID).inserted {
            selectedSetIDs.remove(setID)
        }
    }

    func preview(history: [WorkoutHistoryEntry]) -> SocialSharePreview {
        let blocks = (workout.exercises ?? []).compactMap { exercise -> SocialShareBlock? in
            let sets = exercise.completedSets.filter { selectedSetIDs.contains($0.id) }
            guard !sets.isEmpty else { return nil }
            let name = ExerciseLibrary.exercise(id: exercise.exerciseID)?.name
                ?? MoveKitExercise.all.first(where: {
                    MoveKitExerciseCatalog.workoutExerciseID(for: $0.id) == exercise.exerciseID
                })?.name
                ?? exercise.exerciseID.rawValue
            return SocialShareBlock(id: exercise.id, exerciseID: exercise.exerciseID, name: name, sets: sets)
        }
        let first = blocks.first
        let suggested: String
        if let first {
            if visibility == .exact, let set = first.sets.first {
                suggested = "\(first.name) · \(Self.setText(set, visibility: .exact))"
            } else {
                suggested = "\(first.name) · \(first.sets.count) saved \(first.sets.count == 1 ? "set" : "sets")"
            }
        } else {
            suggested = workout.title
        }
        let typed = headlineOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var chips: [String] = []
        if let first,
           let occurrence = workout.exercises?.first(where: { $0.id == first.id }) {
            let prior = SocialShareAnalysis.lastOccurrence(
                for: first.exerciseID, before: workout, in: history
            )
            let selectedWholeOccurrence = first.sets.count == occurrence.completedSets.count
            let earlierSets = SocialShareAnalysis.priorSets(
                for: first.exerciseID, before: workout, in: history
            )
            if showPR, selectedWholeOccurrence,
               SocialShareAnalysis.isPersonalRecord(current: first.sets, previous: earlierSets) {
                chips.append("Personal record")
            }
            if showComparison, selectedWholeOccurrence, let prior,
               let comparison = SocialShareAnalysis.change(
                   current: first.sets, previous: prior, visibility: visibility
               ) {
                chips.append(comparison)
            }
        }
        return SocialSharePreview(
            workoutTitle: workout.title,
            completedAt: workout.completedAt,
            headline: typed.isEmpty ? suggested : typed,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: visibility,
            chips: chips,
            blocks: blocks
        )
    }

    static func setText(_ set: CompletedSet, visibility: SocialLoadVisibility) -> String {
        if set.isTimed { return set.performanceText }
        switch visibility {
        case .exact:
            return set.load.value == 0
                ? "Bodyweight × \(set.reps)\(set.isPerSide == true ? " per side" : "")"
                : "\(set.load.displayText) × \(set.reps)\(set.isPerSide == true ? " per side" : "")"
        case .change, .repsOnly:
            return set.performanceText
        }
    }
}

enum SocialShareAnalysis {
    static func priorSets(
        for exerciseID: ExerciseID,
        before workout: WorkoutHistoryEntry,
        in history: [WorkoutHistoryEntry]
    ) -> [CompletedSet] {
        history
            .filter { $0.id != workout.id && $0.completedAt < workout.completedAt }
            .flatMap { entry in
                (entry.exercises ?? [])
                    .filter { $0.exerciseID == exerciseID }
                    .flatMap(\.completedSets)
            }
    }

    static func lastOccurrence(
        for exerciseID: ExerciseID,
        before workout: WorkoutHistoryEntry,
        in history: [WorkoutHistoryEntry]
    ) -> [CompletedSet]? {
        history
            .filter { $0.id != workout.id && $0.completedAt < workout.completedAt }
            .sorted(by: WorkoutHistoryEntry.newestFirst)
            .lazy
            .compactMap { entry in
                entry.exercises?.last(where: {
                    $0.exerciseID == exerciseID && !$0.completedSets.isEmpty
                })?.completedSets
            }
            .first
    }

    static func isPersonalRecord(current: [CompletedSet], previous: [CompletedSet]) -> Bool {
        current.contains { set in
            guard !set.isTimed else { return false }
            let sameUnit = previous.filter {
                !$0.isTimed && $0.load.unit == set.load.unit && $0.isPerSide == set.isPerSide
            }
            guard !sameUnit.isEmpty else { return false }
            let improvesPrior = sameUnit.contains {
                $0.load.value <= set.load.value && $0.reps <= set.reps
                    && ($0.load.value < set.load.value || $0.reps < set.reps)
            }
            let alreadyMatchedOrBeaten = sameUnit.contains {
                $0.load.value >= set.load.value && $0.reps >= set.reps
            }
            return improvesPrior && !alreadyMatchedOrBeaten
        }
    }

    static func change(
        current: [CompletedSet],
        previous: [CompletedSet],
        visibility: SocialLoadVisibility
    ) -> String? {
        guard let now = current.first, let before = previous.first,
              !now.isTimed, !before.isTimed, now.isPerSide == before.isPerSide,
              now.load.unit == before.load.unit else { return nil }
        if visibility != .repsOnly, now.load.value != before.load.value {
            let loadDelta = now.load.value - before.load.value
            let loadText = "\(loadDelta > 0 ? "+" : "")\(loadDelta.formatted()) \(now.load.unit.rawValue)"
            let repDelta = now.reps - before.reps
            if repDelta != 0 {
                return "\(loadText), \(repDelta > 0 ? "+" : "")\(repDelta) reps vs last time"
            }
            return "\(loadText) vs last time"
        }
        let delta = now.reps - before.reps
        guard delta != 0 else { return nil }
        return "\(delta > 0 ? "+" : "")\(delta) reps vs last time"
    }
}

private enum SocialComposeStep {
    case choose
    case preview
}

private struct SocialShareImage: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

private struct SocialComposeView: View {
    let workout: WorkoutHistoryEntry
    let history: [WorkoutHistoryEntry]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @State private var draft: SocialShareDraft
    @State private var step: SocialComposeStep = .choose
    @State private var shareImage: SocialShareImage?
    @State private var imageFailed = false
    @State private var cardStyle: SocialShareCardStyle = .warm

    init(workout: WorkoutHistoryEntry, history: [WorkoutHistoryEntry]) {
        self.workout = workout
        self.history = history
        let initialDraft = SocialShareDraft(workout: workout)
        _draft = State(initialValue: initialDraft)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["ZERO_ONE_REVIEW_SOCIAL_STATE"] == "preview",
           environment["ZERO_ONE_REVIEW_HISTORY_STATE"] == "completed", initialDraft.canPreview {
            _step = State(initialValue: .preview)
            if let rawStyle = environment["ZERO_ONE_REVIEW_SHARE_STYLE"],
               let style = SocialShareCardStyle(rawValue: rawStyle) {
                _cardStyle = State(initialValue: style)
            }
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    stepTrack
                    if step == .choose {
                        chooseContent
                    } else {
                        previewContent
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, ZOSpace.l)
                .padding(.vertical, ZOSpace.m)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomAction
                    .padding(.horizontal, ZOSpace.l)
                    .padding(.vertical, ZOSpace.s)
                    .background(theme.backgroundPrimary)
            }
            .navigationTitle("New share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .sheet(item: $shareImage) { item in
            Group {
                SocialActivitySheet(images: item.images)
            }
            .zoSheet()
        }
        .alert("Couldn’t create the image", isPresented: $imageFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your workout and selections are still here. Try sharing again.")
        }
    }

    private var stepTrack: some View {
        HStack(spacing: ZOSpace.s) {
            stepLabel("Choose", selected: step == .choose)
            stepLabel("Preview", selected: step == .preview)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step == .choose ? "Step 1 of 2, Choose" : "Step 2 of 2, Preview")
    }

    private func stepLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .zoText(.section)
            .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                selected ? theme.surfaceSecondary : theme.surfacePrimary,
                in: RoundedRectangle(cornerRadius: ZORadius.control)
            )
    }

    private var chooseContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            Text("From \(workout.title) · \(workout.completedAt.formatted(.dateTime.day().month().year()))")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("EXERCISES AND SAVED SETS")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                ForEach((workout.exercises ?? []).filter { !$0.completedSets.isEmpty }) { exercise in
                    SocialExerciseChoiceRow(
                        exercise: exercise,
                        selectedSetIDs: draft.selectedSetIDs,
                        onToggleExercise: { draft.toggleExercise(exercise) },
                        onToggleSet: { draft.toggleSet($0) }
                    )
                }
            }
            ZOSegmentedControl("Card colour", selection: $cardStyle, options: SocialShareCardStyle.allCases.map { style in ZOSegment(value: style, label: Text(style.rawValue)) })
            Text("One exercise per card. All selected sets are included; additional cards keep longer notes readable.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("SHOW LOADS")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                ZOSegmentedControl("Show loads", selection: $draft.visibility, options: SocialLoadVisibility.allCases.map { option in ZOSegment(value: option, label: Text(option.rawValue)) })
                Text("Exact load shows kg or lb. Change only shows a comparison, not your full load.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            Toggle("Show comparison with last time", isOn: $draft.showComparison)
            Toggle("Show a verified personal record", isOn: $draft.showPR)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("HEADLINE")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                TextField("Use the suggested headline", text: $draft.headlineOverride, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .padding(ZOSpace.m)
                    .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.control))
                Text("Leave blank for a headline made from the selected saved sets.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("YOUR NOTE")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                TextField("Optional note", text: $draft.note, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .padding(ZOSpace.m)
                    .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.control))
            }
            if draft.warnsAboutTypedLoad {
                Label(
                    "Your own headline or note names a load. People receiving the image may see it even with loads hidden.",
                    systemImage: "exclamationmark.triangle"
                )
                .zoText(.body).labelStyle(ZOIconLabelStyle())
                .foregroundStyle(theme.warningPrimary)
                if !draft.headlineOverride.isEmpty {
                    Button("Use suggested headline") { draft.headlineOverride = "" }
                        .frame(minHeight: 44)
                }
                if !draft.note.isEmpty {
                    Button("Clear note") { draft.note = "" }
                        .frame(minHeight: 44)
                }
            }
        }
        .tint(theme.accentForeground)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Exactly what the image will show")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if let images = renderedShareCards() {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    if images.count > 1 {
                        Text("Card \(index + 1) of \(images.count)")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(sharePages[index].accessibilityDescription(visibility: draft.visibility))
                }
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_SOCIAL_STATE"] == "preview" {
                        exportReviewShareCards(images)
                        Logger(subsystem: "app.the01.ios", category: "Launch")
                            .notice("Review social share image rendered")
                    }
                    #endif
                }
            } else {
                Text("The share image could not be rendered. Your choices are kept; try again before sharing.")
                    .foregroundStyle(theme.warningPrimary)
            }
            if draft.warnsAboutTypedLoad {
                Label("Your typed words include a load, even though the load setting hides it.", systemImage: "exclamationmark.triangle")
                    .zoText(.body).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(theme.warningPrimary)
            }
            Button("Edit choices") { step = .choose }
                .zoText(.section)
                .frame(minHeight: 44)
            Text("This opens the system share sheet. Nothing is posted inside 01.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var bottomAction: some View {
        VStack(spacing: ZOSpace.xs) {
            Button {
                if step == .choose {
                    step = .preview
                } else {
                    sharePreviewImage()
                }
            } label: {
                Text(step == .choose ? "Preview" : "Share image")
                    .zoText(.section)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color.black)
                    .background(theme.accentFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!draft.canPreview)
            .opacity(draft.canPreview ? 1 : 0.5)
            Text(step == .choose
                 ? "No image is shared until you review it and choose Share image."
                 : "You choose the destination in the system share sheet.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var sharePages: [SocialShareCardPage] {
        SocialShareCardPage.make(
            preview: draft.preview(history: history),
            headlineOverride: draft.headlineOverride
        )
    }

    @MainActor
    private func renderedShareCards() -> [UIImage]? {
        let pages = sharePages
        guard !pages.isEmpty else { return nil }
        var images: [UIImage] = []
        for page in pages {
            let renderer = ImageRenderer(
                content: SocialShareCard(
                    page: page, completedAt: workout.completedAt,
                    visibility: draft.visibility, style: cardStyle
                )
                .environment(\.dynamicTypeSize, .medium)
            )
            renderer.scale = 3
            guard let image = renderer.uiImage else { return nil }
            images.append(image)
        }
        return images
    }

    @MainActor
    private func sharePreviewImage() {
        guard let images = renderedShareCards() else {
            imageFailed = true
            return
        }
        shareImage = SocialShareImage(images: images)
    }

    #if DEBUG
    private func exportReviewShareCards(_ images: [UIImage]) {
        guard ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_HISTORY_STATE"] == "completed" else { return }
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("ReviewShareCards", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: directory.appendingPathComponent("card-\(index + 1).png"), options: .atomic)
            }
        } catch {
            Logger(subsystem: "app.the01.ios", category: "Launch")
                .error("Review social share export failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}

private struct SocialExerciseChoiceRow: View {
    let exercise: WorkoutHistoryExercise
    let selectedSetIDs: Set<UUID>
    let onToggleExercise: () -> Void
    let onToggleSet: (UUID) -> Void

    @Environment(\.zeroOneTheme) private var theme

    private var name: String {
        ExerciseLibrary.exercise(id: exercise.exerciseID)?.name
            ?? MoveKitExercise.all.first(where: {
                MoveKitExerciseCatalog.workoutExerciseID(for: $0.id) == exercise.exerciseID
            })?.name
            ?? exercise.exerciseID.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Button(action: onToggleExercise) {
                HStack {
                    Image(systemName: exercise.completedSets.allSatisfy {
                        selectedSetIDs.contains($0.id)
                    } ? "checkmark.square.fill" : "square")
                        .foregroundStyle(theme.accentForeground)
                        .accessibilityHidden(true)
                    Text(name)
                        .zoText(.section)
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(exercise.completedSets.count) sets")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include \(name)")
            .accessibilityValue(
                exercise.completedSets.allSatisfy { selectedSetIDs.contains($0.id) }
                    ? "All sets selected" : "Not all sets selected"
            )
            ScrollView(.horizontal) {
                HStack(spacing: ZOSpace.s) {
                    ForEach(Array(exercise.completedSets.enumerated()), id: \.element.id) { index, set in
                        Button { onToggleSet(set.id) } label: {
                            Text("S\(index + 1) · \(set.performanceText)")
                                .zoText(.section)
                                .foregroundStyle(selectedSetIDs.contains(set.id)
                                    ? theme.backgroundPrimary : theme.textPrimary)
                                .padding(.horizontal, ZOSpace.m)
                                .frame(minHeight: 44)
                                .background(
                                    selectedSetIDs.contains(set.id)
                                        ? theme.textPrimary : theme.surfaceSecondary,
                                    in: RoundedRectangle(cornerRadius: ZORadius.control)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Set \(index + 1), \(set.performanceText)")
                        .accessibilityAddTraits(selectedSetIDs.contains(set.id) ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(ZOSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
    }
}

enum SocialShareCardStyle: String, CaseIterable, Identifiable {
    case warm = "Warm"
    case carbon = "Carbon"
    case signal = "Signal"
    case pink = "Pink"
    var id: Self { self }

    var canvas: Color {
        switch self {
        case .warm: Color(red: 247/255, green: 246/255, blue: 241/255)
        case .carbon: Color(red: 36/255, green: 36/255, blue: 34/255)
        case .signal: Color(red: 255/255, green: 254/255, blue: 42/255)
        case .pink: AccentPreference.pink.fill
        }
    }
    var ink: Color {
        self == .carbon ? Color(red: 247/255, green: 246/255, blue: 241/255)
            : Color(red: 2/255, green: 2/255, blue: 2/255)
    }
    var secondary: Color {
        switch self {
        case .carbon: Color(red: 181/255, green: 179/255, blue: 170/255)
        case .signal: Color(red: 58/255, green: 58/255, blue: 42/255)
        case .warm: Color(red: 87/255, green: 85/255, blue: 78/255)
        case .pink: Color(red: 2/255, green: 2/255, blue: 2/255)
        }
    }
}

/// Fixed-size outside-share pages. Preserve every selected saved set and all typed
/// text; overflow becomes another card, never a clipped or silently omitted record.
struct SocialShareCardPage {
    let block: SocialShareBlock?
    let chips: [String]
    let text: String?

    static func make(preview: SocialSharePreview, headlineOverride: String) -> [Self] {
        var pages: [Self] = []
        for (blockIndex, block) in preview.blocks.enumerated() {
            let firstPageIndex = pages.count
            var start = 0
            while start < block.sets.count {
                var count = min(8, block.sets.count - start)
                while count > 1 && exerciseHeight(
                    name: block.name, sets: Array(block.sets[start..<start + count]),
                    visibility: preview.visibility
                ) > 330 { count -= 1 }
                let sets = Array(block.sets[start..<start + count])
                let fitsName = exerciseHeight(name: block.name, sets: sets, visibility: preview.visibility) <= 330
                pages.append(Self(
                    block: SocialShareBlock(
                        id: block.id, exerciseID: block.exerciseID,
                        name: fitsName ? block.name : "Saved exercise", sets: sets
                    ), chips: [], text: nil
                ))
                if !fitsName {
                    pages += textPages(block.name).map { Self(block: nil, chips: [], text: $0) }
                }
                start += count
            }
            if blockIndex == 0 && !preview.chips.isEmpty {
                let evidence = "\(block.name) · \(block.sets.count) selected saved sets\n\n" + preview.chips.joined(separator: "\n")
                // A chip describes the complete selected occurrence, not an arbitrary
                // chunk. Keep its scope explicit when the evidence spans cards.
                if pages.count == firstPageIndex + 1,
                   let first = pages[firstPageIndex].block,
                   exerciseHeight(name: first.name, sets: first.sets, visibility: preview.visibility)
                    + measuredHeight(preview.chips.joined(separator: " · "), size: 17.55, bold: true) + 13 <= 330 {
                    pages[firstPageIndex] = Self(block: first, chips: preview.chips, text: nil)
                } else {
                    pages += textPages(evidence).map { Self(block: nil, chips: [], text: $0) }
                }
            }
        }
        let headline = headlineOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = [headline, preview.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        pages += textPages(words).map { Self(block: nil, chips: [], text: $0) }
        return pages
    }

    private static func measuredHeight(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        let font = SocialSharePrintTypography.uiFont(size: size, weight: bold ? 700 : 500)
        return ceil((text as NSString).boundingRect(
            with: CGSize(width: 311, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        ).height)
    }

    private static func exerciseHeight(name: String, sets: [CompletedSet], visibility: SocialLoadVisibility) -> CGFloat {
        let summary = sets.map { SocialShareDraft.setText($0, visibility: visibility) }.joined(separator: " · ")
        // Metric + name/bar/summary spacing + rep plot and labels. The 330pt
        // budget leaves header, outer padding and breathing room on a 450pt card.
        return 60 + 38 + 94 + measuredHeight(name, size: 24.41, bold: true)
            + measuredHeight(summary, size: 17.55)
    }

    private static func textPages(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let font = SocialSharePrintTypography.uiFont(size: 24, weight: 500)
        let characters = Array(text)
        var start = 0
        var pages: [String] = []
        while start < characters.count {
            var lower = 1
            var upper = characters.count - start
            var fit = 1
            while lower <= upper {
                let count = (lower + upper) / 2
                let candidate = String(characters[start..<start + count])
                let bounds = (candidate as NSString).boundingRect(
                    with: CGSize(width: 311, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil
                )
                if bounds.height <= 300 { fit = count; lower = count + 1 }
                else { upper = count - 1 }
            }
            // Prefer a word boundary, but always advance through an unbroken word.
            if start + fit < characters.count,
               let boundary = characters[start..<start + fit].lastIndex(where: { $0.isWhitespace }),
               boundary > start {
                fit = boundary - start + 1
            }
            pages.append(String(characters[start..<start + fit]))
            start += fit
        }
        return pages
    }

    func accessibilityDescription(visibility: SocialLoadVisibility) -> String {
        if let block {
            return ([block.name] + block.sets.map { SocialShareDraft.setText($0, visibility: visibility) } + chips)
                .joined(separator: ". ")
        }
        return text ?? ""
    }
}

/// Fixed print typography shared by the retained card and its page measurements.
/// Resolve the exact variable resource through the existing validated font API;
/// app theme and Dynamic Type do not change this approved print object.
enum SocialSharePrintTypography {
    static func font(size: CGFloat, weight: CGFloat) -> CTFont {
        var spec = ZOThemeTypography.spec(for: .core, role: .label)
        spec.size = size; spec.weight = weight; spec.width = 100
        do {
            // Print sizes are fixed. iOS 26 snaps UIFontMetrics output to a third of a point.
            let font = try spec.font(for: .large)
            return CTFontGetSize(font) == size ? font : CTFontCreateCopyWithAttributes(font, size, nil, nil)
        }
        catch {
            assertionFailure("The approved Instrument Sans variable print font is unavailable: \(error)")
            return CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
    }

    static func uiFont(size: CGFloat, weight: CGFloat) -> UIFont {
        font(size: size, weight: weight) as UIFont
    }
}

/// Claude Study 24 vShare / retained Study 23 tcard: 236 × 295 CSS
/// scaled to 360 × 450 pt. Card colour is independent of app appearance.
struct SocialShareCard: View {
    let page: SocialShareCardPage
    let completedAt: Date
    let visibility: SocialLoadVisibility
    let style: SocialShareCardStyle
    private let unit: CGFloat = 360 / 236

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image("ZeroOneWordmark")
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 22 * unit, height: 22 * unit)
                    .accessibilityHidden(true)
                Spacer()
                Text(completedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                    .font(Font(SocialSharePrintTypography.font(size: 10.5 * unit, weight: 700)))
                    .tracking(0.84 * unit)
                    .foregroundStyle(style.secondary)
            }
            Spacer(minLength: 12)
            if let block = page.block, let first = block.sets.first {
                Text(visibility == .exact && first.load.value > 0
                     ? "\(first.load.value.formatted()) × \(first.reps)"
                     : "\(first.reps) reps")
                    .font(Font(SocialSharePrintTypography.font(size: 30 * unit, weight: 700)))
                    .tracking(-1.35 * unit)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(block.name)
                    .font(Font(SocialSharePrintTypography.font(size: 16 * unit, weight: 700)))
                    .tracking(-0.24 * unit)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8 * unit)
                SocialRepColumns(sets: block.sets, ink: style.ink, secondary: style.secondary, unit: unit)
                    .padding(.top, 10 * unit)
                Text(block.sets.map { SocialShareDraft.setText($0, visibility: visibility) }.joined(separator: " · "))
                    .font(Font(SocialSharePrintTypography.font(size: 11.5 * unit, weight: 500)))
                    .foregroundStyle(style.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6 * unit)
                if !page.chips.isEmpty {
                    Text(page.chips.joined(separator: " · "))
                        .font(Font(SocialSharePrintTypography.font(size: 11.5 * unit, weight: 600)))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8 * unit)
                }
            } else if let text = page.text {
                Text(text)
                    .font(Font(SocialSharePrintTypography.font(size: 24, weight: 500)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(style.ink)
        .padding(.horizontal, 16 * unit)
        .padding(.top, 16 * unit)
        .padding(.bottom, 14 * unit)
        .frame(width: 360, height: 450, alignment: .topLeading)
        .background(style.canvas, in: RoundedRectangle(cornerRadius: 18 * unit))
    }
}

private struct SocialRepColumns: View {
    let sets: [CompletedSet]
    let ink: Color
    let secondary: Color
    let unit: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: 5 * unit) {
            ForEach(sets) { set in
                VStack(spacing: 3 * unit) {
                  if !sets.contains(where: \.isTimed) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3 * unit)
                            .fill(ink)
                            .frame(height: CGFloat(set.durationSeconds ?? set.reps) / CGFloat(max(1, sets.map { $0.durationSeconds ?? $0.reps }.max() ?? 1)) * 44 * unit)
                    }
                    .frame(width: 14 * unit, height: 44 * unit, alignment: .bottom)
                  }
                    Text(set.durationSeconds.map { "\($0)s" } ?? String(set.reps))
                        .font(Font(SocialSharePrintTypography.font(size: 11 * unit, weight: 700)))
                        .foregroundStyle(secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved sets: \(sets.map(\.performanceText).joined(separator: ", "))")
        // Historical saved sets do not retain a target range. Never invent a band
        // or a 'top of range' claim from the person's current programme.
    }
}

private struct SocialActivitySheet: UIViewControllerRepresentable {
    let images: [UIImage]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: images, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ZeroOneDestinationStateView: View {
    let destination: AppTab
    let state: ZeroOneDestinationState
    let onShowInitial: () -> Void

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.xl) {
                    Spacer(minLength: max(44, proxy.size.height * 0.14))

                    Image(systemName: symbol)
                        .zoIcon(ZOIcon.row)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 54, height: 54)
                        .zeroOneMaterialSurface(.rounded(27))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        Text(destination.title.uppercased())
                            .zoText(.caption)

                            .foregroundStyle(theme.textSecondary)

                        Text(title)
                            .zoText(.display)
                            .foregroundStyle(theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        Text(message)
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Show initial state", action: onShowInitial)
                        .buttonStyle(ZOButtonStyle(.secondary))
                        .accessibilityHint("Returns " + destination.title + " to its initial local state.")

                    Spacer(minLength: ZOSpace.x4)
                }
                .frame(maxWidth: 560, minHeight: proxy.size.height, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.backgroundPrimary.ignoresSafeArea())
    }

    private var symbol: String {
        state == .empty ? "circle.dashed" : "wifi.slash"
    }

    private var title: String {
        switch state {
        case .initial: "Ready."
        case .empty: "Nothing here yet."
        case .unavailable: "Not available right now."
        }
    }

    private var message: String {
        switch state {
        case .initial:
            "This destination is ready to use."
        case .empty:
            "Your " + destination.title.lowercased() + " activity will appear here when there is something useful to show."
        case .unavailable:
            "01 keeps essential workout actions local. This destination can recover without interrupting your session."
        }
    }
}

struct ProfileAccountView: View {
    @Binding var selectedAppearance: AppearancePreference
    @Bindable var demoState: ZeroOneDemoStateModel
    @Bindable var userProfile: ZeroOneUserProfileRepository
    @Bindable var healthConnection: HealthConnectionRepository
    @Bindable var progressPhotos: ProgressPhotoRepository
    let bodyWeight: BodyWeightRepository
    let customWorkouts: CustomWorkoutRepository
    let smartNotes: SmartNoteCenter
    let membership: StoreKitMembershipStore
    let session: WorkoutSession
    let historyState: WorkoutHistorySurfaceState
    let loadChoices: WorkoutLoadChoiceRepository
    let makeLocalDataJSON: @MainActor (LocalDataExportSelection) async throws -> Data
    let widgetInputs: DailyWidgetInputs?
    let dailyGoals: DailyGoalsRepository?
    let hydration: HydrationViewModel?
    let workoutAppointments: WorkoutAppointmentRepository?
    let appointmentCalendar: AppointmentCalendarCoordinator?
    let programmes: [WorkoutProgramme]
    let onOpenScheduledWorkout: ((ScheduledWorkoutReference, UUID) -> Void)?
    let workoutHistoryImport: WorkoutHistoryImportCoordinator?
    let onImportedWorkoutHistory: (@MainActor ([WorkoutHistoryEntry]) throws -> Void)?
    let mealRecordImport: FoodBodyWeightImportCoordinator?
    let bodyWeightRecordImport: FoodBodyWeightImportCoordinator?
    let outdoorHistoryTransfer: OutdoorHistoryTransferCoordinator?
    let initialDestination: ProfileDestination?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneRootShareCoordinator) private var rootShareCoordinator
    @Environment(\.photoComparisonShareHostAuthority) private var photoShareAuthority
    @Environment(\.zeroOneTheme) private var theme
    @State private var path: NavigationPath
    @Environment(\.zeroOneLocalization) private var localization
    @State private var searchText = ""
    @Environment(ZeroOneAccountStore.self) private var account
    @State private var deletionIdentity: ZeroOneAccountIdentity?
    @State private var showingDeleteAccount = false
    @State private var signOutIdentity: ZeroOneAccountIdentity?
    @State private var showingSignOut = false
    @State private var accountWarning: String?
    @AppStorage(DesignThemePreference.storageKey) private var selectedThemeRawValue = DesignThemePreference.core.rawValue
    // Read-only observation of the existing BodyWeightScreen preference, no new key.
    @AppStorage("slick.bodyWeightUnit") private var youWeightUnitRawValue = BodyWeightUnit.kilograms.rawValue
    @Environment(\.calendar) private var youCalendar
    @Environment(\.openURL) private var youOpenURL

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        selectedAppearance: Binding<AppearancePreference>,
        demoState: ZeroOneDemoStateModel,
        userProfile: ZeroOneUserProfileRepository,
        healthConnection: HealthConnectionRepository,
        progressPhotos: ProgressPhotoRepository,
        bodyWeight: BodyWeightRepository,
        customWorkouts: CustomWorkoutRepository,
        smartNotes: SmartNoteCenter,
        membership: StoreKitMembershipStore,
        session: WorkoutSession,
        historyState: WorkoutHistorySurfaceState,
        loadChoices: WorkoutLoadChoiceRepository,
        makeLocalDataJSON: @escaping @MainActor (LocalDataExportSelection) async throws -> Data,
        widgetInputs: DailyWidgetInputs? = nil,
        dailyGoals: DailyGoalsRepository? = nil,
        hydration: HydrationViewModel? = nil,
        workoutAppointments: WorkoutAppointmentRepository? = nil,
        appointmentCalendar: AppointmentCalendarCoordinator? = nil,
        programmes: [WorkoutProgramme] = [],
        onOpenScheduledWorkout: ((ScheduledWorkoutReference, UUID) -> Void)? = nil,
        workoutHistoryImport: WorkoutHistoryImportCoordinator? = nil,
        onImportedWorkoutHistory: (@MainActor ([WorkoutHistoryEntry]) throws -> Void)? = nil,
        mealRecordImport: FoodBodyWeightImportCoordinator? = nil,
        bodyWeightRecordImport: FoodBodyWeightImportCoordinator? = nil,
        outdoorHistoryTransfer: OutdoorHistoryTransferCoordinator? = nil,
        initialDestination: ProfileDestination? = nil
    ) {
        _selectedAppearance = selectedAppearance
        self.demoState = demoState
        self.userProfile = userProfile
        self.healthConnection = healthConnection
        self.progressPhotos = progressPhotos
        self.bodyWeight = bodyWeight
        self.customWorkouts = customWorkouts
        self.smartNotes = smartNotes
        self.membership = membership
        self.session = session
        self.historyState = historyState
        self.loadChoices = loadChoices
        self.makeLocalDataJSON = makeLocalDataJSON
        self.widgetInputs = widgetInputs
        self.dailyGoals = dailyGoals
        self.hydration = hydration
        self.workoutAppointments = workoutAppointments
        self.appointmentCalendar = appointmentCalendar
        self.programmes = programmes
        self.onOpenScheduledWorkout = onOpenScheduledWorkout
        self.workoutHistoryImport = workoutHistoryImport
        self.onImportedWorkoutHistory = onImportedWorkoutHistory
        self.mealRecordImport = mealRecordImport
        self.bodyWeightRecordImport = bodyWeightRecordImport
        self.outdoorHistoryTransfer = outdoorHistoryTransfer
        self.initialDestination = initialDestination
        _path = State(initialValue: NavigationPath(initialDestination.map { [$0] } ?? []))
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { path },
            set: { nextPath in
                rootShareCoordinator?.revokeBeforeRouteChange()
                photoShareAuthority?.revokeAll(before: .route)
                path = nextPath
            }
        )) {
            ProfileSettingsYouHubView(snapshot: youSnapshot, actions: youActions, membershipAccess: membership.access)
                .navigationDestination(for: ProfileSettingsYouHostDestination.self) { destination in
                    switch destination {
                    case .settings: settingsContent
                    }
                }
            .navigationDestination(for: ProfileDestination.self) { destination in
                switch destination {
                case .history:
                    WorkoutHistoryView(state: historyState)
                case let .session(id):
                    if case let .entries(entries) = historyState,
                       let entry = entries.first(where: { $0.id == id }) {
                        WorkoutHistoryDetailView(entry: entry)
                    } else {
                        ContentUnavailableView("Session unavailable", systemImage: "clock.arrow.circlepath")
                    }
                case .baseline:
                    ZeroOneOnboardingView(profileRepository: userProfile, mode: .editing,
                        customWorkoutRepository: customWorkouts, bodyWeightRepository: bodyWeight)
                case .personalDetails:
                    ProfilePersonalDetailsView(profileRepository: userProfile)
                case .account:
                    ZeroOneLoginView()
                case .unitsAndLanguage:
                    ProfileUnitsView(profileRepository: userProfile)
                case .notifications:
                    SmartNotificationsView(notes: smartNotes)
                case .schedule:
                    if let workoutAppointments, let appointmentCalendar, let onOpenScheduledWorkout {
                        WorkoutScheduleView(repository: workoutAppointments, calendarCoordinator: appointmentCalendar,
                            programmes: programmes, customWorkouts: customWorkouts.workouts,
                            onOpenWorkout: onOpenScheduledWorkout)
                    }
                case .widgets:
                    ProfileWidgetsView(inputs: widgetInputs, goals: dailyGoals, hydration: hydration)
                case .membership:
                    MembershipFeatureView(store: membership)
                case .bodyWeight:
                    BodyWeightScreen(repository: bodyWeight)
                case .progress:
                    ProgressScreen(
                        session: session,
                        historyState: historyState,
                        bodyWeight: bodyWeight,
                        loadChoices: loadChoices,
                        progressPhotos: progressPhotos,
                        healthConnection: healthConnection
                    )
                case .settings:
                    SettingsScreen(selectedAppearance: $selectedAppearance)
                case .localData:
                    ProfileLocalDataView(makeLocalDataJSON: makeLocalDataJSON,
                        workoutHistoryImport: workoutHistoryImport,
                        onImportedWorkoutHistory: onImportedWorkoutHistory,
                        mealRecordImport: mealRecordImport,
                        bodyWeightRecordImport: bodyWeightRecordImport,
                        outdoorHistoryTransfer: outdoorHistoryTransfer)
                case .appleHealth:
                    AppleHealthConnectionView(healthConnection: healthConnection)
                case .progressPhotos:
                    ProgressPhotosView(repository: progressPhotos)
                }
            }
        }
        .sheet(isPresented: $showingDeleteAccount, onDismiss: { deletionIdentity = nil }) {
            if let deletionIdentity {
                ProfileSettingsDeleteAccountView(identity: deletionIdentity) { warning in
                    accountWarning = warning
                }
            }
        }
        .confirmationDialog("Sign out of 01?", isPresented: $showingSignOut, titleVisibility: .visible) {
            Button("Sign out") {
                Task { @MainActor in
                    guard let signOutIdentity, account.identity == signOutIdentity,
                          !account.isBusy else { return }
                    photoShareAuthority?.revokeAll(before: .account)
                    await account.signOut()
                    accountWarning = account.errorMessage
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your workouts and other data stay on this iPhone.")
        }
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .toolbarBackground(theme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var youSnapshot: ProfileSettingsYouSnapshot {
        ProfileSettingsYouHostPresentation.snapshot(
            asOf: .now, calendar: youCalendar,
            displayName: userProfile.profile.displayName, profileAvailable: userProfile.isAvailable,
            historyState: historyState,
            bodyWeightEntries: bodyWeight.isAvailable ? bodyWeight.entries : nil,
            bodyWeightUnitRawValue: youWeightUnitRawValue, themeRawValue: selectedThemeRawValue)
    }

    @MainActor private var youActions: ProfileSettingsYouActions {
        let expectedIdentity = account.identity
        let capabilities = ProfileSettingsYouHostPresentation.capabilities(
            profileAvailable: userProfile.isAvailable, weightAvailable: bodyWeight.isAvailable,
            photoAvailable: progressPhotos.isAvailable, accountBusy: account.isBusy)
        var actions = ProfileSettingsYouActions()
        if capabilities.personalDetails {
            actions.personalDetails = {
                guard account.identity == expectedIdentity, !account.isBusy, userProfile.isAvailable else { return }
                rootShareCoordinator?.revokeBeforeRouteChange()
                photoShareAuthority?.revokeAll(before: .route)
                path.append(ProfileDestination.personalDetails)
            }
        }
        if capabilities.bodyWeight {
            actions.bodyWeight = {
                guard account.identity == expectedIdentity, !account.isBusy, bodyWeight.isAvailable else { return }
                rootShareCoordinator?.revokeBeforeRouteChange()
                photoShareAuthority?.revokeAll(before: .route)
                path.append(ProfileDestination.bodyWeight)
            }
        }
        if capabilities.photo {
            actions.photo = {
                guard account.identity == expectedIdentity, !account.isBusy, progressPhotos.isAvailable else { return }
                rootShareCoordinator?.revokeBeforeRouteChange()
                photoShareAuthority?.revokeAll(before: .route)
                path.append(ProfileDestination.progressPhotos)
            }
        }
        actions.settings = {
            guard account.identity == expectedIdentity else { return }
            rootShareCoordinator?.revokeBeforeRouteChange()
            photoShareAuthority?.revokeAll(before: .route)
            path.append(ProfileSettingsYouHostDestination.settings)
        }
        actions.writeToSammy = {
            guard account.identity == expectedIdentity else { return }
            youOpenURL(ProfileSettingsHelpLink.founder.url)
        }
        // No actual member-card authority or edition preference capability is injected.
        // Week code, Share, card allocation and edition persistence stay unavailable.
        return actions
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProfilePersistenceNotice(repository: userProfile)
                if !isSearching { profileAccountHeader }
                ForEach(visibleGroups) { group in profileGroup(group) }
                if isSearching && matchingEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
                if !isSearching {
                    if let message = accountWarning ?? account.errorMessage {
                        Text(verbatim: localization.string(message))
                            .zoText(.caption)
                            .foregroundStyle(theme.destructivePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                            .padding(.top, ZOSpace.l)
                    }
                    if let identity = account.identity {
                        VStack(spacing: 0) {
                            Button("Sign out") {
                                photoShareAuthority?.revokeAll(before: .account)
                                accountWarning = nil
                                signOutIdentity = identity
                                showingSignOut = true
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .disabled(account.isBusy)
                            Divider().overlay(theme.strokeSubtle)
                            Button("Delete account", role: .destructive) {
                                photoShareAuthority?.revokeAll(before: .account)
                                accountWarning = nil
                                deletionIdentity = identity
                                showingDeleteAccount = true
                            }
                            .foregroundStyle(theme.destructivePrimary)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .disabled(account.isBusy)
                        }
                        .zoText(.section)
                        .buttonStyle(.plain)
                        .padding(.horizontal, ZOSpace.l)
                        .background(theme.surfacePrimary, in: .rect(cornerRadius: ZORadius.card))
                        .padding(.top, ZOSpace.xl)
                    }
                    VStack(spacing: ZOSpace.xs) {
                        Text("Workouts log offline.")
                        if let version = ProfileSettingsPresentation.version(
                            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
                            Text(verbatim: "01 " + version)
                        }
                    }
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, ZOSpace.m)
                    #if DEBUG
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text("Local demo state").zoText(.caption)
                        ForEach(AppTab.allCases, id: \.self) { destination in
                            Picker(destination.title, selection: stateBinding(for: destination)) {
                                ForEach(ZeroOneDestinationState.allCases) { state in
                                    Text(state.title).tag(state)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityLabel(destination.title + " demo state")
                        }
                        Text("Review states are stored locally and never affect workout history.")
                            .zoText(.caption)
                    }
                    .padding(.top, ZOSpace.l)
                    #endif
                }
            }
            .padding(.horizontal, ZOSpace.l)
            .padding(.top, ZOSpace.xs)
            .padding(.bottom, ZOSpace.xl)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    rootShareCoordinator?.revokeBeforeRouteChange()
                    photoShareAuthority?.revokeAll(before: .hostDismissal)
                    dismiss()
                }
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityHint("Closes Settings.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundPrimary)
        .searchable(text: $searchText, prompt: "Search settings")
    }

    private func stateBinding(for destination: AppTab) -> Binding<ZeroOneDestinationState> {
        Binding(
            get: { demoState.state(for: destination) },
            set: { demoState.set($0, for: destination) }
        )
    }

    private func profileGroup(_ group: ProfileGroup) -> some View {
        let entries = visibleEntries(in: group)
        return VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(verbatim: localization.string(group.title))
                .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, ZOSpace.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    entryLink(entry)
                    if entry.id != entries.last?.id { Divider().overlay(theme.strokeSubtle) }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, ZOSpace.l)
            .background(theme.surfacePrimary, in: .rect(cornerRadius: ZORadius.card))
        }
        .padding(.top, 22)
    }

    private var profileAccountHeader: some View {
        NavigationLink(value: ProfileDestination.account) {
            HStack(spacing: ZOSpace.m) {
                profileAvatar
                profileHeading
                Image(systemName: "chevron.right")
                    .zoIcon(16)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 56)
        .padding(.horizontal, ZOSpace.l)
        .padding(.vertical, ZOSpace.s)
        .buttonStyle(.plain)
        .background(theme.surfacePrimary, in: .rect(cornerRadius: ZORadius.card))
    }

    private var profileAvatar: some View {
        let tone = userProfile.profile.initialsTone ?? .onyx
        return Text(profileInitial)
            .zoText(.section)
            .foregroundStyle(tone.foreground(in: theme))
            .frame(width: 40, height: 40)
            .background(tone.background(in: theme), in: Circle())
            .accessibilityHidden(true)
    }

    private var profileHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: userProfile.profile.displayName ?? localization.string("Your 01"))
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: localization.string(ProfileSettingsPresentation.accountStatus(
                hasIdentity: account.identity != nil, needsVerification: account.needsVerification)))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthStatusTitle: String {
        switch healthConnection.status {
        case .notConnected: "Not set up"
        case .connecting: "Connecting"
        case .connected: "Setup complete"
        case .unavailable: "Unavailable"
        }
    }

    private var profileInitial: String {
        guard let first = userProfile.profile.displayName?.first else { return "01" }
        return String(first).uppercased()
    }

    private func profileRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: ZOSpace.m) {
            Image(systemName: symbol)
                .zoIcon(16)
                .frame(width: 32, height: 32)
                .background(theme.surfaceSecondary, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).zoText(.section)
                Text(verbatim: detail)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.vertical, ZOSpace.s)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var baselineSummary: String {
        let goal = userProfile.profile.selectedTrainingGoals.isEmpty ? localization.string("Set your training baseline")
            : userProfile.profile.selectedTrainingGoals.map { localization.string($0.title) }.joined(separator: ", ")
        guard let days = userProfile.profile.preferredTrainingDays, !days.isEmpty else { return goal }
        let daysSummary = localization.format(days.count == 1 ? "%1$lld training day" : "%1$lld training days", .integer(days.count))
        return "\(goal) · \(daysSummary)"
    }

    private func displayDetail(for entry: ProfileEntry) -> String {
        // User names and assembled baseline facts are not localization keys.
        if entry.destination == .personalDetails, userProfile.profile.displayName != nil { return entry.detail }
        if entry.destination == .baseline { return entry.detail }
        return localization.string(entry.detail)
    }

    private var allEntries: [ProfileEntry] {
        [
            .init(id: .account, group: .you, title: "Account & sign in",
                  detail: ProfileSettingsPresentation.accountStatus(hasIdentity: account.identity != nil, needsVerification: account.needsVerification),
                  symbol: "person.crop.circle", keywords: "account login sign in email apple"),
            .init(id: .personalDetails, group: .you, title: "Personal details",
                  detail: userProfile.profile.displayName ?? "Name optional",
                  symbol: "person", keywords: "name profile personal"),
            .init(id: .unitsAndLanguage, group: .you, title: "Units & language",
                  detail: "\((userProfile.profile.preferredWeightUnit ?? ZeroOneOnboardingUnitDefaults.weight()).rawValue) · \((userProfile.profile.preferredDistanceUnit ?? ZeroOneOnboardingUnitDefaults.distance()).rawValue)",
                  symbol: "ruler", keywords: "units weight distance language"),
            .init(id: .membership, group: .you, title: "Membership",
                  detail: ProfileSettingsPresentation.membershipStatus(isBeta: membership.configuration.isBeta,
                      access: membership.access), symbol: "star",
                  keywords: "subscription membership billing trial"),
            .init(id: .baseline, group: .you, title: "Goals & training",
                  detail: baselineSummary,
                  symbol: "target", keywords: "goal experience equipment days"),
            .init(id: .bodyWeight, group: .you, title: "Body weight",
                  detail: "Optional private readings", symbol: "scalemass", keywords: "weight readings"),
            .init(id: .schedule, group: .you, title: "Workout schedule",
                  detail: "Appointments and optional Calendar copies", symbol: "calendar",
                  keywords: "appointment schedule calendar workout planning"),
            .init(id: .notifications, group: .howItWorks, title: "Notifications",
                  detail: "Optional workout reminders", symbol: "bell",
                  keywords: "notes notifications reminder quiet hours"),
            .init(route: .coach, group: .howItWorks, title: "Coach voice",
                  detail: "Say it in my AirPods", symbol: "headphones",
                  keywords: "coach voice airpods headphones speak spoken audio"),
            .init(id: .settings, group: .howItWorks, title: "Appearance and themes",
                  detail: "Light, dark or system", symbol: "paintpalette", keywords: "theme settings"),
            .init(route: .theme, group: .howItWorks, title: "Theme",
                  detail: DesignThemePreference.storedValue(selectedThemeRawValue).title,
                  symbol: "sparkles", keywords: "theme retro freak princess appearance"),
            .init(id: .appleHealth, group: .howItWorks, title: "Apple Health",
                  detail: healthStatusTitle, symbol: "heart", keywords: "health permission steps"),
            .init(id: .widgets, group: .howItWorks, title: "Widgets",
                  detail: "Steps, calories and water at a glance", symbol: "square.grid.2x2",
                  keywords: "home screen water steps calories widgets"),
            .init(id: .localData, group: .data, title: "Your data",
                  detail: "Local storage and moving devices", symbol: "iphone",
                  keywords: "backup sync icloud restore transfer privacy"),
            .init(route: .export, group: .data, title: "Export", detail: "Choose records to export",
                  symbol: "square.and.arrow.up", keywords: "export backup json zip files"),
            .init(route: .importData, group: .data, title: "Import", detail: "Review before anything changes",
                  symbol: "square.and.arrow.down", keywords: "import restore transfer json"),
            .init(id: .history, group: .data, title: "Workout history",
                  detail: "Every recorded set", symbol: "dumbbell", keywords: "sessions training logs"),
            .init(id: .progress, group: .data, title: "Progress",
                  detail: "Your training over time", symbol: "chart.bar", keywords: "training charts"),
            .init(id: .progressPhotos, group: .data, title: "Progress photos",
                  detail: "Private on this iPhone", symbol: "photo.on.rectangle", keywords: "pictures"),
            .init(route: .help(.founder), group: .help, title: ProfileSettingsHelpLink.founder.title,
                  detail: "Ideas, bugs, anything", symbol: "envelope", keywords: ProfileSettingsHelpLink.founder.keywords),
            .init(route: .help(.support), group: .help, title: ProfileSettingsHelpLink.support.title,
                  detail: "Help with 01", symbol: "questionmark.circle", keywords: ProfileSettingsHelpLink.support.keywords)
        ].filter {
            ($0.destination != .account || isSearching)
                && ($0.destination != .schedule || (workoutAppointments != nil
                && appointmentCalendar != nil && onOpenScheduledWorkout != nil))
                && ($0.route != .importData || hasImportRoute)
        }
    }

    private var hasImportRoute: Bool {
        (workoutHistoryImport != nil && onImportedWorkoutHistory != nil)
            || mealRecordImport != nil || bodyWeightRecordImport != nil || outdoorHistoryTransfer != nil
    }

    @ViewBuilder
    private func entryLink(_ entry: ProfileEntry) -> some View {
        switch entry.route {
        case let .destination(destination):
            NavigationLink(value: destination) { entryLabel(entry) }
        case .export:
            NavigationLink {
                LocalDataExportView(makeJSON: makeLocalDataJSON)
            } label: { entryLabel(entry) }
        case .importData:
            NavigationLink {
                ProfileSettingsImportView(workoutHistoryImport: workoutHistoryImport,
                    onImportedWorkoutHistory: onImportedWorkoutHistory,
                    mealRecordImport: mealRecordImport, bodyWeightRecordImport: bodyWeightRecordImport,
                    outdoorHistoryTransfer: outdoorHistoryTransfer)
            } label: { entryLabel(entry) }
        case .theme:
            NavigationLink {
                ProfileSettingsThemeView(selectedAppearance: $selectedAppearance)
            } label: { entryLabel(entry) }
        case .coach:
            NavigationLink {
                WorkoutCoachSettingsView()
            } label: { entryLabel(entry) }
        case let .help(link):
            Link(destination: link.url) { entryLabel(entry) }
        }
    }

    private func entryLabel(_ entry: ProfileEntry) -> some View {
        HStack(spacing: ZOSpace.m) {
            profileRow(localization.string(entry.title), detail: displayDetail(for: entry), symbol: entry.symbol)
            Image(systemName: "chevron.right")
                .zoIcon(16)
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var matchingEntries: [ProfileEntry] {
        allEntries.filter { entry in
            ProfileSettingsPresentation.matchesSearch(query: searchText,
                fields: [localization.string(entry.title), displayDetail(for: entry),
                         entry.title, entry.detail, entry.keywords], locale: localization.locale)
        }
    }

    private func visibleEntries(in group: ProfileGroup) -> [ProfileEntry] {
        matchingEntries.filter { $0.group == group }
    }

    private var visibleGroups: [ProfileGroup] {
        ProfileGroup.allCases.filter { group in
            matchingEntries.contains { $0.group == group }
        }
    }
}

enum ProfileDestination: Hashable {
    case history
    case session(UUID)
    case personalDetails
    case account
    case unitsAndLanguage
    case notifications
    case schedule
    case widgets
    case membership
    case baseline
    case bodyWeight
    case progress
    case settings
    case localData
    case appleHealth
    case progressPhotos
}

private enum ProfileGroup: CaseIterable, Identifiable {
    case you, howItWorks, data, help

    var id: Self { self }

    var title: String {
        switch self {
        case .you: "You"
        case .howItWorks: "How 01 works"
        case .data: "Your data"
        case .help: "Help"
        }
    }
}

private struct ProfileEntry: Identifiable {
    enum Route: Hashable {
        case destination(ProfileDestination)
        case export, importData, theme, coach
        case help(ProfileSettingsHelpLink)
    }

    let route: Route
    let group: ProfileGroup
    let title: String
    let detail: String
    let symbol: String
    let keywords: String

    var id: Route { route }
    var destination: ProfileDestination? {
        guard case let .destination(value) = route else { return nil }
        return value
    }

    init(id: ProfileDestination, group: ProfileGroup, title: String, detail: String,
         symbol: String, keywords: String) {
        self.init(route: .destination(id), group: group, title: title, detail: detail,
                  symbol: symbol, keywords: keywords)
    }

    init(route: Route, group: ProfileGroup, title: String, detail: String, symbol: String, keywords: String) {
        self.route = route
        self.group = group
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.keywords = keywords
    }
}

private struct ProfileStatusTile: View {
    let title: String
    let value: String
    let symbol: String

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Image(systemName: symbol)
                .zoIcon(ZOIcon.row)
                .foregroundStyle(theme.textPrimary)
                .accessibilityHidden(true)
            Spacer(minLength: ZOSpace.s)
            Text(title)
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .padding(ZOSpace.m)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.control))
        .accessibilityElement(children: .combine)
    }
}
private enum ProfileSettingsYouHostDestination: Hashable {
    case settings
}

private struct ProfileLocalDataView: View {
    let makeLocalDataJSON: @MainActor (LocalDataExportSelection) async throws -> Data
    let workoutHistoryImport: WorkoutHistoryImportCoordinator?
    let onImportedWorkoutHistory: (@MainActor ([WorkoutHistoryEntry]) throws -> Void)?
    let mealRecordImport: FoodBodyWeightImportCoordinator?
    let bodyWeightRecordImport: FoodBodyWeightImportCoordinator?
    let outdoorHistoryTransfer: OutdoorHistoryTransferCoordinator?
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        List {
            Section("Where your data lives") {
                Label("This iPhone", systemImage: "iphone")
                    .zoText(.section).labelStyle(ZOIconLabelStyle())
                Text("01 saves your workouts, body-weight readings and progress photos locally. Workout logging works without a connection.")
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.surfacePrimary)

            Section("Moving to another iPhone") {
                Text("You can transfer workout history, meals and body-weight readings using an 01 JSON export. Complete walks and runs use a separate outdoor-history file with explicit route review. Water and settings are not restored, and signing in does not enable iCloud sync. Your iPhone backup settings control device backups; 01 cannot confirm what was backed up or restored.")
                Text("Keep your old iPhone until you have checked your records in 01 on the new one.")
                    .zoText(.section)
            }
            .listRowBackground(theme.surfacePrimary)

            Section("Export a copy") {
                NavigationLink {
                    LocalDataExportView(makeJSON: makeLocalDataJSON)
                } label: {
                    Label("Choose records to export", systemImage: "square.and.arrow.up")
                }
                Text("Choose workouts, meals, saved water data, walks and runs. Body weight and route coordinates are off by default. The copy is unencrypted. Workout history, meals and body weight can be imported from its JSON file after review. Complete outdoor history uses the separate transfer below; this general export cannot restore it. ZIP, water and settings cannot be restored.")
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.surfacePrimary)

            if let workoutHistoryImport, let onImportedWorkoutHistory {
                Section("Import a reviewed copy") {
                    NavigationLink {
                        LocalWorkoutHistoryImportView(coordinator: workoutHistoryImport,
                            didConfirm: onImportedWorkoutHistory)
                    } label: {
                        Label("Import workout history", systemImage: "square.and.arrow.down")
                    }
                    Text("Review the records before saving. Existing workouts are preserved; conflicting identifiers stop the complete import. Finish or resolve an active workout first.")
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surfacePrimary)
            }
            if mealRecordImport != nil || bodyWeightRecordImport != nil {
                Section("Import meals or body weight") {
                    if let mealRecordImport {
                        NavigationLink {
                            LocalFoodBodyWeightImportView(coordinator: mealRecordImport)
                        } label: {
                            Label("Import meals", systemImage: "square.and.arrow.down")
                        }
                    }
                    if let bodyWeightRecordImport {
                        NavigationLink {
                            LocalFoodBodyWeightImportView(coordinator: bodyWeightRecordImport)
                        } label: {
                            Label("Import body-weight readings", systemImage: "square.and.arrow.down")
                        }
                    }
                    Text("Review and select records before saving each category. Existing records are kept. Conflicting identifiers block the category, and no records are sent to Apple Health.")
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surfacePrimary)
            }
            if let outdoorHistoryTransfer {
                Section("Transfer saved walks and runs") {
                    NavigationLink {
                        LocalOutdoorHistoryTransferView(coordinator: outdoorHistoryTransfer)
                    } label: {
                        Label("Review outdoor history transfer", systemImage: "arrow.left.arrow.right")
                    }
                    Text("Use this separate format to preserve complete saved outdoor records and route gaps. It includes private coordinates and requires review. Deleted routes remain deleted; conflicting identifiers block the import.")
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surfacePrimary)
            }
        }
        .navigationTitle("Your data")
        .scrollContentBackground(.hidden)
        .background(theme.backgroundPrimary)
        .foregroundStyle(theme.textPrimary)
    }
}

/// Study 09 and Study 18 applied to a saved session: recorded facts only, with
/// unknown kept unknown. Older records keep their summary; nothing is inferred
/// about per-exercise allocations, duration or records.
struct WorkoutHistoryPresentation: Equatable {
    enum Status: Equatable {
        case complete
        case partial

        var title: String { self == .complete ? "Complete" : "Partial" }
        var symbol: String { self == .complete ? "checkmark" : "circle.lefthalf.filled" }
    }

    enum WarmUpOutcome: Equatable {
        case completed
        case partial
        case skipped
        case notRecorded

        init(_ warmUp: WorkoutWarmUp?) {
            switch warmUp?.status {
            case .completed: self = .completed
            case .partial: self = .partial
            case .skipped: self = .skipped
            case .pending, nil: self = .notRecorded
            }
        }

        var title: String {
            switch self {
            case .completed: "Warm-up completed"
            case .partial: "Warm-up partly completed"
            case .skipped: "Warm-up skipped"
            case .notRecorded: "Warm-up not recorded"
            }
        }
    }

    enum Detail: Equatable {
        /// Exercise-level sets were saved.
        case sets
        /// Exercise details were saved, but no working set was logged.
        case noSavedSets
        /// An older summary saved before per-set history.
        case summaryOnly
    }

    /// One Study 18 grid segment. `startsGroup` separates exercises.
    struct GridCell: Identifiable, Equatable {
        let id: String
        let isSaved: Bool
        let startsGroup: Bool
    }

    /// One Study 18 History row: the exercise, its saved/planned count and
    /// only the sets that were saved. Unlogged sets live in the grid.
    struct ExerciseRow: Identifiable, Equatable {
        /// Position in the session, so repeated exercises stay separate.
        let id: Int
        let exerciseID: ExerciseID
        let name: String
        /// Nil in records saved before per-exercise planned counts.
        let plannedCount: Int?
        let sets: [CompletedSet]
        /// False when one unit covers every saved set and a note says so.
        let showsUnit: Bool

        var savedCount: Int { sets.count }

        var statusText: String {
            guard let plannedCount else {
                return savedCount == 0 ? "No sets saved"
                    : "\(WorkoutHistoryPresentation.setsText(savedCount)) saved"
            }
            return "\(savedCount) of \(plannedCount)"
        }

        func text(for set: CompletedSet) -> String {
            if set.isTimed { return set.performanceText }
            return "\(WorkoutHistoryPresentation.loadText(set.load, exerciseID: exerciseID, showsUnit: showsUnit)) × \(set.reps)\(set.isPerSide == true ? " per side" : "")"
        }

        /// One VoiceOver stop per exercise, always with units.
        var accessibilityLabel: String {
            let spoken = sets.enumerated().map { index, set in
                if set.isTimed { return "Set \(index + 1), \(set.performanceText)." }
                let load = WorkoutHistoryPresentation.loadText(set.load, exerciseID: exerciseID)
                return "Set \(index + 1), \(load), \(set.reps == 1 ? "1 repetition" : "\(set.reps) repetitions")\(set.isPerSide == true ? " per side" : "")."
            }
            return (["\(name), \(statusText)."] + (spoken.isEmpty ? ["Not logged."] : spoken)).joined(separator: " ")
        }
    }

    let status: Status
    let savedSetCount: Int
    let plannedSetCount: Int
    let wasAdapted: Bool
    let warmUp: WarmUpOutcome
    let detail: Detail
    let exercises: [ExerciseRow]
    let grid: [GridCell]
    /// Planned sets that were not logged and whose exercise was never recorded.
    let unassignedOpenSetCount: Int
    /// Study 18's "Loads in kg" note, only when every saved set uses one unit.
    let loadUnitNote: String?

    init(entry: WorkoutHistoryDisplayItem) {
        status = entry.endedEarly ? .partial : .complete
        savedSetCount = entry.completedSetCount
        plannedSetCount = entry.plannedSetCount
        wasAdapted = entry.wasAdapted
        warmUp = WarmUpOutcome(entry.warmUp)

        guard let saved = entry.exercises else {
            detail = .summaryOnly
            exercises = []
            loadUnitNote = nil
            // Counts only: which exercise each set belonged to was never saved.
            grid = Self.group(
                "summary", saved: max(0, entry.completedSetCount),
                open: max(0, entry.plannedSetCount - entry.completedSetCount)
            )
            unassignedOpenSetCount = 0
            return
        }

        let units = Set(saved.flatMap(\.completedSets).filter { !$0.isTimed }.map(\.load.unit))
        let singleUnit = units.count == 1 ? units.first : nil
        var cells: [GridCell] = []
        var rows: [ExerciseRow] = []
        for (index, exercise) in saved.enumerated() {
            let sets = exercise.completedSets
            let planned = exercise.plannedSetCount
            let slots = planned.map { max($0, sets.count) } ?? sets.count
            cells += Self.group("\(index)", saved: sets.count, open: slots - sets.count)
            rows.append(ExerciseRow(
                id: index,
                exerciseID: exercise.exerciseID,
                name: Self.exerciseName(for: exercise.exerciseID),
                plannedCount: planned,
                sets: sets,
                showsUnit: singleUnit == nil
            ))
        }
        // Older records know the session's planned total but not each
        // exercise's share, so unlogged sets stay unattributed at the end.
        let unassigned = max(0, entry.plannedSetCount - cells.count)
        cells += Self.group("unassigned", saved: 0, open: unassigned)

        detail = rows.contains { $0.savedCount > 0 } ? .sets : .noSavedSets
        exercises = rows
        grid = cells
        unassignedOpenSetCount = unassigned
        loadUnitNote = singleUnit.map { "Loads in \($0.rawValue)." }
    }

    /// List line, e.g. "10 of 12 sets · Adapted".
    var countText: String {
        "\(savedSetCount) of \(Self.setsText(plannedSetCount))" + (wasAdapted ? " · Adapted" : "")
    }

    /// Study 18 status copy. Adaptation is a saved fact, so it is added when true.
    var statusDetail: String {
        var text = status == .complete && plannedSetCount > 1
            ? "All \(plannedSetCount) sets saved"
            : "\(savedSetCount) of \(Self.setsText(plannedSetCount)) saved"
        if status == .partial { text += ". Ended early; every logged set is kept" }
        if wasAdapted { text += ". Plan adapted for this session" }
        return status == .partial || wasAdapted ? text + "." : text
    }

    var gridAccessibilityLabel: String {
        "\(savedSetCount) of \(plannedSetCount) working sets saved"
    }

    func listAccessibilityLabel(title: String, dateText: String) -> String {
        "\(title). \(status.title). \(savedSetCount) of \(Self.setsText(plannedSetCount)) saved. \(dateText)."
            + (wasAdapted ? " Adapted plan." : "")
    }

    static func setsText(_ count: Int) -> String {
        pluralText(count, noun: "set")
    }

    static func pluralText(_ count: Int, noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func exerciseName(for id: ExerciseID) -> String {
        ExerciseLibrary.exercise(id: id)?.name
            ?? MoveKitExerciseCatalog.match(for: id)?.exercise.name
            ?? "Recorded exercise"
    }

    static func loadText(_ load: Load, exerciseID: ExerciseID, showsUnit: Bool = true) -> String {
        if load.value == 0,
           (ExerciseLibrary.exercise(id: exerciseID)?.equipment.contains(.bodyweight) == true
               || MoveKitExerciseCatalog.match(for: exerciseID)?.exercise.equipment
                   .localizedCaseInsensitiveContains("bodyweight") == true) {
            return "Bodyweight"
        }
        let value = load.value.formatted(.number.precision(.fractionLength(0 ... 2)))
        return showsUnit ? "\(value) \(load.unit.rawValue)" : value
    }

    private static func group(_ id: String, saved: Int, open: Int) -> [GridCell] {
        (0 ..< max(0, saved + open)).map { offset in
            GridCell(id: "\(id)-\(offset + 1)", isSaved: offset < saved, startsGroup: offset == 0)
        }
    }
}

/// Final study 30 proof 40: saved History only. Proof 39 is the neighboring
/// exercise/swap reference. All colors/type/spacing resolve through shared roles.
private struct WorkoutHistorySetGrid: View {
    let cells: [WorkoutHistoryPresentation.GridCell]
    @Environment(\.zeroOneTheme) private var theme

    private var railRadius: CGFloat {
        switch theme.designTheme {
        case .core, .retro: ZOSpace.xs / 2
        case .freak: 0
        case .princess: 4
        }
    }

    var body: some View {
        HStack(spacing: ZOSpace.xs / 2) {
            ForEach(cells) { cell in
                HStack(spacing: 0) {
                    Color.clear.frame(width: cell.startsGroup && cell.id != cells.first?.id ? ZOSpace.xs : 0)
                    RoundedRectangle(cornerRadius: railRadius)
                        .fill(cell.isSaved ? theme.textPrimary : theme.surfaceTertiary)
                        .shadow(color: cell.isSaved && theme.designTheme == .retro && theme.colorScheme == .dark
                            ? Color(zoHex: 0xFF8A3D, alpha: 0.70) : .clear, radius: 6, x: 0, y: 0)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: ZOStroke.railApp)
    }
}

private struct WorkoutHistoryMetric: View {
    let title: String
    let value: String
    var unit: String? = nil
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).zoThemeText(.caption).foregroundStyle(theme.textSecondary)
            Spacer(minLength: ZOSpace.s)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: value).zoHistoryCompactMetricText()
                    .fixedSize(horizontal: false, vertical: true)
                if let unit {
                    Text(verbatim: unit).zoProofText(.label, size: 15, lineHeight: 20, weight: 500)
                        .foregroundStyle(theme.textSecondary).padding(.leading, ZOSpace.xs / 2)
                }
            }
            .foregroundStyle(theme.textPrimary)
        }
        .padding(ZOSpace.m)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(theme.surfacePrimary, in: ZORadius.cardShape)
        .accessibilityElement(children: .combine)
    }
}

/// Wraps chips without truncating a recorded value or its unit/side meaning.
private struct WorkoutHistoryFlowLayout: Layout {
    var spacing: CGFloat = ZOSpace.xs
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}

/// Proof 51's zero-data illustration. These strokes are decorative pattern,
/// not planned sets or history facts; no count is exposed to accessibility.
private struct WorkoutHistoryEmptyRail: View {
    @Environment(\.zeroOneTheme) private var theme

    private var railRadius: CGFloat {
        switch theme.designTheme {
        case .core, .retro: 2
        case .freak: 0
        case .princess: 4
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 6, id: \.self) { _ in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: railRadius).fill(theme.surfaceTertiary)
                    RoundedRectangle(cornerRadius: railRadius).fill(theme.surfaceTertiary)
                }
            }
        }
        .frame(height: ZOStroke.railApp)
        .accessibilityHidden(true)
    }
}

private struct WorkoutHistoryView: View {
    let state: WorkoutHistorySurfaceState
    var onShareSavedWorkout: ((UUID) -> Void)? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var copy: WorkoutHistoryFactsPresentation { .init(localization: localization) }
    // Proof 40: one History with Workouts and Walks and runs.
    @Environment(\.zeroOneOutdoorRepository) private var outdoorRepository
    @State private var kind: HistoryKind = .workouts

    var body: some View {
        VStack(spacing: 0) {
        if outdoorRepository != nil {
            ZOSegmentedControl("History", selection: $kind, options: [
                ZOSegment(value: HistoryKind.workouts, label: Text(verbatim: localization.string("Workouts"))),
                ZOSegment(value: HistoryKind.outdoor, label: Text(verbatim: localization.string("Walks and runs")))
            ])
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.s)
        }
        if kind == .outdoor, let outdoorRepository {
            OutdoorActivityHistoryView(repository: outdoorRepository, embedded: true)
        } else {
        Group {
            switch state {
            case .empty:
                ContentUnavailableView {
                    VStack(spacing: 18) {
                        WorkoutHistoryEmptyRail()
                        Text(verbatim: localization.string("Your workouts land here"))
                            .zoThemeText(.title)
                    }
                } description: {
                    Text(verbatim: localization.string("Finished sessions will stay in local History on this iPhone."))
                        .zoThemeText(.body).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unavailable:
                ContentUnavailableView(localization.string("History unavailable"), systemImage: "exclamationmark.triangle",
                    description: Text(verbatim: localization.string("Your local workout history could not be read. You can still return to Workout and train offline.")))
            case let .entries(entries):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ZOSpace.sectionGap) {
                        if let summary = WorkoutHistoryFactsPresentation.monthSummary(entries, now: .now, calendar: calendar) {
                            VStack(alignment: .leading, spacing: ZOSpace.s) {
                                Text(verbatim: copy.monthTitle(summary, calendar: calendar)).zoText(.caption)
                                    .foregroundStyle(theme.textSecondary).accessibilityAddTraits(.isHeader)
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(spacing: ZOSpace.s) { monthMetrics(summary) }
                                } else {
                                    HStack(alignment: .top, spacing: ZOSpace.s) { monthMetrics(summary) }
                                }
                            }
                        }
                        ForEach(WorkoutHistoryFactsPresentation.weeks(entries, calendar: calendar)) { week in
                            VStack(alignment: .leading, spacing: ZOSpace.s) {
                                Text(verbatim: copy.weekTitle(week, now: .now, calendar: calendar))
                                    .zoThemeText(.section).foregroundStyle(theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(week.entries) { entry in
                                    NavigationLink {
                                        WorkoutHistoryDetailView(entry: entry, onShareSavedWorkout: onShareSavedWorkout)
                                    } label: {
                                        WorkoutHistoryCard(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint(localization.string("Opens the recorded exercises and sets."))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, ZOSpace.screenMargin)
                    .padding(.top, ZOSpace.s)
                    .padding(.bottom, ZOSpace.x3)
                }
                .scrollIndicators(.hidden)
            }
        }
        }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle(localization.string("History"))
        .navigationBarTitleDisplayMode(.inline)
        .zoThemeScreenSurface()
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
    }

    @ViewBuilder private func monthMetrics(_ summary: WorkoutHistoryFactsPresentation.MonthSummary) -> some View {
        WorkoutHistoryMetric(title: localization.string("Workouts"), value: summary.workoutCount.formatted(.number.locale(localization.locale)))
        if let sets = summary.savedSetCount {
            WorkoutHistoryMetric(title: localization.string("Saved sets"), value: sets.formatted(.number.locale(localization.locale)))
        }
    }
}

private struct WorkoutHistoryCard: View {
    let entry: WorkoutHistoryDisplayItem
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar

    private var historyRadius: CGFloat {
        switch theme.designTheme {
        case .core, .retro: ZORadius.card
        case .freak: 2
        case .princess: 22
        }
    }

    var body: some View {
        let copy = WorkoutHistoryFactsPresentation(localization: localization)
        let presentation = WorkoutHistoryPresentation(entry: entry)
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(verbatim: entry.title).zoThemeText(.section).foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: localization.format("%1$@ · %2$@",
                .text(copy.date(entry.completedAt, calendar: calendar)), .text(copy.rowSummary(presentation))))
                .zoThemeText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !presentation.grid.isEmpty {
                WorkoutHistorySetGrid(cells: presentation.grid).padding(.top, 2).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ZOSpace.cardPadding)
        .padding(.vertical, 14)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: historyRadius, style: .continuous))
        .contentShape(ZORadius.cardShape)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutHistoryDetailView: View {
    let entry: WorkoutHistoryDisplayItem
    var onShareSavedWorkout: ((UUID) -> Void)? = nil
    @Environment(\.savedWorkoutHistoryShareAuthority) private var savedShareAuthority
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var copy: WorkoutHistoryFactsPresentation { .init(localization: localization) }

    // A reopened record is still. Finish motion, focus and haptics are owned by
    // the actual acknowledged completion surface and never replayed here.
    var body: some View {
        let presentation = WorkoutHistoryPresentation(entry: entry)
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text(verbatim: copy.date(entry.completedAt, calendar: calendar, wide: true))
                        .zoThemeText(.caption).foregroundStyle(theme.textSecondary)
                    Text(verbatim: entry.title).zoThemeText(.display).foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader).accessibilitySortPriority(1)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !presentation.grid.isEmpty { rail(presentation) }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(verbatim: copy.status(presentation.status)).zoText(.section)
                    Text(verbatim: copy.recordSummary(presentation)).zoText(.body)
                }
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                metrics
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(verbatim: localization.string("Exercises")).zoThemeText(.section)
                        .foregroundStyle(theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Text(verbatim: copy.warmUp(presentation.warmUp)).zoThemeText(.caption)
                        .foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    savedWork(presentation)
                }
                Text(verbatim: localization.string("Saved on this iPhone."))
                    .zoThemeText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xs)
            .padding(.bottom, ZOSpace.x3)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(localization.string("Saved to History"))
        .navigationBarTitleDisplayMode(.inline)
        .zoThemeScreenSurface()
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .toolbar {
            if let savedShareAuthority {
                ToolbarItem(placement: .topBarTrailing) {
                    SavedWorkoutHistoryShareButton(entry: entry.sourceEntry, authority: savedShareAuthority)
                }
            } else if let onShareSavedWorkout {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // This is the real saved source identity, including a
                        // legacy summary. Root freshly validates eligibility.
                        onShareSavedWorkout(entry.sourceEntry.id)
                    } label: {
                        Label(localization.string("Share saved workout"), systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(ZOButtonStyle(.round))
                }
            }
        }
    }

    private var metrics: some View {
        let repetitions = WorkoutHistoryFactsPresentation.totalRepetitions(entry)
        let volume = WorkoutHistoryFactsPresentation.loggedVolume(entry)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: ZOSpace.s) {
                    WorkoutHistoryMetric(title: localization.string("Saved sets"), value: entry.completedSetCount.formatted(.number.locale(localization.locale)))
                    if let volume { WorkoutHistoryMetric(title: localization.string("Logged volume"), value: volume.value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale)), unit: volume.unit.rawValue) }
                    if let repetitions { WorkoutHistoryMetric(title: localization.string("Reps"), value: repetitions.formatted(.number.locale(localization.locale))) }
                }
            } else {
                HStack(alignment: .top, spacing: ZOSpace.s) {
                    WorkoutHistoryMetric(title: localization.string("Saved sets"), value: entry.completedSetCount.formatted(.number.locale(localization.locale)))
                    if let volume { WorkoutHistoryMetric(title: localization.string("Logged volume"), value: volume.value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale)), unit: volume.unit.rawValue) }
                    if let repetitions { WorkoutHistoryMetric(title: localization.string("Reps"), value: repetitions.formatted(.number.locale(localization.locale))) }
                }
            }
        }
    }

    private func rail(_ presentation: WorkoutHistoryPresentation) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            WorkoutHistorySetGrid(cells: presentation.grid)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy.savedCounts(presentation))
            WorkoutHistoryFlowLayout(spacing: ZOSpace.m) {
                railKey(saved: true, title: localization.string("Saved set"))
                railKey(saved: false, title: localization.string("Not logged"))
            }
            .accessibilityHidden(true)
            if presentation.unassignedOpenSetCount > 0 {
                Text(verbatim: localization.string("This older record did not save which exercise each unlogged set belonged to."))
                    .zoText(.caption).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func railKey(saved: Bool, title: String) -> some View {
        HStack(spacing: ZOSpace.xs) {
            RoundedRectangle(cornerRadius: ZOSpace.xs / 2)
                .fill(saved ? theme.textPrimary : theme.surfaceTertiary)
                .frame(width: ZOSpace.m, height: ZOSpace.m)
            Text(verbatim: title).zoText(.caption).foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder private func savedWork(_ presentation: WorkoutHistoryPresentation) -> some View {
        switch presentation.detail {
        case .summaryOnly:
            unavailableDetails(title: "Set details unavailable",
                message: "This older workout was saved before per-set history was available. Its summary is preserved.")
        case .noSavedSets:
            unavailableDetails(title: "No completed sets", message: "This session has no recorded working sets.")
        case .sets:
            VStack(spacing: 0) {
                ForEach(presentation.exercises) { exercise in
                    WorkoutHistoryExerciseRow(exercise: exercise)
                }
            }
            .padding(.horizontal, ZOSpace.cardPadding)
            .zoThemeCardSurface()
        }
    }

    private func unavailableDetails(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(verbatim: localization.string(title)).zoText(.section).foregroundStyle(theme.textPrimary)
            Text(verbatim: localization.string(message)).zoText(.body).foregroundStyle(theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.cardPadding)
        .background(theme.surfacePrimary, in: ZORadius.cardShape)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutHistoryExerciseRow: View {
    let exercise: WorkoutHistoryPresentation.ExerciseRow
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var exactPoster: MoveKitExercise? {
        guard let match = MoveKitExerciseCatalog.match(for: exercise.exerciseID),
              match.relationship == .exact else { return nil }
        return match.exercise
    }

    var body: some View {
        let copy = WorkoutHistoryFactsPresentation(localization: localization)
        HStack(alignment: .top, spacing: ZOSpace.m) {
            if !dynamicTypeSize.isAccessibilitySize, let exactPoster {
                CustomWorkoutExerciseThumbnail(exercise: exactPoster, size: ZOSpace.x4)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(verbatim: copy.exerciseName(exercise.exerciseID)).zoThemeText(.section)
                .foregroundStyle(exercise.savedCount > 0 ? theme.textPrimary : theme.textSecondary)
            Text(verbatim: copy.exerciseCounts(exercise)).zoText(.caption).foregroundStyle(theme.textSecondary)
            if exercise.sets.isEmpty {
                Text(verbatim: localization.string("Not logged")).zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                WorkoutHistoryFlowLayout(spacing: 6) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { number, set in
                        Text(verbatim: copy.setText(set)).zoProofText(.caption, size: 13, lineHeight: 18, weight: 500, tabular: true)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .frame(minHeight: 28)
                            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.small))
                            .accessibilityLabel(copy.setAccessibility(set, number: number + 1))
                    }
                }
            }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ZOSpace.m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}
private struct ZeroOneBetaDestinationView: View {
    let eyebrow: String
    let title: String
    let statement: String
    let symbol: String
    let details: [(String, String)]

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: max(28, proxy.size.height * 0.08))

                    Text(eyebrow)
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)

                    Text(title)
                        .zoText(.display)

                        .foregroundStyle(theme.textPrimary)
                        .padding(.top, ZOSpace.m)
                        .accessibilityAddTraits(.isHeader)

                    Text(statement)
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, ZOSpace.m)
                        .frame(maxWidth: 470, alignment: .leading)

                    Spacer(minLength: max(56, proxy.size.height * 0.18))

                    Image(systemName: symbol)
                        .zoIcon(ZOIcon.feature)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityHidden(true)

                    VStack(spacing: 0) {
                        ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                            HStack(alignment: .firstTextBaseline) {
                                Text(detail.0)
                                    .zoText(.body)
                                    .foregroundStyle(theme.textSecondary)

                                Spacer(minLength: ZOSpace.l)

                                Text(detail.1)
                                    .zoText(.section)
                                    .foregroundStyle(theme.textPrimary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, ZOSpace.l)

                            if index < details.count - 1 {
                                Rectangle()
                                    .fill(theme.strokeSubtle)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, ZOSpace.l)

                    Spacer(minLength: ZOSpace.x4)
                }
                .frame(maxWidth: 560, minHeight: proxy.size.height, alignment: .leading)
                .padding(.horizontal, ZOSpace.screenMargin)
            }
            .scrollIndicators(.hidden)
        }
    }
}
