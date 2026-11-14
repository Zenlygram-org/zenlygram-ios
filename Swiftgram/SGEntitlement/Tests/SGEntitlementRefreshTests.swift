import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Per-account scheduling: one account's refresh never swallows another's, while the budget and the
/// backoff stay device-wide (the server buckets on the install's `X-Device-Id`).
final class SGEntitlementSchedulerAccountTests: XCTestCase {
    private let a: Int64 = 1001
    private let b: Int64 = 1002
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private var suiteName = ""
    private var scheduler: SGEntitlementScheduler!

    override func setUp() {
        super.setUp()
        self.suiteName = "SGEntitlementSchedulerAccountTests.\(UUID().uuidString)"
        self.scheduler = SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.suiteName))
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suiteName)?.removePersistentDomain(forName: self.suiteName)
        self.scheduler = nil
        super.tearDown()
    }

    private var stale: Date {
        return self.now.addingTimeInterval(-25 * 3600)
    }

    private func decide(_ trigger: SGEntitlementRefreshTrigger, _ account: Int64, issuedAt: Date?, wantsRotation: Bool = false, at time: Date? = nil) -> SGEntitlementScheduler.Decision {
        return self.scheduler.decide(trigger: trigger, accountPeerId: account, tokenIssuedAt: issuedAt, isLinked: true, wantsRotation: wantsRotation, now: time ?? self.now)
    }

    func test_anotherAccountsRefreshInFlightDoesNotSwallowAStaleAccount() {
        XCTAssertEqual(self.decide(.foreground, self.a, issuedAt: self.stale), .fetch)
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)

        // Before: one global in-flight flag and one 60 s slot answered `.skip` here, so B's day-old
        // token kept granting until the next foreground.
        XCTAssertEqual(self.decide(.foreground, self.b, issuedAt: self.stale, at: self.now.addingTimeInterval(10)), .fetch)
        XCTAssertEqual(self.decide(.foreground, self.a, issuedAt: self.stale, at: self.now.addingTimeInterval(10)), .skip, "A itself is still in flight")
    }

    func test_theSixtySecondCollapseIsPerAccount() {
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        self.scheduler.didSucceed(accountPeerId: self.a, now: self.now)
        XCTAssertEqual(self.decide(.silentPush, self.a, issuedAt: self.stale, at: self.now.addingTimeInterval(30)), .skip)
        XCTAssertEqual(self.decide(.silentPush, self.b, issuedAt: self.stale, at: self.now.addingTimeInterval(30)), .fetch)
    }

    func test_backoffIsDeviceWide() {
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        self.scheduler.didFail(accountPeerId: self.a, retryAfter: 600, now: self.now)
        guard case let .wait(delay) = self.decide(.foreground, self.b, issuedAt: self.stale, at: self.now.addingTimeInterval(1)) else {
            return XCTFail("a 429 for one account must hold every account on this device")
        }
        XCTAssertGreaterThan(delay, 590)
    }

    func test_concurrentSuccessDoesNotClearTheServersRetryAfter() {
        // A and B are on the wire together (one push, two accounts).
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        self.scheduler.willPerform(.fetch, accountPeerId: self.b, now: self.now)
        self.scheduler.didFail(accountPeerId: self.a, retryAfter: 600, now: self.now.addingTimeInterval(1))
        // B was admitted before the bucket filled and answers later.
        self.scheduler.didSucceed(accountPeerId: self.b, now: self.now.addingTimeInterval(2))
        // Before: B's success set the device-wide hold to nil and this was `.fetch`.
        guard case let .wait(delay) = self.decide(.userInitiated, self.b, issuedAt: nil, at: self.now.addingTimeInterval(120)) else {
            return XCTFail("the server's retry_after must survive another account's success")
        }
        XCTAssertGreaterThan(delay, 470)
        XCTAssertEqual(self.decide(.userInitiated, self.b, issuedAt: nil, at: self.now.addingTimeInterval(700)), .fetch, "and it ends when it ends")
    }

    func test_successStillClearsAnOrdinaryBackoff() {
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        self.scheduler.willPerform(.fetch, accountPeerId: self.b, now: self.now)
        for _ in 0 ..< 8 {
            self.scheduler.didFail(accountPeerId: self.a, retryAfter: nil, now: self.now)
        }
        self.scheduler.didSucceed(accountPeerId: self.b, now: self.now)
        XCTAssertEqual(self.decide(.userInitiated, 1003, issuedAt: nil, at: self.now.addingTimeInterval(1)), .fetch)
    }

    func test_hintsFetchUnlessTheBindingNeedsThePushToken() {
        // A rotation whose answer is lost strands the session after the 60 s overlap, so a hint never
        // rotates on its own; only telemetry the binding still needs does.
        XCTAssertEqual(self.decide(.silentPush, self.a, issuedAt: self.stale), .fetch)
        XCTAssertEqual(self.decide(.storeKitUpdate, self.b, issuedAt: self.stale), .fetch)
        XCTAssertEqual(self.decide(.silentPush, 1003, issuedAt: self.stale, wantsRotation: true), .rotate)
    }

    func test_aFreshBindingStillOwedThePushTokenRegistersIt() {
        let fresh = self.now.addingTimeInterval(-3600)
        XCTAssertEqual(self.decide(.foreground, self.a, issuedAt: fresh, wantsRotation: false), .skip)
        // Before: a fresh token skipped first idle / foreground / account change, so a re-bound
        // account's new binding held no push token for up to a day.
        XCTAssertEqual(self.decide(.foreground, self.a, issuedAt: fresh, wantsRotation: true), .rotate)
        XCTAssertEqual(self.decide(.firstIdleAfterLaunch, self.b, issuedAt: fresh, wantsRotation: true), .rotate)
        XCTAssertEqual(self.decide(.firstIdleAfterLaunch, self.b, issuedAt: fresh, wantsRotation: true), .skip, "the launch pass is still once")
    }

    func test_aFreshBindingOwedThePushTokenWaitsForPostBudget() {
        for index in 0 ..< SGEntitlementScheduler.postBudgetPerHour {
            self.scheduler.willPerform(.rotate, accountPeerId: Int64(index), now: self.now.addingTimeInterval(TimeInterval(index)))
        }
        let fresh = self.now.addingTimeInterval(-3600)
        XCTAssertEqual(self.decide(.foreground, self.a, issuedAt: fresh, wantsRotation: true, at: self.now.addingTimeInterval(120)), .skip, "no POST budget: a GET would not deliver the token")
    }

    func test_budgetIsDeviceWide() {
        for index in 0 ..< SGEntitlementScheduler.getBudgetPerHour {
            self.scheduler.willPerform(.fetch, accountPeerId: Int64(index), now: self.now.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(self.decide(.foreground, self.b, issuedAt: self.stale, at: self.now.addingTimeInterval(120)), .skip)
    }

    func test_freshTokenIsNotRefreshedOnForeground() {
        XCTAssertEqual(self.decide(.foreground, self.b, issuedAt: self.now.addingTimeInterval(-3600)), .skip)
    }

    func test_aTokenWithoutAccountClaimsIsRefreshedAtOnce_butStillBounded() {
        // Paid mode met a legacy token (no `account_ent` / `account_until`): it proves nothing, so a
        // fresh `iat` must not postpone the refresh to the next day…
        let fresh = self.now.addingTimeInterval(-60)
        XCTAssertEqual(self.decide(.accountClaimsMissing, self.a, issuedAt: fresh), .fetch)
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        XCTAssertEqual(self.decide(.accountClaimsMissing, self.a, issuedAt: fresh, at: self.now.addingTimeInterval(5)), .skip, "one in flight")
        self.scheduler.didSucceed(accountPeerId: self.a, now: self.now.addingTimeInterval(5))
        // …but the 60 s collapse, the device-wide budget and any backoff still hold.
        XCTAssertEqual(self.decide(.accountClaimsMissing, self.a, issuedAt: fresh, at: self.now.addingTimeInterval(30)), .skip)
        XCTAssertEqual(self.decide(.accountClaimsMissing, self.a, issuedAt: fresh, at: self.now.addingTimeInterval(61)), .fetch)
        self.scheduler.didFail(accountPeerId: self.b, retryAfter: 600, now: self.now.addingTimeInterval(62))
        guard case .wait = self.decide(.accountClaimsMissing, self.a, issuedAt: fresh, at: self.now.addingTimeInterval(70)) else {
            return XCTFail("a server retry_after holds this refresh too")
        }
        XCTAssertEqual(self.scheduler.decide(trigger: .accountClaimsMissing, accountPeerId: 1003, tokenIssuedAt: fresh, isLinked: false, wantsRotation: false, now: self.now), .skip, "an unlinked account has nothing to refresh")
    }

    func test_launchPassAndUnauthorizedLatchArePerAccount() {
        XCTAssertEqual(self.decide(.firstIdleAfterLaunch, self.a, issuedAt: nil), .fetch)
        self.scheduler.willPerform(.fetch, accountPeerId: self.a, now: self.now)
        XCTAssertEqual(self.decide(.firstIdleAfterLaunch, self.b, issuedAt: nil), .fetch)

        let later = self.now.addingTimeInterval(120)
        XCTAssertEqual(self.decide(.unauthorized(.nonceReplayed), self.b, issuedAt: nil, at: later), .fetch)
        XCTAssertEqual(self.decide(.unauthorized(.nonceReplayed), self.b, issuedAt: nil, at: later), .skip, "once per cause")
        self.scheduler.resetCauses(accountPeerId: self.a)
        XCTAssertEqual(self.decide(.unauthorized(.nonceReplayed), self.b, issuedAt: nil, at: later), .skip, "A's reset is not B's")
    }
}

final class SGEntitlementPushHintTests: XCTestCase {
    func test_onlyTheExactRefreshShapeIsAHint() {
        XCTAssertTrue(SGEntitlement.isRefreshPush(["aps": ["content-available": 1], "zenlypay": ["action": "refresh", "reason": "portal_revoke"]]))
        XCTAssertTrue(SGEntitlement.isRefreshPush(["zenlypay": ["action": "refresh"], "p": "telegram"]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["zenlypay": ["action": "Refresh"]]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["zenlypay": ["action": "grant"]]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["zenlypay": "refresh"]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["zenlypay": ["reason": "refresh"]]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["p": "telegram"]))
        XCTAssertFalse(SGEntitlement.isRefreshPush(["aps": ["content-available": 1]]))
    }

    func test_targetsAreTheActiveAccountThenEveryOtherOnce() {
        XCTAssertEqual(SGEntitlement.refreshTargets(active: 2, known: [1, 2, 3]), [2, 1, 3])
        XCTAssertEqual(SGEntitlement.refreshTargets(active: nil, known: [1, 3]), [1, 3])
        XCTAssertEqual(SGEntitlement.refreshTargets(active: 4, known: []), [4])
    }

    func test_pushTokenReceiptIsPerBindingAndNeverTheToken() {
        let token = "a1b2c3"
        let digest = SGEntitlementPushTelemetry.digest(token)
        XCTAssertNotEqual(digest, token, "the receipt never stores the APNs token")
        XCTAssertEqual(digest.count, 64)

        // Before: one install-wide flag, cleared by the first account's rotation, so every other
        // binding was treated as having the token and an operator's push for it could not arrive.
        let delivered = SGEntitlementSessionMaterial(refreshToken: "a", pushTokenDigest: digest)
        let other = SGEntitlementSessionMaterial(refreshToken: "b")
        XCTAssertFalse(SGEntitlementPushTelemetry(pushToken: token, material: delivered).wantsRotation)
        XCTAssertTrue(SGEntitlementPushTelemetry(pushToken: token, material: other).wantsRotation)
        XCTAssertTrue(SGEntitlementPushTelemetry(pushToken: "new-token", material: delivered).wantsRotation, "a new APNs token is owed again")
        XCTAssertFalse(SGEntitlementPushTelemetry(pushToken: nil, material: other).wantsRotation, "no token, nothing to send")
    }
}

/// The single answer a push gives UIKit: exactly once, on main, from what actually happened.
final class SGEntitlementPushCompletionTests: XCTestCase {
    private func join(expected: Int, deadline: TimeInterval = 5.0, file: StaticString = #filePath, line: UInt = #line) -> (SGEntitlementPushRefreshCompletion, XCTestExpectation, () -> [SGEntitlementPushRefreshOutcome]) {
        let called = self.expectation(description: "completion")
        called.assertForOverFulfill = true
        let lock = NSLock()
        var outcomes: [SGEntitlementPushRefreshOutcome] = []
        let join = SGEntitlementPushRefreshCompletion(expected: expected, deadline: deadline, completion: { outcome in
            XCTAssertTrue(Thread.isMainThread, "UIKit's handler is called on main", file: file, line: line)
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
            called.fulfill()
        })
        return (join, called, {
            lock.lock()
            defer { lock.unlock() }
            return outcomes
        })
    }

    /// Lets anything wrongly scheduled after the first answer land before asserting "exactly once".
    private func settle(_ seconds: TimeInterval) {
        let settled = self.expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            settled.fulfill()
        }
        self.wait(for: [settled], timeout: seconds + 2.0)
    }

    func test_waitsForEveryAttemptThenAnswersOnce() {
        let (join, called, outcomes) = self.join(expected: 3)
        join.record(.failed)
        join.record(.notAttempted)
        XCTAssertTrue(outcomes().isEmpty, "nothing is reported before every attempt has answered")
        join.record(.adopted)
        self.wait(for: [called], timeout: 2.0)
        join.record(.failed)
        self.settle(0.2)
        XCTAssertEqual(outcomes(), [.newData], "partial success is new data, and a late record changes nothing")
    }

    func test_obsoleteResultsAndSkipsAreNoData() {
        let (join, called, outcomes) = self.join(expected: 2)
        join.record(.notAdopted)
        join.record(.notAttempted)
        self.wait(for: [called], timeout: 2.0)
        XCTAssertEqual(outcomes(), [.noData])
    }

    func test_failureWithNothingAdoptedIsFailed() {
        let (join, called, outcomes) = self.join(expected: 2)
        join.record(.notAdopted)
        join.record(.failed)
        self.wait(for: [called], timeout: 2.0)
        XCTAssertEqual(outcomes(), [.failed])
    }

    func test_noLinkedAccountAnswersNoDataAtOnce() {
        let (_, called, outcomes) = self.join(expected: 0)
        self.wait(for: [called], timeout: 2.0)
        self.settle(0.2)
        XCTAssertEqual(outcomes(), [.noData])
    }

    func test_deadlineCountsUnfinishedAsFailedAndIgnoresLateAnswers() {
        let (join, called, outcomes) = self.join(expected: 2, deadline: 0.2)
        join.record(.notAdopted)
        self.wait(for: [called], timeout: 3.0)
        join.record(.adopted)
        self.settle(0.3)
        XCTAssertEqual(outcomes(), [.failed])
    }

    func test_deadlineKeepsAnAdoptionThatAlreadyLanded() {
        let (join, called, outcomes) = self.join(expected: 2, deadline: 0.2)
        join.record(.adopted)
        self.wait(for: [called], timeout: 3.0)
        self.settle(0.3)
        XCTAssertEqual(outcomes(), [.newData])
    }
}

