import XCTest
import CryptoKit
import SGConfig
@testable import SGEntitlement

/// Zenlygram — `sg_config`'s explicit public policy as the build reads it: `publicPolicyRequested`
/// records that EITHER key was named — with a valid value, `null` or a wrong type — before any typed
/// decode, and `SGEntitlementPublicPolicyConfiguration.resolve` yields a configuration only for a
/// whole, valid pair. A request that does not resolve is what fails closed in `SGEntitlement`.
final class SGEntitlementPublicPolicyConfigTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()

    private var spki: String {
        return SGEntitlementTestToken.pinned(self.key, kid: "k2026a").keysByKid["k2026a"] ?? ""
    }

    /// The same decoder `parseSGConfig` uses.
    private func decode(_ json: String) -> SGConfig? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SGConfig.self, from: Data(json.utf8))
    }

    private func object(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private var validURL: String {
        return "https://zenlygram.org/v1/monetization"
    }

    func test_aValidPairIsRequestedAndResolves() {
        let config = self.decode(self.object(["public_policy_url": self.validURL, "public_policy_keys": ["k2026a": self.spki], "privacy_policy_url": "https://zenlygram.org/privacy-policy.html"]))
        XCTAssertEqual(config?.publicPolicyRequested, true)
        XCTAssertEqual(config?.publicPolicyUrl, self.validURL)
        XCTAssertEqual(config?.privacyPolicyUrl, "https://zenlygram.org/privacy-policy.html", "the other fields still decode")
        XCTAssertEqual(config?.apiUrl, SGConfig.defaultApiUrl, "no authenticated input is implied")
        XCTAssertTrue(config?.entitlementKeys == nil)
        let resolved = config.flatMap { SGEntitlementPublicPolicyConfiguration.resolve($0) }
        XCTAssertEqual(resolved?.origin, "https://zenlygram.org")
        XCTAssertEqual(resolved?.pinnedKeys.keysByKid, ["k2026a": self.spki])
    }

    func test_neitherKeyIsNoRequest() {
        let config = self.decode(self.object(["privacy_policy_url": "https://zenlygram.org/privacy-policy.html"]))
        XCTAssertEqual(config?.publicPolicyRequested, false, "a build that never named the public policy keeps the legacy path")
        XCTAssertNil(config.flatMap { SGEntitlementPublicPolicyConfiguration.resolve($0) })
    }

    func test_nullWrongTypeMissingOrInvalidValuesAreRequestedButDoNotResolve() {
        let cases: [(String, String)] = [
            ("url null", "{\"public_policy_url\":null,\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\"}}"),
            ("keys null", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":null}"),
            ("url wrong type", "{\"public_policy_url\":42,\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\"}}"),
            ("keys wrong type", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":\"\(self.spki)\"}"),
            ("keys a list", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":[\"\(self.spki)\"]}"),
            ("keys missing", "{\"public_policy_url\":\"\(self.validURL)\"}"),
            ("url missing", "{\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\"}}"),
            ("keys empty", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":{}}"),
            ("key invalid", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":{\"k2026a\":\"bm90LWEta2V5\"}}"),
            ("one of two keys invalid", "{\"public_policy_url\":\"\(self.validURL)\",\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\",\"k2026b\":\"bm90LWEta2V5\"}}"),
            ("url not https", "{\"public_policy_url\":\"http://zenlygram.org/v1/monetization\",\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\"}}"),
            ("url another path", "{\"public_policy_url\":\"https://zenlygram.org/v1\",\"public_policy_keys\":{\"k2026a\":\"\(self.spki)\"}}")
        ]
        for (name, json) in cases {
            guard let config = self.decode(json) else {
                XCTFail("\(name): one bad field must not drop the whole config")
                continue
            }
            XCTAssertTrue(config.publicPolicyRequested, "\(name): naming the key is the request")
            XCTAssertNil(SGEntitlementPublicPolicyConfiguration.resolve(config), "\(name): never a configuration")
        }
    }
}
