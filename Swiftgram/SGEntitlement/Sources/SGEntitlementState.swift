import Foundation

/// Zenlygram — why the app is in degraded mode (design §4.7, client contract §5.1).
///
/// Degraded mode renders identically for every reason; the reason changes only the MESSAGE.
public enum SGEntitlementDegradedReason: String, CaseIterable, Hashable {
    /// Nothing granting and nothing to explain: never bound, or logged out, and no local App Store
    /// subscription either — or bound with a genuine grant whose `account_until` is null (D9). The
    /// server collapses "never paid" and "a horizon already past" to the same null, so a null
    /// horizon is never rendered as "your subscription ended" (`SGEntitlementEvaluator`).
    case noToken
    /// The token verifies and says the subscription ended: `account_until` is a date already past.
    /// A null `account_until` is `.noToken`, not a lapse (D9).
    case lapsed
    /// The token verifies but we have been offline past `exp + grace_days`. NOT "your subscription
    /// ended" — the correct copy is "reconnect to restore Pro".
    case stale
    /// Signature / kid / issuer / `dev` check failed. Rendered as `.stale`.
    case unverifiable
    /// Reserved by the client contract (§5.1). `SGEntitlementEvaluator` never returns it: a
    /// locally-verified App Store subscription with no JWS evaluates to `.unlocked` with
    /// `source == .storeKit`, because a paying user must not be in degraded mode (invariant I2).
    case provisional
}

/// Where the current decision came from. Informational — never a gate.
public enum SGEntitlementSource: String, CaseIterable, Hashable {
    /// No material at all.
    case none
    /// A verified entitlement JWS.
    case token
    /// `storeKitFallback()`: an App Store subscription StoreKit verified locally, with no JWS yet
    /// (the "bought before linking Telegram" hole, client contract §5.1.1).
    case storeKit
    /// This BUILD carries no entitlement configuration, so there is nothing to enforce. See
    /// `SGEntitlementEnforcement`.
    case unconfigured
    /// The local grace after first launch (`SGEntitlementLocalGrace`): a configured build, no
    /// token and no StoreKit subscription granting, inside the window — whose length is the
    /// accepted signed policy's `local_grace_days` (seven days where the policy cannot say). The
    /// paywall / status UI shows "free until `SGEntitlement.localGraceEndsAt`" for this source.
    /// Never the source under a 0-day policy: that grace never grants.
    case localGrace
    /// The signed monetization policy is FREE (`SGEntitlementPolicy`, the initial mode of every
    /// install): the four shipped capabilities for everyone, with no horizon of its own and no
    /// countdown. Not a subscription, and never `ai`. A genuine paid grant still exists alongside it
    /// (`SGEntitlementClaims.accountGrant`) and resumes granting if paid mode is enabled.
    case freeAccess
}

/// Zenlygram — the evaluated entitlement (client contract §5.1).
public enum SGEntitlementState: Equatable {
    case unlocked(capabilities: Set<String>)
    case degraded(reason: SGEntitlementDegradedReason)

    public var isUnlocked: Bool {
        if case .unlocked = self {
            return true
        }
        return false
    }

    public var degradedReason: SGEntitlementDegradedReason? {
        if case let .degraded(reason) = self {
            return reason
        }
        return nil
    }

    /// The raw capability strings. `["*"]` is possible and means everything.
    public var capabilities: Set<String> {
        if case let .unlocked(capabilities) = self {
            return capabilities
        }
        return []
    }

    public func has(_ capability: SGEntitlementCapability) -> Bool {
        guard case let .unlocked(capabilities) = self else {
            return false
        }
        // A capability this build refuses is refused even under the `"*"` escape hatch: `ai`
        // changes what leaves the device, and no server string may do that to a shipped binary
        // whose privacy disclosure says otherwise. See `SGEntitlementCapability.refusedByThisBuild`.
        if SGEntitlementCapability.refusedByThisBuild.contains(capability) {
            return false
        }
        return capabilities.contains(SGEntitlementCapability.wildcard) || capabilities.contains(capability.rawValue)
    }

    /// The pure per-decision answer for a CREATE, before the device-wide union `SGEntitlement.can(_:)`
    /// adds on top. Exists so the rule can be tested without the Keychain.
    public func allows(_ action: SGEntitlementGatedAction) -> Bool {
        return self.has(action.capability)
    }
}

/// The answer to `SGEntitlement.gate(_:)`: `can(_:)` with the reason the paywall needs for its copy.
public enum SGEntitlementGateResult: Equatable {
    case allowed
    /// The subscription is not currently granting anything: show the PAYWALL — never an error, never
    /// a retry loop, never "contact support", and never a purchase link that leaves the App Store.
    case blocked(reason: SGEntitlementDegradedReason)
    /// The subscription IS live, and this capability is simply not granted here. Today that means
    /// exactly one thing: the AI Assistant, which this build refuses
    /// (`SGEntitlementCapability.refusedByThisBuild`). Hide the feature; do NOT show a paywall,
    /// because buying again would not change the answer.
    case unavailable

    public var isAllowed: Bool {
        return self == .allowed
    }
}

