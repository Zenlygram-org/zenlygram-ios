import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — the signed app-update policy (`GET /v1/app-policy`, contract `app-update-policy.v1`):
/// exactly its eight claims under `aud: zenlygram-app-policy`, each platform `null` or exactly
/// `{min, latest}` of the version pattern with `min <= latest`, the shared pinned ES256 ring, the
/// freshness window applied only to newly fetched tokens — and the purpose wall between it and the
/// monetization policy, which shares its envelope and its ring. Every token here is really signed.
final class SGAppUpdatePolicyVerifierTests: XCTestCase {
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
        if case let .failure(failure) = SGAppUpdatePolicyVerifier.authenticate(token, pinnedKeys: self.pinned) {
            return failure
        }
        return nil
    }

    private func versions(_ min: String, _ latest: String) -> [String: Any] {
        return SGEntitlementTestAppUpdatePolicy.platform(min: min, latest: latest)
    }

    // MARK: - Exact-claim acceptance

    func test_aSignedPolicyWithBothPlatformsAuthenticatesWithItsExactFields() {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 7, iat: self.iat, ios: self.versions("12.9.0", "12.10.0"), android: self.versions("12.10.0", "12.10.6"))
        guard case let .success(policy) = SGAppUpdatePolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("a well-formed app-update policy signed by the pinned ring must authenticate")
        }
        XCTAssertEqual(policy.revision, 7)
        XCTAssertEqual(policy.issuedAt, self.iat)
        XCTAssertEqual(policy.expiresAt, self.iat + 86400)
        XCTAssertEqual(policy.ios?.min.text, "12.9.0")
        XCTAssertEqual(policy.ios?.latest.text, "12.10.0")
        XCTAssertEqual(policy.android?.min.text, "12.10.0")
        XCTAssertEqual(policy.android?.latest.text, "12.10.6")
        XCTAssertEqual(policy.token, token, "the exact signed bytes are what gets persisted and re-verified")
    }

    func test_aNullPlatformIsNoConstraintAndRevisionZeroIsTheServerDefault() {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 0, iat: self.iat)
        guard case let .success(policy) = SGAppUpdatePolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            return XCTFail("the absent server row — revision 0, both platforms null — must authenticate")
        }
        XCTAssertEqual(policy.revision, 0)
        XCTAssertNil(policy.ios)
        XCTAssertNil(policy.android)

        let iosOnly = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 1, iat: self.iat, ios: self.versions("12.9.2", "12.9.2"))
        guard case let .success(mixed) = SGAppUpdatePolicyVerifier.authenticate(iosOnly, pinnedKeys: self.pinned) else {
            return XCTFail("one platform constrained, the other null, with min == latest, must authenticate")
        }
        XCTAssertEqual(mixed.ios?.min, mixed.ios?.latest)
        XCTAssertNil(mixed.android)
    }

    // MARK: - Signature, header, compact form

    func test_anUnpinnedKidIsReportedAsUnknown() {
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, kid: "k2099z", iat: self.iat)), .unknownKid("k2099z"))
    }

    func test_anotherKeysSignatureIsRejected() {
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: P256.Signing.PrivateKey(), iat: self.iat)), .badSignature)
    }

    func test_aTamperedConstraintIsABadSignature() {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 1, iat: self.iat, ios: self.versions("1.0", "1.0"))
        var parts = token.split(separator: ".").map(String.init)
        let forged = try! JSONSerialization.data(withJSONObject: SGEntitlementTestAppUpdatePolicy.claims(revision: 1, iat: self.iat, ios: self.versions("99.0", "99.0")), options: [.sortedKeys])
        parts[1] = SGEntitlementTestToken.base64url(forged)
        XCTAssertEqual(self.authenticate(parts.joined(separator: ".")), .badSignature, "an unsigned min must never block anyone")
    }

    func test_onlyTheExactES256JWTHeaderIsAccepted() {
        let claims = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
        let headers: [[String: Any]] = [
            ["alg": "none", "typ": "JWT", "kid": self.kid],
            ["alg": "ES256", "kid": self.kid],
            ["alg": "ES256", "typ": "JWT", "kid": self.kid, "jku": "https://attacker.invalid/keys"]
        ]
        for header in headers {
            XCTAssertEqual(self.authenticate(SGEntitlementTestToken.make(key: self.key, header: header, payload: claims)), .malformed, "header \(header) must not authenticate")
        }
        XCTAssertEqual(self.authenticate("a.b.c"), .malformed, "below the 100-character floor")
    }

    // MARK: - Purpose separation

    func test_aMonetizationTokenIsNeverAnAppUpdatePolicyAndViceVersa() {
        // Same issuer, same ring, same envelope: only the audience and the claim set tell them apart,
        // and each verifier refuses the other's.
        let monetization = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid", revision: 3, iat: self.iat)
        XCTAssertEqual(self.authenticate(monetization), .wrongPurpose, "a monetization policy must never decide whether the app may open")
        let monetizationV2 = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid", revision: 3, iat: self.iat, version: 2, trialDays: 7)
        XCTAssertEqual(self.authenticate(monetizationV2), .wrongPurpose)

        let appUpdate = SGEntitlementTestAppUpdatePolicy.make(key: self.key, revision: 3, iat: self.iat, ios: self.versions("12.9.0", "12.10.0"))
        guard case let .failure(failure) = SGEntitlementPolicyVerifier.authenticate(appUpdate, pinnedKeys: self.pinned) else {
            return XCTFail("an app-update policy must never set the monetization mode")
        }
        XCTAssertEqual(failure, .wrongPurpose)
        XCTAssertEqual(SGEntitlementTokenVerifier.verify(appUpdate, pinnedKeys: self.pinned, boundDeviceId: nil).failureValue, .wrongPurpose, "…nor pass as an entitlement")

        let entitlement = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims())
        XCTAssertEqual(self.authenticate(entitlement), .wrongPurpose, "an entitlement is never an app-update policy")
    }

    func test_theAudienceIssuerAndVersionMustNameThisPolicy() {
        var otherAudience = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
        otherAudience["aud"] = "zenlygram-monetization"
        XCTAssertEqual(self.authenticate(self.token(otherAudience)), .wrongPurpose, "the eight app-policy keys under the monetization audience")
        var otherIssuer = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
        otherIssuer["iss"] = "somebody-else"
        XCTAssertEqual(self.authenticate(self.token(otherIssuer)), .wrongPurpose)
        for version in [0, 2, 3] as [Int64] {
            XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, version: version)), .wrongPurpose, "ver \(version) is a shape this client never declared")
        }
        var stringVersion = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
        stringVersion["ver"] = "1"
        XCTAssertEqual(self.authenticate(self.token(stringVersion)), .wrongPurpose, "ver must be the integer 1")
    }

    func test_anyExtraOrMissingClaimIsAnotherPurpose() {
        for extra in ["mode", "trial_days", "sub", "dev", "ent", "until", "account_ent", "jti", "server_time", "macos", "min", "latest"] {
            var claims = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
            claims[extra] = extra == "ent" || extra == "account_ent" ? ["*"] : "x"
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "an app-update policy with `\(extra)` must not authenticate — unknown claims are never ignored")
        }
        for missing in ["iss", "aud", "ver", "revision", "ios", "android", "iat", "exp"] {
            var claims = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
            claims.removeValue(forKey: missing)
            XCTAssertEqual(self.authenticate(self.token(claims)), .wrongPurpose, "an app-update policy without `\(missing)` must not authenticate")
        }
    }

    // MARK: - The platform objects

    func test_aPlatformObjectMustBeExactlyMinAndLatestStrings() {
        var extraKey = self.versions("12.9.0", "12.10.0")
        extraKey["build"] = 1234
        let invalid: [(String, Any)] = [
            ("an extra key", extraKey),
            ("a missing key", ["min": "12.9.0"]),
            ("renamed keys", ["min_supported": "12.9.0", "latest": "12.10.0"]),
            ("a non-string min", ["min": 12, "latest": "12.10.0"]),
            ("a null latest", ["min": "12.9.0", "latest": NSNull()]),
            ("a bare string", "12.9.2"),
            ("an array", ["12.9.0", "12.10.0"]),
            ("a boolean", true),
            ("a number", 0),
            ("an empty object", [String: Any]())
        ]
        for (what, value) in invalid {
            XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: value)), .invalidClaims, "ios: \(what) must not authenticate")
            XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, android: value)), .invalidClaims, "android: \(what) must not authenticate")
        }
    }

    func test_aVersionOutsideThePatternIsInvalid() {
        for bad in ["12", "v12.9", "12.9.2.1.1", "12..9", ".12.9", "12.9.", "12.9.2-debug", "123456.0", "12.9.2 ", " 12.9.2", "12.9.2\n", "12,9", ""] {
            XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions(bad, "99.0"))), .invalidClaims, "min `\(bad)` must not authenticate")
            XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("0.0", bad))), .invalidClaims, "latest `\(bad)` must not authenticate")
        }
        // The shipped versions pass: versions.json's 12.9.2 and android/gradle.properties' 12.10.6.
        XCTAssertNil(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("12.9.2", "12.9.2"), android: self.versions("12.10.6", "12.10.6"))))
        XCTAssertNil(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("1.2.3.4", "99999.99999.99999.99999"))))
    }

    func test_minAboveLatestIsInvalid() {
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("12.10.0", "12.9.2"))), .invalidClaims)
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, android: self.versions("12.10.7", "12.10.6"))), .invalidClaims)
        XCTAssertNil(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("12.9", "12.9.0"))), "12.9 == 12.9.0: min is not above latest")
    }

    // MARK: - Exact claim types, lifetime, freshness

    func test_claimTypesAndRangesAreExact() {
        let invalid: [(String, Any)] = [
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
            var claims = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
            claims[claim] = value
            XCTAssertEqual(self.authenticate(self.token(claims)), .invalidClaims, "`\(claim)`: \(value) must not authenticate")
        }
        var maximum = SGEntitlementTestAppUpdatePolicy.claims(iat: self.iat)
        maximum["revision"] = 9_007_199_254_740_991 as Int64
        XCTAssertNil(self.authenticate(self.token(maximum)), "2^53-1 is the contract's maximum revision")
    }

    func test_lifetimeMustBePositiveAndAtMostOneDay() {
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, exp: self.iat)), .invalidClaims, "exp must be after iat")
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, exp: self.iat - 1)), .invalidClaims)
        XCTAssertEqual(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, exp: self.iat + 86401)), .invalidClaims, "exp - iat <= 86400")
        XCTAssertNil(self.authenticate(SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, exp: self.iat + 86400)))
        XCTAssertEqual(SGAppUpdatePolicyVerifier.maximumLifetime, SGEntitlementPolicyVerifier.maximumLifetime)
        XCTAssertEqual(SGAppUpdatePolicyVerifier.maximumClockSkew, SGEntitlementPolicyVerifier.maximumClockSkew, "the fetched window is the monetization policy's")
    }

    func test_aFetchedPolicyMustBeInsideTheSkewedWindow() {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, iat: self.iat, ios: self.versions("12.9.0", "12.10.0"))
        let exp = self.iat + 86400
        func fetched(_ now: Int64) -> SGEntitlementPolicyFailure? {
            if case let .failure(failure) = SGAppUpdatePolicyVerifier.verifyFetched(token, pinnedKeys: self.pinned, now: self.at(now)) {
                return failure
            }
            return nil
        }
        XCTAssertNil(fetched(self.iat))
        XCTAssertNil(fetched(self.iat - 300), "iat <= now + 300")
        XCTAssertEqual(fetched(self.iat - 301), .notYetValid)
        XCTAssertNil(fetched(exp + 299), "exp > now - 300")
        XCTAssertEqual(fetched(exp + 300), .expired)
        XCTAssertEqual(fetched(exp + 30 * 86400), .expired)
    }

    func test_aFetchedPolicyIsAuthenticatedBeforeItsTimeIsTrusted() {
        let forgedFresh = SGEntitlementTestAppUpdatePolicy.make(key: P256.Signing.PrivateKey(), iat: self.iat)
        guard case let .failure(failure) = SGAppUpdatePolicyVerifier.verifyFetched(forgedFresh, pinnedKeys: self.pinned, now: self.at(self.iat)) else {
            return XCTFail("a fresh but unsigned-by-us policy must not verify")
        }
        XCTAssertEqual(failure, .badSignature)
    }
}

