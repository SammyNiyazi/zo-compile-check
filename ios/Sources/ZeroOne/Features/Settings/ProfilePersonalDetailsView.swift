import SwiftUI
import AuthenticationServices

/// Optional accounts. Essential training and existing guest records remain on this device.
struct ZeroOneLoginView: View {
    @Environment(ZeroOneAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hasArrived = false
    @State private var showsEmail = false
    @State private var email = ""
    @State private var code = ""
    @State private var appleNonce: String?
    @State private var showsDeleteConfirmation = false
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                brand
                    .padding(.top, ZOSpace.l)
                    .modifier(ZeroOneLoginEntrance(arrived: hasArrived, delay: 0))

                Text(localization.string(account.identity != nil ? "Your account" : (account.pendingEmail != nil ? "Check your email" : (showsEmail ? "Sign in with email." : (account.hasAuthenticatedBefore ? "Welcome back" : "Welcome")))))
                    .zoText(.display)

                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, ZOSpace.xl)
                    .modifier(ZeroOneLoginEntrance(arrived: hasArrived, delay: 0.04))

                ZStack(alignment: .top) {
                    if account.identity != nil {
                        accountDetails
                    } else if showsEmail {
                        emailEntry
                            .transition(stepTransition(offset: forwardOffset))
                    } else {
                        methods
                            .transition(stepTransition(offset: -forwardOffset))
                    }
                }
                .modifier(ZeroOneLoginEntrance(arrived: hasArrived, delay: 0.08))

                availabilityNotice
                    .modifier(ZeroOneLoginEntrance(arrived: hasArrived, delay: 0.12))

