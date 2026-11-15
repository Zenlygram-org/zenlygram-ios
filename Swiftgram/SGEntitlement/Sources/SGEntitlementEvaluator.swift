import Foundation

/// Zenlygram — what StoreKit knows locally about this install's App Store subscription.
///
/// `SGEntitlement` never imports StoreKit: `Transaction.currentEntitlements` is iOS 15 and `async`,
/// and the entitlement gate must be synchronous and must never await anything (client contract §8,
/// threading). `SGIAP` owns StoreKit and pushes this snapshot in through
/// `SGEntitlement.updateStoreKitFallback(_:)`; the snapshot is persisted, so it is available on the
/// next cold launch before StoreKit has answered anything.
public struct SGEntitlementStoreKitSnapshot: Codable, Equatable {
    /// True when `Transaction.currentEntitlements` held at least one `.verified` transaction whose
    /// `productID` is in `SG_CONFIG.iaps` and whose `revocationDate` is nil.
    public var hasActiveSubscription: Bool
    /// The latest `expirationDate` among those transactions; nil means "no expiry reported".
    public var expirationDate: Date?
    /// When `SGIAP` observed this. Diagnostics only — never used as a horizon.
    public var observedAt: Date

    /// How long past `expirationDate` the snapshot keeps granting.
    ///
    /// Apple renews a subscription server-side while the app is closed, and this snapshot is only
    /// refreshed when the main app next asks StoreKit — so a snapshot whose `expirationDate` has
    /// just passed is far more likely a renewed subscription the device has not synced yet than a
    /// lapse. Treating that instant as the end would hide, in the widget, in notifications and for
    /// the first moments of a cold launch, what a paying user pays to see (invariant I2). The same
    /// idea as the token's `grace_days`, sized to the days a renewal can take to reach the device;
    /// the real end of a subscription that did not renew is `effectiveExpirationDate`.
    public static let renewalAllowance: TimeInterval = 3 * 86400

    /// P7 snapshot v2: one entry per verified, unrevoked, unexpired transaction that contributed.
    /// nil is a LEGACY, identityless aggregate (written before v2, or decoded from such a blob): it
    /// keeps its finite offline deadline unless an authenticated live revocation contradicts it.
    public var receipts: [SGEntitlementStoreKitReceipt]?

    public init(hasActiveSubscription: Bool, expirationDate: Date?, observedAt: Date = Date(), receipts: [SGEntitlementStoreKitReceipt]? = nil) {
        self.hasActiveSubscription = hasActiveSubscription
        self.expirationDate = expirationDate
        self.observedAt = observedAt
        self.receipts = receipts
    }

    /// The instant this snapshot stops granting: `expirationDate + renewalAllowance`, or nil when
    /// StoreKit reported no expiry.
    public var effectiveExpirationDate: Date? {
        return self.expirationDate?.addingTimeInterval(SGEntitlementStoreKitSnapshot.renewalAllowance)
    }
}

/// Zenlygram — one App Store transaction behind a v2 StoreKit snapshot. Ownership is NOT stored
/// here: it belongs to the original and lives in `SGEntitlementAppleProvenanceState`, which survives
/// the snapshot being recomputed.
public struct SGEntitlementStoreKitReceipt: Codable, Equatable, Hashable {
    public let transactionId: String
    public let originalTransactionId: String
    /// The transaction's own `environment` ("Production", "Sandbox", or a local-testing value).
    public let environment: String
    public let expirationDate: Date?

    public init(transactionId: String, originalTransactionId: String, environment: String, expirationDate: Date?) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.environment = environment
        self.expirationDate = expirationDate
    }

    /// Same renewal allowance as the aggregate (`SGEntitlementStoreKitSnapshot.renewalAllowance`).
    public var effectiveExpirationDate: Date? {
        return self.expirationDate?.addingTimeInterval(SGEntitlementStoreKitSnapshot.renewalAllowance)
    }
}

/// A cached entitlement token plus the binding it must belong to.
public struct SGEntitlementCachedToken: Equatable {
    public let jws: String
    /// `devices.id` from `/bind/poll`. A token whose `dev` is something else is not ours.
    public let boundDeviceId: String?
    public let boundAccountId: String?
    public let accountPeerId: Int64?

    public init(jws: String, boundDeviceId: String?, boundAccountId: String? = nil, accountPeerId: Int64? = nil) {
        self.jws = jws
        self.boundDeviceId = boundDeviceId
        self.boundAccountId = boundAccountId
        self.accountPeerId = accountPeerId
    }
}

