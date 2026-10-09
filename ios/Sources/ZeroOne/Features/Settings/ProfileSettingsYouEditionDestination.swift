import SwiftUI

/// Observing the retained store updates the live preview and selected radio in
/// the pushed destination. External edition handlers run only after readback.
@MainActor
struct ProfileSettingsYouEditionDestination: View {
    let snapshot: ProfileSettingsYouSnapshot
    @ObservedObject var store: ProfileSettingsYouEditionStore
    var membershipState: ProfileSettingsYouCardState? = nil
    var onSelected: (@MainActor (ProfileSettingsYouEdition) -> Void)? = nil
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        let displayed = ProfileSettingsYouSnapshot(asOf: snapshot.asOf,
            displayName: snapshot.displayName, card: snapshot.card, month: snapshot.month,
            bodyWeight: snapshot.bodyWeight, edition: store.resolved(fallback: snapshot.edition))
        VStack(spacing: 0) {
            if store.saveFailed {
                ZOBanner(message: localization.string("Card edition could not be saved."), symbol: "info.circle")
                    .padding(.horizontal, 20)
                Button(action: store.reload) { Text(verbatim: localization.string("Try again")) }.buttonStyle(ZOButtonStyle(.quiet))
            }
            ProfileSettingsYouEditionView(snapshot: displayed, selectEdition: { edition in
                if store.select(edition) { onSelected?(edition) }
            }, membershipState: membershipState).disabled(!store.isAvailable)
        }.zoThemeScreenSurface()
    }
}
