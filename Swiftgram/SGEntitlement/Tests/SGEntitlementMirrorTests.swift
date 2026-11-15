import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementMirrorTests: XCTestCase {
    private let iat: Int64 = 1790000000

    override func setUp() {
        super.setUp()
        // The verifier caches keys by `kid`; every test here mints with a fresh key under one kid.
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func mirror(capabilities: [String], until: Int64?, exp: Int64?, source: SGEntitlementSource = .token) -> SGEntitlementMirror {
        return SGEntitlementMirror(
            capabilities: capabilities,
            until: until,
            exp: exp,
            graceDays: 14,
            source: source.rawValue,
            degradedReason: capabilities.isEmpty ? SGEntitlementDegradedReason.lapsed.rawValue : nil,
            updatedAt: self.iat
        )
    }

    private func date(_ unix: Int64) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    func test_theMirrorReDecidesTheSameRuleWithoutTheToken() {
        let value = self.mirror(capabilities: ["vault", "chatlock"], until: self.iat + 30 * 86400, exp: self.iat + 72 * 3600)
        XCTAssertEqual(value.state(now: self.date(self.iat + 60)), .unlocked(capabilities: ["vault", "chatlock"]))
        XCTAssertEqual(value.state(now: self.date(self.iat + 18 * 86400)), .degraded(reason: .stale))
        XCTAssertEqual(value.state(now: self.date(self.iat + 400 * 86400)), .degraded(reason: .lapsed))
    }

    func test_aStoreKitSourcedMirrorMayHaveNoHorizon() {
        let value = self.mirror(capabilities: ["vault"], until: nil, exp: nil, source: .storeKit)
        XCTAssertTrue(value.state(now: self.date(self.iat)).isUnlocked)
    }

    func test_aTokenSourcedMirrorWithNoUntilIsALapse() {
        let value = self.mirror(capabilities: ["vault"], until: nil, exp: self.iat + 72 * 3600)
        XCTAssertEqual(value.state(now: self.date(self.iat)), .degraded(reason: .lapsed))
    }

    func test_anEmptyMirrorIsDegraded_whichCallersMustReadAsUnknownNotAsUnsubscribed() {
        let value = self.mirror(capabilities: [], until: nil, exp: nil)
        XCTAssertFalse(value.state(now: self.date(self.iat)).isUnlocked)
    }

    func test_aLocalGraceSourcedMirrorRevealsUntilTheWindowCloses_thenReadsAsNeverSubscribed() {
        // The main app mirrors the grace's own end as `until`, with no token horizon, so the
        // Notification Service Extension stops on the same second the app does.
        let graceEnd = self.iat + 7 * 86400
        let value = SGEntitlementMirror(
            capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: graceEnd, exp: nil, graceDays: 14,
            source: SGEntitlementSource.localGrace.rawValue, degradedReason: nil, updatedAt: self.iat
        )
        XCTAssertTrue(value.state(now: self.date(graceEnd - 1)).has(.editHistory))
        XCTAssertEqual(value.state(now: self.date(graceEnd)), .degraded(reason: .noToken), "a closed grace is 'never subscribed', not 'your subscription ended'")
    }

    func test_theMirroredGraceEndsWhereTheSignedLengthPutsIt_andAZeroDayGraceMirrorsAsNotActive() {
        // The extensions never read the policy for this: they get the decision the app made under
        // it, with the grace's own end — its start plus the accepted policy's `local_grace_days`.
        let base = Set(SGEntitlementCapability.base.map { $0.rawValue })
        let start = self.date(self.iat)
        let record = SGEntitlementLocalGrace(firstLaunchAt: self.date(self.iat - 60 * 86400)).rebased(firstPaidPolicyAt: start)
        let now = self.date(self.iat + 3600)
        func graceMirror(days: Int) -> SGEntitlementMirror {
            let grace = record.lasting(days: days)
            let decision = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]), now: now, enforcement: .enforcing, localGrace: grace, monetization: .paid)
            return SGEntitlement.composeMirror(decision: decision, localGrace: grace, storeKitExpiry: nil, deviceWide: SGEntitlementDeviceWideDecision(capabilities: decision.state.capabilities, validUntil: decision.validUntil), withheldDecision: decision, withheldDeviceWide: nil, updatedAt: self.iat)
        }
        for days in [1, 7, 30] {
            let value = graceMirror(days: days)
            let end = self.iat + Int64(days) * 86400
            XCTAssertEqual(value.source, SGEntitlementSource.localGrace.rawValue)
            XCTAssertEqual(value.until, end, "\(days) day(s): the mirror carries start + L x 86 400 s")
            XCTAssertNil(value.exp)
            XCTAssertEqual(value.state(now: now), .unlocked(capabilities: base))
            XCTAssertEqual(value.state(now: self.date(end - 1)), .unlocked(capabilities: base))
            XCTAssertEqual(value.state(now: self.date(end)), .degraded(reason: .noToken), "the extension stops on the second the app does")
            XCTAssertEqual(value.state(now: self.date(end - 1), isLedgerReadable: false), .unlocked(capabilities: base), "the grace does not come from StoreKit")
        }
        // 0 days: the app's decision is "not active", and that is what the extensions are handed —
        // no window, no horizon, the same reason as an install whose grace has ended.
        let none = graceMirror(days: 0)
        XCTAssertEqual(none.capabilities, [])
        XCTAssertNil(none.until)
        XCTAssertEqual(none.source, SGEntitlementSource.none.rawValue)
        XCTAssertEqual(none.degradedReason, SGEntitlementDegradedReason.noToken.rawValue)
        for at in [start, now, self.date(self.iat + 400 * 86400)] {
            XCTAssertEqual(none.state(now: at), .degraded(reason: .noToken))
            XCTAssertEqual(none.state(now: at, isLedgerReadable: false), .degraded(reason: .noToken))
        }
        XCTAssertEqual(SGEntitlementMirrorStore.retainedHistoryCaptureBlockedFlag(mirror: none, storedLedger: nil, now: now, enforcement: .enforcing), true, "new capture stops in the extension's replay too")
        XCTAssertEqual(SGEntitlementMirrorStore.retainedHistoryCaptureBlockedFlag(mirror: graceMirror(days: 7), storedLedger: nil, now: now, enforcement: .enforcing), false)
    }

    func test_aFreeModeMirrorUnlocksTheExtensionsWithNoHorizon() {
        // The app decided free access: the Notification Service Extension must reveal exactly what
        // the app reveals, and never self-expire it while the app is not running.
        let base = Set(SGEntitlementCapability.base.map { $0.rawValue })
        let free = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]), now: self.date(self.iat), enforcement: .enforcing, localGrace: nil, monetization: .free)
        let mirror = SGEntitlement.composeMirror(decision: free, localGrace: nil, storeKitExpiry: nil, deviceWide: nil, withheldDecision: free, withheldDeviceWide: nil, updatedAt: self.iat)
        XCTAssertEqual(mirror.source, SGEntitlementSource.freeAccess.rawValue)
        XCTAssertNil(mirror.until)
        XCTAssertNil(mirror.exp)
        XCTAssertEqual(mirror.state(now: self.date(self.iat + 10 * 365 * 86400)), .unlocked(capabilities: base))
        XCTAssertEqual(mirror.state(now: self.date(self.iat), isLedgerReadable: false), .unlocked(capabilities: base), "free access does not come from StoreKit, so withholding StoreKit changes nothing")
        XCTAssertFalse(mirror.state(now: self.date(self.iat)).has(.ai))
    }

    func test_aFreeModeMirrorDoesNotInheritAGenuineTokensHorizon() {
        let key = P256.Signing.PrivateKey()
        let pinned = SGEntitlementTestToken.pinned(key, kid: "k2026a")
        let jws = SGEntitlementTestToken.make(key: key, payload: SGEntitlementTestToken.claims(until: "2030-01-01T00:00:00Z", iat: self.iat, exp: self.iat + 72 * 3600))
        let cached = SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R")
        let free = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: pinned, now: self.date(self.iat + 60), enforcement: .enforcing, localGrace: nil, monetization: .free)
        let mirror = SGEntitlement.composeMirror(decision: free, localGrace: nil, storeKitExpiry: nil, deviceWide: nil, withheldDecision: free, withheldDeviceWide: nil, updatedAt: self.iat)
        XCTAssertTrue(mirror.state(now: self.date(self.iat + 30 * 86400)).has(.editHistory), "the token going stale does not end free access in the extension")
    }

    func test_aFreeModeMirrorRoundTripsThroughTheAppGroupEncoding() throws {
        let mirror = SGEntitlementMirror(capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: nil, exp: nil, graceDays: 14, source: SGEntitlementSource.freeAccess.rawValue, degradedReason: nil, updatedAt: self.iat)
        let decoded = try JSONDecoder().decode(SGEntitlementMirror.self, from: try JSONEncoder().encode(mirror))
        XCTAssertEqual(SGEntitlementMirrorStore.evaluate(mirror: decoded, storedLedger: nil, now: self.date(self.iat + 400 * 86400)).has(.tasks), true)
    }

    func test_anUnconfiguredBuildsMirrorIsUnlocked_notLapsed() {
        // A build with no pinned key and no product ids cannot grant, so it must not hide (invariant
        // I2). Its mirror carries no horizon, which the token rule would otherwise read as a lapse —
        // and the Notification Service / widget would then hide what the app itself shows.
        let value = SGEntitlementMirror(
            capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: nil, exp: nil, graceDays: 14,
            source: SGEntitlementSource.unconfigured.rawValue, degradedReason: nil, updatedAt: self.iat
        )
        XCTAssertTrue(value.state(now: self.date(self.iat + 365 * 86400)).has(.editHistory))
        XCTAssertTrue(value.state(now: self.date(self.iat)).isUnlocked)
    }

    // MARK: - The device-wide union (`SGEntitlement.composeMirror`)

    private func decision(_ state: SGEntitlementState, source: SGEntitlementSource, validUntil: Date) -> SGEntitlementEvaluator.Decision {
        return SGEntitlementEvaluator.Decision(state: state, source: source, validUntil: validUntil, claims: nil, tokenFailure: nil)
    }

    func test_theMirrorCarriesTheDeviceWideUnion_forTheDeviceGlobalCapabilities() {
        // Account A (free, in front) is degraded; account B's token grants everything until T. The
        // app reveals A's chats through the union, so the mirror the widget and the Notification
        // Service read must say so too — with B's horizon, so they stop when B does.
        let t = self.date(self.iat + 20 * 86400)
        let degraded = self.decision(.degraded(reason: .noToken), source: .none, validUntil: .distantFuture)
        let union = SGEntitlementDeviceWideDecision(capabilities: ["vault", "chatlock", "tasks", "edithistory"], validUntil: t)
        let mirror = SGEntitlement.composeMirror(decision: degraded, localGrace: nil, storeKitExpiry: nil, deviceWide: union, updatedAt: self.iat)
        XCTAssertEqual(Set(mirror.capabilities), ["chatlock", "tasks", "edithistory"], "only the device-global capabilities cross accounts; the vault stays per account")
        XCTAssertEqual(mirror.until, self.iat + 20 * 86400)
        XCTAssertNil(mirror.degradedReason)
        XCTAssertTrue(mirror.state(now: self.date(self.iat + 86400)).has(.editHistory))
        XCTAssertEqual(mirror.state(now: t), .degraded(reason: .lapsed), "B's lapse ends the union's reveal in the extensions on the same second")

        // Switching the account switcher to A must not rewrite a good mirror as degraded: the union
        // is what is written, whichever account is in front.
        let alone = SGEntitlement.composeMirror(decision: degraded, localGrace: nil, storeKitExpiry: nil, deviceWide: SGEntitlementDeviceWideDecision(capabilities: [], validUntil: .distantFuture), updatedAt: self.iat)
        XCTAssertEqual(alone.capabilities, [])
        XCTAssertEqual(alone.degradedReason, SGEntitlementDegradedReason.noToken.rawValue)
    }

    func test_theUnionNeverWidensAnUnlockedDecisionPastItsOwnHorizon_andWildcardsMapToTheDeviceGlobalSet() {
        // A holds a partial token (vault only) until T1; B holds "*" until T2 > T1.
        let t1 = self.date(self.iat + 5 * 86400)
        let t2 = self.date(self.iat + 9 * 86400)
        let partial = SGEntitlementEvaluator.Decision(
            state: .unlocked(capabilities: ["vault"]), source: .token, validUntil: t1,
            claims: nil, tokenFailure: nil
        )
        let union = SGEntitlementDeviceWideDecision(capabilities: ["vault", "*"], validUntil: t1)
        let mirror = SGEntitlement.composeMirror(decision: partial, localGrace: nil, storeKitExpiry: nil, deviceWide: union, updatedAt: self.iat)
        XCTAssertEqual(Set(mirror.capabilities), ["vault", "chatlock", "tasks", "edithistory"], "\"*\" from another account means its device-global capabilities, never \"*\" itself")
        XCTAssertEqual(mirror.until, self.iat + 5 * 86400, "the earliest horizon among the decisions that grant")
        // The active account's own "*" needs no widening at all.
        let everything = SGEntitlementEvaluator.Decision(state: .unlocked(capabilities: ["*"]), source: .token, validUntil: t2, claims: nil, tokenFailure: nil)
        XCTAssertEqual(SGEntitlement.composeMirror(decision: everything, localGrace: nil, storeKitExpiry: nil, deviceWide: union, updatedAt: self.iat).capabilities, ["*"])
    }

    func test_aStoreKitSourcedMirrorMirrorsTheEffectiveExpiry() {
        let expiry = self.date(self.iat + 30 * 86400)
        let storeKit = self.decision(.unlocked(capabilities: ["vault", "chatlock", "tasks", "edithistory"]), source: .storeKit, validUntil: expiry)
        let mirror = SGEntitlement.composeMirror(decision: storeKit, localGrace: nil, storeKitExpiry: expiry, deviceWide: nil, updatedAt: self.iat)
        XCTAssertEqual(mirror.until, self.iat + 30 * 86400)
        XCTAssertEqual(mirror.source, SGEntitlementSource.storeKit.rawValue)
    }

    func test_theMirrorRoundTrips() {
        let value = self.mirror(capabilities: ["vault", "tasks"], until: self.iat + 86400, exp: self.iat + 3600)
        let data = try! JSONEncoder().encode(value)
        XCTAssertEqual(try? JSONDecoder().decode(SGEntitlementMirror.self, from: data), value)
    }

    // MARK: - Unreadable shared Apple provenance ledger (extensions: NSE, widget, Siri)

    private let ledgerKey = P256.Signing.PrivateKey()
    private let ledgerKid = "k2026mirror"
    private let domain = "api.zenlygram.test"
    private let corruptLedger = Data("{not json".utf8)
    private var readableLedger: Data {
        var state = SGEntitlementAppleProvenanceState()
        state.recordAttach(originalTransactionId: "9000", environment: "Production", ownership: .unclaimed, domain: self.domain)
        return try! JSONEncoder().encode(state)
    }
    private var now: Date {
        return self.date(self.iat + 3600)
    }
    private var storeKit: SGEntitlementStoreKitSnapshot {
        let expiry = self.date(self.iat + 30 * 86400)
        return SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: expiry, receipts: [
            SGEntitlementStoreKitReceipt(transactionId: "2000", originalTransactionId: "1000", environment: "Production", expirationDate: expiry)
        ])
    }

    /// The app's own evaluation for one account, with the ledger readable or not — the decisions the
    /// mirror is composed from.
    private func decide(token: String? = nil, accountPeerId: Int64?, provenance: SGEntitlementAppleProvenanceState = SGEntitlementAppleProvenanceState(), localGrace: SGEntitlementLocalGrace? = nil, readable: Bool) -> SGEntitlementEvaluator.Decision {
        let cached = token.map { SGEntitlementCachedToken(jws: $0, boundDeviceId: "01JB8R", boundAccountId: nil, accountPeerId: nil) }
        return SGEntitlementEvaluator.evaluate(
            cached: cached,
            storeKit: self.storeKit,
            pinnedKeys: SGEntitlementTestToken.pinned(self.ledgerKey, kid: self.ledgerKid),
            now: self.now,
            localGrace: localGrace,
            storeKitEligibility: SGEntitlementStoreKitEligibility(provenance: provenance, domain: self.domain, accountId: nil, accountPeerId: accountPeerId, isLedgerReadable: readable),
            monetization: .paid
        )
    }

    private func compose(_ readable: SGEntitlementEvaluator.Decision, _ withheld: SGEntitlementEvaluator.Decision, union: SGEntitlementDeviceWideDecision? = nil, withheldUnion: SGEntitlementDeviceWideDecision? = nil, localGrace: SGEntitlementLocalGrace? = nil) -> SGEntitlementMirror {
        return SGEntitlement.composeMirror(decision: readable, localGrace: localGrace, storeKitExpiry: self.storeKit.effectiveExpirationDate, deviceWide: union, withheldDecision: withheld, withheldDeviceWide: withheldUnion, updatedAt: self.iat)
    }

    func test_storeKitDerivedMirror_failsClosedInExtensions_onceTheLedgerBecomesUnreadable() {
        // Written while the ledger was readable: the StoreKit receipt grants.
        let mirror = self.compose(self.decide(accountPeerId: 1, readable: true), self.decide(accountPeerId: 1, readable: false))
        XCTAssertEqual(mirror.source, SGEntitlementSource.storeKit.rawValue)
        XCTAssertTrue(SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: nil, now: self.now).has(.editHistory), "absent ledger is readable")
        XCTAssertTrue(SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: self.readableLedger, now: self.now).has(.editHistory))
        // The ledger bytes then become undecodable; the app has not recomputed or rewritten the mirror.
        let afterCorruption = SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: self.corruptLedger, now: self.now)
        XCTAssertFalse(afterCorruption.isUnlocked, "an extension kept a StoreKit-derived grant past an unreadable ledger")
        // A newer build's format is just as undecodable here, and treated the same.
        let newerFormat = Data(#"{"records":{"k":{"tombstones":{},"ownership":{"futureState":{}}}}}"#.utf8)
        XCTAssertFalse(SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: newerFormat, now: self.now).isUnlocked)
        // Persisted and read back by the extension with the withheld decision intact.
        let decoded = try! JSONDecoder().decode(SGEntitlementMirror.self, from: try! JSONEncoder().encode(mirror))
        XCTAssertEqual(decoded, mirror)
        XCTAssertFalse(SGEntitlementMirrorStore.evaluate(mirror: decoded, storedLedger: self.corruptLedger, now: self.now).isUnlocked)
    }

    func test_unreadableLedger_keepsSignedTokenAndLocalGraceGrants_inExtensions() {
        let paid = SGEntitlementTestToken.make(key: self.ledgerKey, kid: self.ledgerKid, payload: SGEntitlementTestToken.claims(until: "2030-01-01T00:00:00Z", iat: self.iat, exp: self.iat + 72 * 3600))
        let tokenWithheld = self.decide(token: paid, accountPeerId: 1, readable: false)
        XCTAssertEqual(tokenWithheld.source, .token, "premise: the signed token verifies with StoreKit withheld")
        let tokenMirror = self.compose(self.decide(token: paid, accountPeerId: 1, readable: true), tokenWithheld)
        XCTAssertEqual(tokenMirror.source, SGEntitlementSource.token.rawValue)
        let tokenState = SGEntitlementMirrorStore.evaluate(mirror: tokenMirror, storedLedger: self.corruptLedger, now: self.now)
        XCTAssertTrue(tokenState.has(.editHistory) && tokenState.has(.vault), "a valid signed token stopped granting in an extension because of the ledger")
        // The token's own horizons still apply under the withheld decision.
        XCTAssertEqual(SGEntitlementMirrorStore.evaluate(mirror: tokenMirror, storedLedger: self.corruptLedger, now: self.date(self.iat + 400 * 86400)), .degraded(reason: .stale))

        let grace = SGEntitlementLocalGrace(firstLaunchAt: self.date(self.iat))
        let graceWithheld = self.decide(accountPeerId: 1, localGrace: grace, readable: false)
        XCTAssertEqual(graceWithheld.source, .localGrace, "premise: the local grace grants with StoreKit withheld")
        let graceMirror = self.compose(self.decide(accountPeerId: 1, localGrace: grace, readable: true), graceWithheld, localGrace: grace)
        XCTAssertTrue(SGEntitlementMirrorStore.evaluate(mirror: graceMirror, storedLedger: self.corruptLedger, now: self.now).has(.editHistory), "the local grace stopped granting in an extension because of the ledger")
        XCTAssertFalse(SGEntitlementMirrorStore.evaluate(mirror: graceMirror, storedLedger: self.corruptLedger, now: grace.endsAt).isUnlocked, "the grace's own end still applies")
    }

    func test_unreadableLedger_withholdsAStoreKitDerivedDeviceWideUnion_butKeepsATokenDerivedOne() {
        // Account A owns the receipt (claimed); B is in front and holds nothing of its own. The app
        // reveals B's device-global features through A's StoreKit decision — until the ledger is
        // unreadable.
        var provenance = SGEntitlementAppleProvenanceState()
        provenance.recordAttach(originalTransactionId: "1000", environment: "Production", ownership: .fromAttach(boundAccountPeerId: 1, accountId: "01JA", linkedTelegram: true), domain: self.domain)
        let front = self.decide(accountPeerId: 2, provenance: provenance, readable: true)
        let frontWithheld = self.decide(accountPeerId: 2, provenance: provenance, readable: false)
        XCTAssertFalse(front.state.has(.vault), "premise: A's receipt does not grant B directly")
        let owner = self.decide(accountPeerId: 1, provenance: provenance, readable: true)
        let ownerWithheld = self.decide(accountPeerId: 1, provenance: provenance, readable: false)
        let union = SGEntitlementDeviceWideDecision(capabilities: front.state.capabilities.union(owner.state.capabilities), validUntil: min(front.validUntil, owner.validUntil))
        let withheldUnion = SGEntitlementDeviceWideDecision(capabilities: frontWithheld.state.capabilities.union(ownerWithheld.state.capabilities), validUntil: min(frontWithheld.validUntil, ownerWithheld.validUntil))
        let mirror = self.compose(front, frontWithheld, union: union, withheldUnion: withheldUnion)
        XCTAssertTrue(SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: self.readableLedger, now: self.now).has(.editHistory), "premise: the union reveals through A")
        XCTAssertFalse(SGEntitlementMirrorStore.evaluate(mirror: mirror, storedLedger: self.corruptLedger, now: self.now).has(.editHistory), "a StoreKit-derived union survived an unreadable ledger in an extension")

        // The same union carried by A's signed token survives.
        let paid = SGEntitlementTestToken.make(key: self.ledgerKey, kid: self.ledgerKid, payload: SGEntitlementTestToken.claims(until: "2030-01-01T00:00:00Z", iat: self.iat, exp: self.iat + 72 * 3600))
        let tokenOwner = self.decide(token: paid, accountPeerId: 1, provenance: provenance, readable: false)
        XCTAssertEqual(tokenOwner.source, .token, "premise: A's signed token verifies")
        let tokenUnion = SGEntitlementDeviceWideDecision(capabilities: frontWithheld.state.capabilities.union(tokenOwner.state.capabilities), validUntil: min(frontWithheld.validUntil, tokenOwner.validUntil))
        let tokenMirror = self.compose(front, frontWithheld, union: tokenUnion, withheldUnion: tokenUnion)
        let state = SGEntitlementMirrorStore.evaluate(mirror: tokenMirror, storedLedger: self.corruptLedger, now: self.now)
        XCTAssertTrue(state.has(.editHistory), "a token-derived device-global grant was withheld")
        XCTAssertFalse(state.has(.vault), "the vault stays per account under the withheld union too")
    }

    func test_unreadableLedger_withAMirrorFromAnOlderWriter_isUnknownNotGranting() {
        // No withheld decision mirrored (written before the field existed): the StoreKit part cannot
        // be separated, so the extension answers "unknown" — never the StoreKit grant.
        let old = self.mirror(capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: nil, exp: nil, source: .storeKit)
        XCTAssertNil(old.storeKitWithheld)
        XCTAssertTrue(SGEntitlementMirrorStore.evaluate(mirror: old, storedLedger: nil, now: self.now).isUnlocked, "readable: unchanged")
        XCTAssertEqual(SGEntitlementMirrorStore.evaluate(mirror: old, storedLedger: self.corruptLedger, now: self.now), .degraded(reason: .noToken))
        // A mirror JSON from that writer still decodes.
        let legacyJSON = #"{"v":1,"capabilities":["vault"],"until":null,"exp":null,"graceDays":14,"source":"storeKit","degradedReason":null,"updatedAt":1790000000}"#
        let decoded = try? JSONDecoder().decode(SGEntitlementMirror.self, from: Data(legacyJSON.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.storeKitWithheld)
        // No mirror at all is unknown either way.
        XCTAssertEqual(SGEntitlementMirrorStore.evaluate(mirror: nil, storedLedger: self.corruptLedger, now: self.now), .degraded(reason: .noToken))
        // Existing data is never decided by the mirror or the ledger.
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(SGEntitlement.shared.can(action))
        }
    }
}
