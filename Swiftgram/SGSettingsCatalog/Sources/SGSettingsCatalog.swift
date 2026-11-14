import Foundation

// Zenlygram — Settings → Zenlygram is a hub and twelve pages (settings IA, 2026-11). This module is
// the data-only inventory of that tree: the pages in hub order, the hub's own rows, the page every row
// lives on, the keys a deep link may name, and the strings the hub introduced. It is Foundation-only —
// no UIKit, no SG_LENTA (the two Lenta rows are compiled into SGSettingsUI behind the flag and are never
// listed here) — so it is tested hostless, and SGSettingsUI's DEBUG guard ties it to the real entries
// builder: every row the builder emits is in the catalog, every catalog row a build omits is gated.
//
// A row key is the row's setting / link case name in SGSettingsController (= its SGSimpleSettings key
// = its NEW-badge key = `SGItemListUIEntry.tagKey`). No key is ever renamed: persisted badges and deep
// links depend on them.

/// One page of the hub, in hub order (= the order of the search index).
public enum SGSettingsPage: String, CaseIterable, Hashable {
    // The feature pages, pushed from MAIN FEATURES rows.
    case secretVault
    case history
    case callRecording
    // The group pages, pushed from MORE SETTINGS rows.
    case chats
    case messages
    case messageMenu
    case tabBar
    case privacy
    case translation
    case media
    case colors
    case callsAdvanced

    /// Group pages sit under MORE SETTINGS; in the hub's search results their section headers are
    /// prefixed with the page title ("TAB BAR — TABS"). Feature pages keep their headers verbatim.
    public var isGroup: Bool {
        switch self {
        case .secretVault, .history, .callRecording:
            return false
        case .chats, .messages, .messageMenu, .tabBar, .privacy, .translation, .media, .colors, .callsAdvanced:
            return true
        }
    }

    /// The SGLocalizable key of the page title: the hub row's title and the page's navigation-bar title.
    public var titleKey: String {
        switch self {
        case .secretVault:
            return "Settings.SecretVault.Title"
        case .history:
            return "Settings.Hub.History"
        case .callRecording:
            return "Settings.Hub.CallRecording"
        case .chats:
            return "Settings.Hub.Chats"
        case .messages:
            return "Settings.Hub.Messages"
        case .messageMenu:
            return "Settings.Hub.MessageMenu"
        case .tabBar:
            return "Settings.Hub.TabBar"
        case .privacy:
            return "Settings.Hub.Privacy"
        case .translation:
            return "Settings.Hub.Translation"
        case .media:
            return "Settings.Hub.Media"
        case .colors:
            return "Settings.Hub.Colors"
        case .callsAdvanced:
            return "Settings.Hub.CallsAdvanced"
        }
    }

    /// The key of the hub row that opens this page: "page" + the case name with its first letter
    /// uppercased ("pageSecretVault"), which is the row's `SGDisclosureLink` case name in SGSettingsUI.
    public var hubRowKey: String {
        return "page" + self.rawValue.prefix(1).uppercased() + self.rawValue.dropFirst()
    }

    /// The page's position in `allCases` (hub order).
    public var index: Int {
        return SGSettingsPage.allCases.firstIndex(of: self)!
    }

    /// The row-id base the page's entries are built on when they are appended to the hub's for search
    /// (`SGItemListCounter(base:)`): 1000 for the first page, 2000 for the second, … Every page has
    /// fewer than 1000 rows (tested), so the ids stay strictly increasing across the whole list and a
    /// page whose row count varies never shifts another page's stable ids.
    public var searchIdBase: Int {
        return (self.index + 1) * 1000
    }
}

/// What `sgSettingsController(context:focus:)` scrolls to and flashes: a row key. The statics name the
/// rows other screens link to; any other row key works through `init(rawValue:)` (the `?row=` query of
/// `tg://sg/settings`). A key the catalog places on a page opens that page first; a key that is hidden
/// in the current state, or unknown, lands on the plain hub.
public struct SGSettingsFocus: RawRepresentable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let proSubscription = SGSettingsFocus(rawValue: "proSubscription")
    public static let proRestorePurchases = SGSettingsFocus(rawValue: "proRestorePurchases")
    public static let proLinkAccount = SGSettingsFocus(rawValue: "proLinkAccount")
    public static let dataConsent = SGSettingsFocus(rawValue: "dataConsent")
    public static let privacyPolicy = SGSettingsFocus(rawValue: "privacyPolicy")
    public static let secretVault = SGSettingsFocus(rawValue: "pageSecretVault")
    public static let secretVaultEnabled = SGSettingsFocus(rawValue: "secretVaultEnabled")
    public static let chatLock = SGSettingsFocus(rawValue: "chatLock")
    public static let tasks = SGSettingsFocus(rawValue: "tasks")
    public static let history = SGSettingsFocus(rawValue: "pageHistory")
    public static let showDeletedMessages = SGSettingsFocus(rawValue: "showDeletedMessages")
    public static let editHistoryEnabled = SGSettingsFocus(rawValue: "editHistoryEnabled")
    public static let callRecording = SGSettingsFocus(rawValue: "pageCallRecording")
    public static let callRecordings = SGSettingsFocus(rawValue: "callRecordings")
    public static let showTasksTab = SGSettingsFocus(rawValue: "showTasksTab")
    public static let unreadReminderEnabled = SGSettingsFocus(rawValue: "unreadReminderEnabled")
}

