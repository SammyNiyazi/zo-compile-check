import StoreKit
import SwiftUI

/// Pure outcome presentation. The caller owns official card provenance, offer
/// approval and current expired access. These inputs never grant access.
struct MembershipEndedPresentationView: View {
    let access: MembershipAccess
    var memberCard: ProfileSettingsYouSnapshot? = nil
    var monthlyProduct: Product? = nil
    var monthlyOfferEnabled = false
    var onMonthlyOffer: ((String) -> Void)? = nil
    let onAllPlans: () -> Void
    let onRestore: () -> Void
    let onClose: () -> Void
    var onExportTraining: (() -> Void)? = nil
    var isBusy = false
    var message: String? = nil
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.dynamicTypeSize) private var typeSize

    private var qualifiedMonthly: Product? {
        guard let product = monthlyProduct, product.type == .autoRenewable,
              let period = product.subscription?.subscriptionPeriod,
              period.unit == .month, period.value == 1 else { return nil }
        return product
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button("Close", action: onClose).buttonStyle(ZOButtonStyle(.quiet))
                if access == .expired {
                    if let memberCard, memberCard.card != nil {
                        ProfileSettingsYouCardView(snapshot: memberCard, playsArrival: false)
                            .opacity(0.55)
                        Text(localization.string("Your card is waiting.")).zoThemeText(.title)
                            .padding(.top, 14)
                    } else {
                        Text("Member card unavailable").zoText(.caption)
                            .foregroundStyle(theme.textSecondary)
                        Text("Your training is still here.").zoThemeText(.title).padding(.top, 14)
                    }
                    Text("Your membership has ended. Everything you logged remains stored on this iPhone.")
                        .zoText(.body).foregroundStyle(theme.textSecondary).padding(.top, 4)
                    if let product = qualifiedMonthly, let onMonthlyOffer {
                        Button {
                            onMonthlyOffer(product.id)
                        } label: {
                            Text(localization.format("Come back, %1$@ a month", .text(product.displayPrice)))
                        }
                        .buttonStyle(ZOButtonStyle(.primary))
                        .disabled(isBusy || !monthlyOfferEnabled).padding(.top, 14)
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: ZOSpace.s))
                            : AnyLayout(HStackLayout(spacing: ZOSpace.s))
                        layout { alternateActions }.padding(.top, 8)
                    } else {
                        Button("All plans", action: onAllPlans).buttonStyle(ZOButtonStyle(.primary))
                            .padding(.top, 14)
                        Button("Restore membership", action: onRestore)
                            .buttonStyle(ZOButtonStyle(.secondary, wide: true)).disabled(isBusy)
                            .padding(.top, 8)
                    }
                    if let onExportTraining {
                        Button("Export training", action: onExportTraining)
                            .buttonStyle(ZOButtonStyle(.quiet, wide: true)).padding(.top, 8)
                    }
                    if let message {
                        ZOBanner(message: localization.string(message), symbol: "info.circle").padding(.top, 12)
                    }
                } else {
                    Text("Check your membership with Apple.").zoText(.body)
                }
            }
            .foregroundStyle(theme.textPrimary).padding(ZOSpace.screenMargin)
        }
        .accessibilityAction(.escape, onClose)
    }

    @ViewBuilder private var alternateActions: some View {
        Button("All plans", action: onAllPlans)
            .buttonStyle(ZOButtonStyle(.secondary, wide: true))
        Button("Restore membership", action: onRestore)
            .buttonStyle(ZOButtonStyle(.secondary, wide: true)).disabled(isBusy)
    }
}

/// A pure caller-supplied display outcome, not transaction verification or access.
enum MembershipRestorePresentationOutcome {
    case verifiedActive(operationID: UUID)
    case noActive, unavailable, cancelled
}

/// Invoke only for an explicit, current verified Restore completion. The root
/// owns that event, route lifetime and celebration cutoff. Access alone is not
/// an instruction to present this screen. No lifetime entitlement is inferred.
struct MembershipRestoredPresentationView: View {
    let access: MembershipAccess
    let outcome: MembershipRestorePresentationOutcome
    let showCelebration: Bool
    let onContinue: () -> Void
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsVerifiedRestoration: Bool {
        guard case .verifiedActive = outcome else { return false }
        return access.hasVerifiedAccess
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showsVerifiedRestoration {
                    Image(systemName: "checkmark")
                        .zoIcon(28).foregroundStyle(theme.backgroundPrimary)
                        .frame(width: 56, height: 56)
                        .background(theme.successPrimary, in: Circle())
                        .accessibilityHidden(true)
                    Text("Apple confirmed your membership.").zoThemeText(.display).padding(.top, 14)
                    Text("Your local training data is not changed by membership or Restore.")
                        .zoText(.body).foregroundStyle(theme.textSecondary)
                } else {
                    Text("Check your membership with Apple.").zoText(.body)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            .padding(.horizontal, ZOSpace.screenMargin).padding(.top, 60)
        }
        .overlay(alignment: .top) {
            if showsVerifiedRestoration && showCelebration && !reduceMotion {
                MembershipRestoreConfetti().frame(height: 260)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onContinue).buttonStyle(ZOButtonStyle(.primary))
                .padding(.horizontal, ZOSpace.screenMargin).padding(.vertical, ZOSpace.m)
                .background(theme.backgroundPrimary)
        }
        .accessibilityAction(.escape, onContinue)
    }
}

/// proof.js restored -> motion.js zoConfettiStatic(W, 260, 30, 17).
/// Static decorative frame only; no timer, haptic, purchase or success authority.
private struct MembershipRestoreConfetti: View {
    @Environment(\.zeroOneTheme) private var theme
    var body: some View {
        Canvas { context, size in
            var seed = 17
            func random() -> Double {
                seed = (seed * 9301 + 49297) % 233280
                return Double(seed) / 233280
            }
            let colors = [theme.accentFill, theme.textPrimary, theme.accentFill,
                ZOColor.resolved(ZOColor.Data.protein, in: theme.colorScheme),
                ZOColor.resolved(ZOColor.Data.carbs, in: theme.colorScheme),
                ZOColor.resolved(ZOColor.Data.fat, in: theme.colorScheme), theme.textSecondary]
            for index in 0..<30 {
                let x = random() * Double(size.width), y = random() * 260 * 0.75
                let rotation = (random() * 360).rounded()
                let mark = index % 23 == 4
                let circle = index % 3 == 0
                let width: CGFloat = mark ? 10 : circle ? 7 : 6
                let height: CGFloat = mark ? 10 : circle ? 7 : 10
                var piece = context
                piece.translateBy(x: CGFloat(x) + width / 2, y: CGFloat(y) + height / 2)
                piece.rotate(by: .degrees(rotation))
                let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
                if mark {
                    var image = piece.resolve(Image("ZeroOneWordmark").renderingMode(.template))
                    image.shading = .color(theme.accentFill)
                    piece.draw(image, in: rect)
                } else {
                    piece.opacity = 0.55 + random() * 0.45
                    let path = circle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                    piece.fill(path, with: .color(colors[index % colors.count]))
                }
            }
        }.clipped()
    }
}