/// The refresh's answer reaches ONLY the session it was sent under, and a failure keeps the cached
/// token — driven through the production `performRefresh` with a fake HTTP answer, on an instance
/// that owns its scheduler and store. A fake rotation persists through
/// `SGEntitlementClient.persistRotation`, the step the real client runs.
final class SGEntitlementRefreshSessionTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    /// An account no test refreshes: asking the scheduler about it reveals only the device-wide hold.
    private let probe: Int64 = 69_229_542_999
    private let key = P256.Signing.PrivateKey()
    private let current = SGEntitlementSessionMaterial(refreshToken: "current-session", entitlement: "previous-good-token", accountId: "01JB8Q", deviceId: "01JB8R")
    private var schedulerSuite = ""
    private var storeSuite = ""
    private var store: SGEntitlementStore!
    private var scheduler: SGEntitlementScheduler!
    private var entitlement: SGEntitlement!

    override func setUp() {
        super.setUp()
        self.schedulerSuite = "SGEntitlementRefreshSessionTests.scheduler.\(UUID().uuidString)"
        self.storeSuite = "SGEntitlementRefreshSessionTests.store.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        self.scheduler = SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite))
        self.entitlement = SGEntitlement(store: self.store, scheduler: self.scheduler)
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        self.entitlement.overridePinnedKeys(SGEntitlementTestToken.pinned(self.key, kid: "k2026a"))
        let current = self.current
        let seeded = self.store.updateSession(accountPeerId: self.account) { material in
            material = current
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        self.entitlement = nil
        self.scheduler = nil
        self.store = nil
        super.tearDown()
    }

    private var credential: SGEntitlementSessionCredential {
        return SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "current-session")
    }

    private var paidToken: String {
        return SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
    }

    private var noTelemetry: SGEntitlementPushTelemetry {
        return self.entitlement.pendingTelemetry(accountPeerId: self.account)
    }

    /// The stored material without the write timestamp, for comparing with a literal.
    private func stored() -> SGEntitlementSessionMaterial {
        var material = self.store.session(accountPeerId: self.account)
        material.updatedAt = nil
        return material
    }

    /// Whether the device-wide backoff / retry-after is holding every account.
    private var isHoldingDevice: Bool {
        if case .wait = self.scheduler.decide(trigger: .userInitiated, accountPeerId: self.probe, tokenIssuedAt: nil, isLinked: true, wantsRotation: false) {
            return true
        }
        return false
    }

    private func transport(
        fetch: @escaping (SGEntitlementSessionCredential) async -> Result<String, SGEntitlementRequestError> = { _ in .failure(SGEntitlementRequestError(failure: .offline(.timeout))) },
        rotate: @escaping (SGEntitlementSessionCredential, String?) async -> SGEntitlementRotationOutcome = { _, _ in .failed(SGEntitlementRequestError(failure: .offline(.timeout))) }
    ) -> SGEntitlementRefreshTransport {
        return SGEntitlementRefreshTransport(fetch: fetch, rotate: rotate)
    }

    /// The server rotated to `successor`; the answer is persisted exactly as the client does,
    /// including the receipt for the push token the request carried. `beforeAnswer` runs while the
    /// request is in flight, `afterPersist` between the persist and the return (the window in which
    /// a re-bind can land behind a stored rotation).
    private func rotatingTransport(entitlement: String, successor: String, beforeAnswer: @escaping () -> Void = {}, afterPersist: @escaping () -> Void = {}) -> SGEntitlementRefreshTransport {
        let store = self.store!
        return self.transport(rotate: { credential, pushToken in
            beforeAnswer()
            let answer = SGEntitlementRefreshResult(entitlement: entitlement, refreshToken: successor, expiresAt: nil, until: nil)
            let outcome = SGEntitlementClient.persistRotation(answer, presented: credential, deliveredPushToken: pushToken, store: store)
            afterPersist()
            return outcome
        })
    }

    func test_verifiedFetchIsAdoptedUnderTheCapturedSession() async {
        let token = self.paidToken
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport(fetch: { _ in .success(token) }))
        XCTAssertEqual(attempt, .adopted)
        let stored = self.stored()
        XCTAssertEqual(stored.entitlement, token, "the exact verified JWS is stored")
        XCTAssertEqual(stored.until, "2030-01-01T00:00:00Z")
        XCTAssertEqual(stored.refreshToken, "current-session", "a GET never rotates the session")
        XCTAssertEqual(stored.accountId, self.current.accountId)
        XCTAssertEqual(stored.deviceId, self.current.deviceId)
        XCTAssertFalse(self.isHoldingDevice)
    }

    func test_refusedRotationWriteKeepsThePersistedSessionAndReceipt() {
        let seeded = self.store.updateSession(accountPeerId: self.account) {
            $0.pushTokenDigest = SGEntitlementPushTelemetry.digest("old-apns")
        }
        guard case .success = seeded else {
            return XCTFail("could not persist the previous delivery receipt")
        }
        let before = self.store.session(accountPeerId: self.account)
        let refusingStore = SGEntitlementStore(
            defaults: UserDefaults(suiteName: self.storeSuite),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecNotAvailable },
                delete: { _ in }
            )
        )
        let answer = SGEntitlementRefreshResult(entitlement: self.paidToken, refreshToken: "unpersisted-successor", expiresAt: nil, until: nil)
        let outcome = SGEntitlementClient.persistRotation(answer, presented: self.credential, deliveredPushToken: "replacement-apns", store: refusingStore)
        guard case .notPersisted = outcome else {
            return XCTFail("a refused write must not adopt a successor or mark its push token delivered")
        }
        XCTAssertEqual(refusingStore.session(accountPeerId: self.account), before)
        let reopened = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        XCTAssertEqual(reopened.session(accountPeerId: self.account), before, "the durable record must also remain unchanged")
    }

    func test_logoutBetweenSendAndAnswerStoresNothing() async {
        let token = self.paidToken
        let account = self.account
        let store = self.store!
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport(fetch: { _ in
            store.clearSession(accountPeerId: account)
            return .success(token)
        }))
        XCTAssertEqual(attempt, .notAdopted)
        XCTAssertEqual(self.stored(), SGEntitlementSessionMaterial(), "a logged-out account must not be resurrected")
        XCTAssertFalse(self.isHoldingDevice, "an obsolete answer is not a server failure")
    }

    func test_reBindBetweenSendAndAnswerKeepsTheNewBinding() async {
        let token = self.paidToken
        let account = self.account
        let store = self.store!
        let rebound = SGEntitlementSessionMaterial(refreshToken: "rebound-session", entitlement: "rebound-token", accountId: "01JB8Q", deviceId: "01JB8R")
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport(fetch: { _ in
            store.seedSessionForTesting(accountPeerId: account, rebound)
            return .success(token)
        }))
        XCTAssertEqual(attempt, .notAdopted)
        XCTAssertEqual(self.stored(), rebound)
    }

    func test_verifiedRotationIsAdoptedAndRecordsTheReceiptInTheSameWrite() async {
        self.entitlement.setPushToken("apns")
        let telemetry = self.entitlement.pendingTelemetry(accountPeerId: self.account)
        XCTAssertTrue(telemetry.wantsRotation)
        let token = self.paidToken
        let attempt = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: telemetry, transport: self.rotatingTransport(entitlement: token, successor: "rotated-session"))
        XCTAssertEqual(attempt, .adopted)
        let stored = self.stored()
        XCTAssertEqual(stored.refreshToken, "rotated-session")
        XCTAssertEqual(stored.entitlement, token)
        XCTAssertEqual(stored.until, "2030-01-01T00:00:00Z")
        XCTAssertEqual(stored.pushTokenDigest, SGEntitlementPushTelemetry.digest("apns"))
        XCTAssertFalse(self.entitlement.pendingTelemetry(accountPeerId: self.account).wantsRotation, "this binding has the token now")
    }

    func test_theReceiptSurvivesARelaunchSoAFreshAccountIsNotRotatedAgain() async {
        self.entitlement.setPushToken("apns")
        let token = self.paidToken
        let attempt = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: self.entitlement.pendingTelemetry(accountPeerId: self.account), transport: self.rotatingTransport(entitlement: token, successor: "rotated-session"))
        XCTAssertEqual(attempt, .adopted)

        // A new process: a NEW store on the same install storage, a new scheduler, the same token.
        let relaunchSuite = "SGEntitlementRefreshSessionTests.relaunch.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: relaunchSuite)?.removePersistentDomain(forName: relaunchSuite)
        }
        let relaunchedStore = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        let relaunchedScheduler = SGEntitlementScheduler(defaults: UserDefaults(suiteName: relaunchSuite))
        let relaunched = SGEntitlement(store: relaunchedStore, scheduler: relaunchedScheduler)
        relaunched.setPushToken("apns")
        let telemetry = relaunched.pendingTelemetry(accountPeerId: self.account)
        // Before: delivery lived in memory, so every launch owed every binding the token again and
        // a fresh account was rotated on first idle.
        XCTAssertFalse(telemetry.wantsRotation)
        XCTAssertEqual(relaunchedScheduler.decide(trigger: .firstIdleAfterLaunch, accountPeerId: self.account, tokenIssuedAt: Date().addingTimeInterval(-3600), isLinked: true, wantsRotation: telemetry.wantsRotation), .skip)
    }

    func test_aRotationCarryingNoTokenKeepsTheReceipt() async {
        self.entitlement.setPushToken("apns")
        let token = self.paidToken
        _ = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: self.entitlement.pendingTelemetry(accountPeerId: self.account), transport: self.rotatingTransport(entitlement: token, successor: "rotated-session"))
        let answer = SGEntitlementRefreshResult(entitlement: token, refreshToken: "rotated-again", expiresAt: nil, until: nil)
        let outcome = SGEntitlementClient.persistRotation(answer, presented: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "rotated-session"), deliveredPushToken: nil, store: self.store)
        XCTAssertEqual(outcome, .rotated(answer))
        XCTAssertEqual(self.stored().refreshToken, "rotated-again")
        XCTAssertEqual(self.stored().pushTokenDigest, SGEntitlementPushTelemetry.digest("apns"), "the public refresh path without a token keeps the receipt")
    }

    func test_logoutDuringRotationIsObsoleteNotAFailure() async {
        self.entitlement.setPushToken("apns")
        let telemetry = self.entitlement.pendingTelemetry(accountPeerId: self.account)
        let token = self.paidToken
        let account = self.account
        let store = self.store!
        let attempt = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: telemetry, transport: self.rotatingTransport(entitlement: token, successor: "rotated-session", beforeAnswer: {
            store.clearSession(accountPeerId: account)
        }))
        // Before: the client reported "rotation not persisted" as offline, so this was `.failed` and
        // backed off every account on the device.
        XCTAssertEqual(attempt, .notAdopted)
        XCTAssertFalse(self.isHoldingDevice)
        XCTAssertEqual(self.stored(), SGEntitlementSessionMaterial(), "a logged-out account must not be resurrected, nor get a receipt")
    }

    func test_reBindDuringRotationKeepsTheNewBinding() async {
        let token = self.paidToken
        let account = self.account
        let store = self.store!
        let rebound = SGEntitlementSessionMaterial(refreshToken: "rebound-session", entitlement: "rebound-token", accountId: "01JB8Q", deviceId: "01JB8R")
        let attempt = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: self.noTelemetry, transport: self.rotatingTransport(entitlement: token, successor: "rotated-session", beforeAnswer: {
            store.seedSessionForTesting(accountPeerId: account, rebound)
        }))
        XCTAssertEqual(attempt, .notAdopted)
        XCTAssertFalse(self.isHoldingDevice)
        XCTAssertEqual(self.stored(), rebound)
    }

    func test_reBindAfterAStoredRotationLeavesTheNewBindingOwedThePushToken() async {
        self.entitlement.setPushToken("apns")
        let telemetry = self.entitlement.pendingTelemetry(accountPeerId: self.account)
        let token = self.paidToken
        let account = self.account
        let store = self.store!
        let entitlement = self.entitlement!
        let rebound = SGEntitlementSessionMaterial(refreshToken: "rebound-session", entitlement: "rebound-token", accountId: "01JB8Q", deviceId: "01JB8R")
        let attempt = await self.entitlement.performRefresh(.rotate, credential: self.credential, telemetry: telemetry, transport: self.rotatingTransport(entitlement: token, successor: "rotated-session", afterPersist: {
            // The old binding's rotation and receipt are stored; then the account logs out and binds
            // again. The receipt goes with the old binding.
            entitlement.logout(accountPeerId: account)
            store.seedSessionForTesting(accountPeerId: account, rebound)
        }))
        XCTAssertEqual(attempt, .notAdopted, "the successor belongs to a binding that no longer exists")
        XCTAssertEqual(self.stored(), rebound)
        XCTAssertTrue(self.entitlement.pendingTelemetry(accountPeerId: self.account).wantsRotation, "the new binding never received the APNs token")
    }

    func test_transportFailureKeepsTheCachedToken() async {
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport())
        XCTAssertEqual(attempt, .failed)
        XCTAssertEqual(self.stored(), self.current, "offline is never unsubscribed (I2)")
    }

    func test_rateLimitedFetchKeepsTheCachedTokenAndHoldsTheDevice() async {
        let limited = SGEntitlementRequestError(failure: .rateLimited(retryAfter: 600), retryAfter: 600)
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport(fetch: { _ in .failure(limited) }))
        XCTAssertEqual(attempt, .failed)
        XCTAssertEqual(self.stored(), self.current)
        XCTAssertTrue(self.isHoldingDevice, "a real failure still holds every account")
    }

    func test_tokenForAnotherAccountIsNeverStored() async {
        var payload = SGEntitlementTestToken.claims()
        payload["sub"] = "another-pro-account"
        let foreign = SGEntitlementTestToken.make(key: self.key, payload: payload)
        let attempt = await self.entitlement.performRefresh(.fetch, credential: self.credential, telemetry: self.noTelemetry, transport: self.transport(fetch: { _ in .success(foreign) }))
        XCTAssertEqual(attempt, .notAdopted)
        XCTAssertEqual(self.stored(), self.current)
    }

    /// What a refused linked purchase relies on (`SGIAPStoreKitEngine.purchase` applies the prepare's
    /// session failure under the credential it captured): the session-loss family drops THIS
    /// session's refresh token — the account reads as unlinked, so the paywall's Link row returns —
    /// while the token keeps governing; a transient session failure keeps the session.
    func test_applyingASessionLossUnderTheCapturedCredentialUnlinksTheAccount_butKeepsItsToken() {
        for failure in [SGEntitlementSessionFailure.invalidToken, .expiredToken, .sessionRevoked, .deviceRevoked, .refreshReuse] {
            let current = self.current
            _ = self.store.updateSession(accountPeerId: self.account) { $0 = current }
            XCTAssertTrue(self.entitlement.isLinked(accountPeerId: self.account), "premise: linked")
            self.entitlement.apply(SGEntitlementRequestError(failure: .session(failure)), credential: self.credential)
            XCTAssertFalse(self.entitlement.isLinked(accountPeerId: self.account), "\(failure) must drop the captured session")
            XCTAssertNil(self.entitlement.sessionCredential(accountPeerId: self.account))
            XCTAssertEqual(self.store.session(accountPeerId: self.account).entitlement, current.entitlement, "\(failure): the token keeps governing")
        }
    }

    func test_applyingATransientSessionFailureKeepsTheSession() {
        for failure in [SGEntitlementSessionFailure.unauthenticated, .nonceReplayed, .clockSkew] {
            let current = self.current
            _ = self.store.updateSession(accountPeerId: self.account) { $0 = current }
            self.entitlement.apply(SGEntitlementRequestError(failure: .session(failure)), credential: self.credential)
            XCTAssertTrue(self.entitlement.isLinked(accountPeerId: self.account), "\(failure) must not unlink: re-linking would not help")
            XCTAssertEqual(self.entitlement.sessionCredential(accountPeerId: self.account), self.credential)
        }
    }
}

