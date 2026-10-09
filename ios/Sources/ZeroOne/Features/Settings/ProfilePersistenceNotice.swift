import SwiftUI

/// Shared failure feedback, not a replacement for an editor's unsaved draft.
struct ProfilePersistenceNotice: View {
    @Bindable var repository: ZeroOneUserProfileRepository
    var onReload: () -> Void = {}
    @Environment(\.zeroOneTheme) private var theme

    var body: some View {
        if let error = repository.saveError {
            VStack(alignment: .leading, spacing: ZOSpace.s) {
                Text(error)
                    .foregroundStyle(theme.destructivePrimary)
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Reload saved preferences") {
                    if repository.reload() { onReload() }
                }
                .frame(minHeight: 44)
            }
        }
    }
}