/// The hub tree as key tables. Read by the deep-link routing (`page(containing:)`), the DEBUG guard in
/// SGSettingsUI and the catalog tests; never by the entries builder, which stays the source of truth
/// for what a state renders.
public enum SGSettingsCatalog {
    /// The hub's own rows in hub order: the MAIN FEATURES rows (with the Chat Lock recovery row), the
    /// ACCOUNT & DATA rows, the ZENLYGRAM PRO rows, then the nine MORE SETTINGS rows. `protectionRecovery`
    /// also renders on the Secret Vault page (see `sharedRowKeys`); its hub copy is the one a deep link
    /// lands on.
    public static let hubRowKeys: [String] = [
        "pageSecretVault",
        "chatLock",
        "protectionRecovery",
        "tasks",
        "pageHistory",
        "pageCallRecording",
        "proLinkAccount",
        "dataConsent",
        "privacyPolicy",
        "proSubscription",
        "proRestorePurchases",
        "pageChats",
        "pageMessages",
        "pageMessageMenu",
        "pageTabBar",
        "pagePrivacy",
        "pageTranslation",
        "pageMedia",
        "pageColors",
        "pageCallsAdvanced",
    ]

    /// The rows of a page in page order, section by section.
    public static func rowKeys(on page: SGSettingsPage) -> [String] {
        switch page {
        case .secretVault:
            return [
                "secretVaultEnabled",
                "secretVaultUseSecretCode",
                "secretVaultChangePin",
                "protectionRecovery",
            ]
        case .history:
            return [
                "showDeletedMessages",
                "editHistoryEnabled",
            ]
        case .callRecording:
            return [
                "callRecordings",
                "callRecordingNotifyOtherParty",
                "callRecordingSendToSavedMessages",
            ]
        case .chats:
            return [
                // Chat list
                "compactChatList",
                "compactMessagePreview",
                "unlimitedPinnedChats",
                "disableChatSwipeOptions",
                "disableDeleteChatSwipeOption",
                // Chat folders
                "foldersAtBottom",
                "rememberLastFolder",
                "allChatsHidden",
                "compactFolderNames",
                "allChatsTitleLengthOverride",
                // Stories
                "hideStories",
                "disableSwipeToRecordStory",
                "showRepostToStory",
                // Reminders
                "unreadReminderEnabled",
            ]
        case .messages:
            return [
                // Messages & bubbles
                "hideReactions",
                "secondsInMessages",
                "wideChannelPosts",
                "hideChannelBottomButton",
                "disableSnapDeletionEffect",
                "disableScrollToNextChannel",
                "disableScrollToNextTopic",
                // Composing & input
                "sendWithReturnKey",
                "messageDoubleTapActionOutgoingEdit",
                "disableSendAsButton",
                "hideRecordingButton",
                "forceEmojiTab",
                "defaultEmojisFirst",
            ]
        case .messageMenu:
            return [
                "contextShowSaveToCloud",
                "contextShowSaveMedia",
                "contextShowReply",
                "contextShowPin",
                "contextShowSelectFromUser",
                "contextShowMessageReplies",
                "contextShowHideForwardName",
                "contextShowReport",
                "contextShowRestrict",
                "contextShowJson",
            ]
        case .tabBar:
            return [
                "hideTabBar",
                "showTabNames",
                "tabBarSearchEnabled",
                "showContactsTab",
                "showCallsTab",
                "showTasksTab",
                "wideTabBar",
            ]
        case .privacy:
            return [
                // Who can reach you
                "blockForeignUsers",
                "autoAcceptRequests",
                "confirmCalls",
                // Stay invisible
                "hidePhoneInSettings",
                "warnOnStoriesOpen",
                // Profiles
                "showRegDate",
                "showCreationDate",
                "showDC",
                "showProfileId",
                "showViewFirstMessage",
            ]
        case .translation:
            return [
                "translationBackend",
                "quickTranslateButton",
                "languageSettings",
                "transcriptionBackend",
                "forceBuiltInMic",
            ]
        case .media:
            return [
                // Downloads & speed
                "autoDownloadDisabled",
                "downloadSpeedBoost",
                "uploadSpeedBoost",
                // Photos & stickers
                "outgoingPhotoQuality",
                "sendLargePhotos",
                "stickerSize",
                "stickerTimestamp",
                // Video & round video
                "swipeForVideoPIP",
                "startTelescopeWithRearCam",
                "sendRoundVideoFromGallery",
                // Camera & gallery picker
                "disableGalleryCamera",
                "disableGalleryCameraPreview",
            ]
        case .colors:
            return [
                "accountColorsSaturation",
                "nyStyleSnow",
                "nyStyleLightning",
            ]
        case .callsAdvanced:
            return [
                // Calls
                "enableVoipTcp",
                // Advanced
                "contentSettings",
                "autoProxyEnabled",
                // AI assistant (refused by this build; never shown)
                "aiAssistantEnabled",
                "aiAssistantApiKey",
            ]
        }
    }