/// The client-side app-update state: `(revision, iat)` order, idempotence and conflicts, a store
/// slot of its own, re-verification that never re-expires.
final class SGAppUpdatePolicyStateTests: XCTestCase {
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
        self.suiteName = "SGAppUpdatePolicyStateTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suiteName)?.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private func policy(revision: Int64, iat: Int64? = nil, ios: Any = NSNull()) -> String {
        return SGEntitlementTestAppUpdatePolicy.make(key: self.key, kid: self.kid, revision: revision, iat: iat ?? self.iat, ios: ios)
    }

    private func versions(_ min: String, _ latest: String) -> [String: Any] {
        return SGEntitlementTestAppUpdatePolicy.platform(min: min, latest: latest)
    }

    private func accept(_ token: String, into state: SGAppUpdatePolicyState, now: Int64? = nil) -> SGAppUpdatePolicyAcceptance {
        return state.accepting(fetched: token, pinnedKeys: self.pinned, now: Date(timeIntervalSince1970: TimeInterval(now ?? (self.iat + 60))))
    }

    func test_initialHoldsNothing() {
        XCTAssertNil(SGAppUpdatePolicyState.initial.accepted, "nothing accepted: no constraint, nothing shown")
    }

    func test_aNewerRevisionIsAdoptedAndAnOlderOneRejected() {
        let first = self.accept(self.policy(revision: 1, ios: self.versions("12.9.0", "12.10.0")), into: .initial)
        XCTAssertEqual(first.outcome, .adopted)
        XCTAssertEqual(first.state.accepted?.ios?.latest.text, "12.10.0")

        let second = self.accept(self.policy(revision: 2, ios: self.versions("12.10.0", "12.11.0")), into: first.state)
        XCTAssertEqual(second.outcome, .adopted)
        XCTAssertEqual(second.state.accepted?.revision, 2)

        let replay = self.accept(self.policy(revision: 1, iat: self.iat + 3600, ios: self.versions("99.0", "99.0")), into: second.state, now: self.iat + 3600)
        XCTAssertEqual(replay.outcome, .rejected(.older), "a replayed older policy can never re-block anyone")
        XCTAssertEqual(replay.state, second.state)

        let cleared = self.accept(self.policy(revision: 3), into: second.state)
        XCTAssertEqual(cleared.outcome, .adopted, "clearing the constraint is an ordinary newer revision")
        XCTAssertNil(cleared.state.accepted?.ios)
    }

    func test_sameRevisionIsOrderedByIssuance() {
        let first = self.accept(self.policy(revision: 2, iat: self.iat, ios: self.versions("12.9.0", "12.10.0")), into: .initial).state
        let reissued = self.accept(self.policy(revision: 2, iat: self.iat + 10, ios: self.versions("12.9.0", "12.10.1")), into: first, now: self.iat + 60)
        XCTAssertEqual(reissued.outcome, .adopted, "a same-revision re-issue is ordered by its signed iat")
        XCTAssertEqual(reissued.state.accepted?.ios?.latest.text, "12.10.1")
        let stale = self.accept(self.policy(revision: 2, iat: self.iat, ios: self.versions("12.9.0", "12.10.0")), into: reissued.state)
        XCTAssertEqual(stale.outcome, .rejected(.older))
        XCTAssertEqual(stale.state, reissued.state)
    }

    func test_anEqualTupleIsIdempotentForTheSameValuesAndAConflictOtherwise() {
        let accepted = self.accept(self.policy(revision: 3, ios: self.versions("12.9.0", "12.10.0")), into: .initial).state
        // Re-signed (a fresh ECDSA nonce, so different bytes), the same (revision, iat, ios, android).
        let again = self.accept(self.policy(revision: 3, ios: self.versions("12.9.0", "12.10.0")), into: accepted)
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.state, accepted, "the accepted bytes stay")

        let otherLatest = self.accept(self.policy(revision: 3, ios: self.versions("12.9.0", "12.10.6")), into: accepted)
        XCTAssertEqual(otherLatest.outcome, .rejected(.conflictingIssuance))
        XCTAssertEqual(otherLatest.state, accepted, "a conflicting equal tuple must change nothing")
        let otherMin = self.accept(self.policy(revision: 3, ios: self.versions("12.10.0", "12.10.0")), into: accepted)
        XCTAssertEqual(otherMin.outcome, .rejected(.conflictingIssuance))
        let cleared = self.accept(self.policy(revision: 3), into: accepted)
        XCTAssertEqual(cleared.outcome, .rejected(.conflictingIssuance), "null against a constraint under one tuple is a conflict too")
        XCTAssertEqual(cleared.state, accepted)
    }

    func test_anUnverifiableOrExpiredFetchKeepsTheAcceptedPolicy() {
        let accepted = self.accept(self.policy(revision: 1, ios: self.versions("12.9.0", "12.10.0")), into: .initial).state

        let forged = SGEntitlementTestAppUpdatePolicy.make(key: P256.Signing.PrivateKey(), kid: self.kid, revision: 9, iat: self.iat, ios: self.versions("99.0", "99.0"))
        XCTAssertEqual(self.accept(forged, into: accepted).outcome, .rejected(.verification(.badSignature)))
        XCTAssertEqual(self.accept(forged, into: accepted).state, accepted)

        let expired = self.policy(revision: 9, iat: self.iat, ios: self.versions("99.0", "99.0"))
        let late = self.accept(expired, into: accepted, now: self.iat + 86400 + 301)
        XCTAssertEqual(late.outcome, .rejected(.verification(.expired)), "a newer but expired policy is not accepted")
        XCTAssertEqual(late.state, accepted)

        let monetization = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid", revision: 9, iat: self.iat)
        XCTAssertEqual(self.accept(monetization, into: accepted).outcome, .rejected(.verification(.wrongPurpose)))
        XCTAssertEqual(self.accept("not-a-policy", into: .initial).state, .initial)
    }

    func test_freshnessIsFlooredAtTheAcceptedSignedIssuance() {
        let accepted = self.accept(self.policy(revision: 1, iat: self.iat), into: .initial, now: self.iat + 60).state
        let woundBack = Date(timeIntervalSince1970: TimeInterval(self.iat - 10 * 86400))
        let newer = accepted.accepting(fetched: self.policy(revision: 2, iat: self.iat + 120), pinnedKeys: self.pinned, now: woundBack)
        XCTAssertEqual(newer.outcome, .adopted, "a wall clock wound back cannot make a current policy look not yet valid once one was accepted")
        let fresh = SGAppUpdatePolicyState.initial.accepting(fetched: self.policy(revision: 2, iat: self.iat + 120), pinnedKeys: self.pinned, now: woundBack)
        XCTAssertEqual(fresh.outcome, .rejected(.verification(.notYetValid)), "without an accepted policy the wall clock alone decides")
    }

    func test_aRestoredPolicyIsReverifiedButNeverReexpired() {
        let token = self.policy(revision: 4, ios: self.versions("12.9.0", "12.10.0"))
        let restored = SGAppUpdatePolicyState.restoring(stored: token, pinnedKeys: self.pinned)
        XCTAssertEqual(restored.accepted?.revision, 4, "expiry never removes an authenticated constraint: the 30-day valve does (SGAppUpdateDecision)")
        XCTAssertEqual(restored.accepted?.ios?.min.text, "12.9.0")
        XCTAssertEqual(self.accept(self.policy(revision: 3, iat: self.iat + 120), into: restored, now: self.iat + 120).outcome, .rejected(.older), "the order survives a relaunch")
    }

    func test_restoringWithARotatedRingIsInitial() {
        let token = self.policy(revision: 4, ios: self.versions("99.0", "99.0"))
        let rotated = SGEntitlementTestToken.pinned(P256.Signing.PrivateKey(), kid: self.kid)
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: token, pinnedKeys: rotated), .initial, "a stored block under a key the ring no longer holds blocks nothing")
        let otherKid = SGEntitlementTestToken.pinned(self.key, kid: "k2026b")
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: token, pinnedKeys: otherKid), .initial)
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: nil, pinnedKeys: self.pinned), .initial)
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: "garbage", pinnedKeys: self.pinned), .initial)
        let monetization = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid", revision: 4, iat: self.iat)
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: monetization, pinnedKeys: self.pinned), .initial, "the other policy's bytes in this slot are no policy")
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: token, pinnedKeys: self.pinned).accepted?.revision, 4, "premise: the same ring restores it")
    }

    // MARK: - The store slot

    func test_theAppUpdateSlotIsItsOwnScopedKeyBesideTheMonetizationSlot() {
        let defaults = UserDefaults(suiteName: self.suiteName)
        let monetization = SGEntitlementPolicyStore(defaults: defaults).scoped(toOrigin: "https://zenlygram.org")
        let appUpdate = monetization.rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey)
        XCTAssertEqual(monetization.key, "zg.ent.policy.v1@https://zenlygram.org")
        XCTAssertEqual(appUpdate.key, "zg.app.policy.v1@https://zenlygram.org", "the same origin, the app-update layout key")
        XCTAssertEqual(appUpdate.baseKey, "zg.app.policy.v1")
        XCTAssertEqual(SGEntitlementPolicyStore.originKey("https://zenlygram.org", baseKey: SGEntitlementPolicyStore.appUpdateDefaultsKey), appUpdate.key)
        XCTAssertEqual(SGEntitlementPolicyStore(defaults: defaults, baseKey: SGEntitlementPolicyStore.appUpdateDefaultsKey).scoped(toOrigin: "https://zenlygram.org").key, appUpdate.key, "scoping keeps the layout key")
        XCTAssertEqual(SGEntitlementPolicyStore(defaults: defaults, baseKey: SGEntitlementPolicyStore.appUpdateDefaultsKey).key, "zg.app.policy.v1")

        let token = self.policy(revision: 4, ios: self.versions("12.9.0", "12.10.0"))
        XCTAssertTrue(appUpdate.save(token))
        XCTAssertEqual(appUpdate.load(), token, "the exact signed bytes are persisted")
        XCTAssertNil(monetization.load(), "the monetization slot is untouched")
        XCTAssertNil(defaults?.string(forKey: SGEntitlementPolicyStore.defaultsKey))
        XCTAssertNil(defaults?.string(forKey: SGEntitlementPolicyStore.appUpdateDefaultsKey), "the bare key is never written")

        let relaunched = SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.suiteName)).scoped(toOrigin: "https://zenlygram.org").rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey)
        XCTAssertEqual(SGAppUpdatePolicyState.restoring(stored: relaunched.load(), pinnedKeys: self.pinned).accepted?.revision, 4)
        XCTAssertNil(SGEntitlementPolicyStore(defaults: defaults).scoped(toOrigin: "https://zenlygram.org:8443").rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey).load(), "another origin reads nothing")
    }

    func test_theReminderMarkerIsScopedLikeTheSlot() {
        let defaults = UserDefaults(suiteName: self.suiteName)
        let store = SGEntitlementPolicyStore(defaults: defaults).scoped(toOrigin: "https://zenlygram.org").rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey)
        XCTAssertNil(store.loadRemindedLatest())
        store.saveRemindedLatest("12.10.0")
        XCTAssertEqual(store.loadRemindedLatest(), "12.10.0")
        XCTAssertEqual(defaults?.string(forKey: "zg.app.policy.reminded@https://zenlygram.org"), "12.10.0", "the spec's key")
        XCTAssertNil(SGEntitlementPolicyStore(defaults: defaults).scoped(toOrigin: "https://zenlygram.com").rebased(to: SGEntitlementPolicyStore.appUpdateDefaultsKey).loadRemindedLatest(), "another origin's marker")
        store.saveRemindedLatest(nil)
        XCTAssertNil(store.loadRemindedLatest())
        XCTAssertNil(defaults?.object(forKey: "zg.app.policy.reminded@https://zenlygram.org"))
    }
}

