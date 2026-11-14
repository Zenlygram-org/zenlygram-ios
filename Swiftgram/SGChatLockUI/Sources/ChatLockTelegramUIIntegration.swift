import Foundation
import UIKit
import PassKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import AppLock
import GalleryUI
import PeerAvatarGalleryUI
import InstantPageUI
import ContextUI
import LegacyInstantVideoController
import UniversalMediaPlayer
import TelegramPresentationData
import LocalizedPeerData
import SGChatLock
import SGSecretVault

// Zenlygram — wires the Chat Lock session (SGChatLock) to the app (compiled into TelegramUI). Called once
// from SharedAccountContextImpl.init (`// SG: Chat Lock`); only the main app's context configures it.

private final class SGChatLockPlaybackStateBox {
    var last: (Account, SharedMediaPlayerItemPlaybackStateOrLoading, MediaManagerPlayerType)?
    var disposable: Disposable?
}

func sgChatLockConfigure(_ sharedContext: SharedAccountContextImpl) {
    guard sharedContext.applicationBindings.isMainApp, let mainWindow = sharedContext.mainWindow else {
        return
    }

    let appLockIsLocked: Signal<Bool, NoError>
    if let appLockContext = sharedContext.appLockContext as? AppLockContextImpl {
        appLockIsLocked = appLockContext.isCurrentlyLocked
    } else {
        appLockIsLocked = .single(false)
    }

    // The last global player state, so a relock can stop a locked chat's voice / music playback.
    let playbackState = SGChatLockPlaybackStateBox()
    playbackState.disposable = (sharedContext.mediaManager.globalMediaPlayerState
    |> deliverOnMainQueue).start(next: { value in
        playbackState.last = value
    })

    let rootViewController: () -> UIViewController? = { [weak mainWindow] in
        return (mainWindow?.hostView.eventView as? UIWindow)?.rootViewController
    }

    ChatLockSession.shared.configure(ChatLockSession.Configuration(
        appLockIsLocked: appLockIsLocked,
        presentationData: { [weak sharedContext] in
            return sharedContext?.currentPresentationData.with { $0 } ?? defaultPresentationData()
        },
        rootViewController: rootViewController,
        relockTeardown: { [weak sharedContext, weak mainWindow] revokedKeys in
            guard let sharedContext else {
                return
            }
            if !revokedKeys.isEmpty {
                sgChatLockDismissWindowControllers(mainWindow: mainWindow, revokedKeys: revokedKeys)
                sgChatLockDismissNativePresentations(rootViewController: rootViewController())
            }
            sgChatLockStopProtectedPlayback(sharedContext: sharedContext, state: playbackState)
        }
    ))

    // SG: Chat Lock — names the chat on its PIN screen (title only, never content), so a prompt the user did
    // not start from that chat's row (resume after relock, notification, link, comments) says whose PIN it
    // asks for. The presenter uses the first value; nil keeps the generic "Chat is locked" copy.
    ChatLockSession.promptChatTitleProvider = { [weak sharedContext] key in
        guard let sharedContext else {
            return .single(nil)
        }
        return sharedContext.activeAccountContexts
        |> take(1)
        |> mapToSignal { contexts -> Signal<String?, NoError> in
            guard let context = contexts.accounts.first(where: { $0.1.account.peerId == key.accountPeerId })?.1 else {
                return .single(nil)
            }
            return sgChatLockChatTitle(context: context, peerId: key.peerId)
        }
    }

    // SG: Secret Vault — #119: passive use keeps an open vault open (asked when the inactivity timer fires): a
    // vault chat's voice / music / round video playing, or a media viewer on screen at window level or in a
    // stacked screen's own presentation context (`.current`).
    ChatLockSession.vaultKeepAliveProvider = { [weak mainWindow] in
        if sgSecretVaultPlaybackIsActive(playbackState) {
            return true
        }
        guard let mainWindow else {
            return false
        }
        if !sgChatLockCollectWindowControllers(mainWindow: mainWindow, where: sgChatLockIsMediaViewer).isEmpty {
            return true
        }
        return sgChatLockHasCurrentContextMediaViewer(mainWindow: mainWindow) // SG: Secret Vault — #119
    }

    // SG: Secret Vault — migrations, per-account effects, M4 / M5 (SecretVaultTelegramUIIntegration.swift).
    sgSecretVaultConfigure(sharedContext)
}

