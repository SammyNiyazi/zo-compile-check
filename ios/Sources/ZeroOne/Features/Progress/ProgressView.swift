import Charts
import SwiftUI

struct ProgressScreen: View {
    let session: WorkoutSession
    let historyState: WorkoutHistorySurfaceState
    let bodyWeight: BodyWeightRepository
    let loadChoices: WorkoutLoadChoiceRepository?
    let progressPhotos: ProgressPhotoRepository?
    let healthConnection: HealthConnectionRepository?
    let onSharePhotos: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)?

    init(
        session: WorkoutSession,
        historyState: WorkoutHistorySurfaceState,
        bodyWeight: BodyWeightRepository,
        loadChoices: WorkoutLoadChoiceRepository? = nil,
        progressPhotos: ProgressPhotoRepository? = nil,
        healthConnection: HealthConnectionRepository? = nil,
        onSharePhotos: ((ProgressPhotoRecord, ProgressPhotoRecord) -> Void)? = nil
    ) {
        self.session = session
        self.historyState = historyState
        self.bodyWeight = bodyWeight
        self.loadChoices = loadChoices
        self.progressPhotos = progressPhotos
        self.healthConnection = healthConnection
        self.onSharePhotos = onSharePhotos
    }

    @AppStorage("slick.showBodyWeightOnProgress") private var showsBodyWeightOnProgress = true
    @State private var hasAppeared = false
    @State private var insightSuccessEpoch = 0
    @State private var chartWindow = ProgressChartWindow.month
    @AppStorage("slick.bodyWeightUnit") private var chartUnitRaw = BodyWeightUnit.kilograms.rawValue
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneWellbeingAssessment) private var wellbeing

    private var summary: ProgressSummary {
        ProgressSummary(session: session)
    }

    private var savedLift: SavedLiftProgress? {
        SavedLiftProgress(session: session, historyState: historyState)
    }

    private var savedEntries: [WorkoutHistoryDisplayItem]? {
        switch historyState {
        case .empty: []
        case let .entries(entries): entries
        case .unavailable: nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                Text("Progress").zoText(.display).accessibilityAddTraits(.isHeader)
                ZOSegmentedControl("Progress period", selection: $chartWindow,
                    options: ProgressChartWindow.allCases.map { ZOSegment(value: $0, label: Text(LocalizedStringKey($0.rawValue))) })
                let now = Date.now
                let interval = chartWindow.interval(now: now, calendar: calendar)
                Text(interval.start.formatted(.dateTime.month(.abbreviated).day().locale(localization.locale)) + " – "
                     + now.formatted(.dateTime.month(.abbreviated).day().year().locale(localization.locale)))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                if showsBodyWeightOnProgress {
                    if bodyWeight.isAvailable {
                        ProgressWeightTrendCard(chart: ProgressWeightChart(entries: bodyWeight.entries,
                            interval: interval, now: now, calendar: calendar),
                            unit: BodyWeightUnit(rawValue: chartUnitRaw) ?? .kilograms)
                    } else {
                        ZeroOneEmptyState(label: localization.string("Weight"), title: localization.string("Readings unavailable"),
                            message: localization.string("01 cannot confirm the saved readings right now. Reload to see the current state."))
                    }
                }
                ProgressWorkoutTrendCard(weeks: ProgressWorkoutChart.weeks(
                    completedDates: savedEntries?.map(\.completedAt), interval: interval, now: now, calendar: calendar))
                VStack(spacing: 0) {
                    if let progressPhotos {
                        NavigationLink {
                            ProgressPhotosView(repository: progressPhotos, onShare: onSharePhotos)
                        } label: {
                            progressRoute(title: "Before and after", detail: "Only on this iPhone. Never synced.", symbol: "rectangle.split.2x1")
                        }.buttonStyle(.plain)
                    }
                    if let healthConnection {
                        NavigationLink {
                            ProgressSleepSummaryView(healthConnection: healthConnection)
                        } label: {
                            progressRoute(title: "Sleep", detail: "From Apple Health", symbol: "moon")
                        }.buttonStyle(.plain)
                    }
                }
                if showsBodyWeightOnProgress { bodyWeightLink }
                if let entries = savedEntries { weekLink(entries: entries) }
                if let savedLift { savedLiftCard(savedLift) }
                WorkoutActivitySection(historyState: historyState)
                if let workload = wellbeing?.workload { TrainingWorkloadSummaryView(assessment: workload) }
                if let quality = wellbeing?.dietQuality { DietQualitySummaryView(assessment: quality) }
            }
            .padding(.horizontal, ZOSpace.xl)
            .padding(.top, ZOSpace.l)
            .padding(.bottom, ZOSpace.x4)
        }
        .scrollIndicators(.hidden)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { dismiss() }.accessibilityHint("Returns to the previous screen.")
            }
        }
        .foregroundStyle(theme.textPrimary)
        .onAppear { hasAppeared = true }
    }

    private func progressRoute(title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: ZOSpace.m) {
            Image(systemName: symbol).zoIcon(ZOIcon.row).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).zoText(.section)
                Text(detail).zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").zoIcon(ZOIcon.row).foregroundStyle(theme.textSecondary).accessibilityHidden(true)
        }
        .foregroundStyle(theme.textPrimary).frame(minHeight: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.strokeSubtle).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("YOUR PROGRESS")
                .zoText(.caption)
                .foregroundStyle(theme.brandGradientHorizontal)

            Text("Training over time")
                .zoText(.display)
                .accessibilityAddTraits(.isHeader)

            Text("Your completed sessions are counted from the history saved on this iPhone.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func weekLink(entries: [WorkoutHistoryDisplayItem]) -> some View {
        let week = ProgressWeekSnapshot(entries: entries, now: .now, calendar: calendar)
        return NavigationLink {
            ProgressWeekScreen(session: session, entries: entries, loadChoices: loadChoices)
        } label: {
            HStack(spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("THIS WEEK")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text("Your training, together")
                        .zoText(.title)
                        .foregroundStyle(theme.textPrimary)
                    Text("\(week.workoutCount) workouts · \(week.savedSetCount) saved sets")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.textSecondary)
            }
            .zeroOneFeatureSurface()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this week's saved workouts, muscle work, and next-load choices.")
    }

    private var workoutTargetsHeader: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("CURRENT WORKOUT PLAN")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            Text(summary.insight)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func savedLiftCard(_ lift: SavedLiftProgress) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("FROM YOUR SAVED SETS")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            Text(lift.exerciseName)
                .zoText(.title)
            if let latest = lift.points.last {
                Text(localization.format("Latest heaviest set: %1$@ %2$@ × %3$lld",
                     .text(latest.load.value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale))),
                     .text(lift.unit.rawValue), .integer(latest.reps)))
                    .zoText(.section)
            }

            Chart(lift.points) { point in
                LineMark(
                    x: .value("Saved session", point.completedAt),
                    y: .value("Heaviest set load", point.load.value)
                )
                .foregroundStyle(theme.textPrimary)
                .lineStyle(StrokeStyle(lineWidth: ZeroOneChartStyle.lineWidth, lineCap: .round))

                PointMark(
                    x: .value("Saved session", point.completedAt),
                    y: .value("Heaviest set load", point.load.value)
                )
                .foregroundStyle(theme.accentForeground)
                .symbolSize(ZeroOneChartStyle.pointSize)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(theme.strokeSubtle)
                    AxisValueLabel {
                        if let load = value.as(Double.self) {
                            Text(load.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale)))
                        }
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(height: 175)
            .accessibilityLabel(localization.format("Saved %1$@ set loads in %2$@", .text(lift.exerciseName), .text(lift.unit.rawValue)))
            .accessibilityValue(lift.points.map {
                localization.format("%1$@: %2$@ %3$@ for %4$lld reps",
                    .text($0.completedAt.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))),
                    .text($0.load.value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale))),
                    .text(lift.unit.rawValue), .integer($0.reps))
            }.joined(separator: "; "))

            Text("Heaviest completed set from up to six saved sessions. Older records without exercise details and different units are excluded.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let entries = savedEntries {
                NavigationLink {
                    WorkoutExerciseHistoryDetailView(
                        exerciseName: lift.exerciseName,
                        history: WorkoutExerciseHistory(exerciseID: lift.exerciseID, entries: entries),
                        targetReps: session.exercises.first(where: { $0.plan.exerciseID == lift.exerciseID })?.plan.targetReps
                    )
                } label: {
                    Label("View saved sets", systemImage: "arrow.right")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .zeroOneFeatureSurface()
    }

    private var progressInsightCard: some View {
        HStack(alignment: .center, spacing: ZOSpace.l) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text("LEAD TARGET")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)

                Text(summary.leadTargetText)
                    .zoText(.metric)
                    .foregroundStyle(progressHighlightStyle)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: ZOSpace.m)

            Image(systemName: "target")
                .zoIcon(ZOIcon.row)
                .foregroundStyle(progressHighlightStyle)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(progressHighlightStyle)
                        .opacity(0.08)
                }
        }
        .padding(ZOSpace.xl)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZORadius.card, style: .continuous)
                .stroke(theme.strokeSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lead target, " + summary.leadTargetText)
    }

    private var statGrid: some View {
        VStack(spacing: 0) {
            metricRow(
                leading: ("Session", session.isComplete ? "DONE" : "ACTIVE", "Current state"),
                trailing: ("Set progress", "\(session.completedSetCount)/\(session.totalPlannedSetCount)", "Working sets")
            )

            Rectangle().fill(theme.strokeSubtle).frame(height: 1)

            metricRow(
                leading: (
                    "Planned volume",
                    summary.totalPlannedVolumeText,
                    "This session"
                ),
                trailing: ("Lead target", summary.leadTargetText, "Current prescription")
            )
        }
        .overlay(alignment: .top) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
    }

    private var strengthChart: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            chartHeader(
                title: "Target load",
                subtitle: "Current lead-exercise prescription in " + summary.leadTargetUnit
            )

            Chart(summary.strengthPoints) { point in
                LineMark(
                    x: .value("Set", point.label),
                    y: .value("Load", point.load)
                )
                .foregroundStyle(progressHighlightStyle)
                .lineStyle(StrokeStyle(lineWidth: ZeroOneChartStyle.lineWidth, lineCap: .round))

                PointMark(
                    x: .value("Set", point.label),
                    y: .value("Load", point.load)
                )
                .foregroundStyle(progressHighlightStyle)
                .symbolSize(ZeroOneChartStyle.pointSize)
            }
            .chartYScale(domain: summary.strengthDomain)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(ZeroOneChartStyle.gridLine)
                    AxisValueLabel {
                        if let load = value.as(Double.self) {
                            Text(load.formatted(.number.precision(.fractionLength(0 ... 1)).locale(localization.locale)))
                        }
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().foregroundStyle(theme.textSecondary)
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Lead target load chart. " + summary.leadTargetText)
        }
        .zeroOneFeatureSurface()
    }

    private var progressHighlightStyle: AnyShapeStyle {
        theme.id == .liquidMidnight
            ? AnyShapeStyle(theme.brandGradientPrimary)
            : AnyShapeStyle(theme.textPrimary)
    }

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            chartHeader(
                title: "Session volume",
                subtitle: "Planned work by exercise. Values retain their prescription units."
            )

            ForEach(summary.volumeSections) { section in
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(section.unit.rawValue.uppercased())
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)

                    Chart(section.points) { point in
                        BarMark(
                            x: .value("Volume", point.volume),
                            y: .value("Exercise", point.exercise)
                        )
                        .foregroundStyle(theme.brandGradientHorizontal)
                        .cornerRadius(ZORadius.small)
                        .annotation(position: .trailing) {
                            Text(point.formattedVolume)
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(ZeroOneChartStyle.gridLine)
                            AxisValueLabel {
                                if let volume = value.as(Double.self) {
                                    Text(volume.formatted(.number.notation(.compactName)))
                                }
                            }
                            .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisValueLabel().foregroundStyle(theme.textSecondary)
                        }
                    }
                    .frame(height: max(120, CGFloat(section.points.count) * 54))
                    .accessibilityLabel(
                        "Planned workout volume in " + section.unit.rawValue + ". "
                            + section.accessibilityText
                    )
                }
            }
        }
        .padding(.vertical, ZOSpace.l)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.strokeSubtle).frame(height: 1)
        }
    }

    private var bodyWeightLink: some View {
        NavigationLink {
            BodyWeightScreen(repository: bodyWeight)
        } label: {
            HStack(spacing: ZOSpace.m) {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Text("BODY WEIGHT")
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)
                    Text(localization.string(bodyWeight.isAvailable
                         ? (bodyWeight.entries.isEmpty ? "Add your first reading" : "See your readings")
                         : "Readings unavailable"))
                        .zoText(.title)
                        .foregroundStyle(theme.textPrimary)
                    Text("Optional · saved only on this iPhone")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.textSecondary)
            }
            .zeroOneFeatureSurface()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your private body-weight readings.")
    }

    private func chartHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(title)
                .zoText(.title)

            Text(subtitle)
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func metricRow(
        leading: (label: String, value: String, detail: String),
        trailing: (label: String, value: String, detail: String)
    ) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.l) {
            ZeroOneMetricReadout(label: leading.label, value: leading.value, detail: leading.detail)

            Rectangle()
                .fill(theme.strokeSubtle)
                .frame(width: 1, height: 78)

            ZeroOneMetricReadout(label: trailing.label, value: trailing.value, detail: trailing.detail)
        }
        .padding(.vertical, ZOSpace.l)
    }
}

