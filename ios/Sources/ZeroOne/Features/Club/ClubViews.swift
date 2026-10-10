import SwiftUI

// Club core v1 (Sammy, 10 Oct 2026), drawn from study 30 proof screens 48 and 50:
// Club home with "Trained this week" and the feed, member card, People, Activity,
// Club privacy, report, Club rules and Sammy's report queue. Crews, chat and comments come later.

/// Social > Following when the Club service is part of this build.
@MainActor
struct ClubFeedSection: View {
    @Bindable var club: ClubStore
    let history: WorkoutHistoryRepository
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var joining = false
    @State private var showingSettings = false
    @State private var showingPeople = false
    @State private var showingActivity = false
    @State private var showingReports = false
    @State private var composing = false
    @State private var openMember: ClubPerson?

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.l) {
            switch club.phase {
            case .member:
                memberHeader
                if let home = club.home {
                    trainedRow(home.trained)
                    Button { composing = true } label: { Label("Post a workout", systemImage: "plus") }
                        .buttonStyle(ZOButtonStyle(.secondary))
                    if home.feed.isEmpty {
                        ClubNote(title: "Nothing here yet.",
                                 text: "Follow people from People, or post your own workout. Posts from people you follow show here.")
                    }
                    ForEach(home.feed) { post in
                        ClubPostCard(club: club, post: post, onOpenAuthor: { openMember = $0 })
                    }
                }
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .notJoined:
                ClubNote(title: "Join the 01 Club.",
                         text: "Follow people who train, see who trained this week and give Respect. Your card gets its own number. Body weight, food and progress photos are never shared.")
                Button("Join the Club") { joining = true }.buttonStyle(ZOButtonStyle(.primary))
            case .signedOut:
                ClubNote(title: "Sign in to join the Club.",
                         text: "The Club needs an 01 account. Sign in from Profile. Your training works without it.")
            case .closed:
                ClubNote(title: "The Club opens soon.", text: "Your account is ready. Following and posts switch on when the Club opens.")
            case .suspended:
                ClubNote(title: "Your Club account is paused.",
                         text: "Your training is untouched. If you think this is wrong, write to Sammy at sammy@the01.app.")
            case .notConfigured:
                ClubNote(title: "The Club isn't part of this build.", text: "Your training works fully on this iPhone.")
            case .unavailable:
                ClubNote(title: "The Club can't be reached.", text: "Check your connection. Nothing on this iPhone changed.")
                Button("Try again") { Task { await club.refresh(history: history.entries) } }
                    .buttonStyle(ZOButtonStyle(.quiet))
            }
            if let notice = club.notice {
                Text(verbatim: localization.string(notice)).zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .task { await club.refresh(history: history.entries) }
        .refreshable { await club.refresh(history: history.entries) }
        .sheet(isPresented: $joining) { ClubJoinView(club: club).zeroOneTheme(theme).zoSheet(theme) }
        .sheet(isPresented: $showingSettings) { NavigationStack { ClubSettingsView(club: club) }.zeroOneTheme(theme).zoSheet(theme) }
        .sheet(isPresented: $showingPeople) {
            NavigationStack { ClubPeopleView(club: club) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .sheet(isPresented: $showingActivity) { NavigationStack { ClubActivityView(club: club) }.zeroOneTheme(theme).zoSheet(theme) }
        .sheet(isPresented: $showingReports) { NavigationStack { ClubModerationView(club: club) }.zeroOneTheme(theme).zoSheet(theme) }
        .sheet(isPresented: $composing) {
            NavigationStack { ClubComposeView(club: club, history: history) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .sheet(item: $openMember) { person in
            NavigationStack { ClubMemberView(club: club, accountID: person.accountID) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .accessibilityIdentifier("social.club")
    }

    private var memberHeader: some View {
        HStack(spacing: ZOSpace.s) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text("Club").zoThemeText(.title).foregroundStyle(theme.textPrimary).accessibilityAddTraits(.isHeader)
                if let me = club.me, let number = me.person.memberNo {
                    Text(verbatim: localization.format("No. %1$@ · %2$lld followers", .text(ClubPerson.memberNumber(number)),
                                                       .integer(me.followers)))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            iconButton("person.2", "People") { showingPeople = true }
            iconButton("bell", "Activity") { showingActivity = true }
            if club.isAdmin { iconButton("flag", "Reports") { showingReports = true } }
            iconButton("person.crop.circle", "Your card and Club privacy") { showingSettings = true }
        }
    }

    private func iconButton(_ symbol: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .background(theme.surfaceSecondary, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func trainedRow(_ people: [ClubPerson]) -> some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text("Trained this week").zoText(.caption).foregroundStyle(theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ZOSpace.m) {
                        ForEach(people) { person in
                            Button { if person.accountID != club.me?.person.accountID { openMember = person } } label: {
                                VStack(spacing: ZOSpace.xs) {
                                    ClubAvatar(name: person.displayName, trained: true)
                                    Text(verbatim: person.accountID == club.me?.person.accountID
                                         ? localization.string("You") : person.displayName.components(separatedBy: " ").first ?? "")
                                        .zoText(.caption).foregroundStyle(theme.textPrimary).lineLimit(1)
                                }
                                .frame(width: 60)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A letter on a plain circle: no photos in the Club (Sammy, 3 Oct).
struct ClubAvatar: View {
    let name: String
    var trained = false
    var size: CGFloat = 44
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Text(verbatim: String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(trained ? theme.onAccent : theme.textPrimary)
            .frame(width: size, height: size)
            .background(trained ? theme.accentFill : theme.surfaceSecondary, in: Circle())
            .accessibilityHidden(true)
    }
}

struct ClubNote: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(title).zoThemeText(.title).foregroundStyle(theme.textPrimary).accessibilityAddTraits(.isHeader)
            Text(text).zoText(.body).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
    }
}

/// One post: who, when, the chosen sets and Respect. The menu holds report, hide and block.
@MainActor
struct ClubPostCard: View {
    let club: ClubStore
    let post: ClubPost
    var onOpenAuthor: (ClubPerson) -> Void = { _ in }
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var reporting = false
    @State private var confirmingBlock = false

    private var isMine: Bool { post.author?.accountID == club.me?.person.accountID }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(spacing: ZOSpace.s) {
                Button { if let author = post.author, !isMine { onOpenAuthor(author) } } label: {
                    HStack(spacing: ZOSpace.s) {
                        ClubAvatar(name: post.author?.displayName ?? "?", size: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: post.author?.displayName ?? localization.string("Former member"))
                                .zoText(.section).foregroundStyle(theme.textPrimary)
                            Text(verbatim: subtitle).zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    if isMine {
                        Button("Delete post", role: .destructive) { Task { await club.deletePost(post.id) } }
                    } else if let author = post.author {
                        Button("Report this post") { reporting = true }
                        Button(localization.format("Hide %1$@'s posts", .text(author.displayName))) {
                            Task { await club.hidePosts(of: author.accountID, true) }
                        }
                        Button(localization.format("Block %1$@", .text(author.displayName)), role: .destructive) {
                            confirmingBlock = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(theme.textSecondary)
                }
                .accessibilityLabel(Text("More"))
            }
            if !post.text.isEmpty {
                Text(verbatim: post.text).zoText(.body).foregroundStyle(theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            if !post.sets.isEmpty {
                VStack(alignment: .leading, spacing: ZOSpace.xs) {
                    ForEach(Array(post.sets.enumerated()), id: \.offset) { _, set in
                        Text(verbatim: ClubPostCard.setLine(set)).zoText(.section).foregroundStyle(theme.textPrimary)
                    }
                }
            }
            HStack {
                Button {
                    Task { await club.setRespect(post, on: !post.respected) }
                } label: {
                    Label(localization.format("Respect %1$lld", .integer(post.respectCount)),
                          systemImage: post.respected ? "flame.fill" : "flame")
                        .zoText(.section)
                        .padding(.horizontal, ZOSpace.m).frame(minHeight: 36)
                        .background(post.respected ? theme.accentFill : theme.surfaceSecondary, in: Capsule())
                        .foregroundStyle(post.respected ? theme.onAccent : theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(isMine)
                .accessibilityAddTraits(post.respected ? .isSelected : [])
                .sensoryFeedback(.impact(weight: .light), trigger: post.respected) { old, new in !old && new }
                Spacer()
            }
        }
        .padding(ZOSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .sheet(isPresented: $reporting) {
            NavigationStack { ClubReportView(club: club, post: post) }.zeroOneTheme(theme).zoSheet(theme)
        }
        .confirmationDialog(Text(verbatim: localization.format("Block %1$@?", .text(post.author?.displayName ?? ""))),
                            isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let id = post.author?.accountID { Task { await club.block(id, true) } }
            }
        } message: {
            Text("They won't see your card, posts or workouts and can't follow you. They won't be told.")
        }
    }

    private var subtitle: String {
        let number = post.author?.memberNo.map { "No. " + ClubPerson.memberNumber($0) }
        let time = post.createdAt.formatted(.relative(presentation: .named).locale(localization.locale))
        return [number, time].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Goblet squat 18 kg × 10", "Plank 45 s", "Push-up × 12". Units exactly as posted.
    static func setLine(_ set: ZeroOneSocialSelectedSet) -> String {
        var line = set.exercise
        if let load = set.load, let unit = set.unit, load > 0 {
            var number = String(load)
            if number.hasSuffix(".0") { number.removeLast(2) }
            line += " \(number) \(unit)"
        }
        if let reps = set.reps { line += " × \(reps)" }
        if let seconds = set.seconds { line += " \(seconds) s" }
        return line
    }
}

/// Join: handle, the name people see, two privacy choices and the 16+ confirmation.
@MainActor
struct ClubJoinView: View {
    let club: ClubStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var handle = ""
    @State private var name = ""
    @State private var findable = true
    @State private var showTrained = true
    @State private var sixteen = false
    @State private var showingRules = false
    @State private var nameHeld = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name people see", text: $name).textInputAutocapitalization(.words)
                    TextField("Handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("Your handle: 3 to 30 letters, numbers or underscores.") }
                Section {
                    Toggle("Find me by name", isOn: $findable)
                    Toggle("Show me in \"Trained this week\"", isOn: $showTrained)
                } footer: {
                    Text("What others see: your card, that you trained this week and what you post. Never your body weight, food or progress photos.")
                }
                Section {
                    Toggle("I'm 16 or older", isOn: $sixteen)
                    Button("Club rules") { showingRules = true }
                }
                if nameHeld {
                    Section { Text("That name or handle breaks the Club rules. Pick another.").foregroundStyle(theme.textSecondary) }
                } else if let notice = club.notice {
                    Section { Text(verbatim: localization.string(notice)).foregroundStyle(theme.textSecondary) }
                }
            }
            .onChange(of: name) { _, _ in nameHeld = false }
            .onChange(of: handle) { _, _ in nameHeld = false }
            .scrollContentBackground(.hidden)
            .navigationTitle(Text("Join the Club"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        guard ClubWordFilter.isClean(name), ClubWordFilter.isClean(handle) else {
                            nameHeld = true
                            return
                        }
                        Task {
                            if await club.join(handle: handle, displayName: name, findable: findable,
                                               showTrained: showTrained, confirmedSixteen: sixteen) { dismiss() }
                        }
                    }
                    .disabled(!sixteen || club.isWorking || ClubStore.validHandle(handle) == nil
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingRules) { NavigationStack { ClubRulesView() }.zeroOneTheme(theme).zoSheet(theme) }
        }
    }
}

/// Another member: their card, follow, their posts, and hide or block.
@MainActor
struct ClubMemberView: View {
    let club: ClubStore
    let accountID: UUID
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var detail: ClubMemberDetail?
    @State private var failed = false
    @State private var confirmingBlock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                if let detail {
                    if let card = ProfileSettingsYouVerifiedCard(
                        number: detail.person.memberNo.map(ClubPerson.memberNumber) ?? "",
                        holderName: detail.person.displayName, since: detail.person.joinedAt, workouts: detail.workoutsCount) {
                        ProfileSettingsYouCardView(snapshot: .init(asOf: .now, displayName: detail.person.displayName, card: card),
                                                   playsArrival: false)
                    }
                    Text(verbatim: localization.format("%1$lld followers · %2$lld following", .integer(detail.followers),
                                                       .integer(detail.following)))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                    Button {
                        Task { if await club.follow(accountID, !detail.person.iFollow) { await load() } }
                    } label: {
                        Text(detail.person.iFollow ? "Following" : (detail.person.followsMe ? "Follow back" : "Follow"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ZOButtonStyle(detail.person.iFollow ? .secondary : .primary))
                    .disabled(club.isWorking)
                    ForEach(detail.posts) { post in ClubPostCard(club: club, post: post) }
                } else if failed {
                    ClubNote(title: "This member isn't available.", text: "They may have a private profile or left the Club.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(ZOSpace.screenMargin)
        }
        .zoThemeScreenSurface()
        .toolbar {
            if let detail {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(detail.hidden ? "Show their posts" : "Hide their posts") {
                            Task { if await club.hidePosts(of: accountID, !detail.hidden) { await load() } }
                        }
                        Button("Block", role: .destructive) { confirmingBlock = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text("More"))
                }
            }
        }
        .confirmationDialog(Text("Block this member?"), isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { if await club.block(accountID, true) { failed = true; detail = nil } } }
        } message: { Text("They won't see your card, posts or workouts and can't follow you. They won't be told.") }
        .task { await load() }
    }

    private func load() async {
        detail = await club.member(accountID)
        failed = detail == nil
    }
}

/// Followers, following and search by name (proof 48 People).
@MainActor
struct ClubPeopleView: View {
    let club: ClubStore
    @Environment(\.zeroOneTheme) private var theme
    @State private var kind = ClubStore.PeopleKind.followers
    @State private var people: [ClubPerson] = []
    @State private var query = ""
    @State private var results: [ClubPerson]?
    @State private var openMember: ClubPerson?

    var body: some View {
        List {
            if let results {
                Section { if results.isEmpty { Text("No one found.") } else { rows(results) } }
            } else {
                Section {
                    Picker("List", selection: $kind) {
                        Text(verbatim: "\(String(localized: "Followers")) \(club.me?.followers ?? 0)").tag(ClubStore.PeopleKind.followers)
                        Text(verbatim: "\(String(localized: "Following")) \(club.me?.following ?? 0)").tag(ClubStore.PeopleKind.following)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section { if people.isEmpty { Text("No one yet.") } else { rows(people) } }
            }
        }
        .scrollContentBackground(.hidden)
        .zoThemeScreenSurface()
        .navigationTitle(Text("People"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search by name"))
        .onChange(of: query) { _, value in
            Task {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                results = trimmed.count < 2 ? nil : await club.search(trimmed)
            }
        }
        .task(id: kind) { people = await club.people(kind) ?? [] }
        .sheet(item: $openMember) { person in
            NavigationStack { ClubMemberView(club: club, accountID: person.accountID) }.zeroOneTheme(theme).zoSheet(theme)
        }
    }

    private func rows(_ list: [ClubPerson]) -> some View {
        ForEach(list) { person in
            HStack(spacing: ZOSpace.m) {
                Button { openMember = person } label: {
                    HStack(spacing: ZOSpace.m) {
                        ClubAvatar(name: person.displayName, trained: person.trainedThisWeek, size: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: person.displayName).zoText(.section).foregroundStyle(theme.textPrimary)
                            Text(verbatim: ([person.memberNo.map { "No. " + ClubPerson.memberNumber($0) },
                                            person.trainedThisWeek ? String(localized: "trained this week") : nil]
                                .compactMap { $0 }).joined(separator: " · "))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(person.iFollow ? "Following" : (person.followsMe ? "Follow back" : "Follow")) {
                    Task {
                        if await club.follow(person.accountID, !person.iFollow) {
                            people = await club.people(kind) ?? people
                            if results != nil { results = await club.search(query) }
                        }
                    }
                }
                .buttonStyle(ZOButtonStyle(person.iFollow ? .secondary : .primary))
                .disabled(club.isWorking)
            }
        }
    }
}

/// Respect and new followers (proof 48 Activity).
@MainActor
struct ClubActivityView: View {
    let club: ClubStore
    @Environment(\.zeroOneLocalization) private var localization
    @State private var activity: ClubActivity?

    var body: some View {
        List {
            if let activity {
                Section("Respect") {
                    if activity.respects.isEmpty { Text("No Respect in the last 30 days yet.") }
                    ForEach(activity.respects) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Self.respectLine(item, localization: localization))
                            Text(verbatim: item.latest.formatted(.relative(presentation: .named).locale(localization.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Followers") {
                    if activity.followers.isEmpty { Text("No followers yet.") }
                    ForEach(activity.followers) { person in Text(verbatim: person.displayName) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("Activity"))
        .navigationBarTitleDisplayMode(.inline)
        .task { activity = await club.activity() }
    }

    static func respectLine(_ item: ClubActivity.Respects, localization: AppLocalization) -> String {
        guard let first = item.givers.first?.displayName else { return "" }
        return item.count > 1
            ? localization.format("%1$@ and %2$lld others gave you Respect", .text(first), .integer(item.count - 1))
            : localization.format("%1$@ gave you Respect", .text(first))
    }
}

/// Your card, Club privacy, blocked people, rules and leaving (proof 48 Club privacy).
@MainActor
struct ClubSettingsView: View {
    let club: ClubStore
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var blocked: [ClubBlockedPerson] = []
    @State private var confirmingLeave = false
    @State private var showingRules = false

    var body: some View {
        List {
            if let me = club.me {
                Section {
                    if let card = ProfileSettingsYouVerifiedCard(number: me.person.memberNo.map(ClubPerson.memberNumber) ?? "",
                        holderName: me.person.displayName, since: me.person.joinedAt, workouts: me.workoutsCount) {
                        ProfileSettingsYouCardView(snapshot: .init(asOf: .now, displayName: me.person.displayName, card: card))
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    Toggle("Find me by name", isOn: Binding(get: { me.findable },
                        set: { value in Task { await club.updateSettings(findable: value) } }))
                    Toggle("Show me in \"Trained this week\"", isOn: Binding(get: { me.showTrained },
                        set: { value in Task { await club.updateSettings(showTrained: value) } }))
                } header: { Text("Who sees") } footer: {
                    Text("Body weight, food and progress photos are never shared unless you post them yourself.")
                }
            }
            Section("Blocked") {
                if blocked.isEmpty { Text("No one.") }
                ForEach(blocked) { person in
                    HStack {
                        Text(verbatim: person.displayName)
                        Spacer()
                        Button("Unblock") {
                            Task { if await club.block(person.accountID, false) { blocked = await club.blocked() ?? [] } }
                        }
                    }
                }
            }
            Section {
                Button("Club rules") { showingRules = true }
                Button("Leave the Club", role: .destructive) { confirmingLeave = true }
            }
        }
        .scrollContentBackground(.hidden)
        .zoThemeScreenSurface()
        .navigationTitle(Text("Your card"))
        .navigationBarTitleDisplayMode(.inline)
        .task { blocked = await club.blocked() ?? [] }
        .sheet(isPresented: $showingRules) { NavigationStack { ClubRulesView() }.zeroOneTheme(theme).zoSheet(theme) }
        .confirmationDialog(Text("Leave the Club?"), isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave the Club", role: .destructive) { Task { if await club.leaveClub() { dismiss() } } }
        } message: {
            Text("Your Club profile, follows and posts are removed. Your training on this iPhone stays.")
        }
    }
}

/// Study 30 screen 50: what's wrong, optional details, then offer to block.
@MainActor
struct ClubReportView: View {
    let club: ClubStore
    let post: ClubPost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneLocalization) private var localization
    @State private var category = ClubReportCategory.harassment
    @State private var details = ""
    @State private var sent = false

    var body: some View {
        Form {
            if sent {
                Section {
                    Text("Thanks. Sammy will look at it.").font(.headline)
                    Text("He reads every report himself, usually within a day.")
                }
                if let author = post.author {
                    Section {
                        Button(localization.format("Also block %1$@", .text(author.displayName)), role: .destructive) {
                            Task { if await club.block(author.accountID, true) { dismiss() } }
                        }
                    } footer: { Text("They won't see your card, posts or workouts and can't follow you. They won't be told.") }
                }
            } else {
                Section("What's wrong with this post?") {
                    Picker("Reason", selection: $category) {
                        ForEach(ClubReportCategory.allCases) { item in
                            VStack(alignment: .leading) {
                                Text(verbatim: localization.string(item.title))
                                if let detail = item.detail { Text(verbatim: localization.string(detail)).font(.caption) }
                            }
                            .tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical).lineLimit(3...6)
                } footer: {
                    Text("Sammy reads every report, usually within a day. The person won't know it was you.")
                }
            }
        }
        .navigationTitle(Text("Report"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
            if !sent {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send report") {
                        Task { sent = await club.report(post, category: category, details: details) }
                    }
                    .disabled(club.isWorking)
                }
            }
        }
    }
}

/// Study 30 screen 50: "Train hard, be decent."
struct ClubRulesView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text("Train hard, be decent.").font(.title3.weight(.semibold))
            }
            Section {
                ForEach(Array(ClubRulesView.rules.enumerated()), id: \.offset) { index, rule in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "\(index + 1)").font(.headline)
                        Text(rule)
                    }
                }
            }
            Section {
                Text("I read every report myself, usually within a day. If something feels wrong, tap Report, or just write to me. Sammy")
                Button("Write to Sammy") {
                    if let url = URL(string: "mailto:sammy@the01.app") { openURL(url) }
                }
            }
        }
        .navigationTitle(Text("Club rules"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static let rules: [LocalizedStringKey] = [
        "No insults, hate or harassment.",
        "No sexual content.",
        "No selling, spam or scams.",
        "No pushing anyone through pain or into extreme diets.",
        "Respect is the reaction. Use it a lot."
    ]
}

/// Sammy's queue (study 30 screen 50): open and done reports, with Remove, Block and Dismiss.
/// Only accounts listed as moderators on the server can load or act on it.
@MainActor
struct ClubModerationView: View {
    let club: ClubStore
    @Environment(\.zeroOneLocalization) private var localization
    @State private var showOpen = true
    @State private var items: [ClubReportItem]?

    var body: some View {
        List {
            Section {
                Picker("Status", selection: $showOpen) {
                    Text("Open").tag(true)
                    Text("Done").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if let items {
                if items.isEmpty { Text("Nothing to review.") }
                ForEach(items) { item in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: item.categories.compactMap { $0 }.map { localization.string(ClubReportCategory(rawValue: $0)?.title ?? $0) }
                                .joined(separator: ", ")).font(.headline)
                            Text(verbatim: localization.format("%1$@ · No. %2$@ · %3$lld reports", .text(item.author.displayName),
                                .text(item.author.memberNo.map(ClubPerson.memberNumber) ?? "—"), .integer(item.reports)))
                                .font(.caption).foregroundStyle(.secondary)
                            if !item.text.isEmpty { Text(verbatim: item.text) }
                            ForEach(Array(item.sets.enumerated()), id: \.offset) { _, set in Text(verbatim: ClubPostCard.setLine(set)) }
                            ForEach(Array((item.details ?? []).enumerated()), id: \.offset) { _, detail in
                                Text(verbatim: "“\(detail)”").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if showOpen {
                            HStack {
                                Button("Remove") { decide(item, .remove) }.buttonStyle(.bordered)
                                Button("Dismiss") { decide(item, .dismiss) }.buttonStyle(.bordered)
                                Button("Block", role: .destructive) { decide(item, .block) }.buttonStyle(.bordered)
                            }
                        } else {
                            Text(verbatim: localization.string(item.status.capitalized)).font(.caption)
                        }
                    }
                }
            } else {
                ProgressView()
            }
            Section { Text("Only you see this. Reporters stay anonymous to the people they report.").font(.caption) }
        }
        .navigationTitle(Text("Reports"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: showOpen) { items = await club.reports(open: showOpen) }
    }

    private func decide(_ item: ClubReportItem, _ decision: ClubModerationDecision) {
        Task { if await club.resolve(item, decision) { items = await club.reports(open: showOpen) } }
    }
}

/// Post a saved workout to your followers: the best set of each exercise, plus a line.
@MainActor
struct ClubComposeView: View {
    let club: ClubStore
    let history: WorkoutHistoryRepository
    @Environment(\.dismiss) private var dismiss
    @State private var selected: WorkoutHistoryEntry?
    @State private var text = ""
    /// Proof 50: the line as held by the filter, abusive words masked.
    @State private var heldLine: String?
    /// One ID per Publish, kept across retries so a post is never made twice.
    @State private var actionID = UUID()

    private var sessions: [WorkoutHistoryEntry] {
        Array(history.entries.filter { $0.exercises?.contains(where: { !$0.completedSets.isEmpty }) == true }.prefix(12))
    }

    var body: some View {
        Form {
            if let selected {
                Section("What your followers see") {
                    ForEach(Array(Self.sets(for: selected).enumerated()), id: \.offset) { _, set in
                        Text(verbatim: ClubPostCard.setLine(set))
                    }
                }
                Section {
                    TextField("Say something (optional)", text: $text, axis: .vertical).lineLimit(1...4)
                        .onChange(of: text) { _, _ in heldLine = nil }
                } footer: { Text("Only the sets above and your line are posted. Nothing else from this workout leaves your iPhone.") }
                if let heldLine {
                    Section {
                        Label("Not sent yet", systemImage: "exclamationmark.circle").font(.headline)
                        if !heldLine.isEmpty { Text(verbatim: heldLine).foregroundStyle(.secondary) }
                        Text("This looks like it breaks the Club rules. Edit it, then post.")
                    }
                }
            } else {
                Section("Pick a workout") {
                    if sessions.isEmpty { Text("Finish a workout to post it.") }
                    ForEach(sessions) { entry in
                        Button {
                            selected = entry
                            actionID = UUID()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: entry.title)
                                Text(entry.completedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Post a workout"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if let selected {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let sets = Self.sets(for: selected)
                        // Custom exercise names are typed by the person too.
                        guard ClubWordFilter.isClean(line), sets.allSatisfy({ ClubWordFilter.isClean($0.exercise) }) else {
                            heldLine = ClubWordFilter.masked(line)
                            return
                        }
                        Task {
                            if await club.publish(id: actionID, text: line, sets: sets) { dismiss() }
                        }
                    }
                    .disabled(club.isWorking)
                }
            }
        }
    }

    /// The heaviest set of each exercise (longest for timed work), at most six, units as recorded.
    static func sets(for entry: WorkoutHistoryEntry) -> [ZeroOneSocialSelectedSet] {
        (entry.exercises ?? []).compactMap { exercise -> ZeroOneSocialSelectedSet? in
            let sets = exercise.completedSets
            // A custom exercise's ID is the name the person typed.
            let name = ExerciseLibrary.exercise(id: exercise.exerciseID)?.name ?? exercise.exerciseID.rawValue
            if let timed = sets.filter(\.isTimed).max(by: { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }),
               sets.allSatisfy(\.isTimed) {
                return ZeroOneSocialSelectedSet(exercise: name, reps: nil, seconds: timed.durationSeconds, load: nil, unit: nil)
            }
            guard let best = sets.filter({ !$0.isTimed && $0.reps > 0 })
                .max(by: { ($0.load.value, $0.reps) < ($1.load.value, $1.reps) }) else { return nil }
            let loaded = best.load.value > 0
            return ZeroOneSocialSelectedSet(exercise: name, reps: best.reps, seconds: nil,
                load: loaded ? best.load.value : nil, unit: loaded ? best.load.unit.rawValue : nil)
        }
        .filter(\.isValid)
        .prefix(6)
        .map { $0 }
    }
}
