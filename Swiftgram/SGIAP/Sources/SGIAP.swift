import Foundation
import UIKit
import StoreKit
import SGEntitlement
import SGLogging

public extension Notification.Name {
    /// The product list changed: it loaded, it failed, or a price / eligibility moved.
    static let SGIAPHelperProductsUpdatedNotification = Notification.Name("SGIAPProductsUpdatedNotification")
    /// Anything the purchase flow publishes changed — products, the App Store subscription status,
    /// the trial affordance or the attach outbox.
    static let SGIAPStateDidChangeNotification = Notification.Name("SGIAPStateDidChange")

    // MARK: Zenlygram — the three StoreKit 1 names (`SGIAPHelperPurchaseNotification`,
    // `…ErrorNotification`, `…ValidationErrorNotification`) are GONE, together with their last two
    // call sites (AppDelegate's `setupIAP()` and the paywall's publishers). StoreKit 2 hands the
    // outcome back from the awaited call, and there is no separate "validation" step at all:
    // POST /v1/apple/attach IS the validation, and it happens before `Transaction.finish()`.
}

/// Zenlygram — the App Store purchase flow (design §5.2, §5.6).
///
/// The manager itself carries no `@available`: `AccountContext` exposes it as a plain property and
/// the app's floor is iOS 13. Everything StoreKit 2 lives behind `if #available(iOS 15.0, *)` in
/// `SGIAPStoreKitEngine`; below that floor `isPurchaseSupported` is false and the paywall offers the
/// OS-update notice instead of a buy button. Nothing about *using* Pro depends on this — an
/// entitlement earned on a newer device keeps working here, because the gate is `SGEntitlement` and
/// it never asks StoreKit anything.
///
/// Threading: every member is safe from any thread (an internal `NSLock` guards the published
/// snapshot). `purchase`, `restore`, `loadProducts` and `startServerTrial` are `async` and return a
/// result; none of them throws.
///
/// Nothing here runs on the launch critical path. `start()` only attaches the `Transaction.updates`
/// listener — which is a local AsyncSequence, not a network call — and schedules the first snapshot
/// refresh and outbox drain after the first idle window. Products are loaded when the paywall opens.
public final class SGIAPManager {
    private let lock = NSLock()
    private let trialLedger: SGIAPTrialLedger

    // Guarded by `lock`.
    private var engineStorage: AnyObject?
    private var productsValue: [SGIAPProduct] = []
    private var productsStateValue: SGIAPProductsState = .idle
    private var subscriptionStatusSlot = SGIAPSubscriptionStatusSlot<SGIAPSubscriptionStatus>()
    private var didStart = false
    private var updatesTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    public init() {
        self.trialLedger = SGIAPTrialLedger.shared
        self.start()
    }

