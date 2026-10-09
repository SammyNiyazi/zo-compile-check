import SwiftUI

struct LearnTodaySection: View {
    let repository: LearnRepository
    let hasPlannedWorkout: Bool
    let workoutCompleted: Bool
    let workoutInProgress: Bool
    let onOpenWorkout: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var showsWhy = false

    /// The existing Today rule, ignoring "in progress" so the Why sheet keeps
    /// its topic; the card itself never shows during a workout.
    private var moment: LearnWorkoutMoment? {
        LearnWorkoutMoment.current(hasPlannedWorkout: hasPlannedWorkout,
                                   workoutCompleted: workoutCompleted, workoutInProgress: false)
    }

    private var lesson: LearnLesson? {
        moment.flatMap { LearnCatalog.lesson($0.lessonID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = repository.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .zoText(.caption).labelStyle(ZOIconLabelStyle())
                    .foregroundStyle(theme.textPrimary)
            }
            if !workoutInProgress, let lesson, let moment {
                if repository.cardIsVisible(lesson) {
                    LearnMomentCard(lesson: lesson, moment: moment, repository: repository,
                                    onOpenWorkout: onOpenWorkout, onWhy: { showsWhy = true },
                                    onNotNow: { repository.hideCardForToday() })
                } else if repository.cardIsHiddenToday() && repository.state.cardsOnToday {
                    HStack {
                        Text("Learning card hidden for today")
                            .zoText(.label)
                        Spacer()
                        Button("Undo") { repository.undoHideCard() }
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .disabled(!repository.canChange)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .contain)
                }
            }

            NavigationLink {
                LearnHomeView(repository: repository, onOpenWorkout: onOpenWorkout,
                              moment: workoutInProgress ? nil : moment)
            } label: {
                HStack(spacing: ZOSpace.m) {
                    LearnIconTile(symbol: "books.vertical", size: 32, radius: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn").zoText(.section)
                        Text("Short lessons, each with its sources.")
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .zoIcon(ZOIcon.inline)
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, ZOSpace.l)
                .padding(.vertical, ZOSpace.s)
                .frame(minHeight: ZOSpace.rowMinHeight)
                .zoThemeCardSurface()
            }
            .accessibilityLabel("Learn, training knowledge with sources")
        }
        .zoText(.body)
        .sheet(isPresented: $showsWhy) {
            Group {
                LearnWhySheet(repository: repository, topic: lesson?.topic)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .zoSheet()
        }
        .task(id: "\(lesson?.id ?? "none")-\(repository.state.cardsOnToday)-\(repository.state.fewerTopics.contains(lesson?.topic ?? .warmup))") {
            if let lesson, !workoutInProgress { repository.claimCard(lesson) }
        }
    }
}

/// Proof 44's lesson for the next workout: eyebrow, title, length, then
/// Read it. On Today it also keeps Not now and Why; Learn home shows it
/// without them, since only Today claims the daily card.
private struct LearnMomentCard: View {
    let lesson: LearnLesson
    let moment: LearnWorkoutMoment
    let repository: LearnRepository
    let onOpenWorkout: () -> Void
    var onWhy: (() -> Void)? = nil
    var onNotNow: (() -> Void)? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LearnEyebrow(text: localization.string(moment.eyebrow))
            Text(lesson.title)
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text(localization.format("%1$lld min · on this iPhone", .integer(lesson.minutes)))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            NavigationLink {
                LearnLessonView(lesson: lesson, repository: repository, onOpenWorkout: onOpenWorkout)
            } label: {
                Text("Read it")
            }
            .buttonStyle(ZOButtonStyle(.primary, primaryMinHeight: 44))
            .padding(.top, ZOSpace.m)
            .accessibilityLabel(localization.format("Read %1$@", .text(lesson.title)))
            .accessibilityHint("Opens a source-attributed lesson")

            if onNotNow != nil || onWhy != nil {
                HStack {
                    if let onWhy {
                        Button("Why am I seeing this?", action: onWhy)
                            .zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    if let onNotNow {
                        Button("Not now", action: onNotNow)
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .disabled(!repository.canChange)
                    }
                }
                .padding(.top, ZOSpace.xs)
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }
}

struct LearnHomeView: View {
    let repository: LearnRepository
    let onOpenWorkout: () -> Void
    /// The moment around a workout that Today reported, if any. Learn home
    /// shows its lesson on top only then; it never infers one itself.
    var moment: LearnWorkoutMoment? = nil

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var search = ""
    @State private var selectedTopic: LearnTopic? = nil
    @State private var savedOnly = false
    @State private var showsAbout = false

    private var visibleLessons: [LearnLesson] {
        LearnLessonPresentation.lessons(LearnCatalog.lessons, topic: selectedTopic, savedOnly: savedOnly,
                                        savedIDs: repository.state.savedIDs, search: search)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = repository.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .zoText(.label).labelStyle(ZOIconLabelStyle())
                        .padding(.bottom, ZOSpace.m)
                }

                // Proof 44: "Learn" as the display line and one short promise.
                Text("Learn")
                    .zoThemeText(.display)
                    .zoContextualHeadingSigil(role: .display, context: .directScrollDisplay)
                    .accessibilityAddTraits(.isHeader)
                Text("Short lessons, each with its sources.")
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                Button("About Learn") { showsAbout = true }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .padding(.leading, -ZOSpace.m)

                if let moment, let lesson = LearnCatalog.lesson(moment.lessonID) {
                    LearnMomentCard(lesson: lesson, moment: moment, repository: repository,
                                    onOpenWorkout: onOpenWorkout)
                        .padding(.top, ZOSpace.l)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: ZOSpace.s) {
                        LearnFilterButton(title: localization.string("All"), selected: selectedTopic == nil && !savedOnly) {
                            selectedTopic = nil; savedOnly = false
                        }
                        LearnFilterButton(title: localization.string("Saved"), selected: savedOnly) {
                            selectedTopic = nil; savedOnly = true
                        }
                        ForEach(LearnTopic.allCases) { topic in
                            LearnFilterButton(title: localization.string(topic.title),
                                              selected: selectedTopic == topic && !savedOnly) {
                                selectedTopic = topic; savedOnly = false
                            }
                            .accessibilityHint(localization.string(topic.subtitle))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 14)

                Text(savedOnly ? localization.string("Saved lessons")
                     : selectedTopic.map { localization.string($0.title) } ?? localization.string("All lessons"))
                    .zoText(.section)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 22)
                    .padding(.bottom, ZOSpace.s)

                if visibleLessons.isEmpty {
                    ContentUnavailableView(
                        savedOnly ? "Nothing saved yet" : "No matching lessons",
                        systemImage: savedOnly ? "bookmark" : "magnifyingglass",
                        description: Text(savedOnly ? "Save a lesson to find it here, even offline." : "Try another word or topic.")
                    )
                } else {
                    LazyVStack(spacing: ZOSpace.s) {
                        ForEach(visibleLessons) { lesson in
                            NavigationLink {
                                LearnLessonView(lesson: lesson, repository: repository, onOpenWorkout: onOpenWorkout)
                            } label: {
                                LearnLessonRow(lesson: lesson, saved: repository.isSaved(lesson))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.vertical, ZOSpace.l)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .zoThemeScreenSurface()
        .foregroundStyle(theme.textPrimary)
        .zoText(.body)
        .navigationTitle("Learn")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search lessons")
        .sheet(isPresented: $showsAbout) {
            Group {
                LearnAboutSheet(repository: repository)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .zoSheet()
        }
    }
}

private struct LearnFilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(ZOChipStyle(isSelected: selected))
    }
}

/// Proof `.zo-eyebrow`: 12/16, weight 700, 0.8 tracking, uppercase, ink 2.
struct LearnEyebrow: View {
    let text: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        Text(text.uppercased(with: localization.locale))
            .zoProofText(.caption, size: 12, lineHeight: 16, weight: 700, tracking: 0.8)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Proof `.zo-lessonrow .art` (56 pt, radius 12) and `.zo-row .ic` (32 pt,
/// radius 9): an SF symbol on surface 2. Topic icons only; no drawn art.
struct LearnIconTile: View {
    let symbol: String
    var size: CGFloat = 56
    var radius: CGFloat = ZORadius.control
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .zoIcon(size >= 56 ? ZOIcon.row : ZOIcon.inline)
            .foregroundStyle(theme.textPrimary)
            .frame(width: size, height: size)
            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Proof's graded meter is shown only for an explicit grade. An ungraded
/// source kind has words instead of an empty strip that could imply zero.
struct LearnEvidenceMeterView: View {
    let evidence: LearnEvidence
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        Group {
            switch LearnEvidenceMeter.presentation(for: evidence) {
            case .ungraded:
                Text(localization.string("Evidence strength not graded"))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .graded(filled):
                HStack(spacing: ZOSpace.xs) {
                    ForEach(0 ..< LearnEvidenceMeter.segmentCount, id: \.self) { index in
                        Capsule()
                            .fill(index < filled ? theme.textPrimary : theme.surfaceTertiary)
                            .frame(width: 22, height: 8)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LearnEvidenceMeter.accessibilityDescription(for: evidence, localization: localization))
    }
}

/// Proof `.zo-lessonrow`: a 56 pt topic tile, the title, "Topic · N min" with
/// the evidence meter, and a chevron (a bookmark when saved).
private struct LearnLessonRow: View {
    let lesson: LearnLesson
    let saved: Bool
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        HStack(alignment: .center, spacing: ZOSpace.m) {
            LearnIconTile(symbol: lesson.topic.symbol)
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(lesson.title)
                    .zoText(.section)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ZOSpace.s) {
                        topicLine
                        LearnEvidenceMeterView(evidence: lesson.evidence)
                    }
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        topicLine
                        LearnEvidenceMeterView(evidence: lesson.evidence)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: saved ? "bookmark.fill" : "chevron.right")
                .zoIcon(ZOIcon.inline)
                .foregroundStyle(saved ? theme.textPrimary : theme.textTertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(ZOSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: theme.designTheme == .freak ? .circular : .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: theme.designTheme == .freak ? .circular : .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lesson.title), \(lesson.topic.title), \(lesson.minutes) minute read, \(LearnEvidenceMeter.accessibilityDescription(for: lesson.evidence, localization: localization))\(saved ? ", saved" : "")")
    }

    private var topicLine: some View {
        Text(LearnLessonPresentation.topicLine(
            topic: localization.string(lesson.topic.title),
            minutes: localization.format("%1$lld min", .integer(lesson.minutes))))
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

