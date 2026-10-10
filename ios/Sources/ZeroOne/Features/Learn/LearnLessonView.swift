import SwiftUI

struct LearnLessonView: View {
    let lesson: LearnLesson
    let repository: LearnRepository
    let onOpenWorkout: () -> Void

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @AccessibilityFocusState private var focusedAnswer: String?
    @State private var showsEvidence = false
    @State private var showsWhy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = repository.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .zoText(.label).labelStyle(ZOIconLabelStyle())
                        .padding(.bottom, ZOSpace.m)
                }
                header
                shortVersion
                    .padding(.top, 14)
                whyForYou
                steps
                questions
                certainty
                safety
                sources
                feedback
                reviewStatus
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { bookmarkButton }
        }
        .sheet(isPresented: $showsEvidence) {
            LearnEvidenceSheet(evidence: lesson.evidence)
                .zoSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsWhy) {
            LearnWhySheet(repository: repository, topic: lesson.topic)
                .zoSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Learn couldn't save", isPresented: Binding(
            get: { !repository.loadFailed && repository.errorMessage != nil },
            set: { if !$0 { repository.clearError() } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(repository.errorMessage ?? "")
        }
    }

    /// Proof `.zo-weekhead`: a section title, 22 pt above, 8 pt below.
    private func subhead(_ title: String) -> some View {
        Text(localization.string(title))
            .zoText(.section)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 22)
            .padding(.bottom, ZOSpace.s)
    }

    /// Proof 44: the topic and length as an eyebrow, the display title, then
    /// the lesson's own one-line summary.
    private var header: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            LearnEyebrow(text: localization.format("%1$@ · %2$lld min read",
                .text(localization.string(lesson.topic.title)), .integer(lesson.minutes)))
            Text(lesson.title)
                .zoThemeText(.display)
                .zoContextualHeadingSigil(role: .display, context: .directScrollDisplay)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(lesson.dek)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Proof `.zo-short`: surface 2, 16 pt in, the eyebrow, then 17/24 medium.
    private var shortVersion: some View {
        VStack(alignment: .leading, spacing: 6) {
            LearnEyebrow(text: localization.string("The short version"))
            Text(lesson.shortVersion)
                .zoProofText(.body, size: 17, lineHeight: 24, weight: 500)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius, style: theme.designTheme == .freak ? .circular : .continuous))
    }

    /// What was and was not used to show this lesson, in the app's own words.
    private var whyForYou: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("Why you're seeing it")
            Text("This lesson is in the on-device Learn library. 01 has not used Health, location or other apps to choose it.")
                .zoProofText(.body, size: 17, lineHeight: 26)
                .fixedSize(horizontal: false, vertical: true)
            Button("Why am I seeing this?") { showsWhy = true }
                .buttonStyle(ZOButtonStyle(.quiet))
                .padding(.leading, -ZOSpace.m)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("Put it to use")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(lesson.steps) { step in
                    HStack(alignment: .top, spacing: ZOSpace.m) {
                        Circle()
                            .fill(theme.textSecondary)
                            .frame(width: 6, height: 6)
                            .padding(.top, 8)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).zoText(.section)
                            Text(step.detail)
                                .zoProofText(.body, size: 17, lineHeight: 26)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Button(action: onOpenWorkout) {
                HStack(spacing: ZOSpace.s) {
                    Image(systemName: "dumbbell").zoIcon(ZOIcon.inline).accessibilityHidden(true)
                    Text("Open workout")
                }
            }
            .buttonStyle(ZOButtonStyle(.secondary, wide: true))
            .accessibilityHint("Review the existing workout plan. Learn does not change its loads or steps.")
            .padding(.top, ZOSpace.m)
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("Talk it through")
            Text("These answers are written into the lesson. They are not generated in a chat.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, ZOSpace.s)
            VStack(spacing: ZOSpace.s) {
                ForEach(lesson.questions) { question in
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        if repository.state.answeredQuestionIDs.contains("\(lesson.id):\(question.id)") {
                            Text(question.title).zoText(.section)
                            Text(question.answer)
                                .zoProofText(.body, size: 17, lineHeight: 26)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityFocused($focusedAnswer, equals: question.id)
                        } else {
                            Button {
                                repository.update { $0.answeredQuestionIDs.insert("\(lesson.id):\(question.id)") }
                                if repository.canChange { focusedAnswer = question.id }
                            } label: {
                                HStack {
                                    Text(question.title).zoText(.section)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: ZOSpace.s)
                                    Image(systemName: "plus")
                                        .zoIcon(ZOIcon.inline)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!repository.canChange)
                        }
                    }
                    .padding(ZOSpace.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zoThemeCardSurface()
                }
            }
        }
    }

    /// Proof's "How sure?": the meter and its label, then what the source
    /// settles and what stays open. The meter shows "not graded" unless the
    /// lesson carries a graded strength; the label is the evidence kind.
    private var certainty: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("How sure?")
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                if let grade = lesson.grade {
                    HStack(spacing: 10) {
                        HStack(spacing: ZOSpace.xs) {
                            ForEach(LearnGrade.Level.allCases, id: \.rawValue) { level in
                                Capsule().fill(level.rawValue <= grade.level.rawValue ? theme.textPrimary : theme.surfaceTertiary)
                                    .frame(width: 22, height: 8)
                            }
                        }
                        .accessibilityHidden(true)
                        Text(localization.string(grade.claim)).zoText(.section)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Text(localization.string(lesson.evidence.title)).zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        LearnEvidenceMeterView(evidence: lesson.evidence)
                        Text(localization.string(lesson.evidence.title)).zoText(.section)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(lesson.settled)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.format("Still open: %1$@", .text(lesson.open)))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("About evidence labels") { showsEvidence = true }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .padding(.leading, -ZOSpace.m)
            }
            .padding(ZOSpace.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoThemeCardSurface()
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("Where this lesson stops")
            Text(lesson.safety)
                .zoProofText(.body, size: 17, lineHeight: 26)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Proof's sources list: each one linked out, with what it supports and
    /// the date its link was checked, then the revision note.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            subhead("Sources")
            VStack(spacing: 0) {
                ForEach(Array(lesson.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 {
                        Rectangle().fill(theme.strokeSubtle).frame(height: ZOStroke.hairline)
                            .accessibilityHidden(true)
                    }
                    Link(destination: source.url) {
                        HStack(alignment: .center, spacing: ZOSpace.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .zoText(.section)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(localization.format("%1$@ · Supports: %2$@", .text(source.organization), .text(source.supports)))
                                    .zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Link checked 27 Sep 2026")
                                    .zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right.square")
                                .zoIcon(ZOIcon.inline)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(theme.textPrimary)
                        .padding(.vertical, ZOSpace.s)
                        .frame(minHeight: ZOSpace.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens the original source outside 01.")
                }
            }
            .padding(.horizontal, ZOSpace.l)
            .zoThemeCardSurface()
            Text("Bundled summary v1 · Source links checked 27 Sep 2026. Changes to guidance will require a new dated revision.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ZOSpace.s)
        }
    }

    /// Proof's "Was this useful?" card. The existing answer is one local
    /// "useful" mark that can be undone; nothing else is recorded.
    private var feedback: some View {
        let useful = repository.state.helpfulLessonIDs.contains(lesson.id)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Was this useful?").zoText(.section)
            Button(useful ? "Marked useful · Undo" : "Yes, useful") {
                repository.update {
                    if !$0.helpfulLessonIDs.insert(lesson.id).inserted { $0.helpfulLessonIDs.remove(lesson.id) }
                }
            }
            .buttonStyle(ZOChipStyle(isSelected: useful))
            .disabled(!repository.canChange)
            Text("Your feedback stays on this iPhone.")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
        .padding(.top, 22)
    }

    /// The review status, as the proof closes a lesson. No reviewer is named
    /// until one has reviewed it.
    private var reviewStatus: some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text("Source checked 27 Sep 2026 · 01 editorial review pending")
            Text("Source summary by 01 · No named expert or clinical reviewer has approved this lesson")
        }
        .zoText(.caption)
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, ZOSpace.m)
    }

    private var bookmarkButton: some View {
        Button {
            repository.toggleSaved(lesson)
        } label: {
            Image(systemName: repository.isSaved(lesson) ? "bookmark.fill" : "bookmark")
                .zoIcon(ZOIcon.row)
        }
        .buttonStyle(ZOButtonStyle(.round))
        .accessibilityLabel(repository.isSaved(lesson) ? "Remove saved lesson" : "Save lesson")
        .disabled(!repository.canChange)
    }

}

