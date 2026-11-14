load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_build_test")
load("@build_configuration//:variables.bzl", "telegram_minimum_os_version")

# Zenlygram — Chat Lock Center (wf14-chatlock spec §6 C2): the ONE place every Chat Lock user action is
# turned into screens and writes — lock a chat, change / remove a chat's pincode, its Face ID switch, arm /
# change the master pincode, its Face ID switch, turn Chat Lock off (with and without a master), the chat
# picker, the profile menu icon and the completion toasts. The Settings hub and per-chat screen
# (SGSettingsUI), the chat profile (PeerInfoScreen) and the chat-list long-press (ChatListUI, since Stage B)
# all call into here, so the throttle scope / purpose / recovery / entitlement-gate invariants of every PIN
# screen live at a single site (`SGChatLockFlows.makePincodeController`).
#
# Why a module of its own: SGChatLock cannot host it (no AccountContext / entitlement deps — it is linked
# into the Notification Service Extension), and ChatListUI cannot depend on SGSettingsUI (that is a cycle
# through PeerNameColorScreen → WallpaperGridScreen → ThemeAccentColorScreen → ChatListUI). Guard, both must
# stay empty:
#   bazel query "allpaths(//Swiftgram/SGChatLockFlows:SGChatLockFlows, //submodules/ChatListUI:ChatListUI)"
#   bazel query "allpaths(//Swiftgram/SGChatLockFlows:SGChatLockFlows, //Swiftgram/SGSettingsUI:SGSettingsUI)"
#
# No Postbox: peer ids are `EnginePeer.Id` (the `PeerId` typealias), so every ChatPincodeManager /
# ChatLockThrottle / ChatLockSession call compiles unchanged, and the pure decision layer
# (Sources/SGChatLockFlowSpec.swift + Sources/SGChatLockCenterCopy.swift) is Foundation-only so the host
# tests (Tests/run-host-tests.sh) compile it with plain `swiftc`.
swift_library(
    name = "SGChatLockFlows",
    module_name = "SGChatLockFlows",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGChatLock:SGChatLock",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGEntitlementUI:SGEntitlementUI",
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
        # The existing `Settings.ChatLock.Disable.*` confirmation texts (F9 / F10) are reused through `i18n`
        # rather than copied: `SGSimpleSettings.shared.languageCode` is fed from
        # `presentationData.strings.baseLanguageCode`, so both sources speak the same language.
        "//Swiftgram/SGStrings:SGStrings",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        # textAlertController (explainer, turn-off confirmation, device-auth-unavailable).
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        # displayTitle(strings:displayOrder:) for the picked chat.
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        # Completion toasts.
        "//submodules/UndoUI:UndoUI",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Compile-only check in the app's iOS configuration (pattern: Swiftgram/SGFeedBuildTests). A plain
# `bazel build //Swiftgram/SGChatLockFlows:SGChatLockFlows` builds for the host (macOS) and fails on UIKit;
# ios_build_test applies the same iOS transition as the app, so the module can be checked on its own
# (SGSettingsUI's Chat Lock screens and PeerInfoScreen's profile item depend on it since Stage A part 2,
# ChatListUI's chat-list long-press since Stage B).
ios_build_test(
    name = "SGChatLockFlowsBuildTest",
    minimum_os_version = telegram_minimum_os_version,
    targets = [":SGChatLockFlows"],
    tags = ["manual"],
)
