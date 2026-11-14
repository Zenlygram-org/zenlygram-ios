import Foundation
import SGProtectedStore

/// Zenlygram — the evaluated entitlement, mirrored into the App Group so the Notification Service
/// Extension can evaluate with NO network call and NO Keychain read (client contract §8).
///
/// It carries no secret: no refresh token, no JWS, no account id. Only the decision and the horizons
/// needed to re-decide it as time passes, so an extension that is woken hours later does not act on
/// a stale "unlocked".
///
/// **Rule 2 of degraded mode applies here and outranks this type:** on any privacy-affecting branch
/// with unknown entitlement state, behave as if the feature is ON. Chat Lock's preview hiding — in
/// the chat list AND in the NSE — is a PRIVACY setting and must keep working regardless of billing,
/// entitlement or token state, *including when this mirror is missing or unreadable*. Nothing in the
/// NSE's hiding path may depend on `read()` succeeding.
public struct SGEntitlementMirror: Codable, Equatable {
    public static let currentVersion = 1

    public var v: Int
    /// The raw capability strings, `"*"` included. The active account's own list, widened by the
    /// device-global capabilities (`SGEntitlementCapability.isDeviceGlobal`) that ANOTHER account on
    /// the install grants — the same union `SGEntitlement.can(_:)` answers in the app, so a free
    /// account in front of a paying one does not hand the extensions a "no" the app does not give
    /// (`SGEntitlement.composeMirror`).
    public var capabilities: [String]
    /// `until`, unix seconds; nil means locked. For `source == "localGrace"` it is the end of the
    /// local 7-day grace (`SGEntitlementLocalGrace.endsAt`), mirrored like any other horizon so the
    /// extension stops capturing when the window closes; for `"storeKit"` it is the snapshot's
    /// expiry plus `SGEntitlementStoreKitSnapshot.renewalAllowance`. When the union widened the
    /// list it is the earliest horizon among the decisions that grant.
    public var until: Int64?
    /// The token horizon, unix seconds; nil when the decision did not come from a token.
    public var exp: Int64?
    public var graceDays: Int
    /// `SGEntitlementSource.rawValue`.
    public var source: String
    /// `SGEntitlementDegradedReason.rawValue`, or nil while unlocked.
    public var degradedReason: String?
    /// When the main app wrote this, by its own clock. Diagnostics only.
    public var updatedAt: Int64
    /// The same composition of the decisions made with the StoreKit fallback WITHHELD (signed
    /// tokens, the local grace and the unconfigured rule only), written in the same write. Used
    /// instead of the fields above while the shared Apple provenance ledger is unreadable
    /// (`state(now:isLedgerReadable:)`), so an extension never keeps a StoreKit-derived grant the
    /// app would no longer give. nil from a writer that predates it.
    public var storeKitWithheld: SGEntitlementMirrorDecision?

    public init(
        v: Int = SGEntitlementMirror.currentVersion,
        capabilities: [String],
        until: Int64?,
        exp: Int64?,
        graceDays: Int,
        source: String,
        degradedReason: String?,
        updatedAt: Int64,
        storeKitWithheld: SGEntitlementMirrorDecision? = nil
    ) {
        self.v = v
        self.capabilities = capabilities
        self.until = until
        self.exp = exp
        self.graceDays = graceDays
        self.source = source
        self.degradedReason = degradedReason
        self.updatedAt = updatedAt
        self.storeKitWithheld = storeKitWithheld
    }

    /// `state(now:)`, unless the shared Apple provenance ledger is unreadable: then the decision with
    /// the StoreKit fallback withheld, and — from a writer that did not mirror one — "unknown"
    /// (`.degraded(.noToken)`), which extensions already treat as unknown, never as a lapse. Nothing
    /// here touches existing data; the privacy rule (hide when unknown) is unchanged.
    public func state(now: Date, isLedgerReadable: Bool) -> SGEntitlementState {
        if isLedgerReadable {
            return self.state(now: now)
        }
        guard let withheld = self.storeKitWithheld else {
            return .degraded(reason: .noToken)
        }
        return withheld.mirror(updatedAt: self.updatedAt).state(now: now)
    }

    /// Re-decides the mirrored state at `now` — the same rule as `SGEntitlementEvaluator`, without
    /// the token: `unlocked ⟺ now < until AND now < exp + grace_days`.
    public func state(now: Date) -> SGEntitlementState {
        guard !self.capabilities.isEmpty else {
            return .degraded(reason: self.reason)
        }
        // Written by a build that carries no entitlement configuration, or while the signed policy
        // is FREE: neither has a horizon, and the extensions must decide exactly what the app does
        // (invariant I2). Such a mirror would otherwise read as a lapse under the token rule below,
        // and free access must never self-expire in an extension while the app is not running.
        if self.source == SGEntitlementSource.unconfigured.rawValue || self.source == SGEntitlementSource.freeAccess.rawValue {
            return .unlocked(capabilities: Set(self.capabilities))
        }
        if let until = self.until {
            guard now < Date(timeIntervalSince1970: TimeInterval(until)) else {
                // A closed local grace is "never subscribed", not "your subscription ended".
                if self.source == SGEntitlementSource.localGrace.rawValue {
                    return .degraded(reason: .noToken)
                }
                return .degraded(reason: .lapsed)
            }
        } else if self.source != SGEntitlementSource.storeKit.rawValue {
            // A token-sourced mirror with no `until` is a lapse. A StoreKit-sourced one legitimately
            // has no horizon to report.
            return .degraded(reason: .lapsed)
        }
        if let exp = self.exp {
            let hardStop = Date(timeIntervalSince1970: TimeInterval(exp)).addingTimeInterval(TimeInterval(self.graceDays) * 86400.0)
            guard now < hardStop else {
                return .degraded(reason: .stale)
            }
        }
        return .unlocked(capabilities: Set(self.capabilities))
    }

