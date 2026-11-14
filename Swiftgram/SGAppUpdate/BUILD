load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_ui_test", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load(":debug_override.bzl", "SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS")

# Zenlygram — the app-update policy's presenter (update_policy_spec.md §4e–h): the full-screen
# "Update required" block (a global overlay of whichever NavigationController the main window shows,
# above the consent wall, below call screens, re-presented on every root switch and after a forced
# removal), the one dismissable "Update available" reminder per launch, and the QA override of a
# non-store build. The decision itself is SGEntitlement's (`SGAppUpdate.shared`, Foundation only,
# linked into the NSE too); this module is its UIKit half and is linked into the main app only.
#
# The module is `SGAppUpdateUI`, not `SGAppUpdate`: the facade type `SGAppUpdate` lives in
# SGEntitlement, and a module of the same name would shadow it at every call site.
#
# The QA override (§4h) is compiled into non-store builds only: `SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS`
# (debug_override.bzl) defines `SG_APP_UPDATE_DEBUG_OVERRIDE` unless the build configuration says
# `is_appstore_build`; the test library below gets the same define, so its override cases follow.
swift_library(
    name = "SGAppUpdateUI",
    module_name = "SGAppUpdateUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ] + SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS,
    deps = [
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/SGSwiftUI:SGSwiftUI",
        "//Swiftgram/SGLogging:SGLogging",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — the presenter's checks (update_policy_spec §7 "iOS simulator", presenter): the block as
# a global overlay over an Unauthorized and an Authorized root, re-presented after a root switch and
# after a forced removal, above a consent wall and below a call screen, dismiss ignored, the first
# frame gated, a corrected policy lifting it, the reminder's suppressions and its marker written only
# after display, the TestFlight button variant, the QA override. A logic test (no test host) over the
# real module and a real `NavigationController` driven the way the Display in-call-bar tests drive one.
#   Make.py test ... --target //Swiftgram/SGAppUpdate:SGAppUpdateUITests
swift_library(
    name = "SGAppUpdateUITestsLib",
    testonly = True,
    srcs = glob(
        [
            "Tests/**/*.swift",
        ],
        # `Tests/UI/**` is the block's XCUITest suite over the preview host below, not a logic test.
        exclude = [
            "Tests/UI/**",
        ],
    ),
    copts = SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS,
    deps = [
        ":SGAppUpdateUI",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGAppUpdateTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGAppUpdateUITests",
    minimum_os_version = "15.0",
    runner = ":SGAppUpdateTestRunner",
    deps = [
        ":SGAppUpdateUITestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# ---- TEST-ONLY preview of the block screen (update_policy_spec §7, iOS simulator, presenter: "Help link hittable
# without scrolling (iPhone/iPad preview catalog)"; precedent //Swiftgram/SGCustomerSync:SGCustomerSyncPreviewTests).
# The host lays the REAL `SGAppUpdateBlockController` out the way the app does — a `NavigationController` installed in
# a container of the scenario's size and laid out through `containerLayoutUpdated`, the block presented on it as a
# global overlay — for the catalog's geometries (a 4.7-inch frame, the device's window; portrait and landscape),
# store-button variants, languages and Dynamic Type sizes (regular, AX5). Never linked into the app: no SGEntitlement,
# no policy, no network, no persistence. `@testable import SGAppUpdateUI` reaches the internal controller and model.
swift_library(
    name = "SGAppUpdateBlockPreviewHostLib",
    testonly = True,
    srcs = glob([
        "PreviewHost/App/**/*.swift",
        "PreviewHost/Catalog/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":SGAppUpdateUI",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
)

# Its own bundle id and data container, iPhone and iPad. Bundles the app's `SGLocalizable.strings` as the app does,
# so SGStrings resolves the real copy. Launch arguments: `SGAppUpdateBlockPreviewScenario.launchArguments`.
ios_application(
    name = "SGAppUpdateBlockPreviewHost",
    testonly = True,
    bundle_id = "org.zenlygram.SGAppUpdateBlockPreviewHost",
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        "PreviewHost/App/Info.plist",
    ],
    minimum_os_version = "15.0",
    strings = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
    deps = [
        ":SGAppUpdateBlockPreviewHostLib",
    ],
)

swift_library(
    name = "SGAppUpdateBlockPreviewUITestsLib",
    testonly = True,
    srcs = glob([
        "Tests/UI/**/*.swift",
    ]) + [
        "PreviewHost/Catalog/SGAppUpdateBlockPreviewCatalog.swift",
    ],
    data = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
)

ios_test_runner(
    name = "SGAppUpdateBlockPreviewPadRunner",
    device_type = "iPad Pro 13-inch (M5)",
    os_version = "27.0",
)

# Cross-process accessibility queries exercise SwiftUI's actual accessibility bridge, on iPhone and on iPad.
#   Make.py test ... --target //Swiftgram/SGAppUpdate:SGAppUpdateBlockPreviewTests (and ...PreviewPadTests)
ios_ui_test(
    name = "SGAppUpdateBlockPreviewTests",
    size = "large",
    minimum_os_version = "15.0",
    runner = ":SGAppUpdateTestRunner",
    test_host = ":SGAppUpdateBlockPreviewHost",
    deps = [
        ":SGAppUpdateBlockPreviewUITestsLib",
    ],
)

ios_ui_test(
    name = "SGAppUpdateBlockPreviewPadTests",
    size = "large",
    minimum_os_version = "15.0",
    runner = ":SGAppUpdateBlockPreviewPadRunner",
    test_host = ":SGAppUpdateBlockPreviewHost",
    deps = [
        ":SGAppUpdateBlockPreviewUITestsLib",
    ],
)
