import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementTokenVerifierTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    func test_verify_acceptsAWellFormedToken() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: "01JB8R")
        guard case let .success(claims) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertEqual(claims.iss, "zenlygram")
        XCTAssertEqual(claims.dev, "01JB8R")
        XCTAssertEqual(Set(claims.ent), ["vault", "chatlock", "tasks", "edithistory"])
        XCTAssertEqual(claims.graceDays, 14)
    }

    func test_verify_rejectsATamperedPayload() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        var parts = jws.split(separator: ".").map(String.init)
        let forged = try! JSONSerialization.data(withJSONObject: SGEntitlementTestToken.claims(ent: ["*"]), options: [.sortedKeys])
        parts[1] = SGEntitlementTestToken.base64url(forged)
        let result = SGEntitlementTokenVerifier.verify(parts.joined(separator: "."), pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .badSignature)
    }

    func test_verify_rejectsAnotherKeysSignature() {
        let jws = SGEntitlementTestToken.make(key: P256.Signing.PrivateKey(), payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .badSignature)
    }

    func test_verify_reportsAnUnknownKidSeparately() {
        // Not a forgery signal: an old build meeting a rotated key. The caller keeps the last token
        // that DID verify rather than discarding it.
        let jws = SGEntitlementTestToken.make(key: self.key, kid: "k2027b", payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .unknownKid("k2027b"))
    }

    func test_verify_rejectsAlgNone() {
        let jws = SGEntitlementTestToken.make(key: self.key, alg: "none", payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .malformed)
    }

    func test_verify_rejectsAForeignIssuer() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims(iss: "somebody-else"))
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .wrongIssuer)
    }

    func test_verify_rejectsATokenMintedForAnotherBinding() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims(dev: "someone-elses-device"))
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: "01JB8R")
        XCTAssertEqual(result.failureValue, .foreignDevice)
    }

    func test_verify_rejectsAMalformedCompactForm() {
        let pinned = SGEntitlementTestToken.pinned(self.key, kid: "k2026a")
        XCTAssertEqual(SGEntitlementTokenVerifier.verify("a.b", pinnedKeys: pinned, boundDeviceId: nil).failureValue, .malformed)
        XCTAssertEqual(SGEntitlementTokenVerifier.verify("a.b.c.d", pinnedKeys: pinned, boundDeviceId: nil).failureValue, .malformed)
        XCTAssertEqual(SGEntitlementTokenVerifier.verify("", pinnedKeys: pinned, boundDeviceId: nil).failureValue, .malformed)
    }

    func test_verify_rejectsAnotherProAccountOnTheSameDevice() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: "01JB8R", boundAccountId: "another-account")
        XCTAssertEqual(result.failureValue, .foreignAccount)
    }

    func test_verify_rejectsAnotherTelegramAccountOnTheSameDevice() {
        var payload = SGEntitlementTestToken.claims()
        payload["tgid"] = 123_456_789
        let jws = SGEntitlementTestToken.make(key: self.key, payload: payload)
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: "01JB8R", accountPeerId: 987_654_321)
        XCTAssertEqual(result.failureValue, .foreignAccount)
    }

    func test_verify_preservesAppleOnlyTokensWithoutATelegramClaim() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: "01JB8R", boundAccountId: "01JB8Q", accountPeerId: 123_456_789)
        XCTAssertNil(result.failureValue)
    }

    func test_verify_toleratesAnUnknownVersionAndAMissingTgid() {
        var payload = SGEntitlementTestToken.claims()
        payload["ver"] = 7
        payload.removeValue(forKey: "tgid")
        let jws = SGEntitlementTestToken.make(key: self.key, payload: payload)
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        guard case let .success(claims) = result else {
            XCTFail("an unknown ver must still be honoured with the claims we understand")
            return
        }
        XCTAssertNil(claims.tgid)
        XCTAssertEqual(claims.ver, 7)
    }

    func test_verify_acceptsANullUntilAndAnEmptyCapabilityList() {
        let jws = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims(ent: [], until: nil))
        let result = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: SGEntitlementTestToken.pinned(self.key, kid: "k2026a"), boundDeviceId: nil)
        guard case let .success(claims) = result else {
            XCTFail("a lapsed token is authentic, it simply grants nothing")
            return
        }
        XCTAssertNil(claims.until)
        XCTAssertTrue(claims.ent.isEmpty)
    }

    func test_pinnedKeys_fallBackToTheSingleKeySlotOnlyWhileTheMapIsEmpty() {
        let onlyFallback = SGEntitlementPinnedKeys(keysByKid: [:], fallbackKey: "pem")
        XCTAssertEqual(onlyFallback.value(forKid: "anything"), "pem")
        let withMap = SGEntitlementPinnedKeys(keysByKid: ["k2026a": "a"], fallbackKey: "pem")
        XCTAssertEqual(withMap.value(forKid: "k2026a"), "a")
        XCTAssertNil(withMap.value(forKid: "k2027b"))
    }
}

extension Result where Failure == SGEntitlementTokenFailure {
    var failureValue: SGEntitlementTokenFailure? {
        if case let .failure(value) = self {
            return value
        }
        return nil
    }
}