/// The version pattern and its component-wise order.
final class SGAppUpdateVersionTests: XCTestCase {
    private func version(_ text: String) -> SGAppUpdateVersion {
        guard let version = SGAppUpdateVersion(text) else {
            XCTFail("premise: `\(text)` is a version")
            return SGAppUpdateVersion("0.0")!
        }
        return version
    }

    func test_thePatternAcceptsTwoToFourNumericComponentsOfAtMostFiveDigits() {
        // versions.json's 12.9.2 and android/gradle.properties' 12.10.6 are versions.
        for good in ["12.9.2", "12.10.6", "0.0", "1.2.3.4", "99999.99999.99999.99999", "01.02"] {
            XCTAssertNotNil(SGAppUpdateVersion(good), good)
            XCTAssertEqual(SGAppUpdateVersion(good)?.text, good, "the text is kept as written")
        }
        XCTAssertEqual(SGAppUpdateVersion("12.9.2")?.components, [12, 9, 2])
        XCTAssertEqual(SGAppUpdateVersion("01.02")?.components, [1, 2])
        for bad in ["12", "v12.9", "12.9.2.1.1", "12..9", ".12.9", "12.9.", "12.9.2-debug", "12.9.2 (1234)", "123456.0", "12.9.2 ", " 12.9.2", "12,9", "", "12.9.２", "1e3.0", "+1.0", "-1.0"] {
            XCTAssertNil(SGAppUpdateVersion(bad), "`\(bad)` is not a version: a decision made from it fails open")
        }
    }

