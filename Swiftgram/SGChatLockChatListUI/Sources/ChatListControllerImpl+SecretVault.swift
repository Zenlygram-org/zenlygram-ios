import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import SGSimpleSettings
import SGChatLock
import SGSecretVault

// Zenlygram — Secret Vault glue for ChatListUI (audit batch 3, #12; compiled into ChatListUI; hooks in
// ChatListController.swift are tagged `// SG: Secret Vault`).
//
// The vault list is a `.master` screen pushed above the root chat list and registered with the Chat Lock
// session as the vault's holder; chats opened from it keep it on the stack (`parentGroupId: nil`), so the
// stack is `[Tabs, Vault, Chat]` on iPhone and master `[Tabs, Vault]` + detail `[Chat]` on iPad. Closing the
// vault (resign, background, inactivity, turning it off) evicts all of it at once.

/// The title long-press entry flow: the vault PIN, then the vault list. The prompt and recovery sheet
/// are presented from the visible chat-list host, and the vault list is pushed onto its stack.
/// An open vault with an already attached list is reused without a prompt (`requireVault(.reveal)`),
/// popping to that list. Repeated requests join the one prompt on screen. False when nothing was started.
@discardableResult
func sgSecretVaultRequestOpen(_ controller: ChatListControllerImpl, from host: ViewController) -> Bool {
    // When the user reveals with the secret code, no other entry opens the vault.
    guard !SGSimpleSettings.shared.secretVaultUseSecretCode, SecretVaultManager.shared.isActive else {
        return false
    }
    // SG: Secret Vault — the vault is on, but the credential a prompt would ask for is not on this iPhone
    // (audit #70). Prompting anyway is a dead end nothing can satisfy, so explain and offer a new PIN.
    guard SecretVaultManager.shared.isOperable else {
        return sgProtectionRecoveryPresentVaultLost(controller, from: host)
    }
    ChatLockSession.shared.requireVault(accountPeerId: controller.context.account.peerId, purpose: .reveal, from: host, completion: { [weak controller, weak host] result in
        guard let controller, let host, case .unlocked = result else {
            return
        }
        sgSecretVaultPresentList(controller, from: host)
    })
    return true
}

/// The secret code (the vault PIN typed into search) was verified: open the vault and show its list.
func sgSecretVaultRevealedByCode(_ controller: ChatListControllerImpl) {
    let accountPeerId = controller.context.account.peerId
    ChatLockSession.shared.grantVault(accountPeerId: accountPeerId)
    // grantVault is refused while the session is not configured: then there is no open vault to show.
    guard ChatLockSession.shared.isVaultOpen(accountPeerId: accountPeerId) else {
        return
    }
    sgSecretVaultPresentList(controller, from: controller)
}

/// Pushes the vault list (`.master`) onto `host`'s stack, or pops to the one already in that stack for this
/// account. Only while this account's vault is open: a `.reveal` completion may arrive after the vault closed
/// again (fail closed).
func sgSecretVaultPresentList(_ controller: ChatListControllerImpl, from host: ViewController) {
    let accountPeerId = controller.context.account.peerId
    guard ChatLockSession.shared.isVaultOpen(accountPeerId: accountPeerId) else {
        return
    }
    guard let navigationController = host.navigationController as? NavigationController else {
        return
    }
    if let existing = navigationController.viewControllers.first(where: { candidate in
        guard let candidate = candidate as? ChatListControllerImpl else {
            return false
        }
        return candidate.fenixIsVaultList && candidate.context.account.peerId == accountPeerId
    }) {
        let _ = navigationController.popToViewController(existing, animated: true)
        return
    }
    let vaultController = ChatListControllerImpl(
        context: controller.context,
        location: .chatList(groupId: .root),
        controlsHistoryPreload: false,
        enableDebugActions: false,
        fenixIsVaultList: true
    )
    vaultController.navigationPresentation = .master
    navigationController.pushViewController(vaultController)
}

/// Fail closed: a vault list on screen without an open vault removes itself from its stack. Called from
/// viewDidAppear and from layout updates, so the removal itself runs on the next runloop (never inside a
/// navigation layout pass) after re-checking.
func sgSecretVaultListDidAppear(_ controller: ChatListControllerImpl) {
    guard controller.fenixIsVaultList, !ChatLockSession.shared.isVaultOpen(accountPeerId: controller.context.account.peerId) else {
        return
    }
    DispatchQueue.main.async { [weak controller] in
        guard let controller, !ChatLockSession.shared.isVaultOpen(accountPeerId: controller.context.account.peerId) else {
            return
        }
        guard let navigationController = controller.navigationController as? NavigationController, let index = navigationController.viewControllers.firstIndex(where: { $0 === controller }) else {
            return
        }
        navigationController.setViewControllers(Array(navigationController.viewControllers.prefix(index)), animated: false)
    }
}

/// The navigate call's `parentGroupId`: nil from the vault list, so the vault list stays on the stack.
func sgSecretVaultParentGroupId(_ controller: ChatListControllerImpl, _ defaultValue: EnginePeerGroupId) -> EnginePeerGroupId? {
    return controller.fenixIsVaultList ? nil : defaultValue
}

// MARK: - Reveal by secret code (audit #27 / #73 / #89)

/// Installs the search session's code gate. One gate per search activation, owned by the search node's
/// closures: its per-session state (the settle timer, the memo of already-counted candidates) dies with the
/// search, so nothing about what was typed outlives the session.
///
/// The gate — not this file — decides everything: what is held, what may be checked, and what counts against
/// the search path's own `.vaultSearch` brute-force budget (audit batch 4 round 2: never `.vault`, which the
/// PIN screens depend on). Here it is only wired to the two hooks and to the reveal.
func sgSecretVaultInstallCodeGate(_ controller: ChatListControllerImpl, _ node: ChatListSearchContainerNode) {
    // The vault's own search never reveals anything: it is already inside the vault.
    guard !controller.fenixIsVaultList else {
        return
    }
    let gate = SecretVaultCodeGate(onReveal: { [weak controller] in
        guard let controller else {
            return
        }
        controller.deactivateSearch(animated: true)
        sgSecretVaultRevealedByCode(controller) // SG: Secret Vault — a verified vault proof opens the vault
    })
    node.fenixSearchTextChanged = { text in
        return sgSecretVaultCodeCheck(gate.textChanged(text))
    }
    node.fenixSearchTextSubmitted = { text in
        return sgSecretVaultCodeCheck(gate.textSubmitted(text))
    }
}

private func sgSecretVaultCodeCheck(_ outcome: SecretVaultCodeOutcome) -> ChatListFenixSecretCodeCheck {
    switch outcome {
    case .search:
        return .search
    case .hold:
        return .holdRemote
    case .holdExplained:
        // The user asked for a server search that will not happen: the surface owes them a neutral toast
        // rather than silence (audit batch 4 round 2, defect B).
        return .holdRemoteExplained
    case .revealed:
        return .revealed
    }
}