                Button(localization.string(account.identity == nil ? "Continue without an account" : "Continue")) {
                    account.cancelSignIn()
                    dismiss()
                }
                    .zoText(.section)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .modifier(ZeroOneLoginEntrance(arrived: hasArrived, delay: 0.14))
                    .accessibilityHint("Returns to the app. Your training stays on this iPhone.")
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ZOSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.backgroundPrimary.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showsEmail {
                    Button("Back", systemImage: "chevron.backward") {
                        setEmailStep(false)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(ZOButtonStyle(.quiet))
                } else {
                    Button("Close", systemImage: "xmark") { account.cancelSignIn(); dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ZOButtonStyle(.quiet))
                }
            }
        }
        .task { hasArrived = true }
        .sensoryFeedback(.selection, trigger: showsEmail)
        .onDisappear { email = ""; code = ""; appleNonce = nil; account.cancelSignIn() }
        .confirmationDialog("Delete your 01 account?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { _ = await account.deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your online account. Workouts and other training data on this iPhone stay here. Use Local data to manage those separately.")
        }
    }

    private var forwardOffset: CGFloat { layoutDirection == .rightToLeft ? -28 : 28 }

    private func stepTransition(offset: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .offset(x: offset).combined(with: .opacity)
    }

    private func setEmailStep(_ value: Bool) {
        emailFocused = false
        codeFocused = false
        email = ""
        code = ""
        account.clearEmailStep()
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.86)) {
            showsEmail = value
        }
    }

    private var brand: some View {
        Image("ZeroOneFullLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 252, height: 122)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("01 Fitness and Performance")
    }

    private var methods: some View {
        VStack(spacing: ZOSpace.m) {
            SignInWithAppleButton(.signIn, onRequest: { request in
                do {
                    let nonce = try ZeroOneAccountProof.random()
                    appleNonce = nonce
                    request.nonce = ZeroOneAccountProof.appleNonce(nonce)
                    request.requestedScopes = [.email]
                } catch { account.errorMessage = ZeroOneAccountError.secureStorage.localizedDescription }
            }, onCompletion: { result in
                let nonce = appleNonce
                appleNonce = nil
                guard let nonce else { return }
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                        account.errorMessage = ZeroOneAccountError.invalidResponse.localizedDescription
                        return
                    }
                    Task { if await account.signInWithApple(token: token, nonce: nonce) { dismiss() } }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        account.errorMessage = ZeroOneAccountError.unavailable.localizedDescription
                    }
                }
            })
                .signInWithAppleButtonStyle(theme.colorScheme == .dark ? .white : .black)
                .frame(height: 56)
                .clipShape(.rect(cornerRadius: 16))
                .disabled(account.isBusy || appleNonce != nil || account.configuration?.appleEnabled != true)
                .accessibilityHint(Text(localization.string(account.configuration?.appleEnabled == true ? "Sign in securely using Apple." : "Apple sign-in is still being configured.")))

            Button { Task { if await account.signInWithGoogle() { dismiss() } } } label: {
                HStack(spacing: ZOSpace.m) {
                    Image("LoginGoogle")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ZOButtonStyle(.secondary))
            .disabled(account.isBusy || appleNonce != nil || account.configuration?.googleEnabled != true)
            .accessibilityHint(Text(localization.string(account.configuration?.googleEnabled == true ? "Opens Google's secure sign-in." : "Google sign-in is still being configured.")))

            Text("OR")
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZOSpace.xs)

            Button {
                setEmailStep(true)
            } label: {
                Label("Continue with email", systemImage: "envelope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ZOButtonStyle(.secondary))
            .disabled(account.isBusy || appleNonce != nil)
            .accessibilityHint("Sign in with a verification code sent to your email.")
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            if let destination = account.pendingEmail {
                Text("Enter the code sent to \(destination).")
                    .zoText(.body)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Verification code", text: $code)
                    .zoText(.body)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .padding(ZOSpace.m)
                    .frame(minHeight: 56)
                    .background(theme.surfacePrimary, in: .rect(cornerRadius: 16))
                    .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(10)) }
                    .accessibilityLabel("Verification code")
                Button("Verify and continue") {
                    codeFocused = false
                    Task { if await account.verifyEmailCode(code) { code = ""; dismiss() } }
                }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(account.isBusy || code.count < 6)
                Button("Request another code") { Task { _ = await account.requestEmailCode(destination) } }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .disabled(account.isBusy)
                Button("Use a different email") { account.clearEmailStep(); code = "" }
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .disabled(account.isBusy)
            } else {
            Text("Email address")
                .zoText(.section)
            TextField("Email address", text: $email,
                      prompt: Text(verbatim: "you@example.com").foregroundStyle(theme.textSecondary))
                .zoText(.body)
                .foregroundStyle(theme.textPrimary)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .submitLabel(.done)
                .onSubmit { emailFocused = false }
                .padding(ZOSpace.m)
                .frame(minHeight: 56)
                .background(theme.surfacePrimary, in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(emailFocused ? (theme.colorScheme == .dark ? ZeroOneColors.signalYellow : theme.textPrimary) : theme.strokeSubtle, lineWidth: emailFocused ? 2 : 1)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: emailFocused)
                .accessibilityLabel("Email address")
            Button("Send code") {
                emailFocused = false
                Task { if await account.requestEmailCode(email) { codeFocused = true } }
            }
                .buttonStyle(ZOButtonStyle(.primary))
                .disabled(account.isBusy || !account.isConfigured || !SupabaseZeroOneAccountService.validEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)))
                .accessibilityHint("Sends a one-time sign-in code. No password is needed.")
            }
        }
    }

    private var accountDetails: some View {
        VStack(spacing: ZOSpace.m) {
            Text(verbatim: account.identity?.email ?? localization.string("Signed in"))
                .zoText(.section)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            if account.needsVerification {
                Text("Reconnect to verify your session.").zoText(.caption)
                Button("Retry connection") { Task { await account.restore() } }
                    .buttonStyle(ZOButtonStyle(.secondary))
                    .disabled(account.isBusy)
            }
            Button("Sign out") { Task { await account.signOut() } }
                .buttonStyle(ZOButtonStyle(.secondary))
                .disabled(account.isBusy)
            Button("Delete account", role: .destructive) { showsDeleteConfirmation = true }
                .buttonStyle(ZOButtonStyle(.quiet))
                .disabled(account.isBusy)
        }
    }

    private var availabilityNotice: some View {
        VStack(spacing: ZOSpace.s) {
            if account.isBusy { ProgressView().accessibilityLabel("Connecting your account") }
            Text(account.errorMessage.map { localization.string($0) }
                ?? localization.string(account.isConfigured ? "Training stays on this iPhone. Account sync isn't available yet." : "Accounts are being connected. You can continue without one."))
                .zoText(.caption)
                .foregroundStyle(account.errorMessage == nil ? theme.textSecondary : theme.destructivePrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A short arrival sequence; transforms never gate input or alter the approved logo.
private struct ZeroOneLoginEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let arrived: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(arrived || reduceMotion ? 1 : 0.3)
            .offset(y: arrived || reduceMotion ? 0 : 16)
            .scaleEffect(arrived || reduceMotion ? 1 : 0.985)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82).delay(delay), value: arrived)
    }
}


