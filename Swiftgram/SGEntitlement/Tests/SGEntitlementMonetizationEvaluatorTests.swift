import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — the evaluation rule under the signed monetization mode.
///
/// Free: every install — never bound, unbound, past its local grace — gets the four shipped Pro
/// capabilities with no horizon, never `ai`, never `"*"`. Paid: only the GENUINE per-account grant
/// (`account_ent` / `account_until`, with the token's `exp + grace_days`) or the verified StoreKit
/// fallback grants; the legacy `ent` / `until`, which the server widens for old clients while free,
/// is never paid proof.
final class SGEntitlementMonetizationEvaluatorTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let iat: Int64 = 1_790_000_000
    private let base: Set<String> = Set(SGEntitlementCapability.base.map { $0.rawValue })
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func at(_ offset: TimeInterval) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(self.iat) + offset)
    }

    private func cached(
        ent: [String] = ["vault", "chatlock", "tasks", "edithistory"],
        until: String? = "2030-01-01T00:00:00Z",
        account: SGEntitlementTestToken.AccountClaims = .mirrorLegacy
    ) -> SGEntitlementCachedToken {
        let jws = SGEntitlementTestToken.make(
            key: self.key,
            kid: self.kid,
            payload: SGEntitlementTestToken.claims(ent: ent, until: until, iat: self.iat, exp: self.iat + 72 * 3600, account: account)
        )
        return SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R")
    }

    private func evaluate(
        _ mode: SGEntitlementPolicyMode,
        cached: SGEntitlementCachedToken? = nil,
        storeKit: SGEntitlementStoreKitSnapshot? = nil,
        localGrace: SGEntitlementLocalGrace? = nil,
        now: Date
    ) -> SGEntitlementEvaluator.Decision {
        return SGEntitlementEvaluator.evaluate(cached: cached, storeKit: storeKit, pinnedKeys: self.pinned, now: now, enforcement: .enforcing, localGrace: localGrace, monetization: mode)
    }

    // MARK: - Free

    func test_free_aNeverBoundInstallWithNoGraceGetsTheFourShippedCapabilities() {
        let decision = self.evaluate(.free, now: self.at(60))
        XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(decision.source, .freeAccess)
        for action in SGEntitlementGatedAction.allCases where action != .useAIAssistant {
            XCTAssertTrue(decision.state.allows(action), "\(action.rawValue) is free in free mode")
        }
        XCTAssertFalse(decision.state.allows(SGEntitlementGatedAction.useAIAssistant), "free mode is not a future AI unlock")
    }

    func test_free_anExpiredLocalGraceStillUnlocks_andTheGraceIsNotWhatGrants() {
        let expired = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400))
        let decision = self.evaluate(.free, localGrace: expired, now: self.at(0))
        XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(decision.source, .freeAccess)

        let active = SGEntitlementLocalGrace(firstLaunchAt: self.at(-86400))
        XCTAssertEqual(self.evaluate(.free, localGrace: active, now: self.at(0)).source, .freeAccess, "no 7-day countdown while free")
    }

    func test_free_neverSelfExpires() {
        let decision = self.evaluate(.free, now: self.at(0))
        XCTAssertEqual(decision.validUntil, Date.distantFuture, "free access has no horizon of its own")
        let decade = self.evaluate(.free, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.at(0)), now: self.at(10 * 365 * 86400))
        XCTAssertTrue(decade.state.isUnlocked)
    }

    func test_free_neverGrantsAIOrTheWildcard() {
        let decision = self.evaluate(.free, now: self.at(0))
        XCTAssertFalse(decision.state.has(.ai), "free access is the shipped Pro set, not a future AI unlock")
        XCTAssertFalse(decision.state.capabilities.contains(SGEntitlementCapability.wildcard))
        // Even a legacy wildcard token (what the server sends old clients while free) adds nothing.
        let wildcard = self.evaluate(.free, cached: self.cached(ent: ["*"], account: .omitted), now: self.at(60))
        XCTAssertEqual(wildcard.state, .unlocked(capabilities: self.base))
        XCTAssertFalse(wildcard.state.has(.ai))
    }

    func test_free_aLapsedOrStaleOrForeignTokenStillUnlocks() {
        XCTAssertEqual(self.evaluate(.free, cached: self.cached(ent: [], until: nil), now: self.at(60)).state, .unlocked(capabilities: self.base))
        XCTAssertEqual(self.evaluate(.free, cached: self.cached(), now: self.at(400 * 86400)).state, .unlocked(capabilities: self.base))
        let unverifiable = SGEntitlementCachedToken(jws: "not.a.token", boundDeviceId: nil)
        XCTAssertEqual(self.evaluate(.free, cached: unverifiable, now: self.at(60)).state, .unlocked(capabilities: self.base))
    }

    func test_free_aGenuineGrantIsKeptAlongsideFreeAccess() {
        let decision = self.evaluate(.free, cached: self.cached(account: .explicit(ent: ["vault", "chatlock"], until: "2030-01-01T00:00:00Z")), now: self.at(60))
        XCTAssertEqual(decision.source, .freeAccess)
        XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
        XCTAssertNotNil(decision.claims?.accountGrant, "the genuine grant is still read, for the truthful status")
    }

    // MARK: - Paid

    func test_paid_aGenuineAccountGrantUnlocksItsOwnCapabilities() {
        let decision = self.evaluate(.paid, cached: self.cached(account: .explicit(ent: ["vault", "tasks"], until: "2030-01-01T00:00:00Z")), now: self.at(60))
        XCTAssertEqual(decision.state, .unlocked(capabilities: ["vault", "tasks"]))
        XCTAssertEqual(decision.source, .token)
        XCTAssertEqual(decision.validUntil, self.at(72 * 3600 + 14 * 86400), "min(account_until, exp + grace_days)")
    }

    func test_paid_legacyClaimsAreNotPaidProof() {
        // A free-phase legacy token: `ent` widened for old clients, a far `until`, no account claims.
        let legacy = self.cached(ent: ["*"], until: "2036-01-01T00:00:00Z", account: .omitted)
        let decision = self.evaluate(.paid, cached: legacy, now: self.at(60))
        XCTAssertFalse(decision.state.isUnlocked, "synthetic legacy ent/until must not grant paid access")
        XCTAssertNotNil(decision.claims, "the token still verified; the manager asks for one with account claims")
        XCTAssertNil(decision.claims?.accountGrant)

        let shipped = self.evaluate(.paid, cached: self.cached(account: .omitted), now: self.at(60))
        XCTAssertFalse(shipped.state.isUnlocked)
    }

    func test_paid_legacyTokenFallsBackToAVerifiedStoreKitSubscription() {
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: self.at(30 * 86400))
        let decision = self.evaluate(.paid, cached: self.cached(account: .omitted), storeKit: storeKit, now: self.at(60))
        XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(decision.source, .storeKit)

        let noToken = self.evaluate(.paid, storeKit: storeKit, now: self.at(60))
        XCTAssertEqual(noToken.source, .storeKit, "paid before linking Telegram still unlocks")
    }

    func test_paid_aWildcardInTheAccountGrantGrantsNothingExtra() {
        let decision = self.evaluate(.paid, cached: self.cached(account: .explicit(ent: ["*"], until: "2030-01-01T00:00:00Z")), now: self.at(60))
        XCTAssertFalse(decision.state.has(.vault), "the wildcard never belongs in account_ent")
        XCTAssertFalse(decision.state.has(.ai))
    }

    func test_paid_aPastAccountGrantIsALapse_andANullOneIsNoToken_evenUnderAFarLegacyUntil() {
        // D9: the server collapses "never paid" and "a horizon already past" to the same null
        // `account_until`, so a null horizon is "nothing granting" — the offer, never "your
        // subscription has ended" to a bound account that never paid.
        let null = self.evaluate(.paid, cached: self.cached(ent: ["*"], until: "2036-01-01T00:00:00Z", account: .explicit(ent: [], until: nil)), now: self.at(60))
        XCTAssertEqual(null.state, .degraded(reason: .noToken))
        XCTAssertNotNil(null.claims, "the token still verified; its claims still feed the clock mark and the mirror")
        let past = self.evaluate(.paid, cached: self.cached(until: "2036-01-01T00:00:00Z", account: .explicit(ent: ["vault"], until: "2020-01-01T00:00:00Z")), now: self.at(60))
        XCTAssertEqual(past.state, .degraded(reason: .lapsed), "a date already past is what 'ended' means")
    }

    func test_paid_anUnparseableAccountUntilStaysALapse() {
        let decision = self.evaluate(.paid, cached: self.cached(account: .explicit(ent: ["vault"], until: "not-a-date")), now: self.at(60))
        XCTAssertEqual(decision.state, .degraded(reason: .lapsed), "a malformed grant is not a never-paid account; D9 changes the null case only")
    }

    func test_paid_aGenuineGrantStillHonoursExpPlusGrace() {
        let cached = self.cached()
        XCTAssertTrue(self.evaluate(.paid, cached: cached, now: self.at(16 * 86400)).state.isUnlocked)
        XCTAssertEqual(self.evaluate(.paid, cached: cached, now: self.at(18 * 86400)).state, .degraded(reason: .stale))
    }

    func test_paid_aGenuineGrantNeverIncludesAI() {
        let decision = self.evaluate(.paid, cached: self.cached(account: .explicit(ent: ["vault", "chatlock", "tasks", "edithistory", "ai"], until: "2030-01-01T00:00:00Z")), now: self.at(60))
        XCTAssertTrue(decision.state.has(.vault))
        XCTAssertFalse(decision.state.has(.ai), "ai stays refused by this build")
    }

    func test_paid_aMalformedAccountGrantIsNotAGrant() {
        var payload = SGEntitlementTestToken.claims(iat: self.iat, exp: self.iat + 72 * 3600, account: .omitted)
        payload["account_ent"] = "vault"
        payload["account_until"] = "2030-01-01T00:00:00Z"
        let jws = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: payload)
        let decision = self.evaluate(.paid, cached: SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R"), now: self.at(60))
        XCTAssertFalse(decision.state.isUnlocked)

        var onlyEnt = SGEntitlementTestToken.claims(iat: self.iat, exp: self.iat + 72 * 3600, account: .omitted)
        onlyEnt["account_ent"] = ["vault"]
        let half = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: onlyEnt)
        XCTAssertFalse(self.evaluate(.paid, cached: SGEntitlementCachedToken(jws: half, boundDeviceId: "01JB8R"), now: self.at(60)).state.isUnlocked, "both account claims are required")
    }

    func test_paid_theExistingLocalGraceRemainsOnlyAPaidModeFallback() {
        let active = SGEntitlementLocalGrace(firstLaunchAt: self.at(-86400))
        XCTAssertEqual(self.evaluate(.paid, localGrace: active, now: self.at(0)).source, .localGrace)
        let expired = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400))
        XCTAssertEqual(self.evaluate(.paid, localGrace: expired, now: self.at(0)).state, .degraded(reason: .noToken))
    }

    // MARK: - D9: the paid-mode grace is re-based on the first adopted paid policy

    func test_paid_theGraceIsRebasedOnTheFirstPaidPolicy_theLaterWindowWins() {
        // An install first launched a month ago, free all along; the owner flipped paid yesterday.
        let firstLaunch = self.at(-30 * 86400)
        let flip = self.at(-86400)
        let rebased = SGEntitlementLocalGrace(firstLaunchAt: firstLaunch).rebased(firstPaidPolicyAt: flip)
        XCTAssertEqual(rebased.firstLaunchAt, firstLaunch, "the first-launch record itself is untouched")
        XCTAssertEqual(rebased.firstPaidPolicyAt, flip)
        XCTAssertEqual(rebased.startsAt, flip)
        XCTAssertEqual(rebased.endsAt, flip.addingTimeInterval(SGEntitlementLocalGrace.duration))

        let decision = self.evaluate(.paid, localGrace: rebased, now: self.at(0))
        XCTAssertEqual(decision.source, .localGrace, "the flip gives every install the seven days it would have had on first launch")
        XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(decision.validUntil, rebased.endsAt, "the decision re-evaluates itself when the re-based window closes")
        XCTAssertEqual(self.evaluate(.paid, localGrace: rebased, now: flip.addingTimeInterval(7 * 86400 - 1)).source, .localGrace)
        XCTAssertEqual(self.evaluate(.paid, localGrace: rebased, now: flip.addingTimeInterval(7 * 86400)).state, .degraded(reason: .noToken), "seven days from the flip, not seven days plus a second")
    }

    func test_paid_anOldFlipRebasesNothingUseful_andFirstLaunchStillWinsWhenItCameLater() {
        let expired = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400)).rebased(firstPaidPolicyAt: self.at(-8 * 86400))
        XCTAssertEqual(self.evaluate(.paid, localGrace: expired, now: self.at(0)).state, .degraded(reason: .noToken), "the seven days after the flip are over")
        // An install first launched AFTER the flip starts its window at first launch, as before.
        let young = SGEntitlementLocalGrace(firstLaunchAt: self.at(-86400)).rebased(firstPaidPolicyAt: self.at(-20 * 86400))
        XCTAssertEqual(young.startsAt, self.at(-86400))
        XCTAssertEqual(self.evaluate(.paid, localGrace: young, now: self.at(0)).source, .localGrace)
        // No mark (paid never adopted on this install): the first-launch window, unchanged.
        let plain = SGEntitlementLocalGrace(firstLaunchAt: self.at(-86400))
        XCTAssertEqual(plain.rebased(firstPaidPolicyAt: nil), plain)
        XCTAssertEqual(plain.startsAt, plain.firstLaunchAt)
        XCTAssertNil(plain.firstPaidPolicyAt)
    }

    func test_theMarkIsNotInTheFirstLaunchRecordsBytes_andSurvivesObserving() throws {
        let rebased = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400), lastSeenAt: self.at(-86400), firstPaidPolicyAt: self.at(-3600))
        let decoded = try JSONDecoder().decode(SGEntitlementLocalGrace.self, from: JSONEncoder().encode(rebased))
        XCTAssertNil(decoded.firstPaidPolicyAt, "the paid-policy mark is its own Keychain record, never these bytes")
        XCTAssertEqual(decoded, rebased.rebased(firstPaidPolicyAt: nil))

        let observed = rebased.observing(self.at(0))
        XCTAssertEqual(observed.firstPaidPolicyAt, rebased.firstPaidPolicyAt, "advancing the high-water mark keeps the re-base")
        XCTAssertEqual(observed.lastSeenAt, self.at(0))
        XCTAssertTrue(observed.isActive(at: self.at(0)))
        // The record's own high-water mark still closes the re-based window against a wound-back clock.
        let dayEight = rebased.observing(self.at(8 * 86400))
        XCTAssertFalse(dayEight.isActive(at: self.at(0)))
    }

    func test_free_aRebasedGraceIsStillNotWhatGrants() {
        let rebased = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400)).rebased(firstPaidPolicyAt: self.at(-86400))
        let decision = self.evaluate(.free, localGrace: rebased, now: self.at(0))
        XCTAssertEqual(decision.source, .freeAccess, "no countdown while free, re-based or not")
        XCTAssertEqual(decision.validUntil, Date.distantFuture)
    }

    func test_anUnconfiguredBuildIsUnconfiguredInEitherMode() {
        for mode in SGEntitlementPolicyMode.allCases {
            let decision = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]), now: self.at(0), enforcement: SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false), monetization: mode)
            XCTAssertEqual(decision.source, .unconfigured)
        }
    }
}
