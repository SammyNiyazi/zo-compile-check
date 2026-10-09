import SwiftUI

struct ZOBanner: View {
    enum Kind { case information, success, warning, error }

    let message: String
    let symbol: String
    var kind: Kind = .information
    @Environment(\.zeroOneTheme) private var theme

    // The banner reads radius-card, but does not receive the Freak card polygon.
    private var radius: CGFloat {
        ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius
    }

    private var iconColor: Color {
        switch kind {
        case .information: theme.textPrimary
        case .success: theme.successPrimary
        case .warning: theme.warningPrimary
        case .error: theme.destructivePrimary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Image(systemName: symbol)
                .zoIcon(ZOIcon.row)
                .foregroundStyle(iconColor)
                .padding(.top, ZOStroke.hairline)
                .accessibilityHidden(true)
            Text(message)
                .zoText(.label)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ZOSpace.l)
        .padding(.vertical, ZOSpace.m)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The feature supplies a real acknowledgement and, when available, its exact Undo action.
struct ZOToast: View {
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZOSpace.xs))
            : AnyLayout(HStackLayout(spacing: ZOSpace.m))
        layout {
            Text(message)
                .zoText(.label)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ZOToastActionStyle())
            }
        }
        .foregroundStyle(theme.backgroundPrimary)
        .padding(.leading, ZOSpace.l)
        .padding(.trailing, ZOSpace.s)
        .padding(.vertical, typeSize.isAccessibilitySize ? ZOSpace.s : 0)
        .frame(minHeight: ZOSpace.x4)
        .background(theme.textPrimary, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

private struct ZOToastActionStyle: ButtonStyle {
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .zoText(.label)
            .foregroundStyle(theme.backgroundPrimary)
            .underline(isEnabled, color: theme.backgroundPrimary)
            .padding(.horizontal, ZOSpace.m)
            .frame(minHeight: ZOSpace.hitTarget)
            .contentShape(Rectangle())
    }
}