/// Zenlygram — the evaluation rule (design §4.3, client contract §5.1), under the signed
/// monetization mode (`SGEntitlementPolicy`).
///
/// FREE (every install's initial mode): the four shipped capabilities for everyone, with no
/// horizon, no countdown, never `ai` and never `"*"` — never bound, unbound and past-grace installs
/// alike. A genuine grant the account holds is still read alongside it.
///
/// PAID: the token grants only through its GENUINE account claims,
///
///     unlocked  ⟺  effectiveNow < account_until  AND  effectiveNow < exp + grace_days
///
/// with `account_ent` as the capabilities. The legacy `ent` / `until` — widened by the server for
/// old clients while free — is never paid proof. Two local rescues follow when the token does not
/// grant: the StoreKit fallback (§5.1.1) and, after it, the install's local grace
/// (`SGEntitlementLocalGrace`, re-based on the first adopted paid policy — D9 — and lasting the
/// days the accepted signed policy names; 0 days never grant), kept as the existing paid-mode
/// fallback. Precedence, highest first: genuine granting token → StoreKit
/// subscription → local grace → degraded. A null `account_until` degrades as `.noToken`, never as
/// `.lapsed` (D9; see `evaluatePaid`).
///
/// It is a pure function of (cached token, StoreKit snapshot, pinned keys, local grace, mode, now)
/// so it can be unit tested without a Keychain, a network or a device clock.
public enum SGEntitlementEvaluator {
    /// The evaluated decision plus everything the caller needs to cache it and to mirror it to the
    /// Notification Service Extension.
    public struct Decision: Equatable {
        public let state: SGEntitlementState
        public let source: SGEntitlementSource
        /// The decision holds until this instant of `effectiveNow()`. An `.unlocked` decision is
        /// re-evaluated when it crosses its own horizon; a degraded one can only change when new
        /// material arrives, which invalidates it explicitly.
        public let validUntil: Date
        /// The claims, when a token verified — including a token that verified but no longer grants
        /// anything, because the mirror and the clock mark still want them.
        public let claims: SGEntitlementClaims?
        /// Why verification failed, when it did. Never shown to the user as such.
        public let tokenFailure: SGEntitlementTokenFailure?

        public init(
            state: SGEntitlementState,
            source: SGEntitlementSource,
            validUntil: Date,
            claims: SGEntitlementClaims? = nil,
            tokenFailure: SGEntitlementTokenFailure? = nil
        ) {
            self.state = state
            self.source = source
            self.validUntil = validUntil
            self.claims = claims
            self.tokenFailure = tokenFailure
        }
    }

    public static func evaluate(
        cached: SGEntitlementCachedToken?,
        storeKit: SGEntitlementStoreKitSnapshot?,
        pinnedKeys: SGEntitlementPinnedKeys,
        now: Date,
        enforcement: SGEntitlementEnforcement = .enforcing,
        localGrace: SGEntitlementLocalGrace? = nil,
        storeKitEligibility: SGEntitlementStoreKitEligibility? = nil,
        monetization: SGEntitlementPolicyMode
    ) -> Decision {
        // A build that can neither verify a token nor recognise a purchase has no grant path at
        // all, so enforcing would paywall the four features with no way to buy them. See
        // `SGEntitlementEnforcement`.
        guard enforcement.isEnforcing else {
            return Decision(
                state: .unlocked(capabilities: Set(SGEntitlementCapability.base.map { $0.rawValue })),
                source: .unconfigured,
                validUntil: Date.distantFuture,
                claims: nil,
                tokenFailure: nil
            )
        }
        switch monetization {
        case .paid:
            return self.evaluatePaid(cached: cached, storeKit: storeKit, pinnedKeys: pinnedKeys, now: now, localGrace: localGrace, storeKitEligibility: storeKitEligibility)
        case .free:
            // The genuine decision without the local grace (free access is not a countdown), widened
            // to the shipped set. It holds until the genuine grant's own horizon, when there is
            // one, only so the next decision re-reads it; free access itself never ends here.
            let genuine = self.evaluatePaid(cached: cached, storeKit: storeKit, pinnedKeys: pinnedKeys, now: now, localGrace: nil, storeKitEligibility: storeKitEligibility)
            let base = Set(SGEntitlementCapability.base.map { $0.rawValue })
            return Decision(
                state: .unlocked(capabilities: genuine.state.capabilities.union(base)),
                source: .freeAccess,
                validUntil: genuine.state.isUnlocked ? genuine.validUntil : Date.distantFuture,
                claims: genuine.claims,
                tokenFailure: genuine.tokenFailure
            )
        }
    }

