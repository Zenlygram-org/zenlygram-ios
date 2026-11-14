import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import UndoUI
import SGEntitlement
import SGStrings
import SGCustomerSyncCore

// MARK: Zenlygram — the UI half of the entitlement gate.
//
// `SGEntitlement` answers the predicate and knows nothing about controllers (it is linked into the
// Notification Service Extension). This file is the only place that turns a "no" into something a
// user sees, so the three rules of design §4.7 are enforced once instead of at every call site:
//
//  1. A blocked CREATE shows the PAYWALL — never an error alert, never a retry loop, never
//     "contact support", and never a link or call to action to a purchase outside the App Store
//     (guideline 3.1.3(b)).
//  2. A capability the subscription simply does not include (today only `ai`) is `.unavailable`:
//     the feature is HIDDEN, because a paywall there would sell something that would not change
//     the answer.
//  3. Nothing here ever touches reads, un-hides, unlocks or deletes. Those are
//     `SGEntitlementUnrestrictedAction`, they always answer `true`, and they never reach this file.

/// Answers the gate and, when the answer is no, shows the paywall.
///
/// Returns `true` when the caller may proceed with the create. Synchronous and non-blocking: the
/// predicate reads a cached decision, so this is safe on the main thread and inside a context-menu
/// action closure. The server is never consulted here (invariant I1).
public func sgEntitlementGate(
    _ action: SGEntitlementGatedAction,
    context: AccountContext,
    present: (ViewController) -> Void
) -> Bool {
    switch SGEntitlement.gate(action) {
    case .allowed:
        return true
    case .unavailable:
        // The subscription is live and this capability is not in it. There is nothing to sell, so
        // say nothing: a feature in this state must not have had a visible entry point to begin with.
        return false
    case let .blocked(reason):
        sgPresentPayWall(context: context, degradedReason: reason, present: present)
        return false
    }
}

/// The paywall, plus the one-line reason the user is seeing it.
///
/// The reason is shown as a toast rather than folded into the paywall copy: the paywall is upstream
/// Swiftgram's screen (a separate work package) and the degraded reasons differ in kind — "your
/// subscription ended" and "reconnect to restore Pro" must not be flattened into the same sentence.
/// `.noToken` gets no reason toast: a user who never subscribed needs the offer, not an explanation
/// — except once (D9): the first create blocked after the owner enabled paid mode tells this install
/// that Zenlygram Pro is now a subscription (`SGEntitlement.takePaidModeNotice`, once per free ->
/// paid flip). Only the gate calls this, so "a blocked create" is exactly what the notice counts.
public func sgPresentPayWall(
    context: AccountContext,
    degradedReason: SGEntitlementDegradedReason?,
    present: (ViewController) -> Void
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var message: SGEntitlementMessage?
    if let degradedReason {
        if degradedReason == .noToken {
            message = SGEntitlement.shared.takePaidModeNotice(for: degradedReason)
        } else {
            message = SGEntitlement.shared.degradedMessage ?? SGEntitlementMessage.forDegraded(degradedReason)
        }
    }
    if let message {
        present(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil, text: sgEntitlementMessageText(message, presentationData: presentationData), timeout: nil, customUndoText: nil),
                elevatedLayout: false,
                action: { _ in return true }
            )
        )
    }
    guard let payWallController = context.sharedContext.makeSGPayWallController(context: context) else {
        return
    }
    // The paywall's `pro.screen_view` reads this source within 10 s (design 40 §10.2).
    SGAnalytics.notePaywallEntry(.featureGate)
    present(payWallController)
}

/// Renders an `SGEntitlementMessage` with the user's language. The module deliberately carries only
/// the key, so every string stays in `SGStrings` (en + ru + uz).
public func sgEntitlementMessageText(_ message: SGEntitlementMessage, presentationData: PresentationData) -> String {
    return message.localizationKey.i18n(presentationData.strings.baseLanguageCode)
}
