import SwiftUI
import Charts
import UIKit

struct StepsDayView: View {
    let repository: StepsDayRepository
    let distanceUnit: ZeroOneDistancePreference
    /// Root supplies the user's actual goal. Nil keeps the chart and reading without a fabricated target.
    let dailyGoal: Int?
    let onEditDailyGoal: (() -> Void)?

    init(repository: StepsDayRepository, distanceUnit: ZeroOneDistancePreference,
         dailyGoal: Int? = nil, onEditDailyGoal: (() -> Void)? = nil) {
        self.repository = repository
        self.distanceUnit = distanceUnit
        self.dailyGoal = dailyGoal
        self.onEditDailyGoal = onEditDailyGoal
    }

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var observationGate = StepsGoalObservationGate()
    @State private var goalConnectionContextID = UUID()
    @State private var goalMomentTheme: ZeroOneThemeTokens?
    @State private var goalMoment: StepsGoalObservationGate.Attainment?
    @State private var goalBurst: StepsGoalBurstStart?
    @State private var goalFeedbackID: UUID?
    @State private var showsGoalDisc = false


    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                ScrollView {
                    VStack(alignment: .leading, spacing: ZOSpace.m) {
                        switch repository.status {
                        case .notConnected:
                            Text("See your steps").zoThemeText(.title).accessibilityAddTraits(.isHeader)
                            Text("Steps and walking or running distance come from Apple Health. 01 only reads them when you choose to connect.")
                                .zoText(.body).foregroundStyle(theme.textSecondary)
                            Button("Connect Apple Health") { Task { await connectSteps() } }
                                .buttonStyle(ZOButtonStyle(.primary))
                            Button("Not now") { dismiss() }.buttonStyle(ZOButtonStyle(.secondary))
                        case .connecting:
                            ProgressView("Connecting to Apple Health…")
                        case .unavailable:
                            Text("Apple Health isn't available on this device.").zoText(.body)
                        case .connected:
                            let presentation = StepsDayPresentation(reading: repository.currentReading(on: timeline.date, calendar: calendar),
                                now: timeline.date, calendar: calendar, dailyGoal: dailyGoal, isStale: repository.issue == .readFailed)
                            if presentation.reading != nil {
                                readingContent(presentation, now: timeline.date)
                            } else {
                                Text(repository.isRefreshing ? localization.string("Reading today's movement…")
                                     : localization.string("Today's movement hasn't loaded yet.")).zoText(.body)
                            }
                            Button { Task { await refreshSteps(allowCelebration: true) } } label: {
                                HStack(spacing: ZOSpace.s) {
                                    Text("Refresh")
                                    if repository.isRefreshing { ProgressView().accessibilityHidden(true) }
                                }
                            }
                            .buttonStyle(ZOButtonStyle(.secondary)).disabled(repository.isRefreshing)
                            .accessibilityValue(repository.isRefreshing ? localization.string("Refreshing") : "")
                        }
                        if let issue = repository.issue {
                            Text(localization.string(issue.message)).zoText(.body).foregroundStyle(theme.textSecondary)
                        }
                        Text("Your Health readings stay on this iPhone. Nothing here starts GPS recording or changes your workout.")
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, ZOSpace.xl).padding(.top, ZOSpace.l).padding(.bottom, ZOSpace.xxl)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .overlayPreferenceValue(StepsGoalRingAnchorKey.self) { anchor in
                    if let anchor, let goalBurst,
                       goalBurst.theme.designTheme != .core || !reduceMotion {
                        GeometryReader { proxy in
                            let origin = CGPoint(x: proxy[anchor].midX, y: proxy[anchor].midY)
                            if goalBurst.theme.designTheme == .core {
                                // Preserve the installed Core burst and its parent-owned lifetime.
                                StepsGoalBurst(start: goalBurst, origin: origin, theme: goalBurst.theme)
                            } else {
                                StepsThemeGoalBurst(start: goalBurst, origin: origin,
                                    onFinish: finishGoalBurst)
                            }
                        }
                        .id(goalBurst.id)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .refreshable { await refreshSteps(allowCelebration: true) }
                .task(id: calendar.startOfDay(for: timeline.date)) {
                    guard scenePhase == .active else { return }
                    invalidateGoalMoment()
                    await refreshSteps(allowCelebration: false)
                }
                .onChange(of: calendar.startOfDay(for: timeline.date)) { _, _ in invalidateGoalMoment() }
            }
            .background(theme.surfacePrimary.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .toolbarBackground(theme.surfacePrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            .tint(theme.textPrimary)
            .navigationTitle("Steps").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { ZOAppIcon("xmark").frame(width: 44, height: 44) }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel("Close")
                }
            }
            .sensoryFeedback(.success, trigger: goalFeedbackID)
            .onChange(of: scenePhase) { _, phase in
                invalidateGoalMoment()
                if phase == .active { Task { await refreshSteps(allowCelebration: false) } }
            }
            .onChange(of: dailyGoal) { _, _ in invalidateGoalMoment() }
            .onChange(of: calendar) { _, _ in invalidateGoalMoment() }
            .onChange(of: repository.status) { _, status in
                if status == .connecting { invalidateGoalMoment(invalidateConnection: false) }
                else if status != .connected { invalidateGoalMoment() }
            }
            .onChange(of: repository.issue) { _, issue in
                if issue != nil { invalidateGoalMoment() }
            }
            .onChange(of: repository.reading) { _, _ in
                if let context = goalMoment?.context ?? goalBurst?.context,
                   goalObservation(now: .now).map({ $0.context == context && $0.attained }) != true {
                    invalidateGoalMoment()
                }
            }
            .onChange(of: reduceMotion) { _, value in
                if var burst = goalBurst {
                    goalBurst = burst.observeReduceMotion(value) ? burst : nil
                }
            }
            .onDisappear { invalidateGoalMoment() }
        }
    }

