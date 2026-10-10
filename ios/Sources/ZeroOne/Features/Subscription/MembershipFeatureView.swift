import StoreKit
import SwiftUI

/// Present this from Today or Profile. The composition root supplies real product IDs and
/// approved legal URLs; the default configuration intentionally displays beta information.
struct MembershipFeatureView: View {
    // An intentionally view-owned store seeded once by either initializer.
    @State private var store: StoreKitMembershipStore
    @State private var showingExpiredOffer = false
    @State private var presentationID: UUID? = UUID()
    @State private var restoredOperationID: UUID?
    private let onNotNow: (() -> Void)?
    private let onExportTraining: (() -> Void)?
    private let plannedWorkoutDates: [Date]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    init(configuration: MembershipConfiguration = .unconfigured,
         plannedWorkoutDates: [Date] = [],
         onNotNow: (() -> Void)? = nil,
         onExportTraining: (() -> Void)? = nil) {
        store = StoreKitMembershipStore(configuration: configuration)
        self.plannedWorkoutDates = plannedWorkoutDates
        self.onNotNow = onNotNow
        self.onExportTraining = onExportTraining
    }

    init(store: StoreKitMembershipStore,
         plannedWorkoutDates: [Date] = [],
         onNotNow: (() -> Void)? = nil,
         onExportTraining: (() -> Void)? = nil) {
        self.store = store
        self.plannedWorkoutDates = plannedWorkoutDates
        self.onNotNow = onNotNow
        self.onExportTraining = onExportTraining
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.configuration.isBeta {
                    MembershipMessageScreen(
                        title: "You're on the 01 beta.",
                        detail: "Membership is not available in this version.",
                        actionTitle: "Close",
                        action: closeMembership
                    )
                } else if let restoredOperationID, store.access.hasVerifiedAccess {
                    MembershipRestoredPresentationView(access: store.access,
                        outcome: .verifiedActive(operationID: restoredOperationID),
                        showCelebration: true, onContinue: closeMembership)
                } else if store.access.hasVerifiedAccess || store.access == .billingRetry || store.access == .revoked {
                    MembershipStatusScreen(store: store, onClose: closeMembership, onRestore: restoreMembership)
                } else if store.isLoading || store.access == .checking {
                    MembershipMessageScreen(
                        title: "Checking membership",
                        detail: "Asking Apple for your membership and available plans.",
                        actionTitle: "Close",
                        action: closeMembership,
                        showsProgress: true
                    )
                } else if store.access == .expired && !showingExpiredOffer {
                    MembershipExpiredScreen(store: store, onClose: closeMembership,
                                            onRestore: restoreMembership,
                                            onExportTraining: onExportTraining) {
                        showingExpiredOffer = true
                    }
                } else if store.products.isEmpty || store.access == .unknown || store.eligibility == .unavailable {
                    MembershipUnavailableScreen(store: store, onClose: closeMembership)
                } else {
                    MembershipOfferScreen(store: store, plannedWorkoutDates: plannedWorkoutDates, onClose: closeOffer, onRestore: restoreMembership)
                }
            }
            .zoThemeScreenSurface()
        }
        .onAppear { if presentationID == nil { presentationID = UUID() } }
        .onDisappear {
            presentationID = nil
            restoredOperationID = nil
        }
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.reload() } }
        }
        .onChange(of: store.access) { _, access in
            if !access.hasVerifiedAccess { restoredOperationID = nil }
        }
    }

    private func closeMembership() {
        presentationID = nil
        restoredOperationID = nil
        dismiss()
    }

    private func restoreMembership() {
        guard let lifetime = presentationID, store.action == .idle else { return }
        let operationID = UUID()
        Task { @MainActor in
            let restored = await store.restore()
            guard restored, !Task.isCancelled, presentationID == lifetime,
                  store.access.hasVerifiedAccess else { return }
            restoredOperationID = operationID
        }
    }

    private func closeOffer() {
        onNotNow?()
        closeMembership()
    }
}

/// Donna can place this below Start in the week-one review once real week progress and
/// dismissal cadence are available. This card does not decide when the invitation appears.
struct MembershipInvitationCard: View {
    let openMembership: () -> Void
    let dismissInvitation: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.s) {
            Text("01 MEMBERSHIP")
                .zoText(.caption)

                .foregroundStyle(theme.textSecondary)
            Text("Build on week 1.")
                .zoThemeText(.title)
                .foregroundStyle(theme.textPrimary)
            Text("See how the next two weeks can fit your training.")
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
            Button(action: openMembership) {
                HStack {
                    Text("See membership")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .zoText(.section)
                .frame(minHeight: ZOSpace.hitTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textPrimary)
            .accessibilityIdentifier("membership.invitation")
            Button("Not now", action: dismissInvitation)
                .zoText(.body)
                .foregroundStyle(theme.textSecondary)
                .frame(minHeight: ZOSpace.hitTarget)
        }
        .padding(ZOSpace.cardPadding)
        .zoThemeCardSurface()
    }
}