    private static func evaluatePaid(
        cached: SGEntitlementCachedToken?,
        storeKit: SGEntitlementStoreKitSnapshot?,
        pinnedKeys: SGEntitlementPinnedKeys,
        now: Date,
        localGrace: SGEntitlementLocalGrace?,
        storeKitEligibility: SGEntitlementStoreKitEligibility?
    ) -> Decision {
        guard let cached else {
            return self.fallback(storeKit: storeKit, eligibility: storeKitEligibility, localGrace: localGrace, now: now, reason: .noToken, claims: nil, tokenFailure: nil)
        }

        let verification = SGEntitlementTokenVerifier.verify(cached.jws, pinnedKeys: pinnedKeys, boundDeviceId: cached.boundDeviceId, boundAccountId: cached.boundAccountId, accountPeerId: cached.accountPeerId)
        guard case let .success(claims) = verification else {
            var failure: SGEntitlementTokenFailure?
            if case let .failure(value) = verification {
                failure = value
            }
            return self.fallback(storeKit: storeKit, eligibility: storeKitEligibility, localGrace: localGrace, now: now, reason: .unverifiable, claims: nil, tokenFailure: failure)
        }

        // Only the GENUINE grant is paid proof. A legacy token without it proves nothing, and the
        // manager asks the server for one that has it (`SGEntitlementRefreshTrigger
        // .accountClaimsMissing`); "reconnect" is the honest copy meanwhile.
        guard let grant = claims.accountGrant else {
            return self.fallback(storeKit: storeKit, eligibility: storeKitEligibility, localGrace: localGrace, now: now, reason: .stale, claims: claims, tokenFailure: nil)
        }

        // The SUBSCRIPTION horizon. A PAST `account_until` is a lapse: the token says the
        // subscription ended. A NULL one is NOT (D9): the server collapses a never-paid account and a
        // horizon already behind it to the same null (zenlypay `EntitlementService::accountHorizon`
        // answers null unless the latest candidate is still ahead of now), so from the token alone
        // the client cannot tell "never subscribed" from "ended" — and a bound account that never
        // paid must not read "your Zenlygram Pro subscription has ended". A null horizon is therefore
        // "nothing granting", `.noToken`: the offer, never the ended copy. A subscription that really
        // ended still reads as ended where that evidence lives, the StoreKit snapshot behind the
        // status screen. A present but unparseable `account_until` is a malformed grant and stays a
        // lapse, as before.
        guard let until = grant.untilDate, now < until else {
            let reason: SGEntitlementDegradedReason = grant.until == nil ? .noToken : .lapsed
            return self.fallback(storeKit: storeKit, eligibility: storeKitEligibility, localGrace: localGrace, now: now, reason: reason, claims: claims, tokenFailure: nil)
        }

        // The TOKEN horizon: how long this device may trust this piece of paper without checking in.
        let hardStop = claims.hardStopDate
        guard now < hardStop else {
            return self.fallback(storeKit: storeKit, eligibility: storeKitEligibility, localGrace: localGrace, now: now, reason: .stale, claims: claims, tokenFailure: nil)
        }

        return Decision(
            state: .unlocked(capabilities: grant.capabilities),
            source: .token,
            validUntil: min(until, hardStop),
            claims: claims,
            tokenFailure: nil
        )
    }

