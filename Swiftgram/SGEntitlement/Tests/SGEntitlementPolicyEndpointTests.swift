import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — `SGEntitlementPolicyEndpoint`, the credential-free policy GET, against a scripted
/// origin (`SGPolicyStubProtocol`): an anonymous request (no credential, no device header, no
/// cookie), the body bound and the redirect refusal of the transport, failures that are never a
/// policy — and the explicit public configuration: the exact HTTPS endpoint shape, its canonical
/// cache origin, and a key ring that must be whole.
final class SGEntitlementPolicyEndpointTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let host = "policy.zenlygram.test"

    override func setUp() {
        super.setUp()
        SGPolicyStubProtocol.reset(routes: [:])
    }

    override func tearDown() {
        SGPolicyStubProtocol.reset(routes: [:])
        super.tearDown()
    }

    private func endpoint() -> SGEntitlementPolicyEndpoint {
        return SGEntitlementPolicyEndpoint(url: URL(string: "https://\(self.host)/v1/monetization")!, protocolClasses: [SGPolicyStubProtocol.self])!
    }

    private func serve(status: Int = 200, _ body: [String: Any]) {
        SGPolicyStubProtocol.reset(routes: [self.host: SGPolicyStubProtocol.Route(status: status, headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(body)])])
    }

    private func ring(_ key: P256.Signing.PrivateKey, kid: String = "k2026a") -> [String: String] {
        return SGEntitlementTestToken.pinned(key, kid: kid).keysByKid
    }

    // MARK: - The anonymous GET

    func test_thePolicyGETCarriesNoCredentialAndReturnsTheSignedToken() async {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "free", revision: 0)
        self.serve(["policy_token": token, "server_time": "2026-10-24T13:37:40Z"])
        let result = await self.endpoint().fetch()
        XCTAssertEqual(try? result.get(), token)

        let requests = SGPolicyStubProtocol.requests
        XCTAssertEqual(requests.count, 1)
        guard let request = requests.first else {
            return
        }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/v1/monetization")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"), "the policy names no one: no bearer of any kind")
        XCTAssertFalse(names.contains("cookie"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no X-Device-Id / nonce / signature / proof: \(names)")
        // The v2 shape (`trial_days`) is asked for by its exact vendor type; the frozen v1 stays the
        // fallback. Nothing else is negotiated: still no credential, no device header.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.zenlygram.monetization.v2+json, application/json;q=0.9")
    }

    func test_aV2PolicyAnswerIsReturnedUnverifiedLikeAnyOther() async {
        // The endpoint hands back the compact JWS as is; the shape and the signature are the
        // verifier's business, never the transport's.
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 3, version: 2, trialDays: 7)
        self.serve(["policy_token": token, "server_time": "2026-10-24T13:37:40Z"])
        let result = await self.endpoint().fetch()
        XCTAssertEqual(try? result.get(), token)
        XCTAssertEqual(SGEntitlementPolicyEndpoint.monetizationAccept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first, "application/vnd.zenlygram.monetization.v2+json", "the vendor type is listed first and without a q parameter")
        XCTAssertEqual(self.endpoint().accept, SGEntitlementPolicyEndpoint.monetizationAccept, "a monetization endpoint declares the monetization shapes")
    }

    func test_anOversizedPolicyAnswerIsAFailureNotATruncatedToken() async {
        SGPolicyStubProtocol.reset(routes: [self.host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(8, of: 4096))])
        guard case .failure = await self.endpoint().fetch() else {
            return XCTFail("a 32 KiB answer must be refused")
        }
    }

    func test_aRedirectedPolicyRequestIsNotFollowed() async {
        let elsewhere = "elsewhere.zenlygram.test"
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid")
        SGPolicyStubProtocol.reset(routes: [
            self.host: SGPolicyStubProtocol.Route(status: 302, redirectTo: URL(string: "https://\(elsewhere)/v1/monetization")!),
            elsewhere: SGPolicyStubProtocol.Route(chunks: [SGPolicyStubProtocol.json(["policy_token": token])])
        ])
        guard case .failure = await self.endpoint().fetch() else {
            return XCTFail("a policy obtained through a redirect must not be returned")
        }
        XCTAssertEqual(SGPolicyStubProtocol.requests.compactMap { $0.url?.host }, [self.host])
    }

    func test_unavailableRateLimitedAndTokenlessAnswersAreFailures() async {
        for status in [503, 429] {
            self.serve(status: status, ["error": status == 503 ? "monetization_unavailable" : "rate_limited"])
            guard case .failure = await self.endpoint().fetch() else {
                return XCTFail("\(status) is not a policy")
            }
        }
        self.serve(["server_time": "2026-10-24T13:37:40Z"])
        guard case .failure = await self.endpoint().fetch() else {
            return XCTFail("a 200 without policy_token is not a policy")
        }
    }

    // MARK: - The explicit endpoint's shape

    func test_onlyAnExactHTTPSMonetizationEndpointConfigures() {
        let accepted = [
            "https://zenlygram.org/v1/monetization",
            "https://ZenlyGram.ORG/v1/monetization",
            "https://zenlygram.org:8443/v1/monetization"
        ]
        for raw in accepted {
            XCTAssertNotNil(SGEntitlementPolicyEndpoint(url: URL(string: raw)!), raw)
        }
        let refused = [
            "http://zenlygram.org/v1/monetization",
            "https://user:secret@zenlygram.org/v1/monetization",
            "https://user@zenlygram.org/v1/monetization",
            "https://zenlygram.org/v1/monetization?mode=paid",
            "https://zenlygram.org/v1/monetization?",
            "https://zenlygram.org/v1/monetization#fragment",
            "https://zenlygram.org/v1/monetization/",
            "https://zenlygram.org/v1",
            "https://zenlygram.org/v2/monetization",
            "https://zenlygram.org/api/v1/monetization",
            "https:///v1/monetization"
        ]
        for raw in refused {
            guard let url = URL(string: raw) else {
                continue
            }
            XCTAssertNil(SGEntitlementPolicyEndpoint(url: url), raw)
        }
    }

    func test_theCacheOriginIsCanonicalAndKeepsANonDefaultPort() {
        XCTAssertEqual(SGEntitlementPolicyEndpoint(url: URL(string: "https://ZenlyGram.ORG/v1/monetization")!)?.origin, "https://zenlygram.org")
        XCTAssertEqual(SGEntitlementPolicyEndpoint(url: URL(string: "https://zenlygram.org:443/v1/monetization")!)?.origin, "https://zenlygram.org", "the default port is the same origin")
        XCTAssertEqual(SGEntitlementPolicyEndpoint(url: URL(string: "https://zenlygram.org:8443/v1/monetization")!)?.origin, "https://zenlygram.org:8443", "another port is another origin")
        XCTAssertEqual(SGEntitlementPolicyStore.originKey("https://zenlygram.org"), "zg.ent.policy.v1@https://zenlygram.org")
        XCTAssertNotEqual(SGEntitlementPolicyStore.originKey("https://zenlygram.org"), SGEntitlementPolicyStore.defaultsKey)
    }

    func test_theLegacyEndpointIsDerivedExactlyAsBefore() {
        let legacy = SGEntitlementPolicyEndpoint.legacy(baseURL: URL(string: "https://api.zenlygram.test/v1")!, timeout: 5, protocolClasses: nil)
        XCTAssertEqual(legacy.url.absoluteString, "https://api.zenlygram.test/v1/monetization")
        XCTAssertEqual(legacy.timeout, 5)
    }

    // MARK: - The explicit public configuration

    func test_aPublicConfigurationNeedsAWholeRingOfItsOwn() {
        let endpoint = SGEntitlementPolicyEndpoint(url: URL(string: "https://zenlygram.org/v1/monetization")!)!
        let other = P256.Signing.PrivateKey()
        var ring = self.ring(self.key, kid: "k2026a")
        ring.merge(self.ring(other, kid: "k2026b"), uniquingKeysWith: { first, _ in first })

        let configured = SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: ring)
        XCTAssertEqual(configured?.origin, "https://zenlygram.org")
        XCTAssertEqual(configured?.pinnedKeys.keysByKid, ring)
        XCTAssertNil(configured?.pinnedKeys.fallbackKey, "no single-key fallback: an unlisted kid is unknown")
        XCTAssertNil(configured?.pinnedKeys.value(forKid: "k2026c"))

        XCTAssertNil(SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: [:]), "an endpoint without keys is no public policy")
        var damaged = ring
        damaged["k2026c"] = "bm90LWEta2V5"
        XCTAssertNil(SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: damaged), "a ring with an unparseable key is a misconfiguration, never partial trust")
        // A 32-byte Ed25519 key (the inline-query `public_key` shape) is not a P-256 anchor.
        XCTAssertNil(SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: ["k2026a": Data(repeating: 7, count: 32).base64EncodedString()]))
    }
}