struct BodyWeightScreen: View {
    @Environment(\.calendar) private var calendar
    let repository: BodyWeightRepository

    @AppStorage("slick.bodyWeightUnit") private var unitRawValue = BodyWeightUnit.kilograms.rawValue
    @AppStorage("slick.bodyWeightDirection") private var directionRawValue = BodyWeightDirection.none.rawValue
    @AppStorage("slick.showBodyWeightOnProgress") private var showsOnProgress = true
    @State private var presentedSheet: BodyWeightSheet?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var separatorInk: Color {
        contrast == .increased ? ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme) : theme.strokeSubtle
    }

    private var unit: BodyWeightUnit { BodyWeightUnit(rawValue: unitRawValue) ?? .kilograms }
    private var direction: BodyWeightDirection {
        BodyWeightDirection(rawValue: directionRawValue) ?? .none
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Body weight")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                    Text("Your readings")
                        .zoText(.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("A reading is context, not a verdict. This stays on your iPhone and never changes your exercise loads.")
                        .zoText(.body)
                        .foregroundStyle(secondaryInk)
                }

                ZOSegmentedControl("Weight unit", selection: $unitRawValue, options: BodyWeightUnit.allCases.map { option in ZOSegment(value: option.rawValue, label: Text(option.rawValue)) })

                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    Picker("Your direction", selection: $directionRawValue) {
                        ForEach(BodyWeightDirection.allCases) { option in
                            Text(LocalizedStringKey(option.title)).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Optional. This changes only the words around your trend, never your workouts or load suggestions.")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                }

                Toggle("Show in Progress", isOn: $showsOnProgress)
                    .tint(theme.textPrimary)

                if !repository.isAvailable {
                    ZeroOneEmptyState(
                        label: localization.string("Readings unavailable"),
                        title: localization.string("Your data could not be read"),
                        message: localization.string("01 cannot confirm the saved readings right now. Reload to see the current state.")
                    )
                    Button("Try again") { repository.reload() }
                        .buttonStyle(ZOButtonStyle(.secondary))
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let observations = BodyWeightObservationPresentation(entries: repository.entries,
                            isAvailable: repository.isAvailable, now: context.date)
                        let trend = BodyWeightTrend(entries: observations.observedEntries ?? [],
                            now: context.date, calendar: calendar)
                        summaryCard(trend: trend, state: observations.state)
                        if observations.state == .observed { fourWeekCard(trend: trend) }
                        if !trend.lastThirtyDays.isEmpty { trendChart(now: context.date) }
                        if let futureCount = observations.futureCount, futureCount > 0 {
                            Text("Future-dated readings stay in history and are excluded from averages until their recorded time.")
                                .zoText(.caption).foregroundStyle(secondaryInk)
                        }
                        if !repository.entries.isEmpty { readingHistory(now: context.date) }
                    }
                    Button("Add a reading") { presentedSheet = .add }
                        .buttonStyle(ZOButtonStyle(.primary))
                    Text("Your readings remain on this device. A device change needs a separate backup or transfer path.")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                }
            }
            .padding(.horizontal, ZOSpace.xl)
            .padding(.vertical, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("Body weight")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedSheet) { sheet in
            Group {
                Group {
                    switch sheet {
                    case .add:
                        BodyWeightEntrySheet(repository: repository, unit: unit, editing: nil)
                    case let .edit(entry):
                        BodyWeightEntrySheet(repository: repository, unit: unit, editing: entry)
                    case let .delete(entry):
                        BodyWeightDeleteSheet(repository: repository, entry: entry, unit: unit)
                    }
                }
                .zeroOneTheme(theme)
                .preferredColorScheme(theme.colorScheme)
            }
            .zoSheet(theme)
        }
    }

    private func summaryCard(trend: BodyWeightTrend, state: BodyWeightObservationPresentation.State) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("Seven-day average")
                .zoText(.caption)
                .foregroundStyle(secondaryInk)
            if let average = trend.sevenDayAverageKilograms {
                Text(formatted(average))
                    .zoText(.metric)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Text("One reading per day enters this average. Day-to-day changes are normal.")
                    .zoText(.caption)
                    .foregroundStyle(secondaryInk)
                if trend.latestDiffersFromPriorAverage,
                   let averageChange = trend.averageChangeAfterLatestKilograms {
                    let change = abs(unit.displayedValue(for: averageChange))
                    Text(localization.format("A single reading can vary with water, salt, sleep, and timing. Your average moved %1$@ %2$@.",
                            .text(change.formatted(.number.precision(.fractionLength(1)).locale(localization.locale))), .text(unit.rawValue)))
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                }
            } else {
                Text(LocalizedStringKey(state == .futureOnly ? "No readings at or before now" : "No recent readings"))
                    .zoText(.title)
                Text("Add a reading when it is useful to you.")
                    .zoText(.caption)
                    .foregroundStyle(secondaryInk)
            }
            if let latest = trend.latest {
                Text(localization.format("Latest: %1$@ · %2$@", .text(formatted(latest.kilograms)), .text(latest.recordedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localization.locale)))))
                    .zoText(.label)
                    .foregroundStyle(secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeroOneFeatureSurface()
    }

    private func trendChart(now: Date) -> some View {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return ProgressWeightTrendCard(chart: ProgressWeightChart(entries: repository.entries,
            interval: DateInterval(start: start, end: end), now: now, calendar: calendar), unit: unit)
    }

    private func fourWeekCard(trend: BodyWeightTrend) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("Four-week view")
                .zoText(.caption)
                .foregroundStyle(secondaryInk)
            if let change = trend.fourWeekChangeKilograms {
                let value = unit.displayedValue(for: change)
                let sign = value < 0 ? "−" : value > 0 ? "+" : ""
                Text(sign + abs(value).formatted(.number.precision(.fractionLength(1)).locale(localization.locale)) + " " + unit.rawValue)
                    .zoText(.metric)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Text(localization.string(direction.context(for: change)))
                    .zoText(.body)
                Text("Compares the average near your latest reading with the average four weeks earlier. One reading per day counts.")
                    .zoText(.caption)
                    .foregroundStyle(secondaryInk)
            } else {
                Text("Not enough history yet")
                    .zoText(.title)
                Text("Once you have readings across four weeks, we can compare two seven-day averages. No target is assumed.")
                    .zoText(.caption)
                    .foregroundStyle(secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeroOneFeatureSurface()
    }

    private func readingHistory(now: Date) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Reading history")
                .zoText(.title)
                .accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: 0) {
                ForEach(repository.entries) { entry in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.m))
                        : AnyLayout(HStackLayout(spacing: ZOSpace.m))
                    layout {
                        VStack(alignment: .leading, spacing: ZOSpace.xs) {
                            Text(formatted(entry.kilograms))
                                .zoText(.section)
                            Text(entry.recordedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localization.locale)))
                                .zoText(.caption)
                                .foregroundStyle(secondaryInk)
                            if entry.recordedAt > now {
                                Text("Future-dated reading").zoText(.caption).foregroundStyle(secondaryInk)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Correct reading", systemImage: "pencil") {
                                presentedSheet = .edit(entry)
                            }
                            Button("Delete reading", systemImage: "trash", role: .destructive) {
                                presentedSheet = .delete(entry)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(localization.format("Options for reading on %1$@", .text(entry.recordedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localization.locale)))))
                    }
                    .padding(.vertical, ZOSpace.s)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(separatorInk).frame(height: 1)
                    }
                }
            }
        }
    }

    private func formatted(_ kilograms: Decimal) -> String {
        unit.displayedValue(for: kilograms).formatted(.number.precision(.fractionLength(1)).locale(localization.locale)) + " " + unit.rawValue
    }
}