private struct MembershipOfferScreen: View {
    let store: StoreKitMembershipStore
    let plannedWorkoutDates: [Date]
    let onClose: () -> Void
    let onRestore: () -> Void
    @State private var showingTerms = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    private var trialDays: Int? {
        MembershipTrialPresentation.approvedDays(product: store.selectedProduct, eligibility: store.eligibility)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.stack) {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark").accessibilityHidden(true)
                        }
                        .buttonStyle(ZOButtonStyle(.round))
                        .accessibilityLabel(localization.string("Not now"))
                        Spacer()
                        Button("Restore", action: onRestore)
                            .buttonStyle(ZOButtonStyle(.quiet))
                            .disabled(store.action != .idle)
                    }
                    VStack(spacing: ZOSpace.xs) {
                        Text("Everything in 01.")
                            .zoThemeText(.display)
                            .zoContextualHeadingSigil(role: .display, context: .directScrollDisplay)
                        Text("One membership.").zoText(.body).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, ZOSpace.m)

                    MembershipPeriodPicker(store: store)
                    if let product = store.selectedProduct {
                        MembershipPriceSummary(product: product, eligibility: store.eligibility)
                    }
                    if let trialDays {
                        MembershipTrainingBlock(start: context.date, days: trialDays,
                                                plannedWorkoutDates: plannedWorkoutDates)
                    } else if store.eligibility == .checking {
                        MembershipNotice(text: "Checking free trial eligibility with Apple…")
                    } else if store.eligibility == .ineligible {
                        MembershipNotice(text: "A free trial is not available for this Apple Account. Payment starts when you confirm with Apple.")
                    } else {
                        MembershipNotice(text: "Free trial eligibility could not be checked.")
                    }
                    if !store.configuration.hasLegalLinks {
                        MembershipNotice(text: "Purchasing is unavailable until Terms of Use and Privacy Policy are approved and linked.")
                    }
                    if let message = store.message { MembershipNotice(text: message) }
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.bottom, ZOSpace.xxl)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: ZOSpace.xs) {
                    MembershipPrimaryButton(title: trialDays == nil ? "Continue" : "Start 2 weeks free",
                                            subtitle: "Apple asks you to confirm next",
                                            disabled: !store.canPurchase,
                                            showsProgress: store.action != .idle || store.eligibility == .checking) {
                        showingTerms = true
                    }
                    Text("Cancel any time in your Apple Account").zoText(.caption)
                        .foregroundStyle(theme.textSecondary)
                    MembershipLegalLinks(configuration: store.configuration)
                }
                .padding(.bottom, ZOSpace.s)
                .background(theme.backgroundPrimary)
            }
            .navigationDestination(isPresented: $showingTerms) {
                MembershipTermsScreen(store: store, onClose: onClose, onRestore: onRestore)
            }
            .accessibilityAction(.escape) { onClose() }
        }
    }
}

