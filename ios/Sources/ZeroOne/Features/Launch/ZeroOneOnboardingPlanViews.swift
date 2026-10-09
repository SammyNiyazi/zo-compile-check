import SwiftUI

/// First-workout tips. This screen never creates a session, set or history entry.
struct ZeroOneOnboardingWalkthroughView: View {
    let movementName: String
    let onBack: () -> Void
    let onContinue: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var stepNumberWidth = ZOSpace.xxl
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.titleToContent) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text("Know what happens next.")
                        .zoThemeText(.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Nothing is being recorded here.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                VStack(spacing: 0) {
                    step("Open your plan", detail: localization.string("Choose a saved workout and review its warm-up. Recording begins when you start."), number: 1)
                    Divider().overlay(theme.strokeSubtle)
                    step("Log what you actually did", detail: localization.format("For movements such as %1$@, enter your actual load and reps after each set. Undo last set corrects a mistake.", .text(movementName)), number: 2)
                    Divider().overlay(theme.strokeSubtle)
                    step("Rest, then keep going", detail: localization.string("Rest starts after a saved set. Start the next set when ready. Finish saves your completed work to History, even if you end early."), number: 3)
                }
                .zoThemeCardSurface()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xxl)
            .padding(.bottom, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ZOSpace.xs) {
                Button("See my plan", action: onContinue)
                    .buttonStyle(ZOButtonStyle(.primary))
                Button("Back", action: onBack)
                    .buttonStyle(ZOButtonStyle(.quiet))
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
    }

    private func step(_ title: LocalizedStringKey, detail: String, number: Int) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Text(number.formatted())
                .zoText(.label)
                .foregroundStyle(theme.textSecondary)
                .frame(width: stepNumberWidth)
                .frame(minHeight: stepNumberWidth)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text(title).zoText(.section)
                Text(verbatim: detail).zoText(.body).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(ZOSpace.cardPadding)
        .accessibilityElement(children: .combine)
    }
}

