import SwiftUI
import os

struct TodayView: View {
    #if DEBUG
    private static let launchLogger = Logger(subsystem: "app.the01.ios", category: "Launch")
    #endif
    let session: WorkoutSession
    let workoutState: TodayWorkoutState
    let historyState: WorkoutHistorySurfaceState
    let learnRepository: LearnRepository
    let hydration: HydrationState
    let healthConnection: HealthConnectionRepository
    let availableWorkoutMinutes: Int?
    let planRationale: [String]
    let isWorkoutInProgress: Bool
    let offersFinishSetup: Bool
    let onOpenProfile: () -> Void
    let onFinishSetup: () -> Void
    let onOpenAppleHealth: () -> Void
    let onOpenWorkout: () -> Void
    let onOpenHistory: () -> Void
    let onOpenProgress: () -> Void
    let canLogWater: Bool
    let onAddWater: (Int) -> HydrationQuickLogReceipt?
    let onUndoWater: (HydrationQuickLogGroup) -> Bool
    var wellbeingAssessment: WellbeingAssessment? = nil
    var onReviewWellbeing: (() -> Void)? = nil
    var programmeVolumeUnavailable = false
    // App-owned reported goal, when one is available. Never substitute a fixture.
    var dailyStepGoal: Int? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.calendar) private var calendar
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LocalDayProgress.preferenceKey) private var showsDayProgress = false
    @State private var showsReason = false
    @State private var showsWorkoutContents = false

    var body: some View {
        GeometryReader { proxy in
            let contentMargin = ZOSpace.screenMargin

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    todayHeader
                        .padding(.bottom, 20)

                    Group {
                        if programmeVolumeUnavailable && completion == nil && !isWorkoutInProgress {
                            VStack(alignment: .leading, spacing: ZOSpace.m) {
                                Text("Programme sets unavailable").zoThemeText(.title)
                                Text("The saved programme sets could not be verified. Open the programme to retry or review its adjustment before starting.")
                                Button("Review programme", action: onOpenWorkout)
                                    .buttonStyle(ZOButtonStyle(.secondary))
                            }
                            .padding(16)
                            .zoThemeCardSurface()
                        } else {
                            workoutCard
                        }
                    }

                    dailyInstruments
                        .padding(.top, 12)

                    weekSummary
                        .padding(.top, 16)
                        .padding(.bottom, 16)

                    if let wellbeingAssessment, let onReviewWellbeing {
                        WellbeingSummaryView(assessment: wellbeingAssessment, onReview: onReviewWellbeing)
                            .padding(16)
                            .zoThemeCardSurface()
                            .padding(.bottom, 16)
                    }

                    LearnTodaySection(
                        repository: learnRepository,
                        hasPlannedWorkout: !programmeVolumeUnavailable && workoutState == .ready && session.requiresWarmUp,
                        workoutCompleted: completion != nil,
                        workoutInProgress: isWorkoutInProgress,
                        onOpenWorkout: onOpenWorkout
                    )
                    .padding(.bottom, 24)

                    if offersFinishSetup {
                        finishSetupCard
                            .padding(.bottom, 20)
                    }

                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, contentMargin)
                .padding(.top, 10)
                .padding(.bottom, ZOSpace.x3)
                #if DEBUG
                .modifier(TodayReviewFrameDiagnostics(name: "tail"))
                #endif
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .modifier(TodayReviewFrameDiagnostics(name: "viewport"))
            #endif
            .defaultScrollAnchor(Self.reviewScrollAnchor)
            #if DEBUG
            .modifier(TodayReviewScrollDiagnostics())
            #endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .foregroundStyle(theme.textPrimary)
        .sheet(isPresented: $showsReason) {
            Group {
                rationaleSheet
                .presentationDetents(rationaleDetents)
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.surfacePrimary)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet()
        }
        .onAppear {
            #if DEBUG
            Self.launchLogger.notice("TodayView appeared")
            #endif
            Task { @MainActor in
                await Task.yield()
                #if DEBUG
                Self.launchLogger.notice("TodayView ready")
                #endif

                #if DEBUG
                if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_TODAY_WHY"] == "1" {
                    showsReason = true
                }
                #endif
            }
        }
    }

    // Proof 1: the workout stays compact until its real contents are requested.
    private var todayHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today")
                    .zoThemeHeading(.display, context: .headRowDisplay)
                    .foregroundStyle(localInk)
                    .accessibilityAddTraits(.isHeader)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .zoText(.body)
                    .foregroundStyle(localSecondaryInk)
                if showsDayProgress {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let day = LocalDayProgress(at: context.date, calendar: .autoupdatingCurrent) {
                            Text("\(day.percentage)% of the day has passed")
                                .zoText(.caption)
                                .foregroundStyle(localSecondaryInk)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            ZeroOneProfileButton(action: onOpenProfile)
        }
    }

    private var workoutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusChip
            Text(displayTitle)
                .zoThemeText(.title)

                .foregroundStyle(completion == nil ? localInk : localSecondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            Text(workoutMetadata)
                .zoText(.label)
                .foregroundStyle(completion == nil ? localSecondaryInk : localInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            setRail
                .padding(.top, 14)

            if completion == nil {
                Button {
                    withAnimation(reduceMotion ? nil : ZOMotion.carry(ZOMotion.quick)) {
                        showsWorkoutContents.toggle()
                    }
                } label: {
                    HStack {
                        Text(localization.format(session.exercises.count == 1 ? "%1$lld exercise" : "%1$lld exercises", .integer(session.exercises.count)))
                            .zoText(.label)
                        Spacer(minLength: ZOSpace.s)
                        Image(systemName: "chevron.down")
                            .zoIcon(ZOIcon.inline)
                            .foregroundStyle(localTertiaryInk)
                            .rotationEffect(.degrees(showsWorkoutContents ? 180 : 0))
                    }
                    .frame(minHeight: ZOSpace.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsWorkoutContents ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("today.workout.contents")
                if showsWorkoutContents {
                    exerciseRows.padding(.bottom, ZOSpace.m)
                }
                Button(action: onOpenWorkout) {
                    Text(primaryActionTitle)
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .accessibilityIdentifier("today.workout.primary")
                .accessibilityHint(isWorkoutInProgress ? "Resumes your saved workout." : "Opens your workout and warm-up.")
            } else {
                Button("Open in History", action: onOpenHistory)
                    .zoText(.label)
                    .underline()
                    .foregroundStyle(localInk)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("today.workout.history")
                    .padding(.top, 8)
            }

            if completion != nil || isWorkoutInProgress || workoutState == .unavailable {
            Text(workoutReassurance)
                .zoText(.label)
                .foregroundStyle(localSecondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            }

            if completion == nil && !isWorkoutInProgress && workoutState == .ready {
                Button("Why this workout") { showsReason = true }
                    .zoText(.label)
                    .foregroundStyle(localInk)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("today.workout.why")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, ZOSpace.l)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private var statusChip: some View {
        Text(statusChipTitle)
        .zoText(.caption)
        .foregroundStyle(localInk)
        .frame(minHeight: 26)
    }

    @ViewBuilder
    private var dailyInstruments: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: ZOSpace.m) {
                stepsTile
                waterTile
            }
        } else {
            HStack(alignment: .top, spacing: ZOSpace.m) {
                stepsTile
                waterTile
            }
        }
    }

    private var stepsTile: some View {
        TodayStepsInstrument(healthConnection: healthConnection,
            onOpenAppleHealth: onOpenAppleHealth, goal: dailyStepGoal)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoThemeCardSurface()
            #if DEBUG
            .modifier(TodayReviewFrameDiagnostics(name: "movement"))
            #endif
    }

    private var waterTile: some View {
        TodayHydrationInstrument(state: hydration, canLogWater: canLogWater,
            onAddWater: onAddWater, onUndoWater: onUndoWater)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoThemeCardSurface()
    }

    private var setRail: some View {
        let total = max(1, completion?.plannedSetCount ?? session.totalPlannedSetCount)
        let saved = min(total, completion?.completedSetCount ?? session.completedSetCount)
        return HStack(spacing: 6) {
            if completion == nil {
                ForEach(session.exercises) { exercise in
                    HStack(spacing: 2) {
                        ForEach(0..<exercise.plan.plannedSetCount, id: \.self) { index in
                            ZORailSegment(mark: index < exercise.completedSets.count ? .saved : .ahead, radius: 2, motionEnabled: false)
                                .frame(height: 6)
                        }
                    }
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<total, id: \.self) { index in
                        ZORailSegment(mark: index < saved ? .saved : .ahead, radius: 2, motionEnabled: false)
                            .frame(height: 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(saved) of \(total) working sets saved")
    }

    private var exerciseRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.exercises) { exercise in
                let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) ?? 0
                let isCurrent = index == session.currentExerciseIndex && isWorkoutInProgress
                let isComplete = exercise.completedSets.count == exercise.plan.plannedSetCount
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .foregroundStyle(localTertiaryInk)
                                Text(exercise.plan.name)
                                    .fontWeight(isCurrent ? .bold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(isWorkoutInProgress
                                ? "\(exercise.completedSets.count) of \(exercise.plan.plannedSetCount) sets saved"
                                : "\(exercise.plan.plannedSetCount) × \(exercise.plan.prescriptionDisplayText)")
                                .foregroundStyle(localSecondaryInk)
                                .padding(.leading, 28)
                        }
                        .zoText(.body)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .zoText(.caption)
                                .foregroundStyle(localTertiaryInk)
                                .frame(width: 20, alignment: .leading)
                            Text(exercise.plan.name)
                                .zoText(.label)
                                .foregroundStyle(localInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if isComplete {
                                Image(systemName: "checkmark")
                                    .zoIcon(ZOIcon.inline)
                                    .accessibilityHidden(true)
                            }
                            Text(isWorkoutInProgress
                                ? "\(exercise.completedSets.count) of \(exercise.plan.plannedSetCount)"
                                : "\(exercise.plan.plannedSetCount) × \(exercise.plan.prescriptionDisplayText)")
                                .zoText(.caption)
                                .monospacedDigit()
                                .foregroundStyle(localSecondaryInk)
                                .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 5)
                .frame(minHeight: ZOSpace.hitTarget)
                .overlay(alignment: .top) { Rectangle().fill(localStroke).frame(height: ZOStroke.hairline) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Exercise \(index + 1), \(exercise.plan.name), \(isCurrent ? "Current exercise, " : "")\(isComplete ? "Complete, " : "")\(exercise.completedSets.count) of \(exercise.plan.plannedSetCount) sets saved")
            }
        }
    }

    private var weekSummary: some View {
        Button(action: onOpenProgress) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("This week")
                Spacer(minLength: 8)
                Text(weekSummaryTitle)
                    .fontWeight(.semibold)
            }
            .zoText(.caption)
            .foregroundStyle(localSecondaryInk)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("This week, \(weekSummaryTitle). Open Progress")
    }

    private var finishSetupCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: ZOSpace.m) {
                finishSetupCopy
                Spacer(minLength: 0)
                finishSetupButton
            }

            VStack(alignment: .leading, spacing: ZOSpace.m) {
                finishSetupCopy
                finishSetupButton
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }

    private var finishSetupCopy: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("Fit the plan to you")
                .zoText(.section)
            Text("A few questions help 01 guide your training. Your workouts still work without them.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishSetupButton: some View {
        Button("Finish setup", action: onFinishSetup)
            .buttonStyle(ZOButtonStyle(.primary))
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
    }

    private var rationaleSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("WHY THIS")
                        .zoText(.caption)

                        .foregroundStyle(theme.accentForeground)

                    Text(displayTitle)
                        .zoThemeText(.display)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(rationaleEvidence.prefix(3).enumerated()), id: \.offset) { index, evidence in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text((index + 1).formatted(.number.precision(.integerLength(2))))
                                .zoText(.caption)
                                .monospacedDigit()
                                .foregroundStyle(theme.accentForeground)

                            Text(evidence)
                                .zoText(.body)
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
    }

    private var rationaleDetents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.height(390)]
    }

    private static var reviewScrollAnchor: UnitPoint {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_TODAY_SCROLL"] == "bottom" ? .bottom : .top
        #else
        .top
        #endif
    }

    private var localCanvas: Color { theme.backgroundPrimary }

    private var localModule: Color { theme.surfacePrimary }

    private var localInk: Color { theme.textPrimary }

    private var localSecondaryInk: Color { theme.textSecondary }

    private var localTertiaryInk: Color { theme.textTertiary }

    private var localSubsurface: Color { theme.surfaceSecondary }

    private var localStroke: Color { theme.strokeSubtle }

    private var localRailEmpty: Color { theme.surfaceTertiary }

    private var statusChipTitle: String {
        if completion != nil { return "Saved today" }
        if isWorkoutInProgress { return "In progress" }
        if workoutState == .unavailable { return "History unavailable" }
        return "Next workout"
    }

    private var workoutMetadata: String {
        if let completion {
            return "\(completion.endedEarly ? "Partial" : "Complete") · \(completion.completedSetCount) of \(completion.plannedSetCount) sets"
        }
        let duration = estimatedDuration
        if isWorkoutInProgress {
            return "\(duration) · \(session.completedSetCount) of \(session.totalPlannedSetCount) sets saved"
        }
        return "\(duration) · \(session.totalPlannedSetCount) sets"
    }

    private var workoutReassurance: String {
        if completion != nil { return "Your saved workout is in History. The next session can wait until you're ready." }
        if isWorkoutInProgress && session.requiresWarmUp {
            return "Your warm-up is ready. Complete it before your working sets."
        }
        if isWorkoutInProgress, let current = session.currentExercise {
            let nextSet = min(current.completedSets.count + 1, current.plan.plannedSetCount)
            return "Continues at \(current.plan.name), set \(nextSet). Your \(session.completedSetCount) saved sets are kept."
        }
        if workoutState == .unavailable { return "You can still train offline. History is temporarily unavailable." }
        return "Start with the warm-up. Change any set to fit how you feel today."
    }

    private var weekSummaryTitle: String {
        guard case let .entries(entries) = historyState else {
            return historyState == .unavailable ? "History unavailable" : "0 workouts"
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)
        let count = entries.filter { week?.contains($0.completedAt) == true }.count
        return "\(count) \(count == 1 ? "workout" : "workouts")"
    }

    private var estimatedDuration: String {
        guard let estimate = WorkoutTimeEstimator().estimate(for: session) else { return localization.string("Time varies") }
        return localization.format("Estimated up to %1$lld minutes", .integer(estimate.maximumMinutes))
    }

    private var rationaleEvidence: [String] {
        var evidence: [String] = []

        switch workoutState {
        case let .completed(completion):
            evidence.append("\(completion.completedSetCount) working sets recorded locally.")
            evidence.append(
                completion.wasAdapted
                    ? "Completed as the adapted session."
                    : "Completed as planned."
            )
            evidence.append(
                "Finished " + completion.completedAt.formatted(date: .omitted, time: .shortened) + "."
            )
            return evidence
        case .unavailable:
            return [
                "Local workout history is unavailable.",
                "Workout Library and offline training remain available."
            ]
        case .ready:
            break
        }

        if session.completedSetCount > 0 {
            evidence.append("This session is already in progress.")
        } else {
            evidence.append("Your next planned session is ready.")
        }

        if !planRationale.isEmpty && !isWorkoutInProgress {
            return evidence + planRationale
        }

        if session.exercises.first?.plan.previousPerformance.isEmpty == false {
            evidence.append("Lead movement has prior working-set data.")
        }

        if let progressionIncrease {
            let value = progressionIncrease.value.formatted(
                .number.precision(.fractionLength(0 ... 1))
            )
            evidence.append("+\(value) \(progressionIncrease.unit.rawValue) progression available.")
        }

        if let availableWorkoutMinutes {
            evidence.append(localization.format("You reported %1$lld minutes available.", .integer(availableWorkoutMinutes)))
            if WorkoutTimeEstimator().estimate(for: session)?.fitsWithin(minutes: availableWorkoutMinutes) == true {
                evidence.append(localization.string("The planned work is estimated to fit that window."))
            }
        }

        return evidence
    }

    private var completion: WorkoutHistoryDisplayItem? {
        guard case let .completed(item) = workoutState else { return nil }
        return item
    }

    private var displayProgramme: WorkoutProgramme? {
        completion?.programmeID.flatMap(WorkoutProgrammeLibrary.programme)
    }

    private var displayPlan: ExercisePlan? {
        displayProgramme?.exercisePlans.first ?? session.exercises.first?.plan
    }

    private var displayTitle: String {
        completion?.title ?? session.title
    }

    private var primaryActionTitle: String {
        if isWorkoutInProgress { return "Resume workout" }
        return workoutState == .ready ? "Start workout" : "Browse workouts"
    }

    private var progressionIncrease: (value: Double, unit: LoadUnit)? {
        guard wellbeingAssessment?.holdsAutomaticProgression != true else { return nil }
        guard let plan = session.exercises.first?.plan else { return nil }
        let previousLoads = plan.previousPerformance
            .map(\.load)
            .filter { $0.unit == plan.targetLoad.unit }
            .map(\.value)
        guard let previousMaximum = previousLoads.max() else { return nil }

        let increase = plan.targetLoad.value - previousMaximum
        guard increase > 0.001 else { return nil }
        return (increase, plan.targetLoad.unit)
    }

}

