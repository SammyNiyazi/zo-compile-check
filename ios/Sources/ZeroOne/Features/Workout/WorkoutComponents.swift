import CoreText
import Foundation
import SwiftUI
import UIKit

enum TrainingCompanionPalette {
    static func canvas(for scheme: ColorScheme) -> Color {
        ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme).backgroundPrimary
    }

    static func surface(for scheme: ColorScheme) -> Color {
        ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme).surfacePrimary
    }

    static func field(for scheme: ColorScheme) -> Color {
        ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme).surfaceSecondary
    }

    static func ink(for scheme: ColorScheme) -> Color {
        ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme).textPrimary
    }

    static func stroke(for scheme: ColorScheme) -> Color {
        ZeroOneThemeTokens.resolve(.liquidMidnight, colorScheme: scheme).strokeSubtle
    }
}

struct WorkoutCompletionView: View {
    let sessionTitle: String
    let completedSetCount: Int
    let totalSetCount: Int
    let exercises: [WorkoutExercise]
    let endedEarly: Bool
    let totalReps: Int?
    let completedAt: Date?
    let historyState: WorkoutHistorySurfaceState
    let upgrades: [WorkoutCompletionUpgrade]
    let sourceSessionID: UUID
    let loadChoices: WorkoutLoadChoiceRepository
    /// Earlier recorded performance, excluding this session.
    let previousPerformance: (ExerciseID) -> PreviousExercisePerformanceState
    /// The saved record, drawn as Study 18's grid.
    let rail: WorkoutSetRail
    let railNamespace: Namespace.ID
    /// True only on the first render of a live, acknowledged finish.
    let presentsLive: Bool
    /// True when the workout's rail may travel into the grid.
    let carriesRail: Bool
    @Bindable var progressPhotos: ProgressPhotoRepository
    let shouldAnimate: () -> Bool
    let onViewSession: () -> Void
    let onFinish: () -> Void
    var onShare: (() -> Void)? = nil
    var shareIsBusy = false
    /// Verified by WorkoutPersonalRecord. Only Freak turns it into the "New PR" slam.
    var personalRecord = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var upgradeMotionEnabled: Bool? = nil
    @State private var railCarrierLatch: Bool? = nil
    /// Latched at first appearance: a live, newly inserted save in the
    /// foreground earns the one burst. Recovery, reconciliation and relaunch
    /// never set `presentsLive`, so nothing replays.
    @State private var celebrates: Bool? = nil
    @State private var slamStarted = false
    @State private var shakeTrigger = false
    @State private var slamLanded = false
    @AccessibilityFocusState private var titleFocused: Bool

    private var slams: Bool { personalRecord && theme.designTheme == .freak }

    private var staged: Bool {
        !reduceMotion && !voiceOverEnabled && !dynamicTypeSize.isAccessibilitySize
    }

    /// Study 18 settle: status at 360 ms, detail and rows from 420 ms in 60 ms
    /// steps, Done at 480 ms. Nothing starts after 720 ms, so all is still by
    /// 960 ms. Reduce Motion, VoiceOver and large text crossfade in 180 ms.
    private func reveal(_ visible: Bool, at delay: Double, distance: CGFloat = 10) -> WorkoutRise {
        WorkoutRise(
            visible: visible,
            distance: staged ? distance : 0,
            animation: staged
                ? WorkoutMotion.land(0.24).delay(min(delay, 0.72))
                : .easeOut(duration: 0.18)
        )
    }

    private var statusDetail: String {
        let exercisesText = localization.format("%1$lld of %2$lld exercises", .integer(exercises.filter { !$0.completedSets.isEmpty }.count), .integer(exercises.count))
        return endedEarly
            ? localization.format("%1$@ · %2$@. Ended early; every logged set is kept.", .text(workoutCopy.savedProgress(completedSetCount, of: totalSetCount)), .text(exercisesText))
            : localization.format("All sets saved: %1$@ · %2$@.", .text(workoutCopy.quantity(totalSetCount, .sets)), .text(exercisesText))
    }

