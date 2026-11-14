import Foundation

// MARK: Zenlygram — the status screen's decisions, Foundation only.
//
// Everything the "Zenlygram Pro" status screen DECIDES lives here, as plain values: which access
// line it shows, what (if anything) it may say about an App Store subscription, which actions it
// offers, and how a Restore it started may end. The SwiftUI file only reads `SGEntitlement` /
// `SGIAP` into `SGProStatusInputs` and renders the result, so these rules are exercised by
// `Tests/run-status-tests.sh` without the app, StoreKit, the Keychain or a network.
//
// Four facts shape every rule below:
//  - ACCESS is not PAYMENT. The entitlement is unlocked while the signed monetization policy is
//    free, during the paid-mode local grace, in a build that enforces nothing, and under a server
//    token's genuine `account_until` — `max(paid until, trial end)` or, for a VIP grant, a
//    synthetic future date. None of those proves a purchase. The only evidence of a PAID App Store
//    plan this screen has is StoreKit's own (`SGIAP.subscriptionStatus` and the entitlement's
//    StoreKit snapshot), so only that may produce the subscription line.
//  - While the policy is FREE nothing new is sold: no Subscribe, no plan switch, no trial, no
//    product query. Restore, linking and Apple's management page of an EXISTING subscription — one
//    StoreKit or a still-current legacy snapshot shows — stay; without that evidence the page is not
//    offered in either mode (plan lane L1 step 1, 2026-11-11).
//  - With the Apple backend ON, Pro is SHOWN to a non-holder only while the signed policy sells it
//    (`sgProSurfacesVisible`): in free mode every Pro entry point — the main Settings row, the
//    ZENLYGRAM PRO section, the `tg://pro` deep link, the deletion screen's billing paragraph — is
//    hidden for whoever holds nothing, and comes back when the operator flips the policy to paid,
//    without an app update. A holder keeps the status screen (Restore, Manage) in either mode.
//  - The PAYMENT part can be off while the BACKEND stays on (`SGEntitlement.isAppleBackendEnabled`
//    false: `sg_config.apple_backend_enabled` false and no product ids — a build that does not sell
//    through Apple, such as a simulator or development build without the product pair). Then `SGIAP`
//    runs no StoreKit work at all and no App Store subscription can exist for this app, so nothing
//    here may mention one: no Restore, no Manage Subscription, no plan line, no way into the
//    paywall's purchase options. Linking, the server-signed access (free, a horizon) and the
//    consent-required wording stay: they are the backend's, not Apple's.
//  - `SGEntitlement`'s decision describes the ACTIVE account. A screen built for another account
//    (an account switch while it is on screen) must neither render that decision as its own nor act.

/// `SGEntitlementPolicyMode`, mirrored so this file stays Foundation only. Public because the
/// Settings row and the deep link (`SharedAccountContext`) ask `sgProEntryDestination` with it.
public enum SGProMonetization: Equatable {
    case free
    case paid
}

/// The date the status screen may quote as the access horizon, or nil when it may not quote one.
///
/// The stored `until` belongs to the server TOKEN. It is only the truth while that token is what
/// grants and its horizon is still ahead. When the token has lapsed and the App Store subscription
/// (the StoreKit snapshot) or the local grace is what unlocks, the stored `until` is a past or
/// unrelated date, and quoting it would tell a paying user their access ended days ago.
func sgEntitlementStatusUntilDate(storedUntil: Date?, isGrantedByToken: Bool, now: Date) -> Date? {
    guard isGrantedByToken, let storedUntil, now < storedUntil else {
        return nil
    }
    return storedUntil
}

// MARK: - Inputs

/// `SGEntitlementSource`, mirrored so this file stays Foundation only.
enum SGProStatusAccessSource: Equatable {
    case none
    case token
    case storeKit
    case unconfigured
    case localGrace
    case freeAccess
}