    deinit {
        self.updatesTask?.cancel()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Attaches the `Transaction.updates` listener and schedules the first background pass.
    ///
    /// The listener has to be running before anything else: a transaction can arrive when the app is
    /// nowhere near the purchase flow — a renewal, a Family Sharing grant, a purchase made on
    /// another device, or the Ask to Buy approval that arrives days after the child tapped Buy. A
    /// transaction that nobody is listening for is simply redelivered, but it is also never
    /// attached, and the user stays unentitled on our side until the next launch that does listen.
    private func start() {
        self.lock.lock()
        let alreadyStarted = self.didStart
        self.didStart = true
        self.lock.unlock()
        guard !alreadyStarted else {
            return
        }
        guard self.runsStoreKitWork else {
            // No listener, no snapshot refresh, no drain: StoreKit keeps every transaction (and the
            // outbox every entry) exactly as it is until an Apple-enabled build handles them.
            SGLogger.shared.log("SGIAP", "Apple backend held: StoreKit work deferred")
            #if SG_LENTA
            self.startRoutedUpdatesListener()
            #endif
            return
        }

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.applicationDidBecomeActive()
        }))
        // P7: a legacy, identityless StoreKit snapshot was quarantined by a live server revocation.
        // Re-reading StoreKit's own entries replaces it with identified receipts.
        self.observers.append(center.addObserver(forName: SGEntitlement.storeKitProvenanceRequestedNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.refreshStoreKitProvenance()
        }))

        guard #available(iOS 15.0, *) else {
            SGLogger.shared.log("SGIAP", "StoreKit 2 is unavailable on this OS; purchases are disabled")
            return
        }
        let engine = self.storeKitEngine()
        self.updatesTask = Task.detached(priority: .utility) { [weak self] in
            for await update in Transaction.updates {
                #if SG_LENTA
                // TIJ-11: a Lenta product goes to its own handler; Pro's status and engine never see it.
                if await SGIAPLentaRouting.route(update) {
                    continue
                }
                #endif
                // A renewal, an expiry, a refund or a change made in Apple's subscription page: the
                // status the paywall and the status screen quote may have moved with it. Begun (and
                // the old answer unsettled) before the attach below, which can wait on our server;
                // the query itself runs on its own task, so neither waits for the other.
                self?.requestSubscriptionStatus(engine: engine)
                await engine.handle(update)
                self?.publishAfterStoreKitChange()
            }
        }
        self.prewarm()
    }

    #if SG_LENTA
    /// Pro's Apple work is held, but Lenta proves its purchases to its own server: only Lenta products are read
    /// from `Transaction.updates`; every other update is left exactly as it is (redelivered later).
    private func startRoutedUpdatesListener() {
        guard #available(iOS 15.0, *), !SGIAPLentaRouting.productIds.isEmpty else {
            return
        }
        self.updatesTask = Task.detached(priority: .utility) {
            for await update in Transaction.updates {
                _ = await SGIAPLentaRouting.route(update)
            }
        }
    }
    #endif

    /// The post-launch idle hook: refresh what StoreKit already knows locally and retry any attach
    /// that is waiting. Both are cheap and neither blocks anything.
    public func prewarm() {
        guard #available(iOS 15.0, *), self.runsStoreKitWork else {
            return
        }
        let engine = self.storeKitEngine()
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SGEntitlementScheduler.firstIdleDelay * 1_000_000_000.0))
            await engine.refreshSnapshot()
            await engine.drainOutbox()
            // Deliberately NOT `publishAfterStoreKitChange()`: `SGEntitlement` already refreshes on
            // its own idle hook and on foreground, and poking it again here would spend the same
            // budget twice for the same answer. A transaction actually arriving is what warrants it.
            self?.postStateChange()
        }
    }

    /// Also wired to `UIApplication.didBecomeActiveNotification`.
    public func applicationDidBecomeActive() {
        guard #available(iOS 15.0, *), self.runsStoreKitWork else {
            return
        }
        let engine = self.storeKitEngine()
        // The user may be back from Apple's subscription page with auto-renew turned off: unsettle the
        // old answer NOW, not after the snapshot and the outbox drain (which can wait on our server).
        // Only a status read — it never loads products, syncs or buys.
        self.requestSubscriptionStatus(engine: engine)
        Task.detached(priority: .utility) { [weak self] in
            await engine.refreshSnapshot()
            await engine.drainOutbox()
            self?.postStateChange()
        }
    }

    private func refreshStoreKitProvenance() {
        guard #available(iOS 15.0, *), self.runsStoreKitWork else {
            return
        }
        let engine = self.storeKitEngine()
        Task.detached(priority: .utility) { [weak self] in
            await engine.refreshSnapshot()
            self?.postStateChange()
        }
    }

    @available(iOS 15.0, *)
    private func storeKitEngine() -> SGIAPStoreKitEngine {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let existing = self.engineStorage as? SGIAPStoreKitEngine {
            return existing
        }
        let created = SGIAPStoreKitEngine()
        self.engineStorage = created
        return created
    }

    /// The single Apple predicate (`SGEntitlement.isAppleBackendEnabled`): the explicit
    /// `apple_backend_enabled` flag, the authenticated configuration, a product list, and not
    /// public-policy-only. While false nothing StoreKit runs — no `Transaction.updates` listener,
    /// subscription-status query, snapshot refresh, outbox drain or delivery, provenance re-read,
    /// Restore, product load or purchase — so nothing is finished, enqueued, removed or sent.
    private var runsStoreKitWork: Bool {
        return SGEntitlement.shared.isAppleBackendEnabled
    }

    // MARK: - What the paywall reads (synchronous, never blocks)

    /// The App Store will take money from this Apple ID. False for parental controls, a managed
    /// device, or an OS too old for StoreKit 2.
    public var canMakePayments: Bool {
        if #available(iOS 15.0, *) {
            return AppStore.canMakePayments
        }
        return false
    }

    /// False on an OS older than StoreKit 2 requires. The paywall shows the update-iOS notice rather
    /// than a buy button that cannot work — and existing Pro material stays fully usable, because
    /// the gate is the entitlement, not StoreKit.
    public var isPurchaseSupported: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    public var availableProducts: [SGIAPProduct] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.productsValue
    }

    public var productsState: SGIAPProductsState {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.productsStateValue
    }

    public func product(id: String) -> SGIAPProduct? {
        return self.availableProducts.first(where: { $0.id == id })
    }

    /// What the App Store says about this Apple ID's subscription in our group, once products have
    /// been loaded. Informational: the gate is `SGEntitlement`, never this. The last ANSWER, kept
    /// while a newer query runs and when a query fails — what the paywall labels its plans with.
    /// Cleared only when StoreKit answers that nothing of ours is in the group.
    public var subscriptionStatus: SGIAPSubscriptionStatus? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.subscriptionStatusSlot.value
    }

    /// `subscriptionStatus`, but nil while a newer query is in flight, after the newest query failed
    /// (until one answers), and before the first answer. For a surface that states renewal or
    /// billing facts: it must not repeat an answer that is being replaced or could not be
    /// re-confirmed, e.g. right after the user changed auto-renew in Apple's page.
    public var settledSubscriptionStatus: SGIAPSubscriptionStatus? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.subscriptionStatusSlot.settled
    }

    /// Re-reads the subscription status, for the Pro status screen when it appears. Only once
    /// products have been loaded (the subscription group comes from them): it never loads products
    /// itself, so it adds no product request to any path.
    public func refreshSubscriptionStatus() {
        guard #available(iOS 15.0, *), self.runsStoreKitWork else {
            return
        }
        self.requestSubscriptionStatus(engine: self.storeKitEngine())
    }

    /// What buying `productId` would mean right now: a new subscription, the plan already running,
    /// the plan already queued to replace it, or a switch within the subscription group.
    ///
    /// A queued change is `renewalProductId` differing from `productId` while auto-renew is on — a
    /// downgrade made here or in Settings ▸ Subscriptions, which Apple applies at the renewal date.
    /// Neither plan is then "current" in the plain sense, and neither is something to buy: buying
    /// the queued plan again changes nothing, and undoing or changing it is Apple's subscription
    /// page (`.currentUntilRenewal` / `.scheduled`).
    ///
    /// The ranking here is by PERIOD LENGTH, which is a proxy: the authority is the subscription
    /// level configured per product in App Store Connect, and StoreKit is what actually decides.
    /// With exactly two plans — one month and one year, the year ranked above — the proxy and the
    /// authority agree. Add a third plan, or reorder the levels in ASC, and this needs revisiting.
    public func planChange(for productId: String) -> SGIAPPlanChange {
        guard let status = self.subscriptionStatus, status.isActive, let activeProductId = status.productId else {
            return .subscribe
        }
        let queuedProductId = status.queuedRenewalProductId
        if activeProductId == productId {
            return queuedProductId == nil ? .current : .currentUntilRenewal
        }
        if queuedProductId == productId {
            return .scheduled
        }
        let products = self.availableProducts
        guard let candidate = products.first(where: { $0.id == productId }),
              let active = products.first(where: { $0.id == activeProductId }),
              candidate.subscriptionGroupId != nil,
              candidate.subscriptionGroupId == active.subscriptionGroupId,
              let candidateMonths = candidate.period?.months,
              let activeMonths = active.period?.months
        else {
            // A different group, or a product we could not describe. Never claim a switch we cannot
            // substantiate: "Subscribe" is the honest label for "we do not know".
            return .subscribe
        }
        return candidateMonths > activeMonths ? .upgrade : .downgrade
    }

    /// A paid transaction the server refused in a way no retry will fix, AND whose owner is not
    /// already unlocked anyway. The transaction is still unfinished and the money is not lost.
    ///
    /// The second half is the whole point. The commonest way to reach a stuck entry is
    /// `apple_environment_mismatch` — which is what EVERY App Review purchase produces, because App
    /// Review buys with a Sandbox transaction against the production build and so against the
    /// production server. Pro is genuinely live in that state, from the StoreKit snapshot: telling
    /// someone who just paid, and who IS subscribed, that we could not confirm their purchase is
    /// worse than saying nothing, and it would say it on every paywall open for the life of the
    /// install. So the notice appears only when the local unlock is NOT carrying them — the one case
    /// where there is something for the user to act on, and Restore Purchases is the action.
    public var needsPurchaseHelp: Bool {
        guard !SGEntitlement.shared.outbox.stuckEntries().isEmpty else {
            return false
        }
        return !SGEntitlement.shared.state.isUnlocked
    }

    /// Which free-trial affordance to show (§5.6), for the account the paywall was opened for.
    ///
    /// Apple's intro offer and our server trial are separate ledgers and stay separate here: the app
    /// hides ITS OWN affordance when our ledger is consumed, and never tries to hide Apple's, which
    /// it cannot control. Our trial is per Telegram account, so `accountPeerId` is the paywall's own
    /// account — never the active one, which may be a different account entirely.
    public func trialAffordance(accountPeerId: Int64?) -> SGIAPTrialAffordance {
        let isLinked = accountPeerId.map({ SGEntitlement.shared.isLinked(accountPeerId: $0) }) ?? false
        return SGIAPTrialAffordance(
            isAppleIntroOfferAvailable: self.availableProducts.contains(where: { $0.isEligibleForIntroOffer && ($0.introductoryOffer?.isFreeTrial ?? false) }),
            isServerTrialAvailable: isLinked && self.trialLedger.isServerTrialAvailable(accountPeerId: accountPeerId),
            serverTrialRefusal: self.trialLedger.refusalMessage(accountPeerId: accountPeerId)
        )
    }

    // MARK: - Actions

    /// `Product.products(for: SG_CONFIG.iaps)` plus the subscription status. Call it when the paywall
    /// opens, never at launch. While the monetization policy is free nothing is queried and any
    /// products a paid-mode screen loaded are dropped, so no plan can be offered.
    @discardableResult
    public func loadProducts() async -> SGIAPProductsState {
        guard self.runsStoreKitWork, SGEntitlement.shared.offersNewSubscriptions else {
            let state = SGIAPProductsState.failed(.subscriptionsNotOffered)
            self.setProducts([], state: state)
            return state
        }
        guard #available(iOS 15.0, *) else {
            let state = SGIAPProductsState.failed(.requiresNewerOS)
            self.setProducts([], state: state)
            return state
        }
        let engine = self.storeKitEngine()
        switch await engine.loadProducts() {
        case let .loaded(products):
            await self.refreshSubscriptionStatus(engine: engine)
            // The policy may have turned free while the App Store answered: offer no plan then.
            guard SGEntitlement.shared.offersNewSubscriptions else {
                let state = SGIAPProductsState.failed(.subscriptionsNotOffered)
                self.setProducts([], state: state)
                return state
            }
            self.setProducts(products, state: .loaded)
            return .loaded
        case let .failed(message):
            let state = SGIAPProductsState.failed(message)
            self.setProductsState(state)
            return state
        }
    }

    /// Buy one plan for `accountPeerId` — the account whose paywall the user is looking at, passed
    /// explicitly and never read back from the active account (which can change while the App Store
    /// sheet is up). That account's binding prepares the `appAccountToken` and authenticates the
    /// attach; with no linked account the purchase goes through unbound.
    ///
    /// Both plans share a subscription group, so buying the other one while subscribed is an
    /// upgrade or a downgrade that StoreKit performs by itself — Apple prorates an upgrade
    /// immediately and defers a downgrade to the renewal date. There is no separate "change plan"
    /// call to make.
    ///
    /// The account link stays optional, but admission is mandatory: before anything reaches Apple,
    /// the purchase needs the cached mode paid, a FRESH verified paid policy fetched for it, and —
    /// for a linked account — a successful `prepare` for this product (`SGIAPPurchaseAdmission`,
    /// in the StoreKit engine).
    public func purchase(productId: String, accountPeerId: Int64?) async -> SGIAPPurchaseResult {
        guard self.runsStoreKitWork, SGEntitlement.shared.offersNewSubscriptions else {
            return .failed(.subscriptionsNotOffered)
        }
        guard #available(iOS 15.0, *) else {
            return .failed(.requiresNewerOS)
        }
        guard self.canMakePayments else {
            return .failed(.paymentsUnavailable)
        }
        let engine = self.storeKitEngine()
        let result = await engine.purchase(productId: productId, accountPeerId: accountPeerId)
        if case .cancelled = result {
            // Nothing moved, so nothing to publish and nothing to ask the server about.
            return result
        }
        await self.refreshSubscriptionStatus(engine: engine)
        self.publishAfterStoreKitChange()
        return result
    }

    /// Restore Purchases: `AppStore.sync()`, then re-attach everything this Apple ID still entitles.
    /// `accountPeerId` is the account Restore was pressed for: with a binding, each transaction is
    /// explicitly CLAIMED for it (which can recover a purchase made before linking Telegram, on
    /// another device or under a lost key — never one another Telegram account already owns).
    /// Refused while the Apple backend is held, before anything reaches the App Store: it would clear
    /// stuck flags and re-ingest or send transactions this build may not attach.
    public func restore(accountPeerId: Int64?) async -> SGIAPRestoreResult {
        guard self.runsStoreKitWork else {
            return .failed(.temporarilyUnavailable)
        }
        guard #available(iOS 15.0, *) else {
            return .failed(.requiresNewerOS)
        }
        let engine = self.storeKitEngine()
        let result = await engine.restore(accountPeerId: accountPeerId)
        await self.refreshSubscriptionStatus(engine: engine)
        self.publishAfterStoreKitChange()
        return result
    }

    /// `restore(accountPeerId:)` for a caller that is not `async` — the result is delivered on the
    /// MAIN queue, so the completion can present a controller directly.
    public func restore(accountPeerId: Int64?, completion: @escaping (SGIAPRestoreResult) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            completion(await self.restore(accountPeerId: accountPeerId))
        }
    }

    /// The fire-and-forget shape, for a call site that only wants the side effect (`OpenUrl`'s
    /// `restore` deep link).
    public func restorePurchases(accountPeerId: Int64?, completion: @escaping () -> Void) {
        self.restore(accountPeerId: accountPeerId, completion: { _ in
            completion()
        })
    }

    /// OUR trial (`POST /v1/trial/start`), which is not Apple's introductory offer, for the account
    /// the paywall was opened for — explicitly, never the active one.
    ///
    /// It needs a bound device — a linked Telegram account (§3.6). A PURCHASE never does. Every
    /// refusal is remembered so the affordance can be hidden next time, and returned so it can be
    /// shown NEXT TO the purchase options rather than as a dead end. Refused locally, before the
    /// request, while the monetization policy is free or names no trial (`serverTrialDays`).
    public func startServerTrial(accountPeerId: Int64?) async -> SGIAPTrialResult {
        let entitlement = SGEntitlement.shared
        guard entitlement.offersNewSubscriptions else {
            return .failed(.subscriptionsNotOffered)
        }
        // Our trial exists only while the signed policy offers it (`trial_days` > 0). A button
        // tapped between the operator disabling the trial and this screen's re-read would otherwise
        // spend one of the device's 3/h attempts on a certain 409 trial_disabled: refused here with
        // the same copy, and nothing is recorded — the policy, not the ledger, hides the button.
        guard entitlement.serverTrialDays != nil else {
            return .refused(.trialNotOffered)
        }
        // The session the trial runs under, captured once: the request presents it, and the granted
        // token or a failure's consequence applies only while it is still that account's session.
        guard let accountPeerId, let credential = entitlement.sessionCredential(accountPeerId: accountPeerId) else {
            return .notLinked
        }
        guard let client = entitlement.client else {
            return .failed(.temporarilyUnavailable)
        }
        let result = await client.startTrial(credential: credential, idempotencyKey: UUID().uuidString)
        switch result {
        case let .success(trial):
            self.trialLedger.recordGrant(accountPeerId: accountPeerId)
            entitlement.adopt(entitlement: trial.entitlement, credential: credential)
            self.postStateChange()
            return .started(endsAt: trial.trialEndsAtDate)
        case let .failure(error):
            self.trialLedger.record(refusal: error.failure, accountPeerId: accountPeerId)
            entitlement.apply(error, credential: credential)
            self.postStateChange()
            if case .refused = error.failure, let message = error.recovery.message {
                return .refused(message)
            }
            if case .rateLimited = error.failure {
                return .refused(.tooManyAttempts)
            }
            if case .offline = error.failure {
                return .failed(.noConnection)
            }
            return .failed(.temporarilyUnavailable)
        }
    }

    // MARK: - Debug

    #if DEBUG
    /// Debug builds only. Clears the local purchase-flow caches so the paywall, the trial affordance
    /// and the attach path can be exercised again. It cannot take a subscription away: the App Store
    /// owns `Transaction.currentEntitlements`, and the next snapshot refresh reads it back.
    public func resetLocalPurchaseStateForDebug() {
        // A held build may hold an earlier build's attach entries; it deletes none.
        guard self.runsStoreKitWork else {
            return
        }
        self.trialLedger.reset()
        for entry in SGEntitlement.shared.outbox.entries() {
            SGEntitlement.shared.outbox.remove(id: entry.id)
        }
        self.setProducts([], state: .idle)
        self.setSubscriptionStatus(nil)
        self.applicationDidBecomeActive()
    }
    #endif

    // MARK: - Publishing

    private func setProducts(_ products: [SGIAPProduct], state: SGIAPProductsState) {
        self.lock.lock()
        let changed = self.productsValue != products || self.productsStateValue != state
        self.productsValue = products
        self.productsStateValue = state
        self.lock.unlock()
        guard changed else {
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SGIAPHelperProductsUpdatedNotification, object: nil)
            NotificationCenter.default.post(name: .SGIAPStateDidChangeNotification, object: nil)
        }
    }

    private func setProductsState(_ state: SGIAPProductsState) {
        self.lock.lock()
        let changed = self.productsStateValue != state
        self.productsStateValue = state
        self.lock.unlock()
        if changed {
            self.postStateChange()
        }
    }

    /// Debug reset only: forget the status, superseding any query in flight.
    private func setSubscriptionStatus(_ status: SGIAPSubscriptionStatus?) {
        self.lock.lock()
        let generation = self.subscriptionStatusSlot.begin().generation
        let changed = self.subscriptionStatusSlot.complete(generation, status: status)
        self.lock.unlock()
        if changed {
            self.postStateChange()
        }
    }

    /// Opens a status query and supersedes every earlier one (`SGIAPSubscriptionStatusSlot`);
    /// `settledSubscriptionStatus` is nil from here until it lands.
    private func beginSubscriptionStatusQuery() -> UInt64 {
        self.lock.lock()
        let (generation, hidValue) = self.subscriptionStatusSlot.begin()
        self.lock.unlock()
        if hidValue {
            self.postStateChange()
        }
        return generation
    }

    /// Lands a query's result if it is still the newest. A failed query keeps the last answer for
    /// the paywall's plan labels and leaves the settled status unknown; it is never "not subscribed".
    private func finishSubscriptionStatusQuery(_ generation: UInt64, answer: SGIAPSubscriptionStatusAnswer) {
        self.lock.lock()
        let changed: Bool
        switch answer {
        case let .answered(status):
            changed = self.subscriptionStatusSlot.complete(generation, status: status)
        case .unavailable:
            changed = self.subscriptionStatusSlot.fail(generation)
        }
        self.lock.unlock()
        if changed {
            self.postStateChange()
        }
    }

    /// One status query, awaited (after a product load, purchase or Restore). No retry.
    @available(iOS 15.0, *)
    private func refreshSubscriptionStatus(engine: SGIAPStoreKitEngine) async {
        let generation = self.beginSubscriptionStatusQuery()
        let answer = await engine.subscriptionStatus()
        self.finishSubscriptionStatusQuery(generation, answer: answer)
    }

    /// One status query, begun synchronously at the trigger and answered on its own task.
    @available(iOS 15.0, *)
    private func requestSubscriptionStatus(engine: SGIAPStoreKitEngine) {
        let generation = self.beginSubscriptionStatusQuery()
        Task.detached(priority: .utility) { [weak self] in
            let answer = await engine.subscriptionStatus()
            self?.finishSubscriptionStatusQuery(generation, answer: answer)
        }
    }

    /// A transaction arrived or an attach landed: the entitlement may have moved, so ask for a
    /// refresh and tell the UI.
    private func publishAfterStoreKitChange() {
        SGEntitlement.shared.storeKitTransactionsDidChange()
        self.postStateChange()
    }

    private func postStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SGIAPStateDidChangeNotification, object: nil)
        }
    }
}
