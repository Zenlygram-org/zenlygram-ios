import Foundation
import CryptoKit

/// Zenlygram — why a token did not verify (client contract §4.2).
public enum SGEntitlementTokenFailure: Error, Equatable, Hashable {
    /// Not three segments, not base64url, not decodable JSON, or not an ES256 JWT header.
    case malformed
    /// The `kid` is not one of the pinned keys. **Not a forgery signal** — it is usually an old
    /// build meeting a rotated key. Keep the last token that did verify and keep evaluating it.
    case unknownKid(String)
    case badSignature
    case wrongIssuer
    /// Minted for another binding (design §7 row 4).
    case foreignDevice
    /// Authentic, but issued to a different account than the session accepting it.
    case foreignAccount
    /// Authentic, but minted for another PURPOSE: the monetization policy (`aud` / `mode`) is signed
    /// by the same key ring and must never be read as an entitlement, which its lenient decoding
    /// would otherwise do for an unbound install.
    case wrongPurpose
}

/// Zenlygram — ES256 verification of the entitlement JWS against the pinned public keys.
///
/// Verification answers "is this authentic". It deliberately does NOT look at `exp` or `until` —
/// `SGEntitlementEvaluator` answers "what does it grant now". Keeping the two apart is what lets an
/// expired token still feed the grace window and the clock high-water mark.
public enum SGEntitlementTokenVerifier {
    private static let cacheLock = NSLock()
    private static var keyCache: [String: P256.Signing.PublicKey] = [:]

    public static func verify(
        _ jws: String,
        pinnedKeys: SGEntitlementPinnedKeys,
        boundDeviceId: String?,
        boundAccountId: String? = nil,
        accountPeerId: Int64? = nil
    ) -> Result<SGEntitlementClaims, SGEntitlementTokenFailure> {
        // 1. Exactly three segments: two dots, no more, no less.
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return .failure(.malformed)
        }

        // 2. base64url, no padding on the wire.
        guard let headerData = SGEntitlementCrypto.base64urlDecode(String(parts[0])),
              let payloadData = SGEntitlementCrypto.base64urlDecode(String(parts[1])),
              let signatureData = SGEntitlementCrypto.base64urlDecode(String(parts[2])),
              let header = try? JSONDecoder().decode(SGEntitlementTokenHeader.self, from: headerData)
        else {
            return .failure(.malformed)
        }

        // 3. Pin ES256. `alg` never selects the algorithm, and "none" is rejected like anything else.
        guard header.alg == "ES256", header.typ == nil || header.typ == "JWT" else {
            return .failure(.malformed)
        }

        // 4. `kid` selects the pinned key.
        guard let pinned = pinnedKeys.value(forKid: header.kid) else {
            return .failure(.unknownKid(header.kid))
        }
        guard let key = self.publicKey(kid: header.kid, pinned: pinned) else {
            return .failure(.malformed)
        }

        // 5. JOSE form: exactly 64 bytes of fixed-width r||s.
        guard signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        else {
            return .failure(.badSignature)
        }

        // 6. The signed material is the ASCII of the ORIGINAL encoded segments, never a
        //    re-serialisation of the decoded JSON. `isValidSignature` hashes with SHA-256 itself.
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            return .failure(.badSignature)
        }

        // 7. Purpose, then claims. A policy token (`SGEntitlementPolicy`) carries `aud` and `mode`;
        //    no entitlement token ever does.
        guard let object = (try? JSONSerialization.jsonObject(with: payloadData, options: [])) as? [String: Any] else {
            return .failure(.malformed)
        }
        if object["aud"] != nil || object["mode"] != nil {
            return .failure(.wrongPurpose)
        }
        guard let claims = try? JSONDecoder().decode(SGEntitlementClaims.self, from: payloadData) else {
            return .failure(.malformed)
        }
        guard claims.iss == SGEntitlementClaims.expectedIssuer else {
            return .failure(.wrongIssuer)
        }

        // 8. A token minted for another binding is not ours.
        if let boundDeviceId, !boundDeviceId.isEmpty, claims.dev != boundDeviceId {
            return .failure(.foreignDevice)
        }
        if let boundAccountId, !boundAccountId.isEmpty, claims.sub != boundAccountId {
            return .failure(.foreignAccount)
        }
        // Apple-only tokens legitimately omit `tgid`. When it is present, however, it must name
        // the Telegram account this session belongs to, not whichever account confirmed in the bot.
        if let accountPeerId, let telegramUserId = claims.tgid, telegramUserId != SGEntitlementAccountIdentity.telegramUserId(accountPeerId: accountPeerId) {
            return .failure(.foreignAccount)
        }

        return .success(claims)
    }

    /// Parsed keys are cached by `kid`: verification runs on every refresh and on every cache
    /// invalidation, and re-deriving the point each time is pure waste.
    private static func publicKey(kid: String, pinned: String) -> P256.Signing.PublicKey? {
        self.cacheLock.lock()
        if let cached = self.keyCache[kid] {
            self.cacheLock.unlock()
            return cached
        }
        self.cacheLock.unlock()

        guard let point = SGEntitlementCrypto.p256X963(fromPinnedKey: pinned),
              let key = try? P256.Signing.PublicKey(x963Representation: point)
        else {
            return nil
        }
        self.cacheLock.lock()
        self.keyCache[kid] = key
        self.cacheLock.unlock()
        return key
    }

    /// Tests only: the cache is keyed by `kid`, and a test that reuses a `kid` with a different key
    /// would otherwise verify against the first one.
    static func resetKeyCacheForTesting() {
        self.cacheLock.lock()
        self.keyCache.removeAll()
        self.cacheLock.unlock()
    }
}
