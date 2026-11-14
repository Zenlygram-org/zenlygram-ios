import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — proof that this client and the real server agree.
///
/// Every other test in this module signs with a key the test itself generated, so all of them
/// would pass just as happily if our ES256 encoding, our base64url padding or our claim names
/// disagreed with the server's. This one does not: the token below was minted by the deployed
/// zenlypay server (2026-09-23) and the key is the PUBLIC half of its active signing key.
///
/// Both are safe to commit. The public key is meant to be published — the app is GPL, so a shared
/// secret would be a published secret, which is exactly why the entitlement is signed and not
/// MAC'd. The account and device the token names were deleted right after the fixture was taken.
///
/// If the server ever changes how it signs or names a claim, this test fails and the next release
/// does not ship a client that silently rejects every real token.
final class SGEntitlementServerInteropTests: XCTestCase {
    /// `signing_keys.public_key` for kid `k2026a`, as the server prints it.
    private let serverPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaEXLVGbgr1nvSprYzys1YeaC3Zv0
    RceCityCCsZqJ0pkHwcPsgHZj1XoSYq7Bkr6/uvJKf1D8OaRjMtCdGWwdA==
    -----END PUBLIC KEY-----
    """

    /// The same key as bare base64 SPKI DER — the form `sg_config.entitlement_keys` actually
    /// ships, because a PEM's newline escape does not survive the build system's config
    /// rendering (see appstore/SECRETS.md).
    private let serverPublicKeyBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaEXLVGbgr1nvSprYzys1YeaC3Zv0RceCityCCsZqJ0pkHwcPsgHZj1XoSYq7Bkr6/uvJKf1D8OaRjMtCdGWwdA=="

    private let serverMintedJWS = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImsyMDI2YSJ9.eyJpc3MiOiJ6ZW5seWdyYW0iLCJzdWIiOiIwMW0zODBhM2R4M2JxMWZleDU4Nnc5MzBzZCIsInRnaWQiOjEyMzQ1Njc4OSwiZGV2IjoiMDFtMzgwYTNmYWhlMmt0cGQ3czNlcnFiOHkiLCJ0aWVyIjoicHJvIiwiZW50IjpbInZhdWx0IiwiY2hhdGxvY2siLCJ0YXNrcyIsImVkaXRoaXN0b3J5Il0sInVudGlsIjoiMjAzNi0wOS0yMFQyMDo0NjoyN1oiLCJncmFjZV9kYXlzIjoxNCwiaWF0IjoxNzkwMTk2Mzg3LCJleHAiOjE3OTA0NTU1ODcsImp0aSI6ImVkMDczNTIxLTVkZmYtNDI4Ni1iMDMxLTY1ZTIwMzc1YTJlOSIsInZlciI6MX0.kylVNlQnBeYIRSO6T0udUKfk99-Ddxib8pBTktTfnCd9kl6QrKhjvi5K6swlwcYQVuW27FigpofPg3ixmHYH1w"

    private let boundDeviceId = "01m380a3fahe2ktpd7s3erqb8y"

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    func test_aTokenMintedByTheRealServerVerifies() {
        let keys = SGEntitlementPinnedKeys(keysByKid: ["k2026a": self.serverPublicKeyPEM])
        let result = SGEntitlementTokenVerifier.verify(
            self.serverMintedJWS,
            pinnedKeys: keys,
            boundDeviceId: self.boundDeviceId
        )

        guard case let .success(claims) = result else {
            XCTFail("the server's own token did not verify: \(result)")
            return
        }

        XCTAssertEqual(claims.iss, "zenlygram")
        XCTAssertEqual(claims.dev, self.boundDeviceId)
        XCTAssertEqual(claims.sub, "01m380a3dx3bq1fex586w930sd")
        XCTAssertEqual(claims.tgid, 123_456_789)
        XCTAssertEqual(Set(claims.ent), ["vault", "chatlock", "tasks", "edithistory"])
        XCTAssertEqual(claims.graceDays, 14)
    }

    /// The PEM and the bare-base64 forms must be interchangeable, because the docs hand out the
    /// PEM and the build config ships the base64.
    func test_theShippedBase64FormIsTheSameKey() {
        let fromPEM = SGEntitlementCrypto.p256X963(fromPinnedKey: self.serverPublicKeyPEM)
        let fromBase64 = SGEntitlementCrypto.p256X963(fromPinnedKey: self.serverPublicKeyBase64)

        XCTAssertNotNil(fromPEM)
        XCTAssertEqual(fromPEM, fromBase64)

        let keys = SGEntitlementPinnedKeys(keysByKid: ["k2026a": self.serverPublicKeyBase64])
        guard case .success = SGEntitlementTokenVerifier.verify(self.serverMintedJWS, pinnedKeys: keys, boundDeviceId: nil) else {
            XCTFail("the base64 SPKI form did not verify a real token")
            return
        }
    }

    /// The kid in a real token must be one we pin, and an unpinned kid must not be waved through.
    func test_anUnknownKidOnARealTokenIsRejected() {
        let keys = SGEntitlementPinnedKeys(keysByKid: ["k2027z": self.serverPublicKeyBase64])
        let result = SGEntitlementTokenVerifier.verify(self.serverMintedJWS, pinnedKeys: keys, boundDeviceId: nil)

        XCTAssertEqual(result.failureValue, .unknownKid("k2026a"))
    }

    /// A real token bound to another device is not ours, whatever it says.
    func test_aRealTokenForAnotherDeviceIsRejected() {
        let keys = SGEntitlementPinnedKeys(keysByKid: ["k2026a": self.serverPublicKeyBase64])
        let result = SGEntitlementTokenVerifier.verify(self.serverMintedJWS, pinnedKeys: keys, boundDeviceId: "some-other-device")

        XCTAssertNotNil(result.failureValue)
    }
}