struct LearnEvidenceSheet: View {
    let evidence: LearnEvidence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(evidence.title).zoThemeText(.title)
                    Text(evidence.explanation)
                    ForEach([LearnEvidence.publicGuidance, .researchSummary, .how01Works], id: \.rawValue) { item in
                        Label(item.title, systemImage: item == evidence ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .zoThemeScreenSurface()
            .navigationTitle("Evidence labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct LearnWhySheet: View {
    let repository: LearnRepository
    let topic: LearnTopic?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A fixed rule on this iPhone chooses at most one card a day. A warm-up lesson can appear before a planned workout; a progression lesson can appear after a saved workout. Neither appears during a workout.")
                    Text("Uses: today's workout state in 01.")
                    Text("Doesn't use: Apple Health, location, other apps, or what you read elsewhere.")
                    Text("No generated chat or network request chooses a card.")
                    Toggle("Learning cards on Today", isOn: Binding(
                        get: { repository.state.cardsOnToday },
                        set: { value in repository.update { $0.cardsOnToday = value } }
                    ))
                    .disabled(!repository.canChange)
                    if let topic {
                        Toggle("Fewer \(topic.title.lowercased()) lessons", isOn: Binding(
                            get: { repository.state.fewerTopics.contains(topic) },
                            set: { value in repository.update { if value { $0.fewerTopics.insert(topic) } else { $0.fewerTopics.remove(topic) } } }
                        ))
                        .disabled(!repository.canChange)
                        Text("The topic preference removes this topic's timely card. Learn remains available from Today.")
                            .zoText(.caption)
                    }
                }
                .padding(20)
            }
            .zoThemeScreenSurface()
            .navigationTitle("Why this lesson?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct LearnAboutSheet: View {
    let repository: LearnRepository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("01 Learn").zoThemeText(.title)
                    Text("Short lessons that help you make a training decision and return to your workout.")
                    Text("Every lesson names its source and what that source supports.")
                    Text("These bundled summaries have not yet had an independent 01 editorial or clinical review. We do not invent a byline or review date.")
                    Text("Saved lessons and your choices stay on this iPhone. Every bundled lesson works offline; links to original sources need a connection.")
                    Text("Learn does not diagnose, prescribe treatment, or open an AI chat.")
                    Toggle("Learning cards on Today", isOn: Binding(
                        get: { repository.state.cardsOnToday },
                        set: { value in repository.update { $0.cardsOnToday = value } }
                    ))
                    .disabled(!repository.canChange)
                }
                .padding(20)
            }
            .zoThemeScreenSurface()
            .navigationTitle("About Learn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