    func test_comparisonIsComponentWiseWithMissingComponentsAsZero() {
        XCTAssertEqual(self.version("12.9"), self.version("12.9.0"))
        XCTAssertEqual(self.version("12.9"), self.version("12.9.0.0"))
        XCTAssertEqual(self.version("12.9").hashValue, self.version("12.9.0").hashValue, "equal versions hash alike")
        XCTAssertLessThan(self.version("12.9.2"), self.version("12.10.0"), "component-wise, never lexicographic on the text")
        XCTAssertLessThan(self.version("12.10.6"), self.version("12.11"))
        XCTAssertGreaterThan(self.version("1.2.3.4"), self.version("1.2.3"))
        XCTAssertLessThan(self.version("1.2.3"), self.version("1.2.3.4"))
        XCTAssertLessThan(self.version("1.99999"), self.version("2.0"))
        XCTAssertLessThan(self.version("12.9.9"), self.version("12.10"))
        XCTAssertFalse(self.version("12.9.0") < self.version("12.9"))
        XCTAssertTrue(self.version("12.9.2") <= self.version("12.9.2"))
        XCTAssertNotEqual(self.version("12.9.2"), self.version("12.9.20"))
    }

    func test_aConstraintNeedsMinAtMostLatest() {
        XCTAssertNotNil(SGAppUpdateVersions(min: self.version("12.9.0"), latest: self.version("12.10.0")))
        XCTAssertNotNil(SGAppUpdateVersions(min: self.version("12.9"), latest: self.version("12.9.0")), "equal (as versions) is allowed")
        XCTAssertNil(SGAppUpdateVersions(min: self.version("12.10.0"), latest: self.version("12.9.2")))
    }
}

