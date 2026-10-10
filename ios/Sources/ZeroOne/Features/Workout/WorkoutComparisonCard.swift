import SwiftUI

/// Final proof37 set comparison. Bars are decorative; each row exposes the
/// actual saved load/result as one accessible sentence, including unknowns.
/// The caller passes only storage-acknowledged sets as `confirmedSets`.
struct PreviousPerformanceSection: View {
    let state: PreviousExercisePerformanceState
    let confirmedSets: [CompletedSet]
    let currentSet: Int
    let plannedSetCount: Int
    let prescription: WorkingSetPrescription
    /// Replaces the computed heading, for the finished exercise at a handoff.
    var heading: String? = nil
    /// The next exercise's ghost: last time only, never a "today" column.
    var showsToday = true

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var workoutCopy: WorkoutLocalization { WorkoutLocalization(localization: localization) }

    private var presentation: WorkoutComparisonPresentation {
        WorkoutComparisonPresentation(state: state, confirmedSets: showsToday ? confirmedSets : [],
                                      currentSet: showsToday ? currentSet : 0,
                                      plannedSetCount: plannedSetCount, prescription: prescription)
    }

    var body: some View {
        let facts = presentation
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                    headingText(facts)
                    Spacer(minLength: 0)
                    gainBadge(facts.gainedReps)
                }
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    headingText(facts)
                    gainBadge(facts.gainedReps)
                }
            }

            if showsCompactState(facts) {
                Text(localization.string(compactNote(facts.history)))
                    .zoText(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(facts.rows) { row in
                        comparisonRow(row, maximum: row.bar.map { facts.maximum(for: $0.unit) } ?? 1)
                    }
                }

                historyNote(facts.history)
                if facts.hasUncomparedPairs {
                    Text("Set details differ; shown as logged.")
                        .zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.cardPadding)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZORadius.card))
        .foregroundStyle(theme.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout.previousPerformance")
    }

    /// Proof 42's first-ever card, and the same quiet card when history is
    /// unknown or unavailable: nothing to draw yet, so no empty bars.
    private func showsCompactState(_ facts: WorkoutComparisonPresentation) -> Bool {
        switch facts.history {
        case .recorded: return false
        case .none, .unavailable: return !facts.hasTodaySets
        }
    }

    private func compactNote(_ history: WorkoutComparisonPresentation.History) -> String {
        switch history {
        case .unavailable:
            return "History unavailable. Keep logging; this set still works offline."
        case let .none(hasUnknownDetails):
            if hasUnknownDetails { return "Previous workouts have no comparable set details." }
            return showsToday ? "No last time yet. This set sets the bar." : "No last time yet for this one."
        case .recorded:
            return ""
        }
    }

    private func headingText(_ facts: WorkoutComparisonPresentation) -> some View {
        Text(heading ?? computedHeading(facts))
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func computedHeading(_ facts: WorkoutComparisonPresentation) -> String {
        switch facts.history {
        case .unavailable, .none:
            return localization.string(facts.hasTodaySets && showsToday ? "Your sets" : "Last time")
        case let .recorded(date, newerUnknown):
            if newerUnknown {
                return localization.format("Earlier sets · %1$@",
                    .text(date.formatted(.dateTime.day().month(.abbreviated).locale(localization.locale))))
            }
            if !showsToday { return localization.string("The ghost to beat") }
            switch WorkoutComparisonPresentation.recency(of: date, now: .now, calendar: .current) {
            case .today:
                return localization.string("You vs earlier today")
            case .weekday:
                return localization.format("You vs last %1$@",
                    .text(date.formatted(.dateTime.weekday(.wide).locale(localization.locale))))
            case .date:
                return localization.format("You vs %1$@",
                    .text(date.formatted(.dateTime.day().month(.abbreviated).locale(localization.locale))))
            }
        }
    }

    @ViewBuilder
    private func gainBadge(_ gain: Int?) -> some View {
        if let gain, showsToday {
            ZOBadge(text: "+" + workoutCopy.quantity(gain, .reps), isInk: true)
        }
    }

    @ViewBuilder
    private func comparisonRow(_ row: WorkoutComparisonPresentation.Row, maximum: Double) -> some View {
        Group {
            if let bar = row.bar {
                if dynamicTypeSize.isAccessibilitySize {
                    expandedRow(row, bar: bar, maximum: maximum)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            rowTitle(row.id).frame(width: 64, alignment: .leading)
                            WorkoutComparisonBar(bar: bar, maximum: maximum)
                                .frame(minWidth: ZOSpace.xxl)
                            Text(valueCaption(bar, perSide: (row.today ?? row.previous)?.isPerSide == true))
                                .zoText(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56, alignment: .trailing)
                        }
                        expandedRow(row, bar: bar, maximum: maximum)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    rowTitle(row.id)
                    if let previous = row.previous {
                        Text(localization.format("Last time %1$@", .text(summary(previous))))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    if !showsToday {
                        if row.previous == nil {
                            Text(localization.string("Not recorded"))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                    } else if let today = row.today {
                        Text(localization.format("Today %1$@", .text(summary(today))))
                            .zoText(.caption)
                    } else {
                        Text(localization.string(row.isCurrent ? "Now" : "Not logged"))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityIdentifier("workout.previousPerformance.set\(row.id)")
    }

    private func rowAccessibilityLabel(_ row: WorkoutComparisonPresentation.Row) -> String {
        let previous = row.previous.map(summary) ?? localization.string("Not recorded")
        guard showsToday else {
            return localization.format("Set %1$lld. Last time %2$@.", .integer(row.id), .text(previous))
        }
        return localization.format("Set %1$lld. Previous %2$@. Today %3$@.",
            .integer(row.id), .text(previous),
            .text(row.today.map(summary) ?? localization.string("Not logged")))
    }

    private func expandedRow(_ row: WorkoutComparisonPresentation.Row,
                             bar: WorkoutComparisonPresentation.Bar, maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
                rowTitle(row.id)
                Spacer(minLength: 0)
                Text(valueCaption(bar, perSide: (row.today ?? row.previous)?.isPerSide == true))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkoutComparisonBar(bar: bar, maximum: maximum)
        }
    }

    private func rowTitle(_ number: Int) -> some View {
        Text(localization.format("Set %1$lld", .integer(number)))
            .zoText(.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueCaption(_ bar: WorkoutComparisonPresentation.Bar, perSide: Bool) -> String {
        let caption: String
        switch (bar.today, bar.previous) {
        case let (.some(today), .some(previous)):
            caption = localization.format(bar.unit == .seconds ? "%1$lld s / %2$lld s" : "%1$lld / %2$lld",
                                          .integer(today), .integer(previous))
        case let (.none, .some(previous)):
            caption = localization.format(bar.unit == .seconds ? "%1$lld s last" : "%1$lld last", .integer(previous))
        case let (.some(today), .none):
            caption = workoutCopy.quantity(today, bar.unit == .seconds ? .seconds : .reps)
        case (.none, .none):
            caption = localization.string("Not logged")
        }
        return perSide ? localization.format("%1$@ per side", .text(caption)) : caption
    }

    private func summary(_ set: CompletedSet) -> String {
        let result = workoutCopy.setSummary(set)
        return set.isPerSide == nil
            ? result + ". " + localization.string("Side details not recorded.") : result
    }

    @ViewBuilder
    private func historyNote(_ history: WorkoutComparisonPresentation.History) -> some View {
        switch history {
        case .unavailable:
            Text("History unavailable. Keep logging; this set still works offline.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .none(hasUnknownDetails):
            Text(localization.string(hasUnknownDetails
                ? "Previous workouts have no comparable set details."
                : "No earlier sets recorded for this exercise."))
                .zoText(.caption).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .recorded(_, hasNewerUnknownDetails):
            if hasNewerUnknownDetails {
                Text("Newer workouts have no recorded set details. These earlier values are shown without comparison.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WorkoutComparisonBar: View {
    let bar: WorkoutComparisonPresentation.Bar
    let maximum: Double
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 5)
            // The 10 pt track owns the height. The marker is an overlay 4 pt
            // past each edge (proof: top -4, bottom -4), centred on the track.
            shape.fill(theme.surfaceTertiary)
                .overlay(alignment: .leading) {
                    if let today = bar.today {
                        shape.fill(theme.textPrimary)
                            .frame(width: proxy.size.width * fraction(today))
                    }
                }
                .overlay(alignment: .leading) {
                    if let previous = bar.previous {
                        WorkoutPreviousMarker()
                            .stroke(theme.textPrimary.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                            .frame(width: 2, height: 18)
                            .offset(x: proxy.size.width * fraction(previous) - 1)
                    }
                }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func fraction(_ value: Int) -> CGFloat {
        CGFloat(min(1, max(0, Double(value) / max(1, maximum))))
    }
}

private struct WorkoutPreviousMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// The outlined "last time" rail under the session rail, segment for segment.
/// Decorative: the comparison card states the same facts per set.
struct WorkoutPreviousRailView: View {
    let rail: WorkoutPreviousRail

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        let segmentGap = 2 * ZOStroke.hairline
        let exerciseGap = ZOSpace.xs + 2 * ZOStroke.hairline
        HStack(alignment: .center, spacing: ZOSpace.s) {
            Text(label)
                .zoText(.mini)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: segmentGap) {
                ForEach(rail.segments) { segment in
                    if segment.setNumber == 1, segment.id != rail.segments.first?.id {
                        Color.clear.frame(width: exerciseGap - segmentGap)
                    }
                    RoundedRectangle(cornerRadius: 2 * ZOStroke.hairline)
                        .strokeBorder(theme.textPrimary.opacity(segment.hasPrevious ? 0.45 : 0),
                                      lineWidth: ZOStroke.control)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: ZOStroke.railApp)
        }
        .accessibilityHidden(true)
    }

    private var label: String {
        guard case let .session(date) = rail.label,
              WorkoutComparisonPresentation.recency(of: date, now: .now, calendar: .current) == .weekday else {
            return localization.string("Last time")
        }
        return localization.format("Last %1$@",
            .text(date.formatted(.dateTime.weekday(.abbreviated).locale(localization.locale))))
    }
}
