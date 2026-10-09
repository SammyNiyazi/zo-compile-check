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

    /// Release (TestFlight) stays unconfigured until the products exist in App
    /// Store Connect. A Debug run launched with ZERO_ONE_STOREKIT_TEST=1 (the
    /// ZeroOne scheme's Run action, with StoreKit/ZeroOne.storekit) uses Sammy's
    /// prices against Xcode's local StoreKit: no real charges (Sammy, 9 Oct).
    static var current: MembershipConfiguration {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERO_ONE_STOREKIT_TEST"] == "1" { return storeKitTest }
        #endif
        return .unconfigured
    }

    static let storeKitTest = MembershipConfiguration(
        productIDs: ["app.the01.membership.monthly", "app.the01.membership.yearly"],
        subscriptionGroupID: nil,
        termsURL: URL(string: "https://the01.app/terms"),
        privacyURL: URL(string: "https://the01.app/privacy"),
        isBeta: false
    )

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
