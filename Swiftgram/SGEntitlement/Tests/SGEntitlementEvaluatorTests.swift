import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementEvaluatorTests: XCTestCase {
    func test_cachedForeignAccountDoesNotGrantAfterRelaunch() {
        let key = P256.Signing.PrivateKey()
        let pinned = SGEntitlementTestToken.pinned(key, kid: "account-isolation-test")
        var payload = SGEntitlementTestToken.claims()
        payload["tgid"] = 123_456_789
        let token = SGEntitlementTestToken.make(key: key, kid: "account-isolation-test", payload: payload)
        let cached = SGEntitlementCachedToken(jws: token, boundDeviceId: "01JB8R", boundAccountId: "01JB8Q", accountPeerId: 987_654_321)
        let decision = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: pinned, now: Date(timeIntervalSince1970: 1790000001), monetization: .paid)
        XCTAssertEqual(decision.state, .degraded(reason: .unverifiable))
        XCTAssertEqual(decision.tokenFailure, .foreignAccount)
    }

    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let issuedAt: Int64 = 1790000000
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func token(ent: [String] = ["vault", "chatlock", "tasks", "edithistory"], until: String?, graceDays: Int = 14, exp: Int64? = nil) -> SGEntitlementCachedToken {
        let jws = SGEntitlementTestToken.make(
            key: self.key,
            kid: self.kid,
            payload: SGEntitlementTestToken.claims(ent: ent, until: until, graceDays: graceDays, iat: self.issuedAt, exp: exp ?? (self.issuedAt + 72 * 3600))
        )
        return SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R")
    }

    private func date(_ unix: Int64) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    func test_unlocked_whileBeforeUntilAndBeforeExpPlusGrace() {
        let decision = SGEntitlementEvaluator.evaluate(
            cached: self.token(until: "2030-01-01T00:00:00Z"),
            storeKit: nil,
            pinnedKeys: self.pinned,
            now: self.date(self.issuedAt + 3600),
            monetization: .paid
        )
        XCTAssertEqual(decision.state, .unlocked(capabilities: ["vault", "chatlock", "tasks", "edithistory"]))
        XCTAssertEqual(decision.source, .token)
    }

    func test_offlineForSeventeenDays_isStillUnlocked_andEighteenIsStale() {
        // exp = iat + 72 h, grace = 14 d, so the hard stop is 17 days after `iat`.
        let cached = self.token(until: "2030-01-01T00:00:00Z")
        let almost = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 16 * 86400), monetization: .paid)
        XCTAssertTrue(almost.state.isUnlocked, "a user on a plane, or behind a national block, must not lose Pro inside the grace window")
        let past = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 18 * 86400), monetization: .paid)
        XCTAssertEqual(past.state, .degraded(reason: .stale))
    }

    func test_nullUntil_isNoToken_notALapse() {
        // D9: the server answers null for "never paid" and for a horizon already past alike, so a
        // null horizon is "nothing granting" — the offer, never "your subscription ended".
        let decision = SGEntitlementEvaluator.evaluate(cached: self.token(ent: [], until: nil), storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
        XCTAssertEqual(decision.state, .degraded(reason: .noToken))
        XCTAssertNotNil(decision.claims, "a token with a null horizon still verified, and its claims still feed the clock mark")
    }

    func test_untilInThePast_isALapse() {
        let decision = SGEntitlementEvaluator.evaluate(cached: self.token(until: "2020-01-01T00:00:00Z"), storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
        XCTAssertEqual(decision.state, .degraded(reason: .lapsed))
    }

    func test_noToken_isNoToken() {
        let decision = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: self.pinned, now: Date(), monetization: .paid)
        XCTAssertEqual(decision.state, .degraded(reason: .noToken))
        XCTAssertEqual(decision.source, SGEntitlementSource.none)
    }

    func test_unverifiableToken_isUnverifiable_andNeverUnlocked() {
        let cached = SGEntitlementCachedToken(jws: "not.a.token", boundDeviceId: nil)
        let decision = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: Date(), monetization: .paid)
        XCTAssertEqual(decision.state, .degraded(reason: .unverifiable))
    }

    func test_legacyWildcardToken_isAFreePhaseHatchOnly_neverAPaidGrant() {
        // The server forces free mode with its wildcard and keeps `ent: ["*"]` for OLD clients; it
        // never puts the wildcard in `account_ent`. So once paid, a wildcard token proves nothing.
        let jws = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims(ent: ["*"], until: "2030-01-01T00:00:00Z", iat: self.issuedAt, exp: self.issuedAt + 72 * 3600, account: .omitted))
        let cached = SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R")
        let paid = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
        XCTAssertFalse(paid.state.isUnlocked)
        let free = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .free)
        XCTAssertTrue(free.state.has(.tasks))
        // Never the capability that changes what leaves the device. Enabling the AI Assistant sends
        // message text to a third party, and no server string may do that to a binary whose App
        // Privacy answers say it does not. That takes a release.
        XCTAssertFalse(free.state.has(.ai))
    }

    func test_tenYearUntil_isNotClamped() {
        let decision = SGEntitlementEvaluator.evaluate(cached: self.token(until: "2036-01-01T00:00:00Z"), storeKit: nil, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
        XCTAssertTrue(decision.state.isUnlocked, "VIP accounts, and every account while the rollout is dark, legitimately carry a ~10-year until")
    }

    // MARK: - storeKitFallback: the "bought before linking Telegram" hole

    func test_storeKitFallback_rescuesAPayingUserWithNoToken() {
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: self.date(self.issuedAt + 30 * 86400))
        let decision = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt), monetization: .paid)
        XCTAssertEqual(decision.source, .storeKit)
        XCTAssertEqual(decision.state, .unlocked(capabilities: Set(SGEntitlementCapability.base.map { $0.rawValue })))
        XCTAssertFalse(decision.state.has(.ai), "the fallback grants what the product sells, never the AI capability and never \"*\"")
    }

    func test_storeKitFallback_alsoRescuesALapsedOrStaleToken() {
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: nil)
        for cached in [self.token(ent: [], until: nil), self.token(until: "2030-01-01T00:00:00Z", exp: self.issuedAt - 40 * 86400)] {
            let decision = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
            XCTAssertTrue(decision.state.isUnlocked)
            XCTAssertEqual(decision.source, .storeKit)
        }
    }

    func test_storeKitFallback_keepsGrantingThroughTheRenewalAllowance_thenStops() {
        // Apple renews server-side while the app is closed and the snapshot is only refreshed when
        // the app next asks StoreKit, so a period that just ended is a renewal the device has not
        // synced yet, not a lapse (invariant I2). The hard stop is `expirationDate + allowance`.
        let allowance = SGEntitlementStoreKitSnapshot.renewalAllowance
        XCTAssertEqual(allowance, 3 * 86400)
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: self.date(self.issuedAt - 1))
        XCTAssertEqual(storeKit.effectiveExpirationDate, self.date(self.issuedAt - 1).addingTimeInterval(allowance))

        let justPassed = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt), monetization: .paid)
        XCTAssertEqual(justPassed.source, .storeKit, "03:00 came and went with the app closed: still paying, still revealing")
        XCTAssertTrue(justPassed.state.has(.editHistory))
        XCTAssertEqual(justPassed.validUntil, storeKit.effectiveExpirationDate, "the decision re-evaluates itself at the end of the allowance")

        let insideTheAllowance = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt - 1).addingTimeInterval(allowance - 1), monetization: .paid)
        XCTAssertEqual(insideTheAllowance.source, .storeKit)

        let pastTheAllowance = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt - 1).addingTimeInterval(allowance), monetization: .paid)
        XCTAssertEqual(pastTheAllowance.state, .degraded(reason: .noToken), "a subscription that really did not renew stops at the hard stop")
    }

    func test_aVerifiedTokenIsNeverOverriddenByAnInactiveStoreKitSnapshot() {
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: false, expirationDate: nil)
        let decision = SGEntitlementEvaluator.evaluate(cached: self.token(until: "2030-01-01T00:00:00Z"), storeKit: storeKit, pinnedKeys: self.pinned, now: self.date(self.issuedAt + 60), monetization: .paid)
        XCTAssertEqual(decision.source, .token)
        XCTAssertTrue(decision.state.isUnlocked)
    }

    // MARK: - A build that cannot grant must not gate

    /// The state every simulator build, every developer build and every build made before App Store
    /// Connect exists is in: no pinned key, no product ids. Enforcing there would put a paywall in
    /// front of the four features while the paywall has nothing to sell.
    private var unconfigured: SGEntitlementEnforcement {
        return SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false)
    }

    func test_aBuildWithNoKeysAndNoProductsIsUnlocked() {
        let decision = SGEntitlementEvaluator.evaluate(
            cached: nil,
            storeKit: nil,
            pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]),
            now: self.date(self.issuedAt),
            enforcement: self.unconfigured,
            monetization: .paid
        )
        XCTAssertEqual(decision.source, .unconfigured)
        XCTAssertTrue(decision.state.isUnlocked)
        for capability in SGEntitlementCapability.base {
            XCTAssertTrue(decision.state.has(capability), "\(capability.rawValue) must be granted by an unconfigured build")
        }
    }

    func test_anUnconfiguredBuildGrantsTheFourShippedFeaturesButNotAI() {
        let decision = SGEntitlementEvaluator.evaluate(
            cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]),
            now: self.date(self.issuedAt), enforcement: self.unconfigured, monetization: .paid
        )
        // `ai` ships when the server says so, never because a build forgot its configuration.
        XCTAssertFalse(decision.state.has(.ai))
        XCTAssertFalse(decision.state.capabilities.contains(SGEntitlementCapability.wildcard))
    }

    func test_oneHalfOfTheConfigurationIsEnoughToEnforce() {
        // A key but no products: a bound account can still be granted a token, so enforce.
        XCTAssertTrue(SGEntitlementEnforcement(canVerifyTokens: true, knowsProducts: false).isEnforcing)
        // Products but no key: a purchase can still be recognised locally, so enforce.
        XCTAssertTrue(SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: true).isEnforcing)
        XCTAssertFalse(self.unconfigured.isEnforcing)
    }

    func test_aConfiguredBuildStillGatesWithNoToken() {
        // The guard must not leak into configured builds: this is the same call as the test above
        // with enforcement on, and it must come back degraded.
        let decision = SGEntitlementEvaluator.evaluate(
            cached: nil, storeKit: nil, pinnedKeys: self.pinned,
            now: self.date(self.issuedAt), enforcement: .enforcing, monetization: .paid
        )
        XCTAssertEqual(decision.state, .degraded(reason: .noToken))
    }

    // MARK: - The local 7-day grace: everything is free for 7 days after first launch, then Pro

    private var firstLaunch: Date {
        return self.date(self.issuedAt)
    }

    private var grace: SGEntitlementLocalGrace {
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunch)
    }

    private func evaluateWithGrace(cached: SGEntitlementCachedToken? = nil, storeKit: SGEntitlementStoreKitSnapshot? = nil, now: Date) -> SGEntitlementEvaluator.Decision {
        return SGEntitlementEvaluator.evaluate(cached: cached, storeKit: storeKit, pinnedKeys: self.pinned, now: now, enforcement: .enforcing, localGrace: self.grace, monetization: .paid)
    }

    func test_localGrace_unlocksTheFourBaseCapabilitiesWithNoTokenAndNoPurchase() {
        let decision = self.evaluateWithGrace(now: self.firstLaunch.addingTimeInterval(3 * 86400))
        XCTAssertEqual(decision.source, .localGrace)
        XCTAssertEqual(decision.state, .unlocked(capabilities: Set(SGEntitlementCapability.base.map { $0.rawValue })))
        XCTAssertFalse(decision.state.has(.ai), "the grace grants what the product sells, never AI and never \"*\"")
        XCTAssertEqual(decision.validUntil, self.grace.endsAt, "the decision must re-evaluate itself the instant the window closes")
        // One rule, one sentence: inside the window new captures are recorded like any other create.
        XCTAssertTrue(decision.state.allows(.createTask))
        XCTAssertTrue(decision.state.allows(.createRetainedHistoryRecord))
    }

    func test_localGrace_lastsSevenDays_notSevenDaysPlusOneSecond() {
        let sevenDays: TimeInterval = 7 * 86400
        XCTAssertEqual(SGEntitlementLocalGrace.duration, sevenDays)
        let inside = self.evaluateWithGrace(now: self.firstLaunch.addingTimeInterval(sevenDays - 1))
        XCTAssertEqual(inside.source, .localGrace)
        let atTheEnd = self.evaluateWithGrace(now: self.firstLaunch.addingTimeInterval(sevenDays))
        XCTAssertEqual(atTheEnd.state, .degraded(reason: .noToken), "the window is now < firstLaunch + 7 d — closed on the seventh day's last second, not one second later")
        XCTAssertEqual(atTheEnd.source, SGEntitlementSource.none)
        let after = self.evaluateWithGrace(now: self.firstLaunch.addingTimeInterval(sevenDays + 1))
        XCTAssertEqual(after.state, .degraded(reason: .noToken))
    }

    func test_localGrace_ignoresABackwardsClock() {
        // The install has seen a server time eight days after first launch (a token's `iat`, or any
        // response's `server_time`). The user then winds the wall clock back to day one to get the
        // week again. `effectiveNow` floors at the mark, so the evaluation stays past the window.
        let eighthDay = self.firstLaunch.addingTimeInterval(8 * 86400)
        let mark = SGEntitlementClockMark(serverTime: eighthDay, uptime: 1000, bootTime: eighthDay.addingTimeInterval(-1000))
        let woundBack = self.firstLaunch.addingTimeInterval(86400)
        let effective = SGEntitlementClock.effectiveNow(mark: mark, wallClock: woundBack, uptime: 1000 + 60)
        XCTAssertGreaterThanOrEqual(effective, self.grace.endsAt)
        XCTAssertEqual(self.evaluateWithGrace(now: effective).state, .degraded(reason: .noToken))
        // The wall clock alone would have been inside the window — which is exactly what the mark is for.
        XCTAssertEqual(self.evaluateWithGrace(now: woundBack).source, .localGrace)
    }

    func test_aVerifiedTokenBeatsTheLocalGrace() {
        let inside = self.firstLaunch.addingTimeInterval(86400)
        let full = self.evaluateWithGrace(cached: self.token(until: "2030-01-01T00:00:00Z"), now: inside)
        XCTAssertEqual(full.source, .token)
        XCTAssertTrue(full.state.isUnlocked)
        // Once the server grants, its list is authoritative — the grace does not widen it.
        let partial = self.evaluateWithGrace(cached: self.token(ent: ["vault"], until: "2030-01-01T00:00:00Z"), now: inside)
        XCTAssertEqual(partial.source, .token)
        XCTAssertEqual(partial.state, .unlocked(capabilities: ["vault"]))
    }

    func test_aStoreKitSubscriptionBeatsTheLocalGrace() {
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: nil)
        let decision = self.evaluateWithGrace(storeKit: storeKit, now: self.firstLaunch.addingTimeInterval(86400))
        XCTAssertEqual(decision.source, .storeKit)
        XCTAssertTrue(decision.state.isUnlocked)
    }

    func test_theLocalGraceRescuesATokenThatDoesNotGrant_insideTheWindow() {
        // "Everything is free for 7 days after first launch" — whatever the token says. The claims
        // still come back, so a lapsed token keeps feeding the clock mark.
        let inside = self.firstLaunch.addingTimeInterval(2 * 86400)
        let lapsed = self.evaluateWithGrace(cached: self.token(ent: [], until: nil), now: inside)
        XCTAssertEqual(lapsed.source, .localGrace)
        XCTAssertTrue(lapsed.state.has(.editHistory))
        XCTAssertNotNil(lapsed.claims)
        let unverifiable = self.evaluateWithGrace(cached: SGEntitlementCachedToken(jws: "not.a.token", boundDeviceId: nil), now: inside)
        XCTAssertEqual(unverifiable.source, .localGrace)
        XCTAssertNotNil(unverifiable.tokenFailure, "the failure is still reported for diagnostics")
    }

    func test_afterTheLocalGraceALapseDegrades_withTheReasonTheTokenProduced() {
        let after = self.firstLaunch.addingTimeInterval(30 * 86400)
        XCTAssertEqual(self.evaluateWithGrace(now: after).state, .degraded(reason: .noToken))
        XCTAssertEqual(self.evaluateWithGrace(cached: self.token(ent: [], until: nil), now: after).state, .degraded(reason: .noToken), "a null horizon is 'nothing granting', not 'ended' (D9)")
        XCTAssertEqual(self.evaluateWithGrace(cached: self.token(until: "2020-01-01T00:00:00Z"), now: after).state, .degraded(reason: .lapsed))
        // Only NEW captures stop; what was retained stays readable (no gate exists for it) and is never purged here.
        XCTAssertFalse(self.evaluateWithGrace(now: after).state.allows(.createRetainedHistoryRecord))
        XCTAssertFalse(self.evaluateWithGrace(now: after).state.allows(.createTask))
    }

    func test_anExpiredTokenAfterTheGraceIsStale_notFree() {
        let after = self.firstLaunch.addingTimeInterval(30 * 86400)
        let decision = self.evaluateWithGrace(cached: self.token(until: "2030-01-01T00:00:00Z"), now: after)
        XCTAssertEqual(decision.state, .degraded(reason: .stale))
    }

    func test_anUnconfiguredBuildIsUnlockedWithOrWithoutTheGrace() {
        // The unconfigured guard runs first: a build that cannot grant does not need a grace to
        // stay unlocked, and an expired grace must not degrade it.
        let after = self.firstLaunch.addingTimeInterval(30 * 86400)
        let decision = SGEntitlementEvaluator.evaluate(
            cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]),
            now: after, enforcement: self.unconfigured, localGrace: self.grace, monetization: .paid
        )
        XCTAssertEqual(decision.source, .unconfigured)
        XCTAssertTrue(decision.state.allows(.createRetainedHistoryRecord))
    }

    func test_theLocalGraceRecordRoundTrips() {
        let data = try! JSONEncoder().encode(self.grace)
        XCTAssertEqual(try? JSONDecoder().decode(SGEntitlementLocalGrace.self, from: data), self.grace)
        XCTAssertEqual(self.grace.endsAt, self.firstLaunch.addingTimeInterval(7 * 86400))
        // A record written before the high-water mark existed decodes with the mark at first launch.
        let legacy = Data("{\"firstLaunchAt\":\(self.firstLaunch.timeIntervalSinceReferenceDate)}".utf8)
        let decoded = try? JSONDecoder().decode(SGEntitlementLocalGrace.self, from: legacy)
        XCTAssertEqual(decoded?.firstLaunchAt, self.firstLaunch)
        XCTAssertEqual(decoded?.lastSeenAt, self.firstLaunch)
    }

    func test_localGrace_ignoresABackwardsClock_withNoServerMark() {
        // The population the grace exists for never binds and never buys, so it never sees a server
        // time and `effectiveNow` is the raw wall clock. The record carries its own high-water mark:
        // day 8 is observed, the user winds the clock back to day 1, and the window stays closed.
        let dayEight = self.firstLaunch.addingTimeInterval(8 * 86400)
        let observed = self.grace.observing(dayEight)
        XCTAssertEqual(observed.lastSeenAt, dayEight)
        XCTAssertEqual(observed.firstLaunchAt, self.firstLaunch, "observing never moves the window itself")
        XCTAssertFalse(observed.isActive(at: self.firstLaunch.addingTimeInterval(86400)))
        let woundBack = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: self.pinned, now: self.firstLaunch.addingTimeInterval(86400), enforcement: .enforcing, localGrace: observed, monetization: .paid)
        XCTAssertEqual(woundBack.state, .degraded(reason: .noToken))
        // The mark only ever moves forward, and a fresh record's mark is its first launch.
        XCTAssertEqual(observed.observing(self.firstLaunch), observed)
        XCTAssertEqual(self.grace.lastSeenAt, self.firstLaunch)
        XCTAssertEqual(SGEntitlementLocalGrace(firstLaunchAt: dayEight, lastSeenAt: self.firstLaunch).lastSeenAt, dayEight, "never earlier than first launch")
        // Winding forwards still only ends it sooner: inside the window the mark changes nothing.
        let dayTwo = self.grace.observing(self.firstLaunch.addingTimeInterval(2 * 86400))
        XCTAssertEqual(self.evaluateWithGrace(now: self.firstLaunch.addingTimeInterval(3 * 86400)).source, .localGrace)
        XCTAssertTrue(dayTwo.isActive(at: self.firstLaunch.addingTimeInterval(86400)), "the mark floors the evaluation at day 2, still inside")
    }
}