/// SG: Secret Vault — #119: the global player is playing (or buffering while playing) a message of a chat hidden
/// in its account's vault.
private func sgSecretVaultPlaybackIsActive(_ state: SGChatLockPlaybackStateBox) -> Bool {
    guard let last = state.last, case let .state(value) = last.1, let itemId = value.item.id as? PeerMessagesMediaPlaylistItemId else {
        return false
    }
    guard ChatLockSession.shared.isVaultHidden(peerId: itemId.messageId.peerId, accountPeerId: last.0.peerId) else {
        return false
    }
    switch value.status.status {
    case .playing:
        return true
    case let .buffering(_, whilePlaying, _, _):
        return whilePlaying
    case .paused:
        return false
    }
}

/// SG: Secret Vault — #119: a media viewer (gallery, avatar / Instant View gallery, round-video recorder,
/// view-once viewer); on screen it keeps an open vault open.
private func sgChatLockIsMediaViewer(_ controller: ViewController) -> Bool {
    return controller is GalleryController || controller is AvatarGalleryController || controller is InstantPageGalleryController || controller is InstantVideoController || controller is SecretMediaPreviewController
}

/// SG: Secret Vault — #119: a media viewer on screen in the own presentation context (`.current`) of a screen in
/// a navigation stack of the window (the root one and any presented in the window). On iPhone a broadcast
/// channel's gallery opens in the chat's gallery context (OpenChatMessage → ChatControllerImpl's
/// `galleryPresentationContext`), which the window-level collector (`sgChatLockCollectWindowControllers`) does
/// not see; without this, watching a long video there closes the vault mid-video. Keep-alive only: the relock
/// sweep is unchanged (evicting the chat takes its contexts along).
private func sgChatLockHasCurrentContextMediaViewer(mainWindow: Window1) -> Bool {
    var navigationControllers: [NavigationController] = []
    if let rootNavigationController = mainWindow.viewController as? NavigationController {
        navigationControllers.append(rootNavigationController)
    }
    mainWindow.forEachViewController({ controller in
        if let navigationController = controller as? NavigationController, !navigationControllers.contains(where: { $0 === navigationController }) {
            navigationControllers.append(navigationController)
        }
        return true
    }, excludeNavigationSubControllers: true)
    // On screen only: a stacked screen that is not visible keeps its contexts but leaves the window.
    func isVisibleMediaViewer(_ controller: ContainableController) -> Bool {
        guard let controller = controller as? ViewController, sgChatLockIsMediaViewer(controller) else {
            return false
        }
        return controller.isViewLoaded && controller.view.window != nil
    }
    for navigationController in navigationControllers {
        for case let controller as ViewController in navigationController.viewControllers {
            if controller.presentationContext.controllers.contains(where: { isVisibleMediaViewer($0.0) }) {
                return true
            }
            if let chatController = controller as? ChatControllerImpl, chatController.galleryPresentationContext.controllers.contains(where: { isVisibleMediaViewer($0.0) }) {
                return true
            }
        }
    }
    return false
}

/// SG: Chat Lock — whether a locked chat may be named on its PIN screen / cover: never for a chat hidden in
/// the Secret Vault of that account, whose existence the prompt must not reveal. Any thread.
func sgChatLockMayNameChat(_ peerId: PeerId, accountPeerId: PeerId) -> Bool {
    return !ChatLockSession.shared.isVaultHidden(peerId: peerId, accountPeerId: accountPeerId)
}

/// SG: Chat Lock — the chat's display title for its PIN screen and cover (the other party's name for a secret
/// chat). nil for a Secret Vault chat, a peer that is not known yet or an empty title. Live: re-emits on renames.
func sgChatLockChatTitle(context: AccountContext, peerId: PeerId) -> Signal<String?, NoError> {
    return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.MainPeer(id: peerId))
    |> map { peer -> String? in
        guard let peer, sgChatLockMayNameChat(peerId, accountPeerId: context.account.peerId) else {
            return nil
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        return title.isEmpty ? nil : title
    }
    |> distinctUntilChanged
}

