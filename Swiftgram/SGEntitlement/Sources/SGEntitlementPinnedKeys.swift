import Foundation

/// Zenlygram — the entitlement signing keys, pinned in the build (design §4.6).
///
/// **There is no JWKS endpoint and there must never be one.** Fetching keys over the network turns a
/// TLS compromise or a DNS takeover into full entitlement forgery. Two keys ship in every build —
/// the currently active one and the next one — so a server-side key rotation lands without an App
/// Store release, and both `kid`s verify during the overlap.
///
/// Source: `SG_CONFIG.entitlementKeys` (`sg_config.entitlement_keys`, a `kid -> PEM` map). A config
/// that predates the map may carry a single `sg_config.public_key`; it is then used for ANY `kid`,
/// because a one-key config cannot say which kid it is. As soon as `entitlement_keys` is non-empty
/// it is authoritative and an unlisted `kid` is unknown.
///
/// **`public_key` only counts when it parses as a P-256 key.** That slot is not a dormant legacy
/// field in this fork: `SGIQTP` reads the SAME `sg_config.public_key` as a Curve25519/Ed25519 key
/// for the inline-query token protocol, so a production config that keeps inline queries working
/// MUST carry it — and a 32-byte Ed25519 key is not an entitlement trust anchor. Counting it anyway
/// made `isEmpty` false, which brought the transport live against whatever `api_url` said (upstream
/// Swiftgram's host, by default) and then failed every token as `.malformed`. One `p256X963` parse
/// keeps the two algorithms from sharing a trust decision.
public struct SGEntitlementPinnedKeys: Equatable {
    /// `kid` -> PEM or base64 SPKI DER.
    public let keysByKid: [String: String]
    /// The legacy single-key slot, used only while `keysByKid` is empty.
    public let fallbackKey: String?

    public init(keysByKid: [String: String], fallbackKey: String? = nil) {
        self.keysByKid = keysByKid
        self.fallbackKey = fallbackKey
    }

    public var isEmpty: Bool {
        return self.keysByKid.isEmpty && self.fallbackKey == nil
    }

    public func value(forKid kid: String) -> String? {
        if let value = self.keysByKid[kid] {
            return value
        }
        if self.keysByKid.isEmpty {
            return self.fallbackKey
        }
        return nil
    }
}