    var body: some View {
        WorkoutEntranceLatch(animated: presentsLive) { visible in
            content(visible: visible)
        }
        .overlay(alignment: .top) {
            if celebrates == true {
                WorkoutFinishConfetti(personalRecord: slams)
                    .frame(maxWidth: .infinity)
                    .frame(height: 640)
                    .clipped()
            }
        }
        .onAppear {
            railCarrierLatch = railCarrierLatch ?? carriesRail
            celebrates = WorkoutFinishConfetti.celebrates(
                latched: celebrates, presentsLive: presentsLive, reduceMotion: reduceMotion,
                designTheme: theme.designTheme
            )
            // Freak PR: shake after the stamp starts landing, heavy haptic as it lands. Once.
            if celebrates == true, slams, !slamStarted {
                slamStarted = true
                if !reduceMotion { shakeTrigger.toggle() }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ThemeWinTimeline.freakSlamDuration))
                    slamLanded = true
                }
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: shakeTrigger) { content, elapsed in
            content.offset(ThemeWinTimeline.freakShake(elapsed: elapsed, reduceMotion: reduceMotion))
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                LinearKeyframe(ThemeWinTimeline.freakShakeDelay + ThemeWinTimeline.freakShakeDuration,
                    duration: ThemeWinTimeline.freakShakeDelay + ThemeWinTimeline.freakShakeDuration)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: slamLanded) { _, landed in landed }
        .task {
            await presentSuccess()
        }
    }

    @ViewBuilder
    private func content(visible: Bool) -> some View {
        let previous = Dictionary(
            exercises.map { ($0.id, previousPerformance($0.plan.exerciseID)) },
            uniquingKeysWith: { first, _ in first }
        )
        let comparisons = Dictionary(
            exercises.compactMap { exercise in
                previous[exercise.id].flatMap {
                    WorkoutExerciseComparison.evaluate(savedSets: exercise.completedSets, previousPerformance: $0)
                }.map { (exercise.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let finish = WorkoutFinishComparison(exercises: exercises, previous: previousPerformance)
        let coachLines = WorkoutCoachLines(localization: localization).wrapUp(
            completedSetCount: completedSetCount, plannedSetCount: totalSetCount,
            endedEarly: endedEarly, finish: finish, upgrade: upgrades.first
        )

        VStack(alignment: .leading, spacing: ZOSpace.l) {
            // Proof 37's finish: what was saved, one short line, every
            // exercise as a bar against last time, then the totals. The 01
            // mark rides in the coach line.
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(localization.format("SAVED TO HISTORY · %1$@", .text(sessionTitle)) + (completedAt.map { " · \($0.formatted(.dateTime.day().month().year().locale(localization.locale)))" } ?? ""))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Session saved")
                    .zoText(.display)

                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
            }
            .modifier(reveal(visible, at: 0.12))

            WorkoutCoachLineView(lines: coachLines)
                .modifier(reveal(visible, at: 0.24))

            if finish.rows.contains(where: { $0.savedSetCount > 0 }) {
                finishCard(finish)
                    .accessibilityIdentifier("workout.summaryHighlight")
                    .modifier(reveal(visible, at: 0.36))
            }

            HStack(alignment: .top, spacing: ZOSpace.s) {
                completionMetric(value: "\(completedSetCount)/\(totalSetCount)", label: "Sets", index: 0)
                if let volume = finish.volume {
                    completionMetric(value: workoutCopy.load(volume), label: "Volume", index: 1)
                } else {
                    completionMetric(value: exercises.filter { !$0.completedSets.isEmpty }.count.formatted(), label: "Exercises", index: 1)
                }
                completionMetric(value: totalReps?.formatted() ?? "—", label: "Reps", index: 2)
            }
            .modifier(reveal(visible, at: 0.42))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((totalReps.map {
                localization.format("%1$lld of %2$lld working sets completed, %3$lld repetitions recorded",
                    .integer(completedSetCount), .integer(totalSetCount), .integer($0))
            } ?? localization.format("%1$lld of %2$lld working sets completed. Repetition total unavailable.",
                .integer(completedSetCount), .integer(totalSetCount)))
                + (finish.volume.map { " " + localization.format("Volume: %1$@.", .text(workoutCopy.load($0))) } ?? ""))

            // The record below the proof's screen: complete or ended early,
            // and the saved grid the workout's rail travels into.
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Label(localization.string(endedEarly ? "Partial" : "Complete"),
                      systemImage: endedEarly ? "circle.lefthalf.filled" : "checkmark")
                    .zoText(.section).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(colorScheme == .light ? Color.white : Color.black)
                    .padding(.horizontal, ZOSpace.m)
                    .frame(minHeight: 36)
                    .background(theme.textPrimary, in: Capsule())
                    .modifier(reveal(visible, at: 0.48, distance: 8))
                Text(statusDetail)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(reveal(visible, at: 0.48, distance: 8))
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: ZOSpace.s) {
                // A carried grid is already moving; revealing it too would
                // double-animate it.
                WorkoutSessionRail(
                    rail: rail,
                    style: .grid,
                    namespace: railNamespace,
                    carriesSegments: railCarrierLatch ?? carriesRail,
                    motionEnabled: staged
                )
                .modifier(reveal(visible || (railCarrierLatch ?? carriesRail), at: 0.12, distance: 6))
                HStack(spacing: ZOSpace.m) {
                    gridKey(filled: true, label: "Saved set")
                    gridKey(filled: false, label: "Not logged")
                }
                .accessibilityHidden(true)
                .modifier(reveal(visible, at: 0.48, distance: 6))
            }

            if !upgrades.isEmpty {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    ForEach(upgrades) { upgrade in
                        WorkoutCompletionUpgradeCard(
                            upgrade: upgrade,
                            selectedChoice: loadChoices.choice(
                                for: upgrade, sourceSessionID: sourceSessionID
                            ),
                            motionEnabled: upgradeMotionEnabled,
                            workoutFullySaved: true,
                            canChoose: loadChoices.isAvailable,
                            onChoose: {
                                loadChoices.choose($0, for: upgrade, sourceSessionID: sourceSessionID)
                            }
                        )
                    }
                }
                .modifier(reveal(visible, at: 0.54))
            }

            WorkoutProgressionReviewSection(plans: exercises.map(\.plan), sourceSessionID: sourceSessionID)
                .modifier(reveal(visible, at: 0.54))

            VStack(alignment: .leading, spacing: ZOSpace.m) {
                Text("Saved work")
                    .zoText(.section)
                    .foregroundStyle(theme.textSecondary)
                    .modifier(reveal(visible, at: 0.54))
                ForEach(Array(exercises.enumerated()), id: \.element.id) { row, exercise in
                    let planned = exercise.plan.plannedSetCount
                    let saved = exercise.completedSets.count
                    let previousSets = previous[exercise.id].map(Self.previousSets(in:)) ?? []
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                            Text(exercise.plan.name)
                                .zoText(.section)
                                .fixedSize(horizontal: false, vertical: true)
                            if let comparison = comparisons[exercise.id] {
                                WorkoutInkChip(text: workoutCopy.comparisonChip(comparison))
                            }
                            Spacer(minLength: ZOSpace.s)
                            Text(saved == 0 ? localization.string("Not started") : localization.format("%1$lld of %2$lld · %3$@", .integer(saved), .integer(planned), .text(localization.string(saved >= planned ? "Complete" : "Partial"))))
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        if saved > 0 {
                            ForEach(0 ..< max(planned, saved), id: \.self) { index in
                                summarySetRow(
                                    number: index + 1,
                                    set: exercise.completedSets.indices.contains(index)
                                        ? exercise.completedSets[index] : nil,
                                    previous: previousSets.indices.contains(index) ? previousSets[index] : nil
                                )
                            }
                        }
                    }
                    .padding(ZOSpace.m)
                    .background(
                        TrainingCompanionPalette.surface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: ZORadius.card)
                    )
                    .modifier(reveal(visible, at: 0.6 + Double(row) * 0.06))
                }
            }

            Group {
                if case let .entries(entries) = historyState {
                    WorkoutCompletionFrequency(
                        activity: WorkoutActivitySummary(entries: entries, now: .now, calendar: .current)
                    )
                } else if case .unavailable = historyState {
                    Text("Training frequency is unavailable while local History cannot be read.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .modifier(reveal(visible, at: 0.72))

            VStack(spacing: ZOSpace.s) {
                Button(action: onViewSession) {
                    HStack {
                        Text("View session")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                .accessibilityHint("Opens the workout saved in local History.")

                ProgressPhotoCaptureButton(
                    repository: progressPhotos,
                    initialLabel: .postWorkout,
                    presentation: .completion
                )
                .accessibilityHint("Optionally opens the system photo picker. The workout is already complete.")

                Button("Done", action: onFinish)
                    .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityHint("Returns to Today with this workout marked complete.")

                if let onShare {
                    Button("Share", action: onShare)
                        .buttonStyle(ZOButtonStyle(.quiet))
                        .disabled(shareIsBusy)
                        .accessibilityIdentifier("workout.completion.share")
                        .accessibilityHint("Opens a sharing image made from this saved workout.")
                }
            }
            .modifier(reveal(visible, at: 0.48))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZOSpace.l)
        .padding(.vertical, ZOSpace.l)
    }

    private func finishCard(_ finish: WorkoutFinishComparison) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(finish.rows.filter { $0.savedSetCount > 0 }) { row in
                finishRow(row, maximum: finish.maximumPairedReps)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.cardPadding)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.card)
        )
        .accessibilityElement(children: .contain)
    }

    /// A bar only for loads that matched last time; otherwise the saved facts
    /// in words. No previous marker is drawn from incompatible sets.
    private func finishRow(_ row: WorkoutFinishComparison.Row, maximum: Double) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        let caption: String
        let spoken: String
        if let paired = row.pairedReps {
            caption = localization.format("%1$lld / %2$lld", .integer(paired.today), .integer(paired.previous))
            spoken = localization.format("%1$@ today, %2$@ last time",
                .text(workoutCopy.quantity(paired.today, .reps)), .text(workoutCopy.quantity(paired.previous, .reps)))
        } else if let reps = row.savedReps {
            caption = workoutCopy.quantity(reps, .reps)
            spoken = workoutCopy.savedProgress(row.savedSetCount, of: row.plannedSetCount) + ", " + caption
        } else {
            caption = workoutCopy.savedProgress(row.savedSetCount, of: row.plannedSetCount)
            spoken = caption
        }
        return layout {
            Text(verbatim: row.name)
                .zoText(.label)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 104, alignment: .leading)
            if let paired = row.pairedReps {
                WorkoutComparisonBar(
                    bar: WorkoutComparisonPresentation.Bar(previous: paired.previous, today: paired.today, unit: .repetitions),
                    maximum: maximum
                )
                .frame(minWidth: ZOSpace.xxl)
            } else if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            Text(caption)
                .zoText(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.format("%1$@, %2$@", .text(row.name), .text(spoken)))
    }

    private func gridKey(filled: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(filled ? theme.textPrimary : theme.surfaceTertiary)
                .frame(width: 12, height: 12)
            Text(localization.string(label))
        }
        .zoText(.caption)
        .foregroundStyle(theme.textSecondary)
    }

    private static func previousSets(in state: PreviousExercisePerformanceState) -> [CompletedSet] {
        guard case let .recorded(performance) = state, !performance.hasNewerUnknownDetails else { return [] }
        return performance.occurrences.last(where: { !$0.completedSets.isEmpty })?.completedSets ?? []
    }

    private func summarySetRow(number: Int, set: CompletedSet?, previous: CompletedSet?) -> some View {
        HStack(spacing: ZOSpace.s) {
            Text("\(number)")
                .frame(minWidth: 18, alignment: .leading)
                .foregroundStyle(theme.textSecondary)
            if let set {
                Text("\(workoutCopy.load(set.load)) · \(workoutCopy.performance(set))")
                    .foregroundStyle(theme.textPrimary)
            } else {
                Text("Not logged")
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: ZOSpace.s)
            if let previous {
                Text(localization.format("last %1$@", .text(workoutCopy.setSummary(previous))))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .zoText(.label)
        .monospacedDigit()
        .padding(.vertical, ZOSpace.xs)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.strokeSubtle.opacity(0.32)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            localization.format("Set %1$lld. %2$@", .integer(number), .text(set.map { workoutCopy.setSummary($0) } ?? localization.string("Not logged.")))
                + (previous.map { " " + localization.format("Last time %1$@.", .text(workoutCopy.setSummary($0))) } ?? "")
        )
    }

    /// Proof `.zo-tile`: the label on top, the number at the foot, 12 pt in,
    /// at least 92 pt tall, at the card radius.
    private func completionMetric(value: String, label: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(localization.string(label))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .zoText(.metric)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                // Princess only: the pearl band crosses the three totals once (README decision 70).
                .modifier(PrincessNumberShimmer(active: celebrates == true, index: index, count: 3))
        }
        .frame(maxWidth: .infinity, minHeight: 92 - 2 * ZOSpace.m, alignment: .leading)
        .padding(ZOSpace.m)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.card)
        )
    }

    /// Consumes the one-time presentation. A reconciled or recovered summary is
    /// shown still, with no announcement, focus move or upgrade reveal.
    @MainActor
    private func presentSuccess() async {
        let animate = shouldAnimate()
        upgradeMotionEnabled = animate && !reduceMotion
        guard animate else { return }
        if voiceOverEnabled {
            AccessibilityNotification.Announcement(
                workoutCopy.historyAnnouncement(
                    savedSetCount: completedSetCount, plannedSetCount: totalSetCount
                )
            ).post()
        }
        try? await Task.sleep(for: .milliseconds(staged ? 960 : 180))
        guard !Task.isCancelled else { return }
        titleFocused = true
    }
}

/// Proof 37's finish confetti retains its acknowledged-save, one-burst boundary.
/// The shared renderer adapts ornaments to the chosen theme; this wrapper owns
/// the clock and cleanup. Decorative and never interactive. Core Reduce Motion
/// retains its settled confirmation; non-Core admits the static ornament fade
/// only for the caller-qualified, acknowledged newly inserted event.
struct WorkoutFinishConfetti: View {
    static let duration = 1.8
    /// Freak only: the caller has verified a personal record for this finish.
    var personalRecord = false

    /// The one-burst rule, decided at the finish's first appearance: a live,
    /// newly inserted save, outside Reduce Motion. The decision is then kept,
    /// so a later render never starts it, and a recovered or reconciled finish
    /// (never `presentsLive`) never has it.
    static func celebrates(latched: Bool?, presentsLive: Bool, reduceMotion: Bool) -> Bool {
        latched ?? (presentsLive && !reduceMotion)
    }

    /// Sampled at first appearance. A retained decision is never requalified
    /// by a later theme or Reduce Motion change. Event authority stays with
    /// the caller; non-Core Reduce Motion reaches the static renderer fade.
    static func celebrates(latched: Bool?, presentsLive: Bool, reduceMotion: Bool, designTheme: ZOTheme) -> Bool {
        latched ?? (presentsLive && (!reduceMotion || designTheme != .core))
    }

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false
    @State private var presentationTheme: ZeroOneThemeTokens?

    private var renderingTheme: ZeroOneThemeTokens { presentationTheme ?? theme }

    private var cleanupDeadline: Double {
        ThemeWinTimeline.cleanupDeadline(theme: renderingTheme.designTheme, tier: .major, reduceMotion: reduceMotion)
    }