/// `SGEntitlementDegradedReason`, folded to what the user can act on.
enum SGProStatusDegradation: Equatable {
    /// Never linked and nothing bought (`.noToken`).
    case noAccess
    /// The token verifies and says the subscription ended (`.lapsed`).
    case lapsed
    /// Offline past the token's grace, or a token this build cannot verify (`.stale`,
    /// `.unverifiable`, `.provisional`). Never "your subscription ended".
    case reconnect
}

/// What StoreKit's detailed status (`SGIAPSubscriptionStatus`) says, when it has been loaded.
enum SGProStatusAppleState: Equatable {
    /// Subscribed or in Apple's billing grace period: Apple considers it live.
    case live(expiration: Date?, willAutoRenew: Bool)
    /// Apple is retrying a failed renewal charge. Not live, but the user has a subscription to fix.
    case billingRetry
    /// Expired or revoked.
    case ended
    /// StoreKit answered with nothing it could classify.
    case unknown
}

struct SGProStatusInputs: Equatable {
    /// The screen's captured account is the account `SGEntitlement` currently decides for.
    var screenAccountIsActive: Bool
    var isUnlocked: Bool
    var source: SGProStatusAccessSource
    /// Only read while `isUnlocked` is false.
    var degradation: SGProStatusDegradation?
    var localGraceEndsAt: Date?
    /// The screen account's stored token `until`.
    var tokenUntil: Date?
    /// StoreKit's detailed status (`SGIAPManager.settledSubscriptionStatus`): nil until it has been
    /// loaded (needs products), while a newer query is replacing it, and after the newest query
    /// failed — then only the expiry-checked snapshot speaks, which never claims a renewal or billing.
    var appleState: SGProStatusAppleState?
    /// The entitlement's StoreKit snapshot (`Transaction.currentEntitlements`): nil when none was
    /// ever observed on this install. A persisted flag — only believed until `snapshotExpiration`.
    var snapshotHasActiveSubscription: Bool?
    /// The snapshot's latest transaction expiry; nil means none was reported.
    var snapshotExpiration: Date?
    var isLinked: Bool
    /// The signed monetization policy's mode, as `SGEntitlement` holds it right now.
    var monetization: SGProMonetization
    /// `SGEntitlement.isAppleBackendEnabled`: this build sells through the App Store (the
    /// `apple_backend_enabled` flag with product ids, on top of the authenticated backend). Held,
    /// `SGIAP` runs no StoreKit work — no listener, snapshot, product query, Restore or purchase —
    /// so no App Store subscription can exist for this app and the Apple rows (Restore, Manage
    /// Subscription, the plan line, the purchase entry) are not shown. Defaults to on because the
    /// test-only preview scenarios model a paid-capable build through the memberwise init; the live
    /// snapshot (`SGEntitlementStatusSnapshot.read`) always sets it.
    var isAppleBackendEnabled: Bool = true
    /// A StoreKit snapshot an earlier build left behind is still active with a finite expiry ahead
    /// (`SGEntitlement.manageableStoreKitSnapshot`'s legacy fallback) while this origin has none of its
    /// own. Display-only evidence that existing Apple billing may need managing — never a plan, a renewal
    /// or an access source.
    var hasManageableLegacySubscription: Bool = false
    var now: Date
}

// MARK: - Access

/// The one-line access status. Every case names ACCESS; none claims a payment.
enum SGProStatusAccess: Equatable {
    /// The screen's account is no longer the active one: nothing here may be shown or done for it.
    case otherAccount
    /// The local grace grants (paid mode only; never shown while free).
    case freeUntil(Date)
    /// Free for everyone right now: the monetization policy is free. Not a subscription, no date.
    case freeAccess
    /// A server token grants, with a future horizon. Paid, trial, VIP or dark rollout alike.
    case availableUntil(Date)
    /// Granted with no horizon this screen may quote.
    case available
    /// The App Store subscription (StoreKit snapshot) is what grants.
    case viaAppStore
    /// This build enforces nothing (`SGEntitlementEnforcement`): everything is open, nothing is sold.
    case unlockedBuild
    case lapsed
    case reconnect
    case notActive
}

