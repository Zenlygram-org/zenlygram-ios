// MARK: Swiftgram
import SGSimpleSettings
#if SG_LENTA
import SGFeedUI
#endif
import SGUnreadReminder
import SGChatLock
import SGCustomerSync
import SGEntitlement
import SGAppUpdateUI
import Foundation
import UIKit
import Intents
import TelegramPresentationData
import TelegramUIPreferences
import SwiftSignalKit
import Postbox
import TelegramCore
import Display
import LegacyComponents
import DeviceAccess
import TelegramUpdateUI
import AccountContext
import AlertUI
import PresentationDataUtils
import TelegramPermissions
import TelegramNotices
import LegacyUI
import TelegramPermissionsUI
import PasscodeUI
import ImageBlur
import FastBlur
import SettingsUI
import AppLock
import AccountUtils
import ContextUI
import TelegramCallsUI
import AuthorizationUI
import ChatListUI
import StoryContainerScreen
import ChatMessageNotificationItem
import PhoneNumberFormat
import AttachmentUI
import MinimizedContainer
import BrowserUI

final class UnauthorizedApplicationContext {
    let sharedContext: SharedAccountContextImpl
    let account: UnauthorizedAccount
    
    let rootController: AuthorizationSequenceController
    
    let isReady = Promise<Bool>()
    
    var authorizationCompleted: Bool = false

    private var serviceNotificationEventsDisposable: Disposable?
    
    init(apiId: Int32, apiHash: String, sharedContext: SharedAccountContextImpl, account: UnauthorizedAccount, otherAccountPhoneNumbers: ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)])) {
        self.sharedContext = sharedContext
        self.account = account
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        
        var authorizationCompleted: (() -> Void)?
        
        self.rootController = AuthorizationSequenceController(sharedContext: sharedContext, account: account, otherAccountPhoneNumbers: otherAccountPhoneNumbers, presentationData: presentationData, openUrl: sharedContext.applicationBindings.openUrl, apiId: apiId, apiHash: apiHash, authorizationCompleted: {
            authorizationCompleted?()
        })
        (self.rootController as NavigationController).statusBarHost = sharedContext.mainWindow?.statusBarHost
        // MARK: Zenlygram — an "Update required" block removed from the login root by anything but its presenter comes
        // back (update_policy_spec §4f). AppDelegate attaches the block itself right before this root is presented.
        self.rootController.globalOverlayControllersUpdated = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            SGAppUpdate.shared.rootOverlaysChanged(root: strongSelf.rootController, consentWall: nil)
        }
        
        authorizationCompleted = { [weak self] in
            self?.authorizationCompleted = true
        }
        
        self.isReady.set(self.rootController.ready.get())
        
        account.shouldBeServiceTaskMaster.set(sharedContext.applicationBindings.applicationInForeground |> map { value -> AccountServiceTaskMasterMode in
            if value {
                return .always
            } else {
                return .never
            }
        })
        
        DeviceAccess.authorizeAccess(to: .cellularData, presentationData: sharedContext.currentPresentationData.with { $0 }, present: { [weak self] c, a in
            if let strongSelf = self {
                (strongSelf.rootController.viewControllers.last as? ViewController)?.present(c, in: .window(.root))
            }
        }, openSettings: {
            sharedContext.applicationBindings.openSettings()
        }, { result in
            ApplicationSpecificNotice.setPermissionWarning(accountManager: sharedContext.accountManager, permission: .cellularData, value: 0)
        })

        self.serviceNotificationEventsDisposable = (account.serviceNotificationEvents
        |> deliverOnMainQueue).start(next: { [weak self] text in
            if let strongSelf = self {
                let presentationData = strongSelf.sharedContext.currentPresentationData.with { $0 }
                let alertController = textAlertController(sharedContext: strongSelf.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])

                (strongSelf.rootController.viewControllers.last as? ViewController)?.present(alertController, in: .window(.root))
            }
        })
    }

    deinit {
        self.serviceNotificationEventsDisposable?.dispose()
    }
}

final class AuthorizedApplicationContext {
    let sharedApplicationContext: SharedApplicationContext
    let mainWindow: Window1
    let lockedCoveringView: LockedWindowCoveringView
    
    let context: AccountContextImpl
    
    let rootController: TelegramRootController
    let notificationController: NotificationContainerController
    
    private let scheduledCallPeerDisposable = MetaDisposable()
    private var scheduledOpenExternalUrl: URL?
        
    private let passcodeStatusDisposable = MetaDisposable()
    private let passcodeLockDisposable = MetaDisposable()
    private let loggedOutDisposable = MetaDisposable()
    private let inAppNotificationSettingsDisposable = MetaDisposable()
    private let notificationMessagesDisposable = MetaDisposable()
    private let termsOfServiceUpdatesDisposable = MetaDisposable()
    private let termsOfServiceProceedToBotDisposable = MetaDisposable()
    private let watchNavigateToMessageDisposable = MetaDisposable()
    private let permissionsDisposable = MetaDisposable()
    private let appUpdateInfoDisposable = MetaDisposable()
    
    private var inAppNotificationSettings: InAppNotificationSettings?
    
    var passcodeController: PasscodeEntryController?
    
    private var currentAppUpdateInfo: AppUpdateInfo?
    private var currentTermsOfServiceUpdate: TermsOfServiceUpdate?
    private var currentPermissionsController: PermissionController?
    private var currentPermissionsState: PermissionState?
    
    private let unlockedStatePromise = Promise<Bool>()
    var unlockedState: Signal<Bool, NoError> {
        return self.unlockedStatePromise.get()
    }
    
    var applicationBadge: Signal<Int32, NoError> {
        return renderedTotalUnreadCount(accountManager: self.context.sharedContext.accountManager, engine: self.context.engine)
        |> map {
            $0.0
        }
    }
    
    let isReady = Promise<Bool>()
    
    private var presentationDataDisposable: Disposable?
    private var displayAlertsDisposable: Disposable?
    private var removeNotificationsDisposable: Disposable?
    
    private var applicationInForegroundDisposable: Disposable?
    