    @ViewBuilder
    private func readingContent(_ presentation: StepsDayPresentation, now: Date) -> some View {
        if let reading = presentation.reading {
            if let count = reading.totalSteps {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ZOSpace.m) { goalRing(presentation); stepValue(count, presentation: presentation) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: ZOSpace.m) { goalRing(presentation); stepValue(count, presentation: presentation) }
                }
                Text(distanceText(reading.distanceMeters)).zoText(.caption).foregroundStyle(theme.textSecondary)
            } else {
                Text("No readable step total today").zoThemeText(.title)
                Text("There may be no recorded steps, or access may be off. Apple Health doesn't tell 01 which.")
                    .zoText(.body).foregroundStyle(theme.textSecondary)
                if let distance = reading.distanceMeters {
                    Text(distanceText(distance)).zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }

            if !presentation.hours.isEmpty, let interval = presentation.dayInterval {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Chart(presentation.hours) { hour in
                        if let count = hour.count {
                            BarMark(x: .value(localization.string("Hour"), hour.startedAt, unit: .hour),
                                    y: .value(localization.string("Steps"), count), width: .inset(2))
                                .foregroundStyle(calendar.isDate(hour.startedAt, equalTo: now, toGranularity: .hour)
                                    ? theme.textPrimary : theme.textTertiary.opacity(0.45))
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                                .accessibilityLabel(hour.startedAt.formatted(.dateTime.hour().minute().locale(localization.locale)))
                                .accessibilityValue(localization.format("%1$lld steps", .integer(count)))
                        }
                    }
                    .chartXScale(domain: interval.start ... interval.end)
                    .chartYScale(domain: 0 ... max(1, presentation.hours.compactMap(\.count).max() ?? 1))
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                            AxisValueLabel(verticalSpacing: 6) {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(localization.locale)))
                                        .zoProofText(.mini, size: 11, lineHeight: 13, weight: 400)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                    }
                    .chartPlotStyle { $0.frame(height: 96) }
                    .accessibilityLabel("Steps by hour")
                    Text("From Apple Health. The current hour is highlighted. Hours without readable samples are left blank.")
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
                .padding(ZOSpace.l).zoThemeCardSurface(background: theme.surfaceSecondary)
            }
            if let goal = presentation.goal {
                if let onEditDailyGoal {
                    Button(action: onEditDailyGoal) { goalRow(goal, editable: true) }.buttonStyle(.plain)
                        .accessibilityHint("Change your daily step goal")
                } else { goalRow(goal, editable: false) }
            }
            Text(localization.format(presentation.isStale ? "Last available reading · %1$@" : "Apple Health · updated %1$@",
                .text(reading.readAt.formatted(.dateTime.hour().minute().locale(localization.locale)))))
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            if reading.totalSteps == nil || reading.distanceMeters == nil {
                Button("Open app settings") { openSettings() }.buttonStyle(ZOButtonStyle(.secondary))
                Text("You can also review 01's read access in Apple Health.").zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func goalRing(_ presentation: StepsDayPresentation) -> some View {
        if let progress = presentation.progress {
            if let moment = goalMoment,
               goalObservation(now: .now).map({ $0.context == moment.context && $0.attained }) == true {
                StepsGoalMomentRing(moment: moment, theme: goalMomentTheme ?? theme,
                    onLand: { landGoalMoment(moment) },
                    onSettle: { settleGoalMoment(moment.id) },
                    onFinish: { finishGoalMoment(moment.id) })
                    .id(moment.id)
                    .anchorPreference(key: StepsGoalRingAnchorKey.self, value: .bounds) { $0 }
            } else {
            ZStack {
                // Radius32/stroke8 inside72 matches motion.js's static SVG geometry.
                Circle().strokeBorder(theme.surfaceTertiary, lineWidth: 8)
                Circle().trim(from: 0, to: progress)
                    .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(4)
                    .shadow(color: theme.designTheme == .retro && theme.colorScheme == .dark
                        ? Color(zoHex: 0xFF8A3D) : .clear, radius: 3)
                ZOAppIcon("shoeprints.fill", size: 24).foregroundStyle(theme.textPrimary)
            }
            .frame(width: 72, height: 72)
            .overlay(alignment: .bottomTrailing) {
                if presentation.goalReached {
                    ZOAppIcon("checkmark", size: 25.92 * 0.62).foregroundStyle(theme.backgroundPrimary)
                        .frame(width: 25.92, height: 25.92).background(theme.textPrimary, in: Circle())
                        .background { Circle().fill(theme.surfacePrimary).padding(-2) }
                        .offset(x: 2.16, y: 2.16)
                }
            }
            .accessibilityHidden(true)
            .anchorPreference(key: StepsGoalRingAnchorKey.self, value: .bounds) { $0 }
            }
        }
    }

    private func stepValue(_ count: Int, presentation: StepsDayPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(count.formatted(.number.locale(localization.locale))).zoThemeText(.metric)
                        .accessibilityLabel(localization.format("%1$lld steps today", .integer(count)))
                    if let goal = presentation.goal {
                        Text(localization.format("of %1$lld", .integer(goal)))
                            .zoProofText(.label, size: 15, lineHeight: 20, weight: 500).foregroundStyle(theme.textSecondary)
                    }
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count.formatted(.number.locale(localization.locale))).zoThemeText(.metric)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(localization.format("%1$lld steps today", .integer(count)))
                    if let goal = presentation.goal {
                        Text(localization.format("of %1$lld", .integer(goal)))
                            .zoProofText(.label, size: 15, lineHeight: 20, weight: 500)
                            .foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if presentation.goalReached {
                HStack(spacing: 6) {
                    if goalMoment != nil && showsGoalDisc && !reduceMotion {
                        Circle().fill((goalMomentTheme ?? theme).accentFill).frame(width: 14, height: 14)
                            .overlay { Circle().strokeBorder((goalMomentTheme ?? theme).accentEdge, lineWidth: 1) }
                            .accessibilityHidden(true)
                    } else {
                        ZOAppIcon("checkmark", size: 16).accessibilityHidden(true)
                    }
                    Text("Goal reached").zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.backgroundPrimary)
                .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 5).frame(minHeight: 28)
                .background(theme.textPrimary, in: Capsule())
                .accessibilityElement(children: .combine)
                .opacity(goalMoment != nil && goalFeedbackID != goalMoment?.id && !reduceMotion ? 0 : 1)
                .animation(ZOMotion.crossfade(), value: goalFeedbackID)
            }
        }
    }

    private func goalRow(_ goal: Int, editable: Bool) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Daily goal").zoText(.section).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ZOSpace.xs) {
                        Text(goal.formatted(.number.locale(localization.locale))).zoText(.body)
                            .foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if editable { ZOAppIcon("chevron.right", size: 16).foregroundStyle(theme.textTertiary).accessibilityHidden(true) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: ZOSpace.m) {
                    Text("Daily goal").zoText(.section).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(goal.formatted(.number.locale(localization.locale))).zoText(.body)
                        .foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if editable { ZOAppIcon("chevron.right", size: 16).foregroundStyle(theme.textTertiary).accessibilityHidden(true) }
                }
            }
        }
        .foregroundStyle(theme.textPrimary).padding(.horizontal, ZOSpace.l).padding(.vertical, ZOSpace.s).frame(minHeight: 56)
        .zoThemeCardSurface(background: theme.surfaceSecondary)
        .accessibilityElement(children: .combine)
    }

    private func goalObservation(now: Date) -> StepsGoalObservation? {
        let reading = repository.currentReading(on: now, calendar: calendar)
        return StepsGoalObservation(calendar: calendar, now: now, goal: dailyGoal,
            readingDayStart: reading?.dayStart, readAt: reading?.readAt, steps: reading?.totalSteps,
            isAvailable: scenePhase == .active && repository.status == .connected && repository.issue == nil)
    }

    @MainActor private func refreshSteps(allowCelebration: Bool) async {
        guard !repository.isRefreshing else { return }
        let ticket = observationGate.begin(goalObservation(now: .now), allowCelebration: allowCelebration)
        await repository.refresh()
        guard !Task.isCancelled else { observationGate.invalidate(); return }
        if let attainment = observationGate.complete(ticket, with: goalObservation(now: .now)) {
            // One earned event captures presentation; a later theme change never earns/restarts it.
            goalMomentTheme = theme
            goalMoment = attainment
        }
    }

    @MainActor private func connectSteps() async {
        guard repository.status == .notConnected, !repository.isRefreshing else { return }
        invalidateGoalMoment()
        let contextID = goalConnectionContextID
        await repository.connect()
        guard contextID == goalConnectionContextID else { return }
        guard !Task.isCancelled else { invalidateGoalMoment(); return }
        let ticket = observationGate.begin(nil, allowCelebration: false)
        _ = observationGate.complete(ticket, with: goalObservation(now: .now))
    }

    private func invalidateGoalMoment(invalidateConnection: Bool = true) {
        if invalidateConnection { goalConnectionContextID = UUID() }
        observationGate.invalidate()
        goalMoment = nil
        goalMomentTheme = nil
        goalBurst = nil
        showsGoalDisc = false
    }

    private func landGoalMoment(_ moment: StepsGoalObservationGate.Attainment) {
        guard goalMoment?.id == moment.id, goalFeedbackID != moment.id,
              goalObservation(now: .now).map({ $0.context == moment.context && $0.attained }) == true else { return }
        goalFeedbackID = moment.id
        showsGoalDisc = !reduceMotion
        goalBurst = StepsGoalBurstStart(moment: moment, theme: goalMomentTheme ?? theme,
                                       startedAt: ContinuousClock.now, reduceMotion: reduceMotion)
        UIAccessibility.post(notification: .announcement, argument: localization.string("Goal reached"))
    }

    private func settleGoalMoment(_ id: UUID) {
        guard goalMoment?.id == id else { return }
        showsGoalDisc = false
    }

    private func finishGoalMoment(_ id: UUID) {
        guard goalMoment?.id == id else { return }
        goalMoment = nil
        goalMomentTheme = nil
        // Core keeps the exact installed 2280ms parent timeline. Non-Core ornaments
        // may finish later, measured from their original land/burst instant.
        if goalBurst?.theme.designTheme == .core { goalBurst = nil }
        showsGoalDisc = false
    }

    private func finishGoalBurst(_ id: UUID) {
        guard goalBurst?.id == id else { return }
        goalBurst = nil
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func distanceText(_ meters: Double?) -> String {
        guard let meters else { return localization.string("Distance unavailable") }
        let unit: UnitLength = distanceUnit == .miles ? .miles : .kilometers
        let value = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value
        return localization.format("%1$@ %2$@ today", .text(value.formatted(.number.precision(.fractionLength(1)).locale(localization.locale))),
                                   .text(distanceUnit.rawValue))
    }
}

