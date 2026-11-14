import Foundation

/// Zenlygram — which entitlement JWS, if any, travels as `creation_proof.jws` on a `list.create` /
/// `task.create` (`x-creation-proof.native` / `native_cloud_state` / `token_purpose`).
///
/// The owner B is decided by the server alone: a linked B whose own current capabilities allow
/// Tasks creates with no proof at all. The proof only lets ANOTHER account A signed in on this
/// install sponsor the create, so it is chosen fresh immediately before each attempt, never stored,
/// and attached whenever a genuine sponsor exists — a locally cached free policy is no reason to
/// leave one out, and its absence never makes the request fail locally.
///
/// A candidate qualifies only while it is a CURRENTLY linked account — a non-empty stored refresh
/// token. A session drop (`invalid_token`, `device_revoked`, `refresh_reuse`, ...) clears only the
/// refresh token and deliberately keeps the cached JWS; that JWS must never sponsor. Beyond that, a
/// candidate needs a stored per-account entitlement token that:
/// - verifies against the pinned keys as an ENTITLEMENT token (ES256, pinned `kid`, issuer, purpose —
///   never the monetization policy token) for that account's own stored binding `dev` / `sub`;
/// - is `ver` 1, names the account's own Telegram user in `tgid`, and is live: `iat < exp`,
///   `now < exp` (no offline grace) and `iat` at most 300 s ahead of now;
/// - carries a GENUINE account grant (`account_ent` / `account_until`) that includes `tasks` and has
///   not ended. The legacy `ent` / `until`, which the server widens while free, is never sponsor
///   evidence, and the wildcard is already dropped from the account grant.
/// Among qualifying candidates the one whose grant lasts longest wins (then the later `exp`, then
/// the lower peer id, so the choice is deterministic).
enum SGTasksCreationProof {
    static let maxJWSLength = 32768
    static let maxIssuedAtLead: TimeInterval = 300
    static let supportedTokenVersion = 1

    struct Candidate {
        let accountPeerId: Int64
        let material: SGEntitlementSessionMaterial
    }

    static func select(owner: Int64, candidates: [Candidate], pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> String? {
        var best: (jws: String, until: Date, exp: Int64, peer: Int64)?
        for candidate in candidates where candidate.accountPeerId != owner {
            guard let qualified = self.qualify(candidate, pinnedKeys: pinnedKeys, now: now) else {
                continue
            }
            if let current = best {
                let better = qualified.until > current.until
                    || (qualified.until == current.until && qualified.exp > current.exp)
                    || (qualified.until == current.until && qualified.exp == current.exp && candidate.accountPeerId < current.peer)
                guard better else {
                    continue
                }
            }
            best = (qualified.jws, qualified.until, qualified.exp, candidate.accountPeerId)
        }
        return best?.jws
    }

    private static func qualify(_ candidate: Candidate, pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> (jws: String, until: Date, exp: Int64)? {
        let material = candidate.material
        guard let refreshToken = material.refreshToken, !refreshToken.isEmpty,
              let jws = material.entitlement, !jws.isEmpty, jws.utf8.count <= self.maxJWSLength,
              let deviceId = material.deviceId, !deviceId.isEmpty,
              let accountId = material.accountId, !accountId.isEmpty,
              let telegramUserId = SGEntitlementAccountIdentity.telegramUserId(accountPeerId: candidate.accountPeerId),
              case let .success(claims) = SGEntitlementTokenVerifier.verify(jws, pinnedKeys: pinnedKeys, boundDeviceId: deviceId, boundAccountId: accountId, accountPeerId: candidate.accountPeerId)
        else {
            return nil
        }
        guard claims.ver == self.supportedTokenVersion,
              claims.tgid == telegramUserId,
              claims.sub == accountId, claims.dev == deviceId,
              claims.exp > claims.iat,
              now < claims.expiresAtDate,
              claims.issuedAtDate <= now.addingTimeInterval(self.maxIssuedAtLead),
              let grant = claims.accountGrant, grant.capabilities.contains(SGEntitlementCapability.tasks.rawValue),
              let until = grant.untilDate, until > now
        else {
            return nil
        }
        return (jws, until, claims.exp)
    }
}
