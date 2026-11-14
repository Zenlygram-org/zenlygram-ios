import Foundation
import XCTest
import SGSettingsCatalog

/// Zenlygram — the Settings → Zenlygram hub tree as data (settings IA, 2026-11): every row of the old
/// flat list is placed exactly once (the shared recovery row twice, declared), the inventory is the
/// frozen set below, deep-link keys resolve, the per-page search id bases hold, the NEW-badge oracle
/// only names rows of its page, and the three string tables carry every key the hub reads.
///
/// The tables come from this test bundle (`<lang>.lproj/SGLocalizable.strings` at its root, the Bazel
/// target's `data`) or, on a host run, from `SG_SETTINGS_STRINGS_ROOT` (the `Strings` directory of
/// SGStrings).
final class SGSettingsCatalogTests: XCTestCase {
    private static let locales = ["en", "ru", "uz"]

    // MARK: - The frozen inventory (spec §1.4): 75 + 4 + 3 + 13 + 12 = 107 keys

    /// Every `SGBoolSetting` case of the flag-off build, in declaration order (`showLentaTab` is flag-on).
    private static let boolSettings: [String] = [
        "hidePhoneInSettings", "showTabNames", "showContactsTab", "showCallsTab", "showTasksTab", "wideTabBar",
        "foldersAtBottom", "startTelescopeWithRearCam", "hideStories", "uploadSpeedBoost", "showProfileId",
        "warnOnStoriesOpen", "sendWithReturnKey", "rememberLastFolder", "sendLargePhotos", "disableSwipeToRecordStory",
        "disableDeleteChatSwipeOption", "quickTranslateButton", "hideReactions", "showRepostToStory",
        "contextShowSelectFromUser", "contextShowSaveToCloud", "contextShowHideForwardName", "contextShowRestrict",
        "contextShowReport", "contextShowReply", "contextShowPin", "contextShowSaveMedia", "contextShowMessageReplies",
        "contextShowJson", "editHistoryEnabled", "disableScrollToNextChannel", "disableScrollToNextTopic",
        "disableChatSwipeOptions", "disableGalleryCamera", "disableGalleryCameraPreview", "disableSendAsButton",
        "disableSnapDeletionEffect", "stickerTimestamp", "hideRecordingButton", "hideTabBar", "showDC",
        "showCreationDate", "showRegDate", "compactChatList", "unlimitedPinnedChats", "unreadReminderEnabled",
        "blockForeignUsers", "sendRoundVideoFromGallery", "aiAssistantEnabled", "compactMessagePreview",
        "compactFolderNames", "allChatsHidden", "defaultEmojisFirst", "messageDoubleTapActionOutgoingEdit",
        "wideChannelPosts", "forceEmojiTab", "forceBuiltInMic", "secondsInMessages", "hideChannelBottomButton",
        "confirmCalls", "swipeForVideoPIP", "enableVoipTcp", "autoProxyEnabled", "autoDownloadDisabled",
        "autoAcceptRequests", "showViewFirstMessage", "showDeletedMessages", "nyStyleSnow", "nyStyleLightning",
        "tabBarSearchEnabled", "secretVaultEnabled", "secretVaultUseSecretCode", "callRecordingNotifyOtherParty",
        "callRecordingSendToSavedMessages",
    ]

    /// The `SGOneFromManySetting` cases that render a row (`nyStyle` and `bottomTabStyle` have no row).
    private static let oneFromManySettings: [String] = [
        "downloadSpeedBoost", "allChatsTitleLengthOverride", "translationBackend", "transcriptionBackend",
    ]

    private static let sliderSettings: [String] = [
        "accountColorsSaturation", "outgoingPhotoQuality", "stickerSize",
    ]

    /// Every `SGDisclosureLink` case of the flag-off build that renders a row (`helperBots` stays
    /// commented out; `lenta` is flag-on).
    private static let disclosureLinks: [String] = [
        "contentSettings", "languageSettings", "tasks", "chatLock", "secretVaultChangePin", "protectionRecovery",
        "aiAssistantApiKey", "callRecordings", "proSubscription", "proRestorePurchases", "proLinkAccount",
        "dataConsent", "privacyPolicy",
    ]