    private var reason: SGEntitlementDegradedReason {
        guard let raw = self.degradedReason, let reason = SGEntitlementDegradedReason(rawValue: raw) else {
            return .noToken
        }
        return reason
    }
}

/// The decision fields of a mirror, without the mirror's own nesting (`SGEntitlementMirror
/// .storeKitWithheld`). Re-decided by building an `SGEntitlementMirror` from them, so the rule is
/// the mirror's own, not a copy.
public struct SGEntitlementMirrorDecision: Codable, Equatable {
    public var capabilities: [String]
    public var until: Int64?
    public var exp: Int64?
    public var graceDays: Int
    public var source: String
    public var degradedReason: String?

    public init(_ mirror: SGEntitlementMirror) {
        self.capabilities = mirror.capabilities
        self.until = mirror.until
        self.exp = mirror.exp
        self.graceDays = mirror.graceDays
        self.source = mirror.source
        self.degradedReason = mirror.degradedReason
    }

    func mirror(updatedAt: Int64) -> SGEntitlementMirror {
        return SGEntitlementMirror(capabilities: self.capabilities, until: self.until, exp: self.exp, graceDays: self.graceDays, source: self.source, degradedReason: self.degradedReason, updatedAt: updatedAt)
    }
}

/// Reads and writes the App Group mirror. The main app writes; extensions only read.
public enum SGEntitlementMirrorStore {
    public static let defaultsKey = "zg.ent.mirror.v1"
    /// This build's origin-scoped mirror; the bare `defaultsKey` (`.com` era) is never read, written or removed.
    static let scopedDefaultsKey: String = SGEntitlementStoreScope.shipped.scopedKey(SGEntitlementMirrorStore.defaultsKey)

    private static let defaults: UserDefaults? = UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)

    /// The last mirrored decision, or nil when nothing has been written yet or it does not decode.
    /// A newer `v` is read leniently and used as is: a client that discards it would be stricter than
    /// the build that wrote it, which is the wrong direction (invariant I2).
    public static func read() -> SGEntitlementMirror? {
        guard let data = self.defaults?.data(forKey: self.scopedDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SGEntitlementMirror.self, from: data)
    }

    /// The extension-side entry point: the mirrored decision re-evaluated against the shared clock
    /// mark. Never blocks, never touches the network, and answers `.degraded(.noToken)` when the
    /// mirror is missing — which callers must treat as "unknown", not as "the user un-subscribed".
    ///
    /// It also reads the shared Apple provenance ledger bytes (the same App Group key the app uses):
    /// while they cannot be decoded, the StoreKit fallback grants nothing here either
    /// (`SGEntitlementMirror.state(now:isLedgerReadable:)`), even if the mirror was written before
    /// the ledger became unreadable and the app has not recomputed since.
    public static func evaluate(now: Date? = nil) -> SGEntitlementState {
        return self.evaluate(
            mirror: self.read(),
            storedLedger: self.defaults?.data(forKey: SGEntitlement.appleProvenanceKey),
            now: now ?? SGEntitlementClock.shared.effectiveNow()
        )
    }

    /// `evaluate(now:)` over given bytes: the mirror, and the stored ledger as
    /// `SGEntitlementAppleProvenanceStoredLoad` reads it (absent or decodable: readable).
    static func evaluate(mirror: SGEntitlementMirror?, storedLedger: Data?, now: Date) -> SGEntitlementState {
        guard let mirror else {
            return .degraded(reason: .noToken)
        }
        let isLedgerReadable = !SGEntitlementAppleProvenanceStoredLoad(stored: storedLedger).preservesStoredBytes
        return mirror.state(now: now, isLedgerReadable: isLedgerReadable)
    }

    static func write(_ mirror: SGEntitlementMirror) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(mirror) else {
            return
        }
        self.defaults?.set(data, forKey: self.scopedDefaultsKey)
    }
}

extension SGEntitlementMirrorStore {
    /// The Notification Service side of `SGEntitlement.retainedHistoryCaptureBlockedFlag`: the value
    /// to store in the app-group flag the Postbox replay reads before recording new retained history,
    /// re-decided from the mirror against the shared clock mark — so a paid grant that lapses while
    /// the app is not running stops new capture in the extension's replay too. nil (no mirror yet:
    /// unknown) leaves the stored value alone. Nothing here gates reading retained history.
    public static func retainedHistoryCaptureBlockedFlag(now: Date? = nil) -> Bool? {
        return self.retainedHistoryCaptureBlockedFlag(
            mirror: self.read(),
            storedLedger: self.defaults?.data(forKey: SGEntitlement.appleProvenanceKey),
            now: now ?? SGEntitlementClock.shared.effectiveNow(),
            enforcement: .shipped
        )
    }

    static func retainedHistoryCaptureBlockedFlag(mirror: SGEntitlementMirror?, storedLedger: Data?, now: Date, enforcement: SGEntitlementEnforcement) -> Bool? {
        // A build that carries no entitlement configuration cannot be enforcing (invariant I2).
        guard enforcement.isEnforcing else {
            return false
        }
        let state = self.evaluate(mirror: mirror, storedLedger: storedLedger, now: now)
        return SGEntitlementRetainedHistoryCapture.blockedFlag(
            captureAllowed: state.allows(.createRetainedHistoryRecord),
            isDecisionKnown: mirror != nil
        )
    }
}