func sgProStatusAccess(_ inputs: SGProStatusInputs) -> SGProStatusAccess {
    guard inputs.screenAccountIsActive else {
        return .otherAccount
    }
    guard inputs.isUnlocked else {
        switch inputs.degradation {
        case .lapsed:
            return .lapsed
        case .reconnect:
            return .reconnect
        case .noAccess, nil:
            return .notActive
        }
    }
    switch inputs.source {
    case .localGrace:
        if let endsAt = inputs.localGraceEndsAt, inputs.now < endsAt {
            return .freeUntil(endsAt)
        }
        return .available
    case .token:
        if let until = sgEntitlementStatusUntilDate(storedUntil: inputs.tokenUntil, isGrantedByToken: true, now: inputs.now) {
            return .availableUntil(until)
        }
        return .available
    case .storeKit:
        return .viaAppStore
    case .unconfigured:
        return .unlockedBuild
    case .freeAccess:
        return .freeAccess
    case .none:
        return .available
    }
}

// MARK: - The App Store plan

/// What StoreKit says about a PAID App Store subscription on this Apple ID. The only line on the
/// screen that may talk about a purchase.
enum SGProStatusPlan: Equatable {
    case renews(on: Date?)
    case ends(on: Date?)
    /// The snapshot proves a live subscription; the detailed status (renewal, date) is not loaded.
    case active
    case billingRetry
    /// StoreKit was asked and has nothing live for this Apple ID.
    case none

    /// A subscription exists that Apple's own management page can act on.
    var isManageable: Bool {
        switch self {
        case .renews, .ends, .active, .billingRetry:
            return true
        case .none:
            return false
        }
    }
}

/// nil when StoreKit has not answered: then the screen says nothing about a purchase, rather than
/// guess.
///
/// A FRESH detailed status is authoritative, ended included: an expired or revoked answer is never
/// overruled by the persisted snapshot flag, which can outlive the subscription (it is kept across
/// launches and through an empty re-read). Without a detailed answer the snapshot speaks only up to
/// its own transaction expiry on the effective clock — never through the evaluator's offline
/// renewal allowance, which keeps ACCESS going but proves no renewed purchase.
func sgProStatusPlan(appleState: SGProStatusAppleState?, snapshotHasActiveSubscription: Bool?, snapshotExpiration: Date?, now: Date) -> SGProStatusPlan? {
    switch appleState {
    case let .live(expiration, willAutoRenew):
        guard let expiration, now < expiration else {
            // Apple says live, but the date is behind the clock: do not quote a past date.
            return .active
        }
        return willAutoRenew ? .renews(on: expiration) : .ends(on: expiration)
    case .billingRetry:
        return .billingRetry
    case .ended:
        return SGProStatusPlan.none
    case .unknown, nil:
        break
    }
    guard let snapshotHasActiveSubscription else {
        return nil
    }
    guard snapshotHasActiveSubscription else {
        return SGProStatusPlan.none
    }
    if let snapshotExpiration, now >= snapshotExpiration {
        return nil
    }
    return .active
}

// MARK: - Restore

enum SGProStatusRestoreOutcome: Equatable {
    case restored
    case nothingToRestore
    case cancelled
    /// Another App Store purchase or Restore on this device has not returned yet.
    case anotherOperationInProgress
    /// Any other failure, with the `SGStrings` key the purchase flow chose for it.
    case failed(messageKey: String)
}

enum SGProStatusRestorePhase: Equatable {
    case idle
    case running
    case finished(SGProStatusRestoreOutcome)
}

/// One Restore at a time, owned by one screen account. A result that arrives after the screen's
/// account stopped being the active one, or after a newer attempt superseded it, changes nothing
/// on screen: the attach itself still completes for the captured account inside `SGIAP`.
struct SGProStatusRestoreFlow: Equatable {
    private(set) var phase: SGProStatusRestorePhase = .idle
    private var generation = 0

