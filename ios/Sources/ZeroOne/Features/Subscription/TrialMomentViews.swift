import StoreKit
import SwiftUI

/// Proof 53 "Two days before: the reminder". Sits on Today on day 13 and 14:
/// the person's own numbers, the exact charge date and price, and a plain way out.
struct TrialEndingCard: View {
    let window: TrialWindow
    let renewal: MembershipRecapRenewal?
    let progress: TrialProgress?
    let onGotIt: () -> Void

    @State private var showsManage = false
    @Environment(\.zeroOneTheme) private var theme
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.calendar) private var calendar

    private var badge: String {
        window.daysLeft(now: .now, calendar: calendar) >= 2
            ? localization.string("2 days left in your trial") : localization.string("Last day of your trial")
    }

    private var coachLine: String? {
        guard let progress, progress.workouts > 0 else { return nil }
        let daysIn = max(1, window.dayNumber(now: .now, calendar: calendar) - 1)
        let first = localization.format("%1$@ days in: %2$@.",
            .text(daysIn.formatted(.number.locale(localization.locale))), .text(progress.summary(localization)))
        return [first, progress.liftLine(localization)].compactMap { $0 }.joined(separator: " ")
    }

    private var chargeLine: String {
        let day = Date.FormatStyle.dateTime.day().month(.wide).locale(localization.locale)
        let end = window.end.formatted(day)
        let cancelBy = (MembershipOfferCalendar.lastFreeDay(paymentStarts: window.end, calendar: calendar) ?? window.end).formatted(day)
        switch renewal?.continuation ?? .unknown {
        case .cancelled:
            return localization.format("Renewal is off. Your trial ends %1$@.", .text(end))
        case .renews:
            if let renewal, renewal.hasVerifiedPriceAndPeriod, let price = renewal.verifiedPrice, let period = renewal.verifiedPeriod {
                return localization.format("On %1$@ your card becomes yours and Apple charges %2$@ %3$@. Not for you? Cancel by %4$@ and nothing is charged.",
                    .text(end), .text(price), .text(localization.string(period)), .text(cancelBy))
            }
            return localization.format("On %1$@ your card becomes yours. Not for you? Cancel by %2$@ and nothing is charged.",
                .text(end), .text(cancelBy))
        case .unknown:
            return localization.format("Your trial ends %1$@. Check renewal details in your Apple Account.", .text(end))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZOSpace.m) {
            HStack(spacing: ZOSpace.s) {
                ZOBadge(text: badge, isInk: true)
                Spacer(minLength: ZOSpace.s)
                Text(localization.format("Day %1$@ of %2$@",
                    .text(window.dayNumber(now: .now, calendar: calendar).formatted(.number.locale(localization.locale))),
                    .text(TrialWindow.days.formatted(.number.locale(localization.locale)))))
                    .zoText(.caption).foregroundStyle(theme.textSecondary)
            }
            if let coachLine {
                Text(verbatim: coachLine).zoText(.body)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: chargeLine).zoText(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZOSpace.s) {
                Button(localization.string("Manage subscription")) { showsManage = true }
                    .buttonStyle(ZOButtonStyle(.secondary, wide: true))
                Button(localization.string("Got it"), action: onGotIt)
                    .buttonStyle(ZOButtonStyle(.quiet))
                    .accessibilityIdentifier("today.trial.gotIt")
            }
        }
        .padding(ZOSpace.l)
        .zoThemeCardSurface()
        .overlay(ZORadius.cardShape.strokeBorder(theme.textPrimary, lineWidth: 1.5))
        .manageSubscriptionsSheet(isPresented: $showsManage)
        .accessibilityElement(children: .contain)
    }
}

/// "Your 14 days" with its own share sheet. The poster gets a fresh export
/// lifetime per presentation, revoked when the composer closes.
struct TrialRecapHost: View {
    let recap: MembershipTrialRecap?
    let renewal: MembershipRecapRenewal?
    let shareFacts: ZOShareRecapFacts?
    let onClose: () -> Void

    @State private var share: ShareRoute?
    @Environment(\.zeroOneLocalization) private var localization
    @Environment(\.zeroOneTheme) private var theme

    private struct ShareRoute: Identifiable {
        let id = UUID()
        let lifetime: ZOShareExportLifetime
        init() { lifetime = ZOShareExportLifetime(sourceVersion: id) }
    }

    var body: some View {
        MembershipTrialRecapView(recap: recap, renewal: renewal, onClose: onClose,
                                 onShare: shareFacts == nil ? nil : { share = ShareRoute() })
            .sheet(item: $share, onDismiss: { share?.lifetime.invalidate() }) { route in
                if let shareFacts {
                    ZOShareComposer(source: .first14Days(shareFacts), localization: localization,
                                    canExport: { route.lifetime.allows(route.id) },
                                    sourceVersion: route.id, exportLifetime: route.lifetime)
                        .onDisappear { route.lifetime.invalidate() }
                        .zeroOneTheme(theme)
                        .preferredColorScheme(theme.colorScheme)
                        .zoSheet(theme)
                }
            }
    }
}
