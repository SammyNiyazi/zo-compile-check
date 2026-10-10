import SwiftUI

/// Social > Clubs for a Club member (proof 12, 48): your crews, who trained this
/// week and the monthly goal. "Start a crew" and invite links live here.
@MainActor
struct ClubCrewsSection: View {
    let club: ClubStore
    @State private var creating = false
    @State private var opened: ClubCrew?
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            ForEach(club.crews) { crew in
                Button { opened = crew } label: { ClubCrewCard(crew: crew) }
                    .buttonStyle(.plain)
            }
            if club.crews.isEmpty {
                ClubNote(title: "Start a crew", text: "A few people who train. You see who trained this week and chase one goal together.")
            }
            Button { creating = true } label: {
                Label("Start a crew", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(ZOButtonStyle(club.crews.isEmpty ? .primary : .secondary))
        }
        .task { await club.loadCrews() }
        .sheet(isPresented: $creating) {
            NavigationStack { ClubCrewCreateView(club: club) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .sheet(item: $opened) { crew in
            NavigationStack { ClubCrewDetailView(club: club, crewID: crew.id) }.zeroOneTheme(theme).zoSheet(theme)
        }
    }
}

/// The crew card: name, this month's crew workouts against the goal, and who trained this week.
struct ClubCrewCard: View {
    let crew: ClubCrew
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: crew.name).zoThemeText(.title).lineLimit(1)
                Spacer(minLength: ZOSpace.s)
                Text(verbatim: localization.format("%1$lld of %2$lld trained this week",
                                                   .integer(crew.trainedThisWeek), .integer(crew.members.count)))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(verbatim: localization.format("%1$lld of %2$lld crew workouts this month",
                                                   .integer(crew.monthWorkouts), .integer(crew.monthlyGoal)))
                    .zoText(.section)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.strokeSubtle)
                        Capsule().fill(theme.textPrimary)
                            .frame(width: proxy.size.width * min(1, Double(crew.monthWorkouts) / Double(max(crew.monthlyGoal, 1))))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            HStack(spacing: -8) {
                ForEach(crew.members.prefix(8)) { person in
                    // Trained this week: the accent disc, as on the Club home.
                    ClubAvatar(name: person.displayName, trained: person.trainedThisWeek, size: 32)
                        .overlay(Circle().stroke(theme.backgroundPrimary, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(ZOSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Proof 48 "Start a crew": a name, invite only or anyone with the link, the monthly goal.
@MainActor
struct ClubCrewCreateView: View {
    let club: ClubStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var name = ""
    @State private var anyoneWithLink = false
    @State private var goal = 60

    var body: some View {
        Form {
            Section {
                Text("A few people who train. You see who trained this week and chase one goal together.")
                    .foregroundStyle(theme.textSecondary)
                TextField("Crew name", text: $name).textInputAutocapitalization(.words)
            }
            Section("Who can join") {
                Picker("Who can join", selection: $anyoneWithLink) {
                    Text("Invite only: you send the link").tag(false)
                    Text("Anyone with the link: it can be shared on").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Monthly goal") {
                Stepper(value: $goal, in: 5 ... 500, step: 5) {
                    Text(verbatim: localization.format("Crew workouts a month: %1$lld", .integer(goal)))
                }
            }
            if let notice = club.notice {
                Section { Text(verbatim: localization.string(notice)).foregroundStyle(theme.textSecondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text("Start a crew"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create crew") {
                    Task { if await club.createCrew(name: name, anyoneWithLink: anyoneWithLink, monthlyGoal: goal) { dismiss() } }
                }
                .disabled(club.isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// One crew: the goal, the roster with this week's ticks, the invite link and leave.
@MainActor
struct ClubCrewDetailView: View {
    let club: ClubStore
    let crewID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var link: URL?
    @State private var confirmingLeave = false

    private var crew: ClubCrew? { club.crews.first { $0.id == crewID } }

    var body: some View {
        List {
            if let crew {
                Section { ClubCrewCard(crew: crew).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if crew.canInvite {
                    Section {
                        if let url = link ?? crew.invite.flatMap({ ClubCrewLink.url(token: $0.token) }) {
                            ShareLink(item: url, message: Text(verbatim: localization.format("Join %1$@ on 01", .text(crew.name)))) {
                                Label("Share the invite link", systemImage: "square.and.arrow.up")
                            }
                            if let expires = crew.invite?.expiresAt {
                                Text(verbatim: localization.format("The link works until %1$@.",
                                    .text(expires.formatted(.dateTime.day().month(.wide).locale(localization.locale)))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if crew.isOwner {
                                Button("Turn the link off", role: .destructive) {
                                    Task { if await club.turnOffInvite(for: crew) { link = nil } }
                                }
                            }
                        } else {
                            Button("Make an invite link") { Task { link = await club.inviteLink(for: crew) } }
                                .disabled(club.isWorking)
                        }
                    } header: { Text("Invite") } footer: {
                        Text("A link lasts 7 days. People in the same room can also use the week code.")
                    }
                }
                Section("Members") {
                    ForEach(crew.members) { person in
                        HStack {
                            ClubAvatar(name: person.displayName)
                            VStack(alignment: .leading) {
                                Text(verbatim: person.displayName)
                                if let number = person.memberNo {
                                    Text(verbatim: "No. " + ClubPerson.memberNumber(number)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if person.trainedThisWeek {
                                Label("Trained this week", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Button("Leave crew", role: .destructive) { confirmingLeave = true }
                }
                if let notice = club.notice {
                    Section { Text(verbatim: localization.string(notice)).foregroundStyle(.secondary) }
                }
            } else {
                Text("This crew isn't available.").foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(verbatim: crew?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog(Text("Leave this crew?"), isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave crew", role: .destructive) {
                Task { if let crew, await club.leave(crew) { dismiss() } }
            }
        } message: { Text("Your workouts stay yours. If you started the crew, the next member takes it over.") }
    }
}

/// Proof 48 "Getting an invite": who invited, the crew, and exactly what it will see.
@MainActor
struct ClubCrewInviteView: View {
    let club: ClubStore
    let token: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var preview: ClubCrewInvitePreview?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: ZOSpace.l) {
                if let preview {
                    ClubAvatar(name: preview.inviter.displayName)
                    Text(verbatim: localization.format("%1$@ invited you to %2$@", .text(preview.inviter.displayName), .text(preview.name)))
                        .zoThemeText(.display).multilineTextAlignment(.center)
                    Text(verbatim: localization.format("%1$lld members · %2$lld of %3$lld crew workouts this month",
                        .integer(preview.membersCount), .integer(preview.monthWorkouts), .integer(preview.monthlyGoal)))
                        .zoText(.body).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text("What your crew sees").zoText(.section)
                        Text("That you trained this week, your card, and what you post. Never your body weight, food or progress photos.")
                            .zoText(.caption).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(ZOSpace.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zoThemeCardSurface()
                } else if failed {
                    ClubNote(title: "This invite isn't available.", text: "It may have expired or been turned off. Ask for a new link.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
                if let notice = club.notice {
                    Text(verbatim: localization.string(notice)).zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
            .padding(.top, ZOSpace.xl)
        }
        .zoThemeScreenSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ZOSpace.xs) {
                if let preview, !preview.isMember {
                    Button("Join the crew") { Task { if await club.joinCrew(token: token) { dismiss() } } }
                        .buttonStyle(ZOButtonStyle(.primary)).disabled(club.isWorking)
                    Button("Not now") { dismiss() }.buttonStyle(ZOButtonStyle(.quiet))
                } else {
                    Button(preview?.isMember == true ? "You're already in this crew" : "Close") { dismiss() }
                        .buttonStyle(ZOButtonStyle(.secondary))
                }
            }
            .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
            .background(theme.backgroundPrimary)
        }
        .task {
            preview = await club.crewInvite(token: token)
            failed = preview == nil
        }
    }
}
