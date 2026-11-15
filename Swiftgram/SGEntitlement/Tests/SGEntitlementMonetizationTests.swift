import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — the monetization policy wired into the live decision, on an instance that owns its
/// store, scheduler and policy store: free by default, the signed policy fetched independently of
/// any binding, the mode moving the gate and the purchase admission synchronously, network failure
/// changing nothing, persistence across launches, and genuine paid grants surviving revisions.
final class SGEntitlementMonetizationTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let base: Set<String> = Set(SGEntitlementCapability.base.map { $0.rawValue })
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var policySuite = ""
    private var store: SGEntitlementStore!
    private var entitlement: SGEntitlement!

    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    /// The policy clock every test instance runs on (unix seconds). Fixed per test, injected, and
    /// deliberately NOT the account clock mark: policy freshness must not move with the unsigned
    /// `server_time` other responses feed that mark.
    private var policyNow: Int64 = 0

    /// Seconds since 1970 on the ACCOUNT evaluation clock: entitlement tokens are minted at it.
    private var tokenNow: Int64 {
        return Int64(SGEntitlementClock.shared.effectiveNow().timeIntervalSince1970)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        let unique = UUID().uuidString
        self.policyNow = Int64(Date().timeIntervalSince1970)
        self.storeSuite = "SGEntitlementMonetizationTests.store.\(unique)"
        self.schedulerSuite = "SGEntitlementMonetizationTests.scheduler.\(unique)"
        self.policySuite = "SGEntitlementMonetizationTests.policy.\(unique)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        self.entitlement = self.makeEntitlement()
    }

    override func tearDown() {
        // A periodic policy refresh a test armed must not outlive it.
        self.entitlement.applicationWillResignActive()
        self.store.clearSession(accountPeerId: self.account)
        for suite in [self.storeSuite, self.schedulerSuite, self.policySuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        self.entitlement = nil
        self.store = nil
        super.tearDown()
    }

    /// One launch of the install: same store, same policy suite, the test's pinned ring, and a local
    /// grace that ended long ago (an old install) with NO paid-policy mark pinned — so paid mode
    /// degrades it, as before D9 — unless a test calls `resetPaidModeMarkForTesting()` to let the
    /// first paid evaluation mint the real mark through the owned store.
    private func makeEntitlement(pinned: SGEntitlementPinnedKeys? = nil, policyClock: (() -> Date)? = nil, policySuite: String? = nil) -> SGEntitlement {
        let fixed = Date(timeIntervalSince1970: TimeInterval(self.policyNow))
        let entitlement = SGEntitlement(
            store: self.store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: policySuite ?? self.policySuite)),
            policyClock: policyClock ?? { fixed }
        )
        entitlement.overridePinnedKeys(pinned ?? self.pinned)
        entitlement.overrideEnforcement(.enforcing)
        entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: Date().addingTimeInterval(-60 * 86400)))
        return entitlement
    }

    private func policy(_ mode: String, revision: Int64, iat: Int64? = nil) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: iat ?? self.policyNow)
    }

    /// The v2 shape, with its signed `trial_days`.
    private func policyV2(_ mode: String, revision: Int64, trialDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: self.policyNow, version: 2, trialDays: trialDays)
    }

    /// The v3 shape, with its signed `trial_days` and `local_grace_days`.
    private func policyV3(_ mode: String, revision: Int64, trialDays: Int = 0, localGraceDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: self.policyNow, version: 3, trialDays: trialDays, localGraceDays: localGraceDays)
    }

    private func answering(_ result: Result<String, SGEntitlementRequestError>) -> SGEntitlementPolicyTransport {
        return SGEntitlementPolicyTransport(fetch: { result })
    }

    private var offline: SGEntitlementPolicyTransport {
        return self.answering(.failure(SGEntitlementRequestError(failure: .offline(.timeout))))
    }

    /// Persists the session through the owned store's real write path (its keychainless fallback,
    /// read back), exactly as `SGEntitlementRefreshSessionTests` seeds. An in-memory
    /// `seedSessionForTesting` does NOT survive `invalidate()`, which drops the store's cache by
    /// design (it is how a process picks up another process's write) — the seed would vanish and
    /// the account would read as unlinked with no token.
    private func seedSession(account: SGEntitlementTestToken.AccountClaims) {
        let issuedAt = self.tokenNow
        let jws = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims(iat: issuedAt, exp: issuedAt + 72 * 3600, account: account))
        let material = SGEntitlementSessionMaterial(refreshToken: "current-session", entitlement: jws, accountId: "01JB8Q", deviceId: "01JB8R")
        let seeded = self.store.updateSession(accountPeerId: self.account) { stored in
            stored = material
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
        self.entitlement.setActiveAccount(peerId: self.account)
        self.entitlement.invalidate()
        XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "current-session", "premise: the seed survives a cache invalidation")
    }

    // MARK: - Free first

    func test_aFreshInstallIsFreeBeforeAnyPolicyArrives() {
        XCTAssertEqual(self.entitlement.monetizationMode, .free)
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(self.entitlement.source, .freeAccess)
        XCTAssertTrue(self.entitlement.can(.createTask))
        XCTAssertTrue(self.entitlement.can(.createRetainedHistoryRecord), "free mode captures new history (subject to the user's own toggles)")
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .allowed, "no automatic paywall while free")
        XCTAssertEqual(self.entitlement.gate(.useAIAssistant), .unavailable, "AI stays hidden, not sold")
        XCTAssertFalse(self.entitlement.isAIAssistantAvailable)
        XCTAssertFalse(self.entitlement.offersNewSubscriptions, "no purchase may start before paid is enabled")
    }

    func test_freeShowsNoLocalGraceCountdown() {
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: Date().addingTimeInterval(-86400)))
        XCTAssertEqual(self.entitlement.source, .freeAccess)
        XCTAssertNil(self.entitlement.localGraceEndsAt, "free access is not 'free until <date>'")
    }

    func test_anUnboundAccountWithALapsedTokenIsFree() {
        self.seedSession(account: .explicit(ent: [], until: nil))
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base))
        XCTAssertEqual(self.entitlement.source, .freeAccess)
    }

    // MARK: - Fetch, order, failure

    func test_freePaidFreeMovesTheGateAndThePurchaseAdmission() async {
        // The real paid-policy mark (D9): minted by the first paid evaluation, through the owned store.
        self.entitlement.resetPaidModeMarkForTesting()
        let paid = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_000)
        XCTAssertEqual(paid, .adopted)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base), "an old install with nothing paid gets, from the flip, the seven days it would have had on first launch (D9)")
        XCTAssertEqual(self.entitlement.source, .localGrace)
        XCTAssertTrue(self.entitlement.offersNewSubscriptions)
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark")
        }
        XCTAssertEqual(self.entitlement.localGraceEndsAt, flip.addingTimeInterval(SGEntitlementLocalGrace.defaultDuration), "free until seven days after the flip")

        let free = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_061)
        XCTAssertEqual(free, .adopted)
        XCTAssertEqual(self.entitlement.monetizationMode, .free)
        XCTAssertEqual(self.entitlement.source, .freeAccess)
        XCTAssertTrue(self.entitlement.can(.createTask))
        XCTAssertNil(self.entitlement.localGraceEndsAt, "free access is not a countdown")
        XCTAssertFalse(self.entitlement.offersNewSubscriptions, "a paywall still on screen must not start a purchase now")
    }

    func test_anOldInstallWhosePaidModeGraceIsOverIsDegradedOncePaid() async {
        // First launched two months ago; the owner flipped paid a month ago (the pinned mark): the
        // seven days from the flip are over and nothing paid grants, so creates show the paywall.
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: Date().addingTimeInterval(-60 * 86400), firstPaidPolicyAt: Date().addingTimeInterval(-30 * 86400)))
        await self.adoptPaid()
        XCTAssertEqual(self.entitlement.state, .degraded(reason: .noToken))
        XCTAssertNil(self.entitlement.localGraceEndsAt)
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .blocked(reason: .noToken))
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(self.entitlement.can(action), "\(action.rawValue): the user's own data never depends on the mode")
        }
    }

    // MARK: - D9: the grace is re-based once, at the first paid adoption

    func test_theGraceIsRebasedOnceAtTheFirstPaidAdoption_notOnALaterFlip() async {
        self.entitlement.resetPaidModeMarkForTesting()
        XCTAssertNil(self.entitlement.paidModeMarkForTesting, "free mode neither reads nor mints the mark")
        XCTAssertNil(self.entitlement.localGraceEndsAt)

        await self.adoptPaid(revision: 1, uptime: 1_000)
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark")
        }
        let endsAt = flip.addingTimeInterval(SGEntitlementLocalGrace.defaultDuration)
        XCTAssertEqual(self.entitlement.localGraceEndsAt, endsAt)

        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_061)
        XCTAssertEqual(self.entitlement.source, .freeAccess)
        await self.adoptPaid(revision: 3, uptime: 1_122)
        XCTAssertEqual(self.entitlement.paidModeMarkForTesting, flip, "never re-minted: a later free -> paid flip re-bases nothing")
        XCTAssertEqual(self.entitlement.localGraceEndsAt, endsAt)

        // The next launch reads the persisted record instead of minting a fresh window.
        let relaunched = self.makeEntitlement()
        relaunched.resetPaidModeMarkForTesting()
        XCTAssertEqual(relaunched.monetizationMode, .paid)
        XCTAssertEqual(relaunched.localGraceEndsAt?.timeIntervalSince1970 ?? 0, endsAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(relaunched.paidModeMarkForTesting?.timeIntervalSince1970 ?? 0, flip.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - The local grace's length is the accepted signed policy's `local_grace_days`

    private let day: TimeInterval = 86400

    /// "Now" on the ACCOUNT evaluation clock, which is what the grace window is evaluated against
    /// (`SGEntitlementClock.effectiveNow`). Deliberately not `Date()`: the shared clock mark that
    /// other tests in this process move can hold it days away from the wall clock, and a window
    /// pinned "three days ago" must be three days ago on the clock that judges it.
    private var graceNow: Date {
        return SGEntitlementClock.shared.effectiveNow()
    }

    /// An install first launched two months ago that the paid policy reached `daysAgo` days ago:
    /// both records pinned, on the evaluation clock. Returns the flip.
    private func pinGrace(flippedDaysAgo daysAgo: Double) -> Date {
        let now = self.graceNow
        let flip = now.addingTimeInterval(-daysAgo * self.day)
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: now.addingTimeInterval(-60 * self.day), firstPaidPolicyAt: flip))
        return flip
    }

    private func adopt(_ token: String, uptime: TimeInterval) async {
        let result = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(token)), uptime: uptime)
        XCTAssertEqual(result, .adopted, "premise: the policy was adopted")
    }

    private func assertGraceEnds(_ expected: Date, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let endsAt = self.entitlement.localGraceEndsAt else {
            return XCTFail("no 'free until' date: \(message)", file: file, line: line)
        }
        XCTAssertEqual(endsAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, message, file: file, line: line)
    }

    private func assertNoGrace(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.entitlement.state, .degraded(reason: .noToken), message, file: file, line: line)
        XCTAssertEqual(self.entitlement.source, SGEntitlementSource.none, message, file: file, line: line)
        XCTAssertNil(self.entitlement.localGraceEndsAt, "no 'free until' date: \(message)", file: file, line: line)
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .blocked(reason: .noToken), message, file: file, line: line)
    }

    func test_theGraceLastsTheSignedDaysFromTheFlip_oneSevenAndThirty() async {
        // The real paid-policy mark (D9): minted by the first paid evaluation, through the owned store.
        self.entitlement.resetPaidModeMarkForTesting()
        XCTAssertEqual(self.entitlement.localGraceDays, 7, "no policy yet: the default seven days")
        XCTAssertNil(self.entitlement.localGraceEndsAt, "and no countdown while free")

        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 1), uptime: 1_000)
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark")
        }
        XCTAssertEqual(self.entitlement.signedMonetizationPolicy?.version, 3)
        XCTAssertEqual(self.entitlement.signedMonetizationPolicy?.localGraceDays, 1, "the signed value is kept as signed")
        XCTAssertEqual(self.entitlement.localGraceDays, 1)
        XCTAssertEqual(self.entitlement.source, .localGrace)
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base))
        self.assertGraceEnds(flip.addingTimeInterval(self.day), "free until one day after the flip")

        var uptime: TimeInterval = 1_061
        var revision: Int64 = 2
        for days in [7, 30] {
            await self.adopt(self.policyV3("paid", revision: revision, localGraceDays: days), uptime: uptime)
            XCTAssertEqual(self.entitlement.localGraceDays, days)
            XCTAssertEqual(self.entitlement.source, .localGrace)
            self.assertGraceEnds(flip.addingTimeInterval(TimeInterval(days) * self.day), "free until \(days) days after the flip")
            XCTAssertEqual(self.entitlement.paidModeMarkForTesting, flip, "a change of the length never re-bases the start")
            uptime += 61
            revision += 1
        }
    }

    func test_aZeroDayPolicyNeverGrants_showsNoFreeUntil_andStillMintsTheMark() async {
        self.entitlement.resetPaidModeMarkForTesting()
        await self.adopt(self.policyV3("paid", revision: 1, trialDays: 7, localGraceDays: 0), uptime: 1_000)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
        XCTAssertEqual(self.entitlement.localGraceDays, 0)
        self.assertNoGrace("0 days: 'not active' as soon as the paid policy is read, as for an install whose grace has ended")
        XCTAssertFalse(self.entitlement.can(.createTask))
        XCTAssertFalse(self.entitlement.can(.createRetainedHistoryRecord))
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(self.entitlement.can(action), "\(action.rawValue): the user's own data never depends on the grace")
        }
        XCTAssertTrue(self.entitlement.offersNewSubscriptions, "the offer is what an install without a grant meets")
        XCTAssertEqual(self.entitlement.serverTrialDays, 7, "the server's own trial is another thing, and still offered")
        // The mark records when the flip reached this install even though nothing was granted…
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark under a 0-day policy too")
        }
        // …so a later, longer length counts from it.
        await self.adopt(self.policyV3("paid", revision: 2, trialDays: 7, localGraceDays: 7), uptime: 1_061)
        XCTAssertEqual(self.entitlement.source, .localGrace)
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "seven days from the moment the paid policy was first adopted")
        XCTAssertEqual(self.entitlement.paidModeMarkForTesting, flip)
    }

    func test_aNewlyAdoptedLengthAppliesAtOnce_toTheDecisionTheFreeUntilDateAndTheExtensionsMirror() async {
        // An account is known, so the decision is mirrored for the extensions (`writeMirror`).
        self.entitlement.setActiveAccount(peerId: self.account)
        self.entitlement.resetPaidModeMarkForTesting()
        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 7), uptime: 1_000)
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark")
        }
        XCTAssertEqual(self.entitlement.source, .localGrace, "premise: a running grace")
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "premise: seven days")
        let now = SGEntitlementClock.shared.effectiveNow()
        var mirror = self.entitlement.lastWrittenMirrorForTesting
        XCTAssertEqual(mirror?.source, SGEntitlementSource.localGrace.rawValue)
        XCTAssertEqual(mirror?.until, Int64(flip.addingTimeInterval(7 * self.day).timeIntervalSince1970), "the extensions get the grace's own end")
        XCTAssertEqual(mirror?.state(now: now), .unlocked(capabilities: self.base))

        // Lowered to 0: the running grace ends with the adoption itself — no relaunch, no timer.
        let ended = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        ended.assertForOverFulfill = false
        ended.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.state == .degraded(reason: .noToken)
        }
        await self.adopt(self.policyV3("paid", revision: 2, localGraceDays: 0), uptime: 1_061)
        self.assertNoGrace("a shorter length ends a running grace at once")
        await self.fulfillment(of: [ended], timeout: 5)
        mirror = self.entitlement.lastWrittenMirrorForTesting
        XCTAssertEqual(mirror?.capabilities, [], "the extensions see the same answer the app computes")
        XCTAssertNil(mirror?.until)
        XCTAssertEqual(mirror?.source, SGEntitlementSource.none.rawValue)
        XCTAssertEqual(mirror?.state(now: now), .degraded(reason: .noToken))
        XCTAssertEqual(mirror?.storeKitWithheld.map { $0.capabilities }, [], "…with or without the StoreKit fallback")
        XCTAssertEqual(self.entitlement.paidModeMarkForTesting, flip, "never re-minted")

        // Raised to 30: the ended grace is revived, from the SAME start.
        let revived = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        revived.assertForOverFulfill = false
        revived.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.source == .localGrace
        }
        await self.adopt(self.policyV3("paid", revision: 3, localGraceDays: 30), uptime: 1_122)
        XCTAssertEqual(self.entitlement.source, .localGrace, "a longer length revives an ended grace at once")
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base))
        XCTAssertTrue(self.entitlement.can(.createTask))
        self.assertGraceEnds(flip.addingTimeInterval(30 * self.day), "thirty days from the original start")
        await self.fulfillment(of: [revived], timeout: 5)
        mirror = self.entitlement.lastWrittenMirrorForTesting
        XCTAssertEqual(mirror?.source, SGEntitlementSource.localGrace.rawValue)
        XCTAssertEqual(mirror?.until, Int64(flip.addingTimeInterval(30 * self.day).timeIntervalSince1970), "the mirror carries the new end")
        XCTAssertEqual(mirror?.state(now: now), .unlocked(capabilities: self.base))
        XCTAssertEqual(mirror?.state(now: flip.addingTimeInterval(30 * self.day)), .degraded(reason: .noToken), "and an extension stops on that second by itself")
        XCTAssertEqual(self.entitlement.paidModeMarkForTesting, flip)

        // A purchase's own fresh policy is adopted the same way: its length applies before it returns.
        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policyV3("paid", revision: 4, localGraceDays: 0))))
        XCTAssertEqual(authorization, .paid)
        self.assertNoGrace("the policy fetched for a purchase carries the length too")
        XCTAssertEqual(self.entitlement.lastWrittenMirrorForTesting?.capabilities, [])
    }

    func test_midGrace_aShorterLengthEndsIt_aLongerOneExtendsIt_andAnEndedOneIsRevived() async {
        // First launched two months ago; the paid policy reached this install three days ago.
        let flip = self.pinGrace(flippedDaysAgo: 3)

        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 7), uptime: 1_000)
        XCTAssertEqual(self.entitlement.source, .localGrace, "day 3 of 7: running")
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "four days left")

        await self.adopt(self.policyV3("paid", revision: 2, localGraceDays: 2), uptime: 1_061)
        self.assertNoGrace("lowered to 2 on day 3: the window ended yesterday")

        await self.adopt(self.policyV3("paid", revision: 3, localGraceDays: 30), uptime: 1_122)
        XCTAssertEqual(self.entitlement.source, .localGrace, "raised to 30: the ended grace runs again")
        self.assertGraceEnds(flip.addingTimeInterval(30 * self.day), "27 days left — counted from the original start, not 30 fresh ones")

        await self.adopt(self.policyV3("paid", revision: 4, localGraceDays: 5), uptime: 1_183)
        XCTAssertEqual(self.entitlement.source, .localGrace, "lowered to 5 on day 3: still running, with the nearer end")
        self.assertGraceEnds(flip.addingTimeInterval(5 * self.day), "two days left")

        await self.adopt(self.policyV3("paid", revision: 5, localGraceDays: 0), uptime: 1_244)
        self.assertNoGrace("0 switches the grace off whatever day it is")

        // The length is the POLICY's: nothing on the pinned record can supply one.
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: self.graceNow.addingTimeInterval(-60 * self.day), firstPaidPolicyAt: flip, days: 30))
        self.assertNoGrace("a length that is not the signed policy's is never used")
    }

    func test_theHorizonOneShotIsReArmedAtTheNewEnd_whenAnAdoptedPolicyMovesIt() async {
        // The paid policy reached this install one day minus three seconds ago. Under a 30-day
        // policy the grace ends in 29 days, and that is where the one-shot is armed.
        let now = self.graceNow
        let flip = now.addingTimeInterval(-self.day + 3)
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: now.addingTimeInterval(-60 * self.day), firstPaidPolicyAt: flip))
        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 30), uptime: 1_000)
        XCTAssertEqual(self.entitlement.source, .localGrace, "premise: a running grace, 29 days left")
        self.assertGraceEnds(flip.addingTimeInterval(30 * self.day), "premise: thirty days")

        // Lowered to one day: the window now closes three seconds after `now`.
        await self.adopt(self.policyV3("paid", revision: 2, localGraceDays: 1), uptime: 1_061)
        XCTAssertEqual(self.entitlement.source, .localGrace, "premise: still inside the one-day window, for a moment more")
        self.assertGraceEnds(flip.addingTimeInterval(self.day), "the new end")

        // From here on NOTHING asks a gate: the close must arrive from the one-shot the adoption's
        // recompute re-armed at the NEW end — one still armed 29 days away would never post it.
        let closed = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        closed.assertForOverFulfill = false
        closed.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.state == .degraded(reason: .noToken)
        }
        await self.fulfillment(of: [closed], timeout: 15)
        XCTAssertNil(self.entitlement.localGraceEndsAt)
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .blocked(reason: .noToken))
    }

    func test_aVer2PolicyAVer1PolicyAndNoPolicyMeanSevenDays_andAnOlderShapeAfterAV3PutsItBack() async {
        let flip = self.pinGrace(flippedDaysAgo: 3)
        XCTAssertEqual(self.entitlement.localGraceDays, 7, "no policy: seven days")

        // What a server that does not know v3 yet answers this build: v2. Its trial_days is not the
        // grace's length.
        await self.adopt(self.policyV2("paid", revision: 1, trialDays: 30), uptime: 1_000)
        XCTAssertEqual(self.entitlement.localGraceDays, 7, "a ver-2 policy cannot say: seven days")
        XCTAssertEqual(self.entitlement.source, .localGrace)
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "seven days from the flip, exactly as before this build")

        await self.adopt(self.policyV3("paid", revision: 2, trialDays: 30, localGraceDays: 0), uptime: 1_061)
        XCTAssertEqual(self.entitlement.localGraceDays, 0)
        self.assertNoGrace("the first ver-3 policy applies its length")

        // The last ACCEPTED policy decides: a newer ver-2 (then ver-1) issuance is seven days again.
        await self.adopt(self.policyV2("paid", revision: 3, trialDays: 30), uptime: 1_122)
        XCTAssertEqual(self.entitlement.localGraceDays, 7)
        XCTAssertEqual(self.entitlement.source, .localGrace)
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "last accepted policy is ver 2: seven days")
        await self.adopt(self.policy("paid", revision: 4), uptime: 1_183)
        XCTAssertEqual(self.entitlement.localGraceDays, 7)
        self.assertGraceEnds(flip.addingTimeInterval(7 * self.day), "last accepted policy is ver 1: seven days")
    }

    func test_aVer3PolicyWithABadLocalGraceDaysIsRefused_andTheAcceptedLengthStays() async {
        let flip = self.pinGrace(flippedDaysAgo: 3)
        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 5), uptime: 1_000)
        self.assertGraceEnds(flip.addingTimeInterval(5 * self.day), "premise: five days")

        var uptime: TimeInterval = 1_061
        let bad: [Any] = [31, -1, "7", true, NSNull()]
        for value in bad {
            // A newer revision that would also turn the app free: none of it is taken.
            var claims = SGEntitlementTestPolicy.claims(mode: "free", revision: 9, iat: self.policyNow, version: 3, trialDays: 0, localGraceDays: 7)
            claims["local_grace_days"] = value
            let token = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: claims)
            let refused = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(token)), uptime: uptime)
            XCTAssertEqual(refused, .rejected, "local_grace_days \(value)")
            XCTAssertEqual(self.entitlement.monetizationMode, .paid)
            XCTAssertEqual(self.entitlement.localGraceDays, 5, "the last accepted policy stays, with its own length")
            self.assertGraceEnds(flip.addingTimeInterval(5 * self.day), "unchanged by the refused token")
            uptime += 61
        }
        var missing = SGEntitlementTestPolicy.claims(mode: "free", revision: 9, iat: self.policyNow, version: 3, trialDays: 0, localGraceDays: 7)
        missing.removeValue(forKey: "local_grace_days")
        let withoutClaim = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: missing))), uptime: uptime)
        XCTAssertEqual(withoutClaim, .rejected)
        XCTAssertEqual(self.entitlement.localGraceDays, 5)
        // A bad `trial_days` inside a ver-3 token refuses the whole token: its own, valid
        // `local_grace_days` (0 here, which would end the grace) is not adopted either.
        var badTrial = SGEntitlementTestPolicy.claims(mode: "paid", revision: 9, iat: self.policyNow, version: 3, trialDays: 0, localGraceDays: 0)
        badTrial["trial_days"] = 31
        let withBadTrial = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: badTrial))), uptime: uptime + 61)
        XCTAssertEqual(withBadTrial, .rejected)
        XCTAssertEqual(self.entitlement.localGraceDays, 5)
        XCTAssertEqual(self.entitlement.source, .localGrace)
        self.assertGraceEnds(flip.addingTimeInterval(5 * self.day), "unchanged by a token refused for its trial_days")
        // A refused policy admits no purchase either.
        var outOfRange = SGEntitlementTestPolicy.claims(mode: "paid", revision: 9, iat: self.policyNow, version: 3, trialDays: 0, localGraceDays: 7)
        outOfRange["local_grace_days"] = 31
        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: outOfRange))))
        XCTAssertEqual(authorization, .unavailable)
        XCTAssertEqual(self.entitlement.signedMonetizationPolicy?.revision, 1)
        XCTAssertEqual(self.entitlement.localGraceDays, 5)
    }

    func test_theLengthIsDerivedFromTheStoredSignedTokenByEveryProcess_andStoredNowhereElse() async {
        self.entitlement.resetPaidModeMarkForTesting()
        await self.adopt(self.policyV3("paid", revision: 1, localGraceDays: 3), uptime: 1_000)
        guard let flip = self.entitlement.paidModeMarkForTesting else {
            return XCTFail("the first paid evaluation mints the mark")
        }
        self.assertGraceEnds(flip.addingTimeInterval(3 * self.day), "premise: three days")

        // Another instance over the same Keychain records and the same policy slot — the next
        // launch, or another process of the app group — re-verifies the stored token and derives
        // the same length from it.
        let other = self.makeEntitlement()
        other.resetPaidModeMarkForTesting()
        XCTAssertEqual(other.monetizationMode, .paid)
        XCTAssertEqual(other.localGraceDays, 3)
        XCTAssertEqual(other.source, .localGrace)
        XCTAssertEqual(other.localGraceEndsAt?.timeIntervalSince1970 ?? 0, flip.addingTimeInterval(3 * self.day).timeIntervalSince1970, accuracy: 0.001)

        // The policy slot holds the signed token and the notice marker — no length of its own.
        let stored = UserDefaults(suiteName: self.policySuite)?.persistentDomain(forName: self.policySuite) ?? [:]
        let tokenKeys = stored.keys.filter { !$0.hasSuffix(".noticed") }
        XCTAssertEqual(tokenKeys.count, 1, "one policy slot: \(stored.keys.sorted())")
        XCTAssertTrue(tokenKeys.allSatisfy { $0.hasPrefix("\(SGEntitlementPolicyStore.defaultsKey)@") })
        XCTAssertEqual(tokenKeys.first.flatMap { stored[$0] as? String }, self.entitlement.signedMonetizationPolicy?.token, "the exact signed bytes")
        XCTAssertEqual(Set(stored.keys), Set(tokenKeys + tokenKeys.map { "\($0).noticed" }), "nothing else is stored beside it")

        // A ring that no longer verifies the stored token has no policy at all: free — and, were it
        // paid, the default seven days, never the length of a token it cannot verify.
        let rotatedRing = self.makeEntitlement(pinned: SGEntitlementTestToken.pinned(P256.Signing.PrivateKey(), kid: self.kid))
        XCTAssertEqual(rotatedRing.monetizationMode, .free)
        XCTAssertEqual(rotatedRing.localGraceDays, 7)
        XCTAssertNil(rotatedRing.localGraceEndsAt)
    }

    func test_whileFreeTheSignedLengthHasNoEffect() async {
        self.entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: self.graceNow.addingTimeInterval(-86400)))
        await self.adopt(self.policyV3("free", revision: 1, localGraceDays: 0), uptime: 1_000)
        XCTAssertEqual(self.entitlement.localGraceDays, 0, "signed in both modes")
        XCTAssertEqual(self.entitlement.source, .freeAccess, "a 0-day length takes nothing away while free")
        XCTAssertEqual(self.entitlement.state, .unlocked(capabilities: self.base))
        XCTAssertNil(self.entitlement.localGraceEndsAt)
        await self.adopt(self.policyV3("free", revision: 2, localGraceDays: 30), uptime: 1_061)
        XCTAssertEqual(self.entitlement.source, .freeAccess, "and a long one adds no countdown")
        XCTAssertNil(self.entitlement.localGraceEndsAt)
    }

    // MARK: - D9: the one-time notice on the first blocked create, once per flip to paid

    private func adoptFree(revision: Int64, uptime: TimeInterval) async {
        let result = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: revision))), uptime: uptime)
        XCTAssertEqual(result, .adopted, "premise: free adopted")
    }

    func test_theNoticeFiresOnceOnTheFirstBlockedCreate_perFlipToPaid() async {
        // An old install running under the signed free policy, as every install does before the flip.
        await self.adoptFree(revision: 0, uptime: 900)
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "nothing to announce while free")
        await self.adoptPaid(revision: 1, uptime: 1_000)
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .blocked(reason: .noToken), "premise: a blocked create (the pinned grace is long over, no mark)")
        XCTAssertEqual(self.entitlement.takePaidModeNotice(for: .noToken), .paidModeNotice)
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "once")
        XCTAssertNil(self.makeEntitlement().takePaidModeNotice(for: .noToken), "a relaunch does not repeat it")
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .lapsed), "other reasons carry their own copy")

        // The server bumps `revision` on every admin `set` (a price text, a trial setting), so a
        // paid -> paid revision is not a flip and must not re-announce.
        await self.adoptPaid(revision: 2, uptime: 1_061)
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "a paid -> paid revision bump is not a flip")

        await self.adoptFree(revision: 3, uptime: 1_122)
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "free again: nothing blocks, nothing to announce")
        await self.adoptPaid(revision: 4, uptime: 1_183)
        XCTAssertEqual(self.entitlement.takePaidModeNotice(for: .noToken), .paidModeNotice, "a second free -> paid flip is a new flip")
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken))
    }

    func test_aPendingNoticeSurvivesAPaidToPaidRevisionBump() async {
        await self.adoptFree(revision: 0, uptime: 900)
        await self.adoptPaid(revision: 1, uptime: 1_000)
        // No create was blocked yet when the operator edits the paid policy again.
        await self.adoptPaid(revision: 2, uptime: 1_061)
        XCTAssertEqual(self.entitlement.takePaidModeNotice(for: .noToken), .paidModeNotice, "the flip was never announced: the bump must not swallow it")
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "once")
    }

    func test_anInstallWhoseFirstPolicyIsAlreadyPaidGetsNoNotice() async {
        // First launched after the flip: the first policy this install adopts is paid, so "Zenlygram
        // Pro is now a subscription" would be false copy for it. The grace is pinned expired, so the
        // create is blocked exactly as it would be on its day 8.
        await self.adoptPaid(revision: 5, uptime: 1_000)
        XCTAssertEqual(self.entitlement.gate(.createVaultEntry), .blocked(reason: .noToken), "premise: a blocked create")
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "no flip reached this install")
        XCTAssertNil(self.makeEntitlement().takePaidModeNotice(for: .noToken), "nor after a relaunch")
        await self.adoptPaid(revision: 6, uptime: 1_061)
        XCTAssertNil(self.entitlement.takePaidModeNotice(for: .noToken), "a later paid revision is still not a flip")
    }

    // MARK: - D8: a server flip reaches an open app (push hook, 30-minute timer, the 60 s gate)

    /// How many times a scripted policy transport was asked. The lock is touched only inside
    /// synchronous members, so the transport's `async` fetch never holds an `NSLock` itself.
    private final class FetchCounter {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }

        var value: Int {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.count
        }
    }

    /// A policy transport that counts its fetches and answers `token`.
    private func counting(_ token: String) -> (transport: SGEntitlementPolicyTransport, fetches: () -> Int, fetched: XCTestExpectation) {
        let fetched = self.expectation(description: "the policy was fetched")
        fetched.assertForOverFulfill = false
        let counter = FetchCounter()
        let transport = SGEntitlementPolicyTransport(fetch: {
            counter.increment()
            fetched.fulfill()
            return .success(token)
        })
        return (transport, { counter.value }, fetched)
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Fulfilled by the `didChangeNotification` the ADOPTION posts — not by an earlier one (the
    /// first decision `applicationDidBecomeActive` computes posts too), so a test can assert the
    /// mode only once `finishPolicyAttempt` and `recompute` have run in the detached task
    /// `refreshMonetizationPolicy()` spawns. The transport's own `fetched` expectation fires before
    /// either, so the mode read right after it would race.
    private func adoptedPaid() -> XCTestExpectation {
        let changed = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        changed.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.monetizationMode == .paid
        }
        return changed
    }

    func test_aSilentPushRefreshesThePolicyBeforeTheTokens_throughTheGate() async {
        let counting = self.counting(self.policy("paid", revision: 1))
        self.entitlement.installPolicyTransportForTesting(counting.transport)
        self.entitlement.setAccounts(SGEntitlementAccounts(primary: nil, all: []))
        let adopted = self.adoptedPaid()
        let answered = self.expectation(description: "UIKit answered")
        self.entitlement.handleSilentPush(completion: { outcome in
            XCTAssertEqual(outcome, .noData, "no linked account: no token refresh — the policy fetch takes no part in the outcome")
            answered.fulfill()
        })
        await self.fulfillment(of: [counting.fetched, adopted, answered], timeout: 5)
        XCTAssertEqual(counting.fetches(), 1)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid, "the flip reached a backgrounded app")

        // A second push seconds later lands inside the 60 s cooldown: nothing is sent.
        let again = self.expectation(description: "answered again")
        self.entitlement.handleSilentPush(completion: { _ in
            again.fulfill()
        })
        await self.fulfillment(of: [again], timeout: 5)
        await self.settle(0.3)
        XCTAssertEqual(counting.fetches(), 1, "every trigger goes through SGEntitlementPolicyRefreshGate")
    }

    func test_thePeriodicPolicyRefreshRunsWhileActive_everyTickThroughTheGate_andStopsOnResignActive() async {
        let counting = self.counting(self.policy("paid", revision: 1))
        self.entitlement.installPolicyTransportForTesting(counting.transport)
        XCTAssertEqual(SGEntitlementScheduler.policyRefreshInterval, 1800, "a flip reaches an open app within 30 minutes")
        XCTAssertFalse(self.entitlement.isPolicyRefreshTimerScheduled)

        self.entitlement.applicationDidBecomeActive()
        XCTAssertTrue(self.entitlement.isPolicyRefreshTimerScheduled)
        self.entitlement.applicationDidBecomeActive()
        XCTAssertTrue(self.entitlement.isPolicyRefreshTimerScheduled, "a second become-active keeps the running timer")

        // Before the first idle window nothing reaches the network (invariant I1).
        self.entitlement.policyRefreshTimerDidFire()
        await self.settle(0.3)
        XCTAssertEqual(counting.fetches(), 0)

        self.entitlement.markFirstIdlePassedForTesting()
        let adopted = self.adoptedPaid()
        self.entitlement.policyRefreshTimerDidFire()
        await self.fulfillment(of: [counting.fetched, adopted], timeout: 5)
        XCTAssertEqual(counting.fetches(), 1)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
        self.entitlement.policyRefreshTimerDidFire()
        await self.settle(0.3)
        XCTAssertEqual(counting.fetches(), 1, "a tick inside the 60 s cooldown sends nothing")

        self.entitlement.applicationWillResignActive()
        XCTAssertFalse(self.entitlement.isPolicyRefreshTimerScheduled, "the timer stops with the foreground")
    }

    func test_anAdoptedPolicyPublishesAChange() {
        let changed = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        let entitlement = self.entitlement!
        let transport = self.answering(.success(self.policy("paid", revision: 1)))
        Task {
            _ = await entitlement.performPolicyRefresh(transport: transport, uptime: 1_000)
        }
        self.wait(for: [changed], timeout: 5)
    }

    // MARK: - The server's trial (`trial_days`)

    func test_aChangeOfTrialDaysAloneIsPublished_thoughNoDecisionMoves() async {
        // The decision reflects the MODE; an open paywall reads `serverTrialDays` beside it and must
        // learn about a trial the operator enabled, changed or disabled under the same mode.
        let first = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        first.assertForOverFulfill = false
        let seven = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("paid", revision: 1, trialDays: 7))), uptime: 1_000)
        XCTAssertEqual(seven, .adopted)
        await self.fulfillment(of: [first], timeout: 5)
        await self.settle(0.3)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
        XCTAssertEqual(self.entitlement.serverTrialDays, 7)
        let decision = self.entitlement.state
        let source = self.entitlement.source

        let changed = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        changed.assertForOverFulfill = false
        changed.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.serverTrialDays == 14
        }
        let fourteen = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("paid", revision: 2, trialDays: 14))), uptime: 1_061)
        XCTAssertEqual(fourteen, .adopted)
        await self.fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(self.entitlement.serverTrialDays, 14)
        XCTAssertEqual(self.entitlement.state, decision, "the decision itself did not move: only the offer did")
        XCTAssertEqual(self.entitlement.source, source)

        let disabled = XCTNSNotificationExpectation(name: SGEntitlement.didChangeNotification)
        disabled.assertForOverFulfill = false
        disabled.handler = { [entitlement = self.entitlement!] _ in
            return entitlement.serverTrialDays == nil
        }
        let none = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("paid", revision: 3, trialDays: 0))), uptime: 1_122)
        XCTAssertEqual(none, .adopted)
        await self.fulfillment(of: [disabled], timeout: 5)
        XCTAssertNil(self.entitlement.serverTrialDays, "the operator disabled the trial: the button goes within one refresh")
        XCTAssertEqual(self.entitlement.monetizationMode, .paid, "still paid")
        XCTAssertEqual(self.entitlement.state, decision)

        // The same issuance again changes nothing and publishes nothing new to say.
        let same = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("paid", revision: 3, trialDays: 0))), uptime: 1_183)
        XCTAssertEqual(same, .unchanged)
    }

    func test_aFreshlyFetchedV2PaidPolicyAuthorizesAPurchase_andTheTrialIsNeverAdmission() async {
        let adopted = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("paid", revision: 1, trialDays: 7))), uptime: 1_000)
        XCTAssertEqual(adopted, .adopted)
        XCTAssertEqual(self.entitlement.serverTrialDays, 7)

        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policyV2("paid", revision: 1, trialDays: 7))))
        XCTAssertEqual(authorization, .paid, "a v2 paid policy admits a purchase exactly as a v1 one does")
        XCTAssertEqual(self.entitlement.serverTrialDays, 7, "the trial is an offer the paywall shows, never what admits a purchase")

        // The same issuance answered in its v1 shape: the same admission, and the held v2 stands.
        let v1 = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 1))))
        XCTAssertEqual(v1, .paid)
        XCTAssertEqual(self.entitlement.serverTrialDays, 7, "a v1 of the issuance held as v2 is unchanged")

        // A paid policy with no trial admits the purchase just the same: the trial gates nothing.
        let withoutTrial = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policyV2("paid", revision: 2, trialDays: 0))))
        XCTAssertEqual(withoutTrial, .paid)
        XCTAssertNil(self.entitlement.serverTrialDays)

        // A fresh free policy naming days refuses the purchase and offers no trial either.
        let free = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policyV2("free", revision: 3, trialDays: 7))))
        XCTAssertEqual(free, .free)
        XCTAssertEqual(self.entitlement.monetizationMode, .free)
        XCTAssertNil(self.entitlement.serverTrialDays, "never a trial while free")
    }

    func test_theServerTrialIsNilBeforeAnyPolicyAndWhileFree() async {
        XCTAssertNil(self.entitlement.serverTrialDays, "a fresh install offers no trial: it has no verified policy")
        XCTAssertEqual(self.entitlement.monetizationMode, .free)
        let free = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policyV2("free", revision: 1, trialDays: 7))), uptime: 1_000)
        XCTAssertEqual(free, .adopted)
        XCTAssertEqual(self.entitlement.signedMonetizationPolicy?.trialDays, 7, "the signed value is kept as signed")
        XCTAssertNil(self.entitlement.serverTrialDays, "never while free, whatever the signed days: nothing is sold, a trial included")
        XCTAssertEqual(self.entitlement.source, .freeAccess)
    }

    func test_aNetworkFailureKeepsTheLastVerifiedMode() async {
        let failedFree = await self.entitlement.performPolicyRefresh(transport: self.offline, uptime: 1_000)
        XCTAssertEqual(failedFree, .failed)
        XCTAssertEqual(self.entitlement.monetizationMode, .free, "a failure never enables paid")

        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_061)
        let failedPaid = await self.entitlement.performPolicyRefresh(transport: self.offline, uptime: 1_122)
        XCTAssertEqual(failedPaid, .failed)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid, "nor does it fall back to free")
    }

    func test_anUnverifiableOrStaleFetchChangesNothing() async {
        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 3))), uptime: 1_000)
        let forged = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, mode: "free", revision: 9, iat: self.policyNow)
        let rejected = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(forged)), uptime: 1_061)
        XCTAssertEqual(rejected, .rejected)
        let older = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_122)
        XCTAssertEqual(older, .rejected)
        let expired = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 4, iat: self.policyNow - 86400 - 600))), uptime: 1_183)
        XCTAssertEqual(expired, .rejected)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
    }

    func test_oneRequestInFlightAndAtLeastSixtySecondsBetweenAttempts() async {
        var answer: AsyncStream<Result<String, SGEntitlementRequestError>>.Continuation?
        let answers = AsyncStream<Result<String, SGEntitlementRequestError>> { answer = $0 }
        var entered: AsyncStream<Void>.Continuation?
        let enteredSignal = AsyncStream<Void> { entered = $0 }
        let entitlement = self.entitlement!
        let first = Task {
            await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: {
                entered?.yield(())
                var iterator = answers.makeAsyncIterator()
                return await iterator.next() ?? .failure(SGEntitlementRequestError(failure: .offline(.timeout)))
            }), uptime: 1_000)
        }
        var enteredIterator = enteredSignal.makeAsyncIterator()
        _ = await enteredIterator.next()
        let concurrent = await entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_001)
        XCTAssertEqual(concurrent, .skipped, "one policy request in flight")

        answer?.yield(.success(self.policy("paid", revision: 1)))
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .adopted)

        let tooSoon = await entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_030)
        XCTAssertEqual(tooSoon, .skipped)
        XCTAssertEqual(entitlement.monetizationMode, .paid)
        let later = await entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_061)
        XCTAssertEqual(later, .adopted)
    }

    func test_thePolicyFetchNeedsNoBinding() async {
        XCTAssertNil(self.entitlement.activeAccountPeerId)
        XCTAssertFalse(self.entitlement.isLinked(accountPeerId: self.account))
        let result = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_000)
        XCTAssertEqual(result, .adopted)
    }

    // MARK: - Persistence

    func test_theAcceptedPolicyIsReverifiedOnTheNextLaunch() async {
        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1, iat: self.policyNow - 86000))), uptime: 1_000)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)

        let relaunched = self.makeEntitlement()
        XCTAssertEqual(relaunched.monetizationMode, .paid, "the persisted signed policy is reverified, and its own expiry does not change it")

        let rotatedRing = self.makeEntitlement(pinned: SGEntitlementTestToken.pinned(P256.Signing.PrivateKey(), kid: self.kid))
        XCTAssertEqual(rotatedRing.monetizationMode, .free, "a stored policy the ring no longer verifies is no policy at all")
    }

    // MARK: - Genuine paid grants

    func test_aGenuineGrantSurvivesPolicyRevisions() async {
        self.seedSession(account: .explicit(ent: ["vault", "chatlock", "tasks", "edithistory"], until: "2030-01-01T00:00:00Z"))
        let token = self.store.session(accountPeerId: self.account).entitlement

        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_000)
        XCTAssertEqual(self.entitlement.source, .token)
        XCTAssertTrue(self.entitlement.can(.createVaultEntry))

        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("free", revision: 2))), uptime: 1_061)
        XCTAssertEqual(self.entitlement.source, .freeAccess)

        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 3))), uptime: 1_122)
        XCTAssertEqual(self.entitlement.source, .token, "the same genuine grant keeps paying across revisions")
        XCTAssertTrue(self.entitlement.can(.createVaultEntry))
        XCTAssertEqual(self.store.session(accountPeerId: self.account).entitlement, token, "no policy change touches the account's token")
    }

    func test_aLegacyTokenIsNotPaidProofOnceNotFree() async {
        self.seedSession(account: .omitted)
        XCTAssertTrue(self.entitlement.can(.createTask), "premise: free")
        _ = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: 1))), uptime: 1_000)
        XCTAssertFalse(self.entitlement.can(.createTask), "legacy ent/until is not a paid grant")
        XCTAssertTrue(self.entitlement.isLinked(accountPeerId: self.account), "the binding stays usable for restore and refresh")
        XCTAssertNotNil(self.entitlement.sessionCredential(accountPeerId: self.account))
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(self.entitlement.can(action), "\(action.rawValue): the user's own data never depends on the mode")
        }
    }

    // MARK: - Fresh authorization for a NEW purchase (contract x-client-state.apple_purchase_admission)

    private func adoptPaid(revision: Int64 = 1, uptime: TimeInterval = 1_000) async {
        let result = await self.entitlement.performPolicyRefresh(transport: self.answering(.success(self.policy("paid", revision: revision))), uptime: uptime)
        XCTAssertEqual(result, .adopted, "premise: paid adopted")
    }

    func test_aFreshlyFetchedPaidPolicyAuthorizesAPurchase() async {
        await self.adoptPaid()
        let fresh = self.policy("paid", revision: 1)
        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(fresh)))
        XCTAssertEqual(authorization, .paid)
    }

    func test_aPurchaseIsNeverAuthorizedByTheCachedPaidPolicy() async {
        await self.adoptPaid()
        XCTAssertTrue(self.entitlement.offersNewSubscriptions, "premise: the cached policy is paid")
        let offline = await self.entitlement.authorizeNewPurchase(transport: self.offline)
        XCTAssertEqual(offline, .unavailable, "a transport failure must not fall back to the cached paid mode")
        let unavailable = await self.entitlement.authorizeNewPurchase(transport: self.answering(.failure(SGEntitlementRequestError(failure: .offline(.serverError)))))
        XCTAssertEqual(unavailable, .unavailable)
        let forged = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, mode: "paid", revision: 9, iat: self.policyNow)
        let invalid = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(forged)))
        XCTAssertEqual(invalid, .unavailable, "an unverifiable answer authorizes nothing")
        let stale = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 2, iat: self.policyNow - 86400 - 600))))
        XCTAssertEqual(stale, .unavailable, "an expired paid policy authorizes nothing")
        let older = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 0))))
        XCTAssertEqual(older, .unavailable, "an older paid policy than the accepted one authorizes nothing")
        XCTAssertEqual(self.entitlement.monetizationMode, .paid, "a failed authorization changes no mode")
    }

    func test_aFreshFreePolicyRefusesThePurchase_andIsAdopted() async {
        await self.adoptPaid()
        let free = self.policy("free", revision: 2)
        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(free)))
        XCTAssertEqual(authorization, .free)
        XCTAssertEqual(self.entitlement.monetizationMode, .free, "the fresh free policy is the newest truth: adopted like any refresh")
        XCTAssertFalse(self.entitlement.offersNewSubscriptions)
    }

    func test_aConflictingEqualIssuanceAuthorizesNothing() async {
        await self.adoptPaid(revision: 3)
        let conflict = self.policy("free", revision: 3)
        let conflictingAuthorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(conflict)))
        XCTAssertEqual(conflictingAuthorization, .unavailable)
        let matchingAuthorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 3))))
        XCTAssertEqual(matchingAuthorization, .paid, "the same paid issuance, freshly signed, is fresh")
    }

    func test_authorizationIsNotHeldBackByTheRefreshCooldown_butRespectsTheOneRequestInFlight() async {
        await self.adoptPaid(uptime: ProcessInfo.processInfo.systemUptime)
        // A background refresh ran seconds ago; the user's purchase still gets its own fresh fetch.
        let soon = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 1))))
        XCTAssertEqual(soon, .paid)

        var answer: AsyncStream<Result<String, SGEntitlementRequestError>>.Continuation?
        let answers = AsyncStream<Result<String, SGEntitlementRequestError>> { answer = $0 }
        let entered = self.expectation(description: "the background policy request started")
        let entitlement = self.entitlement!
        let backgroundUptime = ProcessInfo.processInfo.systemUptime + 61
        let background = Task {
            await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: {
                entered.fulfill()
                var iterator = answers.makeAsyncIterator()
                return await iterator.next() ?? .failure(SGEntitlementRequestError(failure: .offline(.timeout)))
            }), uptime: backgroundUptime)
        }
        defer {
            answer?.finish()
            background.cancel()
        }
        await self.fulfillment(of: [entered], timeout: 5)
        let busy = await entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 1))))
        XCTAssertEqual(busy, .busy, "one policy request in flight: the purchase is refused, never authorized by the request it did not make")
        answer?.yield(.success(self.policy("paid", revision: 1)))
        _ = await background.value
    }

    func test_authorizationNeedsNoBinding() async {
        await self.adoptPaid()
        XCTAssertNil(self.entitlement.activeAccountPeerId)
        let authorization = await self.entitlement.authorizeNewPurchase(transport: self.answering(.success(self.policy("paid", revision: 1))))
        XCTAssertEqual(authorization, .paid, "an unlinked install may buy (App Review): the public policy is the admission")
    }

    // MARK: - The policy clock (security review M1)

    func test_policyFreshnessFollowsThePolicyClock_whenTheAccountClockIsBehindIt() async {
        // The account mark moves with every other response's UNSIGNED `server_time`; the policy is
        // checked against its own clock only. Issued three days past the account clock: still fresh.
        let ahead = SGEntitlementClock.shared.effectiveNow().addingTimeInterval(3 * 86400)
        let entitlement = self.makeEntitlement(policyClock: { ahead })
        let token = self.policy("paid", revision: 1, iat: Int64(ahead.timeIntervalSince1970))
        let result = await entitlement.performPolicyRefresh(transport: self.answering(.success(token)), uptime: 1_000)
        XCTAssertEqual(result, .adopted)
        XCTAssertEqual(entitlement.monetizationMode, .paid)
    }

    func test_policyFreshnessFollowsThePolicyClock_whenTheAccountClockIsAheadOfIt() async {
        // The other direction: fresh by the account clock, three days in the policy clock's future.
        let behind = SGEntitlementClock.shared.effectiveNow().addingTimeInterval(-3 * 86400)
        let entitlement = self.makeEntitlement(policyClock: { behind })
        let token = self.policy("paid", revision: 1, iat: self.tokenNow)
        let result = await entitlement.performPolicyRefresh(transport: self.answering(.success(token)), uptime: 1_000)
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(entitlement.monetizationMode, .free)
    }

    // MARK: - A decision made under an older policy (fallback review M4)

    /// Drives a recompute that evaluates under the CURRENT policy, then — while it sits between
    /// evaluation and commit — adopts `next` through the real refresh path. The stale recompute must
    /// never leave its decision in the cache.
    private func adoptWhileARecomputeIsInFlight(_ next: String, uptime: TimeInterval) {
        let entitlement = self.entitlement!
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var isFirst = true
        entitlement.recomputeWillCommitForTesting = {
            hookLock.lock()
            let first = isFirst
            isFirst = false
            hookLock.unlock()
            if first {
                entered.signal()
                release.wait()
            }
        }
        let staleFinished = self.expectation(description: "the stale recompute returned")
        DispatchQueue.global().async {
            entitlement.invalidate()
            staleFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "premise: a recompute is between evaluation and commit")

        let adopted = self.expectation(description: "the new policy was adopted")
        let transport = self.answering(.success(next))
        Task {
            let result = await entitlement.performPolicyRefresh(transport: transport, uptime: uptime)
            XCTAssertEqual(result, .adopted)
            adopted.fulfill()
        }
        self.wait(for: [adopted], timeout: 5)
        release.signal()
        self.wait(for: [staleFinished], timeout: 5)
        entitlement.recomputeWillCommitForTesting = nil
    }

    func test_aFreeDecisionComputedBeforePaidWasAdoptedNeverSticks() {
        self.adoptWhileARecomputeIsInFlight(self.policy("paid", revision: 1), uptime: 1_000)
        XCTAssertEqual(self.entitlement.monetizationMode, .paid)
        XCTAssertEqual(self.entitlement.state, .degraded(reason: .noToken), "an old install with nothing paid must not keep free access after paid was enabled")
        XCTAssertNotEqual(self.entitlement.source, .freeAccess)
    }

    func test_aGraceDecisionComputedBeforeAShorterLengthWasAdoptedNeverSticks() {
        // A running grace under a seven-day policy; a recompute is caught between evaluation and
        // commit while a 0-day policy is adopted. Its "granted until day 7" must not be cached.
        let entitlement = self.entitlement!
        _ = self.pinGrace(flippedDaysAgo: 3)
        let seven = self.answering(.success(self.policyV3("paid", revision: 1, localGraceDays: 7)))
        let premise = self.expectation(description: "seven days adopted")
        Task {
            _ = await entitlement.performPolicyRefresh(transport: seven, uptime: 1_000)
            premise.fulfill()
        }
        self.wait(for: [premise], timeout: 5)
        XCTAssertEqual(entitlement.source, .localGrace, "premise: a running grace")

        self.adoptWhileARecomputeIsInFlight(self.policyV3("paid", revision: 2, localGraceDays: 0), uptime: 1_061)
        XCTAssertEqual(entitlement.localGraceDays, 0)
        XCTAssertEqual(entitlement.state, .degraded(reason: .noToken), "a decision made under the older length must not outlive the adoption")
        XCTAssertNil(entitlement.localGraceEndsAt)

        // …and the other way: "ended" computed under 0 days must not stick once 30 are adopted.
        self.adoptWhileARecomputeIsInFlight(self.policyV3("paid", revision: 3, localGraceDays: 30), uptime: 1_122)
        XCTAssertEqual(entitlement.source, .localGrace, "the user must not stay paywalled after the owner lengthened the grace")
        XCTAssertTrue(entitlement.can(.createTask))
    }

    func test_aPaidDecisionComputedBeforeFreeWasAdoptedNeverSticks() {
        let entitlement = self.entitlement!
        let paid = self.answering(.success(self.policy("paid", revision: 1)))
        let premise = self.expectation(description: "paid adopted")
        Task {
            _ = await entitlement.performPolicyRefresh(transport: paid, uptime: 1_000)
            premise.fulfill()
        }
        self.wait(for: [premise], timeout: 5)
        XCTAssertEqual(entitlement.state, .degraded(reason: .noToken), "premise: paid, nothing granting")
        self.adoptWhileARecomputeIsInFlight(self.policy("free", revision: 2), uptime: 1_061)
        XCTAssertEqual(self.entitlement.monetizationMode, .free)
        XCTAssertEqual(self.entitlement.source, .freeAccess, "the user must not stay paywalled after the owner turned free")
        XCTAssertTrue(self.entitlement.can(.createTask))
    }
}
