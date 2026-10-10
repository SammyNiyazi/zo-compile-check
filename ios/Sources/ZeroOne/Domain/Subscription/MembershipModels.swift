import Foundation

/// App Store identifiers and approved legal destinations are supplied by the app composition root.
/// An empty product list deliberately leaves purchasing unavailable.
struct MembershipConfiguration {
    let productIDs: [String]
    let subscriptionGroupID: String?
    let termsURL: URL?
    let privacyURL: URL?
    let isBeta: Bool

    static let unconfigured = MembershipConfiguration(
        productIDs: [],
        subscriptionGroupID: nil,
        termsURL: nil,
        privacyURL: nil,
        isBeta: true
    )

    /// Release uses the products in App Store Connect (group "01 Membership", created 10 Oct 2026).
    /// In TestFlight Apple's sandbox never charges and renews much faster than real time.
    /// A Debug run launched with ZERO_ONE_STOREKIT_TEST=1 (the ZeroOne scheme's Run action, with
    /// StoreKit/ZeroOne.storekit) uses the same IDs against Xcode's local StoreKit (Sammy, 9 Oct).
    static var current: MembershipConfiguration {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERO_ONE_STOREKIT_TEST"] == "1" { return storeKitTest }
        #endif
        return appStore
    }

    static let appStore = MembershipConfiguration(
        productIDs: ["app.the01.membership.monthly", "app.the01.membership.yearly", "app.the01.membership.lifetime"],
        subscriptionGroupID: nil,
        termsURL: URL(string: "https://the01.app/terms"),
        privacyURL: URL(string: "https://the01.app/privacy"),
        isBeta: false
    )

    static let storeKitTest = appStore

    /// Lifetime (Sammy 11 Oct): a one-time purchase beside the subscriptions; nothing renews.
    var lifetimeProductID: String? { productIDs.first { $0.hasSuffix(".lifetime") } }

    var hasLegalLinks: Bool {
        [termsURL, privacyURL].allSatisfy { $0?.scheme == "https" && $0?.host != nil }
    }
}

enum MembershipAccess: Equatable {
    case checking
    case none
    case trial(until: Date)
    case member(until: Date?)
    case gracePeriod(until: Date?)
    case billingRetry
    case expired
    case revoked
    case unknown

    var hasVerifiedAccess: Bool {
        switch self {
        case .trial, .member, .gracePeriod: true
        default: false
        }
    }
}

/// The next time Apple charges, from verified StoreKit data: the end of a free trial or a regular
/// renewal. Shown under Membership and used for the reminder 2 days before.
struct MembershipNextCharge: Equatable {
    let date: Date
    /// Apple's display price of the plan it renews into; nil when Apple hasn't confirmed it.
    let price: String?
    /// "a month" or "a year" (localization keys); nil for other periods.
    let period: String?
    let isTrial: Bool
    /// False once auto-renew is off: nothing will be charged.
    let renews: Bool
}

enum MembershipEligibility: Equatable {
    case checking
    case eligible
    case ineligible
    case unavailable
}

enum MembershipActionState: Equatable {
    case idle
    case purchasing
    case restoring
    case pending
}

/// Billing dates on an offer are estimates until Apple confirms a transaction.
enum MembershipOfferCalendar {
    static func freeUntil(start: Date, days: Int, calendar: Calendar = .current) -> Date? {
        guard days == 14 else { return nil }
        return calendar.date(byAdding: .day, value: days, to: start)
    }

    static func lastFreeDay(paymentStarts: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -1, to: paymentStarts)
    }
}
