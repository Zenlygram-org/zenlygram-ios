import Foundation

/// Zenlygram — whether this BUILD is able to enforce the subscription at all.
///
/// Enforcement needs a grant path, and a build has exactly two: a verified entitlement JWS, which
/// requires a pinned public key (`sg_config.entitlement_keys`, or the legacy single `public_key`
/// when it parses as P-256), and the local StoreKit fallback, which requires knowing which product
/// ids to look for (`sg_config.iaps`).
///
/// A build carrying **neither** can never grant anything to anyone. Enforcing there would put the
/// paywall in front of Secret Vault, Chat Lock, Tasks and Edit History while the paywall itself has
/// no products to sell — a dead end with no way out, for every simulator build, every build made
/// before App Store Connect exists, and every developer build of this open-source app. That is the
/// exact shape invariant I2 forbids: failing in the direction that punishes the user.
///
/// So a build with no configuration is **unlocked**. A configured build then follows the signed
/// monetization policy (`SGEntitlementPolicy`): free for everyone until the owner deliberately
/// enables paid mode.
///
/// Note what this is NOT: it is not a kill switch, not a debug flag and not something the running
/// app can change. It is a property of the build's own configuration, read once
/// (`SGEntitlementEnforcement.shipped`, SGEntitlementShippedConfiguration.swift).
public struct SGEntitlementEnforcement: Equatable {
    /// At least one pinned key, so a server-issued token can verify.
    public let canVerifyTokens: Bool
    /// At least one product id, so a local App Store subscription can be recognised.
    public let knowsProducts: Bool

    public init(canVerifyTokens: Bool, knowsProducts: Bool) {
        self.canVerifyTokens = canVerifyTokens
        self.knowsProducts = knowsProducts
    }

    /// False only when the build can neither verify a token nor recognise a purchase.
    public var isEnforcing: Bool {
        return self.canVerifyTokens || self.knowsProducts
    }

    /// Enforcement is always on, for tests that are about the evaluation rule itself.
    public static let enforcing = SGEntitlementEnforcement(canVerifyTokens: true, knowsProducts: true)
}