// The transient moment is private to this Steps presentation. No shared theme,
// Health source, persisted goal or navigation API is introduced.
private struct StepsGoalRingAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// UI-only lifetime seeded by an already qualified attainment. No new event gate.
/// Internal solely for deterministic tests of the actual presentation boundary.
struct StepsGoalBurstStart {
    let moment: StepsGoalObservationGate.Attainment
    let theme: ZeroOneThemeTokens
    let startedAt: ContinuousClock.Instant
    private(set) var reducedMotionLatched: Bool
    var id: UUID { moment.id }
    var context: StepsGoalObservation.Context { moment.context }

    init?(moment: StepsGoalObservationGate.Attainment, theme: ZeroOneThemeTokens,
          startedAt: ContinuousClock.Instant, reduceMotion: Bool) {
        // Core retains its original no-particles Reduced Motion confirmation.
        guard theme.designTheme != .core || !reduceMotion else { return nil }
        self.moment = moment
        self.theme = theme
        self.startedAt = startedAt
        reducedMotionLatched = reduceMotion
    }

    /// Once travel is removed it never resumes for this event, even after a toggle back.
    /// False tells the actual parent to remove the Core burst immediately.
    mutating func observeReduceMotion(_ value: Bool) -> Bool {
        guard value else { return true }
        guard theme.designTheme != .core else { return false }
        reducedMotionLatched = true
        return true
    }

