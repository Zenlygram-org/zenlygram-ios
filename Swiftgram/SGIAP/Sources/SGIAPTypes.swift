import Foundation
import SGEntitlement

// MARK: - Products

/// Zenlygram — a subscription period, mirrored out of StoreKit.
///
/// Every StoreKit 2 type is iOS 15, and every one of them is `async` to reach. The paywall is not:
/// it is a synchronous SwiftUI view that has to render on iOS 13 too. So `SGIAP` mirrors what the
/// UI needs into plain value types, and the UI never imports StoreKit and never carries an
/// `@available` of its own.
public struct SGIAPPeriod: Equatable, Hashable {
    public enum Unit: String, Hashable, CaseIterable {
        case day
        case week
        case month
        case year
    }

    public let unit: Unit
    public let value: Int

    public init(unit: Unit, value: Int) {
        self.unit = unit
        self.value = value
    }

    /// The period in whole months — 1 for the monthly plan, 12 for the yearly one. `nil` when the
    /// period is not a whole number of months, which is why every per-month price is an Optional.
    public var months: Int? {
        switch self.unit {
        case .month:
            return self.value
        case .year:
            return self.value * 12
        case .day, .week:
            return nil
        }
    }
}

/// Zenlygram — Apple's introductory offer on a product (the 7 free days, §5.1).
///
/// Apple decides eligibility by Apple ID, per subscription group, and there is no API to decline an
/// offer at purchase time. `isEligibleForIntroOffer` on `SGIAPProduct` is Apple's answer, and it is
/// the only thing the trial COPY may be driven by (§5.6).
public struct SGIAPIntroductoryOffer: Equatable {
    public enum PaymentMode: String, Hashable, CaseIterable {
        case freeTrial
        case payAsYouGo
        case payUpFront
        /// A mode this build does not know. Rendered as a plain discount, never as a free trial.
        case unknown
    }

    public let paymentMode: PaymentMode
    /// Already formatted by StoreKit in the storefront's currency. Never build this from `price`.
    public let displayPrice: String
    public let period: SGIAPPeriod
    public let periodCount: Int

    public init(paymentMode: PaymentMode, displayPrice: String, period: SGIAPPeriod, periodCount: Int) {
        self.paymentMode = paymentMode
        self.displayPrice = displayPrice
        self.period = period
        self.periodCount = periodCount
    }

    public var isFreeTrial: Bool {
        return self.paymentMode == .freeTrial
    }
}

/// Zenlygram — one purchasable plan.
public struct SGIAPProduct: Equatable {
    public let id: String
    public let displayName: String
    public let productDescription: String
    /// StoreKit's own formatted price. **Never a hardcoded "$1.99"** — storefronts differ, and the
    /// App Store rejects a price that does not match the one it is about to charge.
    public let displayPrice: String
    public let price: Decimal
    public let period: SGIAPPeriod?
    /// The subscription group. Both plans share one, which is what makes monthly ↔ yearly an
    /// upgrade / downgrade rather than two unrelated subscriptions (§5.1).
    public let subscriptionGroupId: String?
    public let introductoryOffer: SGIAPIntroductoryOffer?
    /// Apple's answer for THIS Apple ID, resolved when the products were loaded. Drives the trial
    /// copy and nothing else.
    public let isEligibleForIntroOffer: Bool
    /// `price` divided by `period.months`, formatted in the product's own currency style. `nil` for
    /// a period that is not a whole number of months.
    public let displayPricePerMonth: String?

    public init(
        id: String,
        displayName: String,
        productDescription: String,
        displayPrice: String,
        price: Decimal,
        period: SGIAPPeriod?,
        subscriptionGroupId: String?,
        introductoryOffer: SGIAPIntroductoryOffer?,
        isEligibleForIntroOffer: Bool,
        displayPricePerMonth: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.displayPrice = displayPrice
        self.price = price
        self.period = period
        self.subscriptionGroupId = subscriptionGroupId
        self.introductoryOffer = introductoryOffer
        self.isEligibleForIntroOffer = isEligibleForIntroOffer
        self.displayPricePerMonth = displayPricePerMonth
    }

    public var isSubscription: Bool {
        return self.subscriptionGroupId != nil
    }
}

/// Where the product list currently stands. The paywall renders from this and never from a
/// "products is empty" guess: empty-because-loading and empty-because-the-App-Store-said-no are
/// different screens.
public enum SGIAPProductsState: Equatable {
    case idle
    case loading
    case loaded
    case failed(SGIAPMessage)
}

// MARK: - The current subscription