private enum BodyWeightSheet: Identifiable {
    case add
    case edit(BodyWeightEntry)
    case delete(BodyWeightEntry)

    var id: String {
        switch self {
        case .add: "add"
        case let .edit(entry): "edit-" + entry.id.uuidString
        case let .delete(entry): "delete-" + entry.id.uuidString
        }
    }
}

private struct BodyWeightEntrySheet: View {
    let repository: BodyWeightRepository
    let unit: BodyWeightUnit
    let editing: BodyWeightEntry?
    private let initialInput: String

    @State private var input: String
    @FocusState private var readingIsFocused: Bool
    @State private var draftID: UUID
    @State private var draftDate: Date
    @State private var showsSaveError = false
    @State private var saveErrorText = "Your entry is still here. Please try again."
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var separatorInk: Color {
        contrast == .increased ? ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme) : theme.strokeSubtle
    }

    init(repository: BodyWeightRepository, unit: BodyWeightUnit, editing: BodyWeightEntry?) {
        self.repository = repository
        self.unit = unit
        self.editing = editing
        let displayedInput = editing.map {
            unit.displayedValue(for: $0.kilograms).formatted(.number.grouping(.never).precision(.fractionLength(1)))
        } ?? ""
        initialInput = displayedInput
        _input = State(initialValue: displayedInput)
        _draftID = State(initialValue: editing?.id ?? UUID())
        _draftDate = State(initialValue: editing?.recordedAt ?? Date())
    }

    private var parsedValue: Decimal? {
        BodyWeightInput.kilograms(input, unit: unit)
    }

    private var inputState: BodyWeightReadingInputPresentation {
        BodyWeightReadingInputPresentation(text: input, unit: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Body weight") {
                    HStack {
                        TextField("Reading", text: $input)
                            .keyboardType(.decimalPad)
                            .focused($readingIsFocused)
                            .zoText(.body)
                            .accessibilityHint(inputState == .invalid
                                ? localization.string("Enter a valid reading. Your typed entry is kept.")
                                : localization.string("Enter the reading in the selected weight unit."))
                            .accessibilityLabel(localization.format("Body-weight reading in %1$@", .text(unit.rawValue)))
                        Text(unit.rawValue)
                            .foregroundStyle(secondaryInk)
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .frame(minHeight: ZOSpace.rowMinHeight)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: ZORadius.control)
                            .strokeBorder(inputState == .invalid ? theme.destructivePrimary
                                : (readingIsFocused ? theme.textPrimary : separatorInk),
                                lineWidth: readingIsFocused ? ZOStroke.focus : ZOStroke.control)
                    }
                    if inputState == .invalid {
                        Label("Enter a valid reading. Your typed entry is kept.", systemImage: "exclamationmark.circle")
                            .zoText(.caption).foregroundStyle(theme.destructivePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let adjustmentLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.s))
                        : AnyLayout(HStackLayout())
                    adjustmentLayout {
                        Button("Decrease by 0.1") { adjust(by: -1) }
                            .frame(minHeight: 44)
                        Spacer()
                        Button("Increase by 0.1") { adjust(by: 1) }
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .disabled(input.isEmpty)
                    DatePicker("Recorded at", selection: $draftDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                if !repository.isAvailable {
                    Section {
                        Text("Saved readings are unavailable. Your typed entry has been kept. Reload saved readings before trying Save again.")
                            .foregroundStyle(secondaryInk)
                        Button("Reload saved readings") { repository.reload() }
                            .frame(minHeight: 44)
                    }
                }
                Section {
                    Text("Optional and private to this iPhone. This reading will not alter your training plan.")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.surfacePrimary)
            .navigationTitle(LocalizedStringKey(editing == nil ? "Add reading" : "Correct reading"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { readingIsFocused = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(parsedValue == nil || !repository.isAvailable)
                }
            }
            .alert("Reading not saved", isPresented: $showsSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(localization.string(saveErrorText))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func adjust(by tenths: Int) {
        guard let current = BodyWeightInput.number(input) else { return }
        let adjusted = max(Decimal(0), current + Decimal(tenths) / 10)
        input = NSDecimalNumber(decimal: adjusted).stringValue
    }

    private func save() {
        guard let kilograms = parsedValue else { return }
        do {
            if let editing {
                if input == initialInput && draftDate == editing.recordedAt {
                    dismiss()
                    return
                }
                let correctedKilograms = input == initialInput ? editing.kilograms : kilograms
                let revised = BodyWeightEntry(
                    id: editing.id,
                    recordedAt: draftDate,
                    kilograms: correctedKilograms
                )
                try repository.replace(editing, with: revised)
            } else {
                try repository.save(BodyWeightEntry(id: draftID, recordedAt: draftDate, kilograms: kilograms))
            }
            dismiss()
        } catch {
            saveErrorText = error as? BodyWeightStoreError == .conflictingEntry
                ? "This reading changed since you opened it. Close and review the latest version."
                : "Your entry is still here. Please try again."
            showsSaveError = true
        }
    }
}

private struct BodyWeightDeleteSheet: View {
    let repository: BodyWeightRepository
    let entry: BodyWeightEntry
    let unit: BodyWeightUnit

    @State private var showsDeleteError = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondaryInk: Color { contrast == .increased ? theme.textPrimary : theme.textSecondary }
    private var separatorInk: Color {
        contrast == .increased ? ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme) : theme.strokeSubtle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                Text("Delete this reading?")
                    .zoText(.title)
                Text(entry.recordedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(localization.locale))
                     + " · " + unit.displayedValue(for: entry.kilograms).formatted(.number.precision(.fractionLength(1)).locale(localization.locale))
                     + " " + unit.rawValue)
                    .zoText(.body)
                Text("Only this reading will be removed. Your workout history and other readings stay unchanged.")
                    .zoText(.caption)
                    .foregroundStyle(secondaryInk)
                if !repository.isAvailable {
                    Text("Saved readings are unavailable. Reload before trying deletion again.")
                        .zoText(.caption)
                        .foregroundStyle(secondaryInk)
                    Button("Reload saved readings") { repository.reload() }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
                Button(role: .destructive, action: delete) {
                    Text("Delete reading")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(ZOButtonStyle(.destructive))
                .tint(theme.destructivePrimary)
                .disabled(!repository.isAvailable)
                Button("Keep reading") { dismiss() }
                    .buttonStyle(ZOButtonStyle(.primary))
            }
            .padding(ZOSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            }
            .background(theme.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Reading not deleted", isPresented: $showsDeleteError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Deletion could not be confirmed. Retry here or close and review your readings.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func delete() {
        do {
            try repository.delete(entry)
            dismiss()
        } catch {
            showsDeleteError = true
        }
    }
}

private struct ProgressWeekScreen: View {
    let session: WorkoutSession
    let entries: [WorkoutHistoryDisplayItem]
    let loadChoices: WorkoutLoadChoiceRepository?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneWorkoutProgression) private var progression
    @State private var hasAppeared = false

    private var week: ProgressWeekSnapshot {
        ProgressWeekSnapshot(entries: entries, now: .now, calendar: .current)
    }

    private var targets: [ExerciseID: RepRange] {
        Dictionary(session.exercises.filter { !$0.plan.isTimed }.map { ($0.plan.exerciseID, $0.plan.targetReps) },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("THIS WEEK")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text("Work that stays with you")
                        .zoText(.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(week.start.formatted(.dateTime.month(.abbreviated).day()))–\(week.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day())) · Monday to Sunday")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                .zeroOneReveal(hasAppeared)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: ZOSpace.xl) {
                        ZeroOneMetricReadout(label: "Workouts", value: week.workoutCount.formatted(), detail: "Saved this week")
                        ZeroOneMetricReadout(label: "Sets", value: week.savedSetCount.formatted(), detail: "Working sets")
                    }
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        ZeroOneMetricReadout(label: "Workouts", value: week.workoutCount.formatted(), detail: "Saved this week")
                        ZeroOneMetricReadout(label: "Sets", value: week.savedSetCount.formatted(), detail: "Working sets")
                    }
                }
                .zeroOneFeatureSurface()
                .zeroOneReveal(hasAppeared, delay: 0.04)

                ProgressLoadChoicesSection(
                    reviews: ProgressLoadReview.available(for: session, entries: entries,
                        progressionReviews: progression?.reviews.isAvailable == true ? progression?.reviews.snapshot.reviews ?? [] : []),
                    repository: loadChoices
                )
                .zeroOneReveal(hasAppeared, delay: 0.08)

                WorkoutProgressionReviewSection(plans: session.exercises.map(\.plan))
                    .zeroOneReveal(hasAppeared, delay: 0.08)

                WorkoutMuscleWeekSection(
                    week: WorkoutMuscleWeek(entries: entries, now: .now, calendar: .current),
                    entries: entries,
                    targetReps: targets
                )
                .zeroOneReveal(hasAppeared, delay: 0.12)

                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    Text("SAVED THIS WEEK")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    if week.sessions.isEmpty {
                        Text("No saved workouts yet this week. A rest day does not erase earlier work.")
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                    }
                    ForEach(week.sessions) { entry in
                        VStack(alignment: .leading, spacing: ZOSpace.xs) {
                            Text(entry.title)
                                .zoText(.section)
                            Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened))
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                            Text("\(entry.completedSetCount) saved sets\(entry.endedEarly ? " · ended early" : "")")
                                .zoText(.body)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    Text("Workout duration is not shown because the saved history does not record elapsed time.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .zeroOneFeatureSurface()
                .zeroOneReveal(hasAppeared, delay: 0.16)
            }
            .padding(.horizontal, ZOSpace.xl)
            .padding(.vertical, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("This week")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasAppeared = true }
    }
}

private struct ProgressLoadChoicesSection: View {
    let reviews: [ProgressLoadReview]
    let repository: WorkoutLoadChoiceRepository?

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneProgressionAllowed) private var progressionAllowed
    @State private var failedReviewID: ExerciseID?

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("NEXT LOAD")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            Text("Your call, every time")
                .zoText(.title)
            if !progressionAllowed {
                Text("Higher-load suggestions are on hold while you review recovery and fuelling.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            } else if reviews.isEmpty {
                Text("No higher load is supported by the latest saved sets in this plan. Keep training at a load that feels right.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(progressionAllowed ? reviews : []) { review in
                let opportunity = review.upgrade.opportunity
                let selection = repository?.choice(
                    for: review.upgrade, sourceSessionID: review.sourceSessionID
                )
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(review.upgrade.exerciseName)
                        .zoText(.section)
                    Text("Every planned set reached \(review.upgrade.targetRepUpperBound) reps at \(opportunity.previousLoad.displayText) on \(review.completedAt.formatted(date: .abbreviated, time: .omitted)).")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text("A small step to \(opportunity.suggestedLoad.displayText) is available. Warm up as usual; keep the prior load if any rep felt unsafe.")
                        .zoText(.body)
                    if let repository {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: ZOSpace.s) {
                                choiceButton("Plan \(opportunity.suggestedLoad.displayText)", .tryNext, review, selection, repository)
                                choiceButton("Keep \(opportunity.previousLoad.displayText)", .repeatPrevious, review, selection, repository)
                            }
                            VStack(spacing: ZOSpace.s) {
                                choiceButton("Plan \(opportunity.suggestedLoad.displayText)", .tryNext, review, selection, repository)
                                choiceButton("Keep \(opportunity.previousLoad.displayText)", .repeatPrevious, review, selection, repository)
                            }
                        }
                    } else {
                        Text("You can choose your next load in the workout.")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    if failedReviewID == review.id {
                        Text("Choice not saved. Your previous choice is unchanged; try again.")
                            .zoText(.caption)
                            .foregroundStyle(theme.destructivePrimary)
                    }
                }
                .padding(.top, ZOSpace.s)
            }
            Text("Suggestions use saved sets and current recovery checks. Body-weight readings never change exercise loads.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .zeroOneFeatureSurface()
    }

    private func choiceButton(
        _ title: String,
        _ choice: WorkoutLoadChoiceSelection,
        _ review: ProgressLoadReview,
        _ current: WorkoutLoadChoiceSelection?,
        _ repository: WorkoutLoadChoiceRepository
    ) -> some View {
        Button {
            failedReviewID = repository.choose(
                choice, for: review.upgrade, sourceSessionID: review.sourceSessionID
            ) ? nil : review.id
        } label: {
            Text(title)
                .zoText(.section)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, ZOSpace.s)
                .background(
                    current == choice ? theme.accentFill : theme.surfaceSecondary,
                    in: RoundedRectangle(cornerRadius: ZORadius.small)
                )
                .foregroundStyle(current == choice ? Color.black : theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current == choice ? .isSelected : [])
    }
}