struct ZeroOneOnboardingPlanView: View {
    let plan: ZeroOneFirstWeekPlan?
    let canChooseAlternative: Bool
    let isSaving: Bool
    let error: String?
    let currentBodyWeight: String?
    let healthWeightMessage: String?
    let isImportingBodyWeight: Bool
    let onBack: () -> Void
    let onChange: (ZeroOneFirstWeekReasonKind) -> Void
    let onEditBodyWeight: () -> Void
    let onFillBodyWeight: () -> Void
    let onAlternative: () -> Void
    let onSave: () -> Void
    let onReloadSavedData: () -> Void
    var needsHealthSetup = false
    var recommendation: ZeroOneFirstWeekRecommendation = .catalogueOrConstraintsIncomplete

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var controls: ZeroOneSetupPlanControls {
        ZeroOneSetupPlanControls(hasPlan: plan != nil, isSaving: isSaving, isImportingBodyWeight: isImportingBodyWeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.titleToContent) {
                Text("Your first week")
                    .zoThemeText(.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let plan {
                    planCard(plan)
                    if let report = plan.selectionReport {
                        ForEach(report.issues, id: \.self) { issue in
                            Text(LocalizedStringKey(issue.messageKey))
                                .zoText(.body)
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DisclosureGroup("Why this plan") {
                        VStack(spacing: ZOSpace.s) {
                            ForEach(plan.reasons, id: \.kind) { reason in
                                reasonRow(reason)
                            }
                        }
                        .padding(.top, ZOSpace.s)
                    }
                    .zoText(.section)
                    if canChooseAlternative {
                        Button("Choose another plan", action: onAlternative)
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .disabled(!controls.canEdit)
                    }
                    DisclosureGroup("Starting weight") { connections }
                        .zoText(.section)
                } else {
                    Text(LocalizedStringKey(recommendation.messageKey))
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review equipment and movement exclusions") { onChange(.limitations) }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
                if let error {
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(verbatim: error)
                            .zoText(.body)
                            .foregroundStyle(theme.destructivePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                        Button("Reload saved data", action: onReloadSavedData)
                            .buttonStyle(ZOButtonStyle(.secondary))
                            .disabled(!controls.canReload)
                            .accessibilityHint("Reloads saved answers and workouts without activating a plan. Review the plan before saving again.")
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xxl)
            .padding(.bottom, ZOSpace.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ZOSpace.xs) {
                Button(action: onSave) {
                    Text(LocalizedStringKey(isSaving ? "Saving…" : "Start with this plan"))
                }
                    .buttonStyle(ZOButtonStyle(.primary, isLoading: isSaving))
                    .disabled(!controls.canSave)
                Button("Back", action: onBack)
                    .buttonStyle(ZOButtonStyle(.quiet))
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
    }

    private func reasonRow(_ reason: ZeroOneFirstWeekReason) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.m) {
                    reasonTitle(reason)
                    Spacer(minLength: 0)
                    changeButton(reason.kind)
                }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    reasonTitle(reason)
                    changeButton(reason.kind)
                }
            }
            Text(verbatim: localization.string(reason.explanation))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private func reasonTitle(_ reason: ZeroOneFirstWeekReason) -> some View {
        Text(verbatim: "\(localization.string(reason.kind.title)) · \(localization.string(reason.answer))")
            .zoText(.section)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func changeButton(_ kind: ZeroOneFirstWeekReasonKind) -> some View {
        Button("Change") { onChange(kind) }
            .buttonStyle(ZOButtonStyle(.quiet))
            .disabled(!controls.canEdit)
            .accessibilityLabel(Text(verbatim: localization.format("Change %1$@", .text(localization.string(kind.title)))))
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text("Apple Health body weight").zoText(.section)
            Text(verbatim: currentBodyWeight.map { localization.format("Starting point: %1$@", .text($0)) }
                 ?? localization.string("No starting weight yet. You can leave it blank."))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if needsHealthSetup {
                Text("First, choose optional read access to steps, active energy, workouts, sleep, body weight and walking/running distance. Then 01 can fill your latest weight. Nothing is written to Health.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
            }
            Button(action: onFillBodyWeight) {
                Text(LocalizedStringKey(isImportingBodyWeight ? "Checking…" : (needsHealthSetup ? "Choose Health access and fill weight" : "Fill from Apple Health")))
            }
                .buttonStyle(ZOButtonStyle(.secondary, isLoading: isImportingBodyWeight))
                .disabled(!controls.canEdit)
            Button("Edit manually", action: onEditBodyWeight)
                .buttonStyle(ZOButtonStyle(.quiet))
                .disabled(!controls.canEdit)
            if let healthWeightMessage {
                Text(verbatim: healthWeightMessage)
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private func planCard(_ plan: ZeroOneFirstWeekPlan) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            Text(LocalizedStringKey(plan.title)).zoThemeText(.title)
            Text(verbatim: localization.string(plan.focus))
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            Text(verbatim: localization.format("%1$lld days a week · %2$lld min available", .integer(plan.trainingDays.count), .integer(plan.preferredMinutes)))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ZOSpace.xs), count: dynamicTypeSize.isAccessibilitySize ? 1 : 7), spacing: ZOSpace.s) {
                ForEach(ZeroOneTrainingDay.allCases) { day in
                    dayTile(day, selected: plan.trainingDays.contains(day))
                }
            }
            DisclosureGroup("Review sessions") {
                ForEach(plan.sessions, id: \.name) { session in
                    VStack(alignment: .leading, spacing: ZOSpace.s) {
                        Text(LocalizedStringKey(session.name)).zoText(.section)
                        Text(verbatim: session.videoIDs.compactMap { MoveKitExerciseCatalog.exercise(for: $0)?.name }.map { localization.string($0) }.joined(separator: " · "))
                            .zoText(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, ZOSpace.m)
                }
            }
            .zoText(.section)
            Text("Choose your starting weights during the workout.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            if let estimate = plan.maximumEstimatedMinutes {
                Text(verbatim: localization.format("Allow up to %1$lld minutes, including warm-up and rest. Timing varies.", .integer(estimate)))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }

    private func dayTile(_ day: ZeroOneTrainingDay, selected: Bool) -> some View {
        Text(verbatim: localization.string(day.shortTitle))
            .zoText(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: ZOSpace.hitTarget)
            .foregroundStyle(selected ? theme.backgroundPrimary : theme.textSecondary)
            .background(selected ? theme.textPrimary : theme.surfaceSecondary, in: Capsule())
            .accessibilityLabel(Text(verbatim: localization.format("%1$@, %2$@", .text(localization.string(day.title)), .text(localization.string(selected ? "training" : "rest")))))
    }
}
