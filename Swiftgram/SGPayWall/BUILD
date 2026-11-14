load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_ui_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

filegroup(
    name = "SGPayWallAssets",
    srcs = glob(["Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

SGPAYWALL_DEPS = [
    # Zenlygram — the paywall reads the entitlement (what the user MAY do) and drives `SGIAP`
    # (what the App Store will sell). It never imports StoreKit itself: attach-before-finish and
    # the outbox live in SGIAP, where a SwiftUI view cannot get them wrong.
    "//Swiftgram/SGConfig:SGConfig",
    # The purchase funnel and the Link screen record through `SGAnalytics` / `SGCustomerLinkEvents`
    # (design 40 §10.2, §8.2): the pure, extension-safe core only, never the app-side SGCustomerSync
    # (which depends on SGTasks, which depends on this module).
    "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
    "//Swiftgram/SGEntitlement:SGEntitlement",
    "//Swiftgram/SGIAP:SGIAP",
    "//Swiftgram/SGLogging:SGLogging",
    "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    "//Swiftgram/SGSwiftUI:SGSwiftUI",
    "//Swiftgram/SGStrings:SGStrings",
    # `sg_config.consent_mode` for the Link row's required-mode notice (`SGPayWallFunnel.consentRequired`).
    "//submodules/BuildConfig:BuildConfig",
    "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
]

swift_library(
    name = "SGPayWall",
    module_name = "SGPayWall",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = SGPAYWALL_DEPS,
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — TEST-ONLY. The status screen's real renderer over synthetic scenarios, never linked
# into the app. It compiles the SAME `Sources/` as `SGPayWall` into a separate module (so the app
# module gains no preview/debug surface) plus `PreviewHost/Scenarios`. Nothing in it creates
# `SGEntitlement.shared` or an `SGIAPManager`, touches StoreKit, the Keychain, the network or any
# persistence (see `SGPayWallStatusPreviewScenarios.swift`).
swift_library(
    name = "SGPayWallStatusPreviewLib",
    testonly = True,
    module_name = "SGPayWallStatusPreview",
    srcs = glob([
        "Sources/**/*.swift",
        "PreviewHost/Scenarios/**/*.swift",
        "PreviewHost/Catalog/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = SGPAYWALL_DEPS,
)

swift_library(
    name = "SGPayWallStatusPreviewHostLib",
    testonly = True,
    srcs = glob([
        "PreviewHost/App/**/*.swift",
    ]),
    # The status screen draws the paywall's Z mark (`Image("pro")`); bundled as the app bundles it
    # (`data = SGRESOURCES` on //Telegram:Lib).
    data = [
        ":SGPayWallAssets",
    ],
    deps = [
        ":SGPayWallStatusPreviewLib",
    ],
)

# Its own bundle id, so its own data container. Bundles the app's `SGLocalizable.strings` (en, ru,
# uz, …) exactly as the app does (`//Telegram:AppStringResources`), so `SGStrings` resolves real
# copy. Launch `-scenario <name> -lang en|ru|uz` (see `SGPayWallStatusPreviewHostApp.swift`).
ios_application(
    name = "SGPayWallStatusPreviewHost",
    testonly = True,
    bundle_id = "org.zenlygram.SGPayWallStatusPreviewHost",
    families = ["iphone"],
    infoplists = ["PreviewHost/App/Info.plist"],
    minimum_os_version = "15.0",
    strings = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
    deps = [
        ":SGPayWallStatusPreviewHostLib",
    ],
)

swift_library(
    name = "SGPayWallStatusPreviewUITestsLib",
    testonly = True,
    srcs = [
        "Tests/StatusPreviewUITests.swift",
        "PreviewHost/Catalog/SGPayWallStatusPreviewCatalog.swift",
    ],
    data = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
)

# Pin the runner to an installed device/OS; the default selects an invalid device here.
ios_test_runner(
    name = "SGPayWallStatusPreviewTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Cross-process accessibility queries exercise SwiftUI's actual accessibility bridge.
ios_ui_test(
    name = "SGPayWallStatusPreviewTests",
    size = "large",
    minimum_os_version = "15.0",
    runner = ":SGPayWallStatusPreviewTestRunner",
    test_host = ":SGPayWallStatusPreviewHost",
    deps = [
        ":SGPayWallStatusPreviewUITestsLib",
    ],
)