    func usesReducedMotion(live value: Bool) -> Bool { value || reducedMotionLatched }

    /// Core's removal remains parent-owned; only Non-Core gets a separate deadline.
    /// Always subtract original elapsed time. A toggle cannot buy a fresh lifetime.
    func remainingTime(elapsed: Double, liveReduceMotion: Bool) -> Double? {
        guard theme.designTheme != .core else { return nil }
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        let deadline = ThemeWinTimeline.cleanupDeadline(theme: theme.designTheme,
            tier: .goal(origin: .zero), reduceMotion: usesReducedMotion(live: liveReduceMotion))
        return max(0, deadline - elapsed)
    }
}

private func stepsMomentElapsed(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: ContinuousClock.now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}

private struct StepsGoalMomentRing: View {
    let moment: StepsGoalObservationGate.Attainment
    let theme: ZeroOneThemeTokens
    let onLand: () -> Void
    let onSettle: () -> Void
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = ContinuousClock.now
    @State private var settledWithoutTravel = false

    var body: some View {
        TimelineView(.animation) { _ in
            let frame = StepsGoalMomentTiming.frame(elapsed: stepsMomentElapsed(since: startedAt),
                fromProgress: moment.fromProgress, reduceMotion: reduceMotion || settledWithoutTravel)
            ZStack {
                Circle().fill(theme.accentFill)
                    .overlay { Circle().strokeBorder(theme.accentEdge, lineWidth: 1) }
                    .scaleEffect(frame.discScale).opacity(frame.discOpacity)
                ZStack {
                    Circle().strokeBorder(theme.surfaceTertiary, lineWidth: 8)
                    Circle().trim(from: 0, to: frame.progress)
                        .stroke(theme.textPrimary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(4)
                        .shadow(color: theme.designTheme == .retro && theme.colorScheme == .dark
                            ? Color(zoHex: 0xFF8A3D) : .clear, radius: 3)
                }.opacity(frame.ringOpacity)
                ZOAppIcon("shoeprints.fill", size: 24)
                    .foregroundStyle(frame.onAccent ? theme.onAccent : theme.textPrimary)
            }
            .frame(width: 72, height: 72)
            .overlay(alignment: .bottomTrailing) {
                ZOAppIcon("checkmark", size: 25.92 * 0.62).foregroundStyle(theme.backgroundPrimary)
                    .frame(width: 25.92, height: 25.92).background(theme.textPrimary, in: Circle())
                    .background { Circle().fill(theme.surfacePrimary).padding(-2) }
                    .scaleEffect(frame.checkScale).opacity(frame.checkOpacity)
                    .offset(x: 2.16, y: 2.16)
            }
        }
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            startedAt = ContinuousClock.now
            do {
                if reduceMotion || settledWithoutTravel {
                    settledWithoutTravel = true
                    onLand()
                    onSettle()
                    try await Task.sleep(for: .milliseconds(120))
                } else {
                    try await Task.sleep(for: .milliseconds(480))
                    try Task.checkCancellation()
                    onLand()
                    try await Task.sleep(for: .milliseconds(1_440))
                    try Task.checkCancellation()
                    onSettle()
                    try await Task.sleep(for: .milliseconds(360))
                }
                try Task.checkCancellation()
                onFinish()
            } catch is CancellationError {
                // Parent context/visibility invalidation or Reduce Motion change.
            } catch {
                onFinish()
            }
        }
    }
}

