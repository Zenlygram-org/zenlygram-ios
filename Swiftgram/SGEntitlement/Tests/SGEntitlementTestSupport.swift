import Foundation
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — mints real ES256 tokens so the verifier is tested against bytes the server could have
/// produced, not against a mock.
enum SGEntitlementTestToken {
    /// The genuine per-account grant (`account_ent` / `account_until`) a token carries.
    enum AccountClaims {
        /// The same values as the legacy `ent` / `until` — what the server mints for an account
        /// whose rights are not widened by the free-mode wildcard.
        case mirrorLegacy
        /// A legacy token minted before the account claims existed.
        case omitted
        case explicit(ent: [String], until: String?)
    }

    static func base64url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func pinned(_ key: P256.Signing.PrivateKey, kid: String) -> SGEntitlementPinnedKeys {
        guard let der = SGEntitlementCrypto.p256SPKI(fromX963: key.publicKey.x963Representation) else {
            return SGEntitlementPinnedKeys(keysByKid: [:])
        }
        return SGEntitlementPinnedKeys(keysByKid: [kid: der.base64EncodedString()])
    }

    static func claims(
        iss: String = "zenlygram",
        dev: String = "01JB8R",
        ent: [String] = ["vault", "chatlock", "tasks", "edithistory"],
        until: String? = "2030-01-01T00:00:00Z",
        graceDays: Int = 14,
        iat: Int64 = 1790000000,
        exp: Int64 = 1790259200,
        account: AccountClaims = .mirrorLegacy
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "iss": iss,
            "sub": "01JB8Q",
            "dev": dev,
            "tier": "pro",
            "ent": ent,
            "grace_days": graceDays,
            "iat": iat,
            "exp": exp,
            "jti": "00000000-0000-0000-0000-000000000000",
            "ver": 1
        ]
        payload["until"] = until ?? NSNull()
        switch account {
        case .mirrorLegacy:
            payload["account_ent"] = ent
            payload["account_until"] = until ?? NSNull()
        case .omitted:
            break
        case let .explicit(accountEnt, accountUntil):
            payload["account_ent"] = accountEnt
            payload["account_until"] = accountUntil ?? NSNull()
        }
        return payload
    }

    static func make(
        key: P256.Signing.PrivateKey,
        kid: String = "k2026a",
        alg: String = "ES256",
        typ: String? = "JWT",
        payload: [String: Any]
    ) -> String {
        var header: [String: Any] = ["alg": alg, "kid": kid]
        if let typ {
            header["typ"] = typ
        }
        return self.make(key: key, header: header, payload: payload)
    }

    /// Signs exactly the given header, for header-strictness tests.
    static func make(key: P256.Signing.PrivateKey, header: [String: Any], payload: [String: Any]) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return self.sign(key: key, headerData: headerData, payloadData: payloadData)
    }

    /// Signs raw payload bytes, for claims that `JSONSerialization` would normalise (a float `ver`).
    static func sign(key: P256.Signing.PrivateKey, headerData: Data, payloadData: Data) -> String {
        let signingInput = "\(self.base64url(headerData)).\(self.base64url(payloadData))"
        let signature = try! key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(self.base64url(signature.rawRepresentation))"
    }
}

/// Zenlygram — real ES256 monetization POLICY tokens (`GET /v1/monetization`, contracts
/// `monetization-policy.v1` / `.v2`), signed with the same pinned ring as the entitlement.
///
/// `version` is what `ver` claims and `trialDays` adds the `trial_days` claim when non-nil; the
/// two are deliberately independent, so the verifier's rejection cases can be minted (v2 keys under
/// `ver: 1`, v1 keys under `ver: 2`). A well-formed v2 token is `version: 2, trialDays: n`; the
/// defaults mint the frozen v1 shape.
enum SGEntitlementTestPolicy {
    static func claims(
        mode: String = "paid",
        revision: Int64 = 1,
        iat: Int64 = 1_790_000_000,
        exp: Int64? = nil,
        version: Int64 = 1,
        trialDays: Int? = nil
    ) -> [String: Any] {
        var claims: [String: Any] = [
            "iss": "zenlygram",
            "aud": "zenlygram-monetization",
            "ver": version,
            "mode": mode,
            "revision": revision,
            "iat": iat,
            "exp": exp ?? (iat + 86400)
        ]
        if let trialDays {
            claims["trial_days"] = trialDays
        }
        return claims
    }

    static func make(
        key: P256.Signing.PrivateKey,
        kid: String = "k2026a",
        mode: String = "paid",
        revision: Int64 = 1,
        iat: Int64 = 1_790_000_000,
        exp: Int64? = nil,
        version: Int64 = 1,
        trialDays: Int? = nil
    ) -> String {
        return SGEntitlementTestToken.make(key: key, kid: kid, payload: self.claims(mode: mode, revision: revision, iat: iat, exp: exp, version: version, trialDays: trialDays))
    }

    /// An accepted state holding `token`, re-verified exactly as a relaunch would.
    static func state(_ token: String, pinned: SGEntitlementPinnedKeys) -> SGEntitlementPolicyState {
        return SGEntitlementPolicyState.restoring(stored: token, pinnedKeys: pinned)
    }
}

/// Zenlygram — real ES256 APP-UPDATE policy tokens (`GET /v1/app-policy`, contract
/// `app-update-policy.v1`), signed with the same pinned ring as the other public policy.
///
/// `ios` / `android` are the platform claims exactly as signed: `NSNull()` (no constraint, the
/// default), a `platform(min:latest:)` object, or any other value a rejection case needs. `version`
/// is what `ver` claims.
enum SGEntitlementTestAppUpdatePolicy {
    static func platform(min: String, latest: String) -> [String: Any] {
        return ["min": min, "latest": latest]
    }

    static func claims(
        revision: Int64 = 1,
        iat: Int64 = 1_790_000_000,
        exp: Int64? = nil,
        ios: Any = NSNull(),
        android: Any = NSNull(),
        version: Int64 = 1
    ) -> [String: Any] {
        return [
            "iss": "zenlygram",
            "aud": "zenlygram-app-policy",
            "ver": version,
            "revision": revision,
            "ios": ios,
            "android": android,
            "iat": iat,
            "exp": exp ?? (iat + 86400)
        ]
    }

    static func make(
        key: P256.Signing.PrivateKey,
        kid: String = "k2026a",
        revision: Int64 = 1,
        iat: Int64 = 1_790_000_000,
        exp: Int64? = nil,
        ios: Any = NSNull(),
        android: Any = NSNull(),
        version: Int64 = 1
    ) -> String {
        return SGEntitlementTestToken.make(key: key, kid: kid, payload: self.claims(revision: revision, iat: iat, exp: exp, ios: ios, android: android, version: version))
    }
}

// The macOS host suite (`run-policy-core-tests.sh`) compiles this file against the PURE core, which
// has no `SGEntitlementStore` and no `SGProtectedStore`; every Bazel target builds the full module,
// whose `SGProtectedStore` dependency is always importable there.
#if canImport(SGProtectedStore)
/// A store of the test's own: an owned defaults suite, and a Keychain that answers
/// `errSecMissingEntitlement`, so every write takes the store's keychainless fallback and its real
/// read-back verification (the simulator is a keychainless build). Two stores on the same suite are
/// two launches of the same install.
enum SGEntitlementOwnedStore {
    static func make(suiteName: String, scope: SGEntitlementStoreScope = .unconfigured) -> SGEntitlementStore {
        return SGEntitlementStore(
            defaults: UserDefaults(suiteName: suiteName),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            ),
            scope: scope
        )
    }
}
#endif