    var body: some View {
        if !finished {
            TimelineView(.animation) { context in
                if let start {
                    let elapsed = context.date.timeIntervalSince(start)
                    ZStack(alignment: .top) {
                        ThemeWinRenderer(theme: renderingTheme, tier: .major,
                            elapsed: elapsed, reduceMotion: reduceMotion)
                        if personalRecord {
                            FreakRecordSlam(theme: renderingTheme, elapsed: elapsed, reduceMotion: reduceMotion)
                                .opacity(ThemeWinTimeline.wrapperOpacity(theme: renderingTheme.designTheme,
                                    elapsed: elapsed, reduceMotion: reduceMotion))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                presentationTheme = presentationTheme ?? theme
                start = start ?? .now
            }
            .task(id: cleanupDeadline) {
                // Live Reduce Motion can shorten the latched effect's remaining lifetime.
                let elapsed = start.map { Date.now.timeIntervalSince($0) } ?? 0
                do {
                    try await Task.sleep(for: .seconds(max(0, cleanupDeadline - elapsed)))
                } catch { return }
                guard !Task.isCancelled else { return }
                finished = true
            }
        }
    }
}

struct WorkoutCompletionUpgradeCard: View {
    private struct IndexedSavedSet: Identifiable {
        let index: Int
        let savedSet: CompletedSet

        var id: UUID { savedSet.id }
    }

    private enum RevealEvent {
        case bar(Int)
        case topLine
        case suggestedLoad
    }

    let upgrade: WorkoutCompletionUpgrade
    let selectedChoice: WorkoutLoadChoiceSelection?
    let motionEnabled: Bool?
    let workoutFullySaved: Bool
    let canChoose: Bool
    let onChoose: (WorkoutLoadChoiceSelection) -> Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var choiceError = false
    @State private var revealedBarCount = 0
    @State private var topLineDrawn = false
    @State private var suggestedLoadRevealed = false
    @State private var revealSkipped = false

    private var showsFinalLoad: Bool { motionEnabled != true || suggestedLoadRevealed }

    private func showsBar(at index: Int) -> Bool {
        motionEnabled != true || index < revealedBarCount
    }

    private var showsTopLine: Bool { motionEnabled != true || topLineDrawn }

    private var indexedSavedSets: [IndexedSavedSet] {
        upgrade.completedSets.enumerated().map { IndexedSavedSet(index: $0.offset, savedSet: $0.element) }
    }

    var body: some View {
        let valuesLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ZOSpace.s))
        let evidenceLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: ZOSpace.m))
        let choiceLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.s))

        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("UPGRADE OPTION")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)

            Text(upgrade.exerciseName)
                .zoText(.title)
                .accessibilityAddTraits(.isHeader)

            evidenceLayout {
                VStack(alignment: .leading, spacing: 3) {
                    Rectangle()
                        .fill(theme.textPrimary)
                        .frame(
                            width: CGFloat(upgrade.completedSets.count) * 17
                                + CGFloat(max(0, upgrade.completedSets.count - 1)) * ZOSpace.xs,
                            height: 2
                        )
                        .scaleEffect(x: showsTopLine ? 1 : 0, anchor: .leading)
                    HStack(alignment: .bottom, spacing: ZOSpace.xs) {
                        ForEach(indexedSavedSets) { indexedSet in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.textPrimary)
                                    .frame(width: 17, height: 44)
                                    .scaleEffect(y: showsBar(at: indexedSet.index) ? 1 : 0.02, anchor: .bottom)
                                Text(indexedSet.savedSet.reps.formatted())
                                    .zoText(.mini).monospacedDigit()
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    localization.format("Saved repetitions: %1$@", .text(upgrade.completedSets.map { String($0.reps) }.joined(separator: ", ")))
                )

                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("TOP OF THE RANGE · EVERY SET")
                        .zoText(.caption)
                        .foregroundStyle(theme.textPrimary)
                    Text(localization.format("All saved sets (%1$lld) reached %2$@ or more.", .integer(upgrade.completedSets.count), .text(workoutCopy.quantity(upgrade.targetRepUpperBound, .reps))))
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            valuesLayout {
                Text(workoutCopy.load(upgrade.opportunity.previousLoad))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "arrow.right")
                    .zoIcon(ZOIcon.row)
                    .accessibilityHidden(true)
                Text(showsFinalLoad
                     ? workoutCopy.load(upgrade.opportunity.suggestedLoad)
                     : workoutCopy.load(upgrade.opportunity.previousLoad))
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
            }
            .zoText(.metric)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                localization.format("Previous load %1$@. Suggested next load %2$@.", .text(workoutCopy.load(upgrade.opportunity.previousLoad)), .text(workoutCopy.load(upgrade.opportunity.suggestedLoad)))
            )

            Text("Every planned set reached the top of its rep range at one load. If form felt controlled, try the next load when this exercise comes around again. You can also repeat the previous load.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)

            choiceLayout {
                choiceButton(
                    title: localization.format("Plan %1$@", .text((workoutCopy.load(upgrade.opportunity.suggestedLoad)))),
                    selection: .tryNext
                )
                choiceButton(
                    title: localization.format("Keep %1$@", .text((workoutCopy.load(upgrade.opportunity.previousLoad)))),
                    selection: .repeatPrevious
                )
            }

            if choiceError {
                Text("Could not save your choice. Tap again to retry, or decide during your next workout.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else if !canChoose {
                Text(localization.string(workoutFullySaved
                     ? "Load choices are unavailable. Your workout is saved; you can still choose a load next time."
                     : "Load choices are unavailable. Your set is saved; you can still choose a load next time."))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else if selectedChoice != nil {
                Text("Choice saved on this iPhone. You can still edit the load before logging next time.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text("No choice saved yet. You can decide during your next workout.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .background(
            TrainingCompanionPalette.surface(for: theme.colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.card)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .task(id: motionEnabled) {
            guard motionEnabled == true else { return }
            try? await Task.sleep(for: .milliseconds(470))
            guard !Task.isCancelled, !revealSkipped else { return }

            var events: [(time: Int, event: RevealEvent)] = upgrade.completedSets.indices.map {
                (time: $0 * 70, event: .bar($0 + 1))
            }
            events.append((time: 120, event: .topLine))
            events.append((time: 440, event: .suggestedLoad))
            events.sort { $0.time < $1.time }

            var previousTime = 0
            for item in events {
                if item.time > previousTime {
                    try? await Task.sleep(for: .milliseconds(item.time - previousTime))
                }
                guard !Task.isCancelled, !revealSkipped else { return }
                switch item.event {
                case let .bar(count):
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) {
                        revealedBarCount = count
                    }
                case .topLine:
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) {
                        topLineDrawn = true
                    }
                case .suggestedLoad:
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)) {
                        suggestedLoadRevealed = true
                    }
                }
                previousTime = item.time
            }
        }
    }

    private func choiceButton(title: String, selection: WorkoutLoadChoiceSelection) -> some View {
        let isSelected = selectedChoice == selection
        return Button {
            revealSkipped = true
            revealedBarCount = upgrade.completedSets.count
            topLineDrawn = true
            suggestedLoadRevealed = true
            choiceError = !onChoose(selection)
        } label: {
            Text(title)
                .zoText(.section)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, ZOSpace.s)
                .foregroundStyle(isSelected ? theme.backgroundPrimary : theme.textPrimary)
                .background(
                    isSelected ? theme.textPrimary : theme.surfaceSecondary,
                    in: RoundedRectangle(cornerRadius: ZORadius.control)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canChoose)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WorkoutCompletionFrequency: View {
    let activity: WorkoutActivitySummary

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @Environment(\.colorScheme) private var colorScheme

    private var recentMonths: [WorkoutActivityMonth] {
        Array(activity.months.suffix(4))
    }

    private var largestMonthCount: Int {
        max(1, recentMonths.map(\.workoutCount).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("TRAINING THIS MONTH")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                Text(activity.thisMonthCount.formatted())
                    .zoText(.metric)
                Text(localization.string(activity.thisMonthCount == 1 ? "session" : "sessions"))
                    .zoText(.section)
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Text("Partial workouts count. Rest days do not reset anything.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)

            WorkoutMonthCalendar(activity: activity, calendar: .current)

            HStack(alignment: .bottom, spacing: ZOSpace.m) {
                ForEach(recentMonths) { month in
                    VStack(spacing: ZOSpace.xs) {
                        Text(month.workoutCount.formatted())
                            .zoText(.caption).monospacedDigit()
                        RoundedRectangle(cornerRadius: ZORadius.small)
                            .fill(theme.textPrimary)
                            .frame(height: max(4, 40 * CGFloat(month.workoutCount) / CGFloat(largestMonthCount)))
                        Text(month.start.formatted(.dateTime.month(.abbreviated).locale(localization.locale)))
                            .zoText(.mini)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localization.format("%1$@: %2$@", .text(month.start.formatted(.dateTime.month(.wide).year().locale(localization.locale))), .text(workoutCopy.quantity(month.workoutCount, .sessions))))
                }
            }
            .frame(height: 82, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.card)
        )
    }
}

struct WorkoutMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        ZeroOneStatTile(title: title.uppercased(), value: value, symbol: symbol)
    }
}

struct ZeroOneActiveExerciseStage: View {
    let artwork: ExerciseArtwork
    let height: CGFloat

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(red: 247 / 255, green: 246 / 255, blue: 241 / 255)

            if artwork.isAvailable {
                ExerciseGuidanceMotionView(artwork: artwork)
                    .frame(maxWidth: .infinity)
                    .frame(height: resolvedHeight)
                    .clipped()
            } else {
                unavailableVisual
                    .dynamicTypeSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: resolvedHeight)
        .clipShape(RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.control, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.string(accessibilityLabel))
    }

    private var unavailableVisual: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("EXERCISE GUIDE")
                .zoText(.caption)

                .foregroundStyle(.black.opacity(0.65))

            Spacer(minLength: ZOSpace.l)

            Text(artwork.exerciseName)
                .zoText(.title)
                .foregroundStyle(.black)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text("Visual guide unavailable. You can still log every set.")
                .zoText(.caption)
                .foregroundStyle(.black.opacity(0.65))
        }
        .padding(ZOSpace.l)
    }

    private var resolvedHeight: CGFloat {
        artwork.isAvailable ? height : min(height, 158)
    }

    private var accessibilityLabel: String {
        if artwork.isAvailable {
            return artwork.accessibilityDescription
        }
        return "Visual guide unavailable for \(artwork.exerciseName). You can still log every set."
    }
}

