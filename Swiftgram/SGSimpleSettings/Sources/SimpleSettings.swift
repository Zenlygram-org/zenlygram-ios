import Foundation
import SGAppGroupIdentifier
import SGLogging
import SGProtectedStore

let APP_GROUP_IDENTIFIER = sgAppGroupIdentifier()

public class SGSimpleSettings {
    
    public static let shared = SGSimpleSettings()

    // MARK: In-app language cache
    // Mirrors presentationData.strings.baseLanguageCode so SG static string
    // helpers resolve the in-app Telegram language, not the iOS system locale.
    // Written from SharedAccountContextImpl's presentationData observer (main thread) and read from
    // the off-main chat-list string helpers, so access is serialized under a lock to avoid a data race.
    private var _languageCode: String = Locale.current.languageCode ?? "en"
    private let languageCodeLock = NSLock()
    public var languageCode: String {
        get { self.languageCodeLock.lock(); defer { self.languageCodeLock.unlock() }; return self._languageCode }
        set { self.languageCodeLock.lock(); self._languageCode = newValue; self.languageCodeLock.unlock() }
    }
    
    private init() {
        // Zenlygram — M0 / M6 (audit batch 3, #49): move the settings the app extensions read (Secret Vault flags,
        // kept-deleted messages and edit history rules) to the app-group suite before any wrapper below caches a value.
        SGSharedDefaultsMigration.runIfNeeded()
        setDefaultValues()
        migrate()
        preCacheValues()
    }
    
