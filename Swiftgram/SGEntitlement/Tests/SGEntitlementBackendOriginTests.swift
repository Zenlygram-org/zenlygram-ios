import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — the authenticated backend origin a build ships, and the two decisions derived from it:
///
/// - `SGEntitlementBackendOrigin(apiUrl:upstreamDefaultApiUrl:)` is the exact validation
///   `SGEntitlementClient.Configuration.shipped` runs on `sg_config.api_url`: canonical root
///   `https://host[:port]` (trailing slashes only), `/v1` appended, and every unsafe form refused;
/// - `SGEntitlementStoreScope` namespaces origin-bound storage (`base@authority`), so a new origin's
///   sessions, device identity, outbox, trial facts and mirror never read or touch another origin's
///   or the bare legacy keys;
/// - `SGEntitlementAppleBackendConfiguration` is the single Apple predicate: the explicit build flag
///   AND the authenticated configuration AND a non-empty product list AND not public-policy-only.
///
/// Pure: runs on the host (`Tests/run-backend-origin-tests.sh`) and in the Bazel suite.
final class SGEntitlementBackendOriginTests: XCTestCase {
    private let upstream = "https://api.swiftgram.app"

    private func origin(_ raw: String) -> SGEntitlementBackendOrigin? {
        return SGEntitlementBackendOrigin(apiUrl: raw, upstreamDefaultApiUrl: self.upstream)
    }

    /// The formula `SGEntitlement.appleTrustDomain` has always applied to the shipped base URL.
    private func legacyAppleTrustDomain(_ baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased() else {
            return nil
        }
        if let port = baseURL.port {
            return "\(host):\(port)"
        }
        return host
    }

    // MARK: - Accepted: the canonical root only

    func test_aCanonicalRootBecomesTheV1BaseURLAndItsAuthority() throws {
        let value = try XCTUnwrap(self.origin("https://api.zenlygram.org"))
        XCTAssertEqual(value.authority, "api.zenlygram.org")
        XCTAssertEqual(value.baseURL.absoluteString, "https://api.zenlygram.org/v1")
    }

    func test_trailingSlashesAndLetterCaseNormalize() throws {
        for raw in ["https://api.zenlygram.org/", "https://api.zenlygram.org///", "HTTPS://API.Zenlygram.ORG", "https://API.ZENLYGRAM.ORG/"] {
            let value = try XCTUnwrap(self.origin(raw), raw)
            XCTAssertEqual(value.authority, "api.zenlygram.org", raw)
            XCTAssertEqual(value.baseURL.absoluteString, "https://api.zenlygram.org/v1", raw)
        }
    }

    func test_anExplicitPortIsPartOfTheAuthorityExactlyAsWritten() throws {
        let custom = try XCTUnwrap(self.origin("https://api.zenlygram.org:8443"))
        XCTAssertEqual(custom.authority, "api.zenlygram.org:8443")
        XCTAssertEqual(custom.baseURL.absoluteString, "https://api.zenlygram.org:8443/v1")
        // Not rewritten: the Apple provenance domain has always kept an explicit port.
        let explicitDefault = try XCTUnwrap(self.origin("https://api.zenlygram.org:443"))
        XCTAssertEqual(explicitDefault.authority, "api.zenlygram.org:443")
        XCTAssertNotEqual(explicitDefault, try XCTUnwrap(self.origin("https://api.zenlygram.org")), "a different authority string is a different namespace, never silently merged")
    }

    func test_anIPv4HostIsAccepted() throws {
        let value = try XCTUnwrap(self.origin("https://192.168.10.5:8443"))
        XCTAssertEqual(value.authority, "192.168.10.5:8443")
    }

    func test_theAuthorityIsByteIdenticalToTheExistingAppleTrustDomain() throws {
        // No ledger migration: for every config that stays valid, the provenance domain derived from
        // the base URL is unchanged and equals the storage authority.
        for raw in ["https://api.zenlygram.org", "https://API.zenlygram.org/", "https://api.zenlygram.org:8443", "https://api.zenlygram.org:443", "https://10.0.0.1:9000"] {
            let value = try XCTUnwrap(self.origin(raw), raw)
            XCTAssertEqual(self.legacyAppleTrustDomain(value.baseURL), value.authority, raw)
        }
    }

    // MARK: - Refused: anything that is not the canonical HTTPS root