/// A refresh push that arrives before the app has published its accounts waits for them.
final class SGEntitlementAccountsReadinessTests: XCTestCase {
    private func settle(_ seconds: TimeInterval) {
        let settled = self.expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            settled.fulfill()
        }
        self.wait(for: [settled], timeout: seconds + 2.0)
    }

    func test_gateRunsAWaiterOnceWhenItOpens() {
        let gate = SGEntitlementReadinessGate()
        let ran = self.expectation(description: "ran")
        ran.assertForOverFulfill = true
        gate.whenOpen(timeout: 0.3, queue: .main) {
            ran.fulfill()
        }
        gate.open(queue: .main)
        self.wait(for: [ran], timeout: 2.0)
        gate.open(queue: .main)
        self.settle(0.5)
    }

    func test_gateRunsAWaiterOnceAtItsTimeoutAndNeverAgainOnALateOpen() {
        let gate = SGEntitlementReadinessGate()
        let ran = self.expectation(description: "ran")
        ran.assertForOverFulfill = true
        gate.whenOpen(timeout: 0.2, queue: .main) {
            ran.fulfill()
        }
        self.wait(for: [ran], timeout: 2.0)
        gate.open(queue: .main)
        self.settle(0.3)
    }

    func test_anOpenGateRunsAtOnce() {
        let gate = SGEntitlementReadinessGate()
        gate.open(queue: .main)
        let ran = self.expectation(description: "ran")
        ran.assertForOverFulfill = true
        gate.whenOpen(timeout: 30, queue: .main) {
            ran.fulfill()
        }
        self.wait(for: [ran], timeout: 2.0)
    }

    func test_pushBeforeAccountsArePublishedWaitsForThem() {
        let suiteName = "SGEntitlementAccountsReadinessTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let entitlement = SGEntitlement(scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: suiteName)))
        let answered = self.expectation(description: "answered")
        answered.assertForOverFulfill = true
        var outcomes: [SGEntitlementPushRefreshOutcome] = []
        entitlement.handleSilentPush(completion: { outcome in
            XCTAssertTrue(Thread.isMainThread)
            outcomes.append(outcome)
            answered.fulfill()
        })
        // Before: the push read an empty account set and answered `.noData` at once.
        self.settle(0.3)
        XCTAssertTrue(outcomes.isEmpty, "no answer before the app has published its accounts")

        entitlement.setAccounts(SGEntitlementAccounts(primary: nil, all: []))
        self.wait(for: [answered], timeout: 2.0)
        self.settle(0.3)
        XCTAssertEqual(outcomes, [.noData], "no linked account: nothing sent")
    }
}
