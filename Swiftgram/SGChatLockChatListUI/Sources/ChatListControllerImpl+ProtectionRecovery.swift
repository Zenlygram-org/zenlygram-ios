import Foundation
import UIKit
import Display
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils
import SGChatLock

// Zenlygram — protection-recovery surfacing for the chat list (audit batch 4, #70 / #71; compiled into
// ChatListUI; the hook in ChatListController.swift is tagged `// SG: Secret Vault`).
//
// After a restore onto a new iPhone the vault PIN and the per-chat pincodes are simply not there: they are
// `ThisDeviceOnly` keychain items, which neither an encrypted backup nor Quick Start carries over. The core
// detects that (`SGProtectionRecovery`) and keeps the protections ON rather than silently switching them off,
// so nothing is uncovered behind the user's back. This file is the part the user actually sees: one honest
// notice at launch, and a way out of the title-gesture dead end.

private enum SGProtectionRecoveryNotice {
    /// Shown at most once per app run. The acknowledgement in the shared state is what makes it once per
    /// restore; this flag only keeps repeated layout passes from stacking alerts in the same runloop.
    static var didPresent = false
}

/// From `fenixSetupSecretVaultIfNeeded` (viewDidAppear AND containerLayoutUpdated, so it must be idempotent).
/// Explains — once — that the protections have to be set up again on this iPhone, and offers to do it.
func sgProtectionRecoveryPresentIfNeeded(_ controller: ChatListControllerImpl) {
    // Only the main root list: the vault list and the archive are not where this belongs.
    guard !controller.fenixIsVaultList, case .chatList(groupId: .root) = controller.location else {
        return
    }
    guard !SGProtectionRecoveryNotice.didPresent, controller.isNodeLoaded, controller.view.window != nil else {
        return
    }
    let status = ChatPincodeManager.shared.protectionRecoveryStatus()
    guard status.hasUnacknowledged, status.vaultNeedsRecovery || status.chatLockNeedsRecovery else {
        return
    }
    SGProtectionRecoveryNotice.didPresent = true
    // Acknowledged BEFORE presenting: an alert that is dismissed (or a crash while it is up) must not turn
    // into a nag on every launch.
    ChatPincodeManager.shared.acknowledgeProtectionRecovery()

    // The vault comes first when both need recovery; the Chat Lock offer then lives in Settings.
    let target: SGProtectionRecoveryTarget = status.vaultNeedsRecovery ? .vault : .chatLock
    let actionTitle = status.vaultNeedsRecovery ? SGProtectionStrings.setNewVaultPin : SGProtectionStrings.setNewChatLockPin
    let text = SGProtectionStrings.recoveryAlertText(
        vault: status.vaultNeedsRecovery,
        chatLock: status.chatLockNeedsRecovery,
        // Only claim chats became visible again when their membership really was lost.
        hiddenCount: status.vaultMembershipLost ? status.lastKnownVaultMemberCount : 0,
        lockedCount: status.pendingLockedChatCount
    )
    controller.present(textAlertController(context: controller.context, title: SGProtectionStrings.recoveryAlertTitle, text: text, actions: [
        TextAlertAction(type: .genericAction, title: SGProtectionStrings.later, action: {}),
        TextAlertAction(type: .defaultAction, title: actionTitle, action: { [weak controller] in
            guard let controller else {
                return
            }
            sgProtectionRecoveryRunSetNewPin(controller, from: controller, target: target)
        })
    ], actionLayout: .vertical), in: .window(.root))
}

/// The title gesture asked for a vault whose credential is gone: a PIN screen
/// nothing can satisfy would be a dead end, so say what happened and offer a new PIN instead. Presented from the
/// visible `host` that asked. False when there is nothing to recover (then nothing is shown).
@discardableResult
func sgProtectionRecoveryPresentVaultLost(_ controller: ChatListControllerImpl, from host: ViewController) -> Bool {
    let status = ChatPincodeManager.shared.protectionRecoveryStatus()
    guard status.vaultNeedsRecovery else {
        return false
    }
    let title: String
    let text: String
    if status.vaultUnverifiable {
        // A record is there, but nothing left on this iPhone can check it (audit #41): even the right PIN
        // would be refused, so never send the user into a "Wrong code" loop.
        title = SGProtectionStrings.vaultUnverifiableTitle
        text = SGProtectionStrings.vaultUnverifiableText
    } else {
        title = SGProtectionStrings.vaultLostTitle
        text = SGProtectionStrings.vaultLostText(count: status.vaultMembershipLost ? status.lastKnownVaultMemberCount : 0)
    }
    host.present(textAlertController(context: controller.context, title: title, text: text, actions: [
        TextAlertAction(type: .genericAction, title: SGProtectionStrings.later, action: {}),
        TextAlertAction(type: .defaultAction, title: SGProtectionStrings.setNewVaultPin, action: { [weak controller, weak host] in
            guard let controller, let host else {
                return
            }
            sgProtectionRecoveryRunSetNewPin(controller, from: host, target: .vault)
        })
    ], actionLayout: .vertical), in: .window(.root))
    return true
}

/// Device-owner authentication (the old credential no longer exists, so ownership is the only proof left),
/// then the ordinary "set a PIN" screen, then the core replaces what the restore left behind.
private func sgProtectionRecoveryRunSetNewPin(_ controller: ChatListControllerImpl, from host: ViewController, target: SGProtectionRecoveryTarget) {
    ChatLockSession.shared.runSetNewPinRecovery(target, presentationData: controller.presentationData, present: { [weak host] viewController in
        host?.present(viewController, animated: true, completion: nil)
    }, completion: { [weak controller, weak host] result in
        // Zenlygram — audit batch 4: on an iPhone with neither a passcode nor biometrics nothing can be
        // proven, so the flow ends before it presents anything. Saying so is the only way out of the dead
        // end; a cancel needs no word, and a finished recovery already changed the screen underneath.
        guard case .unavailable = result, let controller, let host else {
            return
        }
        host.present(textAlertController(context: controller.context, title: SGProtectionStrings.deviceAuthUnavailableTitle, text: SGProtectionStrings.deviceAuthUnavailableText, actions: [
            TextAlertAction(type: .defaultAction, title: controller.presentationData.strings.Common_OK, action: {})
        ]), in: .window(.root))
    })
}
