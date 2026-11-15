import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — the signed monetization policy (`GET /v1/monetization`, contracts
/// `monetization-policy.v1` / `.v2` / `.v3`): exactly one of the three claim shapes with `ver`
/// naming it, the pinned ES256 ring, the freshness window applied only to newly fetched tokens, the
/// `(revision, iat)` order, and persistence that re-verifies but never re-expires. Every token here
/// is really signed; nothing is mocked.
final class SGEntitlementPolicyVerifierTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let iat: Int64 = 1_790_000_000
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func at(_ unix: Int64) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    private func token(_ claims: [String: Any]) -> String {
        return SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: claims)
    }

    private func authenticate(_ token: String) -> SGEntitlementPolicyFailure? {
        if case let .failure(failure) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) {
            return failure
        }
        return nil
    }

    // MARK: - Authentic v1 policies

    func test_aSignedPaidPolicyAuthenticatesWithItsExactFields() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 7, iat: self.iat)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("a well-formed v1 policy signed by the pinned ring must authenticate")
        }
        XCTAssertEqual(policy.mode, .paid)
        XCTAssertEqual(policy.revision, 7)
        XCTAssertEqual(policy.issuedAt, self.iat)
        XCTAssertEqual(policy.expiresAt, self.iat + 86400)
        XCTAssertEqual(policy.token, token, "the exact signed bytes are what gets persisted and re-verified")
    }

    func test_aSignedFreePolicyAuthenticatesAsFree() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "free", revision: 0, iat: self.iat)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("revision 0 is the server default and must authenticate")
        }
        XCTAssertEqual(policy.mode, .free)
        XCTAssertEqual(policy.revision, 0)
    }

    func test_aV1PolicyIsVersionOneAndOffersNoTrial() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 7, iat: self.iat)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("premise: the frozen v1 shape authenticates")
        }
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.trialDays, 0, "a v1 token cannot say: no trial")
        XCTAssertFalse(policy.offersServerTrial)
    }

    // MARK: - The v2 shape (`trial_days`)

    func test_aPaidV2PolicyCarriesItsSignedTrialDays() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 7, iat: self.iat, version: 2, trialDays: 7)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("a well-formed v2 policy signed by the pinned ring must authenticate")
        }
        XCTAssertEqual(policy.version, 2)
        XCTAssertEqual(policy.trialDays, 7)
        XCTAssertEqual(policy.mode, .paid)
        XCTAssertEqual(policy.revision, 7)
        XCTAssertTrue(policy.offersServerTrial)
        XCTAssertEqual(policy.token, token, "the exact signed bytes are what gets persisted and re-verified")
    }

    func test_aFreeV2PolicyOffersNoTrialWhateverItsDays() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "free", revision: 2, iat: self.iat, version: 2, trialDays: 7)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("a free v2 policy authenticates like any other")
        }
        XCTAssertEqual(policy.version, 2)
        XCTAssertEqual(policy.trialDays, 7, "the signed value is kept as signed")
        XCTAssertFalse(policy.offersServerTrial, "nothing is sold while free, a trial included")
    }

    func test_aPaidV2PolicyWithZeroDaysOffersNoTrial() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 2, iat: self.iat, version: 2, trialDays: 0)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("trial_days 0 is the server's 'no trial offered' and must authenticate")
        }
        XCTAssertEqual(policy.version, 2)
        XCTAssertEqual(policy.trialDays, 0)
        XCTAssertFalse(policy.offersServerTrial)
        XCTAssertEqual(policy.mode, .paid, "a disabled trial does not touch the mode")
    }

    func test_theVersionMustNameTheClaimSetItCameWith() {
        // Seven claims are version 1, eight are version 2, nine are version 3: a mismatch is
        // another purpose, not a policy with an odd field — the same answer as for an entitlement
        // token.
        let v2KeysUnderV1 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 1, trialDays: 7)
        XCTAssertEqual(self.authenticate(self.token(v2KeysUnderV1)), .wrongPurpose, "trial_days under ver 1")
        let v1KeysUnderV2 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 2)
        XCTAssertEqual(self.authenticate(self.token(v1KeysUnderV2)), .wrongPurpose, "ver 2 without trial_days")
        let v2KeysUnderV3 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 7)
        XCTAssertEqual(self.authenticate(self.token(v2KeysUnderV3)), .wrongPurpose, "ver 3 without local_grace_days never sets the mode")
        let v1KeysUnderV3 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3)
        XCTAssertEqual(self.authenticate(self.token(v1KeysUnderV3)), .wrongPurpose, "ver 3 with neither of its two extra claims")
        let graceWithoutTrialUnderV3 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, localGraceDays: 7)
        XCTAssertEqual(self.authenticate(self.token(graceWithoutTrialUnderV3)), .wrongPurpose, "ver 3 without trial_days: v3 is the v2 set plus one claim")
        for version: Int64 in [1, 2] {
            let v3KeysUnderOlder = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: version, trialDays: 7, localGraceDays: 7)
            XCTAssertEqual(self.authenticate(self.token(v3KeysUnderOlder)), .wrongPurpose, "local_grace_days under ver \(version)")
        }
        let graceUnderV1 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 1, localGraceDays: 7)
        XCTAssertEqual(self.authenticate(self.token(graceUnderV1)), .wrongPurpose, "local_grace_days is a claim of the v3 SET, not an extra a v1 token may carry")
        let v4 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 4, trialDays: 7, localGraceDays: 7)
        XCTAssertEqual(self.authenticate(self.token(v4)), .wrongPurpose, "a shape this build does not know never sets the mode")
        for version: Int64 in [0, 4, 5] {
            for claims in [
                SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: version),
                SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: version, trialDays: 7),
                SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: version, trialDays: 7, localGraceDays: 7)
            ] {
                XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "ver \(version) names none of the three sets")
            }
        }
    }

    func test_trialDaysMustBeAJSONIntegerWithinAMonth() {
        let invalid: [Any] = [-1, 31, "7", true]
        for value in invalid {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 2, trialDays: 0)
            claims["trial_days"] = value
            XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "trial_days \(value) must not authenticate")
        }
        // `JSONSerialization` would normalise 7.0 to 7: sign the raw bytes.
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": self.kid], options: [.sortedKeys])
        let fractional = Data("{\"aud\":\"zenlygram-monetization\",\"exp\":\(self.iat + 86400),\"iat\":\(self.iat),\"iss\":\"zenlygram\",\"mode\":\"paid\",\"revision\":1,\"trial_days\":7.0,\"ver\":2}".utf8)
        XCTAssertEqual(self.authenticate(SGEntitlementTestToken.sign(key: self.key, headerData: header, payloadData: fractional)), .invalidClaims, "7.0 is not the integer 7")

        XCTAssertNil(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, mode: "paid", iat: self.iat, version: 2, trialDays: 30)), "30 is the contract's maximum")
        XCTAssertNil(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, mode: "paid", iat: self.iat, version: 2, trialDays: 0)), "0 is 'no trial offered'")
        XCTAssertEqual(SGEntitlementPolicyVerifier.maximumTrialDays, 30)
    }

    func test_aV2PolicyWithAnyExtraClaimIsRejected() {
        for extra in ["sub", "dev", "ent", "until", "account_ent", "account_until", "tgid", "jti", "server_time", "trial_ends_at", "trial_enabled", "local_grace_days"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 2, trialDays: 7)
            claims[extra] = extra == "ent" || extra == "account_ent" ? ["*"] : "x"
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "a v2 policy with `\(extra)` must not authenticate")
        }
        for missing in ["iss", "aud", "ver", "mode", "revision", "iat", "exp", "trial_days"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 2, trialDays: 7)
            claims.removeValue(forKey: missing)
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "a v2 policy without `\(missing)` must not authenticate")
        }
    }

    // MARK: - The v3 shape (`local_grace_days`)

    private func v3(mode: String = "paid", revision: Int64 = 7, trialDays: Int = 0, localGraceDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, mode: mode, revision: revision, iat: self.iat, version: 3, trialDays: trialDays, localGraceDays: localGraceDays)
    }

    func test_aV3PolicyCarriesItsSignedLocalGraceDays() {
        for days in [0, 1, 7, 30] {
            let token = self.v3(trialDays: 14, localGraceDays: days)
            guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
                return XCTFail("a well-formed v3 policy with local_grace_days \(days) signed by the pinned ring must authenticate")
            }
            XCTAssertEqual(policy.version, 3)
            XCTAssertEqual(policy.localGraceDays, days, "the signed value is kept as signed, 0 included")
            XCTAssertEqual(policy.trialDays, 14, "v3 is the v2 claim set plus one claim: the trial is still read")
            XCTAssertTrue(policy.offersServerTrial)
            XCTAssertEqual(policy.mode, .paid)
            XCTAssertEqual(policy.revision, 7)
            XCTAssertEqual(policy.issuedAt, self.iat)
            XCTAssertEqual(policy.expiresAt, self.iat + 86400)
            XCTAssertEqual(policy.token, token, "the exact signed bytes are what gets persisted and re-verified")
        }
        XCTAssertEqual(SGEntitlementPolicyVerifier.maximumLocalGraceDays, 30)
        XCTAssertEqual(SGEntitlementLocalGrace.maximumDays, 30)
    }

    func test_aFreeV3PolicyKeepsItsConfiguredLocalGraceDays() {
        // The server signs the configured value in both modes; it is not zeroed while free (it
        // simply has no effect there — the evaluator never consults the grace in free mode).
        let token = self.v3(mode: "free", trialDays: 7, localGraceDays: 21)
        guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("a free v3 policy authenticates like any other")
        }
        XCTAssertEqual(policy.mode, .free)
        XCTAssertEqual(policy.localGraceDays, 21)
        XCTAssertFalse(policy.offersServerTrial, "nothing is sold while free, a trial included")
    }

    func test_aV1OrV2PolicyCannotSayAndMeansTheDefaultSevenDays() {
        XCTAssertEqual(SGEntitlementLocalGrace.defaultDays, 7)
        let v1 = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 7, iat: self.iat)
        let v2 = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", revision: 7, iat: self.iat, version: 2, trialDays: 30)
        for (name, token) in [("v1", v1), ("v2", v2)] {
            guard case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
                return XCTFail("premise: a \(name) policy still authenticates in this build")
            }
            XCTAssertEqual(policy.localGraceDays, 7, "a \(name) token cannot say: the default seven days")
        }
    }

    func test_localGraceDaysMustBeAJSONIntegerWithinAMonth() {
        // The same strictness as `trial_days`: the WHOLE token is refused, never read as "7".
        let invalid: [Any] = [-1, 31, 365, "7", true, false, NSNull(), [7], ["days": 7]]
        for value in invalid {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
            claims["local_grace_days"] = value
            XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "local_grace_days \(value) must not authenticate")
        }
        // `JSONSerialization` would normalise 7.0 to 7: sign the raw bytes.
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": self.kid], options: [.sortedKeys])
        for fraction in ["7.0", "7.5", "0.0"] {
            let fractional = Data("{\"aud\":\"zenlygram-monetization\",\"exp\":\(self.iat + 86400),\"iat\":\(self.iat),\"iss\":\"zenlygram\",\"local_grace_days\":\(fraction),\"mode\":\"paid\",\"revision\":1,\"trial_days\":0,\"ver\":3}".utf8)
            XCTAssertEqual(self.authenticate(SGEntitlementTestToken.sign(key: self.key, headerData: header, payloadData: fractional)), .invalidClaims, "\(fraction) is not a JSON integer")
        }
        // Missing altogether: the eight v2 claims under `ver: 3` — refused as a whole too.
        var missing = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
        missing.removeValue(forKey: "local_grace_days")
        XCTAssertNotNil(self.authenticate(self.token(missing)), "a ver-3 token without local_grace_days must not authenticate")

        XCTAssertNil(self.authenticate(self.v3(localGraceDays: 30)), "30 is the contract's maximum")
        XCTAssertNil(self.authenticate(self.v3(localGraceDays: 0)), "0 is 'no local grace'")
        XCTAssertNil(self.authenticate(self.v3(mode: "free", localGraceDays: 0)))
    }

    func test_aV3PolicyStillNeedsAValidTrialDays() {
        let invalid: [Any] = [-1, 31, "7", true]
        for value in invalid {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
            claims["trial_days"] = value
            XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "trial_days \(value) under ver 3 must not authenticate")
        }
    }

    func test_aFreeV3PolicyIsValidatedJustAsStrictlyAsAPaidOne() {
        // The value has no effect while free, but the token is held to the same contract: a free
        // policy with a bad `local_grace_days` is no policy at all — it cannot turn the app free.
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": self.kid], options: [.sortedKeys])
        for mode in ["free", "paid"] {
            let invalid: [Any] = [-1, 31, "7", true, NSNull()]
            for value in invalid {
                var claims = SGEntitlementTestPolicy.claims(mode: mode, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
                claims["local_grace_days"] = value
                XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "\(mode): local_grace_days \(value) must not authenticate")
            }
            let fractional = Data("{\"aud\":\"zenlygram-monetization\",\"exp\":\(self.iat + 86400),\"iat\":\(self.iat),\"iss\":\"zenlygram\",\"local_grace_days\":7.0,\"mode\":\"\(mode)\",\"revision\":1,\"trial_days\":0,\"ver\":3}".utf8)
            XCTAssertEqual(self.authenticate(SGEntitlementTestToken.sign(key: self.key, headerData: header, payloadData: fractional)), .invalidClaims, "\(mode): 7.0 is not the integer 7")
            var missing = SGEntitlementTestPolicy.claims(mode: mode, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
            missing.removeValue(forKey: "local_grace_days")
            XCTAssertEqual(self.authenticate(self.token(missing)), .wrongPurpose, "\(mode): a missing claim is never read as 7 or 0")
            var extra = SGEntitlementTestPolicy.claims(mode: mode, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
            extra["local_grace_enabled"] = true
            XCTAssertEqual(self.authenticate(self.token(extra)), .wrongPurpose, "\(mode): exactly the nine claims")
            XCTAssertNil(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, mode: mode, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 0)), "\(mode): the well-formed token authenticates")
        }
    }

    func test_theV3ClaimSetIsExactlyItsNineClaims() {
        let claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 7, localGraceDays: 7)
        XCTAssertEqual(Set(claims.keys), ["iss", "aud", "ver", "mode", "revision", "trial_days", "local_grace_days", "iat", "exp"], "the ver-2 set plus one")
        XCTAssertNil(self.authenticate(self.token(claims)))
    }

    func test_aV3PolicyWithAnyExtraOrMissingClaimIsRejected() {
        for extra in ["sub", "dev", "ent", "until", "account_ent", "account_until", "tgid", "jti", "server_time", "trial_ends_at", "trial_enabled", "local_grace", "local_grace_enabled", "grace_days"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 7, localGraceDays: 7)
            claims[extra] = extra == "ent" || extra == "account_ent" ? ["*"] : "x"
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "a v3 policy with `\(extra)` must not authenticate")
        }
        for missing in ["iss", "aud", "ver", "mode", "revision", "iat", "exp", "trial_days", "local_grace_days"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat, version: 3, trialDays: 7, localGraceDays: 7)
            claims.removeValue(forKey: missing)
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "a v3 policy without `\(missing)` must not authenticate")
        }
    }

    func test_aV3PolicyIsNeverAnEntitlementAndIsBoundToItsSignature() {
        let token = self.v3(localGraceDays: 0)
        XCTAssertEqual(SGEntitlementTokenVerifier.verify(token, pinnedKeys: self.pinned, boundDeviceId: nil).failureValue, .wrongPurpose)
        // An unsigned length is never trusted: 0 days re-written to 30 under the same signature.
        var parts = token.split(separator: ".").map(String.init)
        let forged = try! JSONSerialization.data(withJSONObject: SGEntitlementTestPolicy.claims(mode: "paid", revision: 7, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 30), options: [.sortedKeys])
        parts[1] = SGEntitlementTestToken.base64url(forged)
        XCTAssertEqual(self.authenticate(parts.joined(separator: ".")), .badSignature)
        XCTAssertEqual(self.authenticate(SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), mode: "paid", iat: self.iat, version: 3, trialDays: 0, localGraceDays: 30)), .badSignature, "another key's length is no length")
    }

    // MARK: - Signature and header

    func test_aTamperedModeIsABadSignature() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "free", revision: 1, iat: self.iat)
        var parts = token.split(separator: ".").map(String.init)
        let forged = try! JSONSerialization.data(withJSONObject: SGEntitlementTestPolicy.claims(mode: "paid", revision: 1, iat: self.iat), options: [.sortedKeys])
        parts[1] = SGEntitlementTestToken.base64url(forged)
        XCTAssertEqual(self.authenticate(parts.joined(separator: ".")), .badSignature, "an unsigned mode must never be trusted")
    }

    func test_anotherKeysSignatureIsRejected() {
        let token = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), mode: "paid", iat: self.iat)
        XCTAssertEqual(self.authenticate(token), .badSignature)
    }

    func test_anUnpinnedKidIsReportedAsUnknown() {
        let token = SGEntitlementTestPolicy.make(key: self.key, kid: "k2099z", mode: "paid", iat: self.iat)
        XCTAssertEqual(self.authenticate(token), .unknownKid("k2099z"))
    }

    func test_onlyTheExactES256JWTHeaderIsAccepted() {
        let claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        let headers: [[String: Any]] = [
            ["alg": "none", "typ": "JWT", "kid": self.kid],
            ["alg": "HS256", "typ": "JWT", "kid": self.kid],
            ["alg": "ES256", "kid": self.kid],
            ["alg": "ES256", "typ": "jwt", "kid": self.kid],
            ["alg": "ES256", "typ": "JWT", "kid": self.kid, "x5u": "https://attacker.invalid/key"],
            ["alg": "ES256", "typ": "JWT", "kid": ""]
        ]
        for header in headers {
            let token = SGEntitlementTestToken.make(key: self.key, header: header, payload: claims)
            XCTAssertEqual(self.authenticate(token), .malformed, "header \(header) must not authenticate")
        }
    }

    func test_compactFormOutsideTheContractIsMalformed() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", iat: self.iat)
        XCTAssertEqual(self.authenticate("a.b.c"), .malformed, "below the 100-character floor")
        XCTAssertEqual(self.authenticate(token + "="), .malformed, "padding is outside the base64url alphabet")
        XCTAssertEqual(self.authenticate(token + "." + "A"), .malformed, "four segments")
        XCTAssertEqual(self.authenticate(token + String(repeating: "A", count: 8192)), .malformed, "above the 8192-character ceiling")
    }

    // MARK: - Purpose separation

    func test_anEntitlementTokenIsNeverAPolicy() {
        // Same issuer, same pinned key ring: only the exact v1 policy shape may set the mode.
        let entitlement = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims())
        XCTAssertEqual(self.authenticate(entitlement), .wrongPurpose)
    }

    func test_aPolicyCarryingAnyAccountOrUnknownClaimIsRejected() {
        for extra in ["sub", "dev", "ent", "until", "account_ent", "account_until", "tgid", "jti", "server_time"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
            claims[extra] = extra == "ent" || extra == "account_ent" ? ["*"] : "x"
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "a policy with `\(extra)` must not authenticate")
        }
        // `trial_days` is a claim of the v2 SET, not an extra a v1 token may carry.
        var trialUnderV1 = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        trialUnderV1["trial_days"] = 7
        XCTAssertEqual(self.authenticate(self.token(trialUnderV1)), .wrongPurpose, "trial_days under ver 1 is neither shape")
    }

    func test_aPolicyMissingARequiredClaimOrForAnotherAudienceIsRejected() {
        for missing in ["iss", "aud", "ver", "mode", "revision", "iat", "exp"] {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
            claims.removeValue(forKey: missing)
            XCTAssertNotNil(self.authenticate(self.token(claims)), "a policy without `\(missing)` must not authenticate")
        }
        var otherAudience = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        otherAudience["aud"] = "zenlygram-entitlement"
        XCTAssertEqual(self.authenticate(self.token(otherAudience)), .wrongPurpose)
        var otherIssuer = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        otherIssuer["iss"] = "somebody-else"
        XCTAssertEqual(self.authenticate(self.token(otherIssuer)), .wrongPurpose)
        var otherVersion = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        otherVersion["ver"] = 2
        XCTAssertEqual(self.authenticate(self.token(otherVersion)), .wrongPurpose, "ver must name the claim set: the seven v1 claims are version 1, never 2")
        otherVersion["ver"] = 3
        XCTAssertEqual(self.authenticate(self.token(otherVersion)), .wrongPurpose, "a shape this build does not know never sets the mode")
    }

    func test_thePolicyVerifiedAsAnEntitlementIsRejected() {
        // Lenient entitlement decoding would otherwise read a policy as a token with no `sub`/`dev`
        // and an empty `ent` — unbound installs verify with no binding to compare against.
        let policy = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", iat: self.iat)
        let result = SGEntitlementTokenVerifier.verify(policy, pinnedKeys: self.pinned, boundDeviceId: nil)
        XCTAssertEqual(result.failureValue, .wrongPurpose)
    }

    // MARK: - Exact claim types

    func test_claimTypesAndRangesAreExact() {
        let invalid: [(String, Any)] = [
            ("mode", "trial"),
            ("mode", "PAID"),
            ("mode", 1),
            ("revision", -1),
            ("revision", 9_007_199_254_740_992 as Int64),
            ("revision", 1.5),
            ("revision", "1"),
            ("revision", true),
            ("iat", 0),
            ("iat", "1790000000"),
            ("exp", 0),
            ("exp", 1.79e9)
        ]
        for (claim, value) in invalid {
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
            claims[claim] = value
            XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "`\(claim)`: \(value) must not authenticate")
        }
        var maximum = SGEntitlementTestPolicy.claims(mode: "paid", iat: self.iat)
        maximum["revision"] = 9_007_199_254_740_991 as Int64
        XCTAssertNil(self.authenticate(self.token(maximum)), "2^53-1 is the contract's maximum revision")
    }

    func test_aFloatOrBooleanVersionIsNotV1() {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": self.kid], options: [.sortedKeys])
        for ver in ["1.0", "true"] {
            let payload = Data("{\"aud\":\"zenlygram-monetization\",\"exp\":\(self.iat + 86400),\"iat\":\(self.iat),\"iss\":\"zenlygram\",\"mode\":\"paid\",\"revision\":1,\"ver\":\(ver)}".utf8)
            let token = SGEntitlementTestToken.sign(key: self.key, headerData: header, payloadData: payload)
            XCTAssertNotNil(self.authenticate(token), "ver \(ver) is not the integer 1")
        }
    }

    func test_lifetimeMustBePositiveAndAtMostOneDay() {
        XCTAssertEqual(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, iat: self.iat, exp: self.iat)), .invalidClaims, "exp must be after iat")
        XCTAssertEqual(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, iat: self.iat, exp: self.iat - 1)), .invalidClaims)
        XCTAssertEqual(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, iat: self.iat, exp: self.iat + 86401)), .invalidClaims, "exp - iat <= 86400")
        XCTAssertNil(self.authenticate(SGEntitlementTestPolicy.make(key: self.key, iat: self.iat, exp: self.iat + 86400)))
    }

    // MARK: - Freshness (newly fetched tokens only)

    func test_aFetchedPolicyMustBeInsideTheSkewedWindow() {
        let token = SGEntitlementTestPolicy.make(key: self.key, mode: "paid", iat: self.iat)
        let exp = self.iat + 86400
        func fetched(_ now: Int64) -> SGEntitlementPolicyFailure? {
            if case let .failure(failure) = SGEntitlementPolicyVerifier.verifyFetched(token, pinnedKeys: self.pinned, now: self.at(now)) {
                return failure
            }
            return nil
        }
        XCTAssertNil(fetched(self.iat))
        XCTAssertNil(fetched(self.iat - 300), "iat <= effectiveNow + 300")
        XCTAssertEqual(fetched(self.iat - 301), .notYetValid)
        XCTAssertNil(fetched(exp + 299), "exp > effectiveNow - 300")
        XCTAssertEqual(fetched(exp + 300), .expired)
        XCTAssertEqual(fetched(exp + 30 * 86400), .expired)
    }

    func test_aFetchedPolicyIsAuthenticatedBeforeItsTimeIsTrusted() {
        let forgedFresh = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), mode: "paid", iat: self.iat)
        guard case let .failure(failure) = SGEntitlementPolicyVerifier.verifyFetched(forgedFresh, pinnedKeys: self.pinned, now: self.at(self.iat)) else {
            return XCTFail("a fresh but unsigned-by-us policy must not verify")
        }
        XCTAssertEqual(failure, .badSignature)
    }
}

