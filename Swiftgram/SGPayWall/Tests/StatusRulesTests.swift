import Foundation

@main
struct StatusRulesTests {
    private static func check(_ condition: Bool, _ message: String = "Assertion failed", line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let future = now.addingTimeInterval(30 * 86400)
    private static let past = now.addingTimeInterval(-11 * 86400)

    private static func inputs(
        active: Bool = true,
        unlocked: Bool = true,
        source: SGProStatusAccessSource = .token,
        degradation: SGProStatusDegradation? = nil,
        grace: Date? = nil,
        tokenUntil: Date? = nil,
        apple: SGProStatusAppleState? = nil,
        snapshot: Bool? = nil,
        snapshotUntil: Date? = nil,
        linked: Bool = false,
        monetization: SGProMonetization = .paid,
        appleBackend: Bool = true,
        legacyManageable: Bool = false
    ) -> SGProStatusInputs {
        return SGProStatusInputs(
            screenAccountIsActive: active,
            isUnlocked: unlocked,
            source: source,
            degradation: degradation,
            localGraceEndsAt: grace,
            tokenUntil: tokenUntil,
            appleState: apple,
            snapshotHasActiveSubscription: snapshot,
            snapshotExpiration: snapshotUntil,
            isLinked: linked,
            monetization: monetization,
            isAppleBackendEnabled: appleBackend,
            hasManageableLegacySubscription: legacyManageable,
            now: now
        )
    }

    static func main() {
        untilDate()
        access()
        plan()
        screen()
        freeAccess()
        zeroDayGrace()
        legacyManage()
        manageSubscriptionOnEvidence()
        payWallOffer()
        paymentsOff()
        proSurfacesVisible()
        entryDestination()
        restoreFlow()
        restoreNotice()
        print("PASS: status access/plan/restore decisions")
    }

    private static func untilDate() {
        // A verified token grants and carries a future horizon: that date may be quoted.
        check(sgEntitlementStatusUntilDate(storedUntil: future, isGrantedByToken: true, now: now) == future)
        // The token has lapsed but StoreKit / the grace unlocks: "until <a past date>" is false.
        check(sgEntitlementStatusUntilDate(storedUntil: past, isGrantedByToken: false, now: now) == nil, "Showed a lapsed token's past date")
        // Not what grants: never quoted, even in the future.
        check(sgEntitlementStatusUntilDate(storedUntil: future, isGrantedByToken: false, now: now) == nil, "Quoted a horizon that is not what grants")
        check(sgEntitlementStatusUntilDate(storedUntil: now, isGrantedByToken: true, now: now) == nil)
        check(sgEntitlementStatusUntilDate(storedUntil: past, isGrantedByToken: true, now: now) == nil)
        check(sgEntitlementStatusUntilDate(storedUntil: nil, isGrantedByToken: true, now: now) == nil)
    }

    private static func access() {
        // Another account became active: SGEntitlement's decision is THAT account's. Whatever it
        // says — unlocked with a future token, or degraded — this screen shows neither.
        check(sgProStatusAccess(inputs(active: false, tokenUntil: future)) == .otherAccount, "Rendered another account's grant as this account's")
        check(sgProStatusAccess(inputs(active: false, unlocked: false, degradation: .lapsed)) == .otherAccount)

        // A server token horizon is ACCESS: trials, VIP grants and the dark rollout carry one too.
        check(sgProStatusAccess(inputs(source: .token, tokenUntil: future)) == .availableUntil(future))
        check(sgProStatusAccess(inputs(source: .token, tokenUntil: past)) == .available)
        check(sgProStatusAccess(inputs(source: .token, tokenUntil: nil)) == .available)

        // The grace window and its end; a grace that already ended quotes no date.
        check(sgProStatusAccess(inputs(source: .localGrace, grace: future)) == .freeUntil(future))
        check(sgProStatusAccess(inputs(source: .localGrace, grace: past)) == .available)
        // A future grace date is never quoted while something else grants.
        check(sgProStatusAccess(inputs(source: .token, grace: future, tokenUntil: future)) == .availableUntil(future))

        // StoreKit's snapshot grants; a stale token `until` is not quoted under it.
        check(sgProStatusAccess(inputs(source: .storeKit, tokenUntil: past)) == .viaAppStore)
        // An unconfigured build enforces nothing: open, but not "active".
        check(sgProStatusAccess(inputs(source: .unconfigured, tokenUntil: future)) == .unlockedBuild, "Unconfigured build shown as a horizon")

        // Degraded: a lapse, a reconnect (never "ended") and never-had-access stay distinct.
        check(sgProStatusAccess(inputs(unlocked: false, degradation: .lapsed)) == .lapsed)
        check(sgProStatusAccess(inputs(unlocked: false, degradation: .reconnect, tokenUntil: future)) == .reconnect, "Offline read as lapse or as access")
        check(sgProStatusAccess(inputs(unlocked: false, degradation: .noAccess)) == .notActive)
        check(sgProStatusAccess(inputs(unlocked: false, degradation: nil)) == .notActive)
    }

    private static func plan(_ apple: SGProStatusAppleState?, snapshot: Bool?, snapshotUntil: Date? = nil) -> SGProStatusPlan? {
        return sgProStatusPlan(appleState: apple, snapshotHasActiveSubscription: snapshot, snapshotExpiration: snapshotUntil, now: now)
    }

    private static func plan() {
        // Never asked StoreKit (or a query is replacing the answer): say nothing about a purchase.
        check(plan(nil, snapshot: nil) == nil)
        check(plan(.unknown, snapshot: nil) == nil)

        // A fresh live answer is authoritative, with its date only while it is ahead.
        check(plan(.live(expiration: future, willAutoRenew: true), snapshot: false) == .renews(on: future))
        check(plan(.live(expiration: future, willAutoRenew: false), snapshot: nil) == .ends(on: future))
        check(plan(.live(expiration: past, willAutoRenew: true), snapshot: true) == .active, "Quoted a renewal date that is already behind the clock")
        check(plan(.live(expiration: nil, willAutoRenew: true), snapshot: nil) == .active)
        check(plan(.billingRetry, snapshot: false) == .billingRetry)

        // A fresh ENDED / revoked answer wins over the persisted snapshot flag, which can outlive
        // the subscription — "active" from it would contradict Apple's own fresh answer.
        check(plan(.ended, snapshot: true, snapshotUntil: future) == SGProStatusPlan.none, "Stale snapshot overruled a fresh ended status")
        check(plan(.ended, snapshot: nil) == SGProStatusPlan.none)

        // A stale snapshot proves neither a renewed purchase nor an authoritative absence.
        check(plan(nil, snapshot: true, snapshotUntil: future) == .active)
        check(plan(nil, snapshot: true, snapshotUntil: nil) == .active)
        check(plan(nil, snapshot: true, snapshotUntil: past) == nil, "Expired snapshot invented an absent subscription")
        check(plan(nil, snapshot: true, snapshotUntil: now) == nil, "Snapshot was treated as authoritative at its exact expiry")
        check(plan(.unknown, snapshot: true, snapshotUntil: past) == nil)
        check(plan(.unknown, snapshot: false) == SGProStatusPlan.none)

        check(SGProStatusPlan.billingRetry.isManageable, "Billing retry needs Apple's page to fix the payment")
        check(!SGProStatusPlan.none.isManageable)

        // Access may survive in the renewal allowance without proving the current purchase state.
        let recentlyExpired = now.addingTimeInterval(-86400)
        let expired = SGProStatusScreen(inputs: inputs(source: .storeKit, snapshot: true, snapshotUntil: recentlyExpired), restorePhase: .idle, isRestoreAvailable: true)
        check(expired.plan == nil && !expired.offersPlansAsSwitch && !expired.showsManageSubscription)
    }

    private static func screen() {
        // A token horizon with no StoreKit evidence: "Subscribe", no Apple management page.
        let tokenOnly = SGProStatusScreen(inputs: inputs(source: .token, tokenUntil: future, snapshot: false), restorePhase: .idle, isRestoreAvailable: true)
        check(!tokenOnly.offersPlansAsSwitch, "Token horizon treated as a paid plan")
        check(!tokenOnly.showsManageSubscription)
        check(tokenOnly.plan == SGProStatusPlan.none)
        check(tokenOnly.showsActions && tokenOnly.isRestoreEnabled)

        // The grace is free access, not a plan.
        let grace = SGProStatusScreen(inputs: inputs(source: .localGrace, grace: future), restorePhase: .idle, isRestoreAvailable: true)
        check(grace.graceEndsAt == future && !grace.offersPlansAsSwitch)

        // StoreKit shows a subscription: plan switch + Apple's page.
        let paid = SGProStatusScreen(inputs: inputs(source: .storeKit, snapshot: true), restorePhase: .idle, isRestoreAvailable: true)
        check(paid.offersPlansAsSwitch && paid.showsManageSubscription)

        // Another account: no actions, no StoreKit line, no Restore result carried over.
        let other = SGProStatusScreen(inputs: inputs(active: false, source: .storeKit, snapshot: true), restorePhase: .finished(.restored), isRestoreAvailable: true)
        check(!other.showsActions && !other.showsManageSubscription && !other.isRestoreEnabled)
        check(other.plan == nil && other.restorePhase == .idle, "Another account's screen kept StoreKit / Restore state")

        // Restore busy or unavailable: the row is disabled, not hidden.
        let busy = SGProStatusScreen(inputs: inputs(), restorePhase: .running, isRestoreAvailable: true)
        check(busy.showsRestore && !busy.isRestoreEnabled)
        let noManager = SGProStatusScreen(inputs: inputs(), restorePhase: .idle, isRestoreAvailable: false)
        check(noManager.showsRestore && !noManager.isRestoreEnabled, "A missing manager must only disable the row")
        check(tokenOnly.showsRestore && paid.showsRestore && grace.showsRestore)
        check(!other.showsRestore, "Another account's screen offered Restore")
    }

    private static func zeroDayGrace() {
        // The signed policy's `local_grace_days` is 0: the local grace never grants, so under a paid
        // policy an install without a grant reads exactly as one whose grace has ended — the
        // entitlement is degraded (`.noToken`), its source is `.none` and `localGraceEndsAt` is nil
        // (`SGEntitlementStatusSnapshot.read`). No "free until" line anywhere.
        let zero = inputs(unlocked: false, source: .none, degradation: .noAccess, grace: nil, snapshot: false, monetization: .paid)
        check(sgProStatusAccess(zero) == .notActive, "A 0-day grace rendered as access")
        let screen = SGProStatusScreen(inputs: zero, restorePhase: .idle, isRestoreAvailable: true)
        check(screen.graceEndsAt == nil, "Showed 'free until' under a 0-day grace")
        check(screen.access == .notActive)
        check(screen.offersPurchaseEntry && !screen.offersPlansAsSwitch, "The offer is what an install without a grant meets")
        check(screen.showsRestore && screen.isRestoreEnabled && !screen.showsManageSubscription)
        check(screen.accountAccessUntil == nil && screen.existingSubscriptionNotice == nil)
        // Identical to the screen of an install whose seven days are over.
        let ended = inputs(unlocked: false, source: .none, degradation: .noAccess, grace: nil, snapshot: false, monetization: .paid)
        check(SGProStatusScreen(inputs: ended, restorePhase: .idle, isRestoreAvailable: true) == screen)

        // The date alone never makes the line: it needs an UNLOCKED decision whose source is the
        // grace. A policy adopted between the screen's two reads (the decision, then the date) can
        // leave them one step apart until the change notification re-reads both — neither
        // combination may print "free until".
        let staleDate = inputs(unlocked: false, source: .none, degradation: .noAccess, grace: future, monetization: .paid)
        check(sgProStatusAccess(staleDate) == .notActive, "A date without a granting grace rendered as 'free until'")
        check(SGProStatusScreen(inputs: staleDate, restorePhase: .idle, isRestoreAvailable: true).graceEndsAt == nil)
        let staleSource = inputs(unlocked: true, source: .localGrace, grace: nil, monetization: .paid)
        check(sgProStatusAccess(staleSource) == .available, "A grace source without a date invented one")
        check(SGProStatusScreen(inputs: staleSource, restorePhase: .idle, isRestoreAvailable: true).graceEndsAt == nil)

        // Whatever the length, the line quotes the date it is given: one day or thirty.
        for days in [1.0, 7.0, 30.0] {
            let end = now.addingTimeInterval(days * 86400)
            let running = SGProStatusScreen(inputs: inputs(source: .localGrace, grace: end), restorePhase: .idle, isRestoreAvailable: true)
            check(running.access == .freeUntil(end) && running.graceEndsAt == end)
        }
        // A real grant under a 0-day grace is unaffected: the token's own horizon, no grace line.
        let granted = SGProStatusScreen(inputs: inputs(source: .token, grace: nil, tokenUntil: future), restorePhase: .idle, isRestoreAvailable: true)
        check(granted.access == .availableUntil(future) && granted.graceEndsAt == nil)
    }

    private static func legacyManage() {
        // A pre-origin StoreKit snapshot with a finite future expiry (`SGEntitlement.manageableStoreKitSnapshot`'s
        // legacy fallback): existing Apple billing stays manageable, but it is never evidence of a current plan —
        // no "active", no plan switch, no renewal or "managed by Apple" claim. This origin's own snapshot is absent.
        let paid = SGProStatusScreen(inputs: inputs(unlocked: false, source: .none, degradation: .noAccess, apple: nil, snapshot: nil, legacyManageable: true), restorePhase: .idle, isRestoreAvailable: false)
        check(paid.plan == nil, "A legacy snapshot was shown as a plan")
        check(!paid.offersPlansAsSwitch, "A legacy snapshot offered a plan switch")
        check(paid.showsManageSubscription, "Existing Apple billing was not manageable")
        let free = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: nil, snapshot: nil, monetization: .free, legacyManageable: true), restorePhase: .idle, isRestoreAvailable: false)
        check(free.plan == nil && free.existingSubscriptionNotice == nil, "A legacy snapshot claimed an existing subscription")
        check(free.showsManageSubscription)
        // Without it, paid mode keeps the evidence rule.
        check(!SGProStatusScreen(inputs: inputs(unlocked: false, source: .none, degradation: .noAccess, apple: nil, snapshot: nil), restorePhase: .idle, isRestoreAvailable: false).showsManageSubscription)
        // Another account never acts on it.
        check(!SGProStatusScreen(inputs: inputs(active: false, unlocked: false, source: .none, apple: nil, snapshot: nil, legacyManageable: true), restorePhase: .idle, isRestoreAvailable: false).showsManageSubscription)
    }

    private static func freeAccess() {
        // Free for everyone: a truthful free line, never a countdown and never "available until".
        let free = inputs(source: .freeAccess, grace: future, tokenUntil: future, monetization: .free)
        check(sgProStatusAccess(free) == .freeAccess, "Free access rendered as a subscription or a grace")
        let screen = SGProStatusScreen(inputs: free, restorePhase: .idle, isRestoreAvailable: true)
        check(screen.graceEndsAt == nil, "Showed a 7-day countdown while free")
        check(!screen.offersPurchaseEntry, "Offered Subscribe while free")
        check(screen.showsActions && screen.isRestoreEnabled, "Restore must stay available while free")

        // An existing App Store subscription stays visible and manageable while free, but no plan
        // switch (a new charge) is offered.
        let subscriber = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: .live(expiration: future, willAutoRenew: true), snapshot: true, linked: true, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(subscriber.plan == .renews(on: future), "Hid an existing subscription while free")
        check(subscriber.showsManageSubscription, "Apple's management page must stay reachable while free")
        check(!subscriber.offersPurchaseEntry, "Offered a plan switch while free")
        check(subscriber.isLinked)
        let retrying = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: .billingRetry, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(retrying.showsManageSubscription, "A billing problem must stay fixable while free")
        // What free mode ACTUALLY sees for whoever still reaches this screen: no product query, so
        // StoreKit's detailed status is unknown. Without any evidence of an App Store subscription
        // Apple's page is NOT offered (L1 step 1): a holder by server grant, VIP or trial has nothing
        // there to manage, and a non-holder never reaches the screen while free (D1).
        let unknown = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: nil, snapshot: nil, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(!unknown.showsManageSubscription, "Offered Apple's page with no evidence of a subscription while free")
        check(unknown.existingSubscriptionNotice == nil, "Claimed a subscription nothing shows exists")
        // Paid mode keeps the evidence rule: no StoreKit evidence, no management page.
        check(!SGProStatusScreen(inputs: inputs(source: .token, tokenUntil: future, apple: nil, snapshot: nil), restorePhase: .idle, isRestoreAvailable: true).showsManageSubscription)

        // The renewal sentence only when Apple SAYS it renews; otherwise only who manages it.
        check(subscriber.existingSubscriptionNotice == .renewsUntilCancelled)
        let endsSoon = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: .live(expiration: future, willAutoRenew: false), snapshot: true, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(endsSoon.existingSubscriptionNotice == .managedByApple, "Claimed a renewal with auto-renew off")
        let snapshotOnly = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: nil, snapshot: true, snapshotUntil: future, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(snapshotOnly.existingSubscriptionNotice == .managedByApple, "Claimed a renewal StoreKit never confirmed")
        check(retrying.existingSubscriptionNotice == .managedByApple)
        check(SGProStatusScreen(inputs: inputs(source: .storeKit, apple: .live(expiration: future, willAutoRenew: true), snapshot: true), restorePhase: .idle, isRestoreAvailable: true).existingSubscriptionNotice == nil, "The free-mode notice leaked into paid mode")

        // The account's own genuine horizon is a fact worth keeping on screen while free — as a
        // secondary line, never as the access line and never as a countdown.
        let granted = SGProStatusScreen(inputs: inputs(source: .freeAccess, tokenUntil: future, linked: true, monetization: .free), restorePhase: .idle, isRestoreAvailable: true)
        check(granted.access == .freeAccess && granted.accountAccessUntil == future, "Hid the account's genuine horizon while free")
        check(granted.graceEndsAt == nil)
        check(SGProStatusScreen(inputs: inputs(source: .freeAccess, tokenUntil: past, monetization: .free), restorePhase: .idle, isRestoreAvailable: true).accountAccessUntil == nil, "Quoted a horizon that already passed")
        check(SGProStatusScreen(inputs: inputs(source: .freeAccess, tokenUntil: nil, monetization: .free), restorePhase: .idle, isRestoreAvailable: true).accountAccessUntil == nil)
        check(SGProStatusScreen(inputs: inputs(active: false, source: .freeAccess, tokenUntil: future, monetization: .free), restorePhase: .idle, isRestoreAvailable: true).accountAccessUntil == nil, "Showed another account's horizon")
        check(SGProStatusScreen(inputs: inputs(source: .token, tokenUntil: future), restorePhase: .idle, isRestoreAvailable: true).accountAccessUntil == nil, "In paid mode the access line itself quotes the horizon")

        // Another account's screen still shows nothing of this one, free or not.
        check(sgProStatusAccess(inputs(active: false, source: .freeAccess, monetization: .free)) == .otherAccount)

        // Paid: the purchase entry is back, and the existing rules are unchanged.
        check(SGProStatusScreen(inputs: inputs(source: .token, tokenUntil: future), restorePhase: .idle, isRestoreAvailable: true).offersPurchaseEntry)
        check(!SGProStatusScreen(inputs: inputs(active: false), restorePhase: .idle, isRestoreAvailable: true).offersPurchaseEntry)
    }

    private static func manageSubscriptionOnEvidence() {
        // Apple's management page follows evidence of an App Store subscription in BOTH modes (L1
        // step 1, 2026-11-11): StoreKit's plan, a current snapshot, a billing retry, a still-current
        // legacy snapshot — never free access, a server grant, a trial or the local grace by
        // themselves, which prove no purchase. (The "existing subscriptions only" caption of the
        // former always-while-free row went with the row.)
        let evidence = [
            inputs(source: .freeAccess, apple: .live(expiration: future, willAutoRenew: true), snapshot: true, monetization: .free),
            inputs(source: .freeAccess, apple: nil, snapshot: true, snapshotUntil: future, monetization: .free),
            inputs(source: .freeAccess, apple: .billingRetry, monetization: .free),
            inputs(source: .freeAccess, monetization: .free, legacyManageable: true),
            inputs(source: .storeKit, snapshot: true),
            inputs(source: .token, tokenUntil: future, legacyManageable: true)
        ]
        for (index, value) in evidence.enumerated() {
            check(SGProStatusScreen(inputs: value, restorePhase: .idle, isRestoreAvailable: true).showsManageSubscription, "Evidence case \(index) lost Apple's management page")
        }
        let none = [
            inputs(source: .freeAccess, apple: nil, snapshot: nil, monetization: .free),
            inputs(source: .freeAccess, apple: .ended, snapshot: false, monetization: .free),
            // A holder by server grant, VIP or trial: the status screen is theirs while free, Apple's page is not.
            inputs(source: .freeAccess, tokenUntil: future, linked: true, monetization: .free),
            inputs(source: .token, tokenUntil: future, apple: nil, snapshot: nil),
            inputs(source: .localGrace, grace: future)
        ]
        for (index, value) in none.enumerated() {
            check(!SGProStatusScreen(inputs: value, restorePhase: .idle, isRestoreAvailable: true).showsManageSubscription, "No-evidence case \(index) offered Apple's page")
        }
        // Another account: never, evidence or not.
        check(!SGProStatusScreen(inputs: inputs(active: false, source: .freeAccess, apple: .live(expiration: future, willAutoRenew: true), snapshot: true, monetization: .free), restorePhase: .idle, isRestoreAvailable: true).showsManageSubscription)
        // The paywall's row follows the same rule in both modes.
        for monetization in [SGProMonetization.free, .paid] {
            let offer = SGPayWallOffer(monetization: monetization, isAppleBackendEnabled: true, serverTrialDays: nil)
            check(offer.showsManageSubscription(hasAppStoreSubscription: true, isInBillingRetry: false), "Hid Apple's page from an existing subscriber (\(monetization))")
            check(offer.showsManageSubscription(hasAppStoreSubscription: false, isInBillingRetry: true), "A billing problem must stay fixable (\(monetization))")
            check(!offer.showsManageSubscription(hasAppStoreSubscription: false, isInBillingRetry: false), "Offered Apple's page with no evidence (\(monetization))")
        }
    }

    private static func payWallOffer() {
        // Free: no StoreKit product query, no plan, no purchase, no trial of either kind — not even
        // with signed days (the server folds them to 0 while free; a screen that still holds a
        // number must not trust it).
        let free = SGPayWallOffer(monetization: .free, isAppleBackendEnabled: true, serverTrialDays: 7)
        check(free.showsRestore, "Restore lost while free in a build that sells through Apple")
        check(!free.loadsProducts, "Queried App Store products while free")
        check(!free.offersPurchase, "Offered a purchase while free")
        check(free.showsFreeAccess)
        check(!free.showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false), "Offered our trial while free")
        check(!SGPayWallOffer(monetization: .free, isAppleBackendEnabled: true, serverTrialDays: nil).showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false))
        check(free.showsManageSubscription(hasAppStoreSubscription: true, isInBillingRetry: false), "Hid Apple's management page from an existing subscriber while free")
        check(free.showsManageSubscription(hasAppStoreSubscription: false, isInBillingRetry: true))
        check(!free.showsManageSubscription(hasAppStoreSubscription: false, isInBillingRetry: false), "Offered Apple's page with no evidence of a subscription while free")

        // Paid, the signed policy offering 7 days: products and purchases; our trial under the
        // existing conditions, exactly one trial affordance.
        let paid = SGPayWallOffer(monetization: .paid, isAppleBackendEnabled: true, serverTrialDays: 7)
        check(paid.showsRestore)
        check(paid.loadsProducts && paid.offersPurchase && !paid.showsFreeAccess)
        check(paid.serverTrialDays == 7, "The shown length is the signed trial_days")
        check(paid.showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false))
        check(!paid.showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: true), "Two identically-labelled trial buttons")
        check(!paid.showsServerTrial(hasAppStoreSubscription: true, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false), "Offered a trial beside an App Store subscription")
        check(!paid.showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: false, isAppleIntroOfferAvailable: false), "Offered a trial our ledger says was refused, consumed or needs a link")
        check(paid.showsManageSubscription(hasAppStoreSubscription: true, isInBillingRetry: false))
        check(!paid.showsManageSubscription(hasAppStoreSubscription: false, isInBillingRetry: false))

        // Paid with no signed trial (a v1 policy, trial_days 0, the operator's choice): never our
        // button, whatever the ledger says — and nothing else about the offer changes.
        let paidNoTrial = SGPayWallOffer(monetization: .paid, isAppleBackendEnabled: true, serverTrialDays: nil)
        check(!paidNoTrial.showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false), "Offered a trial the signed policy does not")
        check(paidNoTrial.loadsProducts && paidNoTrial.offersPurchase && !paidNoTrial.showsFreeAccess, "The trial changed what is sold")
        check(paidNoTrial.showsRestore && paidNoTrial.showsManageSubscription(hasAppStoreSubscription: true, isInBillingRetry: false))
        check(paid.loadsProducts == paidNoTrial.loadsProducts && paid.offersPurchase == paidNoTrial.offersPurchase, "Products and purchases must not depend on the trial")

        // The contract's bounds are shown as signed.
        for days in [1, 30] {
            check(SGPayWallOffer(monetization: .paid, isAppleBackendEnabled: true, serverTrialDays: days).showsServerTrial(hasAppStoreSubscription: false, isServerTrialAvailable: true, isAppleIntroOfferAvailable: false), "A \(days)-day trial was not offered")
        }

        // A refusal the ledger remembers ("already used", "paused") explains a trial button the signed
        // policy would otherwise show — never one it does not offer: after the operator disables the
        // trial (or under a v1 policy) the button is absent for everyone, and the refusal is stale noise.
        check(paid.explainsServerTrialRefusal(hasAppStoreSubscription: false, isAppleIntroOfferAvailable: false, isUnlocked: false))
        check(!paidNoTrial.explainsServerTrialRefusal(hasAppStoreSubscription: false, isAppleIntroOfferAvailable: false, isUnlocked: false), "Explained a refusal of a trial nobody is offered")
        check(!free.explainsServerTrialRefusal(hasAppStoreSubscription: false, isAppleIntroOfferAvailable: false, isUnlocked: true), "Explained a refusal while free (unlocked)")
        check(!paid.explainsServerTrialRefusal(hasAppStoreSubscription: true, isAppleIntroOfferAvailable: false, isUnlocked: true), "Explained a refusal beside an App Store subscription")
        check(!paid.explainsServerTrialRefusal(hasAppStoreSubscription: false, isAppleIntroOfferAvailable: true, isUnlocked: false), "Explained a refusal next to Apple's own trial button")
        check(!paid.explainsServerTrialRefusal(hasAppStoreSubscription: false, isAppleIntroOfferAvailable: false, isUnlocked: true), "Explained a refusal while Pro is unlocked")
    }

    /// Payments off, backend on (`apple_backend_enabled` false, no product ids — a build without the
    /// product pair): the server-signed FREE policy grants, and nothing on screen mentions Apple.
    private static func paymentsOff() {
        // What the release actually shows: free for everyone, the Link row's account facts, and
        // no Apple row — no Restore (not even disabled), no Manage Subscription, no purchase entry.
        let release = SGProStatusScreen(inputs: inputs(source: .freeAccess, grace: future, tokenUntil: future, linked: true, monetization: .free, appleBackend: false), restorePhase: .idle, isRestoreAvailable: true)
        check(release.access == .freeAccess, "Payments off changed the access line")
        check(release.showsActions, "Payments off hid the Link row")
        check(release.isLinked && release.accountAccessUntil == future, "Payments off hid the backend's account facts")
        check(release.graceEndsAt == nil && !release.offersPurchaseEntry, "Offered a purchase with nothing to sell")
        check(!release.showsRestore, "Rendered a Restore row with the Apple backend held")
        check(!release.isRestoreEnabled, "Enabled Restore with the Apple backend held")
        check(!release.showsManageSubscription, "Offered Apple's subscriptions page for an app that sells nothing there")
        check(release.plan == nil && release.existingSubscriptionNotice == nil)

        // Stale StoreKit evidence (a snapshot or status an Apple-enabled build left) proves nothing
        // this build can sell, restore or manage: still no plan line, no Apple row.
        let stale = SGProStatusScreen(inputs: inputs(source: .freeAccess, apple: .live(expiration: future, willAutoRenew: true), snapshot: true, snapshotUntil: future, monetization: .free, appleBackend: false, legacyManageable: true), restorePhase: .idle, isRestoreAvailable: true)
        check(stale.plan == nil, "A plan line with the Apple backend held")
        check(stale.existingSubscriptionNotice == nil, "Claimed an existing subscription with the Apple backend held")
        check(!stale.offersPlansAsSwitch && !stale.showsManageSubscription && !stale.showsRestore)
        check(!stale.hasManageableLegacySubscription, "A legacy snapshot survived the held Apple backend")

        // A PAID server policy while the Apple backend is held is an operator misconfiguration: the
        // build preflight sees only `sg_config` (it refuses a mixed flag / product-id pair), so the
        // signed policy must stay FREE while a payments-off build ships. If it ever happens, the
        // screen still sells nothing and sends nobody to Apple.
        let paidHeld = SGProStatusScreen(inputs: inputs(source: .token, tokenUntil: future, apple: .billingRetry, snapshot: true, appleBackend: false), restorePhase: .idle, isRestoreAvailable: true)
        check(!paidHeld.offersPurchaseEntry, "Subscribe shown with no product behind it")
        check(!paidHeld.showsRestore && !paidHeld.showsManageSubscription && paidHeld.plan == nil)
        check(paidHeld.access == .availableUntil(future), "Payments off changed a token's access line")
        check(!SGProStatusScreen(inputs: inputs(unlocked: false, degradation: .noAccess, appleBackend: false), restorePhase: .idle, isRestoreAvailable: true).showsRestore)

        // The same build with the Apple backend on keeps Restore (the paid-build rules above); Apple's
        // page still waits for evidence of a subscription.
        let on = SGProStatusScreen(inputs: inputs(source: .freeAccess, monetization: .free, appleBackend: true), restorePhase: .idle, isRestoreAvailable: true)
        check(on.showsRestore && on.isRestoreEnabled && !on.showsManageSubscription)

        // Another account: nothing, whatever the Apple switch says.
        let other = SGProStatusScreen(inputs: inputs(active: false, source: .freeAccess, monetization: .free, appleBackend: false), restorePhase: .idle, isRestoreAvailable: true)
        check(!other.showsActions && !other.showsRestore && !other.showsManageSubscription)

        // The paywall's offer under the same switch: Restore and Manage Subscription gone in both
        // modes, whatever StoreKit evidence the view thinks it has; the free notice stays.
        let freeHeld = SGPayWallOffer(monetization: .free, isAppleBackendEnabled: false, serverTrialDays: nil)
        check(!freeHeld.showsRestore, "The paywall rendered Restore with the Apple backend held")
        check(freeHeld.showsFreeAccess && !freeHeld.loadsProducts && !freeHeld.offersPurchase)
        for (subscription, retry) in [(false, false), (true, false), (false, true), (true, true)] {
            check(!freeHeld.showsManageSubscription(hasAppStoreSubscription: subscription, isInBillingRetry: retry), "The paywall offered Apple's page with the Apple backend held")
            check(!SGPayWallOffer(monetization: .paid, isAppleBackendEnabled: false, serverTrialDays: nil).showsManageSubscription(hasAppStoreSubscription: subscription, isInBillingRetry: retry))
        }
        check(!SGPayWallOffer(monetization: .paid, isAppleBackendEnabled: false, serverTrialDays: nil).showsRestore)
    }

    /// Pro surfaces (the Settings row, the ZENLYGRAM PRO section, the deep link, the deletion
    /// screen's billing paragraph) follow the signed policy only in a build that sells through
    /// Apple: backend × mode × holder, all eight.
    private static func proSurfacesVisible() {
        // Apple backend on: a non-holder sees Pro only while the policy sells it.
        check(!sgProSurfacesVisible(isAppleBackendEnabled: true, monetization: .free, holdsPro: false), "Pro shown to a non-holder while free")
        check(sgProSurfacesVisible(isAppleBackendEnabled: true, monetization: .paid, holdsPro: false), "The offer lost while paid")
        // A holder keeps the status screen (Restore, Manage Subscription) in either mode.
        check(sgProSurfacesVisible(isAppleBackendEnabled: true, monetization: .free, holdsPro: true), "A subscriber lost Restore / Manage at a flip back to free")
        check(sgProSurfacesVisible(isAppleBackendEnabled: true, monetization: .paid, holdsPro: true))
        // Apple backend held: nothing is sold and nothing changes at a flip — the long-standing
        // screens stay (the status screen says Pro is free).
        for monetization in [SGProMonetization.free, .paid] {
            for holdsPro in [false, true] {
                check(sgProSurfacesVisible(isAppleBackendEnabled: false, monetization: monetization, holdsPro: holdsPro), "A payments-off build hid the status screen (\(monetization), holder \(holdsPro))")
            }
        }
    }

    /// The main Settings row "Zenlygram Pro": the status screen for everyone while the Apple backend
    /// is held; with it on, the status screen for a holder, the paywall for a non-holder while the
    /// policy is paid, and no row at all for a non-holder while it is free.
    private static func entryDestination() {
        // Held: the status screen, whatever the policy says.
        for monetization in [SGProMonetization.free, .paid] {
            check(sgProEntryDestination(isAppleBackendEnabled: false, monetization: monetization, holdsPro: false) == .status, "Payments off opened the paywall or hid the row (\(monetization))")
            check(sgProEntryDestination(isAppleBackendEnabled: false, monetization: monetization, holdsPro: true) == .status)
        }
        // On: a holder gets the status screen in either mode, never a second subscription.
        check(sgProEntryDestination(isAppleBackendEnabled: true, monetization: .paid, holdsPro: true) == .status, "A holder was offered a second subscription")
        check(sgProEntryDestination(isAppleBackendEnabled: true, monetization: .free, holdsPro: true) == .status, "A holder lost the status screen while free")
        // On: a non-holder gets the offer while paid and nothing while free.
        check(sgProEntryDestination(isAppleBackendEnabled: true, monetization: .paid, holdsPro: false) == .payWall, "A non-holder in a paid-capable build lost the offer")
        check(sgProEntryDestination(isAppleBackendEnabled: true, monetization: .free, holdsPro: false) == .hidden, "A non-holder was shown Pro while free")
        // The row and the surfaces rule agree: the row is hidden exactly when nothing Pro is shown.
        for backend in [false, true] {
            for monetization in [SGProMonetization.free, .paid] {
                for holdsPro in [false, true] {
                    let hidden = sgProEntryDestination(isAppleBackendEnabled: backend, monetization: monetization, holdsPro: holdsPro) == .hidden
                    check(hidden == !sgProSurfacesVisible(isAppleBackendEnabled: backend, monetization: monetization, holdsPro: holdsPro), "Row and surfaces disagree (backend \(backend), \(monetization), holder \(holdsPro))")
                }
            }
        }
    }

    private static func restoreFlow() {
        var flow = SGProStatusRestoreFlow()
        // Not for another account, not without a manager.
        check(flow.begin(screenAccountIsActive: false, isAvailable: true) == nil)
        check(flow.begin(screenAccountIsActive: true, isAvailable: false) == nil)
        check(flow.phase == .idle)

        // One at a time: a second tap while running is refused.
        guard let first = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
            preconditionFailure("Restore did not start")
        }
        check(flow.isRunning)
        check(flow.begin(screenAccountIsActive: true, isAvailable: true) == nil, "Two Restores at once")

        // Success / nothing found / another operation / a failure are shown.
        check(flow.finish(.restored, attempt: first, screenAccountIsActive: true))
        check(flow.phase == .finished(.restored))
        // A late duplicate of the same attempt changes nothing.
        check(!flow.finish(.nothingToRestore, attempt: first, screenAccountIsActive: true))
        check(flow.phase == .finished(.restored))

        for outcome in [SGProStatusRestoreOutcome.nothingToRestore, .anotherOperationInProgress, .failed(messageKey: "Entitlement.Message.NoConnection")] {
            guard let attempt = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
                preconditionFailure("Restore did not restart after a result")
            }
            check(flow.finish(outcome, attempt: attempt, screenAccountIsActive: true))
            check(flow.phase == .finished(outcome))
        }

        // Cancel: say nothing, back to idle.
        guard let cancelled = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
            preconditionFailure("Restore did not start")
        }
        check(!flow.finish(.cancelled, attempt: cancelled, screenAccountIsActive: true))
        check(flow.phase == .idle)

        // Stale account at completion: the result is dropped, the screen is idle.
        guard let stale = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
            preconditionFailure("Restore did not start")
        }
        check(!flow.finish(.restored, attempt: stale, screenAccountIsActive: false), "Showed a Restore result under another account")
        check(flow.phase == .idle)

        // Account switched away (and back) while running: invalidate orphans the attempt, so even
        // a result that arrives once the account is active again is not shown.
        guard let orphaned = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
            preconditionFailure("Restore did not start")
        }
        flow.invalidate()
        check(flow.phase == .idle)
        check(!flow.finish(.restored, attempt: orphaned, screenAccountIsActive: true), "Orphaned attempt surfaced after an account switch")
        check(flow.phase == .idle)
        check(flow.begin(screenAccountIsActive: true, isAvailable: true) != nil, "Restore stuck after invalidate")
    }

    private static func restoreNotice() {
        check(sgProStatusRestoreNotice(.idle) == nil)
        check(sgProStatusRestoreNotice(.running) == nil)
        check(sgProStatusRestoreNotice(.finished(.cancelled)) == nil)
        check(noticeMatches(.finished(.restored), "IAP.Message.RestoreCompleted", .success))
        // "Nothing found" is information, not an error — an admin grant is not an Apple purchase.
        check(noticeMatches(.finished(.nothingToRestore), "IAP.Message.NothingToRestore", .info))
        check(noticeMatches(.finished(.anotherOperationInProgress), "IAP.Message.StoreOperationInProgress", .pending))
        check(noticeMatches(.finished(.failed(messageKey: "Entitlement.Message.NoConnection")), "Entitlement.Message.NoConnection", .warning))
    }

    private static func noticeMatches(_ phase: SGProStatusRestorePhase, _ key: String, _ kind: SGProStatusNoticeKind) -> Bool {
        guard let notice = sgProStatusRestoreNotice(phase) else {
            return false
        }
        return notice.key == key && notice.kind == kind
    }
}
