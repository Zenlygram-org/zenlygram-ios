import XCTest
import CryptoKit
@testable import SGEntitlement

final class SGEntitlementBindingTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let accountPeerId: Int64 = 123_456_789

    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: "k2026a")
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func confirmation(
        telegramUserId: Int64? = 123_456_789,
        payload: [String: Any]? = nil,
        kid: String = "k2026a"
    ) -> SGEntitlementBindConfirmation {
        var claims = payload ?? SGEntitlementTestToken.claims()
        if payload == nil {
            claims["tgid"] = self.accountPeerId
        }
        return SGEntitlementBindConfirmation(
            refreshToken: "refresh-token",
            entitlement: SGEntitlementTestToken.make(key: self.key, kid: kid, payload: claims),
            account: SGEntitlementBindAccount(id: "01JB8Q", tgUserId: telegramUserId, status: "paid", until: "2030-01-01T00:00:00Z"),
            device: SGEntitlementBindDevice(id: "01JB8R"),
            mergeConflict: nil
        )
    }

    func test_matchingConfirmedAccountAndSignedClaimsAreAccepted() {
        XCTAssertTrue(self.confirmation().belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_modernTelegramUserIdIsDecodedFromThePackedSessionKey() {
        let telegramUserId: Int64 = 9_100_000_001
        // Postbox PeerId(namespace: CloudUser, id: telegramUserId).toInt64().
        let packedPeerId: Int64 = 69_229_542_145
        XCTAssertEqual(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: packedPeerId), telegramUserId)
        var claims = SGEntitlementTestToken.claims()
        claims["tgid"] = telegramUserId
        XCTAssertTrue(self.confirmation(telegramUserId: telegramUserId, payload: claims).belongs(to: packedPeerId, pinnedKeys: self.pinned))
    }

    func test_cloudUserIdentityHandlesUInt32BoundaryAndRejectsOtherNamespaces() {
        XCTAssertEqual(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: 4_294_967_295), 4_294_967_295)
        XCTAssertEqual(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: 34_359_738_368), 4_294_967_296)
        XCTAssertNil(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: (1 << 32) | self.accountPeerId))
        XCTAssertNil(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: 0))
        XCTAssertNil(SGEntitlementAccountIdentity.telegramUserId(accountPeerId: -1))
    }

    func test_confirmingInAnotherTelegramAccountIsRejected() {
        XCTAssertFalse(self.confirmation(telegramUserId: 987_654_321).belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_confirmationMustIdentifyItsTelegramAccount() {
        XCTAssertFalse(self.confirmation(telegramUserId: nil).belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_signedAccountCannotDisagreeWithTheConfirmationEnvelope() {
        var claims = SGEntitlementTestToken.claims()
        claims["sub"] = "a-different-pro-account"
        XCTAssertFalse(self.confirmation(payload: claims).belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_signedTelegramAccountCannotDisagreeWithTheConfirmationEnvelope() {
        var claims = SGEntitlementTestToken.claims()
        claims["tgid"] = 987_654_321
        XCTAssertFalse(self.confirmation(payload: claims).belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_signedDeviceCannotDisagreeWithTheConfirmationEnvelope() {
        XCTAssertFalse(self.confirmation(payload: SGEntitlementTestToken.claims(dev: "another-device")).belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_rotatedUnknownSigningKeyDoesNotPreventTheCorrectAccountRelinking() {
        XCTAssertTrue(self.confirmation(kid: "k2027a").belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
        XCTAssertFalse(self.confirmation(telegramUserId: 987_654_321, kid: "k2027a").belongs(to: self.accountPeerId, pinnedKeys: self.pinned))
    }

    func test_beginningANewerAttemptInvalidatesTheOlderOneOnlyForThatAccount() {
        var attempts = SGEntitlementBindAttempts()
        let first = attempts.begin(accountPeerId: self.accountPeerId)
        let other = attempts.begin(accountPeerId: 987_654_321)
        let replacement = attempts.begin(accountPeerId: self.accountPeerId)
        XCTAssertFalse(attempts.isCurrent(first, accountPeerId: self.accountPeerId))
        XCTAssertTrue(attempts.isCurrent(replacement, accountPeerId: self.accountPeerId))
        XCTAssertTrue(attempts.isCurrent(other, accountPeerId: 987_654_321))
    }

    func test_logoutRejectsAnInflightConfirmationEvenBeforeAnotherBindBegins() {
        var attempts = SGEntitlementBindAttempts()
        let attempt = attempts.begin(accountPeerId: self.accountPeerId)
        attempts.invalidate(accountPeerId: self.accountPeerId)
        XCTAssertFalse(attempts.isCurrent(attempt, accountPeerId: self.accountPeerId))
        let next = attempts.begin(accountPeerId: self.accountPeerId)
        XCTAssertTrue(attempts.isCurrent(next, accountPeerId: self.accountPeerId))
        XCTAssertFalse(attempts.isCurrent(attempt, accountPeerId: self.accountPeerId))
    }

    func test_attemptCannotBeReassignedToAnotherAccountOrDecodedFromTheNetwork() {
        var attempts = SGEntitlementBindAttempts()
        let attempt = attempts.begin(accountPeerId: self.accountPeerId)
        XCTAssertFalse(attempts.isCurrent(attempt, accountPeerId: 987_654_321))
        let data = Data("""
        {"code":"ABCDEFGH","pollToken":"poll","expiresAt":"2030-01-01T00:00:00Z",
         "attempt":{"accountPeerId":123456789,"generation":"\(attempt.generation.uuidString)"}}
        """.utf8)
        let start = try! JSONDecoder().decode(SGEntitlementBindStart.self, from: data)
        XCTAssertNil(start.attempt)
        XCTAssertFalse(attempts.isCurrent(start.attempt, accountPeerId: self.accountPeerId))
    }
}