/// The app-update policy's endpoint (`GET /v1/app-policy`): derived from the configured public
/// policy's canonical origin (never configured on its own), with an `Accept` of its own, the same
/// anonymous bounded GET, and a legacy derivation beside the monetization one.
final class SGAppUpdatePolicyEndpointTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let host = "policy.zenlygram.test"

    override func setUp() {
        super.setUp()
        SGPolicyStubProtocol.reset(routes: [:])
    }

    override func tearDown() {
        SGPolicyStubProtocol.reset(routes: [:])
        super.tearDown()
    }

    private var publicPolicy: SGEntitlementPublicPolicyConfiguration {
        let endpoint = SGEntitlementPolicyEndpoint(url: URL(string: "https://\(self.host)/v1/monetization")!, timeout: 7, protocolClasses: [SGPolicyStubProtocol.self])!
        return SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: SGEntitlementTestToken.pinned(self.key, kid: "k2026a").keysByKid)!
    }

    private func route(_ body: [String: Any], status: Int = 200) -> SGPolicyStubProtocol.Route {
        return SGPolicyStubProtocol.Route(status: status, headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(body)])
    }

    func test_theAppPolicyEndpointIsDerivedFromTheCanonicalOrigin() {
        let plain = SGEntitlementPolicyEndpoint.appPolicy(origin: "https://zenlygram.org")
        XCTAssertEqual(plain?.url.absoluteString, "https://zenlygram.org/v1/app-policy")
        XCTAssertNil(plain?.url.query, "no query")
        XCTAssertNil(plain?.url.fragment)
        XCTAssertEqual(plain?.origin, "https://zenlygram.org", "the same cache origin as the monetization endpoint")
        XCTAssertEqual(plain?.accept, "application/vnd.zenlygram.app-policy.v1+json, application/json;q=0.9")
        XCTAssertEqual(plain?.timeout, 5)

        let port = SGEntitlementPolicyEndpoint.appPolicy(origin: "https://zenlygram.org:8443", timeout: 9)
        XCTAssertEqual(port?.url.absoluteString, "https://zenlygram.org:8443/v1/app-policy", "a non-default port is kept")
        XCTAssertEqual(port?.origin, "https://zenlygram.org:8443")
        XCTAssertEqual(port?.timeout, 9)

        for refused in ["http://zenlygram.org", "https://zenlygram.org/v1/monetization", "https://zenlygram.org/", "https://ZenlyGram.org", "https://zenlygram.org:443", "https://user@zenlygram.org", "https://zenlygram.org?x=1", "https://zenlygram.org#f", "zenlygram.org", ""] {
            XCTAssertNil(SGEntitlementPolicyEndpoint.appPolicy(origin: refused), "`\(refused)` is not a canonical HTTPS origin")
        }
    }

    func test_thePublicConfigurationDerivesItsAppPolicyEndpointFromTheConfiguredOne() {
        let configured = SGEntitlementPolicyEndpoint(url: URL(string: "https://ZenlyGram.ORG:8443/v1/monetization")!, timeout: 7)!
        let configuration = SGEntitlementPublicPolicyConfiguration(endpoint: configured, keysByKid: SGEntitlementTestToken.pinned(self.key, kid: "k2026a").keysByKid)
        XCTAssertEqual(configuration?.appPolicyEndpoint.url.absoluteString, "https://zenlygram.org:8443/v1/app-policy")
        XCTAssertEqual(configuration?.appPolicyEndpoint.timeout, 7, "the configured timeout")
        XCTAssertEqual(configuration?.appPolicyEndpoint.accept, SGEntitlementPolicyEndpoint.appPolicyAccept)
        XCTAssertEqual(configuration?.endpoint.accept, SGEntitlementPolicyEndpoint.monetizationAccept, "each endpoint declares its own shape")
        XCTAssertEqual(configuration?.appPolicyEndpoint.origin, configuration?.origin)
        // The configured URL itself keeps its /v1/monetization-only rule: /v1/app-policy is never configured.
        XCTAssertNil(SGEntitlementPolicyEndpoint(url: URL(string: "https://zenlygram.org/v1/app-policy")!))
    }

    func test_theLegacyAppPolicyEndpointIsDerivedExactlyLikeTheMonetizationOne() {
        let base = URL(string: "https://api.zenlygram.test/v1")!
        let legacy = SGEntitlementPolicyEndpoint.legacyAppPolicy(baseURL: base, timeout: 5, protocolClasses: nil)
        XCTAssertEqual(legacy.url.absoluteString, "https://api.zenlygram.test/v1/app-policy")
        XCTAssertEqual(legacy.accept, SGEntitlementPolicyEndpoint.appPolicyAccept)
        XCTAssertEqual(SGEntitlementPolicyEndpoint.legacy(baseURL: base, timeout: 5, protocolClasses: nil).url.absoluteString, "https://api.zenlygram.test/v1/monetization")
    }

    func test_theAppPolicyGETDeclaresItsOwnAcceptAndNothingIdentifying() async {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 1, ios: SGEntitlementTestAppUpdatePolicy.platform(min: "12.9.0", latest: "12.10.0"))
        SGPolicyStubProtocol.reset(routes: [self.host: self.route(["policy_token": token, "server_time": "2026-10-24T13:37:40Z"])])
        let result = await self.publicPolicy.appPolicyEndpoint.fetch()
        XCTAssertEqual(try? result.get(), token, "the compact JWS is returned as is, unverified")

        let requests = SGPolicyStubProtocol.requests
        XCTAssertEqual(requests.count, 1)
        guard let request = requests.first else {
            return
        }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, self.host)
        XCTAssertEqual(request.url?.path, "/v1/app-policy")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.zenlygram.app-policy.v1+json, application/json;q=0.9")
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("authorization"), "the policy names no one: no bearer of any kind")
        XCTAssertFalse(names.contains("cookie"))
        XCTAssertTrue(names.filter { $0.hasPrefix("x-") }.isEmpty, "no X-Device-Id / nonce / signature / proof: \(names)")
    }

    func test_theTwoEndpointsOfOneOriginAreTwoRequestsWithTwoAccepts() async {
        let monetization = SGEntitlementTestPolicy.make(key: self.key, mode: "free", revision: 0)
        let appUpdate = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 0)
        SGPolicyStubProtocol.reset(routes: [
            "\(self.host)/v1/monetization": self.route(["policy_token": monetization, "server_time": "2026-10-24T13:37:40Z"]),
            "\(self.host)/v1/app-policy": self.route(["policy_token": appUpdate, "server_time": "2026-10-24T13:37:40Z"])
        ])
        let configuration = self.publicPolicy
        let first = await configuration.endpoint.fetch()
        let second = await configuration.appPolicyEndpoint.fetch()
        XCTAssertEqual(try? first.get(), monetization)
        XCTAssertEqual(try? second.get(), appUpdate)
        let accepts = SGPolicyStubProtocol.requests.map { ($0.url?.path ?? "", $0.value(forHTTPHeaderField: "Accept") ?? "") }
        XCTAssertEqual(accepts.count, 2)
        XCTAssertEqual(accepts.first?.0, "/v1/monetization")
        XCTAssertEqual(accepts.first?.1, SGEntitlementPolicyEndpoint.monetizationAccept)
        XCTAssertEqual(accepts.last?.0, "/v1/app-policy")
        XCTAssertEqual(accepts.last?.1, SGEntitlementPolicyEndpoint.appPolicyAccept)
    }

    func test_unavailableRateLimitedAndOversizedAnswersAreFailuresNotPolicies() async {
        for status in [503, 429] {
            SGPolicyStubProtocol.reset(routes: [self.host: self.route(["error": status == 503 ? "app_policy_unavailable" : "rate_limited"], status: status)])
            guard case .failure = await self.publicPolicy.appPolicyEndpoint.fetch() else {
                return XCTFail("\(status) is not a policy")
            }
        }
        SGPolicyStubProtocol.reset(routes: [self.host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(8, of: 4096))])
        guard case .failure = await self.publicPolicy.appPolicyEndpoint.fetch() else {
            return XCTFail("a 32 KiB answer must be refused: the contract's ceiling is 16384 bytes")
        }
    }
}
