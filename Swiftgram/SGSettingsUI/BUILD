load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

filegroup(
    name = "SGUIAssets",
    srcs = glob(["Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGSettingsUI",
    module_name = "SGSettingsUI",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    # Zenlygram — SG_LENTA compiles the hub's Lenta row and the Tab Bar page's Show Lenta Tab switch
    # (--//Telegram:enableLenta only).
    copts = [
        "-warnings-as-errors",
    ] + select({
        "//Telegram:enableLentaSetting": ["-DSG_LENTA"],
        "//conditions:default": [],
    }),
    deps = [
        "//Swiftgram/SGItemListUI:SGItemListUI",
        # Zenlygram — the Settings → Zenlygram hub-and-pages inventory (pages, hub rows, focus keys).
        "//Swiftgram/SGSettingsCatalog:SGSettingsCatalog",
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/SGTasks:SGTasks",
        "//Swiftgram/SGChatLock:SGChatLock",
        # Zenlygram — Chat Lock Center (wf14-chatlock): the hub and per-chat screens render the pure row
        # layer and run every action through the shared flows (the single Chat Lock flow site).
        "//Swiftgram/SGChatLockFlows:SGChatLockFlows",
        "//Swiftgram/SGSecretVault:SGSecretVault",
        "//Swiftgram/SGAIAssistant:SGAIAssistant",
        # Zenlygram — the recordings list and the call-recording settings rows.
        "//Swiftgram/SGCallRecording:SGCallRecording",
        # Zenlygram — the "Send to Saved Messages" action, its row label and its cancel-on-delete.
        "//Swiftgram/SGCallRecordingDelivery:SGCallRecordingDelivery",
        # Zenlygram — the export grant and manual-send result types the list hands to / reads from it.
        "//Swiftgram/SGCallRecordingDelivery:SGCallRecordingDeliveryCore",
        # Zenlygram — the recordings list checks Secret Vault / Chat Lock protection for the pair a
        # recording was made with (fail-closed verdicts), and redacts / gates it accordingly.
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
        # Zenlygram — the recordings list reads `CallKitIntegration.isAvailable` (same source the call
        # screen uses) so an empty list never points at a Record button that cannot appear here.
        "//submodules/TelegramCallsUI:TelegramCallsUI",
        # Zenlygram — the entitlement (the CREATE gates on the four Pro rows + the "ai" capability)
        # and the screens the subscription rows push (status, link account).
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGEntitlementUI:SGEntitlementUI",
        # Restore Purchases goes straight to the StoreKit 2 façade so the outcome (restored /
        # nothing-to-restore / cancelled / failed) can be told apart in the copy.
        "//Swiftgram/SGIAP:SGIAP",
        "//Swiftgram/SGPayWall:SGPayWall",
        "//Swiftgram/SGBindAttest:SGBindAttest",
        # Zenlygram — Settings → Data & privacy (design 40 §11.1): the Data & Consent row and its live
        # value, the privacy policy URL; and the analytics emitters (§10.2: zg.hub / calls.recordings /
        # chat_lock.settings screen views, feature.toggle, pro.restore; the chat_lock.lock_set /
        # lock_removed emitters live in SGChatLockFlows).
        "//Swiftgram/SGCustomerSync:SGCustomerSync",
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
        "//Swiftgram/SGAutoProxy:SGAutoProxy",
        "//Swiftgram/SGAutoAccept:SGAutoAccept",
#        "//Swiftgram/SGAPI:SGAPI",
        "//Swiftgram/SGAPIToken:SGAPIToken",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ItemListUI:ItemListUI",
        # Zenlygram — the "Review muted chats" recovery screen (audit #74) lists peers with a checkmark;
        # the Chat Lock screen lists the locked chats of this account with a swipe-to-remove.
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        # Zenlygram — the Chat Lock screen's "Add a Chat…" row.
        "//submodules/ItemListPeerActionItem:ItemListPeerActionItem",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramUI/Components/AlertComponent",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
        "//submodules/UndoUI:UndoUI",
    ] + select({
        # Zenlygram — the Lenta tab controller / availability rule and its strings.
        "//Telegram:enableLentaSetting": [
            "//Swiftgram/SGFeedUI:SGFeedUI",
            "//Swiftgram/SGFeedStrings:SGFeedStrings",
        ],
        "//conditions:default": [],
    }),
    visibility = [
        "//visibility:public",
    ],
)