    var isRunning: Bool {
        return self.phase == .running
    }

    /// The attempt's token, or nil when Restore may not start now.
    mutating func begin(screenAccountIsActive: Bool, isAvailable: Bool) -> Int? {
        guard screenAccountIsActive, isAvailable, self.phase != .running else {
            return nil
        }
        self.generation += 1
        self.phase = .running
        return self.generation
    }

    /// Applies the attempt's result. Returns whether the screen should show (and announce) it.
    mutating func finish(_ outcome: SGProStatusRestoreOutcome, attempt: Int, screenAccountIsActive: Bool) -> Bool {
        guard attempt == self.generation, self.phase == .running else {
            return false
        }
        guard screenAccountIsActive else {
            self.phase = .idle
            return false
        }
        if outcome == .cancelled {
            self.phase = .idle
            return false
        }
        self.phase = .finished(outcome)
        return true
    }

    /// The screen's account stopped being the active one: drop what is shown and orphan the
    /// in-flight attempt, so its late result cannot surface under another account.
    mutating func invalidate() {
        self.generation += 1
        self.phase = .idle
    }
}

enum SGProStatusNoticeKind: Equatable {
    case success
    case info
    case pending
    case warning
}

/// The inline result line for a finished Restore; nil for "say nothing".
func sgProStatusRestoreNotice(_ phase: SGProStatusRestorePhase) -> (key: String, kind: SGProStatusNoticeKind)? {
    guard case let .finished(outcome) = phase else {
        return nil
    }
    switch outcome {
    case .restored:
        return ("IAP.Message.RestoreCompleted", .success)
    case .nothingToRestore:
        return ("IAP.Message.NothingToRestore", .info)
    case .anotherOperationInProgress:
        return ("IAP.Message.StoreOperationInProgress", .pending)
    case let .failed(messageKey):
        return (messageKey, .warning)
    case .cancelled:
        return nil
    }
}

// MARK: - The screen

/// Everything the status content renders, decided.
struct SGProStatusScreen: Equatable {
    var access: SGProStatusAccess
    var plan: SGProStatusPlan?
    var isLinked: Bool
    var restorePhase: SGProStatusRestorePhase
    /// An `SGIAPManager` exists to restore with.
    var isRestoreAvailable: Bool
    var monetization: SGProMonetization
    /// `SGProStatusInputs.isAppleBackendEnabled`: the build sells through Apple. Held, the screen
    /// shows no Apple row and says nothing about an App Store purchase.
    var isAppleBackendEnabled: Bool
    /// While free: the account's own genuine horizon (`account_until`), still ahead — a fact about
    /// the account (paid, trial or granted), shown as a secondary line under the free status. Never
    /// the access line and never a countdown; nil in paid mode, where the access line quotes it.
    var accountAccessUntil: Date?
    /// `SGProStatusInputs.hasManageableLegacySubscription`, kept only for the active account. Feeds Apple's
    /// management page alone — never `plan`, a plan switch or the existing-subscription notice.
    var hasManageableLegacySubscription: Bool

