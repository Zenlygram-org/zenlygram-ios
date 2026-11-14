import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — `refreshAppUpdatePolicy` end to end on the live coordinator, on instances that own
/// their store, scheduler and policy defaults, against a scripted origin (`SGPolicyStubProtocol`)
/// that serves the public policy's two endpoints by path:
///
/// - the anonymous GET of `/v1/app-policy` with its own `Accept`, adopted, persisted under the
///   app-update slot of the public origin (`zg.app.policy.v1@https://host`) and restored on the next
///   launch, synchronously, before any request;
/// - 503, 429, an oversized or tokenless answer, an older, conflicting or other-purpose token keep
///   the accepted policy; a newer one lifts a block;
/// - its own gate: an app-policy attempt consumes neither the monetization gate nor its cooldown;
/// - the cadence: the first idle window, foreground and the periodic tick fetch it after the
///   monetization policy; the silent push never does;
/// - the decision and its holder (`SGAppUpdate`): block, remind once per `latest`, the marker, the
///   30-day valve, `decisionDidChange` on the main queue.
///
/// A public-policy-only build (no authenticated client), deliberately: the app-update policy is
/// about the build, not about selling, so it applies there too.
final class SGEntitlementAppUpdateTests: XCTestCase {
    private let kid = "k2026a"
    /// Signs both public policies (the `.org` ring).
    private let publicKey = P256.Signing.PrivateKey()
    private let host = "policy.zenlygram.test"
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var policySuite = ""
    private var policyNow: Int64 = 0
    private var store: SGEntitlementStore!
    /// Every coordinator a test made, so a periodic refresh it armed never outlives the test.
    private var made: [SGEntitlement] = []

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        SGPolicyStubProtocol.reset(routes: [:])
        let unique = UUID().uuidString
        self.policyNow = Int64(Date().timeIntervalSince1970)
        self.storeSuite = "SGEntitlementAppUpdateTests.store.\(unique)"
        self.schedulerSuite = "SGEntitlementAppUpdateTests.scheduler.\(unique)"
        self.policySuite = "SGEntitlementAppUpdateTests.policy.\(unique)"
        self.store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: self.storeSuite),
            // Every write takes the store's keychainless fallback: nothing reaches the real Keychain.
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
    }

    override func tearDown() {
        SGPolicyStubProtocol.reset(routes: [:])
        for entitlement in self.made {
            entitlement.applicationWillResignActive()
        }
        self.made = []
        for suite in [self.storeSuite, self.schedulerSuite, self.policySuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        self.store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var policyDefaults: UserDefaults {
        return UserDefaults(suiteName: self.policySuite)!
    }

    private var publicPolicy: SGEntitlementPublicPolicyConfiguration {
        let endpoint = SGEntitlementPolicyEndpoint(url: URL(string: "https://\(self.host)/v1/monetization")!, protocolClasses: [SGPolicyStubProtocol.self])!
        return SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: SGEntitlementTestToken.pinned(self.publicKey, kid: self.kid).keysByKid)!
    }

    private var origin: String {
        return "https://\(self.host)"
    }

    private var appPolicyKey: String {
        return SGEntitlementPolicyStore.originKey(self.origin, baseKey: SGEntitlementPolicyStore.appUpdateDefaultsKey)
    }

    private var monetizationKey: String {
        return SGEntitlementPolicyStore.originKey(self.origin)
    }

    private var remindedKey: String {
        return "zg.app.policy.reminded@\(self.origin)"
    }

    /// One launch of a public-policy-only build installed as `installed`, with the app-policy
    /// stagger collapsed to 0 so a lifecycle trigger's second GET follows at once.
    private func makeEntitlement(installed: String? = "12.9.2", policyClock: (() -> Date)? = nil) -> SGEntitlement {
        let fixed = Date(timeIntervalSince1970: TimeInterval(self.policyNow))
        let entitlement = SGEntitlement(
            store: self.store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: self.policyDefaults),
            policyClock: policyClock ?? { fixed },
            publicPolicy: self.publicPolicy,
            isPublicPolicyRequested: true,
            isAuthenticatedEntitlementConfigured: false
        )
        entitlement.overridePinnedKeys(SGEntitlementPinnedKeys(keysByKid: [:]))
        entitlement.overrideInstalledAppVersion(installed)
        entitlement.overrideAppUpdatePolicyStaggerForTesting(0)
        self.made.append(entitlement)
        return entitlement
    }

    private func versions(_ min: String, _ latest: String) -> [String: Any] {
        return SGEntitlementTestAppUpdatePolicy.platform(min: min, latest: latest)
    }

    private func constraint(_ min: String, _ latest: String) -> SGAppUpdateVersions {
        return SGAppUpdateVersions(min: SGAppUpdateVersion(min)!, latest: SGAppUpdateVersion(latest)!)!
    }

    private func appPolicy(revision: Int64, ios: Any = NSNull(), iat: Int64? = nil, key: P256.Signing.PrivateKey? = nil) -> String {
        return SGEntitlementTestAppUpdatePolicy.make(key: key ?? self.publicKey, kid: self.kid, revision: revision, iat: iat ?? self.policyNow, ios: ios)
    }

    private func monetization(_ mode: String, revision: Int64) -> String {
        return SGEntitlementTestPolicy.make(key: self.publicKey, kid: self.kid, mode: mode, revision: revision, iat: self.policyNow)
    }

    private func route(_ body: [String: Any], status: Int = 200) -> SGPolicyStubProtocol.Route {
        return SGPolicyStubProtocol.Route(status: status, headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(body)])
    }

    /// Serves the two endpoints of the origin by path; a nil token leaves that path unrouted.
    private func serve(appPolicy: String?, monetization: String? = nil) {
        var routes: [String: SGPolicyStubProtocol.Route] = [:]
        if let appPolicy {
            routes["\(self.host)/v1/app-policy"] = self.route(["policy_token": appPolicy, "server_time": "2099-01-01T00:00:00Z"])
        }
        if let monetization {
            routes["\(self.host)/v1/monetization"] = self.route(["policy_token": monetization, "server_time": "2099-01-01T00:00:00Z"])
        }
        SGPolicyStubProtocol.reset(routes: routes)
    }

    private func serveAppPolicy(_ route: SGPolicyStubProtocol.Route) {
        SGPolicyStubProtocol.reset(routes: ["\(self.host)/v1/app-policy": route])
    }

    /// The real anonymous GET of `/v1/app-policy` against the scripted origin.
    private func refreshAppPolicy(_ entitlement: SGEntitlement, uptime: TimeInterval) async -> SGEntitlementPolicyRefreshAttempt {
        return await entitlement.performAppUpdatePolicyRefresh(transport: .live(self.publicPolicy.appPolicyEndpoint), uptime: uptime)
    }

    private func refreshMonetization(_ entitlement: SGEntitlement, uptime: TimeInterval) async -> SGEntitlementPolicyRefreshAttempt {
        return await entitlement.performPolicyRefresh(transport: .live(self.publicPolicy.endpoint), uptime: uptime)
    }

    /// `XCTAssertEqual` cannot `await` inside its autoclosure: the attempt is bound first.
    private func expectAppPolicyRefresh(_ entitlement: SGEntitlement, uptime: TimeInterval, toBe expected: SGEntitlementPolicyRefreshAttempt, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let attempt = await self.refreshAppPolicy(entitlement, uptime: uptime)
        XCTAssertEqual(attempt, expected, message, file: file, line: line)
    }

    private func expectMonetizationRefresh(_ entitlement: SGEntitlement, uptime: TimeInterval, toBe expected: SGEntitlementPolicyRefreshAttempt, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let attempt = await self.refreshMonetization(entitlement, uptime: uptime)
        XCTAssertEqual(attempt, expected, message, file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - End to end through the anonymous endpoint

    func test_aFetchedAppPolicyIsAdoptedPersistedUnderItsScopedKeyAndRestoredBeforeAnyRequest() async {
        let token = self.appPolicy(revision: 1, ios: self.versions("12.10.0", "12.10.6"))
        self.serve(appPolicy: token)
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        XCTAssertTrue(entitlement.isPublicPolicyOnly, "premise: a build that sells nothing still reads the app-update policy")
        XCTAssertEqual(entitlement.appUpdateDecision, .none, "nothing accepted yet: fail open")
        XCTAssertNil(entitlement.signedAppUpdatePolicy)

        let result = await self.refreshAppPolicy(entitlement, uptime: 1_000)
        XCTAssertEqual(result, .adopted)
        XCTAssertEqual(entitlement.signedAppUpdatePolicy?.revision, 1)
        XCTAssertEqual(entitlement.signedAppUpdatePolicy?.ios, self.constraint("12.10.0", "12.10.6"))
        XCTAssertEqual(entitlement.appUpdateDecision, .block(self.constraint("12.10.0", "12.10.6")), "12.9.2 is below min")

        XCTAssertEqual(self.policyDefaults.string(forKey: self.appPolicyKey), token, "the exact signed bytes under zg.app.policy.v1@<origin>")
        XCTAssertNil(self.policyDefaults.string(forKey: self.monetizationKey), "the monetization slot is untouched")
        XCTAssertNil(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.appUpdateDefaultsKey), "the bare key is never written")
        XCTAssertNil(entitlement.signedMonetizationPolicy, "an app-update policy is never the monetization policy")
        XCTAssertEqual(entitlement.monetizationMode, .free)

        let requests = SGPolicyStubProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/app-policy")
        XCTAssertNil(requests.first?.url?.query)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), SGEntitlementPolicyEndpoint.appPolicyAccept)
        let names = Set((requests.first?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no device, nonce or proof header: \(names)")

        // The next launch decides from the stored bytes alone, before any request leaves.
        let relaunched = self.makeEntitlement(installed: "12.9.2")
        XCTAssertEqual(SGAppUpdate(entitlement: relaunched).restoreDecision(), .block(self.constraint("12.10.0", "12.10.6")), "a known-blocked install is decided before its first frame")
        XCTAssertEqual(relaunched.signedAppUpdatePolicy?.revision, 1)
        XCTAssertEqual(SGPolicyStubProtocol.requests.count, 1, "restoring made no request")
        XCTAssertEqual(self.makeEntitlement(installed: "12.10.6").appUpdateDecision, .none, "the same policy, an install at latest: nothing")
        XCTAssertEqual(self.makeEntitlement(installed: "12.9.2-debug").appUpdateDecision, .none, "an unreadable installed version fails open")
    }

    func test_aMonetizationTokenOnTheAppPolicyPathIsRejected_andAnAppPolicyOnTheMonetizationPathToo() async {
        self.serve(appPolicy: self.monetization("paid", revision: 9), monetization: self.appPolicy(revision: 9, ios: self.versions("99.0", "99.0")))
        let entitlement = self.makeEntitlement()
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .rejected, "wrongPurpose: a monetization policy never decides whether the app may open")
        XCTAssertNil(entitlement.signedAppUpdatePolicy)
        XCTAssertEqual(entitlement.appUpdateDecision, .none)
        await self.expectMonetizationRefresh(entitlement, uptime: 1_000, toBe: .rejected, "wrongPurpose: an app-update policy never sets the mode")
        XCTAssertNil(entitlement.signedMonetizationPolicy)
        XCTAssertNil(self.policyDefaults.string(forKey: self.appPolicyKey))
        XCTAssertNil(self.policyDefaults.string(forKey: self.monetizationKey))
    }

    func test_unavailableRateLimitedOversizedAndTokenlessAnswersKeepTheAcceptedPolicy() async {
        let token = self.appPolicy(revision: 1, ios: self.versions("12.10.0", "12.10.6"))
        self.serve(appPolicy: token)
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)

        var uptime: TimeInterval = 1_000
        let answers: [(String, SGPolicyStubProtocol.Route)] = [
            ("503", self.route(["error": "app_policy_unavailable", "message": "no usable key"], status: 503)),
            ("429", self.route(["error": "rate_limited", "retry_after": 60], status: 429)),
            ("oversized", SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(8, of: 4096))),
            ("tokenless 200", self.route(["server_time": "2099-01-01T00:00:00Z"]))
        ]
        for (what, route) in answers {
            uptime += 60
            self.serveAppPolicy(route)
            await self.expectAppPolicyRefresh(entitlement, uptime: uptime, toBe: .failed, "\(what) is a transport failure, never a policy")
            XCTAssertEqual(entitlement.signedAppUpdatePolicy?.revision, 1, "\(what) changed the accepted policy")
            XCTAssertEqual(entitlement.appUpdateDecision, .block(self.constraint("12.10.0", "12.10.6")), "\(what) changed the decision")
            XCTAssertEqual(self.policyDefaults.string(forKey: self.appPolicyKey), token, "\(what) touched the stored bytes")
        }
    }

    func test_anOlderOrConflictingPolicyChangesNothing_aNewerOneLiftsTheBlock() async {
        let second = self.appPolicy(revision: 2, ios: self.versions("12.10.0", "12.10.6"))
        self.serve(appPolicy: second)
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        XCTAssertEqual(entitlement.appUpdateDecision, .block(self.constraint("12.10.0", "12.10.6")))

        self.serve(appPolicy: self.appPolicy(revision: 1))
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_060, toBe: .rejected, "an older revision — even a clearing one — is a replay")
        XCTAssertEqual(entitlement.appUpdateDecision, .block(self.constraint("12.10.0", "12.10.6")))

        self.serve(appPolicy: self.appPolicy(revision: 2, ios: self.versions("12.9.0", "12.10.6")))
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_120, toBe: .rejected, "the accepted issuance with other values is a conflict")
        XCTAssertEqual(entitlement.signedAppUpdatePolicy?.token, second, "the accepted bytes stand")

        self.serve(appPolicy: second)
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_180, toBe: .unchanged, "the accepted issuance again is a routine refresh")

        let forged = self.appPolicy(revision: 3, ios: self.versions("1.0", "1.0"), key: P256.Signing.PrivateKey())
        self.serve(appPolicy: forged)
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_240, toBe: .rejected, "badSignature: an unsigned min lifts nothing either")

        self.serve(appPolicy: self.appPolicy(revision: 3, ios: self.versions("12.9.0", "12.10.6")))
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_300, toBe: .adopted, "the corrected policy")
        XCTAssertEqual(entitlement.appUpdateDecision, .remind(latest: SGAppUpdateVersion("12.10.6")!), "12.9.2 is supported again and below latest")
        XCTAssertEqual(self.makeEntitlement(installed: "12.9.2").appUpdateDecision, .remind(latest: SGAppUpdateVersion("12.10.6")!), "the lift survives a relaunch")
    }

    // MARK: - Gate isolation

    func test_theAppPolicyGateIsItsOwn() async {
        self.serve(appPolicy: self.appPolicy(revision: 1), monetization: self.monetization("free", revision: 0))
        let entitlement = self.makeEntitlement()
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        await self.expectMonetizationRefresh(entitlement, uptime: 1_000, toBe: .adopted, "the app-policy attempt did not consume the monetization gate")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_001, toBe: .skipped, "…but has a 60 s cooldown of its own")
        await self.expectMonetizationRefresh(entitlement, uptime: 1_001, toBe: .skipped)
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_060, toBe: .unchanged)
        await self.expectMonetizationRefresh(entitlement, uptime: 1_001, toBe: .skipped, "the app-policy attempt did not reset the monetization cooldown either")
        XCTAssertEqual(SGPolicyStubProtocol.requests.map { $0.url?.path ?? "" }, ["/v1/app-policy", "/v1/monetization", "/v1/app-policy"])
    }

    // MARK: - Cadence

    /// How many times a scripted transport was asked, and the expectation its first fetch fulfils.
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

    private func counting(_ token: String, description: String) -> (transport: SGEntitlementPolicyTransport, fetches: () -> Int, fetched: XCTestExpectation) {
        let fetched = self.expectation(description: description)
        fetched.assertForOverFulfill = false
        let counter = FetchCounter()
        let transport = SGEntitlementPolicyTransport(fetch: {
            counter.increment()
            fetched.fulfill()
            return .success(token)
        })
        return (transport, { counter.value }, fetched)
    }

    func test_theSilentPushNeverFetchesTheAppPolicy_foregroundAndTheTimerTickDo() async {
        let entitlement = self.makeEntitlement()
        let monetization = self.counting(self.monetization("free", revision: 0), description: "the monetization policy was fetched")
        let appPolicy = self.counting(self.appPolicy(revision: 1), description: "the app-update policy was fetched")
        entitlement.installPolicyTransportForTesting(monetization.transport)
        entitlement.installAppUpdatePolicyTransportForTesting(appPolicy.transport)
        entitlement.setAccounts(SGEntitlementAccounts(primary: nil, all: []))

        let answered = self.expectation(description: "the push answered")
        entitlement.handleSilentPush(completion: { _ in
            answered.fulfill()
        })
        await self.fulfillment(of: [monetization.fetched, answered], timeout: 5)
        await self.settle(0.5)
        XCTAssertEqual(monetization.fetches(), 1, "the push refreshes the monetization policy")
        XCTAssertEqual(appPolicy.fetches(), 0, "NEVER the app-update policy: a background wake spends nothing on a block the user cannot see")

        // Before the first idle window nothing reaches the network (invariant I1).
        entitlement.applicationDidBecomeActive()
        entitlement.policyRefreshTimerDidFire()
        await self.settle(0.5)
        XCTAssertEqual(appPolicy.fetches(), 0)

        entitlement.markFirstIdlePassedForTesting()
        entitlement.applicationDidBecomeActive()
        await self.fulfillment(of: [appPolicy.fetched], timeout: 5)
        XCTAssertEqual(appPolicy.fetches(), 1, "foreground: the app-policy GET follows the monetization one (stagger collapsed to 0 here)")
        XCTAssertEqual(entitlement.signedAppUpdatePolicy?.revision, 1)

        entitlement.policyRefreshTimerDidFire()
        await self.settle(0.5)
        XCTAssertEqual(appPolicy.fetches(), 1, "a tick inside the 60 s cooldown sends nothing")

        // A fresh launch's tick fetches both, the app policy after the monetization policy.
        let next = self.makeEntitlement()
        let nextMonetization = self.counting(self.monetization("free", revision: 0), description: "next: monetization")
        let nextAppPolicy = self.counting(self.appPolicy(revision: 1), description: "next: app policy")
        next.installPolicyTransportForTesting(nextMonetization.transport)
        next.installAppUpdatePolicyTransportForTesting(nextAppPolicy.transport)
        next.markFirstIdlePassedForTesting()
        next.policyRefreshTimerDidFire()
        await self.fulfillment(of: [nextMonetization.fetched, nextAppPolicy.fetched], timeout: 5)
        XCTAssertEqual(nextMonetization.fetches(), 1)
        XCTAssertEqual(nextAppPolicy.fetches(), 1)
    }

    /// update_policy_spec §7 "refresh still ticking while blocked": a block pauses nothing. With a blocking
    /// policy accepted (`appUpdateDecision == .block`), the periodic tick and a foreground each still issue
    /// the app-policy GET, and the corrected policy they bring back lifts the block — `decisionDidChange`
    /// is posted and the decision reads `.remind`. One launch per trigger, because the gate allows one
    /// attempt per 60 s of real uptime; the adopting fetch is dated 120 s of uptime before the trigger.
    func test_theRefreshKeepsTickingWhileBlocked_andTheCorrectedPolicyItFetchesLiftsTheBlock() async {
        let blocking = { (revision: Int64) in self.appPolicy(revision: revision, ios: self.versions("99.0", "99.0")) }
        let corrected = { (revision: Int64) in self.appPolicy(revision: revision, ios: self.versions("12.9.0", "12.10.6")) }
        let blocked: SGAppUpdateDecision = .block(self.constraint("99.0", "99.0"))
        let lifted: SGAppUpdateDecision = .remind(latest: SGAppUpdateVersion("12.10.6")!)
        let earlier = ProcessInfo.processInfo.systemUptime - 120

        // The periodic tick.
        self.serve(appPolicy: blocking(1))
        let ticking = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(ticking, uptime: earlier, toBe: .adopted)
        XCTAssertEqual(ticking.appUpdateDecision, blocked, "premise: blocked")
        let tickMonetization = self.counting(self.monetization("free", revision: 0), description: "tick: monetization")
        let tickAppPolicy = self.counting(corrected(2), description: "tick: the app policy is fetched while blocked")
        ticking.installPolicyTransportForTesting(tickMonetization.transport)
        ticking.installAppUpdatePolicyTransportForTesting(tickAppPolicy.transport)
        let liftedByTick = XCTNSNotificationExpectation(name: SGAppUpdate.decisionDidChange)
        ticking.markFirstIdlePassedForTesting()
        ticking.policyRefreshTimerDidFire()
        await self.fulfillment(of: [tickMonetization.fetched, tickAppPolicy.fetched, liftedByTick], timeout: 5)
        XCTAssertEqual(tickAppPolicy.fetches(), 1, "the tick fetched the app policy while blocked")
        XCTAssertEqual(ticking.appUpdateDecision, lifted, "the corrected policy lifted the block")

        // A foreground, on a later launch (revision 3 blocks again, 4 lifts).
        self.serve(appPolicy: blocking(3))
        let foregrounded = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(foregrounded, uptime: earlier, toBe: .adopted)
        XCTAssertEqual(foregrounded.appUpdateDecision, blocked, "premise: blocked again")
        let foregroundMonetization = self.counting(self.monetization("free", revision: 0), description: "foreground: monetization")
        let foregroundAppPolicy = self.counting(corrected(4), description: "foreground: the app policy is fetched while blocked")
        foregrounded.installPolicyTransportForTesting(foregroundMonetization.transport)
        foregrounded.installAppUpdatePolicyTransportForTesting(foregroundAppPolicy.transport)
        let liftedByForeground = XCTNSNotificationExpectation(name: SGAppUpdate.decisionDidChange)
        foregrounded.markFirstIdlePassedForTesting()
        foregrounded.applicationDidBecomeActive()
        await self.fulfillment(of: [foregroundMonetization.fetched, foregroundAppPolicy.fetched, liftedByForeground], timeout: 5)
        XCTAssertEqual(foregroundAppPolicy.fetches(), 1, "the foreground fetched the app policy while blocked")
        XCTAssertEqual(foregrounded.appUpdateDecision, lifted)
        XCTAssertEqual(SGAppUpdate(entitlement: self.makeEntitlement(installed: "12.9.2")).restoreDecision(), lifted, "the lift is persisted")
    }

    func test_theAppPolicyGETIsStaggeredFiveToThirtySecondsAfterTheMonetizationGET() {
        XCTAssertEqual(SGEntitlement.appUpdatePolicyStagger, 5 ... 30)
        for _ in 0 ..< 50 {
            let delay = SGEntitlement.appUpdatePolicyStaggerDelay()
            XCTAssertGreaterThanOrEqual(delay, 5)
            XCTAssertLessThanOrEqual(delay, 30)
        }
    }

    // MARK: - The decision, its holder and its publication

    func test_anAdoptedAppPolicyPostsDecisionDidChangeOnTheMainQueue() async {
        self.serve(appPolicy: self.appPolicy(revision: 1, ios: self.versions("12.10.0", "12.10.6")))
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        let changed = XCTNSNotificationExpectation(name: SGAppUpdate.decisionDidChange)
        changed.handler = { _ in
            XCTAssertTrue(Thread.isMainThread, "posted on the main queue")
            return true
        }
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        await self.fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(SGAppUpdate(entitlement: entitlement).currentDecision, .block(self.constraint("12.10.0", "12.10.6")))
    }

    func test_theHolderReadsTheDecisionAndRecordsTheReminderUnderTheOrigin() async {
        self.serve(appPolicy: self.appPolicy(revision: 1, ios: self.versions("12.9.0", "12.10.0")))
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        let holder = SGAppUpdate(entitlement: entitlement)
        XCTAssertEqual(holder.restoreDecision(), .none, "nothing stored: nothing shown before the first fetch")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        let latest = SGAppUpdateVersion("12.10.0")!
        XCTAssertEqual(holder.currentDecision, .remind(latest: latest))
        XCTAssertEqual(holder.restoreDecision(), .remind(latest: latest))
        XCTAssertNil(self.policyDefaults.string(forKey: self.remindedKey), "a decision alone never writes the marker")

        holder.noteReminderShown(latest: latest)
        XCTAssertEqual(self.policyDefaults.string(forKey: self.remindedKey), "12.10.0", "zg.app.policy.reminded@<origin> = latest")
        XCTAssertEqual(holder.currentDecision, .none, "shown once")
        XCTAssertEqual(SGAppUpdate(entitlement: self.makeEntitlement(installed: "12.9.2")).restoreDecision(), .none, "…and not again after a relaunch")

        self.serve(appPolicy: self.appPolicy(revision: 2, ios: self.versions("12.9.0", "12.11")))
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_060, toBe: .adopted)
        XCTAssertEqual(holder.currentDecision, .remind(latest: SGAppUpdateVersion("12.11")!), "a new latest reminds once more")
        XCTAssertEqual(self.policyDefaults.string(forKey: self.remindedKey), "12.10.0", "the marker moves only when the presenter shows the new alert")
    }

    func test_aStoredBlockLiftsItselfOnceItsPolicyWentUnrefreshedForThirtyDays() async {
        self.serve(appPolicy: self.appPolicy(revision: 1, ios: self.versions("12.10.0", "12.10.6")))
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        guard let expiresAt = entitlement.signedAppUpdatePolicy?.expiresAt else {
            return XCTFail("premise: a policy was adopted")
        }

        let withinValve = self.makeEntitlement(installed: "12.9.2", policyClock: { Date(timeIntervalSince1970: TimeInterval(expiresAt + 30 * 86400)) })
        XCTAssertEqual(withinValve.appUpdateDecision, .block(self.constraint("12.10.0", "12.10.6")), "exp >= now - 30 days: still blocked")
        let pastValve = self.makeEntitlement(installed: "12.9.2", policyClock: { Date(timeIntervalSince1970: TimeInterval(expiresAt + 30 * 86400 + 1)) })
        XCTAssertEqual(pastValve.appUpdateDecision, .none, "a block never outlives 30 days without a successful fetch")
        XCTAssertEqual(pastValve.signedAppUpdatePolicy?.revision, 1, "the policy itself is kept: the next fetch is ranked against it")
        let remindPastValve = self.makeEntitlement(installed: "12.10.2", policyClock: { Date(timeIntervalSince1970: TimeInterval(expiresAt + 365 * 86400)) })
        XCTAssertEqual(remindPastValve.appUpdateDecision, .remind(latest: SGAppUpdateVersion("12.10.6")!), "the reminder has no valve")
    }

    func test_aRotatedRingRestoresNoBlock() async {
        self.serve(appPolicy: self.appPolicy(revision: 1, ios: self.versions("99.0", "99.0")))
        let entitlement = self.makeEntitlement(installed: "12.9.2")
        await self.expectAppPolicyRefresh(entitlement, uptime: 1_000, toBe: .adopted)
        XCTAssertEqual(entitlement.appUpdateDecision, .block(self.constraint("99.0", "99.0")))

        // The next build ships a ring without this kid: the stored block verifies no more.
        let rotatedEndpoint = SGEntitlementPolicyEndpoint(url: URL(string: "\(self.origin)/v1/monetization")!, protocolClasses: [SGPolicyStubProtocol.self])!
        let rotated = SGEntitlementPublicPolicyConfiguration(endpoint: rotatedEndpoint, keysByKid: SGEntitlementTestToken.pinned(P256.Signing.PrivateKey(), kid: "k2026b").keysByKid)!
        let relaunched = SGEntitlement(
            store: self.store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: self.policyDefaults),
            policyClock: { Date(timeIntervalSince1970: TimeInterval(self.policyNow)) },
            publicPolicy: rotated,
            isPublicPolicyRequested: true,
            isAuthenticatedEntitlementConfigured: false
        )
        self.made.append(relaunched)
        relaunched.overrideInstalledAppVersion("12.9.2")
        XCTAssertNil(relaunched.signedAppUpdatePolicy, "a stored policy under a key the ring no longer holds is no policy")
        XCTAssertEqual(relaunched.appUpdateDecision, .none)
        XCTAssertEqual(self.policyDefaults.string(forKey: self.appPolicyKey)?.isEmpty, false, "the bytes are kept, not deleted: the same ring would restore them")
    }

    // MARK: - A build without the explicit public configuration

    func test_theLegacyAppPolicyEndpointIsTheAuthenticatedBaseURLsAnonymousGET() async {
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "\(self.origin)/v1")!, appVersion: "1.0", osVersion: "27.0")
        configuration.protocolClasses = [SGPolicyStubProtocol.self]
        let endpoint = SGEntitlementPolicyEndpoint.legacyAppPolicy(configuration)
        let token = self.appPolicy(revision: 0)
        self.serve(appPolicy: token)
        let result = await endpoint.fetch()
        XCTAssertEqual(try? result.get(), token)
        XCTAssertEqual(SGPolicyStubProtocol.requests.first?.url?.path, "/v1/app-policy")
        XCTAssertEqual(SGPolicyStubProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), SGEntitlementPolicyEndpoint.appPolicyAccept)
        let names = Set((SGPolicyStubProtocol.requests.first?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no app version, device or credential headers: \(names)")
    }
}