private struct TodayStepsInstrument: View {
    let healthConnection: HealthConnectionRepository
    let onOpenAppleHealth: () -> Void
    let goal: Int?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.calendar) private var calendar
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let snapshot = TodayStepsSnapshot(
                context: healthConnection.context,
                isStale: healthConnection.isContextStale,
                on: timeline.date,
                calendar: calendar
            )

            VStack(alignment: .leading, spacing: ZOSpace.m) {
                Text("Steps").zoText(.caption)
                    .foregroundStyle(theme.textSecondary)

                stepContent(for: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: calendar.startOfDay(for: timeline.date)) {
                await healthConnection.refreshIfConnected()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await healthConnection.refreshIfConnected() }
        }
    }

    @ViewBuilder
    private func stepContent(for snapshot: TodayStepsSnapshot) -> some View {
        switch healthConnection.status {
        case .notConnected:
            Text("See your steps here when you choose to connect Apple Health.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect Apple Health", action: onOpenAppleHealth)
                .buttonStyle(ZOButtonStyle(.secondary))
                .accessibilityHint("Opens Apple Health settings and explains the read-only permissions.")
        case .connecting:
            Text("Connecting to Apple Health…")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
        case .unavailable:
            Text("Apple Health step data is unavailable on this device.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .connected:
            connectedContent(for: snapshot)
        }
    }

    @ViewBuilder
    private func connectedContent(for snapshot: TodayStepsSnapshot) -> some View {
        switch snapshot {
        case let .count(steps, refreshedAt, isStale):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZOSpace.m) {
                    TodayGoalRing(progress: TodayGoalPresentation.progress(value: steps, goal: goal), symbol: "01.jog")
                    stepValue(steps)
                }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    TodayGoalRing(progress: TodayGoalPresentation.progress(value: steps, goal: goal), symbol: "01.jog")
                    stepValue(steps)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(steps.formatted()) steps today")

            DisclosureGroup("Apple Health") {
            Text(isStale
                 ? "Last available from Apple Health, \(refreshedAt.formatted(date: .omitted, time: .shortened)). Refresh failed."
                 : "Apple Health · updated \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            if isStale {
                refreshButton
            }
        case .needsRefresh:
            Text(healthConnection.isRefreshing
                 ? "Reading today's steps…"
                 : healthConnection.issue == .readFailed
                    ? "Apple Health couldn't update today's steps. Try again."
                    : "Today's steps need an update.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !healthConnection.isRefreshing {
                refreshButton
            }
        case .noData:
            Text(healthConnection.isContextStale
                 ? "Apple Health couldn't refresh. No earlier step count is available for today."
                 : "No step data available from Apple Health today.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if healthConnection.isContextStale {
                refreshButton
            } else {
                Button("Review Apple Health access", action: onOpenAppleHealth)
                    .buttonStyle(ZOButtonStyle(.secondary))
            }
        }
    }

    private func stepNumber(_ steps: Int) -> some View {
        Text(steps.formatted())
            .zoThemeText(.metric, size: 26, lineHeight: 30)
            .monospacedDigit()
            .foregroundStyle(theme.textPrimary)
            .contentTransition(.numericText())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func stepValue(_ steps: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            stepNumber(steps)
            if let goal, goal > 0 {
                Text(localization.format("of %1$@", .text(goal.formatted())))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                stepUnit.zoText(.caption)
            }
        }
    }

    private var stepUnit: some View {
        Text("steps today")
            .zoText(.body)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var refreshButton: some View {
        Button("Refresh steps") {
            Task { await healthConnection.refresh() }
        }
        .buttonStyle(ZOButtonStyle(.secondary))
        .disabled(healthConnection.isRefreshing)
    }
}

private struct TodayHydrationInstrument: View {
    let state: HydrationState
    let canLogWater: Bool
    let onAddWater: (Int) -> HydrationQuickLogReceipt?
    let onUndoWater: (HydrationQuickLogGroup) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var successEpoch = 0
    @State private var showsConfirmation = false
    @State private var confirmationTask: Task<Void, Never>?
    @State private var waterUndoGroup: HydrationQuickLogGroup?
    @State private var waterFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack {
                Text("Water").zoText(.caption).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                quickAddButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZOSpace.m) {
                    TodayGoalRing(progress: state.progress, symbol: "drop")
                    hydrationCopy
                }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    TodayGoalRing(progress: state.progress, symbol: "drop")
                    hydrationCopy
                }
            }

            if let waterFeedback {
                Text(waterFeedback)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)

                if let waterUndoGroup {
                    Button("Undo \(waterUndoGroup.addedMilliliters) ml") {
                        undoWater(waterUndoGroup)
                    }
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .accessibilityIdentifier("today.water.undo")
                }
            } else if !canLogWater {
                Text("Water logging is unavailable on this device right now.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sensoryFeedback(.increase, trigger: state.currentMilliliters) { old, new in
            new > old
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            guard Self.showsPersistentReviewSuccess else { return }
            showsConfirmation = true
            successEpoch += 1
        }
        .onDisappear { confirmationTask?.cancel() }
    }

    private var hydrationCopy: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(liters(state.currentMilliliters))
                        .zoThemeText(.metric, size: 26, lineHeight: 30)
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText(value: Double(state.currentMilliliters)))
                        .animation(
                            reduceMotion ? nil : ZeroOneMotion.standard,
                            value: state.currentMilliliters
                        )
                        .lineLimit(1)

                    Text("L")
                        .zoText(.label)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Text(localization.format("of %1$@ L", .text(liters(state.goalMilliliters))))
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
                    .contentTransition(.numericText(value: Double(state.remainingMilliliters)))
                    .animation(
                        reduceMotion ? nil : ZeroOneMotion.standard,
                        value: state.remainingMilliliters
                    )
        }
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localization.format("Water, %1$lld of %2$lld milliliters", .integer(state.currentMilliliters), .integer(state.goalMilliliters))))
    }

    private var quickAddButton: some View {
        Button {
            logWater()
        } label: {
                Image(systemName: showsConfirmation ? "checkmark" : "plus")
                    .zoIcon(ZOIcon.inline)
                    .contentTransition(.symbolEffect(.replace))

        }
        .buttonStyle(ZOButtonStyle(.round))
        .disabled(!canLogWater)
        .accessibilityLabel("Add 250 milliliters of water")
        .accessibilityHint(canLogWater ? "Saves to today’s hydration total." : "Water logging is unavailable.")
        .accessibilityIdentifier("today.water.add")
    }

    private func logWater() {
        guard let receipt = onAddWater(250) else {
            confirmationTask?.cancel()
            showsConfirmation = false
            waterFeedback = "Water save could not be confirmed. Check your total before trying again."
            return
        }
        waterUndoGroup = waterUndoGroup?.appending(receipt) ?? HydrationQuickLogGroup(receipt)
        waterFeedback = "+250 ml saved. \(receipt.savedMilliliters) ml today."
        successEpoch += 1
        showConfirmation()
    }

    private func undoWater(_ group: HydrationQuickLogGroup) {
        confirmationTask?.cancel()
        showsConfirmation = false
        waterUndoGroup = nil
        waterFeedback = onUndoWater(group)
            ? "\(group.addedMilliliters) ml undone."
            : "Undo could not be confirmed. Check your water total."
    }

    private func showConfirmation() {
        confirmationTask?.cancel()
        withAnimation(reduceMotion ? nil : ZeroOneMotion.successMicro) {
            showsConfirmation = true
        }
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(950))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : ZeroOneMotion.fast) {
                showsConfirmation = false
            }
        }
    }

    private static var showsPersistentReviewSuccess: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_SUCCESS_STATE"] == "hydration"
        #else
        false
        #endif
    }

    private func liters(_ milliliters: Int) -> String {
        (Double(milliliters) / 1_000)
            .formatted(.number.precision(.fractionLength(1 ... 2)))
    }
}