    /// The hub rows that open a page, in hub order.
    private static let pageKeys: [String] = [
        "pageSecretVault", "pageHistory", "pageCallRecording", "pageChats", "pageMessages", "pageMessageMenu",
        "pageTabBar", "pagePrivacy", "pageTranslation", "pageMedia", "pageColors", "pageCallsAdvanced",
    ]

    private static var frozenInventory: [String] {
        return self.boolSettings + self.oneFromManySettings + self.sliderSettings + self.disclosureLinks + self.pageKeys
    }

    /// The `SGSettingsFocus` statics (§2.3).
    private static let focusStatics: [SGSettingsFocus] = [
        .proSubscription, .proRestorePurchases, .proLinkAccount, .dataConsent, .privacyPolicy,
        .secretVault, .secretVaultEnabled, .chatLock, .tasks, .history, .showDeletedMessages, .editHistoryEnabled,
        .callRecording, .callRecordings, .showTasksTab, .unreadReminderEnabled,
    ]

    // MARK: - Tests

    func testEveryRowIsPlacedExactlyOnce() {
        var placements: [String: Int] = [:]
        for key in SGSettingsCatalog.hubRowKeys {
            placements[key, default: 0] += 1
        }
        for page in SGSettingsPage.allCases {
            let keys = SGSettingsCatalog.rowKeys(on: page)
            XCTAssertEqual(Set(keys).count, keys.count, "\(page) lists a row twice")
            for key in keys {
                placements[key, default: 0] += 1
            }
        }
        for (key, count) in placements.sorted(by: { $0.key < $1.key }) {
            if SGSettingsCatalog.sharedRowKeys.contains(key) {
                XCTAssertGreaterThan(count, 1, "\(key) is declared shared but renders on one screen")
            } else {
                XCTAssertEqual(count, 1, "\(key) is placed \(count) times")
            }
        }
        XCTAssertEqual(SGSettingsCatalog.sharedRowKeys, ["protectionRecovery"])
        XCTAssertEqual(placements["protectionRecovery"], 2, "the hub (Chat Lock recovery) and the Secret Vault page (vault recovery)")
        XCTAssertEqual(Set(SGSettingsCatalog.hubRowKeys).count, SGSettingsCatalog.hubRowKeys.count)
    }

    func testInventoryIsComplete() {
        let frozen = Self.frozenInventory
        XCTAssertEqual(Self.boolSettings.count, 75)
        XCTAssertEqual(Self.oneFromManySettings.count, 4)
        XCTAssertEqual(Self.sliderSettings.count, 3)
        XCTAssertEqual(Self.disclosureLinks.count, 13)
        XCTAssertEqual(Self.pageKeys.count, 12)
        XCTAssertEqual(frozen.count, 107)
        XCTAssertEqual(Set(frozen).count, frozen.count, "the frozen list repeats a key")

        let all = SGSettingsCatalog.allRowKeys
        XCTAssertEqual(Set(all).count, all.count, "allRowKeys lists a key twice")
        XCTAssertEqual(Set(all).subtracting(frozen).sorted(), [], "the catalog places rows the inventory does not know")
        XCTAssertEqual(Set(frozen).subtracting(all).sorted(), [], "the catalog forgets rows of the inventory")
        XCTAssertEqual(all.count, 107)

        for absent in ["helperBots", "lenta", "showLentaTab"] {
            XCTAssertFalse(all.contains(absent), "\(absent) must not be in the catalog")
            XCTAssertNil(SGSettingsCatalog.page(containing: absent))
        }
        XCTAssertEqual(SGSettingsPage.allCases.map { $0.hubRowKey }, Self.pageKeys)
        XCTAssertEqual(Array(all.prefix(SGSettingsCatalog.hubRowKeys.count)), SGSettingsCatalog.hubRowKeys, "hub rows come first, in hub order")
    }

