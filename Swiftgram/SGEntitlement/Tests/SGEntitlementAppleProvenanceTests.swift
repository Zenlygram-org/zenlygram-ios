import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — P7: the signed `apple_source` claim, the provenance ledger and the per-receipt
/// StoreKit fallback (contract 2026-10-12). Tokens are real ES256 JWS minted by the test key, so the
/// claim is exercised through the same verifier the app uses.
final class SGEntitlementAppleProvenanceTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026p7"
    private let domain = "api.zenlygram.test"
    private let issuedAt: Int64 = 1790000000
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }
    private var now: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.issuedAt + 3600))
    }
    private var future: Date {
        return self.now.addingTimeInterval(20 * 86400)
    }
    private let accountA = "01JACCOUNTA"
    private let accountB = "01JACCOUNTB"
    private let peerA: Int64 = 1001
    private let peerB: Int64 = 2002

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    // MARK: - Helpers

    private func sourceObject(original: String = "1000", environment: String = "Production", eventId: Any = "7", revoked: [(String, String)] = []) -> [String: Any] {
        return [
            "original_transaction_id": original,
            "environment": environment,
            "event_id": eventId,
            "revoked_transactions": revoked.map { ["transaction_id": $0.0, "fallback_until": $0.1] }
        ]
    }

    private func jws(sub: String? = nil, until: String? = nil, appleSource: Any?? = .none) -> String {
        var payload = SGEntitlementTestToken.claims(until: until, iat: self.issuedAt, exp: self.issuedAt + 72 * 3600)
        if let sub {
            payload["sub"] = sub
        }
        if case let .some(value) = appleSource {
            payload["apple_source"] = value ?? NSNull()
        }
        return SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: payload)
    }

    private func claims(_ jws: String) -> SGEntitlementClaims? {
        guard case let .success(claims) = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: self.pinned, boundDeviceId: "01JB8R") else {
            return nil
        }
        return claims
    }

    private func source(_ jws: String) -> SGEntitlementAppleSource? {
        guard case let .source(source)? = self.claims(jws)?.appleSource else {
            return nil
        }
        return source
    }

    private func receipt(original: String = "1000", transaction: String = "2000", environment: String = "Production", expiry: Date? = nil) -> SGEntitlementStoreKitReceipt {
        return SGEntitlementStoreKitReceipt(transactionId: transaction, originalTransactionId: original, environment: environment, expirationDate: expiry ?? self.future)
    }

    private func snapshot(_ receipts: [SGEntitlementStoreKitReceipt]?) -> SGEntitlementStoreKitSnapshot {
        let latest = receipts?.compactMap { $0.expirationDate }.max() ?? self.future
        return SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: latest, receipts: receipts)
    }

    private func evaluate(token: String? = nil, accountId: String? = nil, peer: Int64? = nil, snapshot: SGEntitlementStoreKitSnapshot?, state: SGEntitlementAppleProvenanceState) -> SGEntitlementEvaluator.Decision {
        let cached = token.map { SGEntitlementCachedToken(jws: $0, boundDeviceId: "01JB8R", boundAccountId: accountId, accountPeerId: nil) }
        return SGEntitlementEvaluator.evaluate(
            cached: cached,
            storeKit: snapshot,
            pinnedKeys: self.pinned,
            now: self.now,
            storeKitEligibility: SGEntitlementStoreKitEligibility(provenance: state, domain: self.domain, accountId: accountId, accountPeerId: peer),
            monetization: .paid
        )
    }

    /// A ledger that has seen a verified, lapsed token for account A revoking receipt 2000 of
    /// original 1000 at event 7.
    private func revokedState() -> SGEntitlementAppleProvenanceState {
        var state = SGEntitlementAppleProvenanceState()
        let token = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "7", revoked: [("2000", "2030-01-01T00:00:00Z")])))
        guard let source = self.source(token) else {
            XCTFail("valid apple_source did not decode")
            return state
        }
        state.observe(source, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        return state
    }

    // MARK: - The signed claim

    func test_claim_omittedNullAndObjectAreDistinct() {
        XCTAssertEqual(self.claims(self.jws())?.appleSource, .omitted, "omitted is legacy, not an assertion")
        XCTAssertEqual(self.claims(self.jws(appleSource: .some(nil)))?.appleSource, SGEntitlementAppleSourceClaim.none)
        let source = self.source(self.jws(appleSource: .some(self.sourceObject(eventId: "0012", revoked: [("2000", "2026-01-01T00:00:00Z")]))))
        XCTAssertEqual(source?.originalTransactionId, "1000")
        XCTAssertEqual(source?.environment, .production)
        XCTAssertEqual(source?.eventId, SGEntitlementAppleEventId("12"))
        XCTAssertEqual(source?.revokedTransactions.map { $0.transactionId }, ["2000"])
    }

    func test_claim_malformedProvenanceRejectsTheWholeToken() {
        let malformed: [[String: Any]] = [
            self.sourceObject(eventId: 7),                      // a number, not a decimal string
            self.sourceObject(eventId: "-1"),
            self.sourceObject(eventId: "7.0"),
            self.sourceObject(eventId: ""),
            self.sourceObject(environment: "Xcode"),
            self.sourceObject(original: ""),
            self.sourceObject(revoked: [("2000", "2026-01-01T05:00:00+05:00")]),   // not UTC
            self.sourceObject(revoked: [("2000", "not a date")]),
            self.sourceObject(revoked: [("", "2026-01-01T00:00:00Z")]),
            ["original_transaction_id": "1000", "environment": "Production", "event_id": "7"],   // member missing
            ["original_transaction_id": "1000", "environment": NSNull(), "event_id": "7", "revoked_transactions": []]
        ]
        for object in malformed {
            let result = SGEntitlementTokenVerifier.verify(self.jws(appleSource: .some(object)), pinnedKeys: self.pinned, boundDeviceId: "01JB8R")
            XCTAssertEqual(result, .failure(.malformed), "accepted malformed apple_source \(object)")
        }
    }

    func test_eventIdsCompareAsUnboundedDecimals() {
        XCTAssertEqual(SGEntitlementAppleEventId("007"), SGEntitlementAppleEventId("7"))
        XCTAssertLessThan(SGEntitlementAppleEventId("9")!, SGEntitlementAppleEventId("10")!)
        XCTAssertLessThan(SGEntitlementAppleEventId("18446744073709551615")!, SGEntitlementAppleEventId("18446744073709551616")!, "must not overflow UInt64")
        XCTAssertLessThan(SGEntitlementAppleEventId("99999999999999999999999")!, SGEntitlementAppleEventId("100000000000000000000000")!)
        XCTAssertNil(SGEntitlementAppleEventId("1e3"))
        XCTAssertNil(SGEntitlementAppleEventId(" 7"))
    }

    // MARK: - Evaluation

    func test_freshServerRevoke_staleMatchingReceipt_deniesCreation() {
        let lapsed = self.jws(sub: self.accountA, until: nil)
        let decision = self.evaluate(token: lapsed, accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt()]), state: self.revokedState())
        XCTAssertFalse(decision.state.isUnlocked, "a receipt the server revoked kept granting from the stale StoreKit cache")
        // Without the revocation the same receipt grants: the denial is the tombstone, not the receipt.
        let unrevoked = self.evaluate(token: lapsed, accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt()]), state: SGEntitlementAppleProvenanceState())
        XCTAssertEqual(unrevoked.source, .storeKit)
    }

    func test_unrelatedValidReceipt_andGenuineUnboundPurchase_stillGrant() {
        var state = self.revokedState()
        let unrelated = self.receipt(original: "3000", transaction: "3001")
        let decision = self.evaluate(token: self.jws(sub: self.accountA, until: nil), accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt(), unrelated]), state: state)
        XCTAssertEqual(decision.source, .storeKit, "a tombstone suppressed an unrelated receipt")

        // Bought before any Telegram link: the server said linked_telegram=false. Usable by every
        // account on the device, including one with no binding at all.
        state.recordAttach(originalTransactionId: "4000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: "01JAPPLEONLY", linkedTelegram: false), domain: self.domain)
        let unbound = self.evaluate(snapshot: self.snapshot([self.receipt(original: "4000", transaction: "4001")]), state: state)
        XCTAssertEqual(unbound.source, .storeKit)
        XCTAssertTrue(unbound.state.has(.vault))
    }

    func test_validUnrelatedPaidToken_stillGrantsOverATombstone() {
        let paid = self.jws(sub: self.accountA, until: "2030-01-01T00:00:00Z")
        let decision = self.evaluate(token: paid, accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt()]), state: self.revokedState())
        XCTAssertEqual(decision.source, .token)
    }

    func test_offlineOrServerError_keepsKnownAccess() {
        // No new token arrived (offline / 5xx): nothing is observed, and the last good state governs.
        var state = SGEntitlementAppleProvenanceState()
        let token = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "3")))
        state.observe(self.source(token)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        let decision = self.evaluate(token: token, accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt()]), state: state)
        XCTAssertEqual(decision.source, .storeKit)
        // An identityless legacy aggregate with no live contradiction keeps its finite deadline.
        let legacy = self.evaluate(snapshot: self.snapshot(nil), state: state)
        XCTAssertEqual(legacy.source, .storeKit)
        XCTAssertEqual(legacy.validUntil, self.future.addingTimeInterval(SGEntitlementStoreKitSnapshot.renewalAllowance))
    }

    func test_staleOrEqualTokenCannotClearATombstone_higherReversalRestores() {
        var state = self.revokedState()
        let stale = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "6")))
        state.observe(self.source(stale)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        XCTAssertTrue(state.isTombstoned(domain: self.domain, environment: "Production", originalTransactionId: "1000", transactionId: "2000", now: self.now), "a lower event id restored a revoked receipt")
        let equal = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "7")))
        state.observe(self.source(equal)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        XCTAssertTrue(state.isTombstoned(domain: self.domain, environment: "Production", originalTransactionId: "1000", transactionId: "2000", now: self.now), "an equal event id cleared a live tombstone")

        let reversal = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "8")))
        state.observe(self.source(reversal)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        let decision = self.evaluate(token: reversal, accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt()]), state: state)
        XCTAssertEqual(decision.source, .storeKit, "an authoritative reversal did not restore the receipt")
    }

    func test_orderingIsScopedByDomainAndEnvironment() {
        var state = self.revokedState()
        // Sandbox and another backend are separate event-id spaces: a high id there cannot clear
        // the Production tombstone for the same original id.
        let sandbox = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(environment: "Sandbox", eventId: "99")))
        state.observe(self.source(sandbox)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        let production = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "99")))
        state.observe(self.source(production)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: "other.backend.test", now: self.now)
        XCTAssertTrue(state.isTombstoned(domain: self.domain, environment: "Production", originalTransactionId: "1000", transactionId: "2000", now: self.now))
        XCTAssertFalse(state.isTombstoned(domain: self.domain, environment: "Sandbox", originalTransactionId: "1000", transactionId: "2000", now: self.now))
    }

    func test_resubscribeOnSameOriginal_withNewTransaction_grants() {
        let renewed = self.receipt(original: "1000", transaction: "2100")
        let decision = self.evaluate(token: self.jws(sub: self.accountA, until: nil), accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([renewed]), state: self.revokedState())
        XCTAssertEqual(decision.source, .storeKit, "the tombstone is per transaction, not per original")
    }

    func test_accountSwitch_isolatesTheClaimedReceipt() {
        var state = SGEntitlementAppleProvenanceState()
        state.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: self.peerA, accountId: self.accountA, linkedTelegram: true), domain: self.domain)
        let snapshot = self.snapshot([self.receipt()])
        let owner = self.evaluate(accountId: self.accountA, peer: self.peerA, snapshot: snapshot, state: state)
        XCTAssertTrue(owner.state.has(.vault))
        let other = self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state)
        XCTAssertFalse(other.state.has(.vault), "account A's App Store receipt unlocked account B's Vault")
        // Account B still reaches the install-wide features through account A's own decision, which
        // `SGEntitlement.recompute` unions (`isDeviceGlobal`) — that path is unchanged.
        XCTAssertTrue(owner.state.has(.tasks) && owner.state.has(.chatLock) && owner.state.has(.editHistory))
        // Ownership known only by server account id (anonymous attach, linked_telegram=true): the
        // session whose stored account id matches is the owner even before its peer is known.
        var byAccountId = SGEntitlementAppleProvenanceState()
        byAccountId.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: self.accountA, linkedTelegram: true), domain: self.domain)
        XCTAssertTrue(self.evaluate(accountId: self.accountA, peer: self.peerA, snapshot: snapshot, state: byAccountId).state.has(.vault))
        XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: byAccountId).state.has(.vault))
    }

    func test_logoutAnonymousReplayFailureAndConflict_cannotDemoteOwnership() {
        let claimed = SGEntitlementAppleOwnership.claimed(accountId: self.accountA, accountPeerId: self.peerA)
        XCTAssertEqual(SGEntitlementAppleOwnership.merged(current: claimed, observed: .unclaimed), claimed, "anonymous replay demoted a claimed receipt")
        XCTAssertEqual(SGEntitlementAppleOwnership.merged(current: claimed, observed: .unresolved), claimed, "a failure / 409 demoted a claimed receipt")
        XCTAssertEqual(SGEntitlementAppleOwnership.fromAttach(boundAccountPeerId: nil, accountId: nil, linkedTelegram: nil), .unresolved)
        XCTAssertEqual(SGEntitlementAppleOwnership.fromAttach(boundAccountPeerId: nil, accountId: self.accountA, linkedTelegram: nil), .unresolved, "a missing linked_telegram is not proof of unclaimed")
        // The peer learnt later is kept when the same owner is re-observed without one.
        XCTAssertEqual(SGEntitlementAppleOwnership.merged(current: claimed, observed: .claimed(accountId: self.accountA, accountPeerId: nil)), claimed)
        // Unclaimed becomes claimed once the server positively names an owner (a bind merged it).
        XCTAssertEqual(SGEntitlementAppleOwnership.merged(current: .unclaimed, observed: claimed), claimed)

        // A verified token's ownership survives logout: the state is per install, not per session.
        var state = SGEntitlementAppleProvenanceState()
        let token = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "4")))
        state.observe(self.source(token)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        state.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: "01JAPPLEONLY", linkedTelegram: false), domain: self.domain)
        XCTAssertEqual(state.ownership(domain: self.domain, environment: "Production", originalTransactionId: "1000"), claimed)

        // Persisted and reloaded unchanged (Codable round trip).
        let data = try! JSONEncoder().encode(state)
        XCTAssertEqual(try! JSONDecoder().decode(SGEntitlementAppleProvenanceState.self, from: data), state)
    }

    func test_legacyAggregate_cannotBypassALiveRevokeThroughAnotherAccount() {
        let state = self.revokedState()
        let legacy = self.snapshot(nil)
        XCTAssertTrue(state.hasLiveTombstone(domain: self.domain, now: self.now))
        let accounts: [(String?, Int64?)] = [(self.accountA, self.peerA), (self.accountB, self.peerB), (nil, nil)]
        for (accountId, peer) in accounts {
            let decision = self.evaluate(accountId: accountId, peer: peer, snapshot: legacy, state: state)
            XCTAssertFalse(decision.state.isUnlocked, "the identityless aggregate granted account \(String(describing: accountId)) past a live revoke")
        }
        // A positively identified unrelated receipt is still eligible under the same quarantine.
        let identified = self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: self.snapshot([self.receipt(original: "3000", transaction: "3001")]), state: state)
        XCTAssertEqual(identified.source, .storeKit)
        // The quarantine is about NEW creation only: the local grace still applies, like any lapse.
        let grace = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: legacy, pinnedKeys: self.pinned, now: self.now, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.now), storeKitEligibility: SGEntitlementStoreKitEligibility(provenance: state, domain: self.domain, accountId: nil, accountPeerId: nil), monetization: .paid)
        XCTAssertEqual(grace.source, .localGrace)
    }

    func test_expiredTombstones_doNotSuppressAnything_andArePruned() {
        var state = SGEntitlementAppleProvenanceState()
        let token = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "7", revoked: [("2000", "2026-01-01T00:00:00Z")])))
        let later = Date(timeIntervalSince1970: 1767312000) // 2026-01-02, after fallback_until
        state.observe(self.source(token)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: Date(timeIntervalSince1970: 1700000000))
        XCTAssertFalse(state.hasLiveTombstone(domain: self.domain, now: later))
        XCTAssertFalse(state.isTombstoned(domain: self.domain, environment: "Production", originalTransactionId: "1000", transactionId: "2000", now: later))
        state.prune(now: later)
        XCTAssertFalse(state.hasLiveTombstone(domain: self.domain, now: Date(timeIntervalSince1970: 1700000000)), "an expired tombstone was not pruned")
        // The event id outlives its pruned tombstones, so a stale token still cannot re-plant one.
        let stale = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "6", revoked: [("2000", "2027-01-01T00:00:00Z")])))
        state.observe(self.source(stale)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: later)
        XCTAssertFalse(state.hasLiveTombstone(domain: self.domain, now: later))
    }

    func test_existingDataActions_remainAvailable() {
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(SGEntitlement.shared.can(action), "\(action) must never be gated")
        }
    }

    func test_legacySnapshotBlob_decodesAsIdentityless() {
        let legacyJSON = #"{"hasActiveSubscription":true,"expirationDate":800000000,"observedAt":790000000}"#
        let decoded = try? JSONDecoder().decode(SGEntitlementStoreKitSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.receipts)
    }

    // MARK: - Integrated review (2026-10-12): unknown environment, conflicts, unreadable ledger

    func test_unknownReceiptEnvironment_isCheckedUnderBoth_andEitherDenialDenies() {
        // Production tombstone for 1000/2000 (revokedState). A receipt whose environment could not be
        // read ("") or is not a ledger environment ("Xcode") must not slip past it.
        for environment in ["", "Xcode", "production"] {
            let decision = self.evaluate(token: self.jws(sub: self.accountA, until: nil), accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt(environment: environment)]), state: self.revokedState())
            XCTAssertFalse(decision.state.isUnlocked, "a receipt with environment \"\(environment)\" bypassed a live Production revocation")
        }
        // Another account's claim recorded under Sandbox denies B for an unreadable environment too.
        var claimed = SGEntitlementAppleProvenanceState()
        claimed.recordAttach(originalTransactionId: "1000", environment: "Sandbox", ownership: .fromAttach(boundAccountPeerId: self.peerA, accountId: self.accountA, linkedTelegram: true), domain: self.domain)
        let other = self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: self.snapshot([self.receipt(environment: "")]), state: claimed)
        XCTAssertFalse(other.state.has(.vault), "an unreadable environment let account A's claimed receipt unlock account B")
        XCTAssertTrue(self.evaluate(accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt(environment: "")]), state: claimed).state.has(.vault), "the owner lost its own receipt")
        // Exact environments keep their own scope: a Sandbox receipt is not a Production tombstone.
        let sandbox = self.evaluate(token: self.jws(sub: self.accountA, until: nil), accountId: self.accountA, peer: self.peerA, snapshot: self.snapshot([self.receipt(environment: "Sandbox")]), state: self.revokedState())
        XCTAssertEqual(sandbox.source, .storeKit)
        // Nothing recorded anywhere: an unreadable environment still grants (unbound purchases, I2).
        XCTAssertEqual(self.evaluate(snapshot: self.snapshot([self.receipt(environment: "")]), state: SGEntitlementAppleProvenanceState()).source, .storeKit)
    }

    func test_boundAttachConflict_neverGrantsTheLosingAccount_untilTheServerNamesItOwner() {
        var state = SGEntitlementAppleProvenanceState()
        let snapshot = self.snapshot([self.receipt()])
        // Before: nothing recorded, so the receipt grants B — the fail-open a 409 used to leave.
        XCTAssertTrue(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state).state.has(.vault))
        XCTAssertTrue(state.recordConflict(originalTransactionId: "1000", environment: "Production", accountPeerId: self.peerB, domain: self.domain))
        XCTAssertFalse(state.recordConflict(originalTransactionId: "1000", environment: "Production", accountPeerId: self.peerB, domain: self.domain), "a repeated conflict changed the ledger")
        XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state).state.has(.vault), "account B's 409 left A's receipt granting B")
        XCTAssertEqual(state.ownership(domain: self.domain, environment: "Production", originalTransactionId: "1000"), .unresolved, "a conflict must not invent an owner")
        XCTAssertTrue(self.evaluate(accountId: self.accountA, peer: self.peerA, snapshot: snapshot, state: state).state.has(.vault), "the conflict of B denied another account")
        // Another account becoming owner does not lift B's conflict; an anonymous replay neither.
        state.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: self.peerA, accountId: self.accountA, linkedTelegram: true), domain: self.domain)
        state.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: "01JAPPLEONLY", linkedTelegram: false), domain: self.domain)
        XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state).state.has(.vault))
        // Persisted and reloaded with the conflict.
        let data = try! JSONEncoder().encode(state)
        XCTAssertEqual(try! JSONDecoder().decode(SGEntitlementAppleProvenanceState.self, from: data), state)
        // With no held event id there is nothing to order a token against: B's token does not lift.
        let unordered = self.jws(sub: self.accountB, until: nil, appleSource: .some(self.sourceObject(eventId: "9")))
        var noHeldEvent = state
        noHeldEvent.observe(self.source(unordered)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: noHeldEvent).state.has(.vault), "an unordered token lifted a 409 conflict")
        // A's token sets the held event (8); B's strictly higher one (9) names B: lifted.
        let ownerA = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "8")))
        state.observe(self.source(ownerA)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state).state.has(.vault))
        state.observe(self.source(unordered)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        XCTAssertTrue(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: snapshot, state: state).state.has(.vault), "a newer verified statement naming B did not lift the conflict")
    }

    /// B held the original (event 5) and its bound attach then got a 409. Nothing that is not a
    /// NEW positive statement for B may lift that: the merged/retained owner is B's own old claim.
    private func conflictedB() -> SGEntitlementAppleProvenanceState {
        var state = SGEntitlementAppleProvenanceState()
        let token = self.jws(sub: self.accountB, until: nil, appleSource: .some(self.sourceObject(eventId: "5")))
        state.observe(self.source(token)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        state.recordConflict(originalTransactionId: "1000", environment: "Production", accountPeerId: self.peerB, domain: self.domain)
        return state
    }

    private func grantsB(_ state: SGEntitlementAppleProvenanceState) -> Bool {
        return self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: self.snapshot([self.receipt()]), state: state).state.has(.vault)
    }

    func test_conflict_isNotLiftedByRetainedOwnershipOrUnorderedStatements() {
        XCTAssertFalse(self.grantsB(self.conflictedB()), "baseline: the 409 must deny B")

        // Equal event id, another owner (a bind merge that did not advance event_id).
        var foreign = self.conflictedB()
        let tokenA = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "5")))
        foreign.observe(self.source(tokenA)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        XCTAssertFalse(self.grantsB(foreign), "an equal-event foreign owner lifted B's conflict through B's retained claim")

        // Anonymous replay answered unclaimed (merged ownership stays B's old claim).
        var anonymous = self.conflictedB()
        anonymous.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: "01JAPPLEONLY", linkedTelegram: false), domain: self.domain)
        XCTAssertFalse(self.grantsB(anonymous), "an anonymous unclaimed answer lifted B's conflict")

        // An unresolved answer, and an anonymous answer naming B's account id without a peer.
        var unresolved = self.conflictedB()
        unresolved.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .unresolved, domain: self.domain)
        unresolved.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: nil, accountId: self.accountB, linkedTelegram: true), domain: self.domain)
        XCTAssertFalse(self.grantsB(unresolved), "an unresolved or peerless answer lifted B's conflict")

        // B's own stale token re-delivered at the same event id (cached / in-flight response).
        var stale = self.conflictedB()
        let staleB = self.jws(sub: self.accountB, until: nil, appleSource: .some(self.sourceObject(eventId: "5")))
        stale.observe(self.source(staleB)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        let older = self.jws(sub: self.accountB, until: nil, appleSource: .some(self.sourceObject(eventId: "4")))
        stale.observe(self.source(older)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        XCTAssertFalse(self.grantsB(stale), "B's stale same-owner token undid a fresher 409")

        // Another account's successful bound attach.
        var otherBound = self.conflictedB()
        otherBound.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: self.peerA, accountId: self.accountA, linkedTelegram: true), domain: self.domain)
        XCTAssertFalse(self.grantsB(otherBound))
    }

    func test_conflict_isLiftedByANewPositiveStatementForThatAccount() {
        // B's own successful bound attach / Restore claim after the 409.
        var bound = self.conflictedB()
        bound.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: self.peerB, accountId: self.accountB, linkedTelegram: true), domain: self.domain)
        XCTAssertTrue(self.grantsB(bound), "B's own successful bound attach did not lift its conflict")
        // A verified token naming B at a strictly higher event id than the one held.
        var newer = self.conflictedB()
        let tokenB = self.jws(sub: self.accountB, until: nil, appleSource: .some(self.sourceObject(eventId: "6")))
        newer.observe(self.source(tokenB)!, ownerAccountId: self.accountB, ownerAccountPeerId: self.peerB, domain: self.domain, now: self.now)
        XCTAssertTrue(self.grantsB(newer), "a newer verified statement naming B did not lift its conflict")
        // A newer statement naming ANOTHER owner lifts nothing for B.
        var newerForeign = self.conflictedB()
        let tokenA = self.jws(sub: self.accountA, until: nil, appleSource: .some(self.sourceObject(eventId: "6")))
        newerForeign.observe(self.source(tokenA)!, ownerAccountId: self.accountA, ownerAccountPeerId: self.peerA, domain: self.domain, now: self.now)
        XCTAssertFalse(self.grantsB(newerForeign))
    }

    func test_unreadableLedger_failsClosedForStoreKitOnly() {
        let unreadable = SGEntitlementStoreKitEligibility(provenance: SGEntitlementAppleProvenanceState(), domain: self.domain, accountId: self.accountB, accountPeerId: self.peerB, isLedgerReadable: false)
        let identified = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: self.snapshot([self.receipt()]), pinnedKeys: self.pinned, now: self.now, storeKitEligibility: unreadable, monetization: .paid)
        XCTAssertNotEqual(identified.source, .storeKit, "an unreadable ledger let a StoreKit receipt grant past revocations/owners it cannot see")
        XCTAssertFalse(identified.state.has(.vault))
        let legacy = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: self.snapshot(nil), pinnedKeys: self.pinned, now: self.now, storeKitEligibility: unreadable, monetization: .paid)
        XCTAssertNotEqual(legacy.source, .storeKit, "an unreadable ledger let the legacy aggregate grant")
        // A valid signed token still grants; the local grace still applies like any lapse.
        let paid = self.jws(sub: self.accountB, until: "2030-01-01T00:00:00Z")
        let token = SGEntitlementEvaluator.evaluate(cached: SGEntitlementCachedToken(jws: paid, boundDeviceId: "01JB8R", boundAccountId: self.accountB, accountPeerId: nil), storeKit: self.snapshot([self.receipt()]), pinnedKeys: self.pinned, now: self.now, storeKitEligibility: unreadable, monetization: .paid)
        XCTAssertEqual(token.source, .token)
        let grace = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: self.snapshot([self.receipt()]), pinnedKeys: self.pinned, now: self.now, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.now), storeKitEligibility: unreadable, monetization: .paid)
        XCTAssertEqual(grace.source, .localGrace)
        // Readable (the default) is unchanged: the same receipt grants.
        let readable = SGEntitlementStoreKitEligibility(provenance: SGEntitlementAppleProvenanceState(), domain: self.domain, accountId: self.accountB, accountPeerId: self.peerB)
        XCTAssertEqual(SGEntitlementEvaluator.evaluate(cached: nil, storeKit: self.snapshot([self.receipt()]), pinnedKeys: self.pinned, now: self.now, storeKitEligibility: readable, monetization: .paid).source, .storeKit)
        // Existing data is never evaluated by any of this.
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(SGEntitlement.shared.can(action))
        }
    }

    func test_conflictWithUnreadableEnvironment_isRecordedUnderBoth() {
        var state = SGEntitlementAppleProvenanceState()
        state.recordConflict(originalTransactionId: "1000", environment: "", accountPeerId: self.peerB, domain: self.domain)
        for environment in ["Production", "Sandbox", ""] {
            XCTAssertFalse(self.evaluate(accountId: self.accountB, peer: self.peerB, snapshot: self.snapshot([self.receipt(environment: environment)]), state: state).state.has(.vault), "conflict missed under \"\(environment)\"")
        }
    }

    func test_signedTransactionFields_keyTheConflictRecord() {
        func jws(_ payload: [String: Any]) -> String {
            let body = try! JSONSerialization.data(withJSONObject: payload)
            let encoded = body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJFUzI1NiJ9.\(encoded).c2ln"
        }
        let fields = SGEntitlementAppleSignedTransactionFields(signedTransaction: jws(["originalTransactionId": "1000", "transactionId": "2000", "environment": "Sandbox"]))
        XCTAssertEqual(fields?.originalTransactionId, "1000")
        XCTAssertEqual(fields?.environment, "Sandbox")
        XCTAssertEqual(SGEntitlementAppleSignedTransactionFields(signedTransaction: jws(["originalTransactionId": "1000"]))?.environment, "", "a missing environment must read as unknown, not fail")
        XCTAssertNil(SGEntitlementAppleSignedTransactionFields(signedTransaction: jws(["environment": "Sandbox"])))
        XCTAssertNil(SGEntitlementAppleSignedTransactionFields(signedTransaction: jws(["originalTransactionId": ""])))
        XCTAssertNil(SGEntitlementAppleSignedTransactionFields(signedTransaction: "not-a-jws"))
    }

    func test_storedLedger_unreadableBytesAreNeverOverwritten_readableAndPreFieldLedgersLoad() {
        XCTAssertEqual(SGEntitlementAppleProvenanceStoredLoad(stored: nil), SGEntitlementAppleProvenanceStoredLoad(stored: nil))
        XCTAssertFalse(SGEntitlementAppleProvenanceStoredLoad(stored: nil).preservesStoredBytes, "an absent ledger is a clean start")
        // A ledger exactly as the pre-review build wrote it (no conflict field): loads, writable.
        let preField = #"{"records":{"api.zenlygram.test\nProduction\n1000":{"eventId":"7","tombstones":{"2000":915148800},"ownership":{"claimed":{"accountId":"01JACCOUNTA","accountPeerId":1001}}}}}"#
        let loaded = SGEntitlementAppleProvenanceStoredLoad(stored: Data(preField.utf8))
        XCTAssertFalse(loaded.preservesStoredBytes)
        XCTAssertTrue(loaded.initialState.isTombstoned(domain: self.domain, environment: "Production", originalTransactionId: "1000", transactionId: "2000", now: self.now))
        XCTAssertEqual(loaded.initialState.ownership(domain: self.domain, environment: "Production", originalTransactionId: "1000"), .claimed(accountId: self.accountA, accountPeerId: self.peerA))
        // Corrupt bytes, or a newer build's format this build cannot decode: never written over.
        for unreadable in ["{not json", #"{"records":{"k":{"tombstones":{},"ownership":{"futureState":{}}}}}"#] {
            let load = SGEntitlementAppleProvenanceStoredLoad(stored: Data(unreadable.utf8))
            XCTAssertTrue(load.preservesStoredBytes, "unreadable ledger \(unreadable) would be overwritten from an empty start")
            XCTAssertEqual(load.initialState, SGEntitlementAppleProvenanceState())
        }
    }
}
