import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — which stored entitlement token may sponsor a Tasks create (`SGTasksCreationProof`),
/// against real ES256 tokens and the pinned-key verifier.
final class SGTasksCreationProofTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let owner: Int64 = 1001
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: "k2026a")
    }

    /// A stored session for a CloudUser `peer` (small ids pack to themselves) holding a token with
    /// the given claims.
    private func candidate(
        _ peer: Int64,
        tgid: Int64?? = nil,
        ver: Int = 1,
        iat: Int64 = 1_799_999_000,
        exp: Int64 = 1_800_003_600,
        account: SGEntitlementTestToken.AccountClaims = .explicit(ent: ["tasks"], until: "2030-01-01T00:00:00Z"),
        extra: [String: Any] = [:]
    ) -> SGTasksCreationProof.Candidate {
        var payload = SGEntitlementTestToken.claims(iat: iat, exp: exp, account: account)
        switch tgid {
        case .none:
            payload["tgid"] = peer
        case let .some(value):
            if let value {
                payload["tgid"] = value
            }
        }
        payload["ver"] = ver
        for (name, value) in extra {
            payload[name] = value
        }
        let jws = SGEntitlementTestToken.make(key: self.key, payload: payload)
        return SGTasksCreationProof.Candidate(accountPeerId: peer, material: SGEntitlementSessionMaterial(refreshToken: "r-\(peer)", entitlement: jws, accountId: "01JB8Q", deviceId: "01JB8R"))
    }

    private func select(_ candidates: [SGTasksCreationProof.Candidate]) -> String? {
        return SGTasksCreationProof.select(owner: self.owner, candidates: candidates, pinnedKeys: self.pinned, now: self.now)
    }

    func test_aGenuineTasksGrantOfAnotherAccountSponsors() {
        let sponsor = self.candidate(2002)
        XCTAssertEqual(self.select([sponsor]), sponsor.material.entitlement)
    }

    func test_theOwnerNeverSponsorsItself() {
        XCTAssertNil(self.select([self.candidate(self.owner)]), "B's own rights are the server's first check; its token is not evidence")
    }

    func test_onlyGenuineLiveTasksGrantsQualify() {
        let refused: [(String, SGTasksCreationProof.Candidate)] = [
            ("legacy token without the account pair", self.candidate(2002, account: .omitted)),
            ("grant without tasks", self.candidate(2002, account: .explicit(ent: ["vault"], until: "2030-01-01T00:00:00Z"))),
            ("wildcard is not a genuine grant", self.candidate(2002, account: .explicit(ent: ["*"], until: "2030-01-01T00:00:00Z"))),
            ("grant already ended", self.candidate(2002, account: .explicit(ent: ["tasks"], until: "2027-01-01T00:00:00Z"))),
            ("locked grant", self.candidate(2002, account: .explicit(ent: ["tasks"], until: nil))),
            ("token expired, no offline grace", self.candidate(2002, iat: 1_799_000_000, exp: 1_800_000_000)),
            ("exp not after iat", self.candidate(2002, iat: 1_800_000_100, exp: 1_800_000_100)),
            ("iat more than 300 s ahead", self.candidate(2002, iat: 1_800_000_301, exp: 1_800_009_000)),
            ("unsupported version", self.candidate(2002, ver: 2)),
            ("no tgid (Apple-only)", self.candidate(2002, tgid: .some(nil))),
            ("tgid of another user", self.candidate(2002, tgid: .some(3003))),
            ("policy-purpose token", self.candidate(2002, extra: ["aud": "monetization", "mode": "paid"]))
        ]
        for (name, candidate) in refused {
            XCTAssertNil(self.select([candidate]), name)
        }
        XCTAssertNotNil(self.select([self.candidate(2002, iat: 1_800_000_300, exp: 1_800_009_000)]), "exactly 300 s of lead is tolerated")
    }

    func test_aTokenForAnotherBindingNeverSponsors() {
        let genuine = self.candidate(2002)
        let rebound = SGTasksCreationProof.Candidate(accountPeerId: 2002, material: SGEntitlementSessionMaterial(refreshToken: "r", entitlement: genuine.material.entitlement, accountId: "01JB8Q", deviceId: "01OTHER"))
        XCTAssertNil(self.select([rebound]))
        let unbound = SGTasksCreationProof.Candidate(accountPeerId: 2002, material: SGEntitlementSessionMaterial(refreshToken: "r", entitlement: genuine.material.entitlement))
        XCTAssertNil(self.select([unbound]), "no stored dev/sub to check against")
    }

    func test_theLongestGrantWins() {
        let shorter = self.candidate(2002, account: .explicit(ent: ["tasks"], until: "2029-01-01T00:00:00Z"))
        let longer = self.candidate(3003, account: .explicit(ent: ["tasks", "vault"], until: "2031-01-01T00:00:00Z"))
        XCTAssertEqual(self.select([shorter, longer]), longer.material.entitlement)
        XCTAssertEqual(self.select([longer, shorter]), longer.material.entitlement, "order of discovery does not matter")
        XCTAssertEqual(self.select([self.candidate(2002, account: .omitted), shorter]), shorter.material.entitlement, "one bad candidate does not hide a good one")
    }

    /// A dropped session keeps its cached JWS (`apply` clears only the refresh token). That token
    /// still verifies, but its binding is gone: it must never sponsor, nor outrank a live one.
    private func signedOut(_ candidate: SGTasksCreationProof.Candidate, refreshToken: String? = nil) -> SGTasksCreationProof.Candidate {
        var material = candidate.material
        material.refreshToken = refreshToken
        return SGTasksCreationProof.Candidate(accountPeerId: candidate.accountPeerId, material: material)
    }

    func test_aSignedOutAccountNeverSponsors() {
        let dead = self.signedOut(self.candidate(2002, account: .explicit(ent: ["tasks"], until: "2031-01-01T00:00:00Z")))
        XCTAssertNil(self.select([dead]), "a revoked session's cached JWS is not a currently linked account")
        XCTAssertNil(self.select([self.signedOut(self.candidate(2002), refreshToken: "")]), "an empty token is no session")
        let live = self.candidate(3003, account: .explicit(ent: ["tasks"], until: "2029-01-01T00:00:00Z"))
        XCTAssertEqual(self.select([dead, live]), live.material.entitlement, "the dead account's longer grant does not beat a live shorter one")
        XCTAssertEqual(self.select([live, dead]), live.material.entitlement)
    }
}