/// The decision matrix of §1: fail-open, block with the 30-day valve, one reminder per `latest`,
/// nothing at or above `latest`.
final class SGAppUpdateDecisionTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let iat: Int64 = 1_790_000_000
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    private func policy(ios: Any = NSNull(), android: Any = NSNull(), iat: Int64? = nil) -> SGAppUpdatePolicy {
        let token = SGEntitlementTestAppUpdatePolicy.make(key: self.key, kid: self.kid, revision: 1, iat: iat ?? self.iat, ios: ios, android: android)
        guard case let .success(policy) = SGAppUpdatePolicyVerifier.authenticate(token, pinnedKeys: self.pinned) else {
            XCTFail("premise: the policy authenticates")
            return SGAppUpdatePolicy(revision: 0, issuedAt: 1, expiresAt: 2, ios: nil, android: nil, token: "")
        }
        return policy
    }

    private func versions(_ min: String, _ latest: String) -> [String: Any] {
        return SGEntitlementTestAppUpdatePolicy.platform(min: min, latest: latest)
    }

    private func decide(_ policy: SGAppUpdatePolicy?, installed: String?, reminded: String? = nil, now: Int64? = nil) -> SGAppUpdateDecision {
        return SGAppUpdateDecision.evaluate(policy: policy, installed: installed, remindedLatest: reminded, now: Date(timeIntervalSince1970: TimeInterval(now ?? (self.iat + 60))))
    }

    private func constraint(_ min: String, _ latest: String) -> SGAppUpdateVersions {
        return SGAppUpdateVersions(min: SGAppUpdateVersion(min)!, latest: SGAppUpdateVersion(latest)!)!
    }

    func test_nothingAcceptedShowsNothing() {
        XCTAssertEqual(self.decide(nil, installed: "0.1"), .none, "no policy: fail open")
    }

    func test_noConstraintForThisPlatformShowsNothing() {
        XCTAssertEqual(self.decide(self.policy(), installed: "0.1"), .none, "both null")
        XCTAssertEqual(self.decide(self.policy(android: self.versions("99.0", "99.0")), installed: "0.1"), .none, "Android's constraint never reaches an iPhone")
    }

    func test_anUnreadableInstalledVersionFailsOpen() {
        let blocking = self.policy(ios: self.versions("99.0", "99.0"))
        for installed in ["12.9.2-debug", "12.9.2 (1234)", "unknown", "", "12"] {
            XCTAssertEqual(self.decide(blocking, installed: installed), .none, "`\(installed)` cannot be compared: nothing is shown, however strict the policy")
        }
        XCTAssertEqual(self.decide(blocking, installed: nil), .none, "no CFBundleShortVersionString at all")
    }

    func test_installedBelowMinBlocks() {
        let policy = self.policy(ios: self.versions("12.10.0", "12.10.6"))
        XCTAssertEqual(self.decide(policy, installed: "12.9.2"), .block(self.constraint("12.10.0", "12.10.6")))
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", reminded: "12.10.6"), .block(self.constraint("12.10.0", "12.10.6")), "a reminder already shown never softens a block")
        XCTAssertEqual(self.decide(policy, installed: "12.10"), .remind(latest: SGAppUpdateVersion("12.10.6")!), "12.10 == 12.10.0 == min: supported, so only reminded")
        XCTAssertEqual(self.decide(self.policy(ios: self.versions("12.9.2", "12.9.2")), installed: "12.9.2"), .none, "min == latest == installed: nothing")
    }

    func test_installedBetweenMinAndLatestRemindsOncePerDistinctLatest() {
        let policy = self.policy(ios: self.versions("12.9.0", "12.10.0"))
        let latest = SGAppUpdateVersion("12.10.0")!
        XCTAssertEqual(self.decide(policy, installed: "12.9.2"), .remind(latest: latest))
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", reminded: "12.10.0"), .none, "the reminder for this latest was shown")
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", reminded: "12.10"), .none, "12.10 is the same latest")
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", reminded: "12.9.5"), .remind(latest: latest), "a reminder for an older latest does not count")
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", reminded: "garbage"), .remind(latest: latest))
        let newer = self.policy(ios: self.versions("12.9.0", "12.11"))
        XCTAssertEqual(self.decide(newer, installed: "12.9.2", reminded: "12.10.0"), .remind(latest: SGAppUpdateVersion("12.11")!), "a new latest reminds once more")
    }

    func test_installedAtOrAboveLatestShowsNothing() {
        let policy = self.policy(ios: self.versions("12.9.0", "12.10.0"))
        XCTAssertEqual(self.decide(policy, installed: "12.10.0"), .none)
        XCTAssertEqual(self.decide(policy, installed: "12.10"), .none, "12.10 == 12.10.0")
        XCTAssertEqual(self.decide(policy, installed: "12.10.0.0"), .none)
        XCTAssertEqual(self.decide(policy, installed: "12.10.1"), .none, "a TestFlight or debug build above the store version sees nothing")
        XCTAssertEqual(self.decide(policy, installed: "13.0"), .none)
    }

    func test_aBlockNeverOutlivesThirtyDaysWithoutAFetch() {
        let policy = self.policy(ios: self.versions("12.10.0", "12.10.6"))
        let exp = policy.expiresAt
        XCTAssertEqual(SGAppUpdateDecision.blockValve, 30 * 86400)
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", now: exp - 1), .block(self.constraint("12.10.0", "12.10.6")))
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", now: exp + 30 * 86400), .block(self.constraint("12.10.0", "12.10.6")), "exp >= now - 30 days still blocks")
        XCTAssertEqual(self.decide(policy, installed: "12.9.2", now: exp + 30 * 86400 + 1), .none, "a block whose policy went unrefreshed for 30 days lifts itself")
        XCTAssertEqual(self.decide(policy, installed: "12.10.2", now: exp + 365 * 86400), .remind(latest: SGAppUpdateVersion("12.10.6")!), "the reminder has no valve: it costs the user nothing")
    }
}

/// Two gates: an app-policy attempt never consumes the monetization gate's in-flight slot or its
/// cooldown, and never the purchase slot.
final class SGAppUpdatePolicyGateTests: XCTestCase {
    func test_twoGatesAreIndependent() {
        var monetization = SGEntitlementPolicyRefreshGate()
        var appUpdate = SGEntitlementPolicyRefreshGate()
        XCTAssertTrue(monetization.begin(uptime: 1000))
        XCTAssertTrue(appUpdate.begin(uptime: 1000), "an app-policy attempt beside a monetization request in flight")
        appUpdate.finish()
        XCTAssertFalse(appUpdate.begin(uptime: 1001), "…with a cooldown of its own")
        XCTAssertFalse(monetization.begin(uptime: 1001), "the monetization gate is still in flight")
        monetization.finish()
        XCTAssertTrue(monetization.beginPurchaseAuthorization(uptime: 1002), "the purchase slot is the monetization gate's alone")
        XCTAssertFalse(appUpdate.begin(uptime: 1059))
        XCTAssertTrue(appUpdate.begin(uptime: 1060))
    }
}