private struct MembershipPeriodPicker: View {
    let store: StoreKitMembershipStore
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: ZOSpace.s) {
            ForEach(store.products, id: \.id) { product in
                let selected = store.selectedProduct?.id == product.id
                Button {
                    Task { await store.select(product.id) }
                } label: {
                    HStack(alignment: .center, spacing: ZOSpace.m) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: ZOSpace.s) {
                                periodLabel(product)
                                priceLabel(product, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .center, spacing: ZOSpace.s) {
                                    periodLabel(product)
                                    Spacer(minLength: ZOSpace.s)
                                    priceLabel(product, alignment: .trailing)
                                }
                                VStack(alignment: .leading, spacing: ZOSpace.s) {
                                    periodLabel(product)
                                    priceLabel(product, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, ZOSpace.cardPadding)
                    .padding(.vertical, ZOSpace.m)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: offerRadius))
                    .overlay(RoundedRectangle(cornerRadius: offerRadius)
                        .strokeBorder(selected ? theme.textPrimary : ZOColor.resolved(ZOColor.separatorStrong, in: theme.colorScheme),
                                      lineWidth: selected ? ZOStroke.focus : ZOStroke.control))
                    .animation(reduceMotion ? nil : ZOMotion.brace(ZOMotion.micro), value: selected)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .disabled(store.action != .idle || store.eligibility == .checking)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("membership.plan.\(product.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Billing period")
    }

    private var offerRadius: CGFloat {
        ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius
    }

    private func periodLabel(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: ZOSpace.xs) {
            Text(product.membershipPeriodTitle(localization)).zoText(.section)
            Text("Cancel any time").zoText(.caption).foregroundStyle(theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func priceLabel(_ product: Product, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: ZOSpace.xs) {
            Text(product.displayPrice).zoText(.section)
            Text(product.membershipPeriodPhrase(localization)).zoText(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MembershipPriceSummary: View {
    let product: Product
    let eligibility: MembershipEligibility
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization


    var body: some View {
        Text(summary)
            .zoText(.caption)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("membership.priceTerms")
    }

    private var summary: String {
        if MembershipTrialPresentation.approvedDays(product: product, eligibility: eligibility) != nil {
            return localization.format("Two weeks free, then %1$@ %2$@. Renews automatically until you cancel.",
                                       .text(product.displayPrice), .text(product.membershipPeriodPhrase(localization)))
        }
        if eligibility == .checking {
            return localization.string("Apple is checking whether a free trial applies. No purchase is available yet.")
        }
        return localization.format("%1$@ %2$@ from confirmation with Apple. Renews automatically until you cancel.",
                                   .text(product.displayPrice), .text(product.membershipPeriodPhrase(localization)))
    }
}

private struct MembershipTrainingBlock: View {
    let start: Date
    let days: Int
    let plannedWorkoutDates: [Date]
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization


    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            MembershipFact(icon: "circle.fill", title: localization.string("Today"),
                           detail: localization.string("Full access, free for 2 weeks"))
            if let paymentDate = MembershipOfferCalendar.freeUntil(start: start, days: days) {
                MembershipFact(icon: "calendar", title: paymentDate.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)),
                               detail: localization.string("Estimated first payment, unless you cancel before the trial ends."))
            }
            Text("Dates are estimates if you confirm today. Apple confirms the actual trial end.")
                .zoText(.caption).foregroundStyle(theme.textSecondary)
            let plans = MembershipTrialPresentation.plannedDays(plannedWorkoutDates, start: start, days: days)
            if !plans.isEmpty {
                Text(localization.format("Planned training: %1$@.",
                     .text(plans.map { $0.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)) }.joined(separator: ", "))))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(ZOSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoThemeCardSurface()
    }
}
private struct MembershipTermsScreen: View {
    let store: StoreKitMembershipStore
    let onClose: () -> Void
    let onRestore: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dismiss) private var dismiss

    private var hasTrial: Bool { MembershipTrialPresentation.approvedDays(product: store.selectedProduct, eligibility: store.eligibility) != nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: ZOSpace.l) {
                    HStack {
                        Button("Back") { dismiss() }
                        Spacer()
                        Button("Not now", action: onClose)
                    }
                    .zoText(.section)
                    .frame(minHeight: ZOSpace.hitTarget)
                    Text("Before you start")
                        .zoThemeText(.display)
                    if let product = store.selectedProduct {
                        MembershipPriceSummary(product: product, eligibility: store.eligibility)
                            .padding(ZOSpace.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .zoThemeCardSurface()
                        VStack(alignment: .leading, spacing: ZOSpace.l) {
                            MembershipFact(icon: "hand.raised", title: hasTrial ? "Nothing to pay today" : "Payment today",
                                           detail: hasTrial ? "Your free trial starts when you confirm with Apple." : localization.format("Apple charges %1$@ when you confirm.", .text(product.displayPrice)))
                            if hasTrial, let date = MembershipOfferCalendar.freeUntil(start: context.date, days: 14) {
                                MembershipFact(icon: "calendar", title: localization.format("Estimated payment starts %1$@", .text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)))),
                                               detail: localization.format("Apple charges %1$@ when the trial ends unless you cancel. Apple confirms the actual date.", .text(product.displayPrice)))
                            }
                            MembershipFact(icon: "arrow.triangle.2.circlepath", title: "Renews automatically",
                                           detail: localization.format("%1$@ %2$@ until you cancel.", .text(product.displayPrice), .text(product.membershipPeriodPhrase(localization))))
                            MembershipFact(icon: "xmark.circle", title: "Cancel in your Apple Account",
                                           detail: "Manage your subscription in Settings or the App Store. Cancellation stops the next renewal.")
                            MembershipFact(icon: "square.and.arrow.down", title: "Your training stays stored",
                                           detail: "Membership changes do not delete local workouts or history on this iPhone.")
                        }
                        .padding(ZOSpace.cardPadding)
                        .zoThemeCardSurface()
                    }
                    MembershipLegalLinks(configuration: store.configuration)
                    Button("Restore membership", action: onRestore)
                        .disabled(store.action != .idle)
                        .zoText(.section)
                        .frame(minHeight: ZOSpace.hitTarget)
                    if let message = store.message { MembershipNotice(text: message) }
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, ZOSpace.screenMargin)
                .padding(.top, ZOSpace.l)
                .padding(.bottom, ZOSpace.xxl)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                if let product = store.selectedProduct {
                    MembershipPrimaryButton(
                        title: hasTrial ? localization.string("Start 2 weeks free") : localization.format("Subscribe · %1$@", .text(product.displayPrice)),
                        subtitle: "Apple asks you to confirm next",
                        disabled: !store.canPurchase,
                        showsProgress: store.action != .idle
                    ) { Task { await store.purchase() } }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
        }
        .navigationBarBackButtonHidden()
    }
}