#if DEBUG
/// Common-coordinate evidence that the real content clears the intrinsic dock.
struct TodayReviewFrameDiagnostics: ViewModifier {
    private static let logger = Logger(subsystem: "app.the01.ios", category: "Launch")
    let name: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_TODAY_SCROLL"] == "bottom" {
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .allowsHitTesting(false)
                        .onAppear { report(geometry.frame(in: .global)) }
                        .onChange(of: geometry.frame(in: .global)) { _, frame in report(frame) }
                }
            }
        } else {
            content
        }
    }

    private func report(_ frame: CGRect) {
        let detail = "name=\(name) minY=\(frame.minY) maxY=\(frame.maxY) height=\(frame.height)"
        Self.logger.notice("Today review frame: \(detail, privacy: .public)")
    }
}

/// Measures review reachability without changing production scrolling.
private struct TodayReviewScrollDiagnostics: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *),
           ProcessInfo.processInfo.environment["ZERO_ONE_REVIEW_TODAY_SCROLL"] == "bottom" {
            content.modifier(TodayReviewBottomScroll())
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct TodayReviewBottomScroll: ViewModifier {
    private static let logger = Logger(subsystem: "app.the01.ios", category: "Launch")
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var hasLayout = false
    @State private var requestedBottom = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: TodayReviewScrollMetrics.self) { geometry in
                TodayReviewScrollMetrics(geometry)
            } action: { _, metrics in
                let detail = metrics.description
                Self.logger.notice("Today review scroll geometry: \(detail, privacy: .public)")
                Self.logger.notice("Today review bottom distance: \(metrics.bottomDistance)")
                if metrics.containerHeight > 0 && metrics.contentHeight > 0 {
                    hasLayout = true
                }
            }
            .task(id: hasLayout && scenePhase == .active) {
                guard hasLayout, scenePhase == .active, !requestedBottom else { return }
                await Task.yield()
                guard !Task.isCancelled, scenePhase == .active, !requestedBottom else { return }
                requestedBottom = true
                Self.logger.notice("Today review explicit bottom scroll requested")
                position.scrollTo(edge: .bottom)
            }
    }
}

@available(iOS 18.0, *)
private struct TodayReviewScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let offsetY: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let bounds: CGRect
    let visibleRect: CGRect

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        offsetY = geometry.contentOffset.y
        insetTop = geometry.contentInsets.top
        insetBottom = geometry.contentInsets.bottom
        bounds = geometry.bounds
        visibleRect = geometry.visibleRect
    }

    var bottomDistance: Int {
        Int((contentHeight + insetBottom - offsetY - containerHeight).rounded())
    }

    var description: String {
        "content=\(contentHeight) container=\(containerHeight) offset=\(offsetY) "
            + "insets=\(insetTop),\(insetBottom) bounds=\(bounds) visible=\(visibleRect)"
    }
}
#endif