private struct StepsThemeGoalBurst: View {
    let start: StepsGoalBurstStart
    let origin: CGPoint
    let onFinish: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { _ in
            ThemeWinRenderer(theme: start.theme, tier: .goal(origin: origin),
                elapsed: stepsMomentElapsed(since: start.startedAt),
                reduceMotion: start.usesReducedMotion(live: reduceMotion))
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: start.usesReducedMotion(live: reduceMotion)) {
            guard let remaining = start.remainingTime(
                elapsed: stepsMomentElapsed(since: start.startedAt), liveReduceMotion: reduceMotion) else { return }
            do {
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                try Task.checkCancellation()
                // Parent rechecks the event ID; an obsolete cleanup cannot dismiss its successor.
                onFinish(start.id)
            } catch {
                // View removal, invalidated context or live Reduce Motion changed the task.
                return
            }
        }
    }
}

private struct StepsGoalBurst: View {
    let start: StepsGoalBurstStart
    let origin: CGPoint
    let theme: ZeroOneThemeTokens

    private var colors: [Color] {
        let dark = theme.colorScheme == .dark
        // Exact theme semantic data palette in dist/tokens.css / dist/themes.css.
        return [theme.accentFill, theme.textPrimary, theme.accentFill,
            Color(zoHex: dark ? 0xFF8A50 : 0xC2531C), Color(zoHex: dark ? 0xA08CFF : 0x6A4FD8),
            Color(zoHex: dark ? 0xF2C94C : 0x8F6A00), theme.textSecondary]
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = stepsMomentElapsed(since: start.startedAt)
            Canvas { context, _ in
                guard elapsed >= 0, elapsed < ZOMotion.Celebration.goal else { return }
                let p = StepsGoalMomentTiming.curve(elapsed / ZOMotion.Celebration.goal, 0.2, 0.6, 0.4, 1)
                // A deterministic per-event seed permits reproducible native captures.
                // Distribution, keyframes and geometry follow motion.js goal tier.
                var seed: UInt64 = start.id.uuidString.utf8.reduce(11) { ($0 &* 31) &+ UInt64($1) }
                func random() -> Double {
                    seed = (seed &* 9_301 &+ 49_297) % 233_280
                    return Double(seed) / 233_280
                }
                for i in 0..<ZOMotion.Celebration.goalParticles {
                    let angle = -Double.pi / 2 + (random() - 0.5) * 2.2
                    let velocity = 90 + random() * 90
                    let dx = cos(angle) * velocity
                    let peak = sin(angle) * velocity
                    let fall = 60 + random() * 60
                    let rotation = (random() - 0.5) * 900
                    let first = min(1, p / 0.35), last = max(0, (p - 0.35) / 0.65)
                    let x = p < 0.35 ? dx * 0.6 * first : dx * (0.6 + 0.4 * last)
                    let y = p < 0.35 ? peak * first : peak + fall * last
                    let spin = p < 0.35 ? rotation * 0.4 * first : rotation * (0.4 + 0.6 * last)
                    var particle = context
                    particle.opacity = p < 0.35 ? 1 : 1 - last
                    let rect = CGRect(x: 0, y: 0, width: i % 3 == 0 ? 7 : 6, height: i % 3 == 0 ? 7 : 10)
                    // CSS default transform-origin is the particle's own centre.
                    particle.translateBy(x: origin.x + x + rect.midX, y: origin.y + y + rect.midY)
                    particle.rotate(by: .degrees(spin))
                    particle.translateBy(x: -rect.midX, y: -rect.midY)
                    let shape = i % 3 == 0 ? Circle().path(in: rect) : RoundedRectangle(cornerRadius: 1.5).path(in: rect)
                    particle.fill(shape, with: .color(colors[i % colors.count]))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