private struct MembershipFact: View {
    let icon: String
    let title: String
    let detail: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        HStack(alignment: .top, spacing: ZOSpace.m) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ZORadius.small))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZOSpace.xs) {
                Text(localization.string(title)).zoText(.section).foregroundStyle(theme.textPrimary)
                Text(localization.string(detail)).zoText(.body).foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private struct MembershipStatusScreen: View {
    let store: StoreKitMembershipStore
    let onClose: () -> Void
    let onRestore: () -> Void
    @State private var showingManage = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.xl) {
                Button("Close", action: onClose)
                    .zoText(.section)
                    .frame(minHeight: ZOSpace.hitTarget)
                Text("01 MEMBERSHIP")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
                if hasPaymentIssue {
                    HStack(alignment: .top, spacing: ZOSpace.m) {
                        Image(systemName: "exclamationmark.triangle")
                            .zoIcon(ZOIcon.row)
                            .foregroundStyle(theme.warningPrimary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: ZOSpace.xs) {
                            Text(localization.string(statusTitle)).zoText(.section)
                            Text(localization.string(statusDetail))
                                .zoText(.caption).foregroundStyle(theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, ZOSpace.l)
                    .padding(.vertical, ZOSpace.m)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius:
                        ZOThemeComponentShape(theme: theme.designTheme, role: .card).resolvedRadius,
                        style: .continuous))
                    .accessibilityElement(children: .combine)
                } else {
                    Text(localization.string(statusTitle))
                        .zoThemeText(.display)
                    Text(localization.string(statusDetail))
                        .zoText(.body)
                        .foregroundStyle(theme.textSecondary)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let days = MembershipTrialPresentation.daysLeft(access: store.access, now: context.date) {
                        MembershipNotice(text: days <= 1 ? localization.string("Temporary · last day")
                    : localization.format("Temporary · %1$lld days left", .integer(days)))
                    }
                }
                MembershipNotice(text: "Your local training data is not changed by membership or Restore.")
                if store.access.hasVerifiedAccess || store.access == .billingRetry || store.access == .revoked {
                    MembershipPrimaryButton(title: "Manage in App Store", subtitle: nil, disabled: false) {
                        showingManage = true
                    }
                }
                Button("Restore membership", action: onRestore)
                    .zoText(.section)
                    .frame(minHeight: ZOSpace.hitTarget)
                    .disabled(store.action != .idle)
                if let message = store.message { MembershipNotice(text: message) }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(ZOSpace.screenMargin)
        }
        .manageSubscriptionsSheet(isPresented: $showingManage)
    }

    private var hasPaymentIssue: Bool {
        switch store.access {
        case .gracePeriod, .billingRetry: true
        default: false
        }
    }

    private var statusTitle: String {
        switch store.access {
        case .trial: "Your trial is active."
        case .member: "Your membership is active."
        case .gracePeriod: "Your membership continues."
        case .billingRetry: "Apple is retrying a payment."
        case .revoked: "Membership was revoked."
        default: "Membership status"
        }
    }

    private var statusDetail: String {
        switch store.access {
        case .trial(let date): localization.format("Your trial currently ends %1$@. Manage it in your Apple Account.", .text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale))))
        case .member(let date): date.map { localization.format("Apple currently shows membership through %1$@.", .text($0.formatted(.dateTime.day().month(.abbreviated).year().locale(localization.locale)))) } ?? localization.string("Apple confirms your membership.")
        case .gracePeriod: "Apple reports a billing grace period. Check your payment method in your Apple Account."
        case .billingRetry: "Apple has not confirmed continued access. Check your payment method in your Apple Account."
        case .revoked: "Apple reports that this membership no longer provides access."
        default: "Check your membership with Apple."
        }
    }
}