    private var showContactsTab: Bool
    private var showCallsTab: Bool
    private var showTasksTab: Bool
    private var showCallsTabDisposable: Disposable?
    #if SG_LENTA
    private var lentaTabDisposable: Disposable?
    #endif
    private var enablePostboxTransactionsDiposable: Disposable?
    
    init(sharedApplicationContext: SharedApplicationContext, mainWindow: Window1, context: AccountContextImpl, accountManager: AccountManager<TelegramAccountManagerTypes>, showContactsTab: Bool, showCallsTab: Bool, showTasksTab: Bool, reinitializedNotificationSettings: @escaping () -> Void) {
        self.sharedApplicationContext = sharedApplicationContext
        
        setupLegacyComponents(context: context)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        self.mainWindow = mainWindow
        self.lockedCoveringView = LockedWindowCoveringView(theme: presentationData.theme)
        
        self.context = context

        // MARK: Swiftgram
        SGUnreadReminderManager.startIfNeeded(context: context)
        // Cache the account's own phone number for the Foreign User Block filter.
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> take(1)
        |> deliverOnMainQueue).start(next: { peer in
            if case let .user(user) = peer, let phone = user.phone, !phone.isEmpty {
                SGSimpleSettings.shared.ownPhoneNumber = phone
            }
        })

        self.showContactsTab = showContactsTab
        
        self.showCallsTab = showCallsTab
        
        self.showTasksTab = showTasksTab
        
        self.notificationController = NotificationContainerController(context: context)
        
        self.rootController = TelegramRootController(context: context)
        self.rootController.minimizedContainer = self.sharedApplicationContext.minimizedContainer[context.account.id]
        self.rootController.minimizedContainerUpdated = { [weak self] minimizedContainer in
            guard let self else {
                return
            }
            self.sharedApplicationContext.minimizedContainer[self.context.account.id] = minimizedContainer
        }
        
        self.rootController.globalOverlayControllersUpdated = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            var hasContext = false
            for controller in strongSelf.rootController.globalOverlayControllers {
                if controller is ContextController {
                    hasContext = true
                    break
                }
            }
            
            strongSelf.notificationController.updateIsTemporaryHidden(hasContext)
            