struct WorkoutSetInputGroup: View {
    @Binding var loadDraft: String
    let loadUnit: String
    let availableWidth: CGFloat
    var isTimed: Bool = false
    var perSide: Bool = false
    @Binding var repsDraft: String
    @Binding var isEditing: Bool
    let rir: Int?
    /// Kept for compatibility; the comparison card shows last time per set.
    let previousSetSummary: String
    let targetSummary: String
    let progressionCue: String
    let inputError: String?
    let onCommit: () -> Bool
    let decrementLoad: () -> Void
    let incrementLoad: () -> Void
    let decrementReps: () -> Void
    let incrementReps: () -> Void
    let decrementRIR: () -> Void
    let incrementRIR: () -> Void
    let startRIR: () -> Void
    let clearRIR: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @FocusState private var focusedField: InputField?
    @State private var showsEffort = false
    @State private var showsGuidance = false

    private enum InputField: Hashable { case load, reps }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            // The comparison card and coach line now carry last time's set
            // (proof 37); the target stays beside the values it applies to.
            Text(targetSummary)
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                loadControl
                Rectangle()
                    .fill(theme.strokeSubtle)
                    .frame(height: ZOStroke.hairline)
                    .accessibilityHidden(true)
                repsControl
            }

            if let inputError {
                Text(localization.string(inputError))
                    .zoText(.body)
                    .foregroundStyle(theme.warningPrimary)
                    .accessibilityIdentifier("workout.inputError")
            }

            if !isEditing {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        guidanceButton
                        if !isTimed { effortButton }
                    }
                } else {
                    HStack(spacing: ZOSpace.m) {
                        guidanceButton
                        if !isTimed { effortButton }
                    }
                }
                if showsGuidance {
                    Text(progressionCue)
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                if showsEffort && !isTimed { rirControl }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear { showsEffort = rir != nil }
        .onChange(of: focusedField) { _, field in
            isEditing = field != nil
            if field == nil { _ = onCommit() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Previous") { focusedField = .load }
                Button("Next") { focusedField = .reps }
                Spacer()
                Button("Done") {
                    if onCommit() { focusedField = nil }
                }
            }
        }
    }

    private var guidanceButton: some View {
        Button(localization.string(showsGuidance ? "Hide guidance" : "Load guidance")) {
            showsGuidance.toggle()
        }
        .zoText(.caption)
        .foregroundStyle(theme.textSecondary)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var effortButton: some View {
        Button(localization.string(showsEffort ? "Hide effort" : "Record effort (optional)")) {
            if showsEffort { clearRIR() }
            showsEffort.toggle()
        }
        .zoText(.caption)
        .foregroundStyle(theme.textSecondary)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var loadControl: some View {
        editableValue(label: "Load", text: $loadDraft, unit: loadUnit, shownUnit: loadUnit,
                      field: .load, decrement: decrementLoad, increment: incrementLoad)
    }

    private var repsControl: some View {
        editableValue(label: isTimed ? (perSide ? "Actual sec / side" : "Actual seconds") : (perSide ? "Reps / side" : "Reps"), text: $repsDraft, unit: isTimed ? "seconds" : "reps",
                      shownUnit: nil, field: .reps, decrement: decrementReps, increment: incrementReps)
    }

    private var rirControl: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("How many more clean reps could you do?")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text("This helps judge whether to progress or ease off. Skip it if you're unsure.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if let rir {
                primaryValue(
                    label: "CLEAN REPS LEFT",
                    value: String(rir),
                    unit: "reps left",
                    accessibilityValue: String(rir),
                    decrementLabel: "Decrease clean reps left",
                    incrementLabel: "Increase clean reps left",
                    decrement: decrementRIR,
                    increment: incrementRIR
                )
                Button("Not recorded", action: clearRIR)
                    .frame(minHeight: 44)
            } else {
                Text("Not recorded")
                    .foregroundStyle(theme.textSecondary)
                Button("Record 2 reps left", action: startRIR)
                    .frame(minHeight: 44)
            }
        }
    }

    /// Proof 37's value row: caption and the number with its unit on the
    /// left, minus and plus on the right. The number stays a real field, so
    /// typing still works; the steppers stay the one way to nudge it.
    private func editableValue(
        label: String, text: Binding<String>, unit: String, shownUnit: String?, field: InputField,
        decrement: @escaping () -> Void, increment: @escaping () -> Void
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ZOSpace.s))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string(label))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    TextField(field == .load ? localization.string("Set load") : localization.string(label), text: text)
                        .keyboardType(field == .load ? .decimalPad : .numberPad)
                        .focused($focusedField, equals: field)
                        .zoText(.metric)
                        .monospacedDigit()
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(field == .load ? localization.format("Weight, %1$@", .text(unit)) : localization.string(isTimed ? "Actual completed duration in seconds" : "Repetitions"))
                        .accessibilityIdentifier(field == .load ? "workout.loadInput" : (isTimed ? "workout.durationInput" : "workout.repsInput"))
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: increment()
                            case .decrement: decrement()
                            }
                        }
                    if let shownUnit {
                        Text(verbatim: shownUnit)
                            .zoText(.label)
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: ZOSpace.s) {
                adjustmentButton(systemImage: "minus", accessibilityLabel: localization.format("Decrease %1$@", .text(localization.string(label))), action: decrement)
                adjustmentButton(systemImage: "plus", accessibilityLabel: localization.format("Increase %1$@", .text(localization.string(label))), action: increment)
            }
        }
        .padding(.vertical, ZOSpace.s)
    }

    private func primaryValue(
        label: String,
        value: String,
        unit: String,
        accessibilityValue: String,
        decrementLabel: String,
        incrementLabel: String,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(localization.string(label))
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                valueText(value)
                unitText(localization.string(unit))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localization.string(accessibilityLabel(for: label)))
            .accessibilityValue(accessibilityValue)

            HStack(spacing: ZOSpace.xs) {
                adjustmentButton(systemImage: "minus", accessibilityLabel: decrementLabel, action: decrement)
                adjustmentButton(systemImage: "plus", accessibilityLabel: incrementLabel, action: increment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? ZOSpace.l : 0)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .zoText(.metric)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : ZeroOneMotion.standard, value: value)
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.82 : 0.58)
    }

    private func unitText(_ unit: String) -> some View {
        Text(localization.string(unit))
            .zoText(.label)


            .foregroundStyle(theme.textSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private func adjustmentButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoIcon(ZOIcon.row)
        }
        .buttonStyle(ZOButtonStyle(.step))
        .accessibilityLabel(localization.string(accessibilityLabel))
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(theme.strokeSubtle)
            .frame(height: 1)
    }

    private var verticalMetricDivider: some View {
        Rectangle()
            .fill(theme.strokeSubtle)
            .frame(width: 1, height: 154)
            .padding(.horizontal, ZOSpace.m)
    }

    private func accessibilityLabel(for label: String) -> String {
        switch label {
        case "LOAD": "Weight"
        case "REPS": "Repetitions"
        default: "Reps in reserve"
        }
    }
}

/// Study 09 strong-fill chip: ink on warm white, inverted in dark. Always text,
/// so the chip never carries meaning by colour alone.
struct WorkoutInkChip: View {
    let text: String

    var body: some View {
        ZOBadge(text: text, isInk: true)
    }
}

/// Proof 37's coach line: the 01 mark in a 28 pt ink disc and one or two
/// short sentences. Numbers are bold condensed tabular text at 1.14 em, never
/// a field, a button or a gain claim of their own. One VoiceOver element.
struct WorkoutCoachLineView: View {
    let lines: [WorkoutCoachLine]

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(theme.textPrimary)
                .frame(width: 28, height: 28)
                .overlay {
                    Image("ZeroOneWordmark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .padding(7)
                        .foregroundStyle(theme.backgroundPrimary)
                }
                // The proof sets the disc 4 pt into a 26 pt line box; SwiftUI
                // adds no leading above the first line, so half of that.
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    // Proof `.say.s`: 17/26; the dim secondary line is 500.
                    sentence(line)
                        .zoProofText(index == 0 ? .section : .body, size: 17, lineHeight: 26,
                                     weight: index == 0 ? 600 : 500)
                        .foregroundStyle(index == 0 ? theme.textPrimary : theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.map(\.plainText).joined(separator: " "))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("workout.coachLine")
    }

    private var numberFont: Font {
        let size = CTFontGetSize(ZOTextStyle.section.ctFont(for: dynamicTypeSize)) * 1.14
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(ZOTextStyle.metric.ctFont(for: dynamicTypeSize)), [
                kCTFontVariationAttribute: [0x77647468: 75, 0x77676874: 800]
            ] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return Font(font).monospacedDigit()
    }

    private func sentence(_ line: WorkoutCoachLine) -> Text {
        line.parts.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case let .text(value):
                return text + Text(verbatim: value)
            case let .emphasis(value):
                return text + Text(verbatim: value).font(numberFont).tracking(0.2)
            }
        }
    }
}

/// The upgrade offer sits in the console directly above the load it changes.
/// Pending: a card with the rule's reason and two equal choices. Chosen: a slim,
/// reversible row until set 1 is saved. The rule itself lives in the engine.
struct WorkoutProgressionOpportunitySection: View {
    let opportunity: WorkoutProgressionOpportunity
    let reason: String?
    let selectedLoadValue: Double
    let selection: WorkoutLoadChoiceSelection?
    let canChoose: Bool
    let onPrepare: () -> Void
    let onTry: () -> Void
    let onRepeat: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var showsRule = false