    init(inputs: SGProStatusInputs, restorePhase: SGProStatusRestorePhase, isRestoreAvailable: Bool) {
        self.access = sgProStatusAccess(inputs)
        self.monetization = inputs.monetization
        self.isAppleBackendEnabled = inputs.isAppleBackendEnabled
        // StoreKit facts are per Apple ID, but they are shown only on a screen that may act, and only
        // in a build that sells through Apple: with the Apple backend held nothing was ever sold or
        // queried, so a snapshot or status can only be stale evidence of a subscription that cannot
        // exist for this app.
        let showsAppleFacts = inputs.screenAccountIsActive && inputs.isAppleBackendEnabled
        self.plan = showsAppleFacts ? sgProStatusPlan(appleState: inputs.appleState, snapshotHasActiveSubscription: inputs.snapshotHasActiveSubscription, snapshotExpiration: inputs.snapshotExpiration, now: inputs.now) : nil
        self.isLinked = inputs.isLinked
        self.restorePhase = inputs.screenAccountIsActive ? restorePhase : .idle
        self.isRestoreAvailable = isRestoreAvailable
        self.hasManageableLegacySubscription = showsAppleFacts && inputs.hasManageableLegacySubscription
        if self.access == .freeAccess, let until = inputs.tokenUntil, inputs.now < until {
            self.accountAccessUntil = until
        } else {
            self.accountAccessUntil = nil
        }
    }

    /// Nothing is offered for an account that is no longer active.
    var showsActions: Bool {
        return self.access != .otherAccount
    }

    /// The entry into the paywall's PURCHASE options (Subscribe / View Plans): only while paid
    /// mode sells anything, and only in a build that sells through Apple. While free there is
    /// nothing new to buy, and a plan switch would be a new charge; with the Apple backend held
    /// there is no product behind the button, and the paywall must stay unreachable.
    var offersPurchaseEntry: Bool {
        return self.showsActions && self.isAppleBackendEnabled && self.monetization == .paid
    }

    /// The paywall entry reads "View Plans" (a switch) only when StoreKit shows a subscription;
    /// any unlocked access without one still reads "Subscribe".
    var offersPlansAsSwitch: Bool {
        return self.plan?.isManageable ?? false
    }

    /// Apple's management page, in a build that sells through Apple, on EVIDENCE of an existing
    /// subscription in either mode: StoreKit shows something it can manage (`offersPlansAsSwitch`:
    /// a plan, an Apple billing retry, the current snapshot), or a still-current subscription an
    /// earlier build recorded (`hasManageableLegacySubscription`). Free mode used to show the row to
    /// everyone, because no product is queried then and StoreKit's detailed status is unknown; since
    /// D1 (2026-11-11) a non-holder never reaches this screen while free, and whoever does holds Pro
    /// by the Settings row's own evidence — a server grant, VIP or trial holder with no StoreKit
    /// evidence has no App Store subscription to manage, so the row would only send them to Apple's
    /// page for nothing. With the Apple backend held: never — no App Store subscription can exist
    /// for this app.
    var showsManageSubscription: Bool {
        guard self.showsActions, self.isAppleBackendEnabled else {
            return false
        }
        return self.offersPlansAsSwitch || self.hasManageableLegacySubscription
    }

    /// The Restore row exists only in a build that sells through Apple: with the Apple backend held
    /// there is nothing a Restore could find, and `SGIAP` refuses to run one. (A missing
    /// `SGIAPManager` only disables the row — `isRestoreEnabled`.)
    var showsRestore: Bool {
        return self.showsActions && self.isAppleBackendEnabled
    }

    /// While free, what may be said about an EXISTING App Store subscription StoreKit shows: that
    /// it renews until cancelled only when Apple says it renews; otherwise only that Apple manages
    /// it. nil when nothing shows one, for another account, and in paid mode.
    var existingSubscriptionNotice: SGProStatusExistingSubscriptionNotice? {
        guard self.monetization == .free, self.showsActions, let plan = self.plan, plan != SGProStatusPlan.none else {
            return nil
        }
        if case .renews = plan {
            return .renewsUntilCancelled
        }
        return .managedByApple
    }

    var isRestoreEnabled: Bool {
        return self.showsRestore && self.isRestoreAvailable && self.restorePhase != .running
    }

    /// The local grace line explains the free window; shown while the grace is what grants.
    var graceEndsAt: Date? {
        if case let .freeUntil(date) = self.access {
            return date
        }
        return nil
    }
}