enum ZeroOneProfileInitialTone: String, CaseIterable, Codable, Identifiable, Sendable {
    case onyx, stone, sand, signalYellow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onyx: "Onyx"
        case .stone: "Stone"
        case .sand: "Sand"
        case .signalYellow: "Signal Yellow"
        }
    }

    func background(in theme: ZeroOneThemeTokens) -> Color {
        switch self {
        case .onyx: theme.textPrimary
        case .stone: ZOColor.resolved(ZOColor.surface3, in: .light)
        case .sand: ZOTheme.retro.palette(dark: false)?.surface3 ?? ZOColor.resolved(ZOColor.surface3, in: .light)
        case .signalYellow: ZOColor.Swatch.yellow.fill
        }
    }

    func foreground(in theme: ZeroOneThemeTokens) -> Color {
        self == .onyx ? theme.backgroundPrimary : ZOColor.Swatch.yellow.on
    }
}

enum ZeroOneProfileDisplayName {
    static let maximumLength = 30

    static func validationMessage(for input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maximumLength { return "Use 30 characters or fewer." }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Remove line breaks or control characters."
        }
        return nil
    }

    static func storedValue(for input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ProfilePersonalDetailsView: View {
    @Bindable var profileRepository: ZeroOneUserProfileRepository
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsNameEditor = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ProfilePersonalThemeHeading(title: "Personal details", symbol: "person")
                Text(localization.string("Only what 01 needs. It stays on this iPhone."))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProfilePersistenceNotice(repository: profileRepository)
                    .zoText(.label)

                SettingsThemeGroup(title: "About you", footer: "Your name is optional. 01 does not ask for an email, birthday, gender or height here.", isList: true) {
                    Button { showsNameEditor = true } label: {
                        HStack(spacing: ZOSpace.m) {
                            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                                Text("Display name").zoText(.section)
                                Text(verbatim: profileRepository.profile.displayName ?? localization.string("Not set"))
                                    .zoText(.label)
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.forward")
                                .zoIcon(ZOIcon.inline)
                                .foregroundStyle(theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(theme.textPrimary)
                        .modifier(SettingsThemeListRow())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ZOPressStyle())
                    .accessibilityHint(Text(localization.string("Edit the name shown on your Profile. This stays on this iPhone.")))
                }

                SettingsThemeGroup(title: "Picture", footer: "Your initials on a colour. 01 does not ask for a photo here.") {
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())]
                        : [GridItem(.adaptive(minimum: ZOSpace.rowMinHeight + ZOSpace.x3), spacing: ZOSpace.m)],
                        alignment: .leading, spacing: ZOSpace.l) {
                        ForEach(ZeroOneProfileInitialTone.allCases) { tone in
                            Button {
                                guard profileRepository.updateVerified({ $0.initialsTone = tone }) else {
                                    saveError = "Couldn't save the colour on this iPhone. Try again."
                                    announceProfileError(saveError, localization: localization)
                                    return
                                }
                                saveError = nil
                            } label: {
                                let layout = dynamicTypeSize.isAccessibilitySize
                                    ? AnyLayout(HStackLayout(spacing: ZOSpace.m))
                                    : AnyLayout(VStackLayout(spacing: ZOSpace.s))
                                layout {
                                    Text(verbatim: profileInitial)
                                        .zoText(.section)
                                        .foregroundStyle(tone.foreground(in: theme))
                                        .frame(width: ZOSpace.x4 + ZOSpace.xs, height: ZOSpace.x4 + ZOSpace.xs)
                                        .background(tone.background(in: theme), in: Circle())
                                    HStack(alignment: .top, spacing: ZOSpace.xs) {
                                        Text(localization.string(tone.title))
                                            .zoText(.caption)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if (profileRepository.profile.initialsTone ?? .onyx) == tone {
                                            Image(systemName: "checkmark")
                                                .zoIcon(ZOIcon.inline)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .foregroundStyle(theme.textPrimary)
                                }
                                .frame(maxWidth: .infinity, minHeight: ZOSpace.hitTarget, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ZOPressStyle())
                            .accessibilityLabel(Text(localization.format("Initials colour, %1$@", .text(localization.string(tone.title)))))
                            .accessibilityAddTraits((profileRepository.profile.initialsTone ?? .onyx) == tone ? .isSelected : [])
                        }
                    }
                }

                if let saveError {
                    ZOBanner(message: localization.string(saveError), symbol: "exclamationmark.circle", kind: .error)
                }

                SettingsThemeGroup(title: "What 01 does not ask for") {
                    Text(localization.string("Your account email is managed separately under Account & sign-in."))
                    Text(localization.string("No birthday, gender or height."))
                }
                .zoText(.caption)
                .foregroundStyle(theme.textSecondary)
            }
            .padding(ZOSpace.screenMargin)
        }
        .navigationTitle("Personal details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Personal details").zoText(.section) } }
        .zoThemeScreenSurface()
        .sheet(isPresented: $showsNameEditor) {
            Group {
                ProfileNameEditor(profileRepository: profileRepository)
                    .presentationDetents([.medium, .large])
            }
            .zoSheet()
        }
    }

    private var profileInitial: String {
        guard let first = profileRepository.profile.displayName?.first else { return "01" }
        return String(first).uppercased()
    }
}

