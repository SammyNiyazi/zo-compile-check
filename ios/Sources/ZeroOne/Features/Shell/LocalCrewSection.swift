import SwiftUI

/// Social > Clubs before the service: your own crew, on this iPhone (Sammy, 9 Oct).
/// Proof 12's crew card, reduced to what is true today: a name, a weekly goal
/// and this week's saved workouts. No other members or numbers are shown.
@MainActor
struct LocalCrewSection: View {
    let history: WorkoutHistoryRepository
    @State private var store = LocalCrewStore()
    @State private var editing = false
    @State private var draftName = ""
    @State private var draftGoal = 3
    @State private var failed = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if !store.isAvailable {
                Text("Your crew couldn't be read. It is kept on this iPhone. Try again later.")
                    .zoText(.body).foregroundStyle(theme.textSecondary)
                Button("Try again") { store.reload() }.buttonStyle(ZOButtonStyle(.quiet))
            } else if let crew = store.crew, !editing {
                crewCard(crew)
            } else {
                editor
            }
            if failed {
                Text("That change couldn't be saved. Nothing changed.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .accessibilityIdentifier("social.localCrew")
    }

    private func crewCard(_ crew: LocalCrew) -> some View {
        let done = LocalCrew.workoutsThisWeek(completedAt: history.entries.map(\.completedAt),
                                              asOf: .now, calendar: .current)
        let fraction = min(1, Double(done) / Double(crew.weeklyGoal))
        return VStack(alignment: .leading, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(verbatim: crew.name)
                    .zoThemeText(.title).foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Just you for now. Friends join when the Club opens.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            if history.availability == .available {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(verbatim: done >= crew.weeklyGoal
                         ? localization.string("Goal reached this week.")
                         : localization.format("%1$lld of %2$lld workouts this week", .integer(done), .integer(crew.weeklyGoal)))
                        .zoText(.section).foregroundStyle(theme.textPrimary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.strokeSubtle)
                            Capsule().fill(theme.textPrimary)
                                .frame(width: max(0, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
            } else {
                Text("Workout History is unavailable, so this week's count is hidden.")
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: ZOSpace.m) {
                Button("Edit crew") {
                    draftName = crew.name
                    draftGoal = crew.weeklyGoal
                    failed = false
                    editing = true
                }
                .buttonStyle(ZOButtonStyle(.secondary))
                Button("Leave crew") { failed = !store.leave() }
                    .buttonStyle(ZOButtonStyle(.quiet))
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            Text(verbatim: localization.string(store.crew == nil ? "Start your crew" : "Edit crew"))
                .zoThemeText(.title).foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Name it and set a weekly goal. Friends join when the Club opens.")
                .zoText(.body).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Crew name", text: $draftName)
                .zoText(.section)
                .textInputAutocapitalization(.words)
                .padding(.vertical, ZOSpace.s)
                .overlay(alignment: .bottom) { theme.strokeSubtle.frame(height: ZOStroke.hairline) }
                .onChange(of: draftName) { _, value in
                    if value.count > LocalCrew.nameLimit { draftName = String(value.prefix(LocalCrew.nameLimit)) }
                }
            Stepper(value: $draftGoal, in: LocalCrew.goalRange) {
                Text(verbatim: localization.format("Workouts a week: %1$lld", .integer(draftGoal)))
                    .zoText(.section)
            }
            HStack(spacing: ZOSpace.m) {
                Button { save() } label: {
                    Text(verbatim: localization.string(store.crew == nil ? "Start crew" : "Save crew"))
                }
                    .buttonStyle(ZOButtonStyle(.primary))
                    .disabled(LocalCrew(name: draftName, weeklyGoal: draftGoal, createdAt: .now) == nil)
                if store.crew != nil {
                    Button("Cancel") { editing = false; failed = false }
                        .buttonStyle(ZOButtonStyle(.quiet))
                }
            }
        }
    }

    private func save() {
        guard let crew = LocalCrew(name: draftName, weeklyGoal: draftGoal,
                                   createdAt: store.crew?.createdAt ?? .now) else { return }
        if store.save(crew) {
            failed = false
            editing = false
        } else {
            failed = true
        }
    }
}