    func test_unsafeOrNonCanonicalEndpointsAreRefused() {
        let refused: [(String, String)] = [
            ("", "empty"),
            ("api.zenlygram.org", "no scheme"),
            ("http://api.zenlygram.org", "not HTTPS"),
            ("wss://api.zenlygram.org", "not HTTPS"),
            ("ftp://api.zenlygram.org", "not HTTPS"),
            ("https://", "no host"),
            ("https:///v1", "no host"),
            ("https://user@api.zenlygram.org", "userinfo"),
            ("https://user:secret@api.zenlygram.org", "userinfo with password"),
            ("https://:secret@api.zenlygram.org", "password only"),
            ("https://api.zenlygram.org?x=1", "query"),
            ("https://api.zenlygram.org/?", "empty query"),
            ("https://api.zenlygram.org#fragment", "fragment"),
            ("https://api.zenlygram.org/#", "empty fragment"),
            ("https://api.zenlygram.org/v1", "a path: the backend root is canonical, /v1 is appended"),
            ("https://api.zenlygram.org/api", "an alternate path"),
            ("https://api.zenlygram.org/%2e%2e", "an encoded path"),
            ("https://api.zenlygram.org:0", "port zero"),
            ("https://api.zenlygram.org:65536", "port out of range"),
            ("https://api.zenlygram.org:", "empty port"),
            ("https://api.zenlygram.org:abc", "non-numeric port"),
            ("https://api.zenlygram.org:0443", "non-canonical port digits"),
            ("https://api.zenlygram.org:+443", "signed port"),
            ("https://api.zenlygram.org.", "trailing dot"),
            ("https://.api.zenlygram.org", "empty label"),
            ("https://api..zenlygram.org", "empty label"),
            ("https://-api.zenlygram.org", "label starting with a hyphen"),
            ("https://api_zenlygram.org", "underscore"),
            ("https://[::1]", "IPv6 literal"),
            ("https://[::1]:8443", "IPv6 literal with port"),
            ("https://api.zenlygram.org\\v1", "backslash"),
            (" https://api.zenlygram.org", "leading whitespace"),
            ("https://api.zenlygram.org ", "trailing whitespace"),
            ("https://api.zen lygram.org", "inner whitespace"),
            ("https://api.zenlygram.org%2F", "percent-encoded host"),
            ("https://api.swiftgram.app", "the upstream default"),
            ("https://API.SWIFTGRAM.APP/", "the upstream default in another case"),
            ("https://api.swiftgram.app:443", "the upstream default with an explicit port")
        ]
        for (raw, reason) in refused {
            XCTAssertNil(self.origin(raw), "\(reason): \(raw)")
        }
    }

    // MARK: - Numeric hosts: one canonical spelling only

    /// A host whose last label is all digits is an IPv4 literal to the resolver (`inet_aton`), which
    /// also reads shorthand, decimal, octal, hex and out-of-range forms — so one server could sit under
    /// several authorities (and several storage scopes). Only the canonical dotted quad is accepted.
    func test_aNumericHostMustBeACanonicalDottedQuad() {
        let refused: [(String, String)] = [
            ("https://127.1", "shorthand"),
            ("https://10.1.2", "three parts"),
            ("https://2130706433", "a single decimal number"),
            ("https://0x7f.0.0.1", "a hex octet"),
            ("https://0x7f000001", "a hex number"),
            ("https://0177.0.0.1", "an octal octet"),
            ("https://010.0.0.1", "a leading zero"),
            ("https://999.1.1.1", "an octet out of range"),
            ("https://256.0.0.1", "an octet out of range"),
            ("https://1.2.3.4.5", "five parts"),
            ("https://api.zenlygram.123", "an all-numeric top-level label"),
            ("https://1.2.3.4:0443", "a canonical address with a non-canonical port")
        ]
        for (raw, reason) in refused {
            XCTAssertNil(self.origin(raw), "\(reason): \(raw)")
        }
    }

    func test_canonicalAddressesAndDigitLeadingNamesStayAccepted() throws {
        for raw in ["https://1.2.3.4", "https://8.8.8.8:8443", "https://192.168.10.5", "https://255.255.255.255", "https://0.0.0.0"] {
            XCTAssertNotNil(self.origin(raw), raw)
        }
        // Digits or `0x` inside a DNS name are ordinary labels when the last label is not numeric.
        XCTAssertEqual(try XCTUnwrap(self.origin("https://0x7f.zenlygram.org")).authority, "0x7f.zenlygram.org")
        XCTAssertEqual(try XCTUnwrap(self.origin("https://1.2.3.zenlygram.org")).authority, "1.2.3.zenlygram.org")
        XCTAssertEqual(try XCTUnwrap(self.origin("https://123api.zenlygram.org")).authority, "123api.zenlygram.org")
    }

    // MARK: - Store scope

