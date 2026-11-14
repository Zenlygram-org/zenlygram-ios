import Foundation

/// Zenlygram — the one entitlement decision the Postbox replay needs, reduced to the app-group flag
/// it reads (`SGSimpleSettings.editHistoryCaptureBlocked`).
///
/// Capture runs inside `TelegramCore`, on the Postbox queue, in the app and in the Notification
/// Service, and `TelegramCore` cannot link this module. So the main app (`SGEntitlement.can`) and the
/// Notification Service (the App Group mirror) both reduce `createRetainedHistoryRecord` to this
/// flag with the same rule. It only ever stops NEW capture: nothing reads it on the path that shows
/// or removes history that was already retained.
///
/// The stored sense is "BLOCKED", so an absent key, an unreadable suite and a device before first
/// unlock all read `false` = capture allowed: an unknown decision keeps the free-first behaviour.
public enum SGEntitlementRetainedHistoryCapture {
    /// The value to store, or nil to leave the stored value alone.
    ///
    /// Allowed is always written (`false`): unblocking is never wrong in free mode, and in paid mode
    /// it is exactly the grant. A refusal is written (`true`) only when the decision is the user's —
    /// an account is known in the app, a mirror exists in an extension. "No account yet" is the
    /// first moments of a launch, when every Telegram-bot / Atmos payer still reads `.noToken`.
    public static func blockedFlag(captureAllowed: Bool, isDecisionKnown: Bool) -> Bool? {
        if captureAllowed {
            return false
        }
        return isDecisionKnown ? true : nil
    }
}