private struct WorkoutActivitySection: View {
    let historyState: WorkoutHistorySurfaceState

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Group {
            switch historyState {
            case .empty:
                ZeroOneEmptyState(
                    label: "Training activity",
                    title: "Your first session starts the story",
                    message: "Completed workouts will appear here. Rest days won't erase your work."
                )
            case .unavailable:
                ZeroOneEmptyState(
                    label: "Training activity",
                    title: "History unavailable",
                    message: "Your local history could not be read. No training totals are shown until it recovers."
                )
            case let .entries(entries):
                let activity = WorkoutActivitySummary(entries: entries, now: .now, calendar: .current)
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text("THIS MONTH")
                        .zoText(.caption)

                        .foregroundStyle(theme.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                        Text(activity.thisMonthCount.formatted())
                            .zoText(.metric)
                            .contentTransition(.numericText())
                        Text(activity.thisMonthCount == 1 ? "workout" : "workouts")
                            .zoText(.section)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)

                    Text("\(activity.thisWeekCount) this week · \(activity.thisMonthSetCount) sets this month")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)

                    WorkoutMonthCalendar(activity: activity, calendar: .current)

                    Chart(Array(activity.months.suffix(4))) { month in
                        BarMark(
                            x: .value("Month", month.start, unit: .month),
                            y: .value("Completed workouts", month.workoutCount)
                        )
                        .foregroundStyle(theme.textPrimary.opacity(0.8))
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(theme.strokeSubtle)
                            AxisValueLabel().foregroundStyle(theme.textSecondary)
                        }
                    }
                    .frame(height: 150)
                    .accessibilityLabel("Completed workouts by month")
                    .accessibilityValue(activity.months.suffix(4).map {
                        $0.start.formatted(.dateTime.month(.wide).year()) + ": " + $0.workoutCount.formatted()
                    }.joined(separator: "; "))

