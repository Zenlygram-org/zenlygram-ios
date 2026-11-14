import Foundation
import SGConfig

// MARK: Zenlygram — what this BUILD ships, read once from `SG_CONFIG`.
//
// Kept apart from the types they configure so the pure core (verification, the policy, the
// evaluator) has no `SGConfig` dependency and runs on the host (`Tests/run-policy-core-tests.sh`).

extension SGEntitlementPinnedKeys {
    /// The keys this build ships. Read once; `SG_CONFIG` is a build constant.
    public static let shipped: SGEntitlementPinnedKeys = {
        var fallback: String?
        if let value = SG_CONFIG.publicKey, SGEntitlementCrypto.p256X963(fromPinnedKey: value) != nil {
            fallback = value
        }
        return SGEntitlementPinnedKeys(keysByKid: SG_CONFIG.entitlementKeys ?? [:], fallbackKey: fallback)
    }()
}

extension SGEntitlementEnforcement {
    /// What this build ships. `SG_CONFIG` is a build constant, so this is read once.
    public static let shipped: SGEntitlementEnforcement = {
        return SGEntitlementEnforcement(
            canVerifyTokens: !SGEntitlementPinnedKeys.shipped.isEmpty,
            knowsProducts: !SG_CONFIG.iaps.isEmpty
        )
    }()
}

extension SGEntitlementPublicPolicyConfiguration {
    /// The explicit public policy this build ships (`public_policy_url` + `public_policy_keys`), or
    /// nil when either is absent or invalid. Read once; never derived from `api_url`,
    /// `entitlement_keys` or `public_key`.
    public static let shipped: SGEntitlementPublicPolicyConfiguration? = SGEntitlementPublicPolicyConfiguration.resolve(SG_CONFIG)

    /// `config`'s explicit public policy, or nil when either field is absent or invalid.
    static func resolve(_ config: SGConfig) -> SGEntitlementPublicPolicyConfiguration? {
        guard let raw = config.publicPolicyUrl, let url = URL(string: raw),
              let endpoint = SGEntitlementPolicyEndpoint(url: url),
              let keys = config.publicPolicyKeys
        else {
            return nil
        }
        return SGEntitlementPublicPolicyConfiguration(endpoint: endpoint, keysByKid: keys)
    }

    /// Whether `sg_config` named `public_policy_url` or `public_policy_keys` at all, valid or not. A
    /// request whose configuration is invalid (`shipped == nil`) still fails closed into the
    /// public-only mode; it never falls back to the legacy policy path.
    public static let isRequested: Bool = SG_CONFIG.publicPolicyRequested
}

extension SGEntitlementClient.Configuration {
    /// Whether this build ships the authenticated entitlement client at all (pinned entitlement keys
    /// AND a valid `api_url` origin). Independent of `configure(...)` having run, so it never
    /// mistakes the startup window for an unconfigured build.
    static let isShipped: Bool = SGEntitlementClient.Configuration.shipped(appVersion: nil, osVersion: nil) != nil

    /// The validated origin of `sg_config.api_url` (`SGEntitlementBackendOrigin`), or nil. Read once.
    static let shippedOrigin: SGEntitlementBackendOrigin? = SGEntitlementBackendOrigin(apiUrl: SG_CONFIG.apiUrl, upstreamDefaultApiUrl: SGConfig.defaultApiUrl)
}

extension SGEntitlementStoreScope {
    /// The namespace this build's origin-bound items live under: the authenticated backend's origin,
    /// or `.unconfigured` for a build without one (no pinned keys or no valid `api_url`). Read once;
    /// the app and every extension derive the same value from the same build constant.
    public static let shipped: SGEntitlementStoreScope = {
        guard SGEntitlementClient.Configuration.isShipped, let origin = SGEntitlementClient.Configuration.shippedOrigin else {
            return .unconfigured
        }
        return .origin(origin)
    }()
}

extension SGEntitlementAppleBackendConfiguration {
    /// What this build ships: `apple_backend_enabled` (false unless JSON `true`) and `iaps`.
    public static let shipped = SGEntitlementAppleBackendConfiguration(isFlagEnabled: SG_CONFIG.appleBackendEnabled, productIds: SG_CONFIG.iaps)
}

/// Zenlygram — the `X-Tasks-Wire` value this BUILD sends on every Tasks request (wf15 §8.2).
///
/// `sg_config.tasks_wire` is a build-time value because a client cannot probe: a server that does not
/// accept the value answers 422 before `device.authenticate` on every request (F1a). BuildConfiguration.py
/// accepts only the integers 4 and 5 and refuses 5 for an App Store build or a build pointed at the
/// production server until the backend that accepts 5 is deployed there (`PRODUCTION_TASKS_WIRE_MAX`,
/// raised in its own reviewed commit, WP-I11; the server is then never rolled back below that deploy).
/// What the server actually spoke is recorded separately, per account, as the numeric `server_wire` meta
/// of the cloud store (`SGTasksCloudOperations.serverWire`).
public enum SGTasksShippedWire {
    /// `SG_CONFIG.tasksWire` clamped to the wires this client speaks, `SGTasksWire.wireRevision` (4, also
    /// for an absent key) ... `SGTasksWire.maximumWire` (5). Read once; `SG_CONFIG` is a build constant.
    public static let requestWire: Int = SGTasksShippedWire.requestWire(for: SG_CONFIG)

    /// `config.tasksWire` clamped to `SGTasksWire.wireRevision ... SGTasksWire.maximumWire`.
    static func requestWire(for config: SGConfig) -> Int {
        return min(max(config.tasksWire, SGTasksWire.wireRevision), SGTasksWire.maximumWire)
    }
}