    var body: some View {
        Group {
            if let selection {
                slimRow(selection)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 6)))
            } else {
                card
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: selection)
        .sensoryFeedback(.impact(weight: .light), trigger: selection) { old, new in
            new == .tryNext && old != new
        }
        .onAppear(perform: onPrepare)
        .sheet(isPresented: $showsRule) {
            Group {
                WorkoutProgressionRuleSheet()
                .zeroOneTheme(theme)
            }
            .zoSheet(theme)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout.progressionOpportunity")
    }

    private var card: some View {
        let choiceLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.s))
        return VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(spacing: ZOSpace.s) {
                Text("UPGRADE AVAILABLE")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Button { showsRule = true } label: {
                    Image(systemName: "info.circle")
                        .zoIcon(ZOIcon.row)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .accessibilityLabel("How upgrade offers work")
            }
            .frame(minHeight: 32)

            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                Text(localization.format("%1$@ today", .text(workoutCopy.load(opportunity.suggestedLoad))))
                    .zoText(.title)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                WorkoutInkChip(text: "+" + workoutCopy.load(Load(opportunity.suggestedLoad.value - opportunity.previousLoad.value, unit: opportunity.suggestedLoad.unit)))
            }
            .accessibilityElement(children: .combine)

            if let reason {
                Text(reason)
                    .zoText(.label)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choiceLayout {
                Button(action: onTry) {
                    choiceLabel(localization.format("Try %1$@", .text((workoutCopy.load(opportunity.suggestedLoad)))))
                        .foregroundStyle(theme.backgroundPrimary)
                        .background(theme.textPrimary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sets 1 to the next load. You can switch back until set 1 is saved.")

                Button(action: onRepeat) {
                    choiceLabel(localization.format("Stay at %1$@", .text((workoutCopy.load(opportunity.previousLoad)))))
                        .foregroundStyle(theme.textPrimary)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.textPrimary.opacity(0.28), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keeps last time's load. Staying is a complete session.")
            }
            .disabled(!canChoose)
            .padding(.top, ZOSpace.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.m)
        .background(
            TrainingCompanionPalette.field(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private func slimRow(_ selection: WorkoutLoadChoiceSelection) -> some View {
        let chosen = selection == .tryNext ? opportunity.suggestedLoad : opportunity.previousLoad
        let edited = selectedLoadValue != chosen.value
        let status: String = {
            if edited {
                return localization.format("Set 1 at %1$@, edited", .text(workoutCopy.load(Load(selectedLoadValue, unit: chosen.unit))))
            }
            return selection == .tryNext
                ? localization.format("Upgrade on: %1$@", .text(workoutCopy.load(opportunity.suggestedLoad)))
                : localization.format("Staying at %1$@ today", .text(workoutCopy.load(opportunity.previousLoad)))
        }()
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ZOSpace.s))
        return layout {
            HStack(spacing: ZOSpace.s) {
                if selection == .tryNext && !edited {
                    WorkoutInkChip(text: "+" + workoutCopy.load(Load(opportunity.suggestedLoad.value - opportunity.previousLoad.value, unit: opportunity.suggestedLoad.unit)))
                }
                Text(status)
                    .zoText(.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(selection == .tryNext
                   ? localization.format("Use %1$@", .text((workoutCopy.load(opportunity.previousLoad))))
                   : localization.format("Try %1$@", .text((workoutCopy.load(opportunity.suggestedLoad))))) {
                if selection == .tryNext { onRepeat() } else { onTry() }
            }
            .zoText(.label)
            .foregroundStyle(theme.textPrimary)
            .underline()
            .frame(minHeight: 44)
            .buttonStyle(.plain)
            .disabled(!canChoose)
        }
        .padding(.horizontal, ZOSpace.m)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(
            TrainingCompanionPalette.field(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func choiceLabel(_ title: String) -> some View {
        Text(title)
            .zoText(.section)
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, ZOSpace.s)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The one fixed rule, stated as the engine applies it.
private struct WorkoutProgressionRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    private let rules = [
        "When every planned set last time reached the top of its rep range at one load, and no set was logged as near your limit, 01 offers the smallest load step for that exercise.",
        "Steps: 2.5 kg (5 lb) for most exercises, 5 kg (10 lb) for leg exercises. Bodyweight exercises have no load step.",
        "It's an offer. Staying at your current load is a complete session.",
        "Fewer reps after a step up are expected. Nothing resets, and there's no streak to break."
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    Text("How upgrade offers work")
                        .zoText(.title)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("One fixed rule, applied the same way every time.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                    ForEach(rules, id: \.self) { rule in
                        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                            Text("•").accessibilityHidden(true)
                            Text(localization.string(rule)).fixedSize(horizontal: false, vertical: true)
                        }
                        .zoText(.body)
                        .foregroundStyle(theme.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ZOSpace.xl)
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button("Got it") { dismiss() }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .padding(ZOSpace.l)
                    .background(theme.backgroundPrimary)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(theme.colorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct WorkoutEndSheet: View {
    let copy: WorkoutEndConfirmationCopy
    let localizedMessage: String
    let savedSetCount: Int
    let plannedSetCount: Int
    let canFinish: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text(localization.string(copy.title))
                    .zoText(.title)
                    .accessibilityAddTraits(.isHeader)
                if savedSetCount > 0 {
                    HStack(spacing: ZOSpace.s) {
                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                        Text(workoutCopy.savedProgress(savedSetCount, of: plannedSetCount))
                            .zoText(.section)
                    }
                    Text(localization.string(savedSetCount == plannedSetCount
                         ? "This workout will be saved to History as Complete."
                         : "This workout will be saved to History as Partial. Unlogged sets stay unlogged."))
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                Text(localizedMessage)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                if !canFinish {
                    Text("Return to your workout and retry saving before ending it.")
                        .zoText(.section)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ZOSpace.l)
            .padding(.top, ZOSpace.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: ZOSpace.s) {
                Button(localization.string(copy.confirmTitle), action: onConfirm)
                    .buttonStyle(ZOButtonStyle(.primary))
                    .disabled(!canFinish)
                Button(localization.string(copy.cancelTitle), action: onCancel)
                    .zoText(.section)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .padding(.horizontal, ZOSpace.l)
            .padding(.bottom, ZOSpace.s)
            .background(theme.backgroundPrimary)
        }
        .foregroundStyle(theme.textPrimary)
        .background(theme.backgroundPrimary)
        .accessibilityIdentifier("workout.endSheet")
    }
}

/// The next-exercise card's poster and title travel into the demonstration
/// and headline. The title carries position only; its size change is a
/// scale, never a font-size tween, so text does not re-lay out per frame.
struct WorkoutExerciseCarrier: ViewModifier {
    enum Part: Hashable {
        case media
        case title
    }

    enum Site: Hashable {
        case nextCard
        case header
    }

    private struct Key: Hashable {
        let exerciseID: UUID
        let part: Part
        let inertSite: Site?
    }

    let exerciseID: UUID
    var part: Part = .media
    let site: Site
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        // Always applied, so switching accessibility modes never rebuilds the
        // carried view. A disabled carrier gets a site-only key with no partner.
        content.matchedGeometryEffect(
            id: Key(exerciseID: exerciseID, part: part, inertSite: enabled ? nil : site),
            in: namespace,
            properties: part == .title ? .position : .frame,
            anchor: part == .title ? .topLeading : .center
        )
    }
}

/// The card title and the header title are both proof 37's 24 pt title, so
/// the carried title moves by position alone.
enum WorkoutHandoffTitle {
    static let cardToHeadlineScale: CGFloat = 1
}

/// Presses brace to 98% with motion; nothing moves otherwise.

struct WorkoutNextExerciseCard: View {
    let preview: WorkoutNextExercisePreview
    let namespace: Namespace.ID
    let motionEnabled: Bool
    let onStart: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if preview.canStart {
                Button(action: onStart) { upNext }
                    .buttonStyle(ZOPressStyle(motionEnabled: motionEnabled))
                    .accessibilityLabel(localization.format("Start %1$@", .text(preview.exercise.plan.name)))
                    .accessibilityHint("Ends rest and opens the first set. No set is logged.")
            } else {
                content
                    .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("workout.nextExerciseCard")
    }

    /// Proof 37's next exercise: the poster with an "Up next" tag, then the
    /// name as a title. The ghost card that follows is the caller's. Both
    /// carry into the workout header when the exercise starts.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let match = MoveKitExerciseCatalog.match(for: preview.exercise.plan.exerciseID) {
                WorkoutHandoffPoster(exercise: match.exercise, pointWidth: 393)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.card))
                    .modifier(WorkoutExerciseCarrier(
                        exerciseID: preview.exercise.id, site: .nextCard, namespace: namespace,
                        enabled: motionEnabled
                    ))
                    .overlay(alignment: .bottomLeading) { upNextTag.padding(10) }
                    .accessibilityHidden(true)
            } else {
                Text(localization.string("Up next"))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Text(preview.exercise.plan.name)
                .zoText(.title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(WorkoutExerciseCarrier(
                    exerciseID: preview.exercise.id, part: .title, site: .nextCard,
                    namespace: namespace, enabled: motionEnabled
                ))
        }
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Proof `.zo-media.pose .tag`: onyx in both appearances, like the
    /// poster it sits on, never the accent.
    private var upNextTag: some View {
        HStack(spacing: ZOSpace.xs) {
            Image(systemName: "play.fill")
                .zoIcon(ZOIcon.inline)
            Text(localization.string("Up next"))
                .zoText(.mini)
        }
        .foregroundStyle(Color(zoHex: 0xF7F6F1))
        .padding(.horizontal, ZOSpace.s)
        .frame(height: ZOSpace.xxl)
        .background(Color(zoHex: 0x020202), in: Capsule())
    }

    /// The compact preview while sets of this exercise remain.
    private var content: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.m))
        return layout {
            if let match = MoveKitExerciseCatalog.match(for: preview.exercise.plan.exerciseID) {
                WorkoutHandoffPoster(exercise: match.exercise)
                    .frame(width: 88, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: ZORadius.small))
                    .modifier(WorkoutExerciseCarrier(
                        exerciseID: preview.exercise.id, site: .nextCard, namespace: namespace,
                        enabled: motionEnabled && preview.canStart
                    ))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.string(preview.caption.uppercased()))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(preview.exercise.plan.name)
                    .zoText(.section)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(WorkoutExerciseCarrier(
                        exerciseID: preview.exercise.id, part: .title, site: .nextCard,
                        namespace: namespace, enabled: motionEnabled && preview.canStart
                    ))
                Text(localization.format("%1$@ · %2$@ × %3$@", .text(workoutCopy.quantity(preview.exercise.plan.plannedSetCount, .sets)), .text(loadDescription), .text(workoutCopy.prescription(preview.exercise.plan.prescription))))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if preview.canStart {
                Image(systemName: "arrow.up.right")
                    .zoIcon(ZOIcon.row)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(ZOSpace.m)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: ZORadius.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.control)
                .strokeBorder(TrainingCompanionPalette.stroke(for: colorScheme), lineWidth: 1)
        }
    }

    private var loadDescription: String {
        let plan = preview.exercise.plan
        if plan.targetLoad.value > 0 { return workoutCopy.load(plan.targetLoad) }
        return localization.string(plan.allowsZeroLoad ? "Bodyweight" : "Choose load")
    }
}

private struct WorkoutHandoffPoster: View {
    let exercise: MoveKitExercise
    /// The widest the poster is drawn, for the decoded pixel size.
    var pointWidth: CGFloat = 88
    @Environment(\.displayScale) private var displayScale
    @State private var poster: UIImage?

    private var pixelSize: Int { max(1, Int((pointWidth * displayScale).rounded(.up))) }

    var body: some View {
        ZStack {
            Color(red: 247 / 255, green: 246 / 255, blue: 241 / 255)
            if let poster {
                Image(uiImage: poster).resizable().scaledToFit()
            }
        }
        .task(id: "\(exercise.posterResource):\(pixelSize)") {
            poster = nil
            let loaded = await CustomWorkoutPosterStore.shared.image(
                for: exercise.posterResource, maxPixel: pixelSize
            )
            guard !Task.isCancelled else { return }
            poster = loaded ?? UIImage(named: exercise.posterResource)
        }
    }
}

/// Study 18 curves. No bounce anywhere in the workout.
enum WorkoutMotion {
    /// Arrivals: fast in, dead stop.
    static func land(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.9, 0.25, 1, duration: duration)
    }

    /// Exits accelerate away and never linger.
    static func leave(_ duration: Double) -> Animation {
        .timingCurve(0.4, 0, 1, 1, duration: duration)
    }

    /// Travel: heavy start, long settle.
    static func carry(_ duration: Double) -> Animation {
        .timingCurve(0.35, 0, 0.1, 1, duration: duration)
    }

    /// Presses.
    static func brace(_ duration: Double) -> Animation {
        .timingCurve(0.45, 0, 0.55, 1, duration: duration)
    }
}

/// A block that rises into place after a commit. With motion off it only
/// changes opacity, and with `animation` nil it appears at once.
struct WorkoutRise: ViewModifier {
    let visible: Bool
    let distance: CGFloat
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : distance)
            .animation(animation, value: visible)
    }
}

/// Latches at first appearance whether an entrance is live. Later renders can
/// neither cut the entrance short nor replay it after recovery.
struct WorkoutEntranceLatch<Content: View>: View {
    @State private var visible: Bool
    private let content: (Bool) -> Content

    init(animated: Bool, @ViewBuilder content: @escaping (_ visible: Bool) -> Content) {
        _visible = State(initialValue: !animated)
        self.content = content
    }

    var body: some View {
        content(visible)
            .onAppear { visible = true }
    }
}

/// Study 18's session record. As a 6 pt rail it sits under the workout's top
/// bar; as a 44 pt grid it is the saved summary. The same segment IDs let the
/// rail become the grid when a live finish is saved.
struct WorkoutSessionRail: View {
    enum Style {
        case rail
        case grid
    }

    let rail: WorkoutSetRail
    let style: Style
    let namespace: Namespace.ID
    let carriesSegments: Bool
    let motionEnabled: Bool

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    var body: some View {
        let segmentGap: CGFloat = style == .rail ? 2 * ZOStroke.hairline : 3 * ZOStroke.hairline
        let exerciseGap: CGFloat = style == .rail ? ZOSpace.xs + 2 * ZOStroke.hairline : ZOSpace.s
        // Every segment is equally wide, so each exercise's share follows its
        // planned set count; fixed spacers separate exercises.
        HStack(spacing: segmentGap) {
            ForEach(rail.segments) { segment in
                if segment.setNumber == 1, segment.id != rail.segments.first?.id {
                    Color.clear.frame(width: exerciseGap - segmentGap)
                }
                self.segment(segment)
            }
        }
        .frame(height: style == .rail ? ZOStroke.railApp : ZOSpace.hitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workoutCopy.savedProgress(rail.savedCount, of: rail.segments.count, working: true))
    }

    private func segment(_ segment: WorkoutSetRail.Segment) -> some View {
        let mark: ZORailSegment.Mark = segment.mark == .saved ? .saved : (segment.mark == .current ? .current : .ahead)
        return ZORailSegment(mark: mark,
            radius: style == .rail ? 2 * ZOStroke.hairline : ZOSpace.xs,
            motionEnabled: motionEnabled)
            .modifier(WorkoutRailSegmentCarrier(
                id: segment.id, namespace: namespace, enabled: carriesSegments
            ))
    }
}

private struct WorkoutRailSegmentCarrier: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        // Always applied so identity is stable; disabled segments get a key
        // with no partner and therefore never travel.
        content.matchedGeometryEffect(id: enabled ? id : "inert-\(id)", in: namespace)
    }
}

