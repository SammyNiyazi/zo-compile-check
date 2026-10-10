import SwiftUI
import CoreText

/// Optional capabilities are visible only when the root can perform the real action.
/// Root handlers must revalidate current identity, presented facts and availability at use.
@MainActor
struct ProfileSettingsYouActions {
    var photo: (@MainActor () -> Void)? = nil
    var weekCode: (@MainActor (ProfileSettingsYouVerifiedCard) -> Void)? = nil
    var share: (@MainActor (ProfileSettingsYouVerifiedCard) -> Void)? = nil
    var personalDetails: (@MainActor () -> Void)? = nil
    var bodyWeight: (@MainActor () -> Void)? = nil
    var settings: (@MainActor () -> Void)? = nil
    var selectEdition: (@MainActor (ProfileSettingsYouEdition) -> Void)? = nil
    var writeToSammy: (@MainActor () -> Void)? = nil
}

/// Additive proof7 presentation. The existing ProfileAccountView remains the Settings shell.
/// Root owns NavigationStack, stores, sheets and the current snapshot/edition selection.
@MainActor
struct ProfileSettingsYouHubView: View {
    let snapshot: ProfileSettingsYouSnapshot
    let actions: ProfileSettingsYouActions
    var tilt: Double = 0
    var membershipAccess: MembershipAccess = .unknown
    /// Only root's accepted issued-card/decoder capability enables the local back.
    var weekCodePresentationAllowed = false
    @StateObject private var editionStore = ProfileSettingsYouEditionStore()
    @State private var showsBack = false
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink {
                    ProfileSettingsYouEditionDestination(snapshot: snapshot, store: editionStore,
                        membershipState: cardState, onSelected: actions.selectEdition)
                } label: {
                    ProfileSettingsYouCardView(snapshot: presentedSnapshot, tilt: tilt,
                        membershipState: cardState, side: canShowBack && showsBack ? .back : .front)
                }.buttonStyle(.plain)
                    .accessibilityHint(localization.string("Choose your card edition."))
                if hasCardActions { actionButtons.padding(.top, 14) }
                if let month = snapshot.month {
                    ProfileSettingsYouMonthView(month: month).padding(.top, 16)
                }
                if hasRows { rows.padding(.top, 12) }
                footer.padding(.top, 16)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary)
        .onChange(of: snapshot.card) { showsBack = false }
        .onChange(of: weekCodePresentationAllowed) { if !weekCodePresentationAllowed { showsBack = false } }
        .navigationTitle(localization.string("You"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Text(verbatim: localization.string("Done")).zoText(.label)
                }.foregroundStyle(theme.textPrimary).frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    private var cardState: ProfileSettingsYouCardState {
        .init(access: membershipAccess, asOf: snapshot.asOf, calendar: calendar)
    }
    private var presentedSnapshot: ProfileSettingsYouSnapshot {
        cardState.applyingEdition(editionStore.resolved(fallback: snapshot.edition), to: snapshot)
    }
    private var canShowBack: Bool { snapshot.card != nil && weekCodePresentationAllowed }
    private var hasCardActions: Bool {
        actions.photo != nil || (snapshot.card != nil && (canShowBack || actions.weekCode != nil || actions.share != nil))
    }
    private var hasRows: Bool {
        actions.personalDetails != nil || actions.bodyWeight != nil || actions.settings != nil
    }

    private var actionButtons: some View {
        Group {
            if typeSize.isAccessibilitySize { VStack(spacing: 8) { cardActions } }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { cardActions }
                    VStack(spacing: 8) { cardActions }
                }
            }
        }
    }

    @ViewBuilder private var cardActions: some View {
        if let photo = actions.photo { action("Photo", icon: "camera", perform: photo) }
        if let card = snapshot.card {
            if canShowBack {
                action(showsBack ? "Front" : "Week code", icon: showsBack ? "person" : "viewfinder") {
                    showsBack.toggle()
                }
            } else if let weekCode = actions.weekCode {
                action("Week code", icon: "viewfinder") { weekCode(card) }
            }
            if let share = actions.share { action("Share", icon: "square.and.arrow.up") { share(card) } }
        }
    }

    private func action(_ key: String, icon: String, perform: @escaping @MainActor () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: icon).zoIcon(16).accessibilityHidden(true)
                Text(verbatim: localization.string(key)).zoText(.label)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            }.padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(ProfileSettingsYouSecondaryButtonStyle())
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if let details = actions.personalDetails {
                row("Personal details", icon: "person", value: nil, action: details)
            }
            if let weight = actions.bodyWeight {
                if actions.personalDetails != nil { separator }
                row("Body weight", icon: "scalemass", value: weightLabel, action: weight)
            }
            if let settings = actions.settings {
                if actions.personalDetails != nil || actions.bodyWeight != nil { separator }
                row("Settings", icon: "gearshape", value: nil, action: settings)
            }
        }
        .padding(.horizontal, 16)
        .background(theme.surfacePrimary, in: .rect(cornerRadius: 16))
    }

    private var weightLabel: String? {
        snapshot.bodyWeight.map {
            localization.format("%1$@ %2$@", .text($0.value.formatted(.number.precision(.fractionLength(0...1)).locale(localization.locale))), .text(localization.string($0.unit.rawValue)))
        }
    }

    private var separator: some View { Rectangle().fill(theme.strokeSubtle).frame(height: 1) }

    private func row(_ key: String, icon: String, value: String?, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).zoIcon(20).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: localization.string(key)).zoText(.section)
                    if typeSize.isAccessibilitySize, let value {
                        Text(verbatim: value).zoProofText(.body, size: 15, lineHeight: 20).foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                if !typeSize.isAccessibilitySize, let value {
                    Text(verbatim: value).zoProofText(.body, size: 15, lineHeight: 20).foregroundStyle(theme.textSecondary)
                }
                Image(systemName: "chevron.right").zoIcon(16).foregroundStyle(theme.textTertiary).accessibilityHidden(true)
            }.padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) { footerItems }
            VStack(spacing: 8) { footerItems }
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
    }
    @ViewBuilder private var footerItems: some View {
        Text(verbatim: localization.string("Made by one person who trains."))
            .zoText(.caption).foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let contact = actions.writeToSammy {
            Button(action: contact) {
                Text(verbatim: localization.string("Write to Sammy")).underline().zoText(.caption)
            }
            .buttonStyle(.plain).frame(minHeight: 44)
        }
    }
}

