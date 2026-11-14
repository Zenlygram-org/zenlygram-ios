load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
# Zenlygram — the QA override of the app-update decision is compiled into non-store builds only (§4h).
load("//Swiftgram/SGAppUpdate:debug_override.bzl", "SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS")

config_setting(
    name = "debug_build",
    values = {
        "compilation_mode": "dbg",
    },
)

config_setting(
    name = "fastbuild_build",
    values = {
        "compilation_mode": "fastbuild",
    },
)

flex_dependency = select({
    ":debug_build": [
        "@flex_sdk//:FLEX"
    ],
    ":fastbuild_build": [
        "@flex_sdk//:FLEX"
    ],
    "//conditions:default": [],
})


swift_library(
    name = "SGDebugUI",
    module_name = "SGDebugUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ] + SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS,
    deps = [
        "//Swiftgram/SGItemListUI:SGItemListUI",
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/SGSwiftUI:SGSwiftUI",
        "//Swiftgram/SGIAP:SGIAP",
        "//Swiftgram/SGPayWall:SGPayWall",
        # Zenlygram — the app-update override row (update_policy_spec §4h): `SGAppUpdateDebugOverride`'s
        # three values, and `SGAppUpdate.decisionDidChange` so the presenter re-decides at once.
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGAppUpdate:SGAppUpdateUI",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/AccountContext:AccountContext",
        "//submodules/UndoUI:UndoUI"
    ] + flex_dependency,
    visibility = [
        "//visibility:public",
    ],
)
