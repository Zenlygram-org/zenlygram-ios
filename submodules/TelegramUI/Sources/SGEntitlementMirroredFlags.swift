import Foundation
import SGEntitlement
import SGSimpleSettings

// MARK: Zenlygram — mirroring the evaluated entitlement into the app-group suite.
//
// `SGEntitlement` mirrors its whole decision for the extensions (`SGEntitlementMirrorStore`). This
// file mirrors the one derived flag a place that cannot link `SGEntitlement` needs: new retained-
// history capture (`createRetainedHistoryRecord`) runs inside `TelegramCore`'s Postbox replay, in
// the app and in the Notification Service, and `TelegramCore` must not pull in a UIKit module.
// The flag only stops NEW capture; reading or removing what was already retained never reads it.
//
// Called once at startup and again on every `SGEntitlement.didChangeNotification`. Nothing here
// touches the network. An unknown decision (no account yet) leaves the stored value alone — see
// `SGEntitlementRetainedHistoryCapture`.
func sgUpdateEntitlementMirroredFlags() {
    guard let blocked = SGEntitlement.shared.retainedHistoryCaptureBlockedFlag else {
        return
    }
    if SGSimpleSettings.shared.editHistoryCaptureBlocked != blocked {
        SGSimpleSettings.shared.editHistoryCaptureBlocked = blocked
    }
}