                    Text("Finished sessions, including those ended early. Saved on this iPhone.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .zeroOneFeatureSurface()
            }
        }
    }
}

struct WorkoutMonthCalendar: View {
    private struct WeekdayLabel: Identifiable {
        let weekday: Int
        let name: String

        var id: Int { weekday }
    }

    let activity: WorkoutActivitySummary
    let calendar: Calendar

    @Environment(\.zeroOneTheme) private var theme

    private var weekdayLabels: [WeekdayLabel] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let weekdayIndex = (calendar.firstWeekday - 1 + offset) % 7
            return WeekdayLabel(weekday: weekdayIndex + 1, name: names[weekdayIndex])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(weekdayLabels) { label in
                    Text(label.name)
                        .zoText(.mini)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .accessibilityHidden(true)
                }
                ForEach(0..<activity.leadingWeekdayCount, id: \.self) { _ in
                    Color.clear
                        .frame(height: 38)
                        .accessibilityHidden(true)
                }
                ForEach(activity.monthDays) { day in
                    WorkoutMonthDayCell(day: day)
                }
            }

            Text("Filled: completed · outlined: ended early. Rest days never reset your count.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Training days this month")
    }
}

private struct WorkoutMonthDayCell: View {
    let day: WorkoutActivityDay

    @Environment(\.zeroOneTheme) private var theme