    func testPageContainingIsConsistent() {
        for page in SGSettingsPage.allCases {
            for key in SGSettingsCatalog.rowKeys(on: page) where !SGSettingsCatalog.sharedRowKeys.contains(key) {
                XCTAssertEqual(SGSettingsCatalog.page(containing: key), page, key)
            }
        }
        for key in SGSettingsCatalog.hubRowKeys {
            XCTAssertNil(SGSettingsCatalog.page(containing: key), "\(key) is a hub row")
        }
        XCTAssertNil(SGSettingsCatalog.page(containing: "protectionRecovery"), "the shared recovery row resolves to its hub copy")
        XCTAssertNil(SGSettingsCatalog.page(containing: "noSuchRow"))
        XCTAssertNil(SGSettingsCatalog.page(containing: ""))

        let known = Set(SGSettingsCatalog.allRowKeys)
        for focus in Self.focusStatics {
            XCTAssertTrue(known.contains(focus.rawValue), "\(focus.rawValue) is not a catalog row")
            if let page = SGSettingsCatalog.page(containing: focus.rawValue) {
                XCTAssertTrue(SGSettingsCatalog.rowKeys(on: page).contains(focus.rawValue))
            } else {
                XCTAssertTrue(SGSettingsCatalog.hubRowKeys.contains(focus.rawValue), "\(focus.rawValue) resolves to neither a page nor the hub")
            }
        }
        XCTAssertEqual(SGSettingsFocus.secretVault.rawValue, SGSettingsPage.secretVault.hubRowKey)
        XCTAssertEqual(SGSettingsFocus.history.rawValue, SGSettingsPage.history.hubRowKey)
        XCTAssertEqual(SGSettingsFocus.callRecording.rawValue, SGSettingsPage.callRecording.hubRowKey)
        XCTAssertEqual(SGSettingsCatalog.page(containing: SGSettingsFocus.showDeletedMessages.rawValue), .history)
        XCTAssertEqual(SGSettingsCatalog.page(containing: SGSettingsFocus.showTasksTab.rawValue), .tabBar)
        XCTAssertEqual(SGSettingsCatalog.page(containing: SGSettingsFocus.unreadReminderEnabled.rawValue), .chats)
        XCTAssertEqual(SGSettingsFocus(rawValue: "chatLock"), .chatLock, "any row key works by raw string")
    }

    func testIdBases() {
        XCTAssertLessThan(SGSettingsCatalog.hubRowKeys.count, 1000)
        var previousBase = 0
        for (index, page) in SGSettingsPage.allCases.enumerated() {
            XCTAssertLessThan(SGSettingsCatalog.rowKeys(on: page).count, 1000, "\(page)")
            XCTAssertEqual(page.index, index)
            XCTAssertEqual(page.searchIdBase, (index + 1) * 1000)
            XCTAssertGreaterThan(page.searchIdBase, previousBase, "\(page): bases must strictly increase in hub order")
            XCTAssertGreaterThanOrEqual(page.searchIdBase - previousBase, 1000)
            previousBase = page.searchIdBase
        }
        XCTAssertEqual(SGSettingsPage.allCases.first?.searchIdBase, 1000)
        XCTAssertEqual(SGSettingsPage.allCases.last?.searchIdBase, 12000)

        let expectedHubRowKeys: [SGSettingsPage: String] = [
            .secretVault: "pageSecretVault",
            .history: "pageHistory",
            .callRecording: "pageCallRecording",
            .chats: "pageChats",
            .messages: "pageMessages",
            .messageMenu: "pageMessageMenu",
            .tabBar: "pageTabBar",
            .privacy: "pagePrivacy",
            .translation: "pageTranslation",
            .media: "pageMedia",
            .colors: "pageColors",
            .callsAdvanced: "pageCallsAdvanced",
        ]
        for page in SGSettingsPage.allCases {
            XCTAssertEqual(page.hubRowKey, expectedHubRowKeys[page], "\(page)")
            XCTAssertEqual(page.hubRowKey, "page" + page.rawValue.prefix(1).uppercased() + page.rawValue.dropFirst())
            XCTAssertTrue(SGSettingsCatalog.hubRowKeys.contains(page.hubRowKey))
        }
        XCTAssertEqual(SGSettingsPage.allCases.filter { !$0.isGroup }, [.secretVault, .history, .callRecording])
        XCTAssertEqual(SGSettingsPage.allCases.filter { $0.isGroup }.count, 9)
    }

