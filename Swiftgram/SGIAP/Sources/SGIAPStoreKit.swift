import Foundation
import StoreKit
import SGConfig
import SGEntitlement
import SGLogging

/// The result of one `Product.products(for:)` pass. A plain enum rather than a `Result`, because
/// `SGIAPMessage` is copy, not an error: nothing in this module ever throws it.
enum SGIAPProductsOutcome {
    case loaded([SGIAPProduct])
    case failed(SGIAPMessage)
}

/// Product ids another handler owns (TIJ-11): `sg_config.lenta_iaps` in a Lenta build, none otherwise. Never
/// finished, attached, restored, snapshotted or used for the Pro subscription group here.
let sgIAPRoutedProductIds: [String] = {
    #if SG_LENTA
    return SG_CONFIG.lentaIaps
    #else
    return []
    #endif
}()

/// Zenlygram — everything that touches StoreKit 2.
///
/// An `actor`, for two reasons that are not style:
/// - a purchase and the outbox drain both call `/v1/apple/attach`, and the outbox entry's
///   `Idempotency-Key` is only correct if one attach per entry is in flight at a time;
/// - `Transaction.updates` delivers on its own task, concurrently with whatever the paywall is
///   doing, and both paths mutate the same product cache.
///
/// **The one rule the whole file is built around: never `finish()` an unattached transaction.**
/// StoreKit redelivers an unfinished transaction; a finished one is gone forever, and with it the
/// proof of a payment. Every `finish()` below is downstream of a 2xx (or of a transaction that is
/// provably not a payment: another product, or a refund).
@available(iOS 15.0, *)
actor SGIAPStoreKitEngine {
    private var products: [String: Product] = [:]
    private let drains = SGIAPDrainRunner()
    private let deliveries = SGIAPDeliveryCoordinator()
    private var snapshots = SGIAPSnapshotRefreshState()
    /// One App Store operation at a time on this device: a purchase or a Restore. The actor is
    /// reentrant across every `await` of either, and an overlap is exactly what attribution cannot
    /// survive — two purchases make `route(productId:appAccountToken:)` unable to tell whose
    /// tokenless transaction an update is, and a Restore running during a purchase would enqueue
    /// that purchase's transaction under the Restore's account before the purchase names it.
    /// Checked and set with no `await` in between (`beginStoreOperation`), which on an actor is
    /// atomic.
    private var isStoreOperationInProgress = false

    /// Claims the App Store for one purchase or Restore, or answers false when another holds it.
    /// The caller must not `await` before this and must call `endStoreOperation()` on every exit.
    private func beginStoreOperation() -> Bool {
        guard !self.isStoreOperationInProgress else {
            return false
        }
        self.isStoreOperationInProgress = true
        return true
    }

    private func endStoreOperation() {
        self.isStoreOperationInProgress = false
    }

    /// Attributed purchases between their `prepare` and their return, by an id of their own.
    private var purchasesInFlight: [UUID: PurchaseInFlight] = [:]
    /// `Transaction.updates` deliveries held back while a purchase in flight might be their origin,
    /// keyed like `purchasesInFlight` (`route(productId:appAccountToken:)`).
    private var heldUpdates: [UUID: [HeldUpdate]] = [:]

    /// One attributed purchase in progress. StoreKit can ALSO hand a purchase's own transaction to
    /// `Transaction.updates`, and that delivery can reach the outbox before `purchase(options:)`
    /// returns. It carries no paywall context, so without this record the entry would be created
    /// unbound — and the purchase path, finding it, would keep that (`enqueue` never re-attributes),
    /// and the unbound attach could make the server file the purchase under a new Apple-only
    /// account before the purchase's own attach claims it.
    struct PurchaseInFlight {
        let productId: String
        /// The token `prepare` minted for this purchase, when it did. It is on the transaction.
        let appAccountToken: UUID?
        let accountPeerId: Int64
    }

    /// An update held back by `route`, and what releasing it unattributed does.
    struct HeldUpdate {
        let transactionId: UInt64
        let attachUnbound: () async -> Void
    }

    enum UpdateRoute: Equatable {
        /// It carries the exact `appAccountToken` a purchase in flight here prepared: that account's.
        case attribute(Int64)
        /// It carries no token while a tokenless purchase of the same product is in flight here, so
        /// it may or may not be that purchase's transaction — from another device or a Family Sharing
        /// member, it would not be. Held until the purchase returns and names its own transaction.
        case hold(UUID)
        /// Anything else: attached unbound, and the server resolves the owner from the transaction.
        case unbound
    }

    func beginPurchase(_ purchase: PurchaseInFlight) -> UUID {
        let id = UUID()
        self.purchasesInFlight[id] = purchase
        return id
    }

    /// Where a `Transaction.updates` delivery goes. Only an exact prepared token attributes; a
    /// product match alone never does — another device, a Family Sharing member or a second Apple
    /// ID purchase of the same product looks exactly like it.
    func route(productId: String, appAccountToken: UUID?) -> UpdateRoute {
        if let appAccountToken {
            if let purchase = self.purchasesInFlight.values.first(where: { $0.appAccountToken == appAccountToken }) {
                return .attribute(purchase.accountPeerId)
            }
            return .unbound
        }
        if let held = self.purchasesInFlight.first(where: { $0.value.appAccountToken == nil && $0.value.productId == productId }) {
            return .hold(held.key)
        }
        return .unbound
    }

    func hold(_ update: HeldUpdate, for purchaseId: UUID) {
        self.heldUpdates[purchaseId, default: []].append(update)
    }

    /// Ends a purchase and hands back what was held for it, minus its OWN transaction — the one
    /// `purchase(options:)` returned, which the purchase path has already attached for its account.
    /// The rest were never this purchase's and go out unbound. A cancelled, pending or failed
    /// purchase names no transaction, so everything held is released. Nothing held was finished: a
    /// process that dies holding them gets them redelivered at the next launch.
    func endPurchase(_ purchaseId: UUID, purchasedTransactionId: UInt64?) -> [HeldUpdate] {
        self.purchasesInFlight.removeValue(forKey: purchaseId)
        let held = self.heldUpdates.removeValue(forKey: purchaseId) ?? []
        return held.filter { $0.transactionId != purchasedTransactionId }
    }

    // MARK: - Products

    /// `Product.products(for: SG_CONFIG.iaps)`.
    ///
    /// Called when the paywall opens, never at launch: it is a network call, and invariant I1 keeps
    /// the launch critical path free of those.
    func loadProducts() async -> SGIAPProductsOutcome {
        let identifiers = SG_CONFIG.iaps
        guard !identifiers.isEmpty else {
            SGLogger.shared.log("SGIAP", "No product ids in SG_CONFIG.iaps")
            return .failed(.productsUnavailable)
        }
        do {
            let storeProducts = try await Product.products(for: Set(identifiers))
            guard !storeProducts.isEmpty else {
                SGLogger.shared.log("SGIAP", "App Store returned no products for \(identifiers.count) ids")
                return .failed(.productsUnavailable)
            }
            for product in storeProducts {
                self.products[product.id] = product
            }
            var result: [SGIAPProduct] = []
            // Keep SG_CONFIG's order: it is the order the paywall lists the plans in, and the App
            // Store returns them in whatever order it likes.
            for identifier in identifiers {
                if let product = self.products[identifier] {
                    result.append(await SGIAPStoreKitEngine.describe(product))
                }
            }
            SGLogger.shared.log("SGIAP", "Loaded products: \(result.map({ $0.id }).joined(separator: ", "))")
            return .loaded(result)
        } catch {
            SGLogger.shared.log("SGIAP", "Failed to load products: \(error.localizedDescription)")
            return .failed(SGIAPStoreKitEngine.message(for: error))
        }
    }

    /// The subscription group both plans live in, once products have been loaded. `nil` before that:
    /// there is no way to know it without asking the App Store, and asking is a network call.
    private func subscriptionGroupId() -> String? {
        for identifier in SG_CONFIG.iaps where !sgIAPRoutedProductIds.contains(identifier) {
            if let groupId = self.products[identifier]?.subscription?.subscriptionGroupID {
                return groupId
            }
        }
        return nil
    }

    /// What the App Store says about this Apple ID's subscription in our group.
    ///
    /// Informational only — the gate is `SGEntitlement`. It is what lets the paywall offer the other
    /// plan as a SWITCH: both products share one subscription group, so buying the other one is an
    /// upgrade or a downgrade that StoreKit performs by itself, with Apple prorating the remainder.
    ///
    /// `.answered(nil)` is StoreKit saying there is nothing in the group; `.unavailable` is not
    /// knowing (no products loaded yet, so no group id, or the query threw) and must never be read
    /// as "not subscribed".
    func subscriptionStatus() async -> SGIAPSubscriptionStatusAnswer {
        guard let groupId = self.subscriptionGroupId() else {
            return .unavailable
        }
        do {
            let statuses = try await Product.SubscriptionInfo.status(for: groupId)
            guard let status = SGIAPStoreKitEngine.preferredStatus(statuses) else {
                return .answered(nil)
            }
            var productId: String?
            var expirationDate: Date?
            if case let .verified(transaction) = status.transaction {
                productId = transaction.productID
                expirationDate = transaction.expirationDate
            }
            var willAutoRenew = false
            var renewalProductId: String?
            if case let .verified(renewalInfo) = status.renewalInfo {
                willAutoRenew = renewalInfo.willAutoRenew
                renewalProductId = renewalInfo.autoRenewPreference
            }
            return .answered(SGIAPSubscriptionStatus(
                state: SGIAPStoreKitEngine.state(for: status.state),
                productId: productId,
                expirationDate: expirationDate,
                willAutoRenew: willAutoRenew,
                renewalProductId: renewalProductId
            ))
        } catch {
            SGLogger.shared.log("SGIAP", "Failed to read subscription status: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Buying

    /// The whole purchase, §5.2 in order: admission, prepare, purchase, verify, attach, and only then
    /// finish.
    ///
    /// ADMISSION IS MANDATORY, THE ACCOUNT LINK IS OPTIONAL (`SGIAPPurchaseAdmission`, contract
    /// `x-client-state.apple_purchase_admission`). Every new purchase first fetches the public signed
    /// monetization policy for itself and needs it verified and PAID — never the cached mode. An
    /// UNLINKED install then buys with no `appAccountToken` (some users cannot reach Telegram at all,
    /// and App Review does not let a purchase require an account); the server links it later from
    /// the `X-Device-Id` crumb `/v1/apple/attach` always sends. A LINKED account must also get a
    /// successful `/v1/apple/prepare` for this product: every failure refuses, and is never
    /// downgraded to an unbound purchase. The local mode is re-checked after every await.
    ///
    /// Limit: once StoreKit's sheet is up, a policy flip cannot cancel it — the server's own rules
    /// and Apple are the backstop. Restore, attach and `Transaction.updates` never pass through here.
    ///
    /// `accountPeerId` is the account whose paywall started this purchase. Its binding is resolved
    /// ONCE, here, before anything suspends: the App Store sheet can be up for minutes (SCA, a
    /// password, a backgrounded app), the active account can change meanwhile, and the `prepare`
    /// that minted the `appAccountToken` and the attach that presents the transaction must be the
    /// same account's — the server refuses an attach whose token belongs to someone else.
    ///
    /// One App Store operation at a time (`beginStoreOperation`): a purchase started while another
    /// purchase or a Restore has not returned is refused with `.storeOperationInProgress` — before
    /// prepare, before StoreKit, so nothing is started or charged.
    func purchase(productId: String, accountPeerId: Int64?) async -> SGIAPPurchaseResult {
        guard self.beginStoreOperation() else {
            return .failed(.storeOperationInProgress)
        }
        defer {
            self.endStoreOperation()
        }
        let entitlement = SGEntitlement.shared
        let credential = accountPeerId.flatMap { entitlement.sessionCredential(accountPeerId: $0) }
        guard AppStore.canMakePayments else {
            return .failed(.paymentsUnavailable)
        }
        let product: Product
        if let cached = self.products[productId] {
            product = cached
        } else {
            do {
                guard let fetched = try await Product.products(for: [productId]).first else {
                    return .failed(.productsUnavailable)
                }
                self.products[productId] = fetched
                product = fetched
            } catch {
                return .failed(SGIAPStoreKitEngine.message(for: error))
            }
        }

        var prepare: (() async -> SGIAPPurchaseAdmission.Prepare)?
        // What a session failure of `prepare` says, from that failure's own recovery.
        var sessionRefusalMessage: SGIAPMessage?
        if let credential {
            prepare = {
                guard let client = entitlement.client else {
                    return .unavailable
                }
                let answer = await client.applePrepare(credential: credential, productId: productId, idempotencyKey: UUID().uuidString)
                if case let .failure(error) = answer, case .session = error.failure {
                    // The session's own recovery, applied to the session captured for THIS purchase
                    // only: an invalid / expired / revoked one is dropped (the Link row returns),
                    // a transient one keeps it and schedules the bounded re-check.
                    entitlement.apply(error, credential: credential)
                    sessionRefusalMessage = SGIAPStoreKitEngine.sessionRefusalMessage(error.recovery)
                }
                return SGIAPStoreKitEngine.admissionPrepare(answer)
            }
        }
        let admission = await SGIAPPurchaseAdmission.run(
            productId: productId,
            isOfferedLocally: { entitlement.offersNewSubscriptions },
            authorize: {
                let authorization = await entitlement.authorizeNewPurchase()
                return SGIAPStoreKitEngine.admissionAuthorization(authorization)
            },
            prepare: prepare,
            purchase: { appAccountToken in
                return await self.admittedPurchase(product, appAccountToken: appAccountToken, accountPeerId: credential?.accountPeerId)
            }
        )
        switch admission {
        case let .admitted(result):
            return result
        case let .refused(refusal):
            if refusal == .notOffered {
                // The server or a fresh policy says free: bring the cached mode up to date (gated
                // like every policy refresh), so the paywall stops offering plans.
                entitlement.refreshMonetizationPolicy()
            }
            if refusal == .relink, let sessionRefusalMessage {
                return .failed(sessionRefusalMessage)
            }
            return .failed(SGIAPStoreKitEngine.message(for: refusal))
        }
    }

    /// The StoreKit call itself, reached only through `SGIAPPurchaseAdmission`.
    private func admittedPurchase(_ product: Product, appAccountToken: UUID?, accountPeerId: Int64?) async -> SGIAPPurchaseResult {
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken {
            options.insert(.appAccountToken(appAccountToken))
        }
        // From here until the purchase's own transaction is in the outbox, an update that may be it
        // is routed by `route(productId:appAccountToken:)`, whichever path reaches the outbox first.
        var inFlight: UUID?
        if let accountPeerId {
            inFlight = self.beginPurchase(PurchaseInFlight(productId: product.id, appAccountToken: appAccountToken, accountPeerId: accountPeerId))
        }
        let (result, purchasedTransactionId) = await self.performPurchase(product, options: options, accountPeerId: accountPeerId)
        if let inFlight {
            let released = self.endPurchase(inFlight, purchasedTransactionId: purchasedTransactionId)
            for update in released {
                await update.attachUnbound()
            }
            if !released.isEmpty {
                await self.refreshSnapshot()
            }
        }
        return result
    }

    private static func admissionAuthorization(_ authorization: SGEntitlementPurchaseAuthorization) -> SGIAPPurchaseAdmission.Authorization {
        switch authorization {
        case .paid:
            return .paid
        case .free:
            return .free
        case .unavailable:
            return .unavailable
        case .busy:
            return .busy
        }
    }

    private static func admissionPrepare(_ answer: Result<SGEntitlementApplePrepare, SGEntitlementRequestError>) -> SGIAPPurchaseAdmission.Prepare {
        switch answer {
        case let .success(prepare):
            return SGIAPPurchaseAdmission.Prepare(status: 200, appAccountToken: prepare.appAccountToken, productId: prepare.productId, errorCode: nil)
        case let .failure(error):
            switch error.failure {
            case .offline:
                return .offline
            case .session:
                return .sessionRefused
            case let .unknownRefusal(code, status):
                return SGIAPPurchaseAdmission.Prepare(status: status, appAccountToken: nil, productId: nil, errorCode: code)
            case .refused, .rateLimited:
                return .unavailable
            }
        }
    }

    /// The copy for a refused purchase whose linked `prepare` failed on the SESSION, from that
    /// failure's own recovery (`SGEntitlementFailureMapping`), never reclassified here. When the
    /// recovery dropped the session, its message ("sign in again", "signed out for security") is
    /// actionable: the account reads as unlinked again and the Link row returns. When it kept the
    /// session (a stale signature, a replayed nonce, a skewed clock), linking again would not help
    /// and the Link row stays hidden — so a visible, retryable check failure instead.
    private static func sessionRefusalMessage(_ recovery: SGEntitlementRecovery) -> SGIAPMessage {
        guard case .dropSession = recovery.consequence, let message = recovery.message else {
            return .purchaseCheckFailed
        }
        return .entitlement(message)
    }

    private static func message(for refusal: SGIAPPurchaseAdmission.Refusal) -> SGIAPMessage {
        switch refusal {
        case .notOffered:
            return .subscriptionsNotOffered
        case .unavailable:
            return .purchaseCheckFailed
        case .noConnection:
            return .noConnection
        case .busy:
            return .purchaseCheckBusy
        case .relink:
            // Normally replaced by the session failure's own copy (`sessionRefusalMessage`).
            return .purchaseCheckFailed
        }
    }

    /// `purchase(options:)` and, for a verified transaction, its attach — attributed to
    /// `accountPeerId` — before the caller ends the in-flight record. Returns the transaction's id
    /// when StoreKit handed one back.
    private func performPurchase(_ product: Product, options: Set<Product.PurchaseOption>, accountPeerId: Int64?) async -> (SGIAPPurchaseResult, UInt64?) {
        let productId = product.id
        SGLogger.shared.log("SGIAP", "Buying \(productId) (appAccountToken: \(options.isEmpty ? "no" : "yes"))...")
        do {
            let result = try await product.purchase(options: options)
            switch result {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    // StoreKit itself could not verify the signature. It is not ours to repair, and
                    // it must not be finished: an unverified transaction proves nothing, and
                    // finishing it throws away a redelivery that might verify.
                    SGLogger.shared.log("SGIAP", "Purchase returned an unverified transaction; leaving it unfinished")
                    return (.failed(.entitlement(.purchaseNeedsHelp)), nil)
                }
                let outcome = await self.ingest(transaction, jws: verification.jwsRepresentation, accountPeerId: accountPeerId)
                await self.refreshSnapshot()
                switch outcome {
                case .attached, .ignored:
                    return (.purchased, transaction.id)
                case .deferred:
                    // Paid and verified. The attach retries in the background, and the local
                    // StoreKit snapshot already unlocks Pro — a paying user is never made to wait
                    // for our server (invariant I2).
                    return (.purchased, transaction.id)
                case .needsHelp:
                    return (.purchasedNeedsHelp, transaction.id)
                }
            case .userCancelled:
                return (.cancelled, nil)
            case .pending:
                // Ask to Buy, or an SCA challenge. The transaction arrives later through
                // `Transaction.updates`, which is why that listener starts at launch and not here.
                // It carries the `appAccountToken` minted above for THIS account, and the unbound
                // attach `handle(_:)` makes lets the server resolve the owner from that token.
                SGLogger.shared.log("SGIAP", "Purchase of \(productId) is pending approval")
                return (.pending, nil)
            @unknown default:
                return (.failed(.temporarilyUnavailable), nil)
            }
        } catch {
            SGLogger.shared.log("SGIAP", "Purchase of \(productId) failed: \(error.localizedDescription)")
            return (.failed(SGIAPStoreKitEngine.message(for: error)), nil)
        }
    }

    /// Restore Purchases: `AppStore.sync()`, then re-attach everything the Apple ID still entitles.
    ///
    /// `accountPeerId` is the account Restore was pressed for. When it holds a binding at that
    /// moment, each current transaction gets an EXPLICIT claim (`claimForRestore`, the
    /// `apple-restore` proof) for that account — under the session it holds when the claim is SENT,
    /// never one read before the App Store sheet; otherwise the ordinary anonymous attach. Restore
    /// never creates or re-tags an attributed outbox entry: entries keep the account they were
    /// created with.
    ///
    /// For a bound account, `.restored` means every current transaction was claimed for it. Any
    /// claim that did not go through — offline, a refused session, the session gone, another
    /// account owning the receipt — reports `.failed`, never success (`SGIAPRestoreClaimSummary`).
    ///
    /// Shares the one-operation-at-a-time state with `purchase`: a Restore while a purchase (or
    /// another Restore) has not returned is refused with `.storeOperationInProgress` before
    /// `AppStore.sync()` — otherwise it could enqueue a purchase's own transaction under the Restore's
    /// account before the purchase names it.
    func restore(accountPeerId: Int64?) async -> SGIAPRestoreResult {
        // Held: no `AppStore.sync()`, no stuck-flag reset, no claim, no drain.
        guard SGEntitlement.shared.isAppleBackendEnabled else {
            return .failed(.temporarilyUnavailable)
        }
        guard self.beginStoreOperation() else {
            return .failed(.storeOperationInProgress)
        }
        defer {
            self.endStoreOperation()
        }
        // Whether this is an account Restore: decided now, from the binding the account holds when
        // Restore is pressed. Only the account is kept — its session (refresh token) is read again
        // right before each claim is sent, because it may rotate while the App Store sheet is up.
        let claimAccountPeerId = accountPeerId.flatMap { SGEntitlement.shared.sessionCredential(accountPeerId: $0) != nil ? $0 : nil }
        SGLogger.shared.log("SGIAP", "Restoring purchases...")
        do {
            try await AppStore.sync()
        } catch {
            if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError {
                return .cancelled
            }
            SGLogger.shared.log("SGIAP", "AppStore.sync failed: \(error.localizedDescription)")
            return .failed(SGIAPStoreKitEngine.message(for: error))
        }
        // Restore Purchases IS the manual retry for an attach that stopped retrying by itself. It is
        // the one event that can change a "no automatic retry will fix this" answer — an operator
        // re-deploy, a conflict a human resolved — and it is user-initiated, so it cannot loop.
        SGEntitlement.shared.outbox.clearStuckFlags()
        // Re-attach for real: a transaction this process already delivered (say unbound, before
        // the user linked Telegram) must not be answered from the duplicate memo.
        await self.deliveries.forgetDeliveries()
        var found = false
        var claimOutcomes: [SGIAPRestoreClaimOutcome] = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else {
                continue
            }
            guard SG_CONFIG.iaps.contains(transaction.productID), !sgIAPRoutedProductIds.contains(transaction.productID), transaction.revocationDate == nil else {
                continue
            }
            found = true
            if let claimAccountPeerId {
                claimOutcomes.append(await self.claimForRestore(transaction, jws: result.jwsRepresentation, accountPeerId: claimAccountPeerId))
            } else {
                // Unbound: the ordinary anonymous attach (with its `apple-orphan` proof).
                _ = await self.ingest(transaction, jws: result.jwsRepresentation, accountPeerId: nil)
            }
        }
        // Expired transactions may still be owed an attach even though currentEntitlements no
        // longer contains them. Restore explicitly made these entries retryable too.
        await self.drainOutbox()
        await self.refreshSnapshot()
        guard found else {
            return .nothingToRestore
        }
        guard claimAccountPeerId != nil else {
            return .restored
        }
        return SGIAPStoreKitEngine.restoreResult(SGIAPRestoreClaimSummary(outcomes: claimOutcomes))
    }

    /// What a bound Restore reports. Copy only from messages that already exist.
    static func restoreResult(_ summary: SGIAPRestoreClaimSummary) -> SGIAPRestoreResult {
        switch summary {
        case .restored:
            return .restored
        case .nothingToRestore:
            return .nothingToRestore
        case .notClaimed(.needsHelp):
            return .failed(.entitlement(.purchaseNeedsHelp))
        case .notClaimed(.unavailable):
            return .failed(.temporarilyUnavailable)
        case .notClaimed(.noConnection):
            return .failed(.noConnection)
        }
    }

    /// How a failed explicit claim is treated (`SGIAPRestoreClaim`).
    static func classifyClaimFailure(_ error: SGEntitlementRequestError) -> SGIAPRestoreClaimFailureKind {
        switch error.failure {
        case .offline, .rateLimited:
            return .retryable
        case .session:
            return .sessionRejected
        case .refused(.appleSubscriptionConflict):
            return .conflict
        case .refused, .unknownRefusal:
            if case .backoff = error.recovery.retry {
                // apple_temporarily_unavailable, idempotency_in_flight.
                return .retryable
            }
            return .refused
        }
    }

    /// Restore Purchases for a LINKED account: the explicit claim (`apple-restore` proof). It may move
    /// this receipt's still-unlinked, unmerged orphan — bought before Telegram, on another device, or
    /// under a lost key — to the account's binding. An original already bound to another Telegram
    /// account stays a 409; nothing is reassigned, and the receipt is recorded as not granting this
    /// account.
    ///
    /// It is NOT an outbox entry and never re-tags one. The orchestration is `SGIAPRestoreClaim`:
    /// exclusive on the delivery coordinator for this transaction (an ordinary attach in flight
    /// settles first with its own captured account; none starts beside the claim), the session read
    /// at send time, its own `restore-` idempotency key, and the ordinary (unbound) attach afterwards
    /// only where a later retry can still succeed.
    private func claimForRestore(_ transaction: Transaction, jws: String, accountPeerId: Int64) async -> SGIAPRestoreClaimOutcome {
        let transactionId = String(transaction.id)
        let entitlement = SGEntitlement.shared
        guard let client = entitlement.client else {
            _ = await self.ingest(transaction, jws: jws, accountPeerId: nil)
            return .retryable
        }
        let claim = SGIAPRestoreClaim<SGEntitlementSessionCredential, SGEntitlementAppleAttach, SGEntitlementRequestError>(
            currentCredential: {
                entitlement.sessionCredential(accountPeerId: accountPeerId)
            },
            send: { credential in
                await client.appleAttach(credential: credential, signedTransaction: jws, idempotencyKey: "restore-" + UUID().uuidString, explicitRestore: true)
            },
            classify: SGIAPStoreKitEngine.classifyClaimFailure,
            accept: { attach, credential in
                SGLogger.shared.log("SGIAP", "Restore claim for \(transactionId) attached (granted: \(attach.granted))")
                entitlement.recordAppleAttach(
                    presentedTransactionId: transactionId,
                    transactionId: attach.transaction?.transactionId,
                    originalTransactionId: attach.transaction?.originalTransactionId,
                    environment: attach.transaction?.environment,
                    accountId: attach.account?.id,
                    linkedTelegram: attach.account?.linkedTelegram,
                    boundAccountPeerId: credential.accountPeerId
                )
                if let jws = attach.entitlement {
                    entitlement.adopt(entitlement: jws, credential: credential)
                }
                // The server holds this exact transaction now (a 2xx). An ordinary entry still waiting
                // for it keeps its own attach and finishes it; with none, finishing here is safe.
                if !entitlement.outbox.entries().contains(where: { $0.id == transactionId }) {
                    await transaction.finish()
                }
            },
            reject: { error, credential, kind in
                SGLogger.shared.log("SGIAP", "Restore claim for \(transactionId) failed: \(error.failure)")
                entitlement.apply(error, credential: credential)
                if kind == .conflict {
                    entitlement.recordAppleAttachConflict(signedTransaction: jws, accountPeerId: credential.accountPeerId)
                }
            },
            ordinaryAttach: {
                _ = await self.ingest(transaction, jws: jws, accountPeerId: nil)
            }
        )
        return await claim.run(transactionId: transactionId, deliveries: self.deliveries)
    }

    // MARK: - Transactions

    /// One `Transaction.updates` element: a renewal, a Family Sharing grant, a purchase made on
    /// another device, an Ask to Buy approval, or a refund.
    ///
    /// Nothing on screen started it, so nothing attributes it — with one exception: the transaction
    /// of a purchase still in flight here, which StoreKit may deliver here too and first. One that
    /// carries that purchase's exact prepared `appAccountToken` keeps its account at once; a
    /// tokenless one of the same product is HELD until the purchase names its own transaction
    /// (`route`, `endPurchase`). Otherwise a transaction the outbox already holds keeps its own
    /// account, and a new one is attached UNBOUND. The server then resolves the owner from what the
    /// transaction itself proves — the `appAccountToken` its `prepare` minted, or the account
    /// already holding its original transaction — instead of from whichever account happens to be
    /// active, which would be a 409 conflict (and a stuck entry) for a renewal another signed-in
    /// account owns.
    func handle(_ update: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = update else {
            SGLogger.shared.log("SGIAP", "Unverified transaction in Transaction.updates; leaving it unfinished")
            return
        }
        SGLogger.shared.log("SGIAP", "Transaction update for \(transaction.productID) (\(transaction.id))")
        let jws = update.jwsRepresentation
        if transaction.revocationDate != nil {
            // A refund is never the payment a purchase sheet is waiting to return. In particular,
            // do not hold a tokenless refund just because that same product is being purchased.
            _ = await self.ingest(transaction, jws: jws, accountPeerId: nil)
            await self.refreshSnapshot()
            return
        }
        switch self.route(productId: transaction.productID, appAccountToken: transaction.appAccountToken) {
        case let .attribute(accountPeerId):
            _ = await self.ingest(transaction, jws: jws, accountPeerId: accountPeerId)
        case let .hold(purchaseId):
            // Left unfinished and out of the outbox until that purchase returns.
            self.hold(HeldUpdate(transactionId: transaction.id, attachUnbound: {
                _ = await self.ingest(transaction, jws: jws, accountPeerId: nil)
            }), for: purchaseId)
            return
        case .unbound:
            _ = await self.ingest(transaction, jws: jws, accountPeerId: nil)
        }
        await self.refreshSnapshot()
    }

    /// Attach one transaction, and finish it only if that worked. `accountPeerId` attributes a NEW
    /// outbox entry and is ignored for one that already exists.
    @discardableResult
    private func ingest(_ transaction: Transaction, jws: String, accountPeerId: Int64?) async -> SGIAPAttachOutcome {
        let isAppleHeld = !SGEntitlement.shared.isAppleBackendEnabled
        switch SGIAPAppleBoundary.ingest(isAppleHeld: isAppleHeld, configuredProductIds: SG_CONFIG.iaps, routedProductIds: sgIAPRoutedProductIds, productId: transaction.productID, isRevoked: transaction.revocationDate != nil) {
        case .route:
            // Another handler's product: it reads `Transaction.unfinished` itself and finishes after its own 2xx.
            return .deferred
        case .leaveUntouched:
            // A held build may not prove a payment to any server, and a build whose `sg_config` has
            // no product ids cannot classify anything. Finishing — or enqueuing — here would destroy
            // or rewrite a real purchase over a missing config value. Leave it untouched; it is
            // redelivered until an Apple-enabled build reads it.
            SGLogger.shared.log("SGIAP", isAppleHeld ? "Apple backend held; leaving transaction \(transaction.id) untouched" : "No product ids configured; leaving transaction \(transaction.id) untouched")
            return .deferred
        case .finishUnlisted:
            // A product id this build no longer sells. There is nothing to attach and nothing to
            // lose, and leaving it unfinished would have StoreKit redeliver it on every launch.
            await transaction.finish()
            return .ignored
        case .finishRevoked:
            // A refund. There is no payment left to prove: Apple's own `REFUND` notification is what
            // the server acts on, and it is authoritative. Finishing it stops the redelivery loop;
            // the snapshot refresh below is what actually removes the local unlock.
            SGLogger.shared.log("SGIAP", "Transaction \(transaction.id) was revoked at \(transaction.revocationDate.map { "\($0)" } ?? "?")")
            self.snapshots.recordRevocation(
                transactionId: transaction.id,
                expirationDate: transaction.expirationDate,
                retainedExpirationDate: SGEntitlement.shared.storeKitFallback?.expirationDate
            )
            SGEntitlement.shared.outbox.remove(id: String(transaction.id))
            await transaction.finish()
            return .ignored
        case .attach:
            break
        }
        let entry = SGEntitlement.shared.outbox.enqueue(signedTransaction: jws, transactionId: String(transaction.id), accountPeerId: accountPeerId)
        // `enqueue` returns the EXISTING entry for a transaction we already know, so this is also the
        // path a REDELIVERY takes — and an unfinished transaction is redelivered through
        // `Transaction.updates` on every cold launch, forever. Without these two gates that would
        // fire a fresh `POST /apple/attach` each launch: past a stuck entry ("stop retrying" is what
        // stuck MEANS: `apple_environment_mismatch` can never succeed here), and straight through the
        // exponential backoff of a transient failure. `drainOutbox` already encodes both in
        // `dueEntries()`; this path has to honour the same answer.
        if entry.isStuck {
            return .needsHelp
        }
        if let next = entry.nextAttemptAt, next > Date() {
            return .deferred
        }
        return await self.deliver(entry, finish: {
            await transaction.finish()
        })
    }

    /// `POST /v1/apple/attach` for one outbox entry.
    ///
    /// `finish` is nil when the drain no longer holds the `Transaction` object — the attach still
    /// has to happen, and StoreKit will redeliver the unfinished transaction so it can be finished
    /// on the next pass.
    private func deliver(_ entry: SGEntitlementOutboxEntry, finish: (() async -> Void)?) async -> SGIAPAttachOutcome {
        let outcome = await self.deliveries.deliver(id: entry.id, operation: {
            await self.deliverOnce(transactionId: entry.id)
        })
        if outcome == .attached {
            // A duplicate can enqueue again during the gap between the first attach's removal and
            // its StoreKit finish. The coordinator remembers the 2xx, so remove that duplicate too.
            SGEntitlement.shared.outbox.remove(id: entry.id)
            await finish?()
        }
        return outcome
    }

    private func deliverOnce(transactionId: String) async -> SGIAPAttachOutcome {
        let entitlement = SGEntitlement.shared
        // Held: never sent, removed or finished, whatever client exists — checked before the entry
        // is even read, at the actual delivery boundary every path (ingest, drain, Restore) goes
        // through. Enabled but `configure(...)` has not run yet (`Transaction.updates` starts at
        // launch): kept for a later drain.
        guard case .attach = SGIAPAppleBoundary.delivery(isAppleHeld: !entitlement.isAppleBackendEnabled, hasClient: entitlement.client != nil), let client = entitlement.client else {
            return .deferred
        }
        // A drain's due list becomes stale across awaits. Re-read the durable entry at the actual
        // delivery boundary: another path may have removed it or applied backoff / a stuck flag.
        // Also leave a transaction unfinished when its enqueue could not be persisted.
        guard let entry = entitlement.outbox.entries().first(where: { $0.id == transactionId }) else {
            return .deferred
        }
        if entry.isStuck {
            return .needsHelp
        }
        if let next = entry.nextAttemptAt, next > Date() {
            return .deferred
        }
        // The entry's own account, never the active one, and that account's session captured ONCE
        // for this attempt: presented, then the only session the answer may touch. If the account
        // has been logged out since, it has no session: attach unbound and let the server resolve
        // the owner from the transaction, rather than borrow another account's binding.
        let credential = entry.accountPeerId.flatMap { entitlement.sessionCredential(accountPeerId: $0) }
        let result = await client.appleAttach(credential: credential, signedTransaction: entry.signedTransaction, idempotencyKey: entry.idempotencyKey)
        switch result {
        case let .success(attach):
            // `granted: false` means this exact transaction had already been applied. That is a
            // success — it is the idempotent replay we asked for.
            SGLogger.shared.log("SGIAP", "Attached \(entry.id) (granted: \(attach.granted))")
            // P7: what the server just said about the original's owner. Recorded before the entry is
            // removed and the transaction finished; a response naming another transaction is ignored.
            entitlement.recordAppleAttach(
                presentedTransactionId: entry.id,
                transactionId: attach.transaction?.transactionId,
                originalTransactionId: attach.transaction?.originalTransactionId,
                environment: attach.transaction?.environment,
                accountId: attach.account?.id,
                linkedTelegram: attach.account?.linkedTelegram,
                boundAccountPeerId: credential?.accountPeerId
            )
            entitlement.outbox.remove(id: entry.id)
            if let jws = attach.entitlement, let credential {
                // A bound attach mints a fresh JWS. Adopt it now instead of waiting for the next
                // refresh, so Pro is live the moment the sheet dismisses. An UNBOUND attach returns
                // null here, and the StoreKit snapshot carries the user until they link Telegram.
                // `adopt` refuses it if that session was logged out or re-bound meanwhile.
                entitlement.adopt(entitlement: jws, credential: credential)
            }
            return .attached
        case let .failure(error):
            SGLogger.shared.log("SGIAP", "Attach of \(entry.id) failed: \(error.failure)")
            entitlement.outbox.recordFailure(id: entry.id, failure: error.failure, retryAfter: error.retryAfter.map({ TimeInterval($0) }))
            if let credential {
                // Session consequences only: `apply` can drop a refresh token, never the cached JWS
                // and never a capability — and only that session's.
                entitlement.apply(error, credential: credential)
                if case .refused(.appleSubscriptionConflict) = error.failure {
                    // Another Telegram account owns this original. Left `unresolved`, the receipt
                    // would grant this account (and every other) from the StoreKit snapshot.
                    entitlement.recordAppleAttachConflict(signedTransaction: entry.signedTransaction, accountPeerId: credential.accountPeerId)
                }
            }
            // The outbox already owns the "will another try help?" decision, so read it back rather
            // than re-deriving it here and risking the two disagreeing.
            let isStuck = entitlement.outbox.entries().first(where: { $0.id == entry.id })?.isStuck ?? false
            return isStuck ? .needsHelp : .deferred
        }
    }

    /// Retry every attach whose backoff has elapsed.
    ///
    /// A call made while a drain is running asks that drain for one more pass (the running pass's
    /// due list predates the call) and returns only after that pass has finished
    /// (`SGIAPDrainRunner`). Restore relies on this: it reports after the entries it made retryable
    /// were tried.
    func drainOutbox() async {
        await self.drains.drain({
            await self.drainPass()
        })
    }

    private func drainPass() async {
        // Held: the outbox is neither read for delivery nor drained, and no unfinished transaction is
        // enumerated or finished.
        guard SGEntitlement.shared.isAppleBackendEnabled else {
            return
        }
        let due = SGEntitlement.shared.outbox.dueEntries()
        guard !due.isEmpty else {
            return
        }
        // `Transaction.unfinished` is how a drain gets the `Transaction` back: the outbox persists
        // the signed JWS, which is all the server needs, but only the live object can be finished.
        var unfinished: [String: Transaction] = [:]
        for await result in Transaction.unfinished {
            guard case let .verified(transaction) = result else {
                continue
            }
            unfinished[String(transaction.id)] = transaction
        }
        for entry in due {
            if let transaction = unfinished[entry.id] {
                if transaction.revocationDate != nil {
                    _ = await self.ingest(transaction, jws: entry.signedTransaction, accountPeerId: entry.accountPeerId)
                    continue
                }
                _ = await self.deliver(entry, finish: {
                    await transaction.finish()
                })
            } else {
                _ = await self.deliver(entry, finish: nil)
            }
        }
        await self.refreshSnapshot()
    }

    /// Recomputes `SGEntitlementStoreKitSnapshot` from `Transaction.currentEntitlements` and hands it
    /// to `SGEntitlement`.
    ///
    /// This is the client-side rule the server does not state: an IAP made before any Telegram link
    /// gets `entitlement: null` from `/v1/apple/attach`, so without this the paying user would hold
    /// no token at all and sit in degraded mode — which invariant I2 forbids. `currentEntitlements`
    /// is StoreKit-cached and works offline, and `SGEntitlement` persists the snapshot, so it is
    /// live at the next cold launch before StoreKit has answered anything.
    func refreshSnapshot() async {
        // Held: StoreKit is not read and the cached snapshot's bytes stay exactly as they are.
        guard SGEntitlement.shared.isAppleBackendEnabled else {
            return
        }
        let generation = self.snapshots.beginRefresh()
        let now = SGEntitlement.shared.entitlementClock.effectiveNow()
        var hasActiveSubscription = false
        var latestExpiry: Date?
        // P7 snapshot v2: each contributing transaction, identified, so a server revocation or an
        // owner can be matched to exactly one receipt instead of the whole aggregate.
        var receipts: [SGEntitlementStoreKitReceipt] = []
        // "SAW NOTHING" IS NOT "SAW NOTHING ACTIVE".
        //
        // `currentEntitlements` yields nothing at all when StoreKit cannot answer — a cold launch
        // with no App Store connection, a Sandbox hiccup, an account being re-authenticated. That
        // is indistinguishable, in the loop below, from a user who genuinely has no subscription,
        // and publishing `false` for it OVERWRITES a good snapshot: an unbound Apple purchaser
        // drops to "Link your Telegram account" while holding a live subscription, which is
        // precisely what this snapshot exists to prevent (invariant I2). So an empty pass is
        // recorded as a non-answer and the previous snapshot is kept.
        var observedAnyOfOurs = false
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else {
                continue
            }
            guard SG_CONFIG.iaps.contains(transaction.productID), !sgIAPRoutedProductIds.contains(transaction.productID) else {
                continue
            }
            observedAnyOfOurs = true
            guard transaction.revocationDate == nil, !self.snapshots.isRevoked(transactionId: transaction.id) else {
                continue
            }
            if let expiry = transaction.expirationDate {
                // A period that ended while the app was closed has most likely renewed server-side
                // and not synced yet: keep it through the same allowance the evaluator applies, or a
                // stale `currentEntitlements` at the next launch would rewrite the snapshot as
                // inactive and hide what the user is paying for (`SGEntitlementStoreKitSnapshot.renewalAllowance`).
                if expiry.addingTimeInterval(SGEntitlementStoreKitSnapshot.renewalAllowance) <= now {
                    continue
                }
                latestExpiry = max(latestExpiry ?? expiry, expiry)
            }
            hasActiveSubscription = true
            receipts.append(SGEntitlementStoreKitReceipt(
                transactionId: String(transaction.id),
                originalTransactionId: String(transaction.originalID),
                environment: SGIAPStoreKitEngine.environment(ofSignedTransaction: result.jwsRepresentation) ?? "",
                expirationDate: transaction.expirationDate
            ))
        }
        let preservesPreviousOnEmpty = self.snapshots.preservesPreviousOnEmpty
        guard self.snapshots.completeRefresh(generation) else {
            return
        }
        if preservesPreviousOnEmpty, !observedAnyOfOurs, let previous = SGEntitlement.shared.storeKitFallback, previous.hasActiveSubscription {
            // Nothing of ours came back, and we previously knew better. Keep the old snapshot
            // unless it has run past even the renewal allowance, at which point it is no longer
            // evidence of anything.
            let stillPlausible = previous.expirationDate.map {
                $0.addingTimeInterval(SGEntitlementStoreKitSnapshot.renewalAllowance) > now
            } ?? true

            if stillPlausible {
                return
            }
        }

        SGEntitlement.shared.updateStoreKitFallback(SGEntitlementStoreKitSnapshot(hasActiveSubscription: hasActiveSubscription, expirationDate: latestExpiry, receipts: receipts))
    }

    // MARK: - Helpers

    /// The `environment` field of a StoreKit-verified transaction JWS ("Production", "Sandbox",
    /// "Xcode", …). Read from the signed payload StoreKit already verified, because
    /// `Transaction.environment` is iOS 16+ and its iOS 15 string form is deprecated. nil when the
    /// payload cannot be read — the receipt then matches no tombstone and no owner (`unresolved`).
    static func environment(ofSignedTransaction jws: String) -> String? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let environment = object["environment"] as? String, !environment.isEmpty
        else {
            return nil
        }
        return environment
    }

    private static func preferredStatus(_ statuses: [Product.SubscriptionInfo.Status]) -> Product.SubscriptionInfo.Status? {
        // A Family Sharing member and the purchaser can both appear here. Prefer the one that is
        // actually granting access, then the one that still might, then anything at all.
        for state in [Product.SubscriptionInfo.RenewalState.subscribed, .inGracePeriod, .inBillingRetryPeriod] {
            if let match = statuses.first(where: { $0.state == state }) {
                return match
            }
        }
        return statuses.first
    }

    private static func state(for renewalState: Product.SubscriptionInfo.RenewalState) -> SGIAPSubscriptionStatus.State {
        switch renewalState {
        case .subscribed:
            return .subscribed
        case .expired:
            return .expired
        case .inBillingRetryPeriod:
            return .inBillingRetry
        case .inGracePeriod:
            return .inGracePeriod
        case .revoked:
            return .revoked
        default:
            return .unknown
        }
    }

    private static func describe(_ product: Product) async -> SGIAPProduct {
        var period: SGIAPPeriod?
        var subscriptionGroupId: String?
        var introductoryOffer: SGIAPIntroductoryOffer?
        var isEligibleForIntroOffer = false
        if let subscription = product.subscription {
            period = SGIAPPeriod(subscription.subscriptionPeriod)
            subscriptionGroupId = subscription.subscriptionGroupID
            if let offer = subscription.introductoryOffer, let offerPeriod = SGIAPPeriod(offer.period) {
                introductoryOffer = SGIAPIntroductoryOffer(
                    paymentMode: SGIAPStoreKitEngine.paymentMode(for: offer.paymentMode),
                    displayPrice: offer.displayPrice,
                    period: offerPeriod,
                    periodCount: offer.periodCount
                )
            }
            // Apple's answer for THIS Apple ID, per subscription group. It is the only thing the
            // trial COPY may be driven by (§5.6) — our own ledger is a separate question.
            isEligibleForIntroOffer = await subscription.isEligibleForIntroOffer
        }
        var displayPricePerMonth: String?
        if let months = period?.months, months > 0 {
            if months == 1 {
                displayPricePerMonth = product.displayPrice
            } else {
                displayPricePerMonth = (product.price / Decimal(months)).formatted(product.priceFormatStyle)
            }
        }
        return SGIAPProduct(
            id: product.id,
            displayName: product.displayName,
            productDescription: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            period: period,
            subscriptionGroupId: subscriptionGroupId,
            introductoryOffer: introductoryOffer,
            isEligibleForIntroOffer: isEligibleForIntroOffer,
            displayPricePerMonth: displayPricePerMonth
        )
    }

    private static func paymentMode(for mode: Product.SubscriptionOffer.PaymentMode) -> SGIAPIntroductoryOffer.PaymentMode {
        switch mode {
        case .freeTrial:
            return .freeTrial
        case .payAsYouGo:
            return .payAsYouGo
        case .payUpFront:
            return .payUpFront
        default:
            // A mode this build has never heard of is rendered as a plain discount, never as a free
            // trial: promising free days we cannot confirm is the one wrong answer here.
            return .unknown
        }
    }

    /// StoreKit's errors, mapped to copy. Everything that might work later says so; nothing here
    /// ever reads as "your subscription ended", because none of it is about the subscription.
    static func message(for error: Error) -> SGIAPMessage {
        if let storeKitError = error as? StoreKitError {
            // A plain `default` rather than `@unknown default`: several cases (`notEntitled`,
            // `unsupported`) exist only above this module's deployment target, so enumerating them
            // would not compile at iOS 15.0 and omitting them under `@unknown default` would warn.
            if #available(iOS 15.4, *), case .notEntitled = storeKitError {
                return .paymentsUnavailable
            }
            switch storeKitError {
            case .networkError:
                return .noConnection
            case .notAvailableInStorefront:
                return .productsUnavailable
            default:
                return .temporarilyUnavailable
            }
        }
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable:
                return .productsUnavailable
            case .purchaseNotAllowed:
                return .paymentsUnavailable
            default:
                // Every remaining case is an offer / quantity bug on our side, or one that only
                // exists on a newer SDK. None of them is the user's problem and none is the
                // subscription's, so none may read as "your subscription ended".
                return .temporarilyUnavailable
            }
        }
        if error is URLError {
            return .noConnection
        }
        return .temporarilyUnavailable
    }
}

@available(iOS 15.0, *)
private extension SGIAPPeriod {
    init?(_ period: Product.SubscriptionPeriod) {
        let unit: Unit
        switch period.unit {
        case .day:
            unit = .day
        case .week:
            unit = .week
        case .month:
            unit = .month
        case .year:
            unit = .year
        @unknown default:
            return nil
        }
        self.init(unit: unit, value: period.value)
    }
}

/// One subscription-status query's result (`SGIAPStoreKitEngine.subscriptionStatus()`).
enum SGIAPSubscriptionStatusAnswer {
    /// StoreKit answered; nil means nothing of ours is in the group.
    case answered(SGIAPSubscriptionStatus?)
    /// Not known: no products loaded (no group id), or the query failed. Never "not subscribed".
    case unavailable
}