    private func setDefaultValues() {
        UserDefaults.standard.register(defaults: SGSimpleSettings.defaultValues)
        // Just in case group defaults will be nil
        UserDefaults.standard.register(defaults: SGSimpleSettings.groupDefaultValues)
        if let groupUserDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) {
            groupUserDefaults.register(defaults: SGSimpleSettings.groupDefaultValues)
        }
    }
    
    private func migrate() {
        let showRepostToStoryMigrationKey = "migrated_\(Keys.showRepostToStory.rawValue)"
        if let groupUserDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) {
            if !groupUserDefaults.bool(forKey: showRepostToStoryMigrationKey) {
                self.showRepostToStoryV2 = self.showRepostToStory
                groupUserDefaults.set(true, forKey: showRepostToStoryMigrationKey)
                SGLogger.shared.log("SGSimpleSettings", "Migrated showRepostToStory. \(self.showRepostToStory) -> \(self.showRepostToStoryV2)")
            }
        } else {
            SGLogger.shared.log("SGSimpleSettings", "Unable to migrate showRepostToStory. Shared UserDefaults suite is not available for '\(APP_GROUP_IDENTIFIER)'.")
        }

        let chatListLinesMigrationKey = "migrated_\(Keys.chatListLines.rawValue)"
        if !UserDefaults.standard.bool(forKey: chatListLinesMigrationKey) {
            let legacyCompactMessagePreviewKey = "compactMessagePreview"
            if UserDefaults.standard.object(forKey: legacyCompactMessagePreviewKey) != nil {
                if UserDefaults.standard.bool(forKey: legacyCompactMessagePreviewKey) {
                    self.chatListLines = ChatListLines.one.rawValue
                }
                UserDefaults.standard.removeObject(forKey: legacyCompactMessagePreviewKey)
                SGLogger.shared.log("SGSimpleSettings", "Migrated compactMessagePreview -> chatListLines. \(self.chatListLines)")
            }
            UserDefaults.standard.set(true, forKey: chatListLinesMigrationKey)
        }

        // MARK: Zenlygram — the two capture features default ON (owner decision, 2026-09-24).
        //
        // Flipping a default here is not just a matter of changing the registered value, for two
        // reasons that both bite silently:
        //
        // 1. `object(forKey:)` RETURNS registered defaults, so it cannot answer "did the user ever
        //    choose?". `showDeletedMessages` is in `groupDefaultValues`, so an absence check
        //    written with `object(forKey:)` would find a value for every install and do nothing at
        //    all. `persistentDomain(forName:)` returns only what was actually written, which is
        //    exactly the question.
        // 2. The registration domain is installed by THIS initialiser. An app extension that reads
        //    `sharedGroupDefaults` without going through `SGSimpleSettings.shared` would not see a
        //    registered default, so the app and the NSE could disagree. Writing the value
        //    persistently once removes that class of bug.
        //
        // The rule: write `true` only where nothing was ever persisted. Someone who deliberately
        // turned either feature off keeps it off, forever — the persisted `false` is left alone.
        //
        // These features keep copies of messages OTHER people deleted, on this device, so
        // `appstore/privacy-policy.html` and the store metadata state that they are on by default
        // and how to turn them off.
        let captureDefaultsMigrationKey = "migrated_captureDefaultsOnV1"
        if let groupUserDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) {
            if !groupUserDefaults.bool(forKey: captureDefaultsMigrationKey) {
                let persisted = UserDefaults.standard.persistentDomain(forName: APP_GROUP_IDENTIFIER) ?? [:]
                var turnedOn: [String] = []
                for key in [Keys.showDeletedMessages.rawValue, Keys.editHistoryEnabled.rawValue] {
                    if persisted[key] == nil {
                        groupUserDefaults.set(true, forKey: key)
                        turnedOn.append(key)
                    }
                }
                groupUserDefaults.set(true, forKey: captureDefaultsMigrationKey)
                SGLogger.shared.log("SGSimpleSettings", "Capture defaults: turned on \(turnedOn.isEmpty ? "nothing (both were an explicit choice)" : turnedOn.joined(separator: ", "))")
            }
        } else {
            SGLogger.shared.log("SGSimpleSettings", "Unable to apply capture defaults. Shared UserDefaults suite is not available for '\(APP_GROUP_IDENTIFIER)'.")
        }
    }

    private func preCacheValues() {
        // let dispatchGroup = DispatchGroup()

        let tasks = [
//            { let _ = self.allChatsFolderPositionOverride },
            { let _ = self.tabBarSearchEnabled },
            { let _ = self.allChatsHidden },
            { let _ = self.hideTabBar },
            { let _ = self.bottomTabStyle },
            { let _ = self.compactChatList },
            { let _ = self.chatListLines },
            { let _ = self.compactFolderNames },
            { let _ = self.disableSwipeToRecordStory },
            { let _ = self.rememberLastFolder },
            { let _ = self.quickTranslateButton },
            { let _ = self.stickerSize },
            { let _ = self.stickerTimestamp },
            { let _ = self.hideReactions },
            { let _ = self.disableGalleryCamera },
            { let _ = self.disableSendAsButton },
            { let _ = self.disableSnapDeletionEffect },
            { let _ = self.startTelescopeWithRearCam },
            { let _ = self.hideRecordingButton },
            { let _ = self.inputToolbar },
            { let _ = self.dismissedSGSuggestions },
            { let _ = self.customAppBadge }
        ]

        tasks.forEach { task in
            DispatchQueue.global(qos: .background).async(/*group: dispatchGroup*/) {
                task()
            }
        }

        // dispatchGroup.notify(queue: DispatchQueue.main) {}
    }
    
    public func synchronizeShared() {
        if let groupUserDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) {
            groupUserDefaults.synchronize()
        }
    }
    
    public enum Keys: String, CaseIterable {
        case hidePhoneInSettings
        case contextShowEditedHistory
        case showTabNames
        case startTelescopeWithRearCam
        case accountColorsSaturation
        case uploadSpeedBoost
        case downloadSpeedBoost
        case bottomTabStyle
        case rememberLastFolder
        case lastAccountFolders
        case localDNSForProxyHost
        case sendLargePhotos
        case outgoingPhotoQuality
        case storyStealthMode
        case canUseStealthMode
        case disableSwipeToRecordStory
        case quickTranslateButton
        case outgoingLanguageTranslation
        case hideReactions
        case showRepostToStory
        case showRepostToStoryV2
        case contextShowSelectFromUser
        case contextShowSaveToCloud
        case contextShowRestrict
        // case contextShowBan
        case contextShowHideForwardName
        case contextShowReport
        case contextShowReply
        case contextShowPin
        case contextShowSaveMedia
        case contextShowMessageReplies
        case contextShowJson
        case disableScrollToNextChannel
        case disableScrollToNextTopic
        case disableChatSwipeOptions
        case disableDeleteChatSwipeOption
        case disableGalleryCamera
        case disableGalleryCameraPreview
        case disableSendAsButton
        case disableSnapDeletionEffect
        case stickerSize
        case stickerTimestamp
        case hideRecordingButton
        case hideTabBar
        case showDC
        case showCreationDate
        case showRegDate
        case regDateCache
        case compactChatList
        case chatListLines
        case compactFolderNames
        case allChatsTitleLengthOverride
//        case allChatsFolderPositionOverride
        case allChatsHidden
        case defaultEmojisFirst
        case messageDoubleTapActionOutgoing
        case wideChannelPosts
        case forceEmojiTab
        case forceBuiltInMic
        case secondsInMessages
        case hideChannelBottomButton
        case forceSystemSharing
        case confirmCalls
        case videoPIPSwipeDirection
        case legacyNotificationsFix
        case messageFilterKeywords
        case inputToolbar
        case pinnedMessageNotifications
        case mentionsAndRepliesNotifications
        case primaryUserId
        case status
        case dismissedSGSuggestions
        case secretVaultEnabled
        case secretVaultPeerIds
        case secretVaultMutedPeerIds
        case duckyAppIconAvailable
        case transcriptionBackend
        case translationBackend
        case customAppBadge
        case canUseNY
        case nyStyle
        case wideTabBar
        case tabBarSearchEnabled
        case hideStories
        case warnOnStoriesOpen
        case showProfileId
        case sendWithReturnKey
        case unlimitedPinnedChats
        case unreadReminderEnabled
        case unreadReminderMinutes
        case blockForeignUsers
        case ownPhoneNumber
        case sendRoundVideoFromGallery
        case aiAssistantEnabled
        case aiAssistantDisclosureAccepted
        case autoProxyEnabled
        case autoDownloadDisabled
        case autoAcceptRequests
        case folderDisplayStyle
        case showViewFirstMessage
        case showDeletedMessages
        case secretVaultUseSecretCode
        case newBadgeFirstSeen
        case newBadgeInteracted
        case deletedMessagesRegistry
        case deletedMessagesLastSweep
        case editHistoryEnabled
        case editHistoryPurgeBefore
        case keptDeletedPurgeBefore
        case editHistoryCaptureBlocked
        // MARK: Zenlygram — local call recording (SGCallRecording).
        case callRecordingConsentAccepted
        case callRecordingNotifyOtherParty
        case callRecordingSendToSavedMessages
        // MARK: Zenlygram — QA override of the app-update decision (update_policy_spec §4h).
        case appUpdateDebugOverride
    }
    
    public enum DownloadSpeedBoostValues: String, CaseIterable {
        case none
        case medium
        case maximum
    }
    
    public enum BottomTabStyleValues: String, CaseIterable {
        case telegram
        case ios
    }
    
    public enum AllChatsTitleLengthOverride: String, CaseIterable {
        case none
        case short
        case long
    }
    
    public enum AllChatsFolderPositionOverride: String, CaseIterable {
        case none
        case last
        case hidden
    }

    public enum ChatListLines: String, CaseIterable {
        case three = "3"
        case two = "2"
        case one = "1"

        public static let defaultValue: ChatListLines = .three
    }
    
    public enum MessageDoubleTapAction: String, CaseIterable {
        case `default`
        case none
        case edit
    }
    
    public enum VideoPIPSwipeDirection: String, CaseIterable {
        case up
        case down
        case none
    }

    public enum TranscriptionBackend: String, CaseIterable {
        case `default`
        case apple
    }

    public enum TranslationBackend: String, CaseIterable {
        case `default`
        case gtranslate
        case system
        // Make sure to update TranslationConfiguration
    }
        
    public enum PinnedMessageNotificationsSettings: String, CaseIterable {
        case `default`
        case silenced
        case disabled
    }
    
    public enum MentionsAndRepliesNotificationsSettings: String, CaseIterable {
        case `default`
        case silenced
        case disabled
    }

    public enum NYStyle: String, CaseIterable {
        case `default`
        case snow
        case lightning
    }
    
    public static let defaultValues: [String: Any] = [
        Keys.hidePhoneInSettings.rawValue: true,
        Keys.contextShowEditedHistory.rawValue: true,
        Keys.showTabNames.rawValue: true,
        Keys.startTelescopeWithRearCam.rawValue: false,
        Keys.accountColorsSaturation.rawValue: 100,
        Keys.uploadSpeedBoost.rawValue: false,
        Keys.downloadSpeedBoost.rawValue: DownloadSpeedBoostValues.none.rawValue,
        Keys.rememberLastFolder.rawValue: false,
        Keys.bottomTabStyle.rawValue: BottomTabStyleValues.telegram.rawValue,
        Keys.lastAccountFolders.rawValue: [:],
        Keys.localDNSForProxyHost.rawValue: false,
        Keys.sendLargePhotos.rawValue: false,
        Keys.outgoingPhotoQuality.rawValue: 70,
        Keys.storyStealthMode.rawValue: false,
        Keys.canUseStealthMode.rawValue: true,
        Keys.disableSwipeToRecordStory.rawValue: false,
        Keys.quickTranslateButton.rawValue: false,
        Keys.outgoingLanguageTranslation.rawValue: [:],
        Keys.hideReactions.rawValue: false,
        Keys.showRepostToStory.rawValue: true,
        Keys.contextShowSelectFromUser.rawValue: true,
        Keys.contextShowSaveToCloud.rawValue: true,
        Keys.contextShowRestrict.rawValue: true,
        // Keys.contextShowBan.rawValue: true,
        Keys.contextShowHideForwardName.rawValue: true,
        Keys.contextShowReport.rawValue: true,
        Keys.contextShowReply.rawValue: true,
        Keys.contextShowPin.rawValue: true,
        Keys.contextShowSaveMedia.rawValue: true,
        Keys.contextShowMessageReplies.rawValue: true,
        Keys.contextShowJson.rawValue: false,
        Keys.disableScrollToNextChannel.rawValue: false,
        Keys.disableScrollToNextTopic.rawValue: false,
        Keys.disableChatSwipeOptions.rawValue: false,
        Keys.disableDeleteChatSwipeOption.rawValue: false,
        Keys.disableGalleryCamera.rawValue: false,
        Keys.disableGalleryCameraPreview.rawValue: false,
        Keys.disableSendAsButton.rawValue: false,
        Keys.disableSnapDeletionEffect.rawValue: false,
        Keys.stickerSize.rawValue: 100,
        Keys.stickerTimestamp.rawValue: true,
        Keys.hideRecordingButton.rawValue: false,
        Keys.hideTabBar.rawValue: false,
        Keys.showDC.rawValue: false,
        Keys.showCreationDate.rawValue: true,
        Keys.showRegDate.rawValue: true,
        Keys.regDateCache.rawValue: [:],
        Keys.compactChatList.rawValue: false,
        Keys.chatListLines.rawValue: ChatListLines.defaultValue.rawValue,
        Keys.compactFolderNames.rawValue: false,
        Keys.allChatsTitleLengthOverride.rawValue: AllChatsTitleLengthOverride.none.rawValue,
//        Keys.allChatsFolderPositionOverride.rawValue: AllChatsFolderPositionOverride.none.rawValue
        Keys.allChatsHidden.rawValue: false,
        Keys.defaultEmojisFirst.rawValue: false,
        Keys.messageDoubleTapActionOutgoing.rawValue: MessageDoubleTapAction.default.rawValue,
        Keys.wideChannelPosts.rawValue: false,
        Keys.forceEmojiTab.rawValue: false,
        Keys.hideChannelBottomButton.rawValue: false,
        Keys.secondsInMessages.rawValue: false,
        Keys.forceSystemSharing.rawValue: false,
        Keys.confirmCalls.rawValue: true,
        Keys.videoPIPSwipeDirection.rawValue: VideoPIPSwipeDirection.up.rawValue,
        Keys.messageFilterKeywords.rawValue: [],
        Keys.inputToolbar.rawValue: false,
        Keys.primaryUserId.rawValue: "",
        Keys.dismissedSGSuggestions.rawValue: [],
        Keys.secretVaultPeerIds.rawValue: [],
        Keys.secretVaultMutedPeerIds.rawValue: [],
        Keys.duckyAppIconAvailable.rawValue: true,
        Keys.transcriptionBackend.rawValue: TranscriptionBackend.default.rawValue,
        Keys.translationBackend.rawValue: TranslationBackend.default.rawValue,
        Keys.customAppBadge.rawValue: "",
        Keys.canUseNY.rawValue: false,
        Keys.nyStyle.rawValue: NYStyle.default.rawValue,
        Keys.wideTabBar.rawValue: false,
        Keys.tabBarSearchEnabled.rawValue: true,
        Keys.hideStories.rawValue: false,
        Keys.warnOnStoriesOpen.rawValue: false,
        Keys.showProfileId.rawValue: true,
        Keys.sendWithReturnKey.rawValue: false,
        Keys.unlimitedPinnedChats.rawValue: false,
        Keys.unreadReminderEnabled.rawValue: false,
        Keys.unreadReminderMinutes.rawValue: 5,
        Keys.blockForeignUsers.rawValue: false,
        Keys.ownPhoneNumber.rawValue: "",
        Keys.sendRoundVideoFromGallery.rawValue: true,
        Keys.aiAssistantEnabled.rawValue: false,
        Keys.aiAssistantDisclosureAccepted.rawValue: false,
        Keys.autoProxyEnabled.rawValue: false,
        Keys.autoDownloadDisabled.rawValue: false,
        Keys.autoAcceptRequests.rawValue: false,
        Keys.folderDisplayStyle.rawValue: "auto",
        Keys.showViewFirstMessage.rawValue: false,
        Keys.newBadgeFirstSeen.rawValue: [:],
        Keys.newBadgeInteracted.rawValue: [:],
        // MARK: Zenlygram — call recording. Both OFF: recording never happens without the one-time
        // consent screen, and the "tell the other party" notice is opt-in (owner's decision).
        Keys.callRecordingConsentAccepted.rawValue: false,
        Keys.callRecordingNotifyOtherParty.rawValue: false,
        // OFF: nothing is uploaded until the user turns this on and reads what turning it on means.
        Keys.callRecordingSendToSavedMessages.rawValue: false,
        // Zenlygram — "none": the signed app-update policy decides (see `appUpdateDebugOverride`).
        Keys.appUpdateDebugOverride.rawValue: "none"
    ]
    
    public static let groupDefaultValues: [String: Any] = [
        Keys.legacyNotificationsFix.rawValue: false,
        Keys.pinnedMessageNotifications.rawValue: PinnedMessageNotificationsSettings.default.rawValue,
        Keys.mentionsAndRepliesNotifications.rawValue: MentionsAndRepliesNotificationsSettings.default.rawValue,
        Keys.status.rawValue: 1,
        Keys.showRepostToStoryV2.rawValue: true,
        // Zenlygram — shared with the app extensions (audit batch 3): Secret Vault flags, kept-deleted messages.
        Keys.secretVaultEnabled.rawValue: false,
        Keys.secretVaultUseSecretCode.rawValue: false,
        // Zenlygram — ON by default (2026-09-24). The migration in `migrate()` also persists it,
        // because an extension that never builds `SGSimpleSettings.shared` never installs this
        // registration domain.
        Keys.showDeletedMessages.rawValue: true,
        Keys.editHistoryEnabled.rawValue: true,
    ]
    
    @UserDefault(key: Keys.hidePhoneInSettings.rawValue)
    public var hidePhoneInSettings: Bool

    @UserDefault(key: Keys.contextShowEditedHistory.rawValue)
    public var contextShowEditedHistory: Bool
    
    @UserDefault(key: Keys.showTabNames.rawValue)
    public var showTabNames: Bool
    
    @UserDefault(key: Keys.startTelescopeWithRearCam.rawValue)
    public var startTelescopeWithRearCam: Bool
    
    @UserDefault(key: Keys.accountColorsSaturation.rawValue)
    public var accountColorsSaturation: Int32
    
    @UserDefault(key: Keys.uploadSpeedBoost.rawValue)
    public var uploadSpeedBoost: Bool
    
    @UserDefault(key: Keys.downloadSpeedBoost.rawValue)
    public var downloadSpeedBoost: String
    
    @UserDefault(key: Keys.rememberLastFolder.rawValue)
    public var rememberLastFolder: Bool
    
    // Disabled while Telegram is migrating to Glass
    // @UserDefault(key: Keys.bottomTabStyle.rawValue)
    public var bottomTabStyle: String {
        set {}
        get {
            return BottomTabStyleValues.ios.rawValue
        }
    }
    
    public var lastAccountFolders = UserDefaultsBackedDictionary<String, Int32>(userDefaultsKey: Keys.lastAccountFolders.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.localDNSForProxyHost.rawValue)
    public var localDNSForProxyHost: Bool
    
    @UserDefault(key: Keys.sendLargePhotos.rawValue)
    public var sendLargePhotos: Bool
    
    @UserDefault(key: Keys.outgoingPhotoQuality.rawValue)
    public var outgoingPhotoQuality: Int32

    @UserDefault(key: Keys.hideStories.rawValue)
    public var hideStories: Bool

    @UserDefault(key: Keys.warnOnStoriesOpen.rawValue)
    public var warnOnStoriesOpen: Bool
    
    @UserDefault(key: Keys.storyStealthMode.rawValue)
    public var storyStealthMode: Bool
    
    @UserDefault(key: Keys.canUseStealthMode.rawValue)
    public var canUseStealthMode: Bool    
    
    @UserDefault(key: Keys.disableSwipeToRecordStory.rawValue)
    public var disableSwipeToRecordStory: Bool   
    
    @UserDefault(key: Keys.quickTranslateButton.rawValue)
    public var quickTranslateButton: Bool
    
    public var outgoingLanguageTranslation = UserDefaultsBackedDictionary<String, String>(userDefaultsKey: Keys.outgoingLanguageTranslation.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.hideReactions.rawValue)
    public var hideReactions: Bool

    // @available(*, deprecated, message: "Use showRepostToStoryV2 instead")
    @UserDefault(key: Keys.showRepostToStory.rawValue)
    public var showRepostToStory: Bool

    @UserDefault(key: Keys.showRepostToStoryV2.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var showRepostToStoryV2: Bool

    @UserDefault(key: Keys.contextShowRestrict.rawValue)
    public var contextShowRestrict: Bool

    /*@UserDefault(key: Keys.contextShowBan.rawValue)
    public var contextShowBan: Bool*/

    @UserDefault(key: Keys.contextShowSelectFromUser.rawValue)
    public var contextShowSelectFromUser: Bool

    @UserDefault(key: Keys.contextShowSaveToCloud.rawValue)
    public var contextShowSaveToCloud: Bool

    @UserDefault(key: Keys.contextShowHideForwardName.rawValue)
    public var contextShowHideForwardName: Bool

    @UserDefault(key: Keys.contextShowReport.rawValue)
    public var contextShowReport: Bool

    @UserDefault(key: Keys.contextShowReply.rawValue)
    public var contextShowReply: Bool

    @UserDefault(key: Keys.contextShowPin.rawValue)
    public var contextShowPin: Bool

    @UserDefault(key: Keys.contextShowSaveMedia.rawValue)
    public var contextShowSaveMedia: Bool

    @UserDefault(key: Keys.contextShowMessageReplies.rawValue)
    public var contextShowMessageReplies: Bool
    
    @UserDefault(key: Keys.contextShowJson.rawValue)
    public var contextShowJson: Bool
    
    @UserDefault(key: Keys.disableScrollToNextChannel.rawValue)
    public var disableScrollToNextChannel: Bool

    @UserDefault(key: Keys.disableScrollToNextTopic.rawValue)
    public var disableScrollToNextTopic: Bool

    @UserDefault(key: Keys.disableChatSwipeOptions.rawValue)
    public var disableChatSwipeOptions: Bool

    @UserDefault(key: Keys.disableDeleteChatSwipeOption.rawValue)
    public var disableDeleteChatSwipeOption: Bool

    @UserDefault(key: Keys.disableGalleryCamera.rawValue)
    public var disableGalleryCamera: Bool

    @UserDefault(key: Keys.disableGalleryCameraPreview.rawValue)
    public var disableGalleryCameraPreview: Bool

    @UserDefault(key: Keys.disableSendAsButton.rawValue)
    public var disableSendAsButton: Bool

    @UserDefault(key: Keys.disableSnapDeletionEffect.rawValue)
    public var disableSnapDeletionEffect: Bool
    
    @UserDefault(key: Keys.stickerSize.rawValue)
    public var stickerSize: Int32
    
    @UserDefault(key: Keys.stickerTimestamp.rawValue)
    public var stickerTimestamp: Bool    

    @UserDefault(key: Keys.hideRecordingButton.rawValue)
    public var hideRecordingButton: Bool
    
    @UserDefault(key: Keys.hideTabBar.rawValue)
    public var hideTabBar: Bool

    @UserDefault(key: Keys.showProfileId.rawValue)
    public var showProfileId: Bool
    
    @UserDefault(key: Keys.showDC.rawValue)
    public var showDC: Bool
    
    @UserDefault(key: Keys.showCreationDate.rawValue)
    public var showCreationDate: Bool

    @UserDefault(key: Keys.showRegDate.rawValue)
    public var showRegDate: Bool

    public var regDateCache = UserDefaultsBackedDictionary<String, Data>(userDefaultsKey: Keys.regDateCache.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.compactChatList.rawValue)
    public var compactChatList: Bool

    @UserDefault(key: Keys.chatListLines.rawValue)
    public var chatListLines: String

    @UserDefault(key: Keys.compactFolderNames.rawValue)
    public var compactFolderNames: Bool
    
    @UserDefault(key: Keys.allChatsTitleLengthOverride.rawValue)
    public var allChatsTitleLengthOverride: String
//    
//    @UserDefault(key: Keys.allChatsFolderPositionOverride.rawValue)
//    public var allChatsFolderPositionOverride: String
    @UserDefault(key: Keys.allChatsHidden.rawValue)
    public var allChatsHidden: Bool

    @UserDefault(key: Keys.defaultEmojisFirst.rawValue)
    public var defaultEmojisFirst: Bool
    
    @UserDefault(key: Keys.messageDoubleTapActionOutgoing.rawValue)
    public var messageDoubleTapActionOutgoing: String
    
    @UserDefault(key: Keys.wideChannelPosts.rawValue)
    public var wideChannelPosts: Bool

    @UserDefault(key: Keys.forceEmojiTab.rawValue)
    public var forceEmojiTab: Bool
    
    @UserDefault(key: Keys.forceBuiltInMic.rawValue)
    public var forceBuiltInMic: Bool
    
    @UserDefault(key: Keys.secondsInMessages.rawValue)
    public var secondsInMessages: Bool
    
    @UserDefault(key: Keys.hideChannelBottomButton.rawValue)
    public var hideChannelBottomButton: Bool

    @UserDefault(key: Keys.forceSystemSharing.rawValue)
    public var forceSystemSharing: Bool

    @UserDefault(key: Keys.confirmCalls.rawValue)
    public var confirmCalls: Bool
    
    @UserDefault(key: Keys.videoPIPSwipeDirection.rawValue)
    public var videoPIPSwipeDirection: String

    @UserDefault(key: Keys.legacyNotificationsFix.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var legacyNotificationsFix: Bool
    
    @UserDefault(key: Keys.status.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var status: Int64

    public var ephemeralStatus: Int64 = 1
    
    @UserDefault(key: Keys.messageFilterKeywords.rawValue)
    public var messageFilterKeywords: [String]
    
    @UserDefault(key: Keys.inputToolbar.rawValue)
    public var inputToolbar: Bool

    @UserDefault(key: Keys.sendWithReturnKey.rawValue)
    public var sendWithReturnKey: Bool

    @UserDefault(key: Keys.unlimitedPinnedChats.rawValue)
    public var unlimitedPinnedChats: Bool

    @UserDefault(key: Keys.unreadReminderEnabled.rawValue)
    public var unreadReminderEnabled: Bool

    @UserDefault(key: Keys.unreadReminderMinutes.rawValue)
    public var unreadReminderMinutes: Int32

    @UserDefault(key: Keys.blockForeignUsers.rawValue)
    public var blockForeignUsers: Bool

    @UserDefault(key: Keys.ownPhoneNumber.rawValue)
    public var ownPhoneNumber: String

    @UserDefault(key: Keys.sendRoundVideoFromGallery.rawValue)
    public var sendRoundVideoFromGallery: Bool

    @UserDefault(key: Keys.aiAssistantEnabled.rawValue)
    public var aiAssistantEnabled: Bool

    // One-time App Store data-collection disclosure for the AI Assistant:
    // set once the user confirms that selected message text goes to Anthropic
    // and the API key stays in the local Keychain.
    @UserDefault(key: Keys.aiAssistantDisclosureAccepted.rawValue)
    public var aiAssistantDisclosureAccepted: Bool

    // MARK: Zenlygram — local call recording.
    //
    // One-time consent for recording a call, in the same shape as `aiAssistantDisclosureAccepted`.
    // Apple guideline 2.5.14 requires explicit consent before an app makes a record of user
    // activity; this flag IS that consent, and nothing sets it but the first-use screen. Recording
    // refuses forever while it is false.
    @UserDefault(key: Keys.callRecordingConsentAccepted.rawValue)
    public var callRecordingConsentAccepted: Bool

    // Optional notice to the other party, default OFF. It sends a real chat message and plays a
    // local tone — it cannot put audio into the call itself, and the setting's description says so.
    @UserDefault(key: Keys.callRecordingNotifyOtherParty.rawValue)
    public var callRecordingNotifyOtherParty: Bool

    // Send a finished recording to the user's own Saved Messages, default OFF. It is the only thing
    // that uploads a recording without the user tapping an action in that moment, and the recording
    // becomes an ordinary Telegram cloud message — stored on Telegram's servers, not end-to-end
    // encrypted. The switch's description says exactly that.
    @UserDefault(key: Keys.callRecordingSendToSavedMessages.rawValue)
    public var callRecordingSendToSavedMessages: Bool

    // MARK: Zenlygram — QA override of the app-update DECISION (update_policy_spec §4h).
    //
    // Read by non-App-Store builds only (`GlobalExperimentalSettings.isAppStoreBuild` false; a store build never
    // reads it). The Debug Settings row ("App update override", Zenlygram Debug) writes it, and QA can set it before
    // launch — it lives in the app's own defaults domain (the bundle id), not the app group:
    //
    //   xcrun simctl spawn <udid> defaults write <bundle id> appUpdateDebugOverride block
    //   xcrun simctl spawn <udid> defaults write <bundle id> appUpdateDebugOverride remind
    //   xcrun simctl spawn <udid> defaults delete <bundle id> appUpdateDebugOverride      # back to the policy
    //
    // Values: "none" (the signed policy decides — the default), "remind" (one "Update available" alert per launch,
    // as if the signed latest were 99.0), "block" (the full-screen "Update required" overlay, as if the signed min
    // were 99.0; the relaunch shows it as the first frame). It replaces the decision only: no signed policy is ever
    // written or read differently (zg.app.policy.v1@<origin> stays what the server signed), the refresh keeps running,
    // and the reminder marker (zg.app.policy.reminded@<origin>) is not written under an override. Anything else than
    // the three values reads as "none".
    @UserDefault(key: Keys.appUpdateDebugOverride.rawValue)
    public var appUpdateDebugOverride: String

    @UserDefault(key: Keys.autoProxyEnabled.rawValue)
    public var autoProxyEnabled: Bool

    @UserDefault(key: Keys.autoDownloadDisabled.rawValue)
    public var autoDownloadDisabled: Bool

    @UserDefault(key: Keys.autoAcceptRequests.rawValue)
    public var autoAcceptRequests: Bool

    @UserDefault(key: Keys.folderDisplayStyle.rawValue)
    public var folderDisplayStyle: String

    @UserDefault(key: Keys.showViewFirstMessage.rawValue)
    public var showViewFirstMessage: Bool

    // Zenlygram — in the app-group suite (audit #49): the Share / Notification Service extensions honour it too.
    @UserDefault(key: Keys.showDeletedMessages.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    private var cachedShowDeletedMessages: Bool

    /// Main app: the cached wrapper. App extensions (the long-lived NSE in particular) read the group suite
    /// uncached, so a toggle in the app applies to them without a relaunch.
    public var showDeletedMessages: Bool {
        get {
            if SGProtectedStore.isAppExtension {
                return SGSimpleSettings.sharedGroupDefaults.bool(forKey: Keys.showDeletedMessages.rawValue)
            }
            return self.cachedShowDeletedMessages
        }
        set {
            self.cachedShowDeletedMessages = newValue
        }
    }

    // Zenlygram — in the app-group suite (audit batch 3).
    @UserDefault(key: Keys.secretVaultUseSecretCode.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var secretVaultUseSecretCode: Bool

    @UserDefault(key: Keys.pinnedMessageNotifications.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var pinnedMessageNotifications: String
    
    @UserDefault(key: Keys.mentionsAndRepliesNotifications.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var mentionsAndRepliesNotifications: String
    
    @UserDefault(key: Keys.primaryUserId.rawValue)
    public var primaryUserId: String

    @UserDefault(key: Keys.dismissedSGSuggestions.rawValue)
    public var dismissedSGSuggestions: [String]

    // Zenlygram — in the app-group suite (audit batch 3): SGProtectedStore and the extensions read it uncached.
    @UserDefault(key: Keys.secretVaultEnabled.rawValue, userDefaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public var secretVaultEnabled: Bool

    @UserDefault(key: Keys.secretVaultPeerIds.rawValue)
    public var secretVaultPeerIds: [String]

    @UserDefault(key: Keys.secretVaultMutedPeerIds.rawValue)
    public var secretVaultMutedPeerIds: [String]

    @UserDefault(key: Keys.duckyAppIconAvailable.rawValue)
    public var duckyAppIconAvailable: Bool

    @UserDefault(key: Keys.transcriptionBackend.rawValue)
    public var transcriptionBackend: String

    @UserDefault(key: Keys.translationBackend.rawValue)
    public var translationBackend: String

    @UserDefault(key: Keys.customAppBadge.rawValue)
    public var customAppBadge: String

    @UserDefault(key: Keys.canUseNY.rawValue)
    public var canUseNY: Bool

    @UserDefault(key: Keys.nyStyle.rawValue)
    public var nyStyle: String

    @UserDefault(key: Keys.wideTabBar.rawValue)
    public var wideTabBar: Bool
    
    @UserDefault(key: Keys.tabBarSearchEnabled.rawValue)
    public var tabBarSearchEnabled: Bool

    // MARK: Kept-deleted messages and edit history retention (Batch 6)
    // The retention registry is the account Postbox itself: kept-deleted stamps and edit-history revisions
    // are indexed by Postbox (SGTimestampBasedMessageAttributesTable) and swept by TelegramCore
    // (State/SGMessageRetention.swift). It replaces the UserDefaults registry (#91), including Batch 3's
    // per-extension registry keys (#49): the Postbox lives in the app-group container, so a delete or edit
    // that the Share or Notification Service extension applies is stamped and indexed there by the same
    // replay code as in the app.
    //
    // Zenlygram — audit #49: that replay code runs in the extensions too, so every setting it reads lives in
    // the app-group suite (showDeletedMessages above and the keys below, moved from UserDefaults.standard
    // once by SGSharedDefaultsMigration before this class caches anything). These accessors read the suite
    // directly with no @UserDefault cache: TelegramCore reads them on the Postbox queue, and the long-lived
    // NSE sees a change made in the app without a relaunch. Only the main app writes them; read-modify-write
    // updates are serialized by the lock below.
    // Destructive purges are driven ONLY by the persisted *PurgeBefore timestamps (a missing or
    // unreadable value is 0 = purge nothing), never by a Bool that may read false before first unlock.
    private let deletedMessagesRetentionLock = NSLock()

    /// The app-group suite (falls back to standard defaults when the group container is unavailable).
    static let sharedGroupDefaults: UserDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard

    /// Local edit history. ON by default since 2026-09-24 (applied by the capture-defaults migration
    /// above, which never overrides an explicit choice); an absent key still reads false, so the
    /// migration is what makes the default true.
    public var editHistoryEnabled: Bool {
        get {
            return SGSimpleSettings.sharedGroupDefaults.bool(forKey: Keys.editHistoryEnabled.rawValue)
        }
        set {
            SGSimpleSettings.sharedGroupDefaults.set(newValue, forKey: Keys.editHistoryEnabled.rawValue)
        }
    }

    /// MARK: Zenlygram — the entitlement's only reach into the Postbox replay path.
    ///
    /// Recording NEW retained history (a kept copy of a message someone else deleted, a previous
    /// version of one they edited) is a create gated by `SGEntitlementGatedAction
    /// .createRetainedHistoryRecord` (monetization policy `saved_history`). The replay runs inside
    /// `TelegramCore` (no UIKit module, so no `SGEntitlement`), in the app AND in the Notification
    /// Service, so the decision is mirrored here: by the main app (`sgUpdateEntitlementMirroredFlags`)
    /// and by the Notification Service from the App Group mirror before its replay. Both apply
    /// `SGEntitlementRetainedHistoryCapture`, and an unknown decision leaves the value alone.
    /// Reading or removing history that was already retained never reads this flag.
    ///
    /// The sense is inverted on purpose: the stored flag is "BLOCKED", so an absent key, an
    /// unreadable suite and a device before first unlock all read `false` = capture allowed, the
    /// free-first default.
    public var editHistoryCaptureBlocked: Bool {
        get {
            return SGSimpleSettings.sharedGroupDefaults.bool(forKey: Keys.editHistoryCaptureBlocked.rawValue)
        }
        set {
            SGSimpleSettings.sharedGroupDefaults.set(newValue, forKey: Keys.editHistoryCaptureBlocked.rawValue)
        }
    }

    /// Edit-history revisions captured at or before this Unix time are purged (0 = none).
    public var editHistoryPurgeBefore: Int32 {
        return Int32(clamping: SGSimpleSettings.sharedGroupDefaults.integer(forKey: Keys.editHistoryPurgeBefore.rawValue))
    }

    /// Kept-deleted messages stamped at or before this Unix time are purged (0 = none).
    public var keptDeletedPurgeBefore: Int32 {
        return Int32(clamping: SGSimpleSettings.sharedGroupDefaults.integer(forKey: Keys.keptDeletedPurgeBefore.rawValue))
    }

    /// Requests deletion of every kept-deleted message stamped until now (all accounts, incl. not loaded ones).
    public func requestKeptDeletedPurge() {
        self.requestPurge(key: Keys.keptDeletedPurgeBefore.rawValue)
    }

    /// Requests deletion of every edit-history revision captured until now (all accounts, incl. not loaded ones).
    public func requestEditHistoryPurge() {
        self.requestPurge(key: Keys.editHistoryPurgeBefore.rawValue)
    }

    private func requestPurge(key: String) {
        self.deletedMessagesRetentionLock.lock()
        defer { self.deletedMessagesRetentionLock.unlock() }
        let defaults = SGSimpleSettings.sharedGroupDefaults
        let now = Int(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        let current = defaults.integer(forKey: key)
        defaults.set(max(current, now), forKey: key)
    }

    // Legacy (pre-Batch 6) registry: "accountPeerId:peerId:namespace:messageId:deletedAt" strings plus a
    // per-account last-sweep dictionary in Keys.deletedMessagesLastSweep. Only read as a "this device ran an
    // old build" marker (and for the chats to scan) by the one-time migration, then deleted. Main app only.
    // Old builds left it in two stores, so both are read and cleaned:
    // - the app-group suite (Batch 3, #49; SGSharedDefaultsMigration moved the base build's keys here too):
    //   Keys.deletedMessagesRegistry, one "deletedMessagesRegistry.ext.<bundle suffix>" key per extension (the
    //   entries the Share / Notification Service extensions appended) and "deletedMessagesRegistry.swept" (the
    //   old sweep's tombstones). Every key starting with Keys.deletedMessagesRegistry holds such strings.
    // - UserDefaults.standard (the base build), only when SGSharedDefaultsMigration could not move it.
    // Nothing appends to these keys any more, so the main app is their only writer.

    /// The stores that may hold legacy state: the group suite first, then standard (one store when the suite
    /// fell back to standard).
    private static var legacyRetentionStores: [UserDefaults] {
        if SGSimpleSettings.sharedGroupDefaults === UserDefaults.standard {
            return [UserDefaults.standard]
        }
        return [SGSimpleSettings.sharedGroupDefaults, UserDefaults.standard]
    }

    /// Every legacy registry key stored in `defaults` (main key, per-extension keys, tombstones).
    private static func legacyRegistryKeys(_ defaults: UserDefaults) -> [String] {
        let prefix = Keys.deletedMessagesRegistry.rawValue
        return defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// True when a pre-Batch 6 build left retention state for this account (migration pending).
    public func hasLegacyRetentionState(accountId: Int64) -> Bool {
        self.deletedMessagesRetentionLock.lock()
        defer { self.deletedMessagesRetentionLock.unlock() }
        return self.legacyRetentionStoreUnlocked(accountId: accountId) != nil
    }

    /// Legacy migration input: whether "Show Deleted Messages" was OFF, i.e. the legacy kept copies of
    /// this account must be deleted instead of restamped. nil when the legacy marker is absent (nothing
    /// to decide; the caller treats it as "restamp"). Only a marker read that succeeded in the same locked
    /// section vouches that its store is readable (not a pre-first-unlock read), so the flag is read fresh
    /// from that same store (SGSharedDefaultsMigration moves the flag and the registry together), never
    /// from the @UserDefault cache of showDeletedMessages.
    public func legacyRetentionKeptDisabled(accountId: Int64) -> Bool? {
        self.deletedMessagesRetentionLock.lock()
        defer { self.deletedMessagesRetentionLock.unlock() }
        guard let defaults = self.legacyRetentionStoreUnlocked(accountId: accountId) else {
            return nil
        }
        return !defaults.bool(forKey: Keys.showDeletedMessages.rawValue)
    }

    /// Caller holds deletedMessagesRetentionLock. The store holding legacy state of this account, if any.
    private func legacyRetentionStoreUnlocked(accountId: Int64) -> UserDefaults? {
        let accountKey = "\(accountId)"
        let prefix = accountKey + ":"
        for defaults in SGSimpleSettings.legacyRetentionStores {
            if let timestamps = defaults.dictionary(forKey: Keys.deletedMessagesLastSweep.rawValue), timestamps[accountKey] != nil {
                return defaults
            }
            for key in SGSimpleSettings.legacyRegistryKeys(defaults) {
                if let registry = defaults.stringArray(forKey: key), registry.contains(where: { $0.hasPrefix(prefix) }) {
                    return defaults
                }
            }
        }
        return nil
    }

    /// Chat peer ids (Int64 PeerId values) the legacy registry recorded kept messages in, for this account.
    public func legacyRetentionPeerIds(accountId: Int64) -> Set<Int64> {
        self.deletedMessagesRetentionLock.lock()
        defer { self.deletedMessagesRetentionLock.unlock() }
        var result = Set<Int64>()
        let prefix = "\(accountId):"
        for defaults in SGSimpleSettings.legacyRetentionStores {
            for key in SGSimpleSettings.legacyRegistryKeys(defaults) {
                for entry in defaults.stringArray(forKey: key) ?? [] where entry.hasPrefix(prefix) {
                    let parts = entry.split(separator: ":")
                    if parts.count >= 2, let peerIdValue = Int64(parts[1]) {
                        result.insert(peerIdValue)
                    }
                }
            }
        }
        return result
    }

    /// Drops the legacy retention state of one account (after migration, or on logout).
    public func removeLegacyRetentionState(accountId: Int64) {
        let accountKey = "\(accountId)"
        self.filterLegacyRetentionState(keepAccount: { $0 != accountKey })
    }

    /// Drops the legacy retention state of every account not in `exceptAccountIds` (launch reconciliation).
    public func removeLegacyRetentionState(exceptAccountIds: Set<Int64>) {
        let keptKeys = Set(exceptAccountIds.map { "\($0)" })
        self.filterLegacyRetentionState(keepAccount: { keptKeys.contains($0) })
    }

    private func filterLegacyRetentionState(keepAccount: (String) -> Bool) {
        // Main app only: the group-suite keys are shared with the extensions, which have nothing to migrate.
        if SGProtectedStore.isAppExtension {
            return
        }
        self.deletedMessagesRetentionLock.lock()
        defer { self.deletedMessagesRetentionLock.unlock() }

        for defaults in SGSimpleSettings.legacyRetentionStores {
            for key in SGSimpleSettings.legacyRegistryKeys(defaults) {
                guard let registry = defaults.stringArray(forKey: key) else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                let filtered = registry.filter { entry in
                    guard let separator = entry.firstIndex(of: ":") else {
                        return false
                    }
                    return keepAccount(String(entry[entry.startIndex ..< separator]))
                }
                if filtered.isEmpty {
                    defaults.removeObject(forKey: key)
                } else if filtered.count != registry.count {
                    defaults.set(filtered, forKey: key)
                }
            }

            if let timestamps = defaults.dictionary(forKey: Keys.deletedMessagesLastSweep.rawValue) {
                let filtered = timestamps.filter { keepAccount($0.key) }
                if filtered.isEmpty {
                    defaults.removeObject(forKey: Keys.deletedMessagesLastSweep.rawValue)
                } else if filtered.count != timestamps.count {
                    defaults.set(filtered, forKey: Keys.deletedMessagesLastSweep.rawValue)
                }
            } else if defaults.object(forKey: Keys.deletedMessagesLastSweep.rawValue) != nil {
                defaults.removeObject(forKey: Keys.deletedMessagesLastSweep.rawValue)
            }
        }
    }
}

extension SGSimpleSettings {
    public var isStealthModeEnabled: Bool {
        return storyStealthMode && canUseStealthMode
    }
    
    public static func makeOutgoingLanguageTranslationKey(accountId: Int64, peerId: Int64) -> String {
        return "\(accountId):\(peerId)"
    }
}

extension SGSimpleSettings {
    public var translationBackendEnum: SGSimpleSettings.TranslationBackend {
        return TranslationBackend(rawValue: translationBackend) ?? .default
    }
    
    public var transcriptionBackendEnum: SGSimpleSettings.TranscriptionBackend {
        return TranscriptionBackend(rawValue: transcriptionBackend) ?? .default
    }
}

extension SGSimpleSettings {
    public var isNYEnabled: Bool {
        return canUseNY && NYStyle(rawValue: nyStyle) != .default
    }
}

public func getSGDownloadPartSize(_ default: Int64, fileSize: Int64?) -> Int64 {
    let currentDownloadSetting = SGSimpleSettings.shared.downloadSpeedBoost
    // Increasing chunk size for small files make it worse in terms of overall download performance
    let smallFileSizeThreshold = 1 * 1024 * 1024 // 1 MB
    switch (currentDownloadSetting) {
        case SGSimpleSettings.DownloadSpeedBoostValues.medium.rawValue:
            if let fileSize, fileSize <= smallFileSizeThreshold {
                return `default`
            }
            return 512 * 1024
        case SGSimpleSettings.DownloadSpeedBoostValues.maximum.rawValue:
            if let fileSize, fileSize <= smallFileSizeThreshold {
                return `default`
            }
            return 1024 * 1024
        default:
            return `default`
    }
}

public func getSGMaxPendingParts(_ default: Int) -> Int {
    let currentDownloadSetting = SGSimpleSettings.shared.downloadSpeedBoost
    switch (currentDownloadSetting) {
        case SGSimpleSettings.DownloadSpeedBoostValues.medium.rawValue:
            return 8
        case SGSimpleSettings.DownloadSpeedBoostValues.maximum.rawValue:
            return 12
        default:
            return `default`
    }
}

public func sgUseShortAllChatsTitle(_ default: Bool) -> Bool {
    let currentOverride = SGSimpleSettings.shared.allChatsTitleLengthOverride
    switch (currentOverride) {
        case SGSimpleSettings.AllChatsTitleLengthOverride.short.rawValue:
            return true
        case SGSimpleSettings.AllChatsTitleLengthOverride.long.rawValue:
            return false
        default:
            return `default`
    }
}
