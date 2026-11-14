import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — an authenticated build without an explicit public policy caches the signed monetization
/// policy under its backend origin's own key (`zg.ent.policy.v1@<authority>`, the store's
/// `SGEntitlementStoreScope`), like every other origin-bound item. The bare legacy key — and another
/// origin's — is never read, written or removed, so an old origin's high-revision PAID signed by the
/// same ring can neither out-rank the new origin's first policy nor decide the mode before it.
final class SGEntitlementOriginPolicyCacheTests: XCTestCase {
    private let kid = "k2026a"
    private let key = P256.Signing.PrivateKey()
    private let upstream = "https://api.swiftgram.app"
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var policySuite = ""
    private var policyNow: Int64 = 0

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        let unique = UUID().uuidString
        self.policyNow = Int64(Date().timeIntervalSince1970)
        self.storeSuite = "SGEntitlementOriginPolicyCacheTests.store.\(unique)"
        self.schedulerSuite = "SGEntitlementOriginPolicyCacheTests.scheduler.\(unique)"
        self.policySuite = "SGEntitlementOriginPolicyCacheTests.policy.\(unique)"
    }

    override func tearDown() {
        for suite in [self.storeSuite, self.schedulerSuite, self.policySuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    private var policyDefaults: UserDefaults {
        return UserDefaults(suiteName: self.policySuite)!
    }

    private func scope(_ raw: String) -> SGEntitlementStoreScope {
        guard let origin = SGEntitlementBackendOrigin(apiUrl: raw, upstreamDefaultApiUrl: self.upstream) else {
            XCTFail("premise: \(raw) is a valid origin")
            return .unconfigured
        }
        return .origin(origin)
    }

    private var org: SGEntitlementStoreScope {
        return self.scope("https://api.zenlygram.org")
    }

    private var orgKey: String {
        return "zg.ent.policy.v1@api.zenlygram.org"
    }

    /// The `.com`-era bare key and another origin's own key.
    private var foreignKeys: [String] {
        return [SGEntitlementPolicyStore.defaultsKey, "zg.ent.policy.v1@api.zenlygram.com"]
    }

    private func policy(_ mode: String, revision: Int64) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: self.policyNow)
    }

    /// One launch of an authenticated build (no explicit public policy) for `scope`.
    private func makeEntitlement(_ scope: SGEntitlementStoreScope) -> SGEntitlement {
        let fixed = Date(timeIntervalSince1970: TimeInterval(self.policyNow))
        let store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: self.storeSuite),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            ),
            scope: scope
        )
        let entitlement = SGEntitlement(
            store: store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: self.policyDefaults),
            policyClock: { fixed },
            isAuthenticatedEntitlementConfigured: true
        )
        entitlement.overridePinnedKeys(SGEntitlementTestToken.pinned(self.key, kid: self.kid))
        return entitlement
    }

    func test_aNewOriginNeitherReadsNorIsOutrankedByAnotherOriginsCachedPolicy() async {
        let legacyPaid = self.policy("paid", revision: 9)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: legacyPaid, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: self.kid)).mode, .paid, "premise: the old bytes verify under the same ring")
        for key in self.foreignKeys {
            self.policyDefaults.set(legacyPaid, forKey: key)
        }

        let entitlement = self.makeEntitlement(self.org)
        XCTAssertNil(entitlement.signedMonetizationPolicy, "another origin's cached policy was read")
        XCTAssertEqual(entitlement.monetizationMode, .free, "another origin's PAID decided the mode")

        let free0 = self.policy("free", revision: 0)
        let result = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(free0) }), uptime: 1_000)
        XCTAssertEqual(result, .adopted, "the new origin's first policy was ranked against another origin's revision")
        XCTAssertEqual(entitlement.monetizationMode, .free)
        XCTAssertEqual(self.policyDefaults.string(forKey: self.orgKey), free0, "persisted under the origin's own key")
        for key in self.foreignKeys {
            XCTAssertEqual(self.policyDefaults.string(forKey: key), legacyPaid, "\(key) changed")
        }
    }

    func test_theOriginsOwnPolicySurvivesARelaunchAndStaysItsOwn() async {
        let first = self.makeEntitlement(self.org)
        let paid = self.policy("paid", revision: 1)
        let adopted = await first.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(paid) }), uptime: 1_000)
        XCTAssertEqual(adopted, .adopted)

        XCTAssertEqual(self.makeEntitlement(self.org).monetizationMode, .paid, "the origin's own cache was not restored")
        XCTAssertEqual(self.makeEntitlement(self.scope("https://api.zenlygram.org:8443")).monetizationMode, .free, "another origin restored this origin's policy")
        XCTAssertEqual(self.makeEntitlement(.unconfigured).monetizationMode, .free, "the unconfigured scope restored an origin's policy")
        XCTAssertNil(self.policyDefaults.string(forKey: SGEntitlementPolicyStore.defaultsKey), "the bare legacy key was written")
    }
}
