import SwiftUI

/// Diets > Learn. Sammy (9 Oct) chose Claude-drafted articles with named public
/// sources (DietLearnCatalog), shown as drafts until he or a reviewer approves
/// them. The name is kept for the existing root caller.
struct DietsLearnEmptyView: View {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var selected: LearnLesson?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                Text(localization.string("Diets, explained"))
                    .zoThemeHeading(.title, context: .headRowDisplay)
                    .accessibilityAddTraits(.isHeader)
                if DietLearnCatalog.lessons.isEmpty {
                    Text(localization.string("Diet articles are not available yet."))
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !DietLearnCatalog.isReviewed {
                        Label(localization.string("Drafts with sources. Not yet reviewed by a professional."),
                              systemImage: "doc.text.magnifyingglass")
                            .labelStyle(ZOIconLabelStyle())
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    ForEach(DietLearnCatalog.lessons) { lesson in
                        Button { selected = lesson } label: { row(lesson) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("diets.learn.\(lesson.id)")
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(ZOSpace.screenMargin)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(theme.textPrimary)
        .sheet(item: $selected) { lesson in
            NavigationStack { DietLessonView(lesson: lesson) }
                .zeroOneTheme(theme)
                .zoSheet(theme)
        }
    }

    private func row(_ lesson: LearnLesson) -> some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(localization.string(lesson.title)).zoText(.section).foregroundStyle(theme.textPrimary)
                Text(localization.string(lesson.dek)).zoText(.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.format("%1$lld min read", .integer(lesson.minutes)))
                    .zoText(.caption).foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: ZOSpace.s)
            Image(systemName: "chevron.forward").zoIcon(ZOIcon.inline)
                .foregroundStyle(theme.textTertiary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZOSpace.cardPadding)
        .zoThemeCardSurface()
        .contentShape(Rectangle())
    }
}

/// One drafted diet article: the short version, three steps, questions,
/// what is settled and open, the safety line and every source, linked.
struct DietLessonView: View {
    let lesson: LearnLesson
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    if !DietLearnCatalog.isReviewed {
                        Text(localization.string("Draft, not yet reviewed"))
                            .zoText(.caption).foregroundStyle(theme.textSecondary)
                    }
                    Text(localization.string(lesson.title)).zoThemeText(.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(localization.string(lesson.shortVersion)).zoText(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    ForEach(Array(lesson.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.m) {
                            Text(verbatim: "\(index + 1)").zoText(.metric).foregroundStyle(theme.textSecondary)
                            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                                Text(localization.string(step.title)).zoText(.section)
                                Text(localization.string(step.detail)).zoText(.body).foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(ZOSpace.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zoThemeCardSurface()
                ForEach(lesson.questions) { question in
                    VStack(alignment: .leading, spacing: ZOSpace.xs) {
                        Text(localization.string(question.title)).zoText(.section)
                        Text(localization.string(question.answer)).zoText(.body).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                block("What's settled", lesson.settled)
                block("What's still open", lesson.open)
                block("Safety", lesson.safety)
                VStack(alignment: .leading, spacing: ZOSpace.s) {
                    Text(localization.string(lesson.evidence.title)).zoText(.section)
                    ForEach(lesson.sources) { source in
                        Link(destination: source.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(source.organization): \(source.title)").zoText(.label)
                                Text(localization.string(source.supports)).zoText(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .accessibilityHint(Text(localization.string("Opens the source in Safari.")))
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(ZOSpace.screenMargin)
        }
        .foregroundStyle(theme.textPrimary)
        .tint(theme.textPrimary)
        .zoThemeScreenSurface()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(localization.string(title)).zoText(.caption).foregroundStyle(theme.textSecondary)
            Text(localization.string(text)).zoText(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}
