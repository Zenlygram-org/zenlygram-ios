import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementSessionIsolationTests: XCTestCase {
    private let accountPeerId: Int64 = 69_229_542_145
    private let key = P256.Signing.PrivateKey()
    private let current = SGEntitlementSessionMaterial(refreshToken: "current-session", entitlement: "previous-good-token", accountId: "01JB8Q", deviceId: "01JB8R")

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        SGEntitlement.shared.overridePinnedKeys(SGEntitlementTestToken.pinned(self.key, kid: "k2026a"))
        SGEntitlementStore.shared.seedSessionForTesting(accountPeerId: self.accountPeerId, self.current)
    }

    override func tearDown() {
        SGEntitlementStore.shared.clearSession(accountPeerId: self.accountPeerId)
        SGEntitlement.shared.overridePinnedKeys(.shipped)
        super.tearDown()
    }

    func test_responseFromAnEarlierSessionCannotOverwriteTheCurrentToken() {
        let token = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        let accepted = SGEntitlement.shared.adopt(entitlement: token, credential: SGEntitlementSessionCredential(accountPeerId: self.accountPeerId, refreshToken: "old-session"))
        XCTAssertFalse(accepted)
        XCTAssertEqual(SGEntitlementStore.shared.session(accountPeerId: self.accountPeerId), self.current)
    }

    func test_foreignSignedAccountCannotReplaceThePreviousGoodToken() {
        var payload = SGEntitlementTestToken.claims()
        payload["sub"] = "a-different-pro-account"
        let token = SGEntitlementTestToken.make(key: self.key, payload: payload)
        let accepted = SGEntitlement.shared.adopt(entitlement: token, credential: SGEntitlementSessionCredential(accountPeerId: self.accountPeerId, refreshToken: "current-session"))
        XCTAssertFalse(accepted)
        XCTAssertEqual(SGEntitlementStore.shared.session(accountPeerId: self.accountPeerId), self.current)
    }

    func test_foreignSignedTelegramAccountCannotReplaceThePreviousGoodToken() {
        var payload = SGEntitlementTestToken.claims()
        payload["tgid"] = 123_456_789
        let token = SGEntitlementTestToken.make(key: self.key, payload: payload)
        let accepted = SGEntitlement.shared.adopt(entitlement: token, credential: SGEntitlementSessionCredential(accountPeerId: self.accountPeerId, refreshToken: "current-session"))
        XCTAssertFalse(accepted)
        XCTAssertEqual(SGEntitlementStore.shared.session(accountPeerId: self.accountPeerId), self.current)
    }

    func test_lateUnauthorizedResponseCannotDropAReboundSession() {
        let error = SGEntitlementRequestError(failure: .session(.sessionRevoked))
        SGEntitlement.shared.apply(error, credential: SGEntitlementSessionCredential(accountPeerId: self.accountPeerId, refreshToken: "old-session"))
        XCTAssertEqual(SGEntitlementStore.shared.session(accountPeerId: self.accountPeerId), self.current)
    }
}
