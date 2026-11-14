import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — the explicit public policy (`SGEntitlementPublicPolicyConfiguration`) wired into the
/// live coordinator, on instances that own their store, scheduler and policy defaults:
///
/// - a real refresh through the anonymous endpoint with NO authenticated client;
/// - the public ring as the policy's only trust, and never an entitlement trust;
/// - an origin-scoped cache that never reads, imports or touches the bare legacy key or another
///   origin's, so an old high-revision PAID cannot suppress a FREE revision 0;
/// - a public-policy-only build that keeps the signed policy for diagnostics yet stays FREE: no
///   offer, no grace countdown, no purchase admission;
/// - builds without the explicit configuration keep the entitlement ring, and cache their policy under
///   their own backend scope — never the bare legacy key, never the public origin's.
final class SGEntitlementPublicPolicyTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let kid = "k2026a"
    /// Signs the public policy (the `.org` ring).
    private let publicKey = P256.Signing.PrivateKey()
    /// Signs authenticated entitlement material — and, in the hostile cases, a policy.
    private let entitlementKey = P256.Signing.PrivateKey()
    private let host = "policy.zenlygram.test"
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var policySuite = ""
    private var policyNow: Int64 = 0
    private var store: SGEntitlementStore!

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        SGPolicyStubProtocol.reset(routes: [:])
        let unique = UUID().uuidString
        self.policyNow = Int64(Date().timeIntervalSince1970)
        self.storeSuite = "SGEntitlementPublicPolicyTests.store.\(unique)"
        self.schedulerSuite = "SGEntitlementPublicPolicyTests.scheduler.\(unique)"
        self.policySuite = "SGEntitlementPublicPolicyTests.policy.\(unique)"
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
        self.store.clearSession(accountPeerId: self.account)
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

    private var publicRing: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.publicKey, kid: self.kid)
    }

    private var entitlementRing: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.entitlementKey, kid: self.kid)
    }

    private var publicPolicy: SGEntitlementPublicPolicyConfiguration {
        let endpoint = SGEntitlementPolicyEndpoint(url: URL(string: "https://\(self.host)/v1/monetization")!, protocolClasses: [SGPolicyStubProtocol.self])!
        return SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: self.publicRing.keysByKid)!
    }

    private var originKey: String {
        return SGEntitlementPolicyStore.originKey("https://\(self.host)")
    }

    /// One launch. `publicPolicy: nil` is a build without the explicit configuration unless
    /// `requested` says `sg_config` named it anyway (requested but invalid). The entitlement ring
    /// defaults to EMPTY, the device profile's; enforcement is forced on so a decision that followed
    /// a signed PAID would show (a countdown, a degraded state).
    private func makeEntitlement(
        publicPolicy: SGEntitlementPublicPolicyConfiguration?,
        requested: Bool? = nil,
        authenticated: Bool = false,
        entitlementRing: SGEntitlementPinnedKeys = SGEntitlementPinnedKeys(keysByKid: [:])
    ) -> SGEntitlement {
        let fixed = Date(timeIntervalSince1970: TimeInterval(self.policyNow))
        let entitlement = SGEntitlement(
            store: self.store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: self.policyDefaults),
            policyClock: { fixed },
            publicPolicy: publicPolicy,
            isPublicPolicyRequested: requested ?? (publicPolicy != nil),
            isAuthenticatedEntitlementConfigured: authenticated
        )
        entitlement.overridePinnedKeys(entitlementRing)
        entitlement.overrideEnforcement(.enforcing)
        // Inside the 7-day window: a paid decision would quote "free until <date>".
        entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: Date().addingTimeInterval(-86400)))
        return entitlement
    }

    private func policy(_ mode: String, revision: Int64, key: P256.Signing.PrivateKey? = nil, iat: Int64? = nil) -> String {
        return SGEntitlementTestPolicy.make(key: key ?? self.publicKey, kid: self.kid, mode: mode, revision: revision, iat: iat ?? self.policyNow)
    }

    /// The v2 shape, with its signed `trial_days`.
    private func policyV2(_ mode: String, revision: Int64, trialDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.publicKey, kid: self.kid, mode: mode, revision: revision, iat: self.policyNow, version: 2, trialDays: trialDays)
    }

    private func serve(_ token: String, serverTime: String = "2099-01-01T00:00:00Z") {
        SGPolicyStubProtocol.reset(routes: [self.host: SGPolicyStubProtocol.Route(headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(["policy_token": token, "server_time": serverTime])])])
    }

    /// The real anonymous GET against the scripted origin.
    private func refresh(_ entitlement: SGEntitlement, serving token: String, uptime: TimeInterval) async -> SGEntitlementPolicyRefreshAttempt {
        self.serve(token)
        return await entitlement.performPolicyRefresh(transport: .live(self.publicPolicy.endpoint), uptime: uptime)
    }

    private func seedSession(token: String, into entitlement: SGEntitlement) {
        let material = SGEntitlementSessionMaterial(refreshToken: "current-session", entitlement: token, accountId: "01JB8Q", deviceId: "01JB8R")
        let seeded = self.store.updateSession(accountPeerId: self.account) { stored in
            stored = material
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
        entitlement.setActiveAccount(peerId: self.account)
        entitlement.invalidate()
    }

    // MARK: - Refresh without an authenticated client

    func test_aPublicRefreshVerifiesWithNoAuthenticatedClientAndSendsNothingIdentifying() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        XCTAssertTrue(entitlement.isPublicPolicyOnly)
        XCTAssertNil(entitlement.client, "premise: no authenticated client exists")
        let mark = SGEntitlementClock.shared.currentMark

        let free0 = self.policy("free", revision: 0)
        let result = await self.refresh(entitlement, serving: free0, uptime: 1_000)

        XCTAssertEqual(result, .adopted)
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.mode, .free)
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.revision, 0)
        XCTAssertNil(entitlement.client, "a public refresh never creates the authenticated client")
        let requests = SGPolicyStubProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, self.host)
        XCTAssertEqual(requests.first?.url?.path, "/v1/monetization")
        let names = Set((requests.first?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"))
        XCTAssertFalse(names.contains("cookie"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no device id, nonce, signature or proof: \(names)")
        XCTAssertEqual(SGEntitlementClock.shared.currentMark, mark, "the unsigned server_time moves no clock")
        XCTAssertEqual(self.policyDefaults.string(forKey: self.originKey), free0, "the exact signed bytes, persisted under their own origin")
        XCTAssertNil(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), "the bare legacy key is never written")
    }

    // MARK: - Public-only is FREE whatever the signed mode

    func test_aSignedPaidStaysDiagnostic_publicOnlyOffersNothingAndCountsNothingDown() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        let result = await self.refresh(entitlement, serving: self.policy("paid", revision: 1), uptime: 1_000)
        XCTAssertEqual(result, .adopted, "the signed policy itself is accepted and kept")
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.mode, .paid)

        XCTAssertEqual(entitlement.monetizationMode, .free, "no products, no attach server: never a purchase flow")
        XCTAssertFalse(entitlement.offersNewSubscriptions)
        XCTAssertNil(entitlement.localGraceEndsAt, "no 'free until <date>' countdown")
        XCTAssertEqual(entitlement.source, .freeAccess)
        XCTAssertEqual(entitlement.state, .unlocked(capabilities: Set(SGEntitlementCapability.base.map { $0.rawValue })))

        let requestsBefore = SGPolicyStubProtocol.requests.count
        let shipped = await entitlement.authorizeNewPurchase()
        XCTAssertEqual(shipped, .unavailable)
        var asked = false
        let injected = await entitlement.authorizeNewPurchase(transport: SGEntitlementPolicyTransport(fetch: {
            asked = true
            return .success(self.policy("paid", revision: 1))
        }))
        XCTAssertEqual(injected, .unavailable, "even a fresh verified PAID admits no purchase here")
        XCTAssertFalse(asked, "no policy request is made for a purchase that cannot happen")
        XCTAssertEqual(SGPolicyStubProtocol.requests.count, requestsBefore)

        let relaunched = self.makeEntitlement(publicPolicy: self.publicPolicy)
        XCTAssertEqual(relaunched.signedMonetizationPolicy?.mode, .paid, "re-verified from its origin's cache with the public ring")
        XCTAssertEqual(relaunched.monetizationMode, .free)
        XCTAssertFalse(relaunched.offersNewSubscriptions)
    }

    func test_withAuthenticationConfiguredTheSignedPublicPolicyDecides() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertFalse(entitlement.isPublicPolicyOnly)
        let result = await self.refresh(entitlement, serving: self.policy("paid", revision: 1), uptime: 1_000)
        XCTAssertEqual(result, .adopted)
        XCTAssertEqual(entitlement.monetizationMode, .paid, "the paid/free business rule is unchanged where a purchase can be served")
        XCTAssertTrue(entitlement.offersNewSubscriptions)
    }

    // MARK: - The server's trial (`trial_days`)

    func test_serverTrialDaysFollowTheSignedPaidPolicyAndNothingElse() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertFalse(entitlement.isPublicPolicyOnly, "premise: this build can sell")
        XCTAssertNil(entitlement.serverTrialDays, "nothing before the first verified policy")

        let freeWithDays = await self.refresh(entitlement, serving: self.policyV2("free", revision: 1, trialDays: 7), uptime: 1_000)
        XCTAssertEqual(freeWithDays, .adopted)
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.trialDays, 7, "the signed value is kept as signed")
        XCTAssertNil(entitlement.serverTrialDays, "never while free, whatever the signed days")

        let paidSeven = await self.refresh(entitlement, serving: self.policyV2("paid", revision: 2, trialDays: 7), uptime: 1_061)
        XCTAssertEqual(paidSeven, .adopted)
        XCTAssertEqual(entitlement.monetizationMode, .paid)
        XCTAssertEqual(entitlement.serverTrialDays, 7)

        let paidNone = await self.refresh(entitlement, serving: self.policyV2("paid", revision: 3, trialDays: 0), uptime: 1_122)
        XCTAssertEqual(paidNone, .adopted)
        XCTAssertEqual(entitlement.monetizationMode, .paid, "disabling the trial does not touch the mode")
        XCTAssertNil(entitlement.serverTrialDays, "paid with no trial on offer")

        let paidV1 = await self.refresh(entitlement, serving: self.policy("paid", revision: 4), uptime: 1_183)
        XCTAssertEqual(paidV1, .adopted)
        XCTAssertNil(entitlement.serverTrialDays, "a v1 policy cannot say: fail-safe, no trial")

        let ten = self.policyV2("paid", revision: 5, trialDays: 10)
        let paidTen = await self.refresh(entitlement, serving: ten, uptime: 1_244)
        XCTAssertEqual(paidTen, .adopted)
        XCTAssertEqual(entitlement.serverTrialDays, 10)
        XCTAssertEqual(self.policyDefaults.string(forKey: self.originKey), ten, "the exact signed v2 bytes are persisted under the unchanged origin key")
        XCTAssertNil(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), "the bare legacy key is never written")

        let relaunched = self.makeEntitlement(publicPolicy: self.publicPolicy, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertEqual(relaunched.serverTrialDays, 10, "restored from the origin's cache with its trial_days, never re-expired")
        XCTAssertEqual(relaunched.monetizationMode, .paid)
    }

    func test_aPublicPolicyOnlyBuildOffersNoServerTrialWhateverTheSignedPolicySays() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        XCTAssertTrue(entitlement.isPublicPolicyOnly)
        let result = await self.refresh(entitlement, serving: self.policyV2("paid", revision: 1, trialDays: 7), uptime: 1_000)
        XCTAssertEqual(result, .adopted, "the signed policy itself is accepted and kept")
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.trialDays, 7, "kept for diagnostics")
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.offersServerTrial, true)
        XCTAssertEqual(entitlement.monetizationMode, .free)
        XCTAssertNil(entitlement.serverTrialDays, "nothing to sell and no server to start a trial on: no trial is offered")
        XCTAssertFalse(entitlement.offersNewSubscriptions)

        let relaunched = self.makeEntitlement(publicPolicy: self.publicPolicy)
        XCTAssertEqual(relaunched.signedMonetizationPolicy?.trialDays, 7)
        XCTAssertNil(relaunched.serverTrialDays)
    }

    // MARK: - Distinct trust

    func test_onlyThePublicRingVerifiesThePolicy_andItNeverVerifiesAnEntitlement() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy, entitlementRing: self.entitlementRing)

        let signedByEntitlementKey = await self.refresh(entitlement, serving: self.policy("paid", revision: 5, key: self.entitlementKey), uptime: 1_000)
        XCTAssertEqual(signedByEntitlementKey, .rejected, "the entitlement ring is no policy trust here, even under the same kid")
        XCTAssertNil(entitlement.signedMonetizationPolicy)

        let signedByPublicKey = await self.refresh(entitlement, serving: self.policy("free", revision: 0), uptime: 1_061)
        XCTAssertEqual(signedByPublicKey, .adopted)

        let issuedAt = Int64(SGEntitlementClock.shared.effectiveNow().timeIntervalSince1970)
        let claims = SGEntitlementTestToken.claims(iat: issuedAt, exp: issuedAt + 72 * 3600, account: .explicit(ent: ["vault", "chatlock", "tasks", "edithistory"], until: "2030-01-01T00:00:00Z"))
        self.seedSession(token: SGEntitlementTestToken.make(key: self.publicKey, kid: self.kid, payload: claims), into: entitlement)
        XCTAssertNil(entitlement.genuineGrantUntil(accountPeerId: self.account), "the public ring never verifies an entitlement token")
        self.seedSession(token: SGEntitlementTestToken.make(key: self.entitlementKey, kid: self.kid, payload: claims), into: entitlement)
        XCTAssertNotNil(entitlement.genuineGrantUntil(accountPeerId: self.account), "premise: the entitlement ring is untouched and still verifies its own tokens")
    }

    // MARK: - Origin-scoped cache

    func test_legacyAndOtherOriginPaidCachesAreNeverRead_andCannotSuppressAFreeRevisionZero() async {
        // Worst case: high-revision PAID policies signed by the very same ring, under the bare legacy
        // key, another host's origin and this host on another port.
        let legacyPaid = self.policy("paid", revision: 9)
        let otherOrigins = [
            SGEntitlementPolicyStore.originKey("https://zenlygram.com"),
            SGEntitlementPolicyStore.originKey("https://\(self.host):8443")
        ]
        self.policyDefaults.set(legacyPaid, forKey: SGEntitlementPolicyStore.defaultsKey)
        for key in otherOrigins {
            self.policyDefaults.set(legacyPaid, forKey: key)
        }
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: legacyPaid, pinnedKeys: self.publicRing).mode, .paid, "premise: the foreign bytes verify under this ring")

        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        XCTAssertNil(entitlement.signedMonetizationPolicy, "nothing is imported from another origin's cache")

        let result = await self.refresh(entitlement, serving: self.policy("free", revision: 0), uptime: 1_000)
        XCTAssertEqual(result, .adopted, "revision 0 is this origin's first policy, not 'older' than revision 9 elsewhere")
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.revision, 0)
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.mode, .free)

        XCTAssertEqual(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), legacyPaid, "the bare legacy key is byte-for-byte untouched")
        for key in otherOrigins {
            XCTAssertEqual(self.policyDefaults.string(forKey: key), legacyPaid, "\(key) is byte-for-byte untouched")
        }
    }

    // MARK: - Order and verification within the origin

    func test_withinItsOriginAnInvalidExpiredOrRolledBackPolicyChangesNothing() async {
        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        let free2 = self.policy("free", revision: 2)
        let adopted = await self.refresh(entitlement, serving: free2, uptime: 1_000)
        XCTAssertEqual(adopted, .adopted)

        let rollback = await self.refresh(entitlement, serving: self.policy("paid", revision: 1), uptime: 1_061)
        XCTAssertEqual(rollback, .rejected, "a replayed older revision never undoes a newer one")
        let forged = await self.refresh(entitlement, serving: self.policy("paid", revision: 9, key: P256.Signing.PrivateKey()), uptime: 1_122)
        XCTAssertEqual(forged, .rejected)
        let expired = await self.refresh(entitlement, serving: self.policy("paid", revision: 9, iat: self.policyNow - 86400 - 600), uptime: 1_183)
        XCTAssertEqual(expired, .rejected)
        let same = await self.refresh(entitlement, serving: free2, uptime: 1_244)
        XCTAssertEqual(same, .unchanged)

        XCTAssertEqual(entitlement.signedMonetizationPolicy?.revision, 2)
        XCTAssertEqual(self.policyDefaults.string(forKey: self.originKey), free2, "only the adopted bytes are stored")

        let paid3 = self.policy("paid", revision: 3)
        let newer = await self.refresh(entitlement, serving: paid3, uptime: 1_305)
        XCTAssertEqual(newer, .adopted)
        XCTAssertEqual(entitlement.signedMonetizationPolicy?.mode, .paid)
        XCTAssertEqual(entitlement.monetizationMode, .free, "still public-only")
    }

    // MARK: - Requested but invalid fails closed

    func test_aRequestedButInvalidConfigurationFailsClosedIntoPublicOnly() async {
        // Worst case: the bare legacy key and another origin hold a high-revision PAID that the
        // entitlement ring of this very build verifies.
        let legacyPaid = self.policy("paid", revision: 9, key: self.entitlementKey)
        let otherOrigin = SGEntitlementPolicyStore.originKey("https://zenlygram.com")
        self.policyDefaults.set(legacyPaid, forKey: SGEntitlementPolicyStore.defaultsKey)
        self.policyDefaults.set(legacyPaid, forKey: otherOrigin)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: legacyPaid, pinnedKeys: self.entitlementRing).mode, .paid, "premise: the legacy bytes verify under the entitlement ring")

        let entitlement = self.makeEntitlement(publicPolicy: nil, requested: true, entitlementRing: self.entitlementRing)
        XCTAssertTrue(entitlement.isPublicPolicyOnly, "a malformed explicit request is still public-only: SGIAP defers all Apple work")
        XCTAssertNil(entitlement.signedMonetizationPolicy, "the bare legacy cache is never read")
        XCTAssertEqual(entitlement.monetizationMode, .free)
        XCTAssertFalse(entitlement.offersNewSubscriptions)
        XCTAssertNil(entitlement.localGraceEndsAt)
        let authorization = await entitlement.authorizeNewPurchase()
        XCTAssertEqual(authorization, .unavailable)

        let byEntitlementRing = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(self.policy("paid", revision: 10, key: self.entitlementKey)) }), uptime: 1_000)
        XCTAssertEqual(byEntitlementRing, .rejected, "no fallback to the entitlement ring")
        let byPublicKey = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(self.policy("free", revision: 0)) }), uptime: 1_061)
        XCTAssertEqual(byPublicKey, .rejected, "an invalid ring verifies nothing at all")
        XCTAssertNil(entitlement.signedMonetizationPolicy)
        XCTAssertEqual(entitlement.monetizationMode, .free)

        XCTAssertEqual(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), legacyPaid, "the bare legacy key is byte-for-byte untouched")
        XCTAssertEqual(self.policyDefaults.string(forKey: otherOrigin), legacyPaid)
        XCTAssertNil(self.policyDefaults.string(forKey: self.originKey), "no cache is written for an invalid request")

        let relaunched = self.makeEntitlement(publicPolicy: nil, requested: true, entitlementRing: self.entitlementRing)
        XCTAssertNil(relaunched.signedMonetizationPolicy)
        XCTAssertEqual(relaunched.monetizationMode, .free)
    }

    func test_aRequestedButInvalidConfigurationNeverFallsBackEvenWithAuthentication() async {
        let legacyPaid = self.policy("paid", revision: 9, key: self.entitlementKey)
        self.policyDefaults.set(legacyPaid, forKey: SGEntitlementPolicyStore.defaultsKey)

        let entitlement = self.makeEntitlement(publicPolicy: nil, requested: true, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertFalse(entitlement.isPublicPolicyOnly)
        XCTAssertNil(entitlement.signedMonetizationPolicy, "not the bare legacy cache")
        XCTAssertEqual(entitlement.monetizationMode, .free, "no verified policy: free")
        XCTAssertFalse(entitlement.offersNewSubscriptions)
        let refreshed = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(self.policy("paid", revision: 10, key: self.entitlementKey)) }), uptime: 1_000)
        XCTAssertEqual(refreshed, .rejected, "not the entitlement ring")
        XCTAssertEqual(entitlement.monetizationMode, .free)
        XCTAssertEqual(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), legacyPaid)
    }

    // MARK: - Preservation on the policy path

    /// The policy path only: a real public refresh (adopted and rejected), a refused purchase
    /// authorization, decisions read, and a requested-but-invalid build's refresh — none of them may
    /// touch an earlier build's pending attach or session. This does NOT exercise the StoreKit
    /// listener or `finish()` wiring (`SGIAPAppleBoundary` and the unrun SGIAP integration own that).
    func test_thePolicyPathLeavesAPendingAttachAndTheSessionByteForByte() async {
        let outbox = SGEntitlementOutbox(store: self.store)
        let entry = outbox.enqueue(signedTransaction: "historical.signed.transaction", transactionId: "2000000123456789", accountPeerId: self.account)
        let material = SGEntitlementSessionMaterial(refreshToken: "historical-session", entitlement: "historical-token", accountId: "01JB8Q", deviceId: "01JB8R")
        guard case .success = self.store.updateSession(accountPeerId: self.account, { $0 = material }) else {
            return XCTFail("premise: the owned store persists the session")
        }
        self.store.invalidateCache()
        let persistedMaterial = self.store.session(accountPeerId: self.account)
        let outboxBytes = self.store.outboxData()
        XCTAssertNotNil(outboxBytes, "premise: the pending attach is persisted")
        let persisted = UserDefaults(suiteName: self.storeSuite)?.persistentDomain(forName: self.storeSuite) as NSDictionary?
        XCTAssertNotNil(persisted)

        let entitlement = self.makeEntitlement(publicPolicy: self.publicPolicy)
        entitlement.setActiveAccount(peerId: self.account)
        _ = entitlement.state
        let adopted = await self.refresh(entitlement, serving: self.policy("paid", revision: 1), uptime: 1_000)
        XCTAssertEqual(adopted, .adopted)
        let rejected = await self.refresh(entitlement, serving: self.policy("paid", revision: 2, key: P256.Signing.PrivateKey()), uptime: 1_061)
        XCTAssertEqual(rejected, .rejected)
        let authorization = await entitlement.authorizeNewPurchase()
        XCTAssertEqual(authorization, .unavailable)
        entitlement.invalidate()
        _ = entitlement.state
        _ = entitlement.monetizationMode

        let invalid = self.makeEntitlement(publicPolicy: nil, requested: true)
        invalid.setActiveAccount(peerId: self.account)
        let refused = await invalid.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(self.policy("paid", revision: 3)) }), uptime: 2_000)
        XCTAssertEqual(refused, .rejected)
        _ = invalid.state

        self.store.invalidateCache()
        XCTAssertEqual(self.store.outboxData(), outboxBytes, "the serialized outbox is byte-for-byte unchanged")
        XCTAssertEqual(SGEntitlementOutbox(store: self.store).entries(), [entry], "the pending attach was not removed or rewritten")
        XCTAssertEqual(self.store.session(accountPeerId: self.account), persistedMaterial, "the persisted session material is unchanged")
        XCTAssertEqual(UserDefaults(suiteName: self.storeSuite)?.persistentDomain(forName: self.storeSuite) as NSDictionary?, persisted, "nothing in the store's persisted domain moved")
    }

    // MARK: - Builds without the explicit configuration

    func test_aBuildWithoutThePublicConfiguration_verifiesWithTheEntitlementRing_andCachesUnderItsOwnScopeOnly() async {
        // The bare pre-origin key holds a policy that verifies under the SAME entitlement ring and out-ranks
        // revision 1. If the bare cache were still read, the PAID revision 1 below would be rejected as older.
        let bare = self.policy("free", revision: 50, key: self.entitlementKey)
        self.policyDefaults.set(bare, forKey: SGEntitlementPolicyStore.defaultsKey)

        let entitlement = self.makeEntitlement(publicPolicy: nil, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertFalse(entitlement.isPublicPolicyOnly)
        XCTAssertEqual(entitlement.monetizationMode, .free, "the bare pre-origin policy decided nothing")
        let paid = self.policy("paid", revision: 1, key: self.entitlementKey)
        let result = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(paid) }), uptime: 1_000)
        XCTAssertEqual(result, .adopted, "verified with the entitlement ring, and not ranked against the bare cache")
        XCTAssertEqual(entitlement.monetizationMode, .paid)

        XCTAssertEqual(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), bare, "the bare key is neither written nor removed")
        XCTAssertNil(self.policyDefaults.string(forKey: self.originKey), "the public origin's cache is untouched")

        // A relaunch of the same build restores its own policy through the consumer.
        let relaunched = self.makeEntitlement(publicPolicy: nil, authenticated: true, entitlementRing: self.entitlementRing)
        XCTAssertEqual(relaunched.monetizationMode, .paid, "the build's own cached policy was not restored")
    }

    func test_theLegacyEndpointIsTheAuthenticatedBaseURLsAnonymousGET() async {
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://\(self.host)/v1")!, appVersion: "1.0", osVersion: "27.0")
        configuration.protocolClasses = [SGPolicyStubProtocol.self]
        let endpoint = SGEntitlementPolicyEndpoint.legacy(configuration)
        let token = self.policy("free", revision: 0)
        self.serve(token)
        let result = await endpoint.fetch()
        XCTAssertEqual(try? result.get(), token)
        XCTAssertEqual(SGPolicyStubProtocol.requests.first?.url?.path, "/v1/monetization")
        let names = Set((SGPolicyStubProtocol.requests.first?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no app version, device or credential headers: \(names)")
    }
}