/// Zenlygram — what the App Store says about this Apple ID's subscription in our group.
///
/// Informational: the entitlement gate is `SGEntitlement`, never this. It exists so the paywall can
/// say "your plan renews on …" and can offer the OTHER plan as a switch rather than as a second
/// subscription.
public struct SGIAPSubscriptionStatus: Equatable {
    public enum State: String, Hashable, CaseIterable {
        case subscribed
        case expired
        case inBillingRetry
        case inGracePeriod
        case revoked
        case unknown
    }

    public let state: State
    public let productId: String?
    public let expirationDate: Date?
    public let willAutoRenew: Bool
    /// What renews NEXT. Different from `productId` means a plan change is already queued: a
    /// downgrade takes effect at renewal, while an upgrade is immediate and makes the two match
    /// again. See `queuedRenewalProductId`.
    public let renewalProductId: String?

    public init(state: State, productId: String?, expirationDate: Date?, willAutoRenew: Bool, renewalProductId: String?) {
        self.state = state
        self.productId = productId
        self.expirationDate = expirationDate
        self.willAutoRenew = willAutoRenew
        self.renewalProductId = renewalProductId
    }

    /// Apple still considers the subscription live. A billing-retry period is NOT live, but it is
    /// also not a lapse the app may act on: only the entitlement decides that.
    public var isActive: Bool {
        return self.state == .subscribed || self.state == .inGracePeriod
    }

    /// The plan already queued to replace `productId` at `expirationDate`, or nil when nothing is
    /// queued. Only while auto-renew is ON: with it off nothing renews at all, and Apple's lingering
    /// `autoRenewPreference` describes no change that will happen.
    public var queuedRenewalProductId: String? {
        guard self.willAutoRenew, let renewalProductId = self.renewalProductId, renewalProductId != self.productId else {
            return nil
        }
        return renewalProductId
    }
}

/// Zenlygram — what buying a given plan would MEAN right now, given what is already subscribed.
///
/// Both plans live in one subscription group (§5.1), which is the whole point: StoreKit performs the
/// switch itself, Apple prorates an upgrade immediately and defers a downgrade to the renewal date,
/// and there is no separate "change plan" API to call. This exists so the paywall can LABEL the
/// button correctly — offering "Subscribe" to someone who is already subscribed reads like a second
/// charge, and that is a refund request waiting to happen.
public enum SGIAPPlanChange: Equatable {
    /// Nothing of ours is active: a plain new subscription.
    case subscribe
    /// This is the plan that is active right now, and it renews as itself (or does not renew).
    case current
    /// This plan is active right now, but a different plan is already queued to replace it at the
    /// renewal date (`SGIAPSubscriptionStatus.queuedRenewalProductId`). Keeping it — undoing the
    /// queued change — is done on Apple's subscription page, not by buying it again.
    case currentUntilRenewal
    /// This plan is the one already queued to start at the renewal date. Nothing is charged until
    /// then; buying it again would change nothing, and undoing or changing it is Apple's
    /// subscription page.
    case scheduled
    /// A longer period than the active plan. Apple applies it immediately and refunds the prorated
    /// remainder of the current period.
    case upgrade
    /// A shorter period than the active plan. It takes effect at the next renewal; nothing is
    /// charged now and nothing is lost.
    case downgrade
}

// MARK: - Outcomes

/// Zenlygram — every way a purchase can end (§5.2, and the four StoreKit outcomes).
public enum SGIAPPurchaseResult: Equatable {
    /// Paid, StoreKit-verified, and the server has it. Pro is live.
    case purchased
    /// Paid and StoreKit-verified, but the server could not confirm it and no automatic retry will
    /// fix it: `apple_environment_mismatch`, `apple_subscription_conflict`, or `apple_jws_invalid`
    /// past its attempts. **Pro is already unlocked locally** from the StoreKit snapshot — this is
    /// not a failed purchase — and the transaction stays UNFINISHED. Show the support path.
    case purchasedNeedsHelp
    /// Ask to Buy, or an SCA challenge: the App Store will deliver the transaction later, through
    /// `Transaction.updates`. Tell the user it is waiting for approval; do not retry.
    case pending
    case cancelled
    case failed(SGIAPMessage)
}

/// Zenlygram — the outcome of Restore Purchases.
public enum SGIAPRestoreResult: Equatable {
    /// At least one of our products came back and was re-attached.
    case restored
    /// The Apple ID has no subscription of ours. Not an error: the most common cause is the wrong
    /// Apple ID, and the copy should say so without blaming the user.
    case nothingToRestore
    /// The user dismissed the App Store's password prompt. Say nothing.
    case cancelled
    case failed(SGIAPMessage)
}

/// Zenlygram — the outcome of OUR trial (`POST /v1/trial/start`), which is not Apple's intro offer.
public enum SGIAPTrialResult: Equatable {
    case started(endsAt: Date?)
    /// The server's ledger says no (§5.6). The message goes NEXT TO the purchase options — never a
    /// dead end.
    case refused(SGEntitlementMessage)
    /// The trial needs a bound device, i.e. a linked Telegram account. A purchase does not (§3.6).
    case notLinked
    case failed(SGIAPMessage)
}

