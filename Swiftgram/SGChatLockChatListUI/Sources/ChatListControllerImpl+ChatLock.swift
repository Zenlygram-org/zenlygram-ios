import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGChatLock

// Zenlygram — Chat Lock glue for ChatListUI (compiled into ChatListUI; hooks in ChatListController.swift
// are tagged `// SG: Chat Lock`).

private final class SGChatLockDisposableHolder {
    static var associatedKey: UInt8 = 0
    /// SG: Secret Vault — the vault list's `registerVaultScreen` registration.
    static var vaultScreenAssociatedKey: UInt8 = 0

    let disposable: Disposable

    init(_ disposable: Disposable) {
        self.disposable = disposable
    }

    deinit {
        self.disposable.dispose()
    }
}

/// From loadDisplayNode, right after the display node exists.
/// - A forum / monoforum topic list of a locked peer is a screen of that chat's content: it gets the
///   backstop gate (a covered peek when previewing, a prompt when pushed). This covers every forum push
///   (navigateToChatController, navigateToForumChannel, openPeer) and every forum peek.
/// - The root chat list collapses a locked forum shown inline when the session relocks.
func sgChatLockListDidLoad(_ controller: ChatListControllerImpl) {
    let accountPeerId = controller.context.account.peerId
    switch controller.location {
    case let .forum(peerId):
        ChatLockControllerGate.attach(to: controller, peerId: peerId, accountPeerId: accountPeerId, style: controller.previewing ? .preview : .interactive)?.hostViewDidLoad()
    case let .savedMessagesChats(peerId):
        if peerId != accountPeerId {
            ChatLockControllerGate.attach(to: controller, peerId: peerId, accountPeerId: accountPeerId, style: controller.previewing ? .preview : .interactive)?.hostViewDidLoad()
        }
    case .chatList:
        if controller.previewing {
            return
        }
        let disposable = ChatLockSession.shared.addRelockHandler({ [weak controller] _ in
            guard let controller, controller.isNodeLoaded, let displayNode = controller.displayNode as? ChatListControllerNode else {
                return
            }
            guard let location = displayNode.inlineStackContainerNode?.location, case let .forum(peerId) = location else {
                return
            }
            let session = ChatLockSession.shared
            let accountPeerId = controller.context.account.peerId
            // SG: Secret Vault — a vaulted forum shown inline collapses too (the relock closed its vault).
            if session.isProtected(peerId: peerId, accountPeerId: accountPeerId) || session.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId) {
                controller.setInlineChatList(location: nil, animated: false)
            }
        })
        objc_setAssociatedObject(controller, &SGChatLockDisposableHolder.associatedKey, SGChatLockDisposableHolder(disposable), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if controller.fenixIsVaultList {
            // SG: Secret Vault — the vault list keeps its account's vault open while it is in its stack; closing
            // the vault evicts it (and every vault chat above it).
            let vaultDisposable = ChatLockSession.shared.registerVaultScreen(controller, accountPeerId: accountPeerId)
            objc_setAssociatedObject(controller, &SGChatLockDisposableHolder.vaultScreenAssociatedKey, SGChatLockDisposableHolder(vaultDisposable), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// Chat list tap preflight (runs after the monoforum remap, before any inline-forum / navigation logic).
/// Asks for a locked chat's PIN before anything is pushed or opened inline; on success re-runs the whole
/// selection (the fresh grant lets it through). Otherwise clears the row highlight, which used to stay
/// stuck after a cancelled PIN. Returns true when the tap was intercepted.
func sgChatLockListPreflight(_ controller: ChatListControllerImpl, peerId: EnginePeer.Id, retry: @escaping () -> Void) -> Bool {
    let accountPeerId = controller.context.account.peerId
    let session = ChatLockSession.shared
    if session.isContentVisible(peerId: peerId, accountPeerId: accountPeerId) {
        return false
    }
    session.requireUnlock(peerId: peerId, accountPeerId: accountPeerId, reason: .openChat, from: controller, completion: { [weak controller] result in
        if case .unlocked = result {
            retry()
            return
        }
        guard let controller, controller.isNodeLoaded, let displayNode = controller.displayNode as? ChatListControllerNode else {
            return
        }
        displayNode.clearHighlightAnimated(true)
    })
    return true
}
