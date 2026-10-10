import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreKitMembershipStore {
    private(set) var products: [Product] = []
    private(set) var access: MembershipAccess = .checking
    private(set) var eligibility: MembershipEligibility = .checking
    private(set) var action: MembershipActionState = .idle
    private(set) var isLoading = false
    private(set) var message: String?
    /// Proof 53: the verified trial end, renewal switch and renewal price. nil outside a trial.
    private(set) var trialRenewal: MembershipRecapRenewal?
    var selectedProductID: String?

    let configuration: MembershipConfiguration
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(configuration: MembershipConfiguration) {
        self.configuration = configuration
    }

    deinit { updatesTask?.cancel() }

    var selectedProduct: Product? {
        products.first(where: { $0.id == selectedProductID }) ?? products.first
    }

    /// Today also needs real week-one progress and its own per-week dismissal record.
    var canShowInvitation: Bool {
        !configuration.isBeta && !products.isEmpty && access == .none
            && eligibility != .checking && eligibility != .unavailable
    }

    var canPurchase: Bool {
        guard !configuration.isBeta, configuration.hasLegalLinks,
              selectedProduct != nil, action == .idle else { return false }
        guard access == .none || access == .expired else { return false }
        return eligibility != .checking && eligibility != .unavailable
    }

    func start() async {
        guard !configuration.isBeta else { return }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self, !Task.isCancelled else { break }
                    switch result {
                    case .verified(let transaction) where self.configuration.productIDs.contains(transaction.productID):
                        await transaction.finish()
                        await self.refreshAccess()
                        if self.action == .pending {
                            self.action = .idle
                            self.message = self.access.hasVerifiedAccess
                                ? "Apple confirmed your membership."
                                : "Apple updated the purchase, but membership is not active."
                        }
                    case .unverified(let transaction, _) where self.configuration.productIDs.contains(transaction.productID):
                        if self.action == .pending {
                            self.action = .idle
                            self.message = "Apple could not verify this purchase. No access was changed."
                        }
                        await self.refreshAccess()
                    default:
                        continue
                    }
                }
            }
        }
        await reload()
    }

    func reload() async {
        guard !configuration.isBeta, action == .idle else { return }
        guard !configuration.productIDs.isEmpty else {
            products = []
            eligibility = .unavailable
            access = .unknown
            message = "Membership is not available yet."
            return
        }

        isLoading = true
        eligibility = .checking
        message = nil
        await refreshAccess()
        do {
            let loaded = try await Product.products(for: configuration.productIDs)
            let groupID = configuration.subscriptionGroupID ?? loaded.first?.subscription?.subscriptionGroupID
            products = loaded.filter {
                $0.type == .autoRenewable && $0.subscription?.subscriptionGroupID == groupID
                    && configuration.productIDs.contains($0.id)
            }
                .sorted { lhs, rhs in
                    (configuration.productIDs.firstIndex(of: lhs.id) ?? .max)
                        < (configuration.productIDs.firstIndex(of: rhs.id) ?? .max)
                }
            if selectedProductID == nil || !products.contains(where: { $0.id == selectedProductID }) {
                selectedProductID = products.first?.id
            }
            if products.isEmpty {
                eligibility = .unavailable
                message = "Membership plans could not be loaded. Try again when connected."
            } else {
                await refreshEligibility()
                await refreshAccess()
            }
        } catch {
            products = []
            eligibility = .unavailable
            message = "Membership plans could not be loaded. Try again when connected."
        }
        isLoading = false
    }

    func select(_ productID: String) async {
        guard products.contains(where: { $0.id == productID }), selectedProductID != productID else { return }
        selectedProductID = productID
        await refreshEligibility()
    }

    func refreshEligibility() async {
        guard let product = selectedProduct, let subscription = product.subscription else {
            eligibility = .unavailable
            return
        }
        eligibility = .checking
        let eligible = await subscription.isEligibleForIntroOffer
        guard selectedProductID == product.id else { return }
        guard let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              offer.periodCount == 1,
              Self.twoWeekDays(offer.period) != nil else {
            eligibility = .unavailable
            message = "This membership plan is not configured with the approved two-week free trial."
            return
        }
        eligibility = eligible ? .eligible : .ineligible
    }

    func refreshAccess() async {
        trialRenewal = nil
        let ids = Set(configuration.productIDs)
        var entitlement: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ids.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantFuture) > .now else { continue }
            if entitlement == nil || transaction.purchaseDate > entitlement!.purchaseDate {
                entitlement = transaction
            }
        }

        let groupID = configuration.subscriptionGroupID ?? selectedProduct?.subscription?.subscriptionGroupID
        guard let groupID else {
            access = entitlement.map { .member(until: $0.expirationDate) } ?? .unknown
            return
        }
        do {
            let statuses = try await Product.SubscriptionInfo.status(for: groupID)
            let verified = statuses.compactMap { status -> (Product.SubscriptionInfo.RenewalState, Transaction)? in
                guard case .verified(let transaction) = status.transaction,
                      ids.contains(transaction.productID) else { return nil }
                return (status.state, transaction)
            }
            if let live = verified.first(where: {
                ($0.0 == .subscribed || $0.0 == .inGracePeriod) && $0.1.revocationDate == nil
            }) {
                if live.0 == .inGracePeriod {
                    access = .gracePeriod(until: live.1.expirationDate)
                } else if live.1.offerType == .introductory,
                          products.first(where: { $0.id == live.1.productID })?.subscription?.introductoryOffer?.paymentMode == .freeTrial,
                          let end = live.1.expirationDate {
                    access = .trial(until: end)
                    trialRenewal = Self.renewal(end: end, transaction: live.1, statuses: statuses, products: products)
                } else {
                    access = .member(until: live.1.expirationDate)
                }
            } else if let entitlement {
                access = .member(until: entitlement.expirationDate)
            } else if verified.contains(where: { $0.0 == .inBillingRetryPeriod }) {
                access = .billingRetry
            } else if verified.contains(where: { $0.0 == .revoked }) {
                access = .revoked
            } else if verified.contains(where: { $0.0 == .expired }) {
                access = .expired
            } else {
                access = .none
            }
        } catch {
            access = entitlement.map { .member(until: $0.expirationDate) } ?? .unknown
        }
    }

    func purchase() async {
        guard canPurchase, let product = selectedProduct else { return }
        action = .purchasing
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      configuration.productIDs.contains(transaction.productID),
                      transaction.revocationDate == nil,
                      (transaction.expirationDate ?? .distantFuture) > .now else {
                    message = "Apple could not verify this purchase. No access was changed."
                    break
                }
                access = .member(until: transaction.expirationDate)
                await transaction.finish()
                await refreshAccess()
                if !access.hasVerifiedAccess, transaction.revocationDate == nil,
                   (transaction.expirationDate ?? .distantFuture) > .now {
                    access = .member(until: transaction.expirationDate)
                }
                message = "Membership confirmed by Apple."
            case .pending:
                action = .pending
                message = "Waiting for Apple approval. Membership will update when Apple confirms it."
                return
            case .userCancelled:
                break
            @unknown default:
                message = "Apple returned an unknown purchase result. Check your membership before trying again."
            }
        } catch {
            message = "The purchase could not be completed. Please try again."
        }
        action = .idle
    }

    /// True only for this explicit sync followed by currently verified access.
    /// Callers must also retain their own presentation lifetime before showing success.
    @discardableResult
    func restore() async -> Bool {
        guard !configuration.isBeta, action == .idle else { return false }
        action = .restoring
        defer { action = .idle }
        message = nil
        do {
            try await AppStore.sync()
            await refreshAccess()
            if access.hasVerifiedAccess {
                message = "Apple confirmed your membership. Your training data was not changed."
                return !Task.isCancelled
            } else if access == .unknown || access == .checking {
                message = "Apple could not confirm membership right now. Your training data was not changed."
            } else {
                message = "No active membership was found. Your training data was not changed."
            }
        } catch {
            message = "Apple could not check purchases right now. Try again later."
        }
        return false
    }

    /// Only Apple's verified renewal info decides renews or cancelled; the price is
    /// the product the subscription renews into, never the currently selected offer.
    private static func renewal(end: Date, transaction: Transaction, statuses: [Product.SubscriptionInfo.Status],
                                products: [Product]) -> MembershipRecapRenewal {
        let info = statuses.lazy.compactMap { status -> Product.SubscriptionInfo.RenewalInfo? in
            guard case .verified(let current) = status.transaction, current.id == transaction.id,
                  case .verified(let info) = status.renewalInfo else { return nil }
            return info
        }.first
        let continuation: MembershipRecapRenewal.Continuation = info.map { $0.willAutoRenew ? .renews : .cancelled } ?? .unknown
        let product = products.first { $0.id == (info?.autoRenewPreference ?? transaction.productID) }
        var period: String?
        if let subscription = product?.subscription, subscription.subscriptionPeriod.value == 1 {
            switch subscription.subscriptionPeriod.unit {
            case .month: period = "a month"
            case .year: period = "a year"
            default: period = nil
            }
        }
        return MembershipRecapRenewal(trialEnds: end, continuation: continuation,
                                      verifiedPrice: product?.displayPrice, verifiedPeriod: period)
    }

    private static func twoWeekDays(_ period: Product.SubscriptionPeriod) -> Int? {
        if period.unit == .week && period.value == 2 { return 14 }
        if period.unit == .day && period.value == 14 { return 14 }
        return nil
    }
}