    func test_anOriginScopeSuffixesTheBaseKeyWithItsAuthority() throws {
        let scope = SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("https://api.zenlygram.org")))
        XCTAssertEqual(scope.identifier, "api.zenlygram.org")
        XCTAssertEqual(scope.scopedKey("session.v1.42"), "session.v1.42@api.zenlygram.org")
        XCTAssertEqual(scope.scopedKey("zg.iap.trial.v1"), "zg.iap.trial.v1@api.zenlygram.org")
        XCTAssertEqual(scope.scopedKey("zg.ent.mirror.v1"), "zg.ent.mirror.v1@api.zenlygram.org")
    }

    func test_theUnconfiguredScopeCanNeverCollideWithAnOrigin() throws {
        XCTAssertEqual(SGEntitlementStoreScope.unconfigured.scopedKey("device.id.v1"), "device.id.v1@!unconfigured")
        // A single-label host literally named "unconfigured" is a real origin, not the absent one.
        let named = SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("https://unconfigured")))
        XCTAssertNotEqual(named.identifier, SGEntitlementStoreScope.unconfigured.identifier)
        XCTAssertNotEqual(named.scopedKey("x"), SGEntitlementStoreScope.unconfigured.scopedKey("x"))
        XCTAssertNotEqual(named, .unconfigured)
    }

    func test_scopedKeysNeverEqualTheBareLegacyKey() throws {
        let scopes: [SGEntitlementStoreScope] = [
            .unconfigured,
            .origin(try XCTUnwrap(self.origin("https://api.zenlygram.org"))),
            .origin(try XCTUnwrap(self.origin("https://api.zenlygram.com")))
        ]
        for base in ["session.v1.42", "device.id.v1", "device.enclave.v1", "device.softkey.v1", "apple.outbox.v1", "zg.iap.trial.v1", "zg.ent.mirror.v1"] {
            let keys = scopes.map { $0.scopedKey(base) }
            XCTAssertFalse(keys.contains(base), base)
            XCTAssertEqual(Set(keys).count, keys.count, "two scopes shared a key for \(base)")
        }
    }

    func test_originsThatDifferOnlyByPortAreSeparateScopes() throws {
        let a = SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("https://api.zenlygram.org")))
        let b = SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("https://api.zenlygram.org:8443")))
        XCTAssertNotEqual(a.scopedKey("apple.outbox.v1"), b.scopedKey("apple.outbox.v1"))
        XCTAssertNotEqual(a.storageToken, b.storageToken)
    }

    func test_theStorageTokenIsAnOpaqueStableDigestOfTheIdentifier() throws {
        let scope = SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("https://api.zenlygram.org")))
        let token = scope.storageToken
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) }, token)
        XCTAssertFalse(token.contains("zenlygram"), "a directory name must not reveal or be parsed as the origin")
        let expected = SHA256.hash(data: Data("api.zenlygram.org".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(token, expected)
        XCTAssertEqual(token, SGEntitlementStoreScope.origin(try XCTUnwrap(self.origin("HTTPS://API.ZENLYGRAM.ORG/"))).storageToken, "stable across spellings of the same authority")
        XCTAssertNotEqual(token, SGEntitlementStoreScope.unconfigured.storageToken)
    }

    // MARK: - The single Apple predicate

    private let products = ["org.zenlygram.pro.month", "org.zenlygram.pro.year"]

    func test_appleWorkRunsOnlyWithTheExplicitFlagAuthenticationAndProducts() {
        let enabled = SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: self.products)
        XCTAssertTrue(enabled.isEnabled(isAuthenticatedEntitlementConfigured: true, isPublicPolicyOnly: false))
        XCTAssertFalse(enabled.isEnabled(isAuthenticatedEntitlementConfigured: false, isPublicPolicyOnly: false), "no authenticated config")
        XCTAssertFalse(enabled.isEnabled(isAuthenticatedEntitlementConfigured: true, isPublicPolicyOnly: true), "public-policy-only")
        XCTAssertFalse(enabled.isEnabled(isAuthenticatedEntitlementConfigured: false, isPublicPolicyOnly: true))
    }

    func test_authenticationAndAPreexistingProductListAreNotActivationAuthority() {
        let unflagged = SGEntitlementAppleBackendConfiguration(isFlagEnabled: false, productIds: self.products)
        XCTAssertFalse(unflagged.isEnabled(isAuthenticatedEntitlementConfigured: true, isPublicPolicyOnly: false), "an existing SKU list plus auth must stay held without the explicit flag")
    }

    func test_anEmptyOrDamagedProductListHoldsEvenWithTheFlag() {
        for ids in [[], [""], ["org.zenlygram.pro.month", ""]] {
            let value = SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: ids)
            XCTAssertFalse(value.isEnabled(isAuthenticatedEntitlementConfigured: true, isPublicPolicyOnly: false), "\(ids)")
        }
    }

    func test_heldIsHeldUnderEveryInput() {
        for authenticated in [false, true] {
            for publicOnly in [false, true] {
                XCTAssertFalse(SGEntitlementAppleBackendConfiguration.held.isEnabled(isAuthenticatedEntitlementConfigured: authenticated, isPublicPolicyOnly: publicOnly))
            }
        }
        XCTAssertFalse(SGEntitlementAppleBackendConfiguration.held.isFlagEnabled)
        XCTAssertTrue(SGEntitlementAppleBackendConfiguration.held.productIds.isEmpty)
    }
}
