load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "SGItemListUI",
    module_name = "SGItemListUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — list-identity regression tests (pure, hostless): a row id that changes node kind between two
# states must become delete + insert, never an in-place update of the wrong node class (the Secret Vault crash).
# Plus the Settings hub's row contract: a row's tag key is its setting / link case name, pages built on
# their own `SGItemListCounter(base:)` concatenate without shifting each other, `isNew` feeds the roll-up.
swift_library(
    name = "SGItemListUITestsLib",
    testonly = True,
    srcs = [
        "Tests/SGItemListUIEntryIdentityTests.swift",
        "Tests/SGItemListUIEntryTagTests.swift",
    ],
    deps = [
        ":SGItemListUI",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/MergeLists:MergeLists",
    ],
)

# The UI stack the hosted tests use. The test HOST links exactly these, so rules_apple (`-bundle_loader`
# + avoid_deps) leaves them out of the injected test bundle. That is load-bearing: Texture's
# `+[ASDisplayNode load]` creates a UIView. Inside the injected bundle it ran under libXCTestBundleInject's
# dlopen (dyld lock held) and waited on UIKit's application-configuration `dispatch_once`, whose owner thread
# was itself waiting for the dyld lock: a deadlock, so no test ever started. Linked into the host, it runs in
# the normal pre-main initializers, as in the app. Keep the hosted test library's deps within this list.
HOSTED_TEST_UI_DEPS = [
    "//submodules/Display:Display",
    "//submodules/ItemListUI:ItemListUI",
    "//submodules/TelegramPresentationData:TelegramPresentationData",
    "//submodules/TelegramUIPreferences:TelegramUIPreferences",
]

# Zenlygram — hosted UIKit tests: drive the production ItemListSwitchItemNode the way VoiceOver and touches do
# (row element activation, spoken value, native value change) for both switch types and control modes. They
# build real ItemList nodes, which need `PresentationStrings` (see the host below).
swift_library(
    name = "SGItemListUIHostedTestsLib",
    testonly = True,
    srcs = [
        "Tests/ItemListSwitchItemAccessibilityTests.swift",
    ],
    deps = HOSTED_TEST_UI_DEPS,
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGItemListUITestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test host (never shipped). The generated `PresentationStrings` initializer reads `PresentationStrings.data`
# from the MAIN bundle and asserts when it is missing; the default rules_apple host has no resources. Like the
# Telegram app, this host bundles the generated data file at its root, so the tests can build real ItemList
# nodes. Like the app since the Xcode 27 work (docs/entitlement.md), it declares a single UIWindowScene with a
# window and an empty root view controller, plus a UILaunchScreen. It does nothing else at launch. It links
# HOSTED_TEST_UI_DEPS (Swift libraries are alwayslink) so their initializers run here, not in the test bundle.
swift_library(
    name = "SGItemListUITestHostLib",
    testonly = True,
    srcs = glob([
        "TestHost/**/*.swift",
    ]),
    deps = HOSTED_TEST_UI_DEPS,
)

ios_application(
    name = "SGItemListUITestHost",
    testonly = True,
    bundle_id = "org.zenlygram.SGItemListUITestHost",
    families = ["iphone"],
    infoplists = ["TestHost/Info.plist"],
    minimum_os_version = "15.0",
    resources = [
        "//Telegram:GeneratedPresentationStrings/Resources/PresentationStrings.data",
    ],
    deps = [
        ":SGItemListUITestHostLib",
    ],
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGItemListUITests",
    minimum_os_version = "15.0",
    runner = ":SGItemListUITestRunner",
    deps = [
        ":SGItemListUITestsLib",
    ],
)

# Hosted: rules_apple runs a test with `test_host` through `xcodebuild test-without-building`.
ios_unit_test(
    name = "SGItemListUIHostedTests",
    minimum_os_version = "15.0",
    runner = ":SGItemListUITestRunner",
    test_host = ":SGItemListUITestHost",
    deps = [
        ":SGItemListUIHostedTestsLib",
    ],
)