/// The stable primary-action slot survives log -> rest -> entry. Its shape
/// changes only after the model exposes a successfully persisted state.
struct WorkoutPrimaryDock: View {
    let action: WorkoutPrimaryAction
    let savedSetNumber: Int?
    /// Changes once per live, acknowledged save. Recovery never changes it,
    /// so the saved confirmation cannot replay.
    let confirmationTrigger: Int
    /// The commit being rendered, for its delays; `.steady` afterwards.
    let commit: WorkoutDockTransition
    let motionEnabled: Bool
    /// Proof 37 repeats the entered values on Log ("Log 16 kg × 11"). The
    /// caller passes it only when the drafts parse to the values Log commits.
    var logSummary: String? = nil
    let onActivate: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    private var fold: CGFloat { action.isResting ? 1 : 0 }

    private var showsConfirmation: Bool { motionEnabled && scenePhase == .active }

    /// While resting the label slot holds the saved confirmation; it is seen
    /// only during the keyframes that follow an acknowledged save.
    private var labelText: String {
        if case .logSet = action, let logSummary {
            return localization.format("Log %1$@", .text(logSummary))
        }
        guard action.isResting else { return workoutCopy.primaryTitle(action) }
        return "✓ " + workoutCopy.savedSet(savedSetNumber)
    }

    /// VoiceOver keeps the set number when the label shows the values.
    private var accessibilityText: String {
        if case .logSet = action, let logSummary {
            return localization.format("%1$@, %2$@", .text(workoutCopy.primaryTitle(action)), .text(logSummary))
        }
        return labelText
    }

    /// "Saved" is said first; the fold starts at 240 ms and takes 360 ms.
    /// The line grows back at once, or from 240 ms when a new exercise lands.
    private var foldAnimation: Animation {
        guard motionEnabled else { return .easeOut(duration: 0.18) }
        if action.isResting { return WorkoutMotion.carry(0.36).delay(0.24) }
        return WorkoutMotion.carry(0.36).delay(commit == .handoff ? 0.24 : 0)
    }

    private var labelTransition: AnyTransition {
        guard motionEnabled else { return .opacity.animation(.easeOut(duration: 0.18)) }
        let insertion: AnyTransition = action.isResting
            ? .identity
            : .opacity.combined(with: .offset(y: 10))
                .animation(WorkoutMotion.land(0.18).delay(commit == .handoff ? 0.36 : 0.18))
        return .asymmetric(
            insertion: insertion,
            removal: .opacity.combined(with: .offset(y: -10)).animation(WorkoutMotion.leave(0.12))
        )
    }