    private var hasCompleteWorkout: Bool {
        day.workoutCount > day.partialWorkoutCount
    }

    private var accessibilitySummary: String {
        let name = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard day.workoutCount > 0 else {
            return "\(name): \(day.isFuture ? "upcoming" : "no workout")"
        }
        let count = "\(day.workoutCount) \(day.workoutCount == 1 ? "workout" : "workouts")"
        let partial = day.partialWorkoutCount > 0
            ? ", \(day.partialWorkoutCount) ended early" : ""
        return "\(name): \(count)\(partial)"
    }

    var body: some View {
        Text(day.date.formatted(.dateTime.day()))
            .zoText(.caption).monospacedDigit()
            .foregroundStyle(hasCompleteWorkout ? theme.backgroundPrimary : theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background {
                if hasCompleteWorkout {
                    RoundedRectangle(cornerRadius: ZORadius.small)
                        .fill(theme.textPrimary)
                } else if day.workoutCount > 0 {
                    RoundedRectangle(cornerRadius: ZORadius.small)
                        .stroke(theme.textPrimary, lineWidth: 1.5)
                }
            }
            .overlay {
                if day.isToday {
                    RoundedRectangle(cornerRadius: ZORadius.small)
                        .stroke(theme.chartAccent, lineWidth: 2)
                }
            }
            .opacity(day.isFuture ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }
}

private struct WorkoutMuscleWeekSection: View {
    let week: WorkoutMuscleWeek
    let entries: [WorkoutHistoryDisplayItem]
    let targetReps: [ExerciseID: RepRange]

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var selectedRegion: WorkoutMuscleRegion?
    @State private var period = WorkoutMusclePeriod.week
    @State private var date = Date.now

    private var displayed: WorkoutMuscleWeek {
        WorkoutMuscleWeek(entries: period.entries(from: entries, containing: date, calendar: .autoupdatingCurrent),
                          now: date, calendar: .autoupdatingCurrent)
    }

    private var workedRegions: [WorkoutMuscleRegionLoad] {
        displayed.regions.filter { $0.score > 0 }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.region.rawValue < $1.region.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("MUSCLE WORK")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            Text("What your sets trained")
                .zoText(.display)
                .accessibilityAddTraits(.isHeader)
            ZOSegmentedControl("Muscle work period", selection: $period, options: WorkoutMusclePeriod.allCases.map { item in ZOSegment(value: item, label: Text(LocalizedStringKey(item.title))) })
            DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
            Text(localization.format("%1$@ · Saved working sets only", .text(period == .day
                 ? date.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))
                 : localization.format("%1$@ – %2$@", .text(displayed.start.formatted(.dateTime.month(.abbreviated).day().locale(localization.locale))),
                    .text(displayed.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day().locale(localization.locale)))))))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)



            if workedRegions.isEmpty {
                Text(localization.string(entries.isEmpty
                     ? "No sessions saved yet. Your trained areas will appear here after a workout."
                     : "No mapped working sets in this period. Rest days are part of training too."))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text("Choose a muscle group to see the saved workouts behind it.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                ForEach(workedRegions) { load in
                    Button { selectedRegion = load.region } label: {
                        VStack(alignment: .leading, spacing: ZOSpace.s) {
                        HStack(spacing: ZOSpace.s) {

                            Text(localization.string(load.region.title))
                            Spacer(minLength: ZOSpace.s)
                            Text(localization.format("%1$lld direct · %2$lld helping", .integer(load.directSets), .integer(load.helperSets)))
                                .foregroundStyle(theme.textSecondary)
                            Image(systemName: "chevron.right")
                                .zoIcon(ZOIcon.row)
                                .accessibilityHidden(true)
                        }
                          GeometryReader { geometry in
                            let maximum = max(1, workedRegions.map { $0.directSets + $0.helperSets }.max() ?? 1)
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.textPrimary)
                                    .frame(width: max(0, geometry.size.width * CGFloat(load.directSets) / CGFloat(maximum) - 1))
                                RoundedRectangle(cornerRadius: 3).fill(theme.textSecondary)
                                    .frame(width: max(0, geometry.size.width * CGFloat(load.helperSets) / CGFloat(maximum) - 1))
                            }
                          }
                          .frame(height: 6).accessibilityHidden(true)
                        }
                        .zoText(.label)
                        .frame(minHeight: 64)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                     .accessibilityLabel(localization.format("%1$@: %2$lld direct sets, %3$lld helping sets. Show saved workouts.",
                            .text(localization.string(load.region.title)), .integer(load.directSets), .integer(load.helperSets)))
                }
            }

            Text("Direct and helping sets are shown separately. These are saved sets, not muscle growth or recovery.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            if displayed.sessionsWithoutExerciseDetails > 0 {
                Text("Some older sessions have no exercise details and are excluded from these counts.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            if displayed.setsWithoutMuscleMapping > 0 {
                Text("Some saved sets have unknown muscle labels and are excluded from these counts.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .zeroOneFeatureSurface()
        .sheet(item: $selectedRegion) { region in
            Group {
                WorkoutMuscleRegionSheet(
                    region: region, week: displayed, entries: entries, targetReps: targetReps
                )
            }
            .zoSheet()
        }
    }

    private func select(_ region: WorkoutMuscleRegion) { selectedRegion = region }

    private func tint(for tier: Int) -> Color {
        switch tier {
        case 1: theme.chartAccent.opacity(0.42)
        case 2: theme.chartAccent.opacity(0.72)
        case 3: theme.chartAccent
        default: theme.textSecondary.opacity(0.22)
        }
    }
}

private struct WorkoutMuscleRegionSheet: View {
    private struct SessionDetail: Identifiable {
        let entry: WorkoutHistoryDisplayItem
        let contributions: [WorkoutMuscleExerciseContribution]

        var id: UUID { entry.id }
    }

    let region: WorkoutMuscleRegion
    let week: WorkoutMuscleWeek
    let entries: [WorkoutHistoryDisplayItem]
    let targetReps: [ExerciseID: RepRange]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme

    private var load: WorkoutMuscleRegionLoad? {
        week.regions.first { $0.region == region }
    }

    private var sessions: [SessionDetail] {
        let relevant = week.contributions.filter { $0.region == region }
        let ids = Set(relevant.map(\.sessionID))
        return entries.filter { ids.contains($0.id) }
            .sorted { $0.completedAt > $1.completedAt }
            .map { entry in
                SessionDetail(
                    entry: entry,
                    contributions: relevant.filter { $0.sessionID == entry.id }
                )
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    Text("\(load?.directSets ?? 0) direct sets · \(load?.helperSets ?? 0) helping sets in this period")
                        .zoText(.section)
                    Text("A helping set contributes half to the map's colour. These are saved sets, not a measure of muscle growth.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                    if sessions.isEmpty {
                        Text("No saved working sets for this area in this period.")
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                    }
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: ZOSpace.xs) {
                            Text(session.entry.title)
                                .zoText(.section)
                            Text("\(session.entry.completedAt.formatted(date: .abbreviated, time: .shortened))\(session.entry.endedEarly ? " · ended early" : "")")
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                            ForEach(session.contributions) { contribution in
                                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                                    NavigationLink {
                                        WorkoutExerciseHistoryDetailView(
                                            exerciseName: contribution.exerciseName,
                                            history: WorkoutExerciseHistory(
                                                exerciseID: contribution.exerciseID,
                                                entries: entries
                                            ),
                                            targetReps: targetReps[contribution.exerciseID]
                                        )
                                    } label: {
                                        HStack(spacing: ZOSpace.s) {
                                            Text("\(contribution.exerciseName) · \(contribution.completedSets.count) \(contribution.isDirect ? "direct" : "helping") \(contribution.completedSets.count == 1 ? "set" : "sets")")
                                                .zoText(.section)
                                            Spacer(minLength: ZOSpace.s)
                                            Image(systemName: "chevron.right")
                                                .zoIcon(ZOIcon.row)
                                                .accessibilityHidden(true)
                                        }
                                        .frame(minHeight: 48, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(contribution.exerciseName), \(contribution.completedSets.count) saved sets. Show exercise history.")
                                    ForEach(contribution.completedSets) { set in
                                        Text(set.isTimed ? set.performanceText : "\(set.load.displayText) × \(set.performanceText)")
                                            .zoText(.caption).monospacedDigit()
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                }
                                .padding(.top, ZOSpace.xs)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                }
                .padding(ZOSpace.l)
            }
            .navigationTitle(region.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct WorkoutExerciseHistoryDetailView: View {
    let exerciseName: String
    let history: WorkoutExerciseHistory
    let targetReps: RepRange?

    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZOSpace.l) {
                Text("SAVED EXERCISE HISTORY")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(exerciseName)
                    .zoText(.title)
                    .accessibilityAddTraits(.isHeader)
                Text("These are your recorded sets, newest first. Older workout summaries without set details are not shown.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)

                if history.items.isEmpty {
                    Text("No saved sets for this exercise yet.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(history.items) { item in
                    WorkoutExerciseHistoryCard(item: item, targetReps: targetReps)
                }
            }
            .padding(ZOSpace.l)
        }
        .background(theme.backgroundPrimary)
        .navigationTitle("Exercise history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkoutExerciseHistoryCard: View {
    let item: WorkoutExerciseHistoryItem
    let targetReps: RepRange?

    @Environment(\.zeroOneTheme) private var theme

    private var maxReps: Int {
        max(1, max(targetReps?.upperBound ?? 0, item.completedSets.map(\.reps).max() ?? 1))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnsRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text(item.sessionTitle)
                .zoText(.section)
            Text("\(item.completedAt.formatted(date: .abbreviated, time: .shortened))\(item.endedEarly ? " · ended early" : "")")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)

            if !item.completedSets.contains(where: \.isTimed) {
              ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: ZOSpace.s) {
                    ForEach(Array(item.completedSets.enumerated()), id: \.element.id) { index, set in
                        VStack(spacing: 4) {
                            Text(set.reps.formatted())
                                .zoText(.caption).monospacedDigit()
                            ZStack(alignment: .bottom) {
                                if let targetReps {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(theme.textSecondary.opacity(0.18))
                                        .frame(width: 28, height: CGFloat(targetReps.upperBound - targetReps.lowerBound + 1) / CGFloat(maxReps) * 64)
                                        .frame(height: 64, alignment: .top)
                                }
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(set.reps >= (targetReps?.upperBound ?? Int.max)
                                          ? theme.chartAccent : theme.textSecondary)
                                    .frame(width: 24, height: max(14, CGFloat(set.reps) / CGFloat(maxReps) * 64))
                                    .scaleEffect(y: columnsRevealed ? 1 : (reduceMotion ? 1 : 0.05), anchor: .bottom)
                                    .opacity(columnsRevealed ? 1 : 0)
                                    .animation(reduceMotion ? .easeOut(duration: 0.2)
                                               : .easeOut(duration: 0.24).delay(Double(index) * 0.07),
                                               value: columnsRevealed)
                            }
                            .frame(height: 64, alignment: .bottom)
                            Text("\(index + 1)")
                                .zoText(.mini).monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .frame(minHeight: 96, alignment: .bottomLeading)
            }
            .scrollIndicators(.hidden)
            .accessibilityHidden(true)

            if let targetReps {
                Text("Shaded range is the current plan's \(targetReps.lowerBound)–\(targetReps.upperBound) reps. Highlighted bars reached its top. Earlier plans may have differed.")
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            }

            ForEach(Array(item.completedSets.enumerated()), id: \.element.id) { index, set in
                Text("Set \(index + 1): \(set.isTimed ? set.performanceText : "\(set.load.displayText) × \(set.performanceText)")")
                    .zoText(.caption).monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .zeroOneFeatureSurface()
        .onAppear { columnsRevealed = true }
    }
}

private struct StrengthPoint: Identifiable {
    let id: String
    let label: String
    let load: Double
}

private struct VolumePoint: Identifiable {
    let id: UUID
    let exercise: String
    let volume: Double
    let unit: LoadUnit

    var formattedVolume: String {
        volume.formatted(.number.notation(.compactName)) + " " + unit.rawValue
    }
}

private struct VolumeSection: Identifiable {
    var id: String { unit.rawValue }
    let unit: LoadUnit
    let points: [VolumePoint]

    var accessibilityText: String {
        points.map { $0.exercise + ", " + $0.formattedVolume }.joined(separator: "; ")
    }
}

private struct ProgressSummary {
    let strengthPoints: [StrengthPoint]
    let volumeSections: [VolumeSection]
    let strengthDomain: ClosedRange<Double>
    let leadTargetText: String
    let leadTargetUnit: String
    let totalPlannedVolumeText: String
    let insight: String

    var hasTargets: Bool { !strengthPoints.isEmpty }

    init(session: WorkoutSession) {
        let validExercises = session.exercises.filter { exercise in
            let plan = exercise.plan
            return plan.targetLoad.value.isFinite
                && plan.targetLoad.value >= 0
                && !plan.isTimed && plan.targetReps.upperBound > 0
                && plan.plannedSetCount > 0
        }
        let leadExercise = validExercises.first?.plan
        if let leadExercise {
            strengthPoints = [
                StrengthPoint(
                    id: "target",
                    label: "Target",
                    load: leadExercise.targetLoad.value
                )
            ]
            let padding = max(1, leadExercise.targetLoad.value * 0.1)
            strengthDomain = max(0, leadExercise.targetLoad.value - padding) ... (leadExercise.targetLoad.value + padding)
            leadTargetText = Self.formatted(load: leadExercise.targetLoad)
            leadTargetUnit = leadExercise.targetLoad.unit.rawValue
        } else {
            strengthPoints = []
            strengthDomain = 0 ... 1
            leadTargetText = "Not available"
            leadTargetUnit = "the prescribed unit"
        }

        let volumePoints = validExercises.map { exercise in
            let plan = exercise.plan
            return VolumePoint(
                id: exercise.id,
                exercise: Self.shortName(plan.name),
                volume: plan.targetLoad.value * Double(plan.targetReps.upperBound * plan.plannedSetCount),
                unit: plan.targetLoad.unit
            )
        }
        totalPlannedVolumeText = [LoadUnit.kilograms, .pounds]
            .compactMap { unit -> String? in
                let points = volumePoints.filter { $0.unit == unit }
                guard !points.isEmpty else { return nil }
                let total = points.reduce(0) { $0 + $1.volume }
                return total.formatted(.number.notation(.compactName)) + " " + unit.rawValue
            }
            .joined(separator: " / ")
        volumeSections = [LoadUnit.kilograms, .pounds]
            .compactMap { unit in
                let points = volumePoints.filter { $0.unit == unit }
                guard !points.isEmpty else { return nil }
                return VolumeSection(unit: unit, points: points)
            }
        insight = "Review the planned loads, repetitions, and set counts before you train."
    }

    private static func formatted(load: Load) -> String {
        load.value.formatted(.number.precision(.fractionLength(0 ... 1))) + " " + load.unit.rawValue
    }

    private static func shortName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "Barbell ", with: "")
            .replacingOccurrences(of: "Chest-Supported ", with: "")
            .replacingOccurrences(of: "Seated Dumbbell ", with: "DB ")
    }
}
