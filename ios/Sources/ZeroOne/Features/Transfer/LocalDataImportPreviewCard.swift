import SwiftUI

/// Canonical .zo-suggest presentation only; callers retain all review and import authority.
struct LocalDataImportPreviewCard: View {
    var fileName: String? = nil
    let foundTitle: String
    let found: Int
    let addedTitle: String
    let added: Int
    let skippedTitle: String
    let skipped: Int
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let fileName {
                Text(verbatim: fileName)
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(localization.string("Review before import"))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            LabeledContent(localization.string(foundTitle)) {
                count(found, style: .section)
            }
                .zoText(.section)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                LabeledContent(localization.string(addedTitle)) {
                    count(added, style: .section)
                }
                    .zoText(.section)
                LabeledContent(localization.string(skippedTitle)) {
                    count(skipped, style: .label)
                }
                    .zoText(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            Text(localization.string("Nothing on this iPhone is replaced."))
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfacePrimary, in: previewShape)
        .overlay { previewShape.strokeBorder(theme.textPrimary, lineWidth: ZOStroke.control) }
        .accessibilityElement(children: .contain)
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius,
                         style: theme.designTheme == .freak ? .circular : .continuous)
    }

    private func count(_ value: Int, style: ZOTextStyle) -> some View {
        let spec = style.spec
        return Text(verbatim: value.formatted(.number.locale(localization.locale)))
            .zoProofText(style, size: spec.size, lineHeight: spec.lineHeight,
                weight: spec.weight, width: 85, tracking: spec.tracking, tabular: true)
    }
}