    var body: some View {
        Button(action: onActivate) {
            ZStack {
                Text(labelText)
                    .zoText(.section)
                    .foregroundStyle(theme.onAccent)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .keyframeAnimator(
                        initialValue: WorkoutDockConfirmationFrame(),
                        trigger: confirmationTrigger
                    ) { content, frame in
                        content
                            .opacity(action.isResting ? (showsConfirmation ? frame.opacity : 0) : 1)
                            .offset(y: action.isResting && showsConfirmation ? frame.offset : 0)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.03)
                            CubicKeyframe(1, duration: 0.18)
                            LinearKeyframe(1, duration: 0.03)
                            CubicKeyframe(0, duration: 0.12)
                        }
                        KeyframeTrack(\.offset) {
                            MoveKeyframe(10)
                            LinearKeyframe(10, duration: 0.03)
                            CubicKeyframe(0, duration: 0.18)
                        }
                    }
                    .id(action.isResting ? (savedSetNumber.map { "saved.\($0)" } ?? "saved") : action.title)
                    .transition(labelTransition)
            }
            .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight)
            .padding(.horizontal, ZOSpace.xl)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? ZOSpace.s : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.isResting)
        .accessibilityHidden(action.isResting)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(localization.string(action.accessibilityHint))
        .accessibilityIdentifier("workout.primaryAction")
        // The label owns the height. A sibling Shape accepts all offered height
        // and can consume the workout's safe-area inset, hiding content and Exit.
        .background(alignment: .bottom) { background }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("workout.primaryDock")
    }

    @ViewBuilder
    private var background: some View {
        if motionEnabled {
            ZStack(alignment: .bottom) {
                WorkoutDockFoldShape(fold: fold)
                    .fill(theme.surfaceTertiary)
                WorkoutDockFoldShape(fold: fold)
                    .fill(theme.accentFill)
                    .overlay {
                        WorkoutDockFoldShape(fold: fold)
                            .strokeBorder(theme.accentPreference.swatch.edge(in: theme.colorScheme), lineWidth: ZOStroke.hairline)
                    }
                    .mask { restFillMask }
            }
            .animation(foldAnimation, value: action.isResting)
        } else {
            ZStack(alignment: .bottom) {
                if action.isResting {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ZORestLine(progress: action.remainingFraction(at: context.date))
                            .transaction { $0.animation = nil }
                    }
                    .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: ZORadius.button, style: .continuous)
                        .fill(theme.accentFill)
                        .overlay {
                            if colorScheme == .light {
                                RoundedRectangle(cornerRadius: ZORadius.button, style: .continuous)
                                    .strokeBorder(theme.accentPreference.swatch.edge(in: theme.colorScheme), lineWidth: ZOStroke.hairline)
                            }
                        }
                        .transition(.opacity)
                }
            }
            .animation(foldAnimation, value: action.isResting)
        }
    }

    @ViewBuilder
    private var restFillMask: some View {
        if motionEnabled {
            TimelineView(.animation(paused: !action.isResting || scenePhase != .active)) { context in
                Rectangle()
                    .scaleEffect(x: action.remainingFraction(at: context.date), anchor: .leading)
                    .transaction { $0.animation = nil }
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Rectangle()
                    .scaleEffect(x: action.remainingFraction(at: context.date), anchor: .leading)
                    .transaction { $0.animation = nil }
            }
        }
    }
}

private struct WorkoutDockConfirmationFrame {
    var opacity = 0.0
    var offset: CGFloat = 10
}

struct WorkoutDockFoldShape: InsettableShape {
    var fold: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    func inset(by amount: CGFloat) -> WorkoutDockFoldShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let amount = min(1, max(0, fold))
        let height = rect.height + (min(ZOStroke.restLine, rect.height) - rect.height) * amount
        let radius = ZORadius.button + (ZOStroke.restLine / 2 - ZORadius.button) * amount
        return Path(roundedRect: CGRect(
            x: rect.minX + insetAmount, y: rect.maxY - height + insetAmount,
            width: max(0, rect.width - 2 * insetAmount), height: max(0, height - 2 * insetAmount)
        ), cornerRadius: max(0, radius - insetAmount))
    }
}

struct RestTimerPanel: View {
    let availableHeight: CGFloat
    let remainingSeconds: Int
    let totalSeconds: Int
    let nextSetSummary: String
    let nextExerciseName: String
    let savedSet: CompletedSet?
    let savedSetNumber: Int?
    let targetReps: RepRange
    let response: WorkoutSetResponse?
    let guidance: SetEffortGuidance?
    let selectedNextLoad: Load
    let canChooseNextLoad: Bool
    let nextActionTitle: String
    let canAdvance: Bool
    /// True only when this panel appears because a set was just saved in the
    /// foreground with motion allowed. Latched at first appearance.
    let staggerEntrance: Bool
    /// True when the workout's coach line already states the saved set's
    /// comparison; the panel then keeps only the next-load choice's note.
    var coachLineShown = false
    /// Which part of the rest moment to draw. `.full` is the original single
    /// panel. Proof 37 places the parts apart: the clock in the scroll under
    /// the coach line, the saved-set details below the bars, and the early
    /// start under the dock's rest line.
    var part: Part = .full
    let onAddTime: () -> Void
    let onSubtractTime: () -> Void
    let onUndo: (UUID) -> Void
    let onSkip: () -> Void
    let onSelectNextLoad: (Load) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    enum Part {
        case full
        /// "Rest", the hero clock, then −15 s and +15 s, centred.
        case clock
        /// The saved set with Undo, its note and next-load choice, effort
        /// guidance and the next set. Secondary: the coach line and bars
        /// above already carry the moment.
        case details
        /// The early start, quiet, under the rest line. Hidden once rest ends,
        /// when the dock itself offers the start.
        case startNow
    }

    var body: some View {
        switch part {
        case .full:
            fullPanel
        case .clock:
            WorkoutEntranceLatch(animated: staggerEntrance) { visible in
                clock
                    .modifier(rise(visible, at: 0.18, distance: 12))
            }
        case .details:
            WorkoutEntranceLatch(animated: staggerEntrance) { visible in
                secondaryDetails(visible: visible)
            }
        case .startNow:
            if remainingSeconds > 0 {
                Button(localization.format("%1$@ now", .text(nextActionTitle)), action: onSkip)
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .frame(maxWidth: .infinity)
                    .disabled(!canAdvance)
                    .accessibilityHint(localization.string(nextActionHint))
                    .accessibilityIdentifier("workout.restStartNow")
            }
        }
    }

    private var fullPanel: some View {
        VStack(spacing: ZOSpace.m) {
            WorkoutEntranceLatch(animated: staggerEntrance) { visible in
                if dynamicTypeSize.isAccessibilitySize || availableHeight < 600 {
                    ScrollView(.vertical) {
                        restDetails(visible: visible)
                            .padding(.horizontal, ZOSpace.xs)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: max(120, availableHeight * 0.4))
                    .accessibilityIdentifier("workout.scrollableRestDetails")
                } else {
                    restDetails(visible: visible)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ZOSpace.m)
        .background(
            TrainingCompanionPalette.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 26)
        )
    }

    /// Study 18 after a save: the saved line lands at 120 ms, then the timer,
    /// controls and next context at 180, 240 and 300 ms.
    private func rise(_ visible: Bool, at delay: Double, distance: CGFloat = 10) -> WorkoutRise {
        WorkoutRise(visible: visible, distance: distance, animation: WorkoutMotion.land(0.24).delay(delay))
    }

    private func restDetails(visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let savedSet {
                savedSetDetails(savedSet)
                    .modifier(rise(visible, at: 0.12))
            }

            clock
                .modifier(rise(visible, at: 0.18, distance: 12))

            if remainingSeconds > 0 {
                Button(localization.format("%1$@ now", .text(nextActionTitle)), action: onSkip)
                    .zoText(.section)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .disabled(!canAdvance)
                    .accessibilityHint(localization.string(nextActionHint))
                    .modifier(rise(visible, at: 0.24, distance: 12))
            }

            nextContext
                .modifier(rise(visible, at: 0.30, distance: 12))
        }
    }

    /// Proof 37: "Rest", the hero clock, then −15 s and +15 s, centred.
    private var clock: some View {
        VStack(spacing: ZOSpace.s) {
            countdown
            if remainingSeconds > 0 { restAdjustments }
        }
        .frame(maxWidth: .infinity)
    }

    /// The panel's own facts and choices, below the bars. Nothing here is
    /// new: Undo, the response note, the next-load choice, effort guidance
    /// and the next set keep their existing sources and actions.
    private func secondaryDetails(visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let savedSet {
                savedSetDetails(savedSet)
                    .modifier(rise(visible, at: 0.30))
            }
            nextContext
                .modifier(rise(visible, at: 0.36, distance: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Effort guidance, then the next set.
    private var nextContext: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let guidance { setGuidance(guidance) }

            HStack(spacing: ZOSpace.xs) {
                Text("Next")
                    .zoText(.section)
                Text(nextSetSummary)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localization.format("Next set, %1$@, %2$@", .text(nextExerciseName), .text(nextSetSummary)))
        }
    }

    private func savedSetDetails(_ savedSet: CompletedSet) -> some View {
        let matchingResponse = response?.id == savedSet.id ? response : nil
        let gainChip = matchingResponse.flatMap { workoutCopy.gainChip($0) }
        let setTitle = workoutCopy.savedSet(savedSetNumber)
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(spacing: ZOSpace.s) {
                Image(systemName: "checkmark.circle.fill")
                    .zoIcon(ZOIcon.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(setTitle)
                        .zoText(.section)
                    Text("\(workoutCopy.load(savedSet.load)) · \(workoutCopy.performance(savedSet))")
                        .zoText(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                // The note below states the same gain in words, so the chip
                // can yield its width at accessibility sizes.
                if let gainChip, !dynamicTypeSize.isAccessibilitySize {
                    WorkoutInkChip(text: gainChip)
                        .accessibilityHidden(true)
                }
                Button("Undo") { onUndo(savedSet.id) }
                    .zoText(.section)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!canAdvance)
                    .accessibilityLabel(savedSetNumber.map { localization.format("Undo set %1$lld", .integer($0)) } ?? localization.string("Undo set"))
                    .accessibilityHint("Removes this set and restores its numbers for editing.")
            }
            .padding(ZOSpace.s)
            .background(
                TrainingCompanionPalette.field(for: colorScheme),
                in: RoundedRectangle(cornerRadius: ZORadius.control)
            )

            if let matchingResponse,
               !coachLineShown || (matchingResponse.offersNextSetLoadChoice && canChooseNextLoad) {
                let showsChoice = matchingResponse.offersNextSetLoadChoice && canChooseNextLoad
                Text(workoutCopy.responseNote(
                    for: matchingResponse, targetReps: targetReps, offersNextLoadChoice: showsChoice
                ))
                .zoText(.body)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("workout.savedSetResponse")
                if showsChoice {
                    nextLoadChoice(for: matchingResponse)
                }
            }
        }
    }

    private var countdown: some View {
        VStack(alignment: .center, spacing: ZOSpace.xs) {
            Text(localization.string(statusTitle))
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if totalSeconds > 0 {
                Text(Self.formattedDuration(remainingSeconds))
                    .zoText(.timerHero)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.string(remainingSeconds > 0 ? "Rest time remaining" : "Ready for the next set"))
        .accessibilityValue(remainingSeconds > 0 ? workoutCopy.duration(remainingSeconds) : "")
    }

    private func nextLoadChoice(for response: WorkoutSetResponse) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ZOSpace.s))
            : AnyLayout(HStackLayout(spacing: ZOSpace.s))
        return VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("NEXT SET LOAD")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            layout {
                nextLoadButton(title: localization.format("Keep %1$@", .text((workoutCopy.load(response.savedSet.load)))), load: response.savedSet.load)
                nextLoadButton(title: localization.format("Use %1$@", .text((workoutCopy.load(response.previousSet.load)))), load: response.previousSet.load)
            }
            Text("You can still edit the load before logging the next set.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityIdentifier("workout.nextSetLoadChoice")
    }