/// Zenlygram — every user-visible message this module can ask a surface to show.
///
/// The module itself renders nothing and holds no literal user-facing text: it names a key in
/// `Swiftgram/SGStrings` (en + ru + uz) and the UI resolves it with `key.i18n(lang)`. None of these
/// strings may contain, or lead to, a purchase outside the App Store (guideline 3.1.3(b)).
public enum SGEntitlementMessage: Equatable, Hashable {
    /// `.noToken` — "Link your Telegram account", next to the purchase options.
    case notLinked
    /// `.lapsed` — "Your subscription ended".
    case subscriptionEnded
    /// D9 — "Zenlygram Pro is now a subscription": the one-time notice the first CREATE blocked
    /// after the owner enabled paid mode shows a never-subscribed user, once per free -> paid flip
    /// that reached this install (`SGEntitlement.takePaidModeNotice`). Not a reason copy: `.noToken`
    /// itself stays silent.
    case paidModeNotice
    /// `.stale` / `.unverifiable` — "Reconnect to restore Pro". NOT "your subscription ended".
    case reconnectToRestore
    /// A persistent unknown `kid`: this build is too old to verify the server's current key.
    case updateTheApp
    /// `clock_skew` that survived one re-signed retry.
    case checkDateAndTime
    /// The session-loss 401 family. Never a forced modal, never on launch.
    case signInAgain
    /// `refresh_reuse` — security-flavoured wording.
    case signedOutForSecurity
    /// `503 bind_paused`. Never mentions billing.
    case linkingUnavailable
    /// `state: "denied"`.
    case linkingDeclined
    /// `state: "expired"`, or the countdown reached zero.
    case linkingCodeExpired
    /// `state: "consumed"`, or a poll that timed out after the server consumed the row.
    case linkingDidNotGoThrough
    /// `merge_conflict: true`. Non-blocking: the sign-in SUCCEEDED.
    case linkingMergeConflict
    /// Transport failure on a user-initiated action.
    case noConnection
    /// `429` on a user-initiated action.
    case tooManyAttempts
    /// `409 trial_already_used`.
    case trialAlreadyUsed
    /// `409 trial_device_cap`.
    case trialDeviceCap
    /// `409 trial_device_blocked`.
    case trialDeviceBlocked
    /// `503 trial_paused`.
    case trialUnavailable
    /// `409 trial_disabled`, and `SGIAP.startServerTrial`'s own guard when the signed policy names
    /// no `trial_days`: the server's trial is not on offer right now. Its own copy — not
    /// `.trialUnavailable`, whose "temporarily unavailable" names an outage.
    case trialNotOffered
    /// `409 apple_subscription_conflict` / `401 apple_jws_invalid`: a human has to look at it.
    case purchaseNeedsHelp
    /// `5xx` and anything else generic on a user-initiated action.
    case temporarilyUnavailable

    public var localizationKey: String {
        switch self {
        case .notLinked:
            return "Entitlement.Message.NotLinked"
        case .subscriptionEnded:
            return "Entitlement.Message.SubscriptionEnded"
        case .paidModeNotice:
            return "Entitlement.Message.PaidModeNotice"
        case .reconnectToRestore:
            return "Entitlement.Message.ReconnectToRestore"
        case .updateTheApp:
            return "Entitlement.Message.UpdateTheApp"
        case .checkDateAndTime:
            return "Entitlement.Message.CheckDateAndTime"
        case .signInAgain:
            return "Entitlement.Message.SignInAgain"
        case .signedOutForSecurity:
            return "Entitlement.Message.SignedOutForSecurity"
        case .linkingUnavailable:
            return "Entitlement.Message.LinkingUnavailable"
        case .linkingDeclined:
            return "Entitlement.Message.LinkingDeclined"
        case .linkingCodeExpired:
            return "Entitlement.Message.LinkingCodeExpired"
        case .linkingDidNotGoThrough:
            return "Entitlement.Message.LinkingDidNotGoThrough"
        case .linkingMergeConflict:
            return "Entitlement.Message.LinkingMergeConflict"
        case .noConnection:
            return "Entitlement.Message.NoConnection"
        case .tooManyAttempts:
            return "Entitlement.Message.TooManyAttempts"
        case .trialAlreadyUsed:
            return "Entitlement.Message.TrialAlreadyUsed"
        case .trialDeviceCap:
            return "Entitlement.Message.TrialDeviceCap"
        case .trialDeviceBlocked:
            return "Entitlement.Message.TrialDeviceBlocked"
        case .trialUnavailable:
            return "Entitlement.Message.TrialUnavailable"
        case .trialNotOffered:
            return "Entitlement.Message.TrialNotOffered"
        case .purchaseNeedsHelp:
            return "Entitlement.Message.PurchaseNeedsHelp"
        case .temporarilyUnavailable:
            return "Entitlement.Message.TemporarilyUnavailable"
        }
    }

    /// The copy a degraded surface shows next to the purchase options.
    public static func forDegraded(_ reason: SGEntitlementDegradedReason) -> SGEntitlementMessage {
        switch reason {
        case .noToken:
            return .notLinked
        case .lapsed:
            return .subscriptionEnded
        case .stale, .unverifiable, .provisional:
            return .reconnectToRestore
        }
    }
}
