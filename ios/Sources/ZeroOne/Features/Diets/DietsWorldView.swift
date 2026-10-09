import SwiftUI

/// Proof 22's Diets host. All data, actions and approved learning content come
/// from the caller; this view owns only the selected segment.
struct DietsWorldView<Today: View, Trackers: View, Learn: View>: View {
    private enum Segment: Hashable {
        case today, trackers, learn
    }

    @Binding private var focusHydration: Bool
    private let onOpenProfile: () -> Void
    private let today: (Bool, @escaping () -> Void) -> Today
    private let trackers: () -> Trackers
    private let learn: () -> Learn

    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var selection: Segment = .today

    init(
        focusHydration: Binding<Bool>,
        onOpenProfile: @escaping () -> Void,
        @ViewBuilder today: @escaping (Bool, @escaping () -> Void) -> Today,
        @ViewBuilder trackers: @escaping () -> Trackers,
        @ViewBuilder learn: @escaping () -> Learn
    ) {
        self._focusHydration = focusHydration
        self.onOpenProfile = onOpenProfile
        self.today = today
        self.trackers = trackers
        self.learn = learn
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ZOSpace.m) {
                header
                ZOSegmentedControl("Diets sections", selection: $selection, options: [
                    ZOSegment(value: .today, label: Text("Today")),
                    ZOSegment(value: .trackers, label: Text("Trackers")),
                    ZOSegment(value: .learn, label: Text("Learn"))
                ])
                .accessibilityIdentifier("diets.world.sections")
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, ZOSpace.screenMargin)
            .padding(.top, ZOSpace.s)
            .padding(.bottom, ZOSpace.m)

            ZStack {
                // Keeping this subtree mounted retains the existing manual-entry
                // draft and review lifetime. The child cancels transient work
                // while inactive; hidden content cannot receive taps or AX focus.
                today(selection == .today, { selection = .trackers })
                    .opacity(selection == .today ? 1 : 0)
                    .allowsHitTesting(selection == .today)
                    .accessibilityHidden(selection != .today)

                if selection == .trackers {
                    trackers()
                } else if selection == .learn {
                    learn()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: focusHydration, initial: true) { _, shouldFocus in
            guard shouldFocus else { return }
            selection = .today
            // DietsHomeView consumes the request after scrolling to its real
            // hydration surface. The host must not clear it first.
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ZOSpace.l) {
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text("Diets")
                    .zoThemeHeading(.display, context: .headRowDisplay)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month()
                    .locale(localization.locale)))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZOSpace.s)
            ZeroOneProfileButton(action: onOpenProfile)
        }
    }
}