    private func nextLoadButton(title: String, load: Load) -> some View {
        let selected = selectedNextLoad == load
        return Button { onSelectNextLoad(load) } label: {
            HStack(spacing: ZOSpace.xs) {
                Text(title)
                    .lineLimit(2)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .zoText(.section)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, ZOSpace.s)
            .foregroundStyle(selected ? theme.backgroundPrimary : theme.textPrimary)
            .background(
                selected ? theme.textPrimary : theme.surfacePrimary,
                in: RoundedRectangle(cornerRadius: ZORadius.control)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canAdvance)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusTitle: String {
        if remainingSeconds > 0 { return "Rest" }
        return totalSeconds > 0
            ? "Rest done. Start when ready."
            : "Set saved. Start when ready."
    }

    private var nextActionHint: String {
        guard canAdvance else { return "Retry saving your workout before continuing." }
        return remainingSeconds > 0
            ? "Ends rest early and opens the next set or exercise."
            : "Opens the next set or exercise when you are ready."
    }

    /// Proof `.zo-adjust`: two outlined chips, at least 72 pt wide, 8 pt apart.
    private var restAdjustments: some View {
        HStack(spacing: ZOSpace.s) {
            Button(action: onSubtractTime) {
                Text("−15 s").frame(minWidth: 72 - 2 * ZOSpace.l)
            }
            .accessibilityHint("Removes up to fifteen seconds from rest. It will not start the next set.")
            Button(action: onAddTime) {
                Text("+15 s").frame(minWidth: 72 - 2 * ZOSpace.l)
            }
            .accessibilityHint("Adds fifteen seconds to rest.")
        }
        .buttonStyle(ZOChipStyle(isSelected: false))
        .disabled(!canAdvance)
    }

    private func setGuidance(_ guidance: SetEffortGuidance) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Image(systemName: guidanceSymbol(for: guidance.kind))
                .zoIcon(ZOIcon.inline)
                .foregroundStyle(guidanceTint(for: guidance.kind))
                .frame(width: 30, height: 30)
                .background(theme.surfaceSecondary, in: Circle())

            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(localization.string(guidance.title))
                    .zoText(.caption)

                    .foregroundStyle(guidanceTint(for: guidance.kind))

                Text(workoutCopy.effortInstruction(guidance, savedReps: savedSet?.reps, target: targetReps))
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.string(guidance.title))
        .accessibilityValue(workoutCopy.effortInstruction(guidance, savedReps: savedSet?.reps, target: targetReps))
    }

    private func guidanceSymbol(for kind: SetEffortGuidanceKind) -> String {
        switch kind {
        case .limitReached:
            return "hand.raised.fill"
        case .nearLimit:
            return "arrow.down.right"
        case .onTarget:
            return "checkmark"
        case .capacityAvailable:
            return "arrow.up.right"
        }
    }

    private func guidanceTint(for kind: SetEffortGuidanceKind) -> Color {
        switch kind {
        case .limitReached, .nearLimit:
            return theme.warningPrimary
        case .onTarget:
            return theme.accentForeground
        case .capacityAvailable:
            return ZeroOneColors.titanium
        }
    }

    private static func formattedDuration(_ totalSeconds: Int) -> String {
        String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func accessibleDuration(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes) minutes, \(seconds) seconds"
    }
}

private struct WorkoutStepUpAnimationValues {
    var height: CGFloat = 56
    var cornerRadius: CGFloat = 16
    var textOpacity: Double = 0
    var headlineOpacity: Double = 0
    var savedResultOpacity: Double = 0
    var comparisonOpacity: Double = 0
    var undoOpacity: Double = 0
    var textOffset: CGFloat = 28
    var bandOpacity: Double = 1
}

/// A one-shot, skippable celebration of a confirmed saved set, not a save affordance.
struct WorkoutStepUpBand: View {
    let moment: WorkoutSetProgressMoment
    let setNumber: Int
    let canUndo: Bool
    let onUndo: (UUID) -> Void
    let onDismiss: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }
    @State private var animationTrigger = 0

    var body: some View {
        Color.clear.keyframeAnimator(
            initialValue: WorkoutStepUpAnimationValues(),
            trigger: animationTrigger
        ) { _, values in
            ZStack(alignment: .bottom) {
                Button(action: onDismiss) {
                    VStack(spacing: ZOSpace.xs) {
                        // The band opens by restating the fact it celebrates:
                        // this set is already saved.
                        Label(workoutCopy.savedSet(setNumber), systemImage: "checkmark")
                            .zoText(.label).labelStyle(ZOIconLabelStyle())
                            .opacity(values.textOpacity)
                        Text(workoutCopy.momentHeadline(moment))
                            .zoText(.display)

                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .opacity(values.headlineOpacity)
                        Text("\(workoutCopy.load(moment.savedSet.load)) · \(workoutCopy.performance(moment.savedSet))")
                            .zoText(.section)
                            .opacity(values.savedResultOpacity)
                        Text(localization.format("Up from %1$@ last time.", .text(workoutCopy.setSummary(moment.previousSet))))
                            .zoText(.section)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .opacity(values.comparisonOpacity)
                    }
                    .foregroundStyle(Color.black)
                    .offset(y: values.textOffset)
                    .padding(.horizontal, ZOSpace.m)
                    .padding(.bottom, canUndo ? 48 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: values.height)
                    .background(theme.accentFill, in: RoundedRectangle(cornerRadius: values.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: values.cornerRadius)
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: values.cornerRadius))
                    .opacity(values.bandOpacity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip Step Up animation")

                if canUndo {
                    Button("Undo set", systemImage: "arrow.uturn.backward") {
                        onUndo(moment.id)
                    }
                    .zoText(.section)
                    .foregroundStyle(Color.black)
                    .frame(minHeight: 44)
                    .padding(.bottom, ZOSpace.s)
                    .opacity(values.undoOpacity)
                    .allowsHitTesting(values.undoOpacity > 0.9)
                }
            }
        } keyframes: { _ in
                KeyframeTrack(\.height) {
                    CubicKeyframe(248, duration: 0.22)
                    LinearKeyframe(248, duration: 0.68)
                    CubicKeyframe(56, duration: 0.36)
                }
                KeyframeTrack(\.cornerRadius) {
                    CubicKeyframe(24, duration: 0.22)
                    LinearKeyframe(24, duration: 0.68)
                    CubicKeyframe(16, duration: 0.36)
                }
                KeyframeTrack(\.textOpacity) {
                    LinearKeyframe(0, duration: 0.06)
                    CubicKeyframe(1, duration: 0.24)
                    LinearKeyframe(1, duration: 0.60)
                    CubicKeyframe(0, duration: 0.12)
                    LinearKeyframe(0, duration: 0.24)
                }
                KeyframeTrack(\.headlineOpacity) {
                    LinearKeyframe(0, duration: 0.06)
                    CubicKeyframe(1, duration: 0.24)
                    LinearKeyframe(1, duration: 0.60)
                    CubicKeyframe(0, duration: 0.12)
                    LinearKeyframe(0, duration: 0.24)
                }
                KeyframeTrack(\.savedResultOpacity) {
                    LinearKeyframe(0, duration: 0.11)
                    CubicKeyframe(1, duration: 0.24)
                    LinearKeyframe(1, duration: 0.55)
                    CubicKeyframe(0, duration: 0.12)
                    LinearKeyframe(0, duration: 0.24)
                }
                KeyframeTrack(\.comparisonOpacity) {
                    LinearKeyframe(0, duration: 0.15)
                    CubicKeyframe(1, duration: 0.24)
                    LinearKeyframe(1, duration: 0.51)
                    CubicKeyframe(0, duration: 0.12)
                    LinearKeyframe(0, duration: 0.24)
                }
                KeyframeTrack(\.undoOpacity) {
                    LinearKeyframe(0, duration: 0.22)
                    CubicKeyframe(1, duration: 0.20)
                    LinearKeyframe(1, duration: 0.48)
                    CubicKeyframe(0, duration: 0.12)
                    LinearKeyframe(0, duration: 0.24)
                }
                KeyframeTrack(\.textOffset) {
                    CubicKeyframe(0, duration: 0.30)
                    LinearKeyframe(0, duration: 0.60)
                    CubicKeyframe(14, duration: 0.12)
                    LinearKeyframe(14, duration: 0.24)
                }
                KeyframeTrack(\.bandOpacity) {
                    LinearKeyframe(1, duration: 1.02)
                    CubicKeyframe(0, duration: 0.24)
                }
        }
        .task(id: moment.id) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            animationTrigger += 1
            do {
                try await Task.sleep(for: .milliseconds(1_300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}



extension Load {
    var displayText: String {
        let valueText = value.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(valueText) \(unit.rawValue)"
    }
}

extension RepRange {
    var displayText: String {
        lowerBound == upperBound ? "\(lowerBound) reps" : "\(lowerBound)–\(upperBound) reps"
    }
}