            // Zenlygram — a consent wall removed by anything but its presenter is presented again (design 40 §5.1).
            SGCustomerSync.shared.rootOverlaysChanged(accountPeerId: strongSelf.context.account.peerId.toInt64())
            // Zenlygram — the "Update required" block comes back when removed and stays above the wall
            // (update_policy_spec §4f); a call screen is above both (`SGCallScreenPlacement`).
            SGAppUpdate.shared.rootOverlaysChanged(root: strongSelf.rootController, consentWall: SGCustomerSync.shared.consentWallController(over: strongSelf.rootController))
        }
        
        if KeyShortcutsController.isAvailable {
            let keyShortcutsController = KeyShortcutsController { [weak self] f in
                // Zenlygram — no key shortcuts behind the consent wall (design 40 §5.1) or the update block.
                if let strongSelf = self, strongSelf.dropsRootActions {
                    return
                }
                if let strongSelf = self, let appLockContext = strongSelf.context.sharedContext.appLockContext as? AppLockContextImpl {
                    let _ = (appLockContext.isCurrentlyLocked
                    |> take(1)
                    |> deliverOnMainQueue).start(next: { locked in
                        guard !locked else {
                            return
                        }
                        if let tabController = strongSelf.rootController.rootTabController {
                            let selectedController = tabController.controllers[tabController.selectedIndex]
                            
                            if let index = strongSelf.rootController.viewControllers.lastIndex(where: { controller in
                                guard let controller = controller as? ViewController else {
                                    return false
                                }
                                if controller === tabController {
                                    return false
                                }
                                switch controller.navigationPresentation {
                                case .master:
                                    return true
                                default:
                                    break
                                }
                                return false
                            }), let controller = strongSelf.rootController.viewControllers[index] as? ViewController {
                                if !f(controller) {
                                    return
                                }
                            } else {
                                if !f(selectedController) {
                                    return
                                }
                            }
                            
                            if let controller = strongSelf.rootController.topViewController as? ViewController, controller !== selectedController {
                                if !f(controller) {
                                    return
                                }
                            }
                        }
                        strongSelf.mainWindow.forEachViewController(f)
                        if let globalOverlayController = strongSelf.rootController.globalOverlayControllers.last {
                            if !f(globalOverlayController) {
                                return
                            }
                        }
                    })
                }
            }
            context.keyShortcutsController = keyShortcutsController
        }
        
        if self.rootController.rootTabController == nil {
            self.rootController.addRootControllers(hidePhoneInSettings: SGSimpleSettings.shared.hidePhoneInSettings, showContactsTab: self.showContactsTab, showCallsTab: self.showCallsTab, showTasksTab: self.showTasksTab)
        }
        // MARK: Zenlygram — the data-consent wall for THIS account (design 40 §5). Local state only:
        // UserDefaults, the session item and the bundled manifest, never the network (I1, owner exception O1).
        let consentReady = SGCustomerSync.shared.attachRoot(context: context, rootController: self.rootController)
        // MARK: Zenlygram — the "Update required" block of a known-blocked install (update_policy_spec §4e): decided
        // synchronously from the stored, re-verified policy (no network) and presented on this root before its first
        // frame, as a global overlay above the consent wall; its readiness gates the root's as the wall's does. The
        // +8 s fetch only refines or lifts it.
        let updateReady = SGAppUpdate.shared.attachRoot(self.rootController, kind: .authorized)
        let wallsReady = combineLatest(consentReady, updateReady)
        |> map { $0 && $1 }
        if let tabsController = self.rootController.viewControllers.first as? TabBarController, !tabsController.controllers.isEmpty, tabsController.selectedIndex >= 0 {
            let controller = tabsController.controllers[tabsController.selectedIndex]
            let combinedReady = combineLatest(tabsController.ready.get(), controller.ready.get(), wallsReady)
            |> map { $0 && $1 && $2 }
            |> filter { $0 }
            |> take(1)
            self.isReady.set(combinedReady)
        } else {
            self.isReady.set(wallsReady
            |> filter { $0 }
            |> take(1))
        }
        
        let accountId = context.account.id
        self.loggedOutDisposable.set((context.account.loggedOut
        |> deliverOnMainQueue).start(next: { [weak self] value in
            if value {
                Logger.shared.log("ApplicationContext", "account logged out")
                let _ = logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: false).start()
                if let strongSelf = self {
                    strongSelf.rootController.currentWindow?.forEachController { controller in
                        if let controller = controller as? TermsOfServiceController {
                            controller.dismiss()
                        }
                    }
                }
            }
        }))
        
        self.inAppNotificationSettingsDisposable.set(((context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings])) |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) {
                    let previousSettings = strongSelf.inAppNotificationSettings
                    strongSelf.inAppNotificationSettings = settings
                    if let previousSettings = previousSettings, previousSettings.displayNameOnLockscreen != settings.displayNameOnLockscreen {
                        reinitializedNotificationSettings()
                    }
                }
            }
        }))

        let engine = context.engine
        self.notificationMessagesDisposable.set((context.account.stateManager.notificationMessages
        |> mapToSignal { messageList -> Signal<[([Message], PeerGroupId, Bool, MessageHistoryThreadData?)], NoError> in
            return engine.data.get(EngineDataMap(
                messageList.compactMap { item -> TelegramEngine.EngineData.Item.Messages.ChatListIndex? in
                    if let message = item.0.first {
                        return TelegramEngine.EngineData.Item.Messages.ChatListIndex(id: message.id.peerId)
                    } else {
                        return nil
                    }
                }
            ))
            |> map { chatListIndexMap -> [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)] in
                return messageList.filter { item in
                    guard let message = item.0.first else {
                        return false
                    }
                    if let maybeChatListIndex = chatListIndexMap[message.id.peerId], maybeChatListIndex != nil {
                        return true
                    } else {
                        return false
                    }
                }
            }
        }
        |> deliverOn(Queue.mainQueue())).start(next: { [weak self] sgMessageList in
            // SG: Secret Vault — a chat hidden in this account's closed vault gets no in-app banner and no sound
            // (#18: a mention / reply in a vault group); other chats of the same batch still notify.
            let messageList = sgMessageList.filter { item in
                guard let message = item.0.first else {
                    return true
                }
                return !sgSecretVaultSuppressesInAppNotification(context: context, peerId: message.id.peerId)
            }
            if messageList.isEmpty {
                return
            }

            if let strongSelf = self, let (messages, _, notify, threadData) = messageList.last, let firstMessage = messages.first {
                if UIApplication.shared.applicationState == .active {
                    let chatLocation: NavigateToChatControllerParams.Location
                    if let _ = threadData, let threadId = firstMessage.threadId {
                        chatLocation = .replyThread(ChatReplyThreadMessage(
                            peerId: firstMessage.id.peerId, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false
                        ).normalized)
                    } else {
                        guard let peer = firstMessage.peers[firstMessage.id.peerId] else {
                            return
                        }
                        chatLocation = .peer(EnginePeer(peer))
                    }
                    
                    var chatIsVisible = false
                    if let topController = strongSelf.rootController.topViewController as? ChatControllerImpl, topController.traceVisibility() {
                        if topController.chatLocation.peerId == firstMessage.id.peerId, (topController.chatLocation.threadId == nil || topController.chatLocation.threadId == firstMessage.threadId) {
                            chatIsVisible = true
                        }
                    }
                    
                    if !notify {
                        chatIsVisible = true
                    }
                    
                    if !chatIsVisible {
                        strongSelf.mainWindow.forEachViewController({ controller in
                            if let controller = controller as? ChatControllerImpl, controller.chatLocation.peerId == chatLocation.peerId, (chatLocation.threadId == nil || chatLocation.threadId == controller.chatLocation.threadId) {
                                chatIsVisible = true
                                return false
                            }
                            return true
                        })
                    }
                    
                    let inAppNotificationSettings: InAppNotificationSettings
                    if let current = strongSelf.inAppNotificationSettings {
                        inAppNotificationSettings = current
                    } else {
                        inAppNotificationSettings = InAppNotificationSettings.defaultSettings
                    }
                    
                    if let appLockContext = strongSelf.context.sharedContext.appLockContext as? AppLockContextImpl {
                        let _ = (appLockContext.isCurrentlyLocked
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { locked in
                            guard let strongSelf = self else {
                                return
                            }
                            
                            guard !locked else {
                                return
                            }
                            let isMuted = firstMessage.attributes.contains(where: { attribute in
                                if let attribute = attribute as? NotificationInfoMessageAttribute {
                                    return attribute.flags.contains(.muted)
                                } else {
                                    return false
                                }
                            })
                            if !isMuted {
                                if firstMessage.id.peerId == context.account.peerId, !firstMessage.flags.contains(.WasScheduled) {
                                } else {
                                    if inAppNotificationSettings.playSounds {
                                        serviceSoundManager.playIncomingMessageSound()
                                    }
                                    if inAppNotificationSettings.vibrate {
                                        serviceSoundManager.playVibrationSound()
                                    }
                                }
                            }
                            if let forwardInfo = firstMessage.forwardInfo, forwardInfo.flags.contains(.isImported) {
                                return
                            }
                            for media in firstMessage.media {
                                if let action = media as? TelegramMediaAction {
                                    if case .messageAutoremoveTimeoutUpdated = action.action {
                                        return
                                    } else if case .conferenceCall = action.action {
                                        return
                                    }
                                }
                            }
                            
                            if chatIsVisible {
                                return
                            }
                            
                            if firstMessage.restrictionReason(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) != nil {
                                return
                            }
                            if let chatPeer = firstMessage.peers[firstMessage.id.peerId] {
                                if EnginePeer(chatPeer).restrictionText(platform: "ios", contentSettings: strongSelf.context.currentContentSettings.with { $0 }) != nil {
                                    return
                                }
                            }
                            
                            if inAppNotificationSettings.displayPreviews {
                                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                                strongSelf.notificationController.enqueue(ChatMessageNotificationItem(context: strongSelf.context, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, messages: messages, threadData: threadData, tapAction: {
                                    // MARK: Swiftgram — ChatLock: tapping the (redacted) banner of a locked chat must go
                                    // through the pincode-gated navigateToChatController; the overlay-chat presentation
                                    // below would bypass the lock and reveal the chat's content.
                                    // SG: Secret Vault — same for a vault chat (the gate asks for the vault PIN once the
                                    // vault has closed); keyed by this account, so another account's lock or vault never
                                    // applies here (#48).
                                    if let strongSelf = self, ChatLockSession.shared.isProtected(peerId: firstMessage.id.peerId, accountPeerId: strongSelf.context.account.peerId) || ChatLockSession.shared.isVaultHidden(peerId: firstMessage.id.peerId, accountPeerId: strongSelf.context.account.peerId) {
                                        strongSelf.notificationController.removeItemsWithGroupingKey(firstMessage.id.peerId)
                                        if let chatPeer = firstMessage.peers[firstMessage.id.peerId] {
                                            strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: strongSelf.rootController, context: strongSelf.context, chatLocation: .peer(EnginePeer(chatPeer))))
                                        }
                                        return false
                                    }
                                    if let strongSelf = self {
                                        var foundOverlay = false
                                        strongSelf.mainWindow.forEachViewController({ controller in
                                            if isOverlayControllerForChatNotificationOverlayPresentation(controller) {
                                                foundOverlay = true
                                                return false
                                            }
                                            return true
                                        }, excludeNavigationSubControllers: true)
                                        
                                        if foundOverlay {
                                            return true
                                        }
                                        
                                        if let topController = strongSelf.rootController.topViewController as? ViewController, isInlineControllerForChatNotificationOverlayPresentation(topController) {
                                            return true
                                        }
                                        
                                        if let topController = strongSelf.rootController.topViewController as? ChatControllerImpl, topController.chatLocation.peerId == chatLocation.peerId, (topController.chatLocation.threadId == nil || topController.chatLocation.threadId == chatLocation.threadId) {
                                            strongSelf.notificationController.removeItemsWithGroupingKey(firstMessage.id.peerId)
                                            
                                            return false
                                        }

                                        let proceedAction: (Bool) -> Bool = { allowExpansion in
                                            if let minimizedContainer = strongSelf.rootController.minimizedContainer, minimizedContainer.isExpanded {
                                                minimizedContainer.collapse()
                                            } else if let topContoller = strongSelf.rootController.topViewController as? AttachmentController {
                                                topContoller.minimizeIfNeeded()
                                            }  else if let topContoller = strongSelf.rootController.topViewController as? BrowserScreen {
                                                topContoller.requestMinimize(topEdgeOffset: nil, initialVelocity: nil)
                                            }

                                            for controller in strongSelf.rootController.viewControllers {
                                                if let controller = controller as? ChatControllerImpl, controller.chatLocation.peerId == chatLocation.peerId, (controller.chatLocation.threadId == nil || controller.chatLocation.threadId == chatLocation.threadId) {
                                                    if allowExpansion {
                                                        return true
                                                    } else {
                                                        strongSelf.notificationController.removeItemsWithGroupingKey(firstMessage.id.peerId)

                                                        let chatController = ChatControllerImpl(context: strongSelf.context, chatLocation: chatLocation.asChatLocation, mode: .overlay(strongSelf.rootController))
                                                        let presentationArguments = ChatControllerOverlayPresentationData(expandData: (nil, {}))
                                                        chatController.presentationArguments = presentationArguments
                                                        (strongSelf.rootController.viewControllers.last as? ViewController)?.present(chatController, in: .window(.root), with: presentationArguments)
                                                        return false
                                                    }
                                                }
                                            }

                                            strongSelf.notificationController.removeItemsWithGroupingKey(firstMessage.id.peerId)

                                            var processed = false
                                            for media in firstMessage.media {
                                                if let action = media as? TelegramMediaAction, case .geoProximityReached = action.action {
                                                    strongSelf.context.sharedContext.openLocationScreen(context: strongSelf.context, messageId: firstMessage.id, navigationController: strongSelf.rootController)
                                                    processed = true
                                                    break
                                                }
                                            }

                                            if !processed {
                                                strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: strongSelf.rootController, context: strongSelf.context, chatLocation: chatLocation))
                                            }

                                            return false
                                        }

                                        if let topController = strongSelf.rootController.topViewController as? ChatControllerImpl {
                                            let didPresentAlert = topController.presentVoiceMessageDiscardAlert(action: {
                                                let _ = proceedAction(false)
                                            }, discardIfVideo: true, performAction: false)
                                            if didPresentAlert {
                                                return false
                                            }
                                        }
                                        
                                        return proceedAction(true)
                                    }
                                    return false
                                }, expandAction: { expandData in
                                    if let strongSelf = self {
                                        // MARK: Swiftgram — ChatLock: the pan-down expansion of a locked chat's
                                        // (redacted) banner must not present the chat content in the overlay
                                        // controller; route it through the pincode-gated navigateToChatController,
                                        // mirroring the tapAction guard above.
                                        // SG: Secret Vault — vault chats too, keyed by this account (#48).
                                        if ChatLockSession.shared.isProtected(peerId: firstMessage.id.peerId, accountPeerId: strongSelf.context.account.peerId) || ChatLockSession.shared.isVaultHidden(peerId: firstMessage.id.peerId, accountPeerId: strongSelf.context.account.peerId) {
                                            strongSelf.notificationController.removeItemsWithGroupingKey(firstMessage.id.peerId)
                                            if let chatPeer = firstMessage.peers[firstMessage.id.peerId] {
                                                strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: strongSelf.rootController, context: strongSelf.context, chatLocation: .peer(EnginePeer(chatPeer))))
                                            }
                                            return
                                        }
                                        let chatController = ChatControllerImpl(context: strongSelf.context, chatLocation: chatLocation.asChatLocation, mode: .overlay(strongSelf.rootController))
                                        chatController.presentationArguments = ChatControllerOverlayPresentationData(expandData: expandData())
                                        (strongSelf.rootController.viewControllers.last as? ViewController)?.present(chatController, in: .window(.root), with: ChatControllerOverlayPresentationData(expandData: expandData()))
                                    }
                                }))
                            }
                        })
                    }
                }
            }
        }))
        
        self.termsOfServiceUpdatesDisposable.set((context.account.stateManager.termsOfServiceUpdate
        |> deliverOnMainQueue).start(next: { [weak self] termsOfServiceUpdate in
            guard let strongSelf = self, strongSelf.currentTermsOfServiceUpdate != termsOfServiceUpdate else {
                return
            }
            
            strongSelf.currentTermsOfServiceUpdate = termsOfServiceUpdate
            if let termsOfServiceUpdate = termsOfServiceUpdate {
                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                var acceptImpl: ((String?) -> Void)?
                var declineImpl: (() -> Void)?
                let controller = TermsOfServiceController(context: strongSelf.context, presentationData: presentationData, text: termsOfServiceUpdate.text, entities: termsOfServiceUpdate.entities, ageConfirmation: termsOfServiceUpdate.ageConfirmation, signingUp: false, accept: { proccedBot in
                    acceptImpl?(proccedBot)
                }, decline: {
                    declineImpl?()
                }, openUrl: { url in
                    if let parsedUrl = URL(string: url) {
                        UIApplication.shared.open(parsedUrl, options: [:], completionHandler: nil)
                    }
                })
                
                acceptImpl = { [weak controller] botName in
                    controller?.inProgress = true
                    guard let strongSelf = self else {
                        return
                    }
                    let _ = (strongSelf.context.engine.accountData.acceptTermsOfService(id: termsOfServiceUpdate.id)
                    |> deliverOnMainQueue).start(completed: {
                        controller?.dismiss()
                        if let strongSelf = self, let botName = botName {
                            strongSelf.termsOfServiceProceedToBotDisposable.set((strongSelf.context.engine.peers.resolvePeerByName(name: botName, referrer: nil, ageLimit: 10)
                            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                                guard case let .result(result) = result else {
                                    return .complete()
                                }
                                return .single(result)
                            }
                            |> deliverOnMainQueue).start(next: { peer in
                                if let strongSelf = self, let peer = peer {
                                    self?.rootController.pushViewController(ChatControllerImpl(context: strongSelf.context, chatLocation: .peer(id: peer.id)))
                                }
                            }))
                        }
                    })
                }
                
                declineImpl = { [weak controller] in
                    guard let strongSelf = self else {
                        return
                    }
                    let accountId = strongSelf.context.account.id
                    let accountManager = strongSelf.context.sharedContext.accountManager
                    let _ = (strongSelf.context.engine.auth.deleteAccount(reason: "GDPR", password: nil)
                    |> deliverOnMainQueue).start(error: { _ in
                        guard let strongSelf = self else {
                            return
                        }
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        let controller = textAlertController(context: strongSelf.context, title: nil, text: presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])
                        (strongSelf.rootController.viewControllers.last as? ViewController)?.present(controller, in: .window(.root))
                    }, completed: {
                        controller?.dismiss()
                        let _ = logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: true).start()
                    })
                }
                
                (strongSelf.rootController.viewControllers.last as? ViewController)?.present(controller, in: .window(.root))
            }
        }))
        
        self.appUpdateInfoDisposable.set((context.account.stateManager.appUpdateInfo
        |> deliverOnMainQueue).start(next: { [weak self] appUpdateInfo in
            guard let strongSelf = self, strongSelf.currentAppUpdateInfo != appUpdateInfo else {
                return
            }
            
            strongSelf.currentAppUpdateInfo = appUpdateInfo
            if let appUpdateInfo = appUpdateInfo {
                let controller = updateInfoController(context: strongSelf.context, appUpdateInfo: appUpdateInfo)
                strongSelf.mainWindow.present(controller, on: .update)
            }
        }))
        
        if #available(iOS 10.0, *) {
            let permissionsPosition = ValuePromise(0, ignoreRepeated: true)
            self.permissionsDisposable.set((combineLatest(queue: .mainQueue(), requiredPermissions(context: context), permissionUISplitTest(postbox: context.account.postbox), permissionsPosition.get(), context.sharedContext.accountManager.noticeEntry(key: ApplicationSpecificNotice.permissionWarningKey(permission: .contacts)!), context.sharedContext.accountManager.noticeEntry(key: ApplicationSpecificNotice.permissionWarningKey(permission: .notifications)!), context.sharedContext.accountManager.noticeEntry(key: ApplicationSpecificNotice.permissionWarningKey(permission: .cellularData)!))
            |> deliverOnMainQueue).start(next: { [weak self] required, splitTest, position, contactsPermissionWarningNotice, notificationsPermissionWarningNotice, cellularDataPermissionWarningNotice in
                guard let strongSelf = self else {
                    return
                }
                
                let contactsTimestamp = contactsPermissionWarningNotice.value.flatMap({ ApplicationSpecificNotice.getTimestampValue($0) })
                let notificationsTimestamp = notificationsPermissionWarningNotice.value.flatMap({ ApplicationSpecificNotice.getTimestampValue($0) })
                let cellularDataTimestamp = cellularDataPermissionWarningNotice.value.flatMap({ ApplicationSpecificNotice.getTimestampValue($0) })
                if contactsTimestamp == nil, case .requestable = required.0.status {
                    ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .contacts, value: 1)
                }
                if notificationsTimestamp == nil, case .requestable = required.1.status {
                    ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .notifications, value: 1)
                }
                
                let config = splitTest.configuration
                var order = config.order
                if !order.contains(.cellularData) {
                    order.append(.cellularData)
                }
                if !order.contains(.siri) {
                    order.append(.siri)
                }
                var requestedPermissions: [(PermissionState, Bool)] = []
                var i: Int = 0
                for subject in order {
                    if i < position {
                        i += 1
                        continue
                    }
                    var modal = false
                    switch subject {
                        case .contacts:
                            if case .modal = config.contacts {
                                modal = true
                            }
                            if case .requestable = required.0.status, contactsTimestamp != 0 {
                                requestedPermissions.append((required.0, modal))
                            }
                        case .notifications:
                            if case .modal = config.notifications {
                                modal = true
                            }
                            if case .requestable = required.1.status, notificationsTimestamp != 0 {
                                requestedPermissions.append((required.1, modal))
                            }
                        case .cellularData:
                            if case .denied = required.2.status, cellularDataTimestamp != 0 {
                                requestedPermissions.append((required.2, true))
                            }
                        case .siri:
                            if case .requestable = required.3.status {
                                requestedPermissions.append((required.3, false))
                            }
                    }
                    i += 1
                }
                
                if let (state, modal) = requestedPermissions.first {
                    if modal {
                        var didAppear = false
                        let controller: PermissionController
                        if let currentController = strongSelf.currentPermissionsController {
                            controller = currentController
                            didAppear = true
                        } else {
                            controller = PermissionController(context: context, splitTest: splitTest)
                            strongSelf.currentPermissionsController = controller
                        }
                        
                        controller.setState(.permission(state), animated: didAppear)
                        controller.proceed = { resolved in
                            permissionsPosition.set(position + 1)
                            switch state {
                                case .contacts:
                                    ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .contacts, value: 0)
                                case .notifications:
                                    ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .notifications, value: 0)
                                case .cellularData:
                                    ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .cellularData, value: 0)
                                default:
                                    break
                            }
                        }
                        
                        if !didAppear {
                            Queue.mainQueue().after(0.15, {
                                (strongSelf.rootController.viewControllers.last as? ViewController)?.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                            })
                        }
                    } else {
                        if strongSelf.currentPermissionsState != state {
                            strongSelf.currentPermissionsState = state
                            switch state {
                                case .contacts:
                                    splitTest.addEvent(.ContactsRequest)
                                    DeviceAccess.authorizeAccess(to: .contacts, presentationData: context.sharedContext.currentPresentationData.with { $0 }, { result in
                                        if result {
                                            splitTest.addEvent(.ContactsAllowed)
                                        } else {
                                            splitTest.addEvent(.ContactsDenied)
                                        }
                                        permissionsPosition.set(position + 1)
                                        ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .contacts, value: 0)
                                    })
                                case .notifications:
                                    splitTest.addEvent(.NotificationsRequest)
                                    DeviceAccess.authorizeAccess(to: .notifications, registerForNotifications: { result in
                                        context.sharedContext.applicationBindings.registerForNotifications(result)
                                    }, { result in
                                        if result {
                                            splitTest.addEvent(.NotificationsAllowed)
                                        } else {
                                            splitTest.addEvent(.NotificationsDenied)
                                        }
                                        permissionsPosition.set(position + 1)
                                        ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .notifications, value: 0)
                                    })
                                case .cellularData:
                                    DeviceAccess.authorizeAccess(to: .cellularData, presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { [weak self] c, a in
                                        if let strongSelf = self {
                                            (strongSelf.rootController.viewControllers.last as? ViewController)?.present(c, in: .window(.root))
                                        }
                                    }, openSettings: {
                                        context.sharedContext.applicationBindings.openSettings()
                                    }, { result in
                                        permissionsPosition.set(position + 1)
                                        ApplicationSpecificNotice.setPermissionWarning(accountManager: context.sharedContext.accountManager, permission: .cellularData, value: 0)
                                    })
                                case .siri:
                                    DeviceAccess.authorizeAccess(to: .siri, requestSiriAuthorization: { completion in
                                        return context.sharedContext.applicationBindings.requestSiriAuthorization(completion)
                                    }, { result in
                                        permissionsPosition.set(position + 1)
                                    })
                            }
                        }
                    }
                } else {
                    if let controller = strongSelf.currentPermissionsController {
                        strongSelf.currentPermissionsController = nil
                        controller.dismiss(completion: {})
                    }
                    strongSelf.currentPermissionsState = nil
                }
            }))
        }
        
        self.displayAlertsDisposable = (context.account.stateManager.displayAlerts
        |> deliverOnMainQueue).start(next: { [weak self] alerts in
            if let strongSelf = self {
                for (text, isDropAuth) in alerts {
                    let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                    let actions: [TextAlertAction]
                    if isDropAuth {
                        actions = [TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .genericAction, title: presentationData.strings.LogoutOptions_LogOut, action: {
                            if let strongSelf = self {
                                let _ = logoutFromAccount(id: strongSelf.context.account.id, accountManager: strongSelf.context.sharedContext.accountManager, alreadyLoggedOutRemotely: false).start()
                            }
                        })]
                    } else {
                        actions = [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                    }
                    let controller = textAlertController(context: strongSelf.context, title: nil, text: text, actions: actions)
                    (strongSelf.rootController.viewControllers.last as? ViewController)?.present(controller, in: .window(.root))
                }
            }
        })
        
        self.removeNotificationsDisposable = (context.account.stateManager.appliedIncomingReadMessages
        |> deliverOnMainQueue).start(next: { [weak self] ids in
            if let strongSelf = self {
                strongSelf.context.sharedContext.applicationBindings.clearMessageNotifications(ids)
            }
        })
       
        let importableContacts = self.context.sharedContext.contactDataManager?.importable() ?? .single([:])
        let optionalImportableContacts = self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.contactsSettings))
        |> mapToSignal { preferences -> Signal<[DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData], NoError> in
            let settings: ContactsSettings = preferences?.get(ContactsSettings.self) ?? .defaultSettings
            if settings.synchronizeContacts {
                return importableContacts
            } else {
                return .single([:])
            }
        }
        self.context.account.importableContacts.set(optionalImportableContacts)
        self.context.sharedContext.deviceContactPhoneNumbers.set(optionalImportableContacts
        |> map { contacts in
            return Set(contacts.keys.map { cleanPhoneNumber($0.rawValue) })
        })
        
        let previousTheme = Atomic<PresentationTheme?>(value: nil)
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                if previousTheme.swap(presentationData.theme) !== presentationData.theme {
                    strongSelf.lockedCoveringView.updateTheme(presentationData.theme)
                    strongSelf.rootController.updateTheme(NavigationControllerTheme(presentationTheme: presentationData.theme))
                }
            }
        })
        
        let showCallsTabSignal = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
        |> map { sharedData -> (Bool, Bool, Bool) in
            var showCallsTabValue = CallListSettings.defaultSettings.showTab
            var showContactsTabValue = CallListSettings.defaultSettings.showContactsTab
            var showTasksTabValue = CallListSettings.defaultSettings.showTasksTab
            if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) {
                showCallsTabValue = settings.showTab
                showContactsTabValue = settings.showContactsTab
                showTasksTabValue = settings.showTasksTab
            }
            return (showContactsTabValue, showCallsTabValue, showTasksTabValue)
        }
        self.showCallsTabDisposable = (showCallsTabSignal |> deliverOnMainQueue).start(next: { [weak self] showContactsTabValue, showCallsTabValue, showTasksTabValue in
            if let strongSelf = self {
                var needControllersUpdate = false
                if strongSelf.showCallsTab != showCallsTabValue {
                    needControllersUpdate = true
                    strongSelf.showCallsTab = showCallsTabValue
                }
                if strongSelf.showContactsTab != showContactsTabValue {
                    needControllersUpdate = true
                    strongSelf.showContactsTab = showContactsTabValue
                }
                if strongSelf.showTasksTab != showTasksTabValue {
                    needControllersUpdate = true
                    strongSelf.showTasksTab = showTasksTabValue
                }
                if needControllersUpdate {
                    strongSelf.rootController.updateRootControllers(showContactsTab: showContactsTabValue, showCallsTab: showCallsTabValue, showTasksTab: showTasksTabValue)
                }
            }
        })
        
        #if SG_LENTA
        // Zenlygram — Lenta tab: the stored Settings ▸ Tabs choice, else the availability rule
        // (storefront + cached server answer), re-evaluated while this context lives.
        let lentaTabPreference = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
        |> map { sharedData -> Bool? in
            return sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self)?._showLentaTab
        }
        |> distinctUntilChanged
        self.lentaTabDisposable = (SGFeedAvailability.tabVisibility(preference: lentaTabPreference, accountPeerId: context.account.peerId.toInt64())
        |> deliverOnMainQueue).start(next: { [weak self] isVisible in
            self?.rootController.updateLentaTab(isVisible: isVisible)
        })
        #endif
        
        self.rootController.setForceInCallStatusBar((self.context.sharedContext as! SharedAccountContextImpl).currentCallStatusBarNode)
        if let groupCallController = self.context.sharedContext.currentGroupCallController as? VoiceChatController {
            if let overlayController = groupCallController.currentOverlayController {
                groupCallController.parentNavigationController = self.rootController
                self.rootController.presentOverlay(controller: overlayController, inGlobal: true, blockInteraction: false)
            }
        }
    }
    
    deinit {
        self.context.account.postbox.clearCaches()
        self.context.account.shouldKeepOnlinePresence.set(.single(false))
        self.context.account.shouldBeServiceTaskMaster.set(.single(.never))
        self.loggedOutDisposable.dispose()
        self.inAppNotificationSettingsDisposable.dispose()
        self.notificationMessagesDisposable.dispose()
        self.termsOfServiceUpdatesDisposable.dispose()
        self.passcodeLockDisposable.dispose()
        self.passcodeStatusDisposable.dispose()
        self.displayAlertsDisposable?.dispose()
        self.removeNotificationsDisposable?.dispose()
        self.presentationDataDisposable?.dispose()
        self.enablePostboxTransactionsDiposable?.dispose()
        self.termsOfServiceProceedToBotDisposable.dispose()
        self.watchNavigateToMessageDisposable.dispose()
        self.permissionsDisposable.dispose()
        self.scheduledCallPeerDisposable.dispose()
        #if SG_LENTA
        self.lentaTabDisposable?.dispose()
        #endif
    }
    
    #if SG_LENTA
    /// Zenlygram — the Lenta tab state from the settings AppDelegate read for this context, applied
    /// before the first frame (the live signal above follows asynchronously).
    func applyInitialLentaTabPreference(_ preference: Bool?) {
        self.rootController.updateLentaTab(isVisible: SGFeedAvailability.isTabVisible(preference: preference, accountPeerId: self.context.account.peerId.toInt64()))
    }
    #endif
    
    func openNotificationSettings() {
        self.rootController.pushViewController(notificationsAndSoundsController(context: self.context, exceptionsList: nil))
    }
    
    func startCall(peerId: PeerId, isVideo: Bool) {
        guard let appLockContext = self.context.sharedContext.appLockContext as? AppLockContextImpl else {
            return
        }
        self.scheduledCallPeerDisposable.set((appLockContext.isCurrentlyLocked
        |> filter {
            !$0
        }
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            let _ = strongSelf.context.sharedContext.callManager?.requestCall(context: strongSelf.context, peerId: peerId, isVideo: isVideo, endCurrentIfAny: false)
        }))
    }
    
    /// Zenlygram — this account's consent wall is up: deep links, notification taps and root shortcuts are dropped
    /// (not queued) until the user decides (design 40 §5.1).
    private var isConsentWallPresented: Bool {
        return SGCustomerSync.shared.isWallPresented(accountPeerId: self.context.account.peerId.toInt64())
    }

    /// Zenlygram — the install's "Update required" block is up (update_policy_spec §4f): the same drops as behind
    /// the wall, until a corrected policy or the update lifts it.
    private var isUpdateBlockPresented: Bool {
        return SGAppUpdate.shared.isBlockPresented
    }

    /// Deep links, notification taps and root shortcuts are dropped while either is up.
    private var dropsRootActions: Bool {
        return self.isConsentWallPresented || self.isUpdateBlockPresented
    }

    #if SG_LENTA
    func openLentaPush(userInfo: [AnyHashable: Any], accountMatched: Bool) {
        if self.isConsentWallPresented {
            return
        }
        SGFeedPushRouting.open(userInfo: userInfo, accountMatched: accountMatched, context: self.context, navigationController: self.rootController)
    }
    #endif
    
    func openChatWithPeerId(peerId: PeerId, threadId: Int64?, messageId: MessageId? = nil, activateInput: Bool = false, storyId: StoryId?, openAppIfAny: Bool = false, alwaysKeepMessageId: Bool = false) {
        if self.dropsRootActions {
            return
        }
        if let storyId {
            // SG: Secret Vault — the story viewer does not go through navigateToChatController: a story of a chat
            // hidden in this account's closed vault (opened from its notification) asks for the vault PIN first (#20).
            // The viewer then holds the vault and is evicted with it (StoryContainerScreen registers itself).
            if sgSecretVaultInterceptOpen(context: self.context, peerId: storyId.peerId, from: nil, retry: { [weak self] in
                self?.openChatWithPeerId(peerId: peerId, threadId: threadId, messageId: messageId, activateInput: activateInput, storyId: storyId, openAppIfAny: openAppIfAny, alwaysKeepMessageId: alwaysKeepMessageId)
            }) {
                return
            }
            var controllers = self.rootController.viewControllers
            controllers = controllers.filter { c in
                if c is StoryContainerScreen {
                    return false
                }
                return true
            }
            self.rootController.setViewControllers(controllers, animated: false)
            
            self.rootController.chatListController?.openStoriesFromNotification(peerId: storyId.peerId, storyId: storyId.id)
        } else {
            var visiblePeerId: PeerId?
            if let controller = self.rootController.topViewController as? ChatControllerImpl, controller.chatLocation.peerId == peerId, controller.chatLocation.threadId == threadId {
                visiblePeerId = peerId
            }
            
            if visiblePeerId != peerId || messageId != nil {
                let isOutgoingMessage: Signal<Bool, NoError>
                if let messageId {
                    let accountPeerId = self.context.account.peerId
                    isOutgoingMessage = self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                    |> map { message -> Bool in
                        if let message {
                            return !message._asMessage().effectivelyIncoming(accountPeerId)
                        } else {
                            return false
                        }
                    }
                } else {
                    isOutgoingMessage = .single(false)
                }
                let _ = combineLatest(
                    queue: Queue.mainQueue(),
                    self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)),
                    isOutgoingMessage
                ).start(next: { peer, isOutgoingMessage in
                    guard let peer = peer else {
                        return
                    }
                    
                    let chatLocation: NavigateToChatControllerParams.Location
                    if let threadId = threadId {
                        chatLocation = .replyThread(ChatReplyThreadMessage(
                            peerId: peerId, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false
                        ))
                    } else {
                        chatLocation = .peer(peer)
                    }
                    
                    // SG: Secret Vault — #7: the mini app (Spotlight "contact-" item of a bot) bypasses
                    // navigateToChatController, and nothing would tie it to the vault session: a bot hidden in this
                    // account's vault opens its chat instead, through the gated path (vault PIN; the chat holds the
                    // vault and is evicted with it).
                    if openAppIfAny, case let .user(user) = peer, let botInfo = user.botInfo, botInfo.flags.contains(.hasWebApp), !ChatLockSession.shared.isVaultHidden(peerId: peer.id, accountPeerId: self.context.account.peerId), let parentController = self.rootController.viewControllers.last as? ViewController {
                        self.context.sharedContext.openWebApp(
                            context: self.context,
                            parentController: parentController,
                            updatedPresentationData: nil,
                            botPeer: peer,
                            chatPeer: nil,
                            threadId: nil,
                            buttonText: "",
                            url: "",
                            simple: true,
                            source: .generic,
                            skipTermsOfService: true,
                            payload: nil,
                            verifyAgeCompletion: nil
                        )
                    } else {
                        self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: self.rootController, context: self.context, chatLocation: chatLocation, subject: alwaysKeepMessageId || isOutgoingMessage ? messageId.flatMap { .message(id: .id($0), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false) } : nil, activateInput: activateInput ? .text : nil))
                    }
                })
            }
        }
    }
    
    func openUrl(_ url: URL, external: Bool = false) {
        if self.dropsRootActions {
            return
        }
        if self.rootController.rootTabController != nil {
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            self.context.sharedContext.openExternalUrl(context: self.context, urlContext: external ? .external : .generic, url: url.absoluteString, forceExternal: false, presentationData: presentationData, navigationController: self.rootController, dismissInput: { [weak self] in
                self?.rootController.view.endEditing(true)
            })
        } else {
            self.scheduledOpenExternalUrl = url
        }
    }
    
    func openRootSearch() {
        if self.dropsRootActions {
            return
        }
        self.rootController.openChatsController(activateSearch: true)
    }
    
    func openRootCompose() {
        if self.dropsRootActions {
            return
        }
        self.rootController.openRootCompose()
    }
    
    func openRootCamera() {
        if self.dropsRootActions {
            return
        }
        self.rootController.openRootCamera()
    }
    
    func openAppIcon() {
        if self.dropsRootActions {
            return
        }
        self.rootController.openAppIcon()
    }
    
    func switchAccount() {
        let _ = (activeAccountsAndPeers(context: self.context)
        |> take(1)
        |> map { primaryAndAccounts -> (AccountContext, EnginePeer, Int32)? in
            return primaryAndAccounts.1.first
        }
        |> map { accountAndPeer -> AccountContext? in
            if let (context, _, _) = accountAndPeer {
                return context
            } else {
                return nil
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] context in
            guard let strongSelf = self, let context = context else {
                return
            }
            strongSelf.context.sharedContext.switchToAccount(id: context.account.id, fromSettingsController: nil, withChatListController: nil)
        })
    }
    
    private func updateCoveringViewSnaphot(_ visible: Bool) {
        if visible {
            let scale: CGFloat = 0.5
            let unscaledSize = self.mainWindow.hostView.containerView.frame.size
            let image = generateImage(CGSize(width: floor(unscaledSize.width * scale), height: floor(unscaledSize.height * scale)), rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.scaleBy(x: scale, y: scale)
                UIGraphicsPushContext(context)
                self.mainWindow.hostView.containerView.drawHierarchy(in: CGRect(origin: CGPoint(), size: unscaledSize), afterScreenUpdates: false)
                UIGraphicsPopContext()
            }).flatMap(applyScreenshotEffectToImage)
            self.lockedCoveringView.updateSnapshot(image)
        } else {
            self.lockedCoveringView.updateSnapshot(nil)
        }
    }
}
