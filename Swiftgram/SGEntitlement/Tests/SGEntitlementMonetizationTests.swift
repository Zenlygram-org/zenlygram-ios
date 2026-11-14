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
        XCTAssertEqual(self.entitlement.localGraceEndsAt, flip.addingTimeInterval(SGEntitlementLocalGrace.duration), "free until seven days after the flip")

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
        let endsAt = flip.addingTimeInterval(SGEntitlementLocalGrace.duration)
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
