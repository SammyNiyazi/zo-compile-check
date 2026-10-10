import SwiftUI

/// Proof 25 "Messages": crew chats and friends (people who follow each other),
/// with unread counts and who trained this week.
@MainActor
struct ClubMessagesView: View {
    let club: ClubStore
    let history: WorkoutHistoryRepository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        List {
            if club.inbox.isEmpty {
                Text("Follow each other to message, or start a crew to chat together.")
                    .foregroundStyle(.secondary)
            }
            ForEach(club.inbox) { conversation in
                NavigationLink {
                    ClubChatView(club: club, history: history, conversation: conversation)
                } label: {
                    HStack(spacing: ZOSpace.m) {
                        ClubAvatar(name: conversation.name, trained: conversation.person?.trainedThisWeek == true, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: conversation.name).font(.headline).lineLimit(1)
                            if let last = conversation.last {
                                Text(verbatim: (conversation.crewID != nil && !last.mine ? last.author.displayName + ": " : "")
                                     + last.preview(localization))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if conversation.unread > 0 {
                            Text(verbatim: String(conversation.unread))
                                .font(.caption.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 7).frame(minHeight: 20)
                                .foregroundStyle(theme.backgroundPrimary)
                                .background(theme.textPrimary, in: Capsule())
                                .accessibilityLabel(Text(verbatim: localization.format("%1$lld unread", .integer(conversation.unread))))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text("Messages"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { await club.loadInbox() }
        .refreshable { await club.loadInbox() }
    }
}

/// One conversation. Refreshes while open; text passes the word filter first.
@MainActor
struct ClubChatView: View {
    let club: ClubStore
    let history: WorkoutHistoryRepository
    let conversation: ClubConversation
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var messages: [ClubMessage] = []
    @State private var draft = ""
    @State private var held = false
    @State private var sharingWorkout = false
    @State private var planningTogether = false
    @State private var reporting: ClubMessage?

    private var target: ClubChatTarget? {
        if let crew = conversation.crewID { return .crew(crew) }
        return conversation.person.map { .person($0.accountID) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ZOSpace.s) {
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(ZOSpace.screenMargin)
            }
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .zoThemeScreenSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(Text(verbatim: conversation.name))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Refresh every 8 seconds while the chat is open; reading marks it read.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .onDisappear { Task { await club.loadInbox() } }
        .sheet(isPresented: $sharingWorkout) {
            NavigationStack { ClubChatWorkoutPicker(history: history) { sets in send(.workout, payload: ["sets": .sets(sets)]) } }
                .zeroOneTheme(theme).zoSheet(theme)
        }
        .sheet(isPresented: $planningTogether) {
            NavigationStack {
                ClubTrainTogetherSheet { when, title, place in
                    send(.together, payload: ["when": .string(ISO8601DateFormatter().string(from: when)),
                                              "title": .string(title), "place": .string(place)])
                }
            }
            .zeroOneTheme(theme).zoSheet(theme)
        }
        .sheet(item: $reporting) { message in
            NavigationStack { ClubMessageReportView(club: club, message: message) }.zeroOneTheme(theme).zoSheet(theme)
        }
    }

    private func reload() async {
        guard let target, let fresh = await club.messages(target) else { return }
        if fresh != messages { messages = fresh }
    }

    private func send(_ kind: ClubMessage.Kind, body: String = "", payload: [String: ClubValue] = [:]) {
        guard let target else { return }
        Task {
            if await club.send(target, id: UUID(), kind: kind, body: body, payload: payload) {
                if kind == .text { draft = "" }
                await reload()
            }
        }
    }

    private var composer: some View {
        VStack(spacing: ZOSpace.xs) {
            if held {
                Label("Not sent yet. This looks like it breaks the Club rules. Edit it, then send.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: ZOSpace.s) {
                Menu {
                    Button { sharingWorkout = true } label: { Label("Share a workout", systemImage: "dumbbell") }
                    Button { planningTogether = true } label: { Label("Train together", systemImage: "calendar") }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 40, height: 40)
                        .background(theme.surfaceSecondary, in: Circle())
                }
                .accessibilityLabel(Text("Share a workout or train together"))
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .padding(.horizontal, ZOSpace.m).padding(.vertical, 10)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
                    .onChange(of: draft) { _, _ in held = false }
                Button {
                    let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return }
                    guard ClubWordFilter.isClean(line) else { held = true; return }
                    send(.text, body: line)
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40)
                        .foregroundStyle(theme.backgroundPrimary).background(theme.textPrimary, in: Circle())
                }
                .accessibilityLabel(Text("Send"))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || club.isWorking)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.s)
        .background(theme.backgroundPrimary)
    }

    @ViewBuilder private func bubble(_ message: ClubMessage) -> some View {
        VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
            if conversation.crewID != nil && !message.mine {
                Text(verbatim: message.author.displayName).font(.caption).foregroundStyle(theme.textSecondary)
            }
            content(message)
                .contextMenu {
                    if message.mine {
                        Button("Delete", role: .destructive) { Task { if await club.deleteMessage(message) { await reload() } } }
                    } else {
                        Button("Report") { reporting = message }
                    }
                }
            Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    @ViewBuilder private func content(_ message: ClubMessage) -> some View {
        switch message.kind {
        case .workout:
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text("Workout").font(.caption.weight(.semibold)).foregroundStyle(theme.textSecondary)
                ForEach(Array((message.payload.sets ?? []).enumerated()), id: \.offset) { _, set in
                    Text(verbatim: ClubPostCard.setLine(set)).font(.subheadline)
                }
            }
            .padding(ZOSpace.m)
            .frame(maxWidth: 280, alignment: .leading)
            .zoThemeCardSurface()
        case .together:
            togetherCard(message)
        default:
            Text(verbatim: message.body)
                .padding(.horizontal, ZOSpace.m).padding(.vertical, 10)
                .foregroundStyle(message.mine ? theme.backgroundPrimary : theme.textPrimary)
                .background(message.mine ? theme.textPrimary : theme.surfaceSecondary,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 300, alignment: message.mine ? .trailing : .leading)
        }
    }

    private func togetherCard(_ message: ClubMessage) -> some View {
        let going = message.answers.filter(\.isIn).map { $0.mine ? localization.string("You") : $0.name }
        let mine = message.answers.first(where: \.mine)
        return VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("Train together").font(.caption.weight(.semibold)).foregroundStyle(theme.textSecondary)
            if let when = message.payload.when {
                Text(when.formatted(.dateTime.weekday(.wide).hour().minute().locale(localization.locale)))
                    .font(.headline)
            }
            Text(verbatim: [message.payload.title, message.payload.place].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")).font(.subheadline)
            if !going.isEmpty {
                Text(verbatim: localization.format("In: %1$@", .text(going.joined(separator: ", "))))
                    .font(.caption).foregroundStyle(theme.textSecondary)
            }
            if !message.mine {
                HStack {
                    Button("I'm in") { answer(message, "in") }
                        .buttonStyle(ZOButtonStyle(mine?.isIn == true ? .primary : .secondary))
                    Button("Not this time") { answer(message, "out") }
                        .buttonStyle(ZOButtonStyle(mine.map { !$0.isIn } == true ? .primary : .secondary))
                }
            }
        }
        .padding(ZOSpace.m)
        .frame(maxWidth: 300, alignment: .leading)
        .zoThemeCardSurface()
    }

    private func answer(_ message: ClubMessage, _ value: String) {
        send(.answer, payload: ["to": .string(message.id.uuidString), "answer": .string(value)])
    }
}

/// Share a saved workout into a chat: the same chosen sets as a Club post.
@MainActor
struct ClubChatWorkoutPicker: View {
    let history: WorkoutHistoryRepository
    let onPick: ([ZeroOneSocialSelectedSet]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            let sessions = Array(history.entries.filter { $0.exercises?.contains(where: { !$0.completedSets.isEmpty }) == true }.prefix(12))
            if sessions.isEmpty { Text("Finish a workout to share it.") }
            ForEach(sessions) { entry in
                Button {
                    let sets = ClubComposeView.sets(for: entry)
                    guard !sets.isEmpty else { return }
                    onPick(sets)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: entry.title)
                        Text(entry.completedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(Text("Share a workout"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// "Train together": a time, a workout and the gym, answered with one tap.
struct ClubTrainTogetherSheet: View {
    let onSend: (Date, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var when = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(
        bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now) ?? .now
    @State private var title = ""
    @State private var place = ""

    var body: some View {
        Form {
            DatePicker("When", selection: $when, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
            TextField("Workout, e.g. Upper body A", text: $title)
            TextField("Gym (optional)", text: $place)
        }
        .navigationTitle(Text("Train together"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    onSend(when, String(title.trimmingCharacters(in: .whitespaces).prefix(60)),
                           String(place.trimmingCharacters(in: .whitespaces).prefix(60)))
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || !ClubWordFilter.isClean(title) || !ClubWordFilter.isClean(place))
            }
        }
    }
}

/// Report a message: the same reasons as a post; Sammy reads every report.
@MainActor
struct ClubMessageReportView: View {
    let club: ClubStore
    let message: ClubMessage
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
                Section {
                    Button(localization.format("Also block %1$@", .text(message.author.displayName)), role: .destructive) {
                        Task { if await club.block(message.author.accountID, true) { dismiss() } }
                    }
                }
            } else {
                Section("What's wrong with this message?") {
                    Picker("Reason", selection: $category) {
                        ForEach(ClubReportCategory.allCases) { item in
                            Text(verbatim: localization.string(item.title)).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical).lineLimit(3 ... 6)
                } footer: { Text("Sammy reads every report, usually within a day. The person won't know it was you.") }
            }
        }
        .navigationTitle(Text("Report"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
            if !sent {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { sent = await club.reportMessage(message, category: category.rawValue, details: details) }
                    }
                    .disabled(club.isWorking)
                }
            }
        }
    }
}

/// Sammy's queue: reported messages, Remove or Dismiss.
@MainActor
struct ClubMessageModerationSection: View {
    let club: ClubStore
    @State private var items: [ClubMessageReport]?
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        Section("Messages") {
            if let items {
                if items.isEmpty { Text("No reported messages.") }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: localization.format("%1$@ · %2$lld reports", .text(item.author.displayName), .integer(item.reports)))
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.body.isEmpty { Text(verbatim: item.body) }
                        HStack {
                            Button("Remove") { decide(item, remove: true) }.buttonStyle(.bordered)
                            Button("Dismiss") { decide(item, remove: false) }.buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { items = await club.messageReports() }
    }

    private func decide(_ item: ClubMessageReport, remove: Bool) {
        Task { if await club.resolveMessageReport(item.id, remove: remove) { items = await club.messageReports() } }
    }
}