/// Galleries (avatar, Instant View), view-once / secret-media viewers, the round-video recorder, context
/// menus, peeks, pinch-zoom and the send-options screen float above the navigation stack at window level,
/// above the chat's cover, so eviction does not reach them: take them down, now and once more on return.
private func sgChatLockDismissWindowControllers(mainWindow: Window1?, revokedKeys: Set<ChatLockKey>) {
    guard let mainWindow else {
        return
    }
    sgChatLockSweepWindowControllers(mainWindow: mainWindow, revokedKeys: revokedKeys)
    SGChatLockReturnSweep.shared.schedule(mainWindow: mainWindow, revokedKeys: revokedKeys)
}

/// A window overlay whose presentation was already in flight when the relock ran lands AFTER the teardown,
/// above the relocked chat's cover: the message context menu is built in an async signal before
/// `presentInGlobalOverlay`, so Home / the side button between the long-press and that call leaves the menu
/// (with the lifted message) up on return; an overlay whose container was still loading at teardown time is
/// not listed by `overlayControllers` / `globalOverlayControllers` either. Nothing can be presented on
/// purpose while the app is in the background, so sweep the window once more when it returns to the
/// foreground (before the privacy shield lifts on didBecomeActive), for the revoked chats still locked.
private final class SGChatLockReturnSweep {
    static let shared = SGChatLockReturnSweep()

    private weak var mainWindow: Window1?
    private var revokedKeys = Set<ChatLockKey>()
    private var observer: NSObjectProtocol?

    /// Main thread, from the relock teardown. Armed only by a relock in the background (didEnterBackground,
    /// device lock): the next willEnterForeground is then exactly the return. Repeated relocks accumulate.
    func schedule(mainWindow: Window1, revokedKeys: Set<ChatLockKey>) {
        guard UIApplication.shared.applicationState == .background else {
            return
        }
        self.mainWindow = mainWindow
        self.revokedKeys.formUnion(revokedKeys)
        if self.observer == nil {
            // queue: nil — delivered synchronously on the posting (main) thread, before the first frame.
            self.observer = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.run()
            })
        }
    }

    /// One shot: disarms, then sweeps only if a revoked chat is still locked and ungranted.
    private func run() {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        let session = ChatLockSession.shared
        let stillLocked = self.revokedKeys.filter { key in
            return !session.isContentVisible(peerId: key.peerId, accountPeerId: key.accountPeerId)
        }
        self.revokedKeys.removeAll()
        guard !stillLocked.isEmpty, let mainWindow = self.mainWindow else {
            return
        }
        sgChatLockSweepWindowControllers(mainWindow: mainWindow, revokedKeys: stillLocked)
    }
}

/// The Display controllers at window level that match `predicate`, each once: the overlays of the root
/// navigation controller and of any navigation controller presented in the window (global overlays included,
/// topmost first), then the window's own controllers. Collects only; nothing is dismissed.
private func sgChatLockCollectWindowControllers(mainWindow: Window1, where predicate: (ViewController) -> Bool) -> [ViewController] {
    var controllers: [ViewController] = []
    var seen = Set<ObjectIdentifier>()
    func collect(_ controller: ContainableController) {
        guard let controller = controller as? ViewController, seen.insert(ObjectIdentifier(controller)).inserted else {
            return
        }
        controllers.append(controller)
    }
    // Every overlay, topmost first. `forEachViewController` visits only the top `.window(.root)` overlay
    // and never the global overlays that `presentInGlobalOverlay` uses: message / link / reaction context
    // menus, peeks and pinch-zoom live there.
    func collectOverlays(of navigationController: NavigationController) {
        for controller in navigationController.globalOverlayControllers.reversed() {
            collect(controller)
        }
        for controller in navigationController.overlayControllers.reversed() {
            collect(controller)
        }
    }
    if let rootNavigationController = mainWindow.viewController as? NavigationController {
        collectOverlays(of: rootNavigationController)
    }
    mainWindow.forEachViewController({ controller in
        // Window1.present hands overlays to a navigation controller presented in the window, if any.
        if let navigationController = controller as? NavigationController {
            collectOverlays(of: navigationController)
        }
        collect(controller)
        return true
    }, excludeNavigationSubControllers: true)
    return controllers.filter(predicate)
}