/// The client-side policy state: initial free, `(revision, iat)` order, conflicts, persistence.
final class SGEntitlementPolicyStateTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let iat: Int64 = 1_790_000_000
    private var suiteName = ""
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        self.suiteName = "SGEntitlementPolicyStateTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suiteName)?.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private func policy(_ mode: String, revision: Int64, iat: Int64? = nil) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: iat ?? self.iat)
    }

    /// The same issuance in the v2 shape, with its `trial_days`.
    private func policyV2(_ mode: String, revision: Int64, iat: Int64? = nil, trialDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: iat ?? self.iat, version: 2, trialDays: trialDays)
    }

    /// The same issuance in the v3 shape, with its `trial_days` and its `local_grace_days`.
    private func policyV3(_ mode: String, revision: Int64, iat: Int64? = nil, trialDays: Int = 0, localGraceDays: Int) -> String {
        return SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: mode, revision: revision, iat: iat ?? self.iat, version: 3, trialDays: trialDays, localGraceDays: localGraceDays)
    }

    private func accept(_ token: String, into state: SGEntitlementPolicyState, now: Int64? = nil) -> SGEntitlementPolicyAcceptance {
        return state.accepting(fetched: token, pinnedKeys: self.pinned, now: Date(timeIntervalSince1970: TimeInterval(now ?? (self.iat + 60))))
    }

    func test_initialModeIsFreeWithNothingAccepted() {
        XCTAssertEqual(SGEntitlementPolicyState.initial.mode, .free, "every install starts free until the owner deliberately enables paid")
        XCTAssertNil(SGEntitlementPolicyState.initial.accepted)
    }

    func test_freePaidFreeFollowsTheNewestRevision() {
        let paid = self.accept(self.policy("paid", revision: 1), into: .initial)
        XCTAssertEqual(paid.outcome, .adopted)
        XCTAssertEqual(paid.state.mode, .paid)

        let free = self.accept(self.policy("free", revision: 2), into: paid.state)
        XCTAssertEqual(free.outcome, .adopted)
        XCTAssertEqual(free.state.mode, .free)

        let paidAgain = self.accept(self.policy("paid", revision: 3), into: free.state)
        XCTAssertEqual(paidAgain.outcome, .adopted)
        XCTAssertEqual(paidAgain.state.mode, .paid)
        XCTAssertEqual(paidAgain.state.accepted?.revision, 3)
    }

    func test_anOlderRevisionIsRejectedAndChangesNothing() {
        let newer = self.accept(self.policy("free", revision: 5), into: .initial).state
        let replay = self.accept(self.policy("paid", revision: 4, iat: self.iat + 3600), into: newer, now: self.iat + 3600)
        XCTAssertEqual(replay.outcome, .rejected(.older), "a replayed older paid policy must not re-enable paid")
        XCTAssertEqual(replay.state, newer)
    }

    func test_sameRevisionIsOrderedByIssuance() {
        let first = self.accept(self.policy("paid", revision: 2, iat: self.iat), into: .initial).state
        let emergency = self.accept(self.policy("free", revision: 2, iat: self.iat + 10), into: first, now: self.iat + 60)
        XCTAssertEqual(emergency.outcome, .adopted, "a same-revision emergency change is ordered by its signed iat")
        XCTAssertEqual(emergency.state.mode, .free)

        let stale = self.accept(self.policy("paid", revision: 2, iat: self.iat), into: emergency.state)
        XCTAssertEqual(stale.outcome, .rejected(.older))
        XCTAssertEqual(stale.state.mode, .free)
    }

    func test_anEqualTupleIsIdempotentForTheSameModeAndAConflictOtherwise() {
        let accepted = self.accept(self.policy("paid", revision: 3), into: .initial).state
        // Re-signed (a fresh ECDSA nonce, so different bytes) but the same (revision, iat, mode).
        let again = self.accept(self.policy("paid", revision: 3), into: accepted)
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.state, accepted)

        let conflict = self.accept(self.policy("free", revision: 3), into: accepted)
        XCTAssertEqual(conflict.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(conflict.state, accepted, "a conflicting equal tuple must change nothing")
    }

    // MARK: - The two shapes under one order (`trial_days`)

    func test_theSameIssuanceFetchedAsV2IsAdoptedAndAV1OfItChangesNothing() {
        // This build's first fetch after the server started minting v2: the issuance it already
        // holds, with its trial_days now legible.
        let v1 = self.accept(self.policy("paid", revision: 3), into: .initial).state
        XCTAssertEqual(v1.accepted?.version, 1)
        XCTAssertEqual(v1.accepted?.trialDays, 0)

        let upgraded = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: v1)
        XCTAssertEqual(upgraded.outcome, .adopted, "a v1 -> v2 upgrade of the same issuance is adopted")
        XCTAssertEqual(upgraded.state.accepted?.version, 2)
        XCTAssertEqual(upgraded.state.accepted?.trialDays, 7)
        XCTAssertEqual(upgraded.state.accepted?.offersServerTrial, true)
        XCTAssertEqual(upgraded.state.mode, .paid)

        // A v1 of the issuance held as v2 (a proxy, a cache): the v2 stands, the trial stays.
        let downgraded = self.accept(self.policy("paid", revision: 3), into: upgraded.state)
        XCTAssertEqual(downgraded.outcome, .unchanged, "a v1 of the same issuance never takes the trial away")
        XCTAssertEqual(downgraded.state, upgraded.state)

        // Another mode under the same tuple is a conflict, whatever the shapes.
        let conflict = self.accept(self.policyV2("free", revision: 3, trialDays: 7), into: v1)
        XCTAssertEqual(conflict.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(conflict.state, v1)
        let conflictBack = self.accept(self.policy("free", revision: 3), into: upgraded.state)
        XCTAssertEqual(conflictBack.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(conflictBack.state, upgraded.state)
    }

    func test_twoV2PoliciesOfTheSameIssuanceMustAgreeOnTheirTrialDays() {
        let seven = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: .initial).state
        // Re-signed (a fresh ECDSA nonce) with the same claims: a routine refresh.
        let again = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: seven)
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.state, seven)

        let fourteen = self.accept(self.policyV2("paid", revision: 3, trialDays: 14), into: seven)
        XCTAssertEqual(fourteen.outcome, .rejected(.conflictingIssuance), "the server bumps the revision for every trial change: an equal tuple with other days is a conflict")
        XCTAssertEqual(fourteen.state, seven, "a conflicting equal tuple must change nothing")
        XCTAssertEqual(fourteen.state.accepted?.trialDays, 7)
    }

    func test_aNewerV1IssuanceWinsOverAStoredV2AndHidesTheTrialUntilTheNextV2() {
        let v2 = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: .initial).state
        XCTAssertEqual(v2.accepted?.trialDays, 7)

        // `(revision, iat)` alone orders policies: the shape never does.
        let newerV1 = self.accept(self.policy("paid", revision: 3, iat: self.iat + 10), into: v2, now: self.iat + 60)
        XCTAssertEqual(newerV1.outcome, .adopted)
        XCTAssertEqual(newerV1.state.accepted?.version, 1)
        XCTAssertEqual(newerV1.state.accepted?.trialDays, 0, "fail-safe: a v1 cannot say, so no trial is shown")
        XCTAssertEqual(newerV1.state.accepted?.offersServerTrial, false)
        XCTAssertEqual(newerV1.state.mode, .paid)

        // The next fetch carries a newer iat still and, as v2, re-adopts the trial.
        let readopted = self.accept(self.policyV2("paid", revision: 3, iat: self.iat + 20, trialDays: 7), into: newerV1.state, now: self.iat + 60)
        XCTAssertEqual(readopted.outcome, .adopted)
        XCTAssertEqual(readopted.state.accepted?.trialDays, 7)
        XCTAssertEqual(readopted.state.accepted?.offersServerTrial, true)

        // An older v2 cannot bring a trial back over a newer issuance.
        let replay = self.accept(self.policyV2("paid", revision: 3, iat: self.iat, trialDays: 30), into: newerV1.state, now: self.iat + 60)
        XCTAssertEqual(replay.outcome, .rejected(.older))
        XCTAssertEqual(replay.state, newerV1.state)
    }

    func test_aTrialChangeArrivesAsANewerRevision() {
        let seven = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: .initial).state
        let fourteen = self.accept(self.policyV2("paid", revision: 4, trialDays: 14), into: seven)
        XCTAssertEqual(fourteen.outcome, .adopted)
        XCTAssertEqual(fourteen.state.accepted?.trialDays, 14)

        let disabled = self.accept(self.policyV2("paid", revision: 5, trialDays: 0), into: fourteen.state)
        XCTAssertEqual(disabled.outcome, .adopted, "disabling the trial is an ordinary newer policy")
        XCTAssertEqual(disabled.state.mode, .paid, "the mode did not move")
        XCTAssertEqual(disabled.state.accepted?.trialDays, 0)
        XCTAssertEqual(disabled.state.accepted?.offersServerTrial, false)

        let free = self.accept(self.policyV2("free", revision: 6, trialDays: 7), into: disabled.state)
        XCTAssertEqual(free.outcome, .adopted)
        XCTAssertEqual(free.state.mode, .free)
        XCTAssertEqual(free.state.accepted?.offersServerTrial, false, "never a trial while free")
    }

    func test_aRestoredPolicyKeepsItsShapeAndItsTrialDays() {
        let v2 = self.policyV2("paid", revision: 4, trialDays: 10)
        let restoredV2 = SGEntitlementPolicyState.restoring(stored: v2, pinnedKeys: self.pinned)
        XCTAssertEqual(restoredV2.mode, .paid)
        XCTAssertEqual(restoredV2.accepted?.version, 2)
        XCTAssertEqual(restoredV2.accepted?.trialDays, 10, "the stored v2 keeps its trial_days across a relaunch")
        XCTAssertEqual(restoredV2.accepted?.offersServerTrial, true)

        let restoredV1 = SGEntitlementPolicyState.restoring(stored: self.policy("paid", revision: 4), pinnedKeys: self.pinned)
        XCTAssertEqual(restoredV1.accepted?.version, 1)
        XCTAssertEqual(restoredV1.accepted?.trialDays, 0, "a stored v1 has no trial to restore")

        // The store key names the store's layout, not the token's `ver`: a v2 lands in the v1 slot.
        let store = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName))
        XCTAssertEqual(store.key, "zg.ent.policy.v1")
        XCTAssertTrue(store.save(v2))
        let relaunched = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName))
        XCTAssertEqual(relaunched.load(), v2, "the exact signed v2 bytes are persisted under the unchanged key")
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: relaunched.load(), pinnedKeys: self.pinned).accepted?.trialDays, 10)
    }

    // MARK: - The three shapes under one order (`local_grace_days`)

    func test_theLocalGraceLengthIsTheAcceptedPolicys_andSevenDaysWhereItCannotSay() {
        XCTAssertEqual(SGEntitlementPolicyState.initial.localGraceDays, 7, "no policy: the default seven days")
        let v1 = self.accept(self.policy("paid", revision: 1), into: .initial).state
        XCTAssertEqual(v1.localGraceDays, 7, "a v1 policy cannot say: seven days")
        let v2 = self.accept(self.policyV2("paid", revision: 2, trialDays: 30), into: v1).state
        XCTAssertEqual(v2.localGraceDays, 7, "a v2 policy cannot say either — never its trial_days")
        var state = v2
        var revision: Int64 = 3
        for days in [0, 1, 7, 30, 3] {
            let adopted = self.accept(self.policyV3("paid", revision: revision, localGraceDays: days), into: state)
            XCTAssertEqual(adopted.outcome, .adopted)
            XCTAssertEqual(adopted.state.localGraceDays, days, "a v3 policy's signed local_grace_days is the length")
            XCTAssertEqual(adopted.state.accepted?.version, 3)
            state = adopted.state
            revision += 1
        }
        // Signed in both modes: a free v3 policy keeps the configured value (it has no effect there).
        let free = self.accept(self.policyV3("free", revision: revision, localGraceDays: 12), into: state)
        XCTAssertEqual(free.outcome, .adopted)
        XCTAssertEqual(free.state.mode, .free)
        XCTAssertEqual(free.state.localGraceDays, 12)
    }

    func test_theSameIssuanceFetchedAsV3IsAdoptedAndAnOlderShapeOfItChangesNothing() {
        // This build's first fetch after the server started minting v3: the issuance it already
        // holds as v2 (or v1), with its local_grace_days now legible.
        let v2 = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: .initial).state
        XCTAssertEqual(v2.localGraceDays, 7)
        let upgraded = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 0), into: v2)
        XCTAssertEqual(upgraded.outcome, .adopted, "a v2 -> v3 upgrade of the same issuance is adopted")
        XCTAssertEqual(upgraded.state.accepted?.version, 3)
        XCTAssertEqual(upgraded.state.localGraceDays, 0)
        XCTAssertEqual(upgraded.state.accepted?.trialDays, 7)

        let v1 = self.accept(self.policy("paid", revision: 3), into: .initial).state
        let fromV1 = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 21), into: v1)
        XCTAssertEqual(fromV1.outcome, .adopted, "a v1 -> v3 upgrade of the same issuance is adopted")
        XCTAssertEqual(fromV1.state.localGraceDays, 21)
        XCTAssertEqual(fromV1.state.accepted?.trialDays, 7)

        // An older shape of the issuance held as v3 (a proxy, a cache, a server one release
        // behind): the v3 stands — its length is not replaced by the default.
        for older in [self.policyV2("paid", revision: 3, trialDays: 7), self.policy("paid", revision: 3)] {
            let downgraded = self.accept(older, into: upgraded.state)
            XCTAssertEqual(downgraded.outcome, .unchanged, "an older shape of the same issuance never takes the signed length away")
            XCTAssertEqual(downgraded.state, upgraded.state)
            XCTAssertEqual(downgraded.state.localGraceDays, 0)
        }

        // Another mode under the same tuple is a conflict, whatever the shapes.
        let conflict = self.accept(self.policyV3("free", revision: 3, trialDays: 7, localGraceDays: 0), into: v2)
        XCTAssertEqual(conflict.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(conflict.state, v2)
        let conflictBack = self.accept(self.policyV2("free", revision: 3, trialDays: 7), into: upgraded.state)
        XCTAssertEqual(conflictBack.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(conflictBack.state, upgraded.state)
    }

    func test_twoV3PoliciesOfTheSameIssuanceMustAgreeOnTheirTrialDaysAndTheirLocalGraceDays() {
        let held = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 7), into: .initial).state
        // Re-signed (a fresh ECDSA nonce) with the same claims: a routine refresh.
        let again = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 7), into: held)
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.state, held)

        // The server bumps the revision for every change of the local grace: an equal tuple with
        // another length is a conflict, and the accepted length stands — shorter or longer.
        for other in [0, 6, 8, 30] {
            let conflict = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: other), into: held)
            XCTAssertEqual(conflict.outcome, .rejected(.conflictingIssuance), "local_grace_days \(other) under the accepted (revision, iat)")
            XCTAssertEqual(conflict.state, held, "a conflicting equal tuple must change nothing")
            XCTAssertEqual(conflict.state.localGraceDays, 7)
        }
        let otherTrial = self.accept(self.policyV3("paid", revision: 3, trialDays: 14, localGraceDays: 7), into: held)
        XCTAssertEqual(otherTrial.outcome, .rejected(.conflictingIssuance), "two v3 tokens of one issuance agree on trial_days too")
        XCTAssertEqual(otherTrial.state, held)

        // The rule compares two tokens of the SAME shape. Across shapes the matrix is the v1 / v2
        // one, extended: the newer shape of the issuance is adopted and the older one is ignored,
        // whatever the claim only one of them is asked about.
        let v2 = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: .initial).state
        let upgrade = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 0), into: v2)
        XCTAssertEqual(upgrade.outcome, .adopted)
        XCTAssertEqual(upgrade.state.localGraceDays, 0)
        let older = self.accept(self.policyV2("paid", revision: 3, trialDays: 7), into: held)
        XCTAssertEqual(older.outcome, .unchanged)
        XCTAssertEqual(older.state, held)
    }

    func test_aNewerOlderShapedIssuanceWinsOverAStoredV3_andTheGraceIsSevenDaysUntilTheNextV3() {
        let v3 = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 0), into: .initial).state
        XCTAssertEqual(v3.localGraceDays, 0)

        // `(revision, iat)` alone orders policies: the shape never does. The last accepted policy
        // is then ver 2, which cannot say — seven days, by the one rule.
        let newerV2 = self.accept(self.policyV2("paid", revision: 3, iat: self.iat + 10, trialDays: 7), into: v3, now: self.iat + 60)
        XCTAssertEqual(newerV2.outcome, .adopted)
        XCTAssertEqual(newerV2.state.accepted?.version, 2)
        XCTAssertEqual(newerV2.state.localGraceDays, 7)
        XCTAssertEqual(newerV2.state.accepted?.trialDays, 7, "the v2 still carries the trial")

        let newerV1 = self.accept(self.policy("paid", revision: 3, iat: self.iat + 15), into: newerV2.state, now: self.iat + 60)
        XCTAssertEqual(newerV1.outcome, .adopted)
        XCTAssertEqual(newerV1.state.localGraceDays, 7)

        // The next fetch carries a newer iat still and, as v3, re-adopts the signed length.
        let readopted = self.accept(self.policyV3("paid", revision: 3, iat: self.iat + 20, trialDays: 7, localGraceDays: 0), into: newerV1.state, now: self.iat + 60)
        XCTAssertEqual(readopted.outcome, .adopted)
        XCTAssertEqual(readopted.state.localGraceDays, 0)

        // An older v3 cannot bring another length back over a newer issuance.
        let replay = self.accept(self.policyV3("paid", revision: 3, iat: self.iat, trialDays: 7, localGraceDays: 30), into: readopted.state, now: self.iat + 60)
        XCTAssertEqual(replay.outcome, .rejected(.older))
        XCTAssertEqual(replay.state, readopted.state)
        XCTAssertEqual(replay.state.localGraceDays, 0)
    }

    func test_aV3WithAnInvalidLocalGraceDaysIsRefusedAsAWhole_andTheAcceptedPolicyStays() {
        let held = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 5), into: .initial).state
        let bad: [Any] = [31, -1, "7", true, NSNull()]
        for value in bad {
            // A NEWER revision that would also flip the mode: nothing of it is taken.
            var claims = SGEntitlementTestPolicy.claims(mode: "free", revision: 9, iat: self.iat + 10, version: 3, trialDays: 0, localGraceDays: 7)
            claims["local_grace_days"] = value
            let refused = self.accept(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: claims), into: held)
            XCTAssertEqual(refused.outcome, .rejected(.verification(.invalidClaims)), "local_grace_days \(value)")
            XCTAssertEqual(refused.state, held, "the last accepted policy stays, with its own length and mode")
            XCTAssertEqual(refused.state.localGraceDays, 5)
            XCTAssertEqual(refused.state.mode, .paid)
        }
        var missing = SGEntitlementTestPolicy.claims(mode: "free", revision: 9, iat: self.iat + 10, version: 3, trialDays: 0, localGraceDays: 7)
        missing.removeValue(forKey: "local_grace_days")
        let refused = self.accept(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: missing), into: held)
        XCTAssertEqual(refused.outcome, .rejected(.verification(.wrongPurpose)), "a ver-3 token without the claim is no policy at all")
        XCTAssertEqual(refused.state, held)
        // With nothing accepted, a refused v3 leaves the install without a policy: free, seven days.
        var first = SGEntitlementTestPolicy.claims(mode: "paid", revision: 9, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 7)
        first["local_grace_days"] = 31
        let none = self.accept(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: first), into: .initial)
        XCTAssertEqual(none.outcome, .rejected(.verification(.invalidClaims)))
        XCTAssertEqual(none.state, .initial)
        XCTAssertEqual(none.state.localGraceDays, 7)
    }

    func test_aBadTrialDaysInsideAV3RefusesTheWholeToken_andItsLocalGraceDaysIsNotAdopted() {
        let held = self.accept(self.policyV3("paid", revision: 3, trialDays: 7, localGraceDays: 5), into: .initial).state
        let bad: [Any] = [-1, 31, "7", true, NSNull()]
        for value in bad {
            // A newer revision whose `local_grace_days` is perfectly valid — and would switch the
            // grace off — beside a `trial_days` that is not: nothing of the token is taken.
            var claims = SGEntitlementTestPolicy.claims(mode: "paid", revision: 9, iat: self.iat + 10, version: 3, trialDays: 0, localGraceDays: 0)
            claims["trial_days"] = value
            let refused = self.accept(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: claims), into: held)
            XCTAssertEqual(refused.outcome, .rejected(.verification(.invalidClaims)), "trial_days \(value) inside a ver-3 token")
            XCTAssertEqual(refused.state, held)
            XCTAssertEqual(refused.state.localGraceDays, 5, "the refused token's local_grace_days is not adopted either")
            XCTAssertEqual(refused.state.accepted?.trialDays, 7)
        }
        var missing = SGEntitlementTestPolicy.claims(mode: "paid", revision: 9, iat: self.iat + 10, version: 3, trialDays: 0, localGraceDays: 0)
        missing.removeValue(forKey: "trial_days")
        let refused = self.accept(SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: missing), into: held)
        XCTAssertEqual(refused.outcome, .rejected(.verification(.wrongPurpose)), "a ver-3 token is the ver-2 set plus one: trial_days is not optional in it")
        XCTAssertEqual(refused.state.localGraceDays, 5)
    }

    func test_aRestoredV3KeepsItsLocalGraceDays_andTheTokenIsItsOnlyStore() {
        for days in [0, 3, 30] {
            let v3 = self.policyV3("paid", revision: 4, trialDays: 10, localGraceDays: days)
            let restored = SGEntitlementPolicyState.restoring(stored: v3, pinnedKeys: self.pinned)
            XCTAssertEqual(restored.mode, .paid)
            XCTAssertEqual(restored.accepted?.version, 3)
            XCTAssertEqual(restored.localGraceDays, days, "the stored v3 keeps its local_grace_days across a relaunch")
            XCTAssertEqual(restored.accepted?.trialDays, 10)
        }
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: self.policyV2("paid", revision: 4, trialDays: 10), pinnedKeys: self.pinned).localGraceDays, 7, "a stored v2 has no length to restore")
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: self.policy("paid", revision: 4), pinnedKeys: self.pinned).localGraceDays, 7)
        // A stored v3 that no longer verifies is no policy: free, and the default length.
        let rotatedOut = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, mode: "paid", revision: 4, iat: self.iat, version: 3, trialDays: 0, localGraceDays: 0)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: rotatedOut, pinnedKeys: self.pinned), .initial)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: rotatedOut, pinnedKeys: self.pinned).localGraceDays, 7)

        // The store key names the store's layout, not the token's `ver`: a v3 lands in the slot the
        // v1 / v2 had, and that one string is everything the policy store holds — the length has no
        // key of its own.
        let defaults = UserDefaults(suiteName: self.suiteName)
        let store = SGEntitlementPolicyStore(defaults: defaults)
        XCTAssertEqual(store.key, "zg.ent.policy.v1")
        let v3 = self.policyV3("paid", revision: 4, trialDays: 10, localGraceDays: 3)
        XCTAssertTrue(store.save(v3))
        let relaunched = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName))
        XCTAssertEqual(relaunched.load(), v3, "the exact signed v3 bytes are persisted under the unchanged key")
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: relaunched.load(), pinnedKeys: self.pinned).localGraceDays, 3)
        XCTAssertEqual(defaults?.persistentDomain(forName: self.suiteName).map { Array($0.keys) }, ["zg.ent.policy.v1"], "nothing but the signed token is stored")
    }

    func test_anUnverifiableOrExpiredFetchKeepsTheLastVerifiedMode() {
        let paid = self.accept(self.policy("paid", revision: 1), into: .initial).state

        let forged = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, mode: "free", revision: 9, iat: self.iat)
        XCTAssertEqual(self.accept(forged, into: paid).outcome, .rejected(.verification(.badSignature)))
        XCTAssertEqual(self.accept(forged, into: paid).state.mode, .paid)

        let expired = self.policy("free", revision: 9, iat: self.iat)
        let late = self.accept(expired, into: paid, now: self.iat + 86400 + 301)
        XCTAssertEqual(late.outcome, .rejected(.verification(.expired)), "a newer but expired policy is not accepted")
        XCTAssertEqual(late.state.mode, .paid)

        XCTAssertEqual(self.accept("not-a-policy", into: .initial).state.mode, .free)
    }

    func test_aRestoredPolicyKeepsItsModePastItsExpiry() {
        let token = self.policy("paid", revision: 4)
        let restored = SGEntitlementPolicyState.restoring(stored: token, pinnedKeys: self.pinned)
        XCTAssertEqual(restored.mode, .paid, "cached expiry never changes an authenticated mode")
        XCTAssertEqual(restored.accepted?.revision, 4)
    }

    func test_aStoredPolicyThatNoLongerVerifiesRestoresFree() {
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: nil, pinnedKeys: self.pinned), .initial)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: "garbage", pinnedKeys: self.pinned), .initial)
        let otherKey = SGEntitlementTestPolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, mode: "paid", revision: 4, iat: self.iat)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: otherKey, pinnedKeys: self.pinned), .initial)
        let rotatedOut = SGEntitlementTestPolicy.make(key: self.key, kid: "k2019x", mode: "paid", revision: 4, iat: self.iat)
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: rotatedOut, pinnedKeys: self.pinned), .initial)
        let entitlement = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims())
        XCTAssertEqual(SGEntitlementPolicyState.restoring(stored: entitlement, pinnedKeys: self.pinned), .initial)
    }

    func test_freshnessIsFlooredAtTheAcceptedSignedIssuance() {
        // Freshness is checked against the wall clock, floored at the accepted policy's SIGNED `iat`
        // — never the account clock mark that unsigned `server_time` moves. A wall clock wound back
        // ten days therefore cannot make a newer, genuinely current policy look not yet valid.
        let accepted = self.accept(self.policy("free", revision: 1, iat: self.iat), into: .initial, now: self.iat + 60).state
        let woundBack = Date(timeIntervalSince1970: TimeInterval(self.iat - 10 * 86400))
        let newer = accepted.accepting(fetched: self.policy("paid", revision: 2, iat: self.iat + 120), pinnedKeys: self.pinned, now: woundBack)
        XCTAssertEqual(newer.outcome, .adopted)
        // Without an accepted policy there is no signed floor: the wall clock alone decides.
        let fresh = SGEntitlementPolicyState.initial.accepting(fetched: self.policy("paid", revision: 2, iat: self.iat + 120), pinnedKeys: self.pinned, now: woundBack)
        XCTAssertEqual(fresh.outcome, .rejected(.verification(.notYetValid)))
    }

    func test_orderSurvivesARelaunch() {
        let store = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName))
        let newer = self.policy("free", revision: 6)
        guard case .adopted = self.accept(newer, into: .initial).outcome else {
            return XCTFail("premise: revision 6 is accepted")
        }
        XCTAssertTrue(store.save(newer))

        let relaunched = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName))
        XCTAssertEqual(relaunched.load(), newer, "the exact signed bytes are persisted")
        let restored = SGEntitlementPolicyState.restoring(stored: relaunched.load(), pinnedKeys: self.pinned)
        XCTAssertEqual(restored.mode, .free)
        XCTAssertEqual(self.accept(self.policy("paid", revision: 5, iat: self.iat + 120), into: restored, now: self.iat + 120).outcome, .rejected(.older))
    }
}

