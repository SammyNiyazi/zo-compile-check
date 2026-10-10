import Charts
import StoreKit
import SwiftUI

/// Root controls entry and the once-per-trial cadence. This view only presents
/// supplied history and forwards Close/Keep going/Share. Keep going never buys.
struct MembershipTrialRecapView: View {
    let recap: MembershipTrialRecap?
    let renewal: MembershipRecapRenewal?
    let onClose: () -> Void
    var onShare: (() -> Void)? = nil
    @State private var showingManage = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar

    init(recap: MembershipTrialRecap? = nil,
         renewal: MembershipRecapRenewal? = nil,
         onClose: @escaping () -> Void,
         onShare: (() -> Void)? = nil) {
        self.recap = recap
        self.renewal = renewal
        self.onClose = onClose
        self.onShare = onShare
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                HStack(spacing: ZOSpace.s) {
                    Button(action: onClose) {
                        Image(systemName: "xmark").accessibilityHidden(true)
                    }
                    .buttonStyle(ZOButtonStyle(.round))
                    .accessibilityLabel(localization.string("Close"))
                    Text("Your 14 days").zoText(.section)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    Color.clear.frame(width: ZOSpace.hitTarget, height: ZOSpace.hitTarget)
                        .accessibilityHidden(true)
                }
                if let recap, recap.hasDisplayableFacts(calendar: calendar) {
                    Text("Look what you did in 14 days.")
                        .zoThemeText(.display)
                        .zoContextualHeadingSigil(role: .display, context: .directScrollDisplay)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    Text(recap.interval.start.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))
                         + " · " + recap.interval.end.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: ZOSpace.s) { summary(recap) }
                    } else {
                        HStack(spacing: ZOSpace.s) { summary(recap) }
                    }
                    if !recap.qualifiedStrength.isEmpty {
                        Text("Your lifts").zoText(.section)
                        VStack(spacing: ZOSpace.l) {
                            ForEach(recap.qualifiedStrength) { lift in strength(lift) }
                        }
                        .padding(ZOSpace.cardPadding)
                        .zoThemeCardSurface()
                    }
                    let weights = recap.weightPlot(calendar: calendar)
                    if !weights.isEmpty {
                        Text("Body weight").zoText(.section)
                        VStack(alignment: .leading, spacing: ZOSpace.s) {
                            Text("7-day average from Apple Health").zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                            if let latest = weights.last {
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(latest.kilograms.formatted(.number.precision(.fractionLength(1)).locale(localization.locale)))
                                        .zoThemeText(.metric)
                                    Text("kg")
                                        .zoProofText(.body, size: 15, lineHeight: 20, weight: 500, width: 100)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .accessibilityElement(children: .combine)
                                Text(latest.date.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)))
                                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                            }
                            Chart(weights) { point in
                                LineMark(x: .value(localization.string("Date"), point.date), y: .value(localization.string("kg"), point.kilograms),
                                         series: .value(localization.string("Segment"), point.segment))
                                    .foregroundStyle(theme.textPrimary)
                                PointMark(x: .value(localization.string("Date"), point.date), y: .value(localization.string("kg"), point.kilograms))
                                    .foregroundStyle(theme.textPrimary)
                            }
                            .environment(\.locale, localization.locale)
                            .accessibilityLabel(localization.string("Body weight"))
                            .chartYScale(domain: .automatic(includesZero: false))
                            .chartLegend(.hidden)
                            .frame(height: 112)
                            Text("Gaps remain gaps.").zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                        .padding(ZOSpace.cardPadding)
                        .zoThemeCardSurface()
                    }
                    if let days = recap.attendanceDays(calendar: calendar) {
                        Text("Showing up").zoText(.section)
                        VStack(alignment: .leading, spacing: ZOSpace.m) {
                            Text("Your two weeks").zoText(.section)
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(spacing: ZOSpace.m) {
                                    ForEach(days) { day in attendance(day) }
                                }
                            } else {
                                // Render only supplied days. Missing observations never become empty/rest days.
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ZOSpace.xs), count: 7),
                                          spacing: ZOSpace.m) {
                                    ForEach(days) { day in attendance(day) }
                                }
                            }
                        }
                        .padding(ZOSpace.cardPadding)
                        .zoThemeCardSurface()
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: ZOSpace.s) { activityMetrics(recap) }
                    } else {
                        HStack(alignment: .top, spacing: ZOSpace.s) { activityMetrics(recap) }
                    }
                    if !recap.readLessons.isEmpty {
                        Text("You learned").zoText(.section)
                        VStack(spacing: ZOSpace.m) {
                            ForEach(recap.readLessons) { lesson in
                                VStack(spacing: ZOSpace.m) {
                                    HStack(spacing: ZOSpace.m) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(theme.successPrimary)
                                            .accessibilityHidden(true)
                                        Text(verbatim: lesson.title).zoText(.section)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .accessibilityElement(children: .combine)
                                    if lesson.id != recap.readLessons.last?.id {
                                        Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                        }
                        .padding(ZOSpace.cardPadding)
                        .zoThemeCardSurface()
                    }
                    if let onShare {
                        Button(action: onShare) {
                            Label("Share my 14 days", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    }
                } else {
                    Text("Your trial recap is unavailable.").zoThemeText(.display)
                    Text("Your training stays on this iPhone. You can still manage your subscription with Apple.")
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: ZOSpace.s) {
                Button("Keep going", action: onClose).buttonStyle(ZOButtonStyle(.primary))
                    .accessibilityIdentifier("membership.recap.keepGoing")
                Text(renewalDetail).zoText(.caption).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Manage subscription") { showingManage = true }
                    .buttonStyle(ZOButtonStyle(.quiet))
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
        .manageSubscriptionsSheet(isPresented: $showingManage)
        .accessibilityAction(.escape, onClose)
    }

    @ViewBuilder private func summary(_ recap: MembershipTrialRecap) -> some View {
        if let count = MembershipTrialRecap.count(recap.workouts) {
            MembershipRecapMetric(title: "Workouts", value: count.formatted(.number.locale(localization.locale)))
        }
        if let count = MembershipTrialRecap.count(recap.completedSets) {
            MembershipRecapMetric(title: "Sets", value: count.formatted(.number.locale(localization.locale)))
        }
        if let count = MembershipTrialRecap.count(recap.bests) {
            MembershipRecapMetric(title: "Bests", value: count.formatted(.number.locale(localization.locale)))
        }
    }

    private func strength(_ lift: MembershipTrialRecap.Strength) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ZOSpace.xs) { strengthLabels(lift) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) { strengthLabels(lift) }
                    VStack(alignment: .leading, spacing: ZOSpace.xs) { strengthLabels(lift) }
                }
            }
            GeometryReader { geometry in
                let maximum = max(lift.firstLoadKilograms, lift.currentLoadKilograms)
                let first = maximum > 0 ? lift.firstLoadKilograms / maximum : 0
                let current = maximum > 0 ? lift.currentLoadKilograms / maximum : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceSecondary)
                    Capsule().fill(theme.textPrimary).frame(width: geometry.size.width * current)
                    Rectangle().fill(theme.textSecondary)
                        .frame(width: ZOStroke.focus)
                        .offset(x: max(0, min(geometry.size.width - ZOStroke.focus,
                                             geometry.size.width * first)))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func strengthLabels(_ lift: MembershipTrialRecap.Strength) -> some View {
        Text(verbatim: lift.exerciseName).zoText(.section)
            .fixedSize(horizontal: false, vertical: true)
        Text(localization.format("%1$@ → %2$@ kg",
            .text(lift.firstLoadKilograms.formatted(.number.locale(localization.locale))),
            .text(lift.currentLoadKilograms.formatted(.number.locale(localization.locale)))))
            .zoText(.caption).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func activityMetrics(_ recap: MembershipTrialRecap) -> some View {
        if let steps = MembershipTrialRecap.count(recap.averageDailySteps) {
            MembershipRecapMetric(title: "Steps a day", value: steps.formatted(.number.locale(localization.locale)), metricSize: 26)
        }
        if let walk = recap.validLongestWalk {
            MembershipRecapMetric(title: "Longest walk",
                value: walk.formatted(.number.precision(.fractionLength(1)).locale(localization.locale)),
                metricSize: 26, unit: "km")
        }
    }

    private func attendance(_ day: MembershipTrialRecap.AttendanceDay) -> some View {
        let done = day.completed == true
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .center, spacing: ZOSpace.m))
            : AnyLayout(VStackLayout(alignment: .center, spacing: ZOSpace.s))
        return layout {
            Text(day.date.formatted(dynamicTypeSize.isAccessibilitySize
                ? .dateTime.weekday(.wide).day().month(.abbreviated).locale(localization.locale)
                : .dateTime.weekday(.narrow).locale(localization.locale)))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            Group {
                if done { Image(systemName: "checkmark") }
                else { Text(day.date.formatted(.dateTime.day().locale(localization.locale))) }
            }
            .zoText(.caption)
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? ZOSpace.hitTarget : nil,
                   maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : 36,
                   minHeight: 36)
            .padding(dynamicTypeSize.isAccessibilitySize ? ZOSpace.s : 0)
            .foregroundStyle(done ? theme.backgroundPrimary : theme.textPrimary)
            .background(done ? theme.textPrimary : theme.surfaceSecondary, in: Circle())
            .overlay(Circle().stroke(day.planned == true && !done ? theme.textPrimary : .clear,
                                     lineWidth: ZOStroke.focus))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(localization.locale)))
        .accessibilityValue(localization.string(done ? "Completed" : day.completed == nil
            ? "Completion unknown" : day.planned == true ? "Planned, not completed" : "Not completed"))
    }

    private var renewalDetail: String {
        guard let renewal, renewal.matches(recap, calendar: calendar) else {
            return localization.string("Check renewal details in your Apple Account.")
        }
        let date = renewal.trialEnds.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))
        switch renewal.continuation {
        case .cancelled:
            return localization.format("Renewal is off. Your trial ends %1$@.", .text(date))
        case .renews:
            guard renewal.hasVerifiedPriceAndPeriod,
                  let price = renewal.verifiedPrice, let period = renewal.verifiedPeriod else {
                return localization.format("Your trial ends %1$@. Check the renewal price in your Apple Account.", .text(date))
            }
            return localization.format("%1$@ %2$@ from %3$@ unless you cancel.", .text(price), .text(period), .text(date))
        case .unknown:
            return localization.format("Your trial ends %1$@. Check renewal details in your Apple Account.", .text(date))
        }
    }
}

private struct MembershipRecapMetric: View {
    let title: String
    let value: String
    var metricSize: CGFloat = 30
    var unit: String? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).zoThemeText(.metric, size: metricSize, lineHeight: ZOThemeTypography.spec(for: theme.designTheme, role: .metric).lineHeight)
                    .foregroundStyle(theme.textPrimary)
                if let unit {
                    Text(localization.string(unit))
                        .zoProofText(.body, size: 15, lineHeight: 20, weight: 500, width: 100)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(theme.surfacePrimary, in: ZORadius.cardShape)
        .accessibilityElement(children: .combine)
    }
}