    /// Rows that render on more than one screen: the "Restore protection" row is on the hub for Chat
    /// Lock recovery and on the Secret Vault page for vault recovery (and as its paused row).
    public static let sharedRowKeys: Set<String> = ["protectionRecovery"]

    /// Every row key once: the hub rows, then the pages in hub order (a shared key keeps its first place).
    public static var allRowKeys: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in self.hubRowKeys + SGSettingsPage.allCases.flatMap({ self.rowKeys(on: $0) }) where seen.insert(key).inserted {
            result.append(key)
        }
        return result
    }

    /// The page a row lives on: nil for the hub's own rows (the shared `protectionRecovery` included)
    /// and for keys the catalog does not know.
    public static func page(containing key: String) -> SGSettingsPage? {
        if self.hubRowKeys.contains(key) {
            return nil
        }
        return SGSettingsPage.allCases.first { self.rowKeys(on: $0).contains(key) }
    }

    /// Rows the builder emits only in some states — gated on an entitlement, the app configuration, a
    /// device capability or a recovery state. The DEBUG guard allows these, and only these, to be
    /// missing from a build of the whole tree.
    public static let gatedRowKeys: Set<String> = [
        "proSubscription",
        "proRestorePurchases",
        "dataConsent",
        "privacyPolicy",
        "pageCallRecording",
        "callRecordings",
        "callRecordingNotifyOtherParty",
        "callRecordingSendToSavedMessages",
        "secretVaultUseSecretCode",
        "secretVaultChangePin",
        "protectionRecovery",
        "aiAssistantEnabled",
        "aiAssistantApiKey",
        "contentSettings",
        "autoProxyEnabled",
        "nyStyleSnow",
        "nyStyleLightning",
    ]

    /// Test oracle for the NEW-badge roll-up: the rows of each page born with a NEW badge
    /// (`SGNewBadgeTracker.shouldShow` at the entry site). Never read by the builder — the hub rolls a
    /// page row's badge up from the page's built entries (`SGItemListUIEntry.isNew`), so a gated row
    /// cannot raise a pill while it is hidden.
    public static let newBadgeKeys: [SGSettingsPage: [String]] = [
        .secretVault: ["secretVaultEnabled", "secretVaultUseSecretCode", "secretVaultChangePin"],
        .history: ["showDeletedMessages", "editHistoryEnabled"],
        .callRecording: [],
        .chats: ["unlimitedPinnedChats", "unreadReminderEnabled"],
        .messages: [],
        .messageMenu: [],
        .tabBar: [],
        .privacy: ["blockForeignUsers", "autoAcceptRequests", "showViewFirstMessage"],
        .translation: [],
        .media: ["autoDownloadDisabled", "sendRoundVideoFromGallery"],
        .colors: [],
        .callsAdvanced: ["autoProxyEnabled", "aiAssistantEnabled"],
    ]

    /// The SGLocalizable keys the hub introduced, carried by en, ru and uz: the three hub block headers,
    /// the nine group titles and the two feature-page titles that had no key, and the two new section
    /// headers. (The Secret Vault row reuses `Settings.SecretVault.Title` and `Settings.ChatLock.On/Off`.)
    public static let newStringKeys: [String] = [
        "Settings.Hub.Features.Header",
        "Settings.AccountData.Header",
        "Settings.Hub.Groups.Header",
        "Settings.Hub.History",
        "Settings.Hub.CallRecording",
        "Settings.Hub.Chats",
        "Settings.Hub.Messages",
        "Settings.Hub.MessageMenu",
        "Settings.Hub.TabBar",
        "Settings.Hub.Privacy",
        "Settings.Hub.Translation",
        "Settings.Hub.Media",
        "Settings.Hub.Colors",
        "Settings.Hub.CallsAdvanced",
        "Settings.DeletedMessages.Header",
        "Settings.Reminders.Header",
    ]

    /// Existing keys whose text changed with the hub because it named a place in the old flat list.
    public static let editedStringKeys: [String] = [
        "Settings.Pro.Notice",
        "Settings.Tabs.ShowTasks.Desc",
        "Settings.Translation.EntireChat.PremiumRequired",
    ]
}
