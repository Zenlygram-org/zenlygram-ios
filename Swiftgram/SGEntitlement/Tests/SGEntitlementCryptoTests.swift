import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementCryptoTests: XCTestCase {
    func test_base64urlDecodesUnpaddedInput() {
        XCTAssertEqual(SGEntitlementCrypto.base64urlDecode("YQ"), Data("a".utf8))
        XCTAssertEqual(SGEntitlementCrypto.base64urlDecode("YWI"), Data("ab".utf8))
        XCTAssertEqual(SGEntitlementCrypto.base64urlDecode("YWJj"), Data("abc".utf8))
        XCTAssertNil(SGEntitlementCrypto.base64urlDecode("Y"), "a length that cannot be padded is not base64")
    }

    func test_base64urlRoundTripsAndUsesTheJOSEAlphabet() {
        let data = Data((0 ..< 64).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let encoded = SGEntitlementCrypto.base64urlEncode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(SGEntitlementCrypto.base64urlDecode(encoded), data)
    }

    func test_spkiRoundTripsForAP256Key() {
        // `device_pubkey` must be the SPKI DER: the raw x9.63 point is rejected with 422.
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        guard let der = SGEntitlementCrypto.p256SPKI(fromX963: point) else {
            XCTFail("SPKI wrapping failed")
            return
        }
        XCTAssertEqual(der.count, 91)
        XCTAssertEqual(SGEntitlementCrypto.p256X963(fromSPKI: der), point)
        XCTAssertEqual(SGEntitlementCrypto.p256X963(fromPinnedKey: der.base64EncodedString()), point)
    }

    func test_pinnedKeysAcceptPEM() {
        let key = P256.Signing.PrivateKey()
        let der = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation)!
        let pem = "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----"
        XCTAssertEqual(SGEntitlementCrypto.p256X963(fromPinnedKey: pem), key.publicKey.x963Representation)
    }

    func test_garbagePinnedKeysDoNotParse() {
        XCTAssertNil(SGEntitlementCrypto.p256X963(fromPinnedKey: ""))
        XCTAssertNil(SGEntitlementCrypto.p256X963(fromPinnedKey: "not base64 at all !!!"))
        XCTAssertNil(SGEntitlementCrypto.p256X963(fromSPKI: Data(repeating: 0, count: 91)))
    }

    func test_hexIsLowercaseAndFixedWidth() {
        XCTAssertEqual(SGEntitlementCrypto.hexString(Data([0x00, 0x0f, 0xff])), "000fff")
        XCTAssertEqual(SGEntitlementCrypto.randomBytes(32)?.count, 32)
    }
}
