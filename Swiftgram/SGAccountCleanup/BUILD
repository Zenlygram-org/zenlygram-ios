load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGAccountCleanup",
    module_name = "SGAccountCleanup",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Zenlygram — SG_LENTA only switches the launch sweep of the optional feature's storage from
    # "remove everything" (builds without it) to "remove signed-out accounts". No feature module is
    # linked here: the cleanup works on neutral Keychain / folder names.
    copts = [
        "-warnings-as-errors",
    ] + select({
        "//Telegram:enableLentaSetting": ["-DSG_LENTA"],
        "//conditions:default": [],
    }),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGUnreadReminder:SGUnreadReminder",
        "//Swiftgram/SGAutoAccept:SGAutoAccept",
        "//Swiftgram/SGTasks:SGTasks",
        "//Swiftgram/SGChatLock:SGChatLock",
        "//Swiftgram/SGSecretVault:SGSecretVault",
        "//Swiftgram/SGKeychainBackupManager:SGKeychainBackupManager",
        # Zenlygram — call recordings outlive every Postbox, so the last logout wipes them here.
        "//Swiftgram/SGCallRecording:SGCallRecording",
        # Zenlygram — and a recording being deleted here may have an upload to Saved Messages in
        # flight, which has to be cancelled before its file is unlinked.
        "//Swiftgram/SGCallRecordingDelivery:SGCallRecordingDelivery",
        # Zenlygram — a removed account's Pro entitlement session (binding, refresh token, cached
        # JWS) is logged out here.
        "//Swiftgram/SGEntitlement:SGEntitlement",
        # Zenlygram — the app-group container is one of the roots SGFeatureStorageCleanup sweeps.
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
    ],
    visibility = [
        "//visibility:public",
    ],
)