/// Root may present this destination only when selectEdition is available.
/// Selection remains root-owned; a callback does not imply persistence succeeded.
struct ProfileSettingsYouEditionView: View {
    let snapshot: ProfileSettingsYouSnapshot
    let selectEdition: @MainActor (ProfileSettingsYouEdition) -> Void
    var membershipState: ProfileSettingsYouCardState? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProfileSettingsYouCardView(snapshot: snapshot, membershipState: membershipState)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    ForEach(ProfileSettingsYouEdition.allCases) { edition in
                        Button { selectEdition(edition) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ProfileSettingsYouCardView(snapshot: .init(asOf: snapshot.asOf,
                                    displayName: snapshot.displayName, card: snapshot.card, edition: edition), playsArrival: false, membershipState: membershipState)
                                    .overlay {
                                        if edition == snapshot.edition {
                                            RoundedRectangle(cornerRadius: 14).strokeBorder(theme.textPrimary, lineWidth: 2)
                                                .padding(-3)
                                        }
                                    }.accessibilityHidden(true)
                                Text(verbatim: localization.string(edition.title)).zoText(.label)
                                Text(verbatim: localization.string(edition.themeTitle)).zoText(.caption).foregroundStyle(theme.textSecondary)
                            }
                            .padding(.vertical, 3).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(localization.string(edition.title))
                            .accessibilityValue(localization.string(edition.themeTitle))
                            .accessibilityAddTraits(edition == snapshot.edition ? .isSelected : [])
                    }
                }.padding(.top, 20)
                Text(verbatim: localization.string("Your theme picks the edition until you choose one."))
                    .zoText(.caption).foregroundStyle(theme.textSecondary).padding(.top, 16)
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.foregroundStyle(theme.textPrimary)
            .navigationTitle(localization.string("Card edition")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileSettingsYouMonthView: View {
    let month: ProfileSettingsYouMonth
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var metricSize = 26.0
    private var title: String {
        var format = Date.FormatStyle.dateTime.month(.wide).locale(localization.locale)
        format.calendar = month.calendar
        format.timeZone = month.calendar.timeZone
        return localization.format("%1$@ so far", .text(month.asOf.formatted(format)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    monthTitle
                    Spacer(minLength: 8)
                    monthWeek
                }
                VStack(alignment: .leading, spacing: 4) { monthTitle; monthWeek }
            }
            if month.scope == .recordedHistory {
                Text(verbatim: localization.string("Recorded history on this iPhone"))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            Group {
                if typeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 12) { facts } }
                else { HStack(alignment: .top, spacing: 12) { facts } }
            }
            if let goal = month.goal {
                HStack(spacing: 4) {
                    ForEach(Array(zip(0..<15, ProfileSettingsYouPresentation.rail(goal: goal))), id: \.0) { _, state in
                        Rectangle().fill(state == .done ? theme.textPrimary : state == .current ? theme.textPrimary.opacity(0.45) : theme.surfaceTertiary)
                    }
                }.frame(height: 6).accessibilityHidden(true)
                Text(verbatim: localization.format("%1$lld of %2$lld planned workouts", .integer(goal.completed), .integer(goal.target)))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfacePrimary, in: .rect(cornerRadius: 16))
    }
    private var monthTitle: some View {
        Text(verbatim: title).zoText(.section).accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private var monthWeek: some View {
        if let week = month.calendarWeek {
            Text(verbatim: localization.format("Week %1$lld of %2$lld", .integer(week.current), .integer(week.total)))
                .zoText(.caption).foregroundStyle(theme.textSecondary)
        }
    }
    @ViewBuilder private var facts: some View {
        if let count = month.workouts { fact(count, month.scope == .recordedHistory ? "recorded workouts" : "workouts") }
        if let count = month.respectsReceived { fact(count, "respect received") }
        if let count = month.newBests { fact(count, count == 1 ? "new best" : "new bests") }
    }
    private func fact(_ count: Int, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(count, format: .number.locale(localization.locale))
                .font(Font(CTFontCreateCopyWithAttributes(ZOTextStyle.metric.ctFont(for: .large), metricSize, nil, nil)).monospacedDigit())
            Text(verbatim: localization.string(key)).zoText(.caption).foregroundStyle(theme.textSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private struct ProfileSettingsYouSecondaryButtonStyle: ButtonStyle {
    @Environment(\.zeroOneTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(theme.textPrimary)
            .background(configuration.isPressed ? theme.surfaceSecondary : theme.surfacePrimary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ZOColor.separatorStrong, lineWidth: 1))
    }
}
