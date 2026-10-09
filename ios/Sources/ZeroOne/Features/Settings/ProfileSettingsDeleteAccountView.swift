import SwiftUI
import StoreKit

/// Uses the existing authenticated deletion flow, including Apple reauthentication.
/// The presented identity must still be the current identity at confirmation.
struct ProfileSettingsDeleteAccountView: View {
    let identity: ZeroOneAccountIdentity
    let didDelete: @MainActor (String?) -> Void
    @Environment(ZeroOneAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var showingSubscriptions = false
    @State private var showsConfirmation = false

    private var matchesIdentity: Bool { account.identity == identity }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    Text("Delete your account?")
                        .zoText(.title)
                        .accessibilityAddTraits(.isHeader)
                    Text("This permanently deletes your online account. Workouts and other training data on this iPhone stay here. Manage those separately in Your data.")
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                    Text("Deleting your account does not cancel an Apple subscription. Cancel it in Apple's Subscriptions first.")
                        .zoText(.caption)
                        .padding(ZOSpace.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surfaceSecondary, in: .rect(cornerRadius: ZORadius.card))
                    Button("Open Subscriptions") { showingSubscriptions = true }
                        .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                    if !matchesIdentity {
                        Text("Your account changed. Close this screen and check the current account before deleting.")
                            .zoText(.caption)
                            .foregroundStyle(theme.destructivePrimary)
                    }
                    if let message = account.errorMessage {
                        Text(verbatim: localization.string(message))
                            .zoText(.caption)
                            .foregroundStyle(theme.destructivePrimary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if account.isBusy { ProgressView().accessibilityLabel("Connecting your account") }
                    Button("Delete account", role: .destructive) { showsConfirmation = true }
                        .buttonStyle(ZOButtonStyle(.destructive, wide: true))
                        .disabled(account.isBusy || !matchesIdentity)
                    Button("Keep my account") { dismiss() }
                        .buttonStyle(ZOButtonStyle(.quiet))
                        .disabled(account.isBusy)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(ZOSpace.screenMargin)
            }
            .background(theme.surfacePrimary)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("Your account")
            .navigationBarTitleDisplayMode(.inline)
        }
        .manageSubscriptionsSheet(isPresented: $showingSubscriptions)
        .confirmationDialog("Delete your 01 account?", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task { @MainActor in
                    // Recheck after scheduling, immediately before the service call.
                    guard ProfileSettingsPresentation.canDelete(presented: identity,
                        current: account.identity, isBusy: account.isBusy) else { return }
                    if await account.deleteAccount() {
                        didDelete(account.errorMessage)
                        dismiss()
                    }
                }
            }
            Button("Keep my account", role: .cancel) { }
        } message: {
            Text("This permanently deletes your online account. Workouts and other data on this iPhone stay here. An Apple subscription must be cancelled separately.")
        }
        .interactiveDismissDisabled(account.isBusy)
        .zoSheet()
    }
}
