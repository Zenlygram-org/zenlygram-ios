import Foundation
import SGEntitlement

// Zenlygram — compiled into NON-STORE builds only (update_policy_spec §4h "compiled only when
// !isAppStoreBuild"): `SG_APP_UPDATE_DEBUG_OVERRIDE` is set by `debug_override.bzl` from the build
// configuration's `is_appstore_build`. A store build has no override type, no read of the defaults
// key and no Debug Settings row; the runtime `isAppStoreBuild` argument below stays as the belt.
#if SG_APP_UPDATE_DEBUG_OVERRIDE

/// Zenlygram — the QA override of the app-update DECISION (update_policy_spec §4h), read by non-store
/// builds only, from `SGSimpleSettings.shared.appUpdateDebugOverride`: the Debug Settings row writes
/// it, and `defaults write` sets it before launch (the key, the values and the reset are documented at
/// that property).
///
/// It replaces what the signed policy decided and nothing else: no policy is written, read differently
/// or expired — `zg.app.policy.v1@<origin>` stays exactly what the server signed — and the reminder
/// marker is not written under an override (the marker belongs to a signed `latest`).
public enum SGAppUpdateDebugOverride: String, CaseIterable {
    /// The signed policy decides (the default).
    case none
    /// One "Update available" alert per launch, as if the signed `latest` were `version`.
    case remind
    /// The full-screen "Update required" block, as if the signed `min` were `version`.
    case block

    /// The pretend `min` / `latest` of an override — above any version this app will ship, so the
    /// alert reads "Zenlygram 99.0 is available" and a build above the store version is blocked too.
    public static let version = SGAppUpdateVersion("99.0")!
    static let blockConstraint = SGAppUpdateVersions(min: SGAppUpdateDebugOverride.version, latest: SGAppUpdateDebugOverride.version)!

    /// What QA set — or `.none` for an App Store build (the value is never read) and for anything
    /// that is not one of the three values.
    public static func resolve(raw: String?, isAppStoreBuild: Bool) -> SGAppUpdateDebugOverride {
        guard !isAppStoreBuild, let raw else {
            return .none
        }
        return SGAppUpdateDebugOverride(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .none
    }

    /// The decision under this override.
    public func apply(to decision: SGAppUpdateDecision) -> SGAppUpdateDecision {
        switch self {
        case .none:
            return decision
        case .remind:
            return .remind(latest: SGAppUpdateDebugOverride.version)
        case .block:
            return .block(SGAppUpdateDebugOverride.blockConstraint)
        }
    }
}

#endif