/// The policy fetch gate: one request in flight, at least 60 s between attempts, monotonic.
final class SGEntitlementPolicyRefreshGateTests: XCTestCase {
    func test_oneInFlightAndSixtySecondsBetweenAttempts() {
        var gate = SGEntitlementPolicyRefreshGate()
        XCTAssertTrue(gate.begin(uptime: 1000))
        XCTAssertFalse(gate.begin(uptime: 1001), "a second request while one is in flight")
        gate.finish()
        XCTAssertFalse(gate.begin(uptime: 1059), "attempts are at least 60 s apart, success or failure alike")
        XCTAssertTrue(gate.begin(uptime: 1060))
        gate.finish()
        XCTAssertFalse(gate.begin(uptime: 1119))
        XCTAssertTrue(gate.begin(uptime: 1121))
    }

    func test_aFinishedAttemptWithNoInFlightRequestStillCoolsDown() {
        var gate = SGEntitlementPolicyRefreshGate()
        gate.finish()
        XCTAssertTrue(gate.begin(uptime: 5), "a stray finish never blocks the first attempt")
        gate.finish()
        gate.finish()
        XCTAssertFalse(gate.begin(uptime: 30))
    }

    func test_aPurchaseAuthorizationSharesTheInFlightSlotButNotTheCooldown() {
        var gate = SGEntitlementPolicyRefreshGate()
        XCTAssertTrue(gate.begin(uptime: 1000))
        XCTAssertFalse(gate.beginPurchaseAuthorization(uptime: 1001), "never two policy requests at once")
        gate.finish()
        XCTAssertTrue(gate.beginPurchaseAuthorization(uptime: 1002), "a user's purchase is not held back by a background refresh's cooldown")
        XCTAssertFalse(gate.begin(uptime: 1003), "…and the authorization is itself an attempt for the background cadence")
        gate.finish()
        XCTAssertFalse(gate.begin(uptime: 1061))
        XCTAssertTrue(gate.begin(uptime: 1062))
    }
}