    func testNewBadgeOracle() {
        for page in SGSettingsPage.allCases {
            let oracle = try? XCTUnwrap(SGSettingsCatalog.newBadgeKeys[page], "\(page) has no oracle entry")
            let rows = Set(SGSettingsCatalog.rowKeys(on: page))
            for key in oracle ?? [] {
                XCTAssertTrue(rows.contains(key), "\(page): \(key) is not a row of the page")
            }
        }
        XCTAssertEqual(SGSettingsCatalog.newBadgeKeys.count, SGSettingsPage.allCases.count)
        XCTAssertEqual(SGSettingsCatalog.newBadgeKeys.values.flatMap { $0 }.count, 14)
    }

    func testStringsEnRuUz() throws {
        let tables = try Self.locales.map { try self.table($0) }
        let keys = SGSettingsPage.allCases.map { $0.titleKey } + SGSettingsCatalog.newStringKeys + SGSettingsCatalog.editedStringKeys
        XCTAssertEqual(SGSettingsCatalog.newStringKeys.count, 16)
        XCTAssertEqual(Set(SGSettingsCatalog.newStringKeys).count, 16)
        for (index, locale) in Self.locales.enumerated() {
            for key in keys {
                let value = try XCTUnwrap(tables[index][key], "\(locale): \(key) is missing")
                XCTAssertFalse(value.isEmpty, "\(locale): \(key) is empty")
            }
            for key in SGSettingsCatalog.newStringKeys {
                let value = (tables[index][key] ?? "").lowercased()
                XCTAssertFalse(value.contains("lenta"), "\(locale): \(key) names Lenta (the flag-off binary must not)")
                XCTAssertFalse(value.contains("sgfeed"), "\(locale): \(key) names SGFeed")
            }
        }

        // uz: the Settings.* family is written with ASCII apostrophes; the ACCOUNT & DATA header alone
        // keeps ʼ (U+02BC) because the row beneath it reads "Maʼlumotlar va rozilik".
        let uz = tables[2]
        let apostropheAllowList: Set<String> = ["Settings.AccountData.Header"]
        for key in SGSettingsCatalog.newStringKeys where key.hasPrefix("Settings.") {
            let value = uz[key] ?? ""
            if apostropheAllowList.contains(key) {
                XCTAssertTrue(value.contains("\u{02BC}"), "uz: \(key) is allow-listed for ʼ but does not use it")
            } else {
                XCTAssertFalse(value.contains("\u{02BB}") || value.contains("\u{02BC}"), "uz: \(key) uses a non-ASCII apostrophe: \(value)")
            }
        }
        XCTAssertTrue((uz["Settings.Pro.Notice"] ?? "").contains("Maxfiy seyf"), "uz: the Pro notice names the vault as the row does")
        XCTAssertFalse((uz["Settings.Pro.Notice"] ?? "").contains("xazina"), "uz: one name for the vault")
        XCTAssertTrue((tables[0]["Settings.Translation.EntireChat.PremiumRequired"] ?? "").contains("Translation & Voice"), "en: the path names the hub page")
    }

    // MARK: - Helpers

    /// The app's `SGLocalizable.strings` for `lang`.
    private func table(_ lang: String) throws -> [String: String] {
        var url: URL?
        if let root = ProcessInfo.processInfo.environment["SG_SETTINGS_STRINGS_ROOT"], !root.isEmpty {
            url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("\(lang).lproj/SGLocalizable.strings")
        } else if let path = Bundle(for: SGSettingsCatalogTests.self).path(forResource: "SGLocalizable", ofType: "strings", inDirectory: nil, forLocalization: lang) {
            url = URL(fileURLWithPath: path)
        }
        let found = try XCTUnwrap(url, "SGLocalizable.strings for \(lang) not found")
        return try XCTUnwrap(NSDictionary(contentsOf: found) as? [String: String], "\(lang): SGLocalizable.strings does not parse")
    }
}