    /// `storeKitFallback()` — the "bought before linking Telegram" hole (client contract §5.1.1) —
    /// and, after it, the local grace.
    ///
    /// `/apple/attach` on an unbound device returns `entitlement: null`, so a user who paid before
    /// ever linking Telegram holds no JWS at all. Leaving them degraded would violate invariant I2.
    /// The fallback grants the four SHIPPED capabilities — never `"*"`, never `ai`: what the product
    /// sells, not what the server might later add.
    ///
    /// The local grace (`SGEntitlementLocalGrace`) is consulted last and grants the same four, in
    /// PAID mode only (the free mode never shows a countdown). It applies whatever the reason the
    /// token did not grant — no token, lapsed, stale, unverifiable — and past its end, or at a
    /// signed length of 0 days (`SGEntitlementLocalGrace.isActive`), it changes nothing, so the
    /// decision degrades with the reason the token produced.
    private static func fallback(
        storeKit: SGEntitlementStoreKitSnapshot?,
        eligibility: SGEntitlementStoreKitEligibility?,
        localGrace: SGEntitlementLocalGrace?,
        now: Date,
        reason: SGEntitlementDegradedReason,
        claims: SGEntitlementClaims?,
        tokenFailure: SGEntitlementTokenFailure?
    ) -> Decision {
        let capabilities = Set(SGEntitlementCapability.base.map { $0.rawValue })
        if let storeKit, storeKit.hasActiveSubscription, let horizon = self.storeKitHorizon(storeKit, eligibility: eligibility, now: now) {
            return Decision(
                state: .unlocked(capabilities: capabilities),
                source: .storeKit,
                validUntil: horizon,
                claims: claims,
                tokenFailure: tokenFailure
            )
        }
        if let localGrace, localGrace.isActive(at: now) {
            return Decision(
                state: .unlocked(capabilities: capabilities),
                source: .localGrace,
                validUntil: localGrace.endsAt,
                claims: claims,
                tokenFailure: tokenFailure
            )
        }
        return Decision(
            state: .degraded(reason: reason),
            source: .none,
            validUntil: Date.distantFuture,
            claims: claims,
            tokenFailure: tokenFailure
        )
    }

    /// When the StoreKit snapshot grants this account, the instant it stops; nil when it does not.
    ///
    /// Without `eligibility` (or for a legacy, identityless aggregate) this is the original rule: the
    /// aggregate grants until `expirationDate + renewalAllowance`. With it (P7):
    /// - a v2 receipt grants only if it is unexpired, not an exact live tombstone
    ///   (environment, original, transaction), not an original this account's bound attach was
    ///   refused for as another account's (409), and owned by this account, unclaimed or unresolved —
    ///   an environment other than exactly Production / Sandbox is checked under both;
    ///   another account's claimed receipt never grants here (Vault / AI are per account; the
    ///   install-wide features still reach other accounts through the owner's own decision in
    ///   `SGEntitlement.recompute`'s union);
    /// - a legacy aggregate is quarantined for every account while an authenticated live revocation
    ///   exists in this trust domain, because nothing identifies which receipt it stands for.
    /// Transport failures never reach here as revocations: only verified tokens write tombstones.
    /// An unreadable stored ledger (`isLedgerReadable == false`) grants nothing from StoreKit.
    static func storeKitHorizon(_ storeKit: SGEntitlementStoreKitSnapshot, eligibility: SGEntitlementStoreKitEligibility?, now: Date) -> Date? {
        guard let eligibility else {
            return self.legacyHorizon(storeKit, now: now)
        }
        guard eligibility.isLedgerReadable else {
            // The local provenance is unavailable (unreadable stored ledger): fail closed for the
            // StoreKit creation fallback rather than grant past revocations or owners it cannot see.
            return nil
        }
        guard let receipts = storeKit.receipts else {
            if eligibility.provenance.hasLiveTombstone(domain: eligibility.domain, now: now) {
                return nil
            }
            return self.legacyHorizon(storeKit, now: now)
        }
        var horizon: Date?
        for receipt in receipts {
            let effective = receipt.effectiveExpirationDate ?? Date.distantFuture
            guard now < effective else {
                continue
            }
            // An environment other than exactly Production / Sandbox is checked under both, and
            // either denying denies (`SGEntitlementAppleProvenanceState.receiptGrants`).
            guard eligibility.provenance.receiptGrants(domain: eligibility.domain, environment: receipt.environment, originalTransactionId: receipt.originalTransactionId, transactionId: receipt.transactionId, accountId: eligibility.accountId, accountPeerId: eligibility.accountPeerId, now: now) else {
                continue
            }
            horizon = max(horizon ?? effective, effective)
        }
        return horizon
    }

    private static func legacyHorizon(_ storeKit: SGEntitlementStoreKitSnapshot, now: Date) -> Date? {
        // The snapshot's own horizon includes the renewal allowance: a period that ended while the
        // app was closed has most likely renewed (`SGEntitlementStoreKitSnapshot.renewalAllowance`).
        if let expiry = storeKit.effectiveExpirationDate {
            return expiry > now ? expiry : nil
        }
        return Date.distantFuture
    }
}