enum SGProStatusExistingSubscriptionNotice: Equatable {
    /// Apple reports auto-renew on: it keeps renewing until cancelled in Manage Subscription.
    case renewsUntilCancelled
    /// Auto-renew off, a billing retry, or only the persisted snapshot: Apple manages it — no
    /// claim about renewal.
    case managedByApple
}

// MARK: - The paywall's offer

/// What the PAYWALL may offer under the monetization mode. Free: a truthful free-access notice and
/// nothing to buy — no product query, no plan, no purchase, no trial of either kind. Paid: products
/// and purchases, and — only while the signed policy names one (`serverTrialDays`) — our own trial,
/// with exactly one trial affordance ever on screen. Linking is offered in both modes; Restore and
/// Apple's management page of an existing subscription too, but only in a build that sells through
/// Apple (`isAppleBackendEnabled`) — held, no App Store subscription can exist for this app.
struct SGPayWallOffer: Equatable {
    let monetization: SGProMonetization
    /// `SGEntitlement.isAppleBackendEnabled` (`SGProStatusInputs.isAppleBackendEnabled`).
    let isAppleBackendEnabled: Bool
    /// `SGEntitlement.serverTrialDays`: the signed policy's `trial_days` while it is paid and
    /// non-zero, nil otherwise — the ONLY thing that may put our trial button on screen, and the
    /// length that button names. Never an unverified token's value; always nil while free, under
    /// a v1 policy, and while the operator has not enabled the trial.
    let serverTrialDays: Int?

    init(monetization: SGProMonetization, isAppleBackendEnabled: Bool, serverTrialDays: Int?) {
        self.monetization = monetization
        self.isAppleBackendEnabled = isAppleBackendEnabled
        self.serverTrialDays = serverTrialDays
    }

    /// Ask StoreKit for products (and their subscription status) when the paywall opens.
    var loadsProducts: Bool {
        return self.monetization == .paid
    }

    /// Plan cards and the purchase button.
    var offersPurchase: Bool {
        return self.monetization == .paid
    }

    /// The "free for everyone right now" notice in place of the plans.
    var showsFreeAccess: Bool {
        return self.monetization == .free
    }

    /// OUR trial button ("Try N days free"): only while the signed policy OFFERS a trial
    /// (`serverTrialDays`), for a linked account our ledger has not seen refused or consumed
    /// (`isServerTrialAvailable`, `SGIAP.trialAffordance`), with no App Store subscription to trial
    /// beside, and never next to Apple's introductory offer — which is carried by the purchase
    /// button's own copy, so when Apple offers free days ours steps aside and exactly one trial
    /// affordance is ever on screen. Never while free, and never purchase admission: the length
    /// shown is the signed `trial_days`, the real end is `trial_ends_at` from `POST /v1/trial/start`.
    func showsServerTrial(hasAppStoreSubscription: Bool, isServerTrialAvailable: Bool, isAppleIntroOfferAvailable: Bool) -> Bool {
        return self.offersPurchase && self.serverTrialDays != nil && !hasAppStoreSubscription && isServerTrialAvailable && !isAppleIntroOfferAvailable
    }

    /// Whether a refusal of our trial the ledger remembers (`SGIAPTrialAffordance.serverTrialRefusal`:
    /// "already used", "paused") is shown next to the plans. It explains why OUR trial button is
    /// missing — so only while the signed policy offers a trial at all (`serverTrialDays`): with no
    /// trial on offer (free, a v1 policy, `trial_days` 0 after the operator disabled it) the button is
    /// absent for everyone and a refusal from an earlier period is stale noise, not an explanation.
    /// Beside Apple's own "Start Free Trial", an App Store subscription or an unlocked Pro there is
    /// nothing missing to explain either.
    func explainsServerTrialRefusal(hasAppStoreSubscription: Bool, isAppleIntroOfferAvailable: Bool, isUnlocked: Bool) -> Bool {
        return self.serverTrialDays != nil && !hasAppStoreSubscription && !isAppleIntroOfferAvailable && !isUnlocked
    }