private struct MembershipExpiredScreen: View {
    let store: StoreKitMembershipStore
    let onClose: () -> Void
    let onRestore: () -> Void
    let onExportTraining: (() -> Void)?
    let showOffer: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        MembershipEndedPresentationView(
            access: store.access,
            onAllPlans: showOffer,
            onRestore: onRestore,
            onClose: onClose,
            onExportTraining: onExportTraining,
            isBusy: store.action != .idle,
            message: store.message
        )
    }
}

private struct MembershipUnavailableScreen: View {
    let store: StoreKitMembershipStore
    let onClose: () -> Void

    var body: some View {
        MembershipMessageScreen(
            title: "Your training is safe.",
            detail: store.access == .unknown
                ? "Apple could not confirm membership right now. Try again when connected."
                : "Membership plans are unavailable right now. Try again when connected.",
            actionTitle: "Try again",
            action: { Task { await store.reload() } },
            secondaryTitle: "Close",
            secondaryAction: onClose
        )
    }
}

private struct MembershipMessageScreen: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var showsProgress = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZOSpace.l) {
                if showsProgress { ProgressView().tint(theme.textPrimary) }
                Text("01 MEMBERSHIP")
                    .zoText(.caption)

                    .foregroundStyle(theme.textSecondary)
                Text(localization.string(title))
                    .zoThemeText(.display)
                    .foregroundStyle(theme.textPrimary)
                Text(localization.string(detail))
                    .zoText(.body)
                    .foregroundStyle(theme.textSecondary)
                Button(localization.string(actionTitle), action: action)
                    .buttonStyle(ZOButtonStyle(.primary))
                if let secondaryTitle, let secondaryAction {
                    Button(localization.string(secondaryTitle), action: secondaryAction)
                        .buttonStyle(ZOButtonStyle(.quiet))
                }
            }
            .padding(ZOSpace.screenMargin)
        }
    }
}

private struct MembershipNotice: View {
    let text: String
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ZOBanner(message: localization.string(text), symbol: "info.circle")
    }
}

private struct MembershipLegalLinks: View {
    let configuration: MembershipConfiguration
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ZOSpace.xl) { links }
            VStack(alignment: .leading, spacing: ZOSpace.s) { links }
        }
        .zoText(.section)
        .foregroundStyle(theme.textPrimary)
        .frame(minHeight: ZOSpace.hitTarget)
    }

    @ViewBuilder private var links: some View {
        if let termsURL = configuration.termsURL { Link("Terms of Use", destination: termsURL) }
        if let privacyURL = configuration.privacyURL { Link("Privacy Policy", destination: privacyURL) }
    }
}

private struct MembershipPrimaryButton: View {
    let title: String
    let subtitle: String?
    let disabled: Bool
    var showsProgress = false
    let action: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2 * ZOStroke.hairline) {
                Text(localization.string(title))
                if let subtitle { Text(localization.string(subtitle)).zoText(.caption) }
            }
        }
        .buttonStyle(ZOButtonStyle(.primary, isLoading: showsProgress))
        .disabled(disabled || showsProgress)
        .padding(.horizontal, ZOSpace.screenMargin)
        .padding(.vertical, ZOSpace.m)
        .background(theme.backgroundPrimary)
    }
}

private extension Product {
    func membershipPeriodTitle(_ localization: AppLocalization) -> String {
        guard let period = subscription?.subscriptionPeriod else { return localization.string("Plan") }
        if period.unit == .month && period.value == 1 { return localization.string("Monthly") }
        if period.unit == .year && period.value == 1 { return localization.string("Yearly") }
        return displayName
    }

    func membershipPeriodPhrase(_ localization: AppLocalization) -> String {
        guard let period = subscription?.subscriptionPeriod else { return localization.string("per period") }
        if period.unit == .month && period.value == 1 { return localization.string("per month") }
        if period.unit == .year && period.value == 1 { return localization.string("per year") }
        let unit: String
        switch period.unit {
        case .day: unit = "days"
        case .week: unit = "weeks"
        case .month: unit = "months"
        case .year: unit = "years"
        @unknown default: return localization.string("per period")
        }
        return localization.format("per %1$lld %2$@", .integer(period.value), .text(localization.string(unit)))
    }
}