/// Zenlygram — which free-trial affordance the paywall may show, and why not (§5.6).
///
/// Two ledgers, deliberately kept apart: Apple's (per Apple ID, per subscription group, answered by
/// `isEligibleForIntroOffer`) and ours (per Telegram account, answered by `/v1/trial/start`). The
/// app hides ITS OWN affordance when our ledger is consumed; it never tries to hide Apple's, which
/// it cannot control and must not misrepresent.
public struct SGIAPTrialAffordance: Equatable {
    /// Apple will show its own free days for at least one loaded product.
    public let isAppleIntroOfferAvailable: Bool
    /// Our own trial is still on the table as far as this device has been told.
    public let isServerTrialAvailable: Bool
    /// Why our trial is off, when the server has said so. Shown next to the purchase options.
    public let serverTrialRefusal: SGEntitlementMessage?

    public init(isAppleIntroOfferAvailable: Bool, isServerTrialAvailable: Bool, serverTrialRefusal: SGEntitlementMessage?) {
        self.isAppleIntroOfferAvailable = isAppleIntroOfferAvailable
        self.isServerTrialAvailable = isServerTrialAvailable
        self.serverTrialRefusal = serverTrialRefusal
    }
}

// MARK: - Messages

/// Zenlygram — every user-visible message the purchase flow can ask a surface to show.
///
/// Like `SGEntitlementMessage`, this names a key in `Swiftgram/SGStrings` (en + ru + uz) and renders
/// nothing itself. None of these strings may contain, or lead to, a purchase outside the App Store
/// (guideline 3.1.3(b)): no "also available on the web", no "cheaper on Telegram", and no support
/// link that leads to one.
public enum SGIAPMessage: Equatable, Hashable {
    /// `AppStore.canMakePayments` is false — parental controls, a managed device, a restricted
    /// account.
    case paymentsUnavailable
    /// This build runs on an OS older than StoreKit 2 requires. Existing Pro material keeps working;
    /// only buying does not.
    case requiresNewerOS
    /// `Product.products(for:)` came back empty or threw. Almost always the App Store, briefly.
    case productsUnavailable
    /// Ask to Buy / SCA: the transaction arrives later through `Transaction.updates`.
    case purchasePending
    /// Another App Store operation on this device — a purchase or a Restore, from this or another
    /// account's screen — has not returned yet. Nothing new was started and nothing was charged.
    case storeOperationInProgress
    case purchaseCompleted
    case restoreCompleted
    case nothingToRestore
    /// A transport failure on a user-initiated action. Never "unsubscribed".
    case noConnection
    /// Anything else that is nobody's fault and might work later.
    case temporarilyUnavailable
    /// The signed monetization policy is FREE: no new purchase, plan switch or trial is started.
    /// Nothing was sent to Apple or charged. Restore and existing subscriptions are unaffected.
    case subscriptionsNotOffered
    /// The fresh monetization policy a new purchase needs could not be fetched or verified (no
    /// connection, a wrong date and time, a server problem). Nothing was sent to Apple or charged.
    case purchaseCheckFailed
    /// Another policy check is in flight right now: try again in a moment. Nothing was charged.
    case purchaseCheckBusy
    /// Everything the entitlement module already has copy for — the attach refusals in particular.
    case entitlement(SGEntitlementMessage)

    public var localizationKey: String {
        switch self {
        case .paymentsUnavailable:
            return "IAP.Message.PaymentsUnavailable"
        case .requiresNewerOS:
            return "IAP.Message.RequiresNewerOS"
        case .productsUnavailable:
            return "IAP.Message.ProductsUnavailable"
        case .purchasePending:
            return "IAP.Message.PurchasePending"
        case .storeOperationInProgress:
            return "IAP.Message.StoreOperationInProgress"
        case .purchaseCompleted:
            return "IAP.Message.PurchaseCompleted"
        case .restoreCompleted:
            return "IAP.Message.RestoreCompleted"
        case .nothingToRestore:
            return "IAP.Message.NothingToRestore"
        case .noConnection:
            return SGEntitlementMessage.noConnection.localizationKey
        case .temporarilyUnavailable:
            return SGEntitlementMessage.temporarilyUnavailable.localizationKey
        case .subscriptionsNotOffered:
            return "IAP.Message.SubscriptionsNotOffered"
        case .purchaseCheckFailed:
            return "IAP.Message.PurchaseCheckFailed"
        case .purchaseCheckBusy:
            return "IAP.Message.PurchaseCheckBusy"
        case let .entitlement(message):
            return message.localizationKey
        }
    }
}