    /// The Restore row: only in a build that sells through Apple. Held, `SGIAP` refuses to run a
    /// Restore and there is nothing one could find (`SGProStatusScreen.showsRestore`).
    var showsRestore: Bool {
        return self.isAppleBackendEnabled
    }

    /// Apple's management page, in a build that sells through Apple, on evidence in either mode: an
    /// existing subscription to manage or an Apple billing retry to fix (`SGProStatusScreen
    /// .showsManageSubscription`). Free mode no longer shows it to everyone: the paywall is not
    /// reachable for a non-holder while free (D1), and one left open across a flip to free must not
    /// send a user who bought nothing to Apple's subscriptions page. Held: never.
    func showsManageSubscription(hasAppStoreSubscription: Bool, isInBillingRetry: Bool) -> Bool {
        guard self.isAppleBackendEnabled else {
            return false
        }
        return hasAppStoreSubscription || isInBillingRetry
    }
}

// MARK: - Pro surfaces

/// Whether any Pro ENTRY POINT or Pro-branded chrome is shown right now: the main Settings row
/// "Zenlygram Pro", the ZENLYGRAM PRO section of Settings ▸ Zenlygram (header, Subscription row,
/// Restore, the sales blurb), the screen behind the `tg://pro` deep link, the account-deletion
/// billing paragraph, and the "…is part of Zenlygram Pro" sentence of the two retention toggles.
///
/// With the Apple backend ON the surfaces follow the signed monetization policy: while it is FREE
/// nothing is sold, so a non-holder gets no offer and no Pro branding at all; the operator's flip
/// to PAID brings every surface back on the next policy refresh, without an app update. Whoever
/// HOLDS Pro (`holdsPro` is `sgProSettingsRowOpensStatus`: a verified grant, an App Store
/// subscription StoreKit shows, Apple billing in retry) keeps the status screen in either mode —
/// Restore and Apple's management page must stay reachable for a subscriber after a flip back to
/// free (monetization-policy.json x-client-state.ui).
///
/// With the Apple backend HELD nothing is sold whatever the policy says and nothing changes at a
/// flip, so the surfaces keep their long-standing behaviour: shown, leading to the status screen
/// that says Pro is free (or what the account holds). The rule is about the SERVER flip, which only
/// an Apple-enabled build can act on.
public func sgProSurfacesVisible(isAppleBackendEnabled: Bool, monetization: SGProMonetization, holdsPro: Bool) -> Bool {
    guard isAppleBackendEnabled else {
        return true
    }
    return monetization == .paid || holdsPro
}

// MARK: - The Settings row "Zenlygram Pro"

/// Where the main Settings row "Zenlygram Pro" leads.
public enum SGProEntryDestination: Equatable {
    case status
    case payWall
    /// No Pro surface is shown right now (`sgProSurfacesVisible` false): the row does not exist,
    /// and a deep link to it opens nothing.
    case hidden
}

/// With the Apple backend held nothing is sold, so the paywall — "premium version", the plans, the
/// purchase button — is never the right screen: everyone gets the status screen, which says that
/// Pro is free (or what the account holds) and offers no purchase. With it on, whoever already HOLDS
/// Pro or is billed by Apple gets the status screen (`holdsPro` is `sgProSettingsRowOpensStatus`,
/// SGPayWallStatus.swift); everyone else gets the offer while the signed policy is PAID, and no row
/// at all while it is FREE (`.hidden`, `sgProSurfacesVisible`).
public func sgProEntryDestination(isAppleBackendEnabled: Bool, monetization: SGProMonetization, holdsPro: Bool) -> SGProEntryDestination {
    guard sgProSurfacesVisible(isAppleBackendEnabled: isAppleBackendEnabled, monetization: monetization, holdsPro: holdsPro) else {
        return .hidden
    }
    if !isAppleBackendEnabled || holdsPro {
        return .status
    }
    return .payWall
}