/// Collected first, dismissed after (dismissal mutates the containers).
private func sgChatLockSweepWindowControllers(mainWindow: Window1, revokedKeys: Set<ChatLockKey>) {
    let controllers = sgChatLockCollectWindowControllers(mainWindow: mainWindow, where: { controller in
        return sgChatLockShouldDismissOnRelock(controller, revokedKeys: revokedKeys)
    })
    for controller in controllers {
        if let controller = controller as? InstantVideoController {
            controller.dismissVideo()
        } else if let controller = controller as? ContextController {
            // The regular dismissal restores extracted source content (message bubbles, list rows).
            controller.dismiss(completion: nil)
        } else if controller.isNodeLoaded, let galleryNode = controller.displayNode as? GalleryControllerNode, let dismiss = galleryNode.dismiss {
            // Gallery nodes' own dismiss restores the chat's read state and hidden media immediately.
            dismiss()
        } else {
            // SecretMediaPreviewController leaves synchronously; peeks, pinch-zoom and send options animate out.
            controller.dismiss()
        }
        // Animated dismissals keep the menu and the extracted message above the cover until the animation
        // ends, possibly only after return: hide what is still on screen now. The dismissal still
        // completes and puts the extracted content back into the (covered) chat.
        if controller.isViewLoaded, controller.view.window != nil {
            controller.view.isHidden = true
        }
    }
}

private func sgChatLockShouldDismissOnRelock(_ controller: ViewController, revokedKeys: Set<ChatLockKey>) -> Bool {
    if let controller = controller as? SecretMediaPreviewController {
        // Closing a view-once viewer destroys the media, so spare other chats' viewers. Unknown: dismiss.
        guard let messageId = sgChatLockSecretMediaMessageId(controller) else {
            return true
        }
        return revokedKeys.contains(where: { $0.peerId == messageId.peerId })
    }
    return controller is GalleryController || controller is AvatarGalleryController || controller is InstantPageGalleryController || controller is InstantVideoController || controller is ContextController || controller is PeekController || controller is PinchController || controller is ChatSendMessageActionSheetController
}

/// SecretMediaPreviewController keeps its message id private (GalleryUI is upstream code); read the stored
/// property by reflection. nil if upstream renames it.
private func sgChatLockSecretMediaMessageId(_ controller: SecretMediaPreviewController) -> MessageId? {
    for child in Mirror(reflecting: controller).children where child.label == "messageId" {
        return child.value as? MessageId
    }
    return nil
}

/// UIKit modals (document pickers, Safari, share sheets…) presented over the window root. Our own PIN
/// prompt and Apple Pay are left alone.
private func sgChatLockDismissNativePresentations(rootViewController: UIViewController?) {
    guard let rootViewController, let presented = rootViewController.presentedViewController else {
        return
    }
    if presented is PKPaymentAuthorizationViewController {
        return
    }
    var current: UIViewController? = presented
    while let controller = current {
        if controller is ChatLockPromptNavigationController {
            return
        }
        current = controller.presentedViewController
    }
    rootViewController.dismiss(animated: false, completion: nil)
}

/// A relock stops a locked chat's voice / round-video / music playback, which also removes the playback
/// header and the round-video overlay. SG: Secret Vault — any chat whose content is no longer visible (a
/// relocked chat, or a vault chat after its vault closed: audit #14).
private func sgChatLockStopProtectedPlayback(sharedContext: SharedAccountContextImpl, state: SGChatLockPlaybackStateBox) {
    guard let last = state.last, case let .state(value) = last.1 else {
        return
    }
    guard let itemId = value.item.id as? PeerMessagesMediaPlaylistItemId else {
        return
    }
    if !ChatLockSession.shared.isContentVisible(peerId: itemId.messageId.peerId, accountPeerId: last.0.peerId) {
        sharedContext.mediaManager.setPlaylist(nil, type: last.2, control: .playback(.pause))
    }
}