private struct ProfileNameEditor: View {
    @Bindable var profileRepository: ZeroOneUserProfileRepository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @State private var draft: String
    @State private var showsDiscardConfirmation = false
    @State private var saveError: String?
    @FocusState private var fieldFocused: Bool

    init(profileRepository: ZeroOneUserProfileRepository) {
        self.profileRepository = profileRepository
        // One-time editor draft. Parent changes do not replace an unsaved edit.
        _draft = State(initialValue: profileRepository.profile.displayName ?? "")
    }

    private var proposedName: String? { ZeroOneProfileDisplayName.storedValue(for: draft) }
    private var isDirty: Bool { proposedName != profileRepository.profile.displayName }
    private var validationMessage: String? { ZeroOneProfileDisplayName.validationMessage(for: draft) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.m) {
                    if profileRepository.saveError != nil {
                        ProfilePersistenceNotice(repository: profileRepository) { saveError = nil }
                    }
                    TextField("Display name", text: $draft)
                        .zoText(.body)
                        .padding(.horizontal, ZOSpace.l)
                        .frame(maxWidth: .infinity, minHeight: ZOSpace.rowMinHeight)
                        .background(theme.surfaceSecondary, in: fieldShape)
                        .overlay {
                            fieldShape
                                .strokeBorder(fieldFocused ? theme.textPrimary
                                    : (validationMessage == nil ? theme.separatorStrong : theme.destructivePrimary),
                                    lineWidth: fieldFocused ? ZOStroke.focus : ZOStroke.control)
                        }
                        .textContentType(.nickname)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("profile.displayName")
                        .focused($fieldFocused)
                    Text(localization.string("Optional, up to 30 characters. Clear the field to remove your name."))
                        .zoText(.caption).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                if let validationMessage {
                    ZOBanner(message: localization.string(validationMessage), symbol: "exclamationmark.circle", kind: .error)
                }
                if let saveError {
                    ZOBanner(message: localization.string(saveError), symbol: "exclamationmark.circle", kind: .error)
                }
                }
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.xxl)
            }
            .zoText(.body)
            .foregroundStyle(theme.textPrimary)
            .scrollDismissesKeyboard(.immediately)
            .background(theme.surfacePrimary)
            .navigationTitle("Display name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Display name").zoText(.section) }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { showsDiscardConfirmation = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isDirty || validationMessage != nil)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $showsDiscardConfirmation) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            } message: {
                Text(localization.string("Your current saved name will stay unchanged."))
            }
            .onChange(of: validationMessage, initial: true) { _, message in
                announceProfileError(message, localization: localization)
            }
            .interactiveDismissDisabled(isDirty)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ZOThemeComponentShape(theme: theme.designTheme, role: .control, radius: ZORadius.control).resolvedRadius,
            style: theme.designTheme == .freak ? .circular : .continuous)
    }

    private func save() {
        guard isDirty, validationMessage == nil else { return }
        guard profileRepository.updateVerified({ $0.displayName = proposedName }) else {
            saveError = "Couldn't save your name on this iPhone. Try again; your edit is still here."
            announceProfileError(saveError, localization: localization)
            return
        }
        dismiss()
    }
}

/// Announce only static failure copy from the real error state, never the name draft.
private func announceProfileError(_ message: String?, localization: AppLocalization) {
    guard let message else { return }
    AccessibilityNotification.Announcement(localization.string(message)).post()
}


/// Original heading content/layout; only this caller adopts the shared title role.
private struct ProfilePersonalThemeHeading: View {
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
                .zoThemeText(.title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(theme.textPrimary)
    }
}
