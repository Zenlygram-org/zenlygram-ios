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
        XCTAssertEqual(rebased.endsAt, flip.addingTimeInterval(SGEntitlementLocalGrace.defaultDuration))
        XCTAssertEqual(SGEntitlementLocalGrace.defaultDuration, 7 * 86400, "with no signed length the window is the seven days it always was")

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

    // MARK: - The grace's length is the accepted signed policy's `local_grace_days`

    private let day: TimeInterval = 86400

    /// An accepted policy state holding one really signed token, re-verified as a relaunch would.
    private func policyState(version: Int64, mode: String = "paid", trialDays: Int? = nil, localGraceDays: Int? = nil) -> SGEntitlementPolicyState {
        let token = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: 1, iat: self.iat, version: version, trialDays: trialDays, localGraceDays: localGraceDays)
        let state = SGEntitlementTestPolicy.state(token, pinned: self.pinned)
        XCTAssertNotNil(state.accepted, "premise: the ver-\(version) policy authenticates")
        return state
    }

    /// The install's two records exactly as `SGEntitlement.localGrace(now:monetization:days:)`
    /// combines them with the accepted policy's length.
    private func grace(start: Date, under state: SGEntitlementPolicyState) -> SGEntitlementLocalGrace {
        return SGEntitlementLocalGrace(firstLaunchAt: self.at(-60 * 86400)).rebased(firstPaidPolicyAt: start).lasting(days: state.localGraceDays)
    }

    func test_paid_theGraceLastsExactlyTheSignedDays_oneSevenAndThirty() {
        let start = self.at(0)
        for days in [1, 7, 30] {
            let state = self.policyState(version: 3, trialDays: 0, localGraceDays: days)
            let grace = self.grace(start: start, under: state)
            XCTAssertEqual(grace.days, days)
            XCTAssertEqual(grace.startsAt, start, "the length never moves the start")
            XCTAssertEqual(grace.duration, TimeInterval(days) * self.day)
            XCTAssertEqual(grace.endsAt, start.addingTimeInterval(TimeInterval(days) * self.day), "end = start + L x 86 400 s")

            let first = self.evaluate(.paid, localGrace: grace, now: start)
            XCTAssertEqual(first.source, .localGrace, "\(days) day(s): granted from the first second")
            XCTAssertEqual(first.state, .unlocked(capabilities: self.base))
            XCTAssertEqual(first.validUntil, grace.endsAt, "the decision re-evaluates itself when the window of \(days) day(s) closes")
            let lastSecond = self.evaluate(.paid, localGrace: grace, now: grace.endsAt.addingTimeInterval(-1))
            XCTAssertEqual(lastSecond.source, .localGrace, "\(days) day(s): still granted one second before the end")
            let atTheEnd = self.evaluate(.paid, localGrace: grace, now: grace.endsAt)
            XCTAssertEqual(atTheEnd.state, .degraded(reason: .noToken), "\(days) day(s), not \(days) day(s) plus a second")
            XCTAssertEqual(atTheEnd.source, SGEntitlementSource.none)
            XCTAssertEqual(atTheEnd.validUntil, Date.distantFuture)
        }
    }

    func test_paid_aZeroDayGraceNeverGrants() {
        let start = self.at(0)
        let state = self.policyState(version: 3, trialDays: 0, localGraceDays: 0)
        XCTAssertEqual(state.localGraceDays, 0)
        let grace = self.grace(start: start, under: state)
        XCTAssertEqual(grace.days, 0)
        XCTAssertEqual(grace.endsAt, start, "no window at all: it would end where it starts")
        // At the very moment the paid policy is first read, any time after — and under a clock
        // wound back BEFORE the start, where `now < endsAt` alone would have read as open.
        for now in [start, start.addingTimeInterval(1), start.addingTimeInterval(3 * self.day), start.addingTimeInterval(400 * self.day), start.addingTimeInterval(-1), start.addingTimeInterval(-30 * self.day)] {
            XCTAssertFalse(grace.isActive(at: now))
            let decision = self.evaluate(.paid, localGrace: grace, now: now)
            XCTAssertEqual(decision.state, .degraded(reason: .noToken), "0 days: 'not active' at once, exactly as an install whose grace has ended")
            XCTAssertEqual(decision.source, SGEntitlementSource.none, "never .localGrace: nothing shows a 'free until' date for it")
            XCTAssertEqual(decision.validUntil, Date.distantFuture)
            for action in SGEntitlementGatedAction.allCases {
                XCTAssertFalse(decision.state.allows(action), "\(action.rawValue) needs a real grant under a 0-day grace")
            }
        }
        // A fresh, never-observed, never-re-based record (first launched under the 0-day policy).
        let fresh = SGEntitlementLocalGrace(firstLaunchAt: start).lasting(days: 0)
        XCTAssertFalse(fresh.isActive(at: start))
        XCTAssertEqual(self.evaluate(.paid, localGrace: fresh, now: start).state, .degraded(reason: .noToken))
    }

    func test_paid_underAZeroDayGraceARealGrantStillGrants_andTheTokensReasonStillShows() {
        let grace = self.grace(start: self.at(0), under: self.policyState(version: 3, trialDays: 0, localGraceDays: 0))
        let token = self.evaluate(.paid, cached: self.cached(), localGrace: grace, now: self.at(60))
        XCTAssertEqual(token.source, .token, "a genuine grant does not need the grace")
        XCTAssertTrue(token.state.isUnlocked)
        let storeKit = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: self.at(30 * 86400))
        XCTAssertEqual(self.evaluate(.paid, storeKit: storeKit, localGrace: grace, now: self.at(60)).source, .storeKit)
        // What the token says is what degrades: the grace hides nothing and adds nothing.
        let lapsed = self.evaluate(.paid, cached: self.cached(account: .explicit(ent: ["vault"], until: "2020-01-01T00:00:00Z")), localGrace: grace, now: self.at(60))
        XCTAssertEqual(lapsed.state, .degraded(reason: .lapsed))
        let legacy = self.evaluate(.paid, cached: self.cached(account: .omitted), localGrace: grace, now: self.at(60))
        XCTAssertEqual(legacy.state, .degraded(reason: .stale))
    }

    func test_paid_aV2PolicyAV1PolicyAndNoPolicyAllMeanSevenDays() {
        let start = self.at(0)
        let states: [(String, SGEntitlementPolicyState)] = [
            ("ver 2", self.policyState(version: 2, trialDays: 30)),
            ("ver 1", self.policyState(version: 1)),
            ("no policy", .initial)
        ]
        for (name, state) in states {
            XCTAssertEqual(state.localGraceDays, 7, name)
            let grace = self.grace(start: start, under: state)
            XCTAssertEqual(grace, SGEntitlementLocalGrace(firstLaunchAt: self.at(-60 * 86400)).rebased(firstPaidPolicyAt: start), "\(name): exactly the window this build had before the length was signed")
            XCTAssertEqual(grace.endsAt, start.addingTimeInterval(7 * self.day), name)
            XCTAssertEqual(self.evaluate(.paid, localGrace: grace, now: start.addingTimeInterval(7 * self.day - 1)).source, .localGrace, name)
            XCTAssertEqual(self.evaluate(.paid, localGrace: grace, now: start.addingTimeInterval(7 * self.day)).state, .degraded(reason: .noToken), name)
        }
        // A v2 policy's trial_days is never mistaken for the grace's length.
        XCTAssertEqual(self.policyState(version: 2, trialDays: 0).localGraceDays, 7)
        // A v3 policy that signs seven is the same window by another route.
        XCTAssertEqual(self.grace(start: start, under: self.policyState(version: 3, trialDays: 0, localGraceDays: 7)), self.grace(start: start, under: .initial))
    }

    func test_paid_aShorterLengthEndsARunningGrace_andALongerOneExtendsIt() {
        // Day 3 of a seven-day window.
        let start = self.at(0)
        let now = start.addingTimeInterval(3 * self.day)
        let record = SGEntitlementLocalGrace(firstLaunchAt: self.at(-60 * 86400)).rebased(firstPaidPolicyAt: start).observing(now)
        let seven = record.lasting(days: self.policyState(version: 3, trialDays: 0, localGraceDays: 7).localGraceDays)
        XCTAssertEqual(self.evaluate(.paid, localGrace: seven, now: now).source, .localGrace, "premise: a running grace")
        XCTAssertEqual(seven.endsAt, start.addingTimeInterval(7 * self.day))

        // The owner lowers it to 2: the window ended yesterday — the grace stops at once.
        let two = record.lasting(days: self.policyState(version: 3, trialDays: 0, localGraceDays: 2).localGraceDays)
        XCTAssertEqual(two.startsAt, start, "never re-based: only the end moved")
        XCTAssertEqual(two.endsAt, start.addingTimeInterval(2 * self.day))
        XCTAssertEqual(self.evaluate(.paid, localGrace: two, now: now).state, .degraded(reason: .noToken), "a shorter length ends a running grace")

        // Exactly today's age (3 days): `now < endsAt` is already false at the boundary.
        let three = record.lasting(days: 3)
        XCTAssertEqual(self.evaluate(.paid, localGrace: three, now: now).state, .degraded(reason: .noToken))
        // 4 keeps it running, with the nearer end.
        let four = record.lasting(days: 4)
        let shortened = self.evaluate(.paid, localGrace: four, now: now)
        XCTAssertEqual(shortened.source, .localGrace)
        XCTAssertEqual(shortened.validUntil, start.addingTimeInterval(4 * self.day), "the decision's own horizon is the new end")

        // Raised to 30: the same start, a later end.
        let thirty = record.lasting(days: self.policyState(version: 3, trialDays: 0, localGraceDays: 30).localGraceDays)
        let extended = self.evaluate(.paid, localGrace: thirty, now: now)
        XCTAssertEqual(extended.source, .localGrace)
        XCTAssertEqual(extended.validUntil, start.addingTimeInterval(30 * self.day))
        XCTAssertEqual(thirty.startsAt, start)

        // To 0: off, whatever day it is.
        XCTAssertEqual(self.evaluate(.paid, localGrace: record.lasting(days: 0), now: now).state, .degraded(reason: .noToken))
    }

    func test_paid_aLongerLengthRevivesAnEndedGrace_fromTheSameStart() {
        // Day 10: the seven days are over, and the record has SEEN day 10.
        let start = self.at(0)
        let now = start.addingTimeInterval(10 * self.day)
        let record = SGEntitlementLocalGrace(firstLaunchAt: self.at(-60 * 86400)).rebased(firstPaidPolicyAt: start).observing(now)
        XCTAssertEqual(self.evaluate(.paid, localGrace: record.lasting(days: 7), now: now).state, .degraded(reason: .noToken), "premise: an ended grace")

        let thirty = record.lasting(days: 30)
        let revived = self.evaluate(.paid, localGrace: thirty, now: now)
        XCTAssertEqual(revived.source, .localGrace, "nothing remembers 'it ended': the window is always start + L")
        XCTAssertEqual(revived.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(revived.validUntil, start.addingTimeInterval(30 * self.day), "20 days are left, counted from the original start — not 30 fresh ones")
        XCTAssertEqual(thirty.firstPaidPolicyAt, start)
        // A length that is still behind the clock revives nothing.
        XCTAssertEqual(self.evaluate(.paid, localGrace: record.lasting(days: 10), now: now).state, .degraded(reason: .noToken))
        XCTAssertEqual(self.evaluate(.paid, localGrace: record.lasting(days: 11), now: now).source, .localGrace)
        // …and back to seven it is over again.
        XCTAssertEqual(self.evaluate(.paid, localGrace: thirty.lasting(days: 7), now: now).state, .degraded(reason: .noToken))

        // The record's own high-water mark still closes the LONGER window against a wound-back
        // clock: once day 31 was seen, no clock setting re-opens thirty days.
        let dayThirtyOne = record.lasting(days: 30).observing(start.addingTimeInterval(31 * self.day))
        XCTAssertFalse(dayThirtyOne.isActive(at: start.addingTimeInterval(self.day)))
        XCTAssertEqual(dayThirtyOne.days, 30, "observing keeps the length")
    }

    func test_free_theSignedLengthHasNoEffect() {
        let start = self.at(0)
        for days in [0, 7, 30] {
            let state = self.policyState(version: 3, mode: "free", trialDays: 0, localGraceDays: days)
            XCTAssertEqual(state.mode, .free)
            XCTAssertEqual(state.localGraceDays, days, "signed in both modes")
            let decision = self.evaluate(state.mode, localGrace: self.grace(start: start, under: state), now: start.addingTimeInterval(self.day))
            XCTAssertEqual(decision.source, .freeAccess, "free access is not a countdown, whatever the length")
            XCTAssertEqual(decision.state, .unlocked(capabilities: self.base))
            XCTAssertEqual(decision.validUntil, Date.distantFuture)
        }
    }

    func test_theLengthIsNeverInTheRecordsBytes_andIsClampedToTheContract() throws {
        let record = SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400), lastSeenAt: self.at(-86400), firstPaidPolicyAt: self.at(-3600), days: 3)
        XCTAssertEqual(record.days, 3)
        let bytes = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["firstLaunchAt", "lastSeenAt"], "the record holds its two dates and nothing else: the length lives only in the signed policy token")
        let decoded = try JSONDecoder().decode(SGEntitlementLocalGrace.self, from: bytes)
        XCTAssertEqual(decoded.days, SGEntitlementLocalGrace.defaultDays, "a decoded record carries no length: the policy is asked again")
        XCTAssertNil(decoded.firstPaidPolicyAt)
        XCTAssertEqual(decoded.lasting(days: 3).rebased(firstPaidPolicyAt: self.at(-3600)), record)

        // The combinators keep each other's part.
        XCTAssertEqual(record.rebased(firstPaidPolicyAt: self.at(-7200)).days, 3)
        XCTAssertEqual(record.observing(self.at(0)).days, 3)
        XCTAssertEqual(record.lasting(days: 9).firstPaidPolicyAt, record.firstPaidPolicyAt)
        XCTAssertEqual(record.lasting(days: 9).lastSeenAt, record.lastSeenAt)
        XCTAssertEqual(record.lasting(days: 9).firstLaunchAt, record.firstLaunchAt)

        // Whoever builds it, the window is never negative and never longer than the contract's 30.
        XCTAssertEqual(record.lasting(days: -5).days, 0)
        XCTAssertFalse(record.lasting(days: -5).isActive(at: self.at(-3600)))
        XCTAssertEqual(record.lasting(days: 31).days, 30)
        XCTAssertEqual(record.lasting(days: 3650).endsAt, record.startsAt.addingTimeInterval(30 * self.day))
        XCTAssertEqual(SGEntitlementLocalGrace(firstLaunchAt: self.at(0)).days, 7, "a record nothing was combined with is the default seven days")
    }

    func test_anUnconfiguredBuildIsUnconfiguredInEitherMode() {
        for mode in SGEntitlementPolicyMode.allCases {
            let decision = SGEntitlementEvaluator.evaluate(cached: nil, storeKit: nil, pinnedKeys: SGEntitlementPinnedKeys(keysByKid: [:]), now: self.at(0), enforcement: SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false), monetization: mode)
            XCTAssertEqual(decision.source, .unconfigured)
        }
    }
}
