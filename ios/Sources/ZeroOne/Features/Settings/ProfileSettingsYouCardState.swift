import Foundation

enum ProfileSettingsYouCardSide: Equatable { case front, back }

/// Projects observed access; it never turns a purchase into an issued member
/// number. Retained profile displayName and existing official card are separate.
struct ProfileSettingsYouCardState: Equatable {
    enum Status: Equatable {
        case unknown, trial(daysLeft: Int), member, paymentIssue, ended, revoked
    }
    let status: Status
    init(access: MembershipAccess, asOf: Date, calendar: Calendar) {
        guard asOf.timeIntervalSinceReferenceDate.isFinite else { status = .unknown; return }
        switch access {
        case let .trial(until):
            guard until.timeIntervalSinceReferenceDate.isFinite, until > asOf,
                  let days = MembershipTrialPresentation.daysLeft(access: access, now: asOf, calendar: calendar) else {
                status = .unknown; return
            }
            status = .trial(daysLeft: days)
        case let .member(until):
            guard until.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 > asOf }) ?? true else {
                status = .unknown; return
            }
            status = .member
        case .gracePeriod, .billingRetry: status = .paymentIssue
        case .expired: status = .ended
        case .revoked: status = .revoked
        case .none, .checking, .unknown: status = .unknown
        }
    }
    var isTrial: Bool { if case .trial = status { return true }; return false }
    var statusKey: String? {
        switch status {
        case .unknown: nil
        case .trial: "Trial active"
        case .member: "Membership active"
        case .paymentIssue: "Payment issue"
        case .ended: "Membership ended"
        case .revoked: "Membership revoked"
        }
    }
    func applyingEdition(_ edition: ProfileSettingsYouEdition,
                         to snapshot: ProfileSettingsYouSnapshot) -> ProfileSettingsYouSnapshot {
        .init(asOf: snapshot.asOf, displayName: snapshot.displayName, card: snapshot.card,
              month: snapshot.month, bodyWeight: snapshot.bodyWeight, edition: edition)
    }
}
