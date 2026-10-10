import SwiftUI

/// Presentation only. Feature views retain their own drafts, permissions and actions.
struct ProfileDataGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text(localization.string(title))
                .zoProofText(.caption, size: 13, lineHeight: 18, weight: 600)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, ZOSpace.xs)
            VStack(alignment: .leading, spacing: ZOSpace.m) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ZOSpace.cardPadding)
                .background(theme.surfacePrimary, in: ZORadius.cardShape)
            if let footer {
                Text(localization.string(footer))
                    .zoText(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZOSpace.xs)
            }
        }
    }
}

/// The preview is generated from the coordinator's actual counts. It grants no import authority.
struct LocalDataPreviewCard: View {
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
        .background(theme.surfacePrimary, in: ZORadius.cardShape)
        .overlay { ZORadius.cardShape.strokeBorder(theme.textPrimary, lineWidth: ZOStroke.control) }
        .accessibilityElement(children: .contain)
    }

    private func count(_ value: Int, style: ZOTextStyle) -> some View {
        let spec = style.spec
        return Text(verbatim: value.formatted(.number.locale(localization.locale)))
            .zoProofText(style, size: spec.size, lineHeight: spec.lineHeight,
                weight: spec.weight, width: 85, tracking: spec.tracking, tabular: true)
    }
}

struct LocalDataScreenHeading: View {
    let title: String
    let symbol: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            ZOAppIcon(symbol, size: ZOIcon.row)
                .frame(width: ZOSpace.x3, height: ZOSpace.x3)
                .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.small + ZOStroke.hairline))
                .accessibilityHidden(true)
            Text(localization.string(title))
                .zoText(.title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(theme.textPrimary)
    }
}
