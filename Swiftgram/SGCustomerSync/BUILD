load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_ui_test", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

# Zenlygram — customer data on our own server (design 40): the PURE core — consent text + hash,
# the consent store and state machine, upload ordering, clearance, auto-link and deletion policies,
# the coordinator reducer, backoff, the profile snapshot and digest, analytics taxonomy v1 + pipeline
# + queue, wire DTOs. Foundation + CryptoKit only, no module dependency, extension-safe: every feature
# module may import it for `SGAnalytics`, `SGCustomerDataGate` and `SGCustomerLinkEvents`; nothing here
# runs unless the main app installs the pipeline.
swift_library(
    name = "SGCustomerSyncCore",
    module_name = "SGCustomerSyncCore",
    srcs = glob([
        "Core/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [],
    visibility = [
        "//visibility:public",
    ],
)

plist_fragment(
    name = "SGCustomerSyncResourcesInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.zenlygram.SGCustomerSyncResources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>SGCustomerSyncResources</string>
    """
)

# The vendored consent tree (contract §5.1), paths kept: SGCustomerSyncResources.bundle/consent/manifest.json,
# .../consent/v1/{uz,ru,en}.md. Copied byte for byte by `B/tools/consent/vendor.sh`, never edited here.
# Precedent: SGAutoProxy's apple_resource_bundle (Swiftgram/SGAutoProxy/BUILD).
apple_resource_bundle(
    name = "SGCustomerSyncResources",
    infoplists = [
        ":SGCustomerSyncResourcesInfoPlist",
    ],
    structured_resources = glob([
        "Resources/consent/**",
    ]),
    strip_structured_resources_prefixes = [
        "Resources",
    ],
)

# Zenlygram — the app-side half: the coordinator driver (lifecycle, auto-link, profile sync, event
# flush), the Telegram reads and every screen (consent wall, decline, Data & consent, My data,
# deletion). Main app only; never call it from an extension.
#
# Its sources arrive with I-3 (design 40 §17). swift_library refuses an empty `srcs`, and that error
# would fail every target of this package (the core tests included), so the target is declared
# exactly when `Sources/` holds a file.
[swift_library(
    name = "SGCustomerSync",
    module_name = "SGCustomerSync",
    srcs = sources,
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SGCustomerSyncResources",
    ],
    deps = [
        ":SGCustomerSyncCore",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGBindAttest:SGBindAttest",
        "//Swiftgram/SGTasks:SGTasks",
        "//Swiftgram/SGConfig:SGConfig",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/SGSwiftUI:SGSwiftUI",
        "//Swiftgram/SGLogging:SGLogging",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
) for sources in [glob(["Sources/**/*.swift"], allow_empty = True)] if sources]

# The core's tests (design 40 §15.2), also run on the macOS host by Tests/run-core-tests.sh. The
# fixtures and the app's string tables land at the bundle root, the consent tree inside
# SGCustomerSyncResources.bundle (Tests/SGCustomerSyncTestFixtures.swift resolves both).
swift_library(
    name = "SGCustomerSyncCoreTestsLib",
    testonly = True,
    srcs = glob(
        [
            "Tests/**/*.swift",
        ],
        exclude = [
            "Tests/UI/**",
            "Tests/App/**",
        ],
    ),
    data = glob([
        "Tests/Fixtures/**",
    ]) + [
        ":SGCustomerSyncResources",
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
    deps = [
        ":SGCustomerSyncCore",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGCustomerSyncTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
#   Make.py test ... --target //Swiftgram/SGCustomerSync:SGCustomerSyncCoreTests
ios_unit_test(
    name = "SGCustomerSyncCoreTests",
    minimum_os_version = "15.0",
    runner = ":SGCustomerSyncTestRunner",
    deps = [
        ":SGCustomerSyncCoreTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — the app-side module's own checks (Tests/App, one subject per file):
# `SGCustomerSyncConfig` (consent keys, activation); `SGCustomerSync.bindPermission` (stale grants
# read as needs_reconsent included) / `myData` / `sessionEnd`; `SGCustomerTransportLive.rawAnswer`,
# and the driver's per-account turn with its clearance re-check after the turn and inside
# SGEntitlement's gate (`performIfCleared`, over a scripted facade); `SGCustomerSyncReceipts` (a
# cleared receipt drops the snapshot in flight); the call screen above the consent wall
# (`SGCallScreenPlacement`, `SGConsentWallPresenter.raisesCallScreen`);
# `SGProfileReader.accountLine` / `maskedPhone`. A logic test (no test host) over the real module,
# so it links the module's whole graph; the consent tree comes with the module's own `data`.
#   Make.py test ... --target //Swiftgram/SGCustomerSync:SGCustomerSyncAppTests
swift_library(
    name = "SGCustomerSyncAppTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/App/**/*.swift",
    ]),
    data = [
        ":SGCustomerSyncResources",
    ],
    deps = [
        ":SGCustomerSync",
        ":SGCustomerSyncCore",
        "//Swiftgram/SGEntitlement:SGEntitlement",
    ],
)

ios_unit_test(
    name = "SGCustomerSyncAppTests",
    minimum_os_version = "15.0",
    runner = ":SGCustomerSyncTestRunner",
    deps = [
        ":SGCustomerSyncAppTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# ---- TEST-ONLY preview of the consent screens (design 40 §15.6, WP I-4). The SAME `Sources/UI/Views/**` as the app
# module compiled into a separate module over fixture states (`PreviewHost/Scenarios`; precedent
# //Swiftgram/SGPayWall:SGPayWallStatusPreviewTests). Never linked into the app: no SGEntitlement, no consent store,
# no network, no persistence. The views depend on SwiftUI, the core and SGStrings only.
swift_library(
    name = "SGCustomerSyncViewsPreviewLib",
    testonly = True,
    module_name = "SGCustomerSyncViewsPreview",
    srcs = glob([
        "Sources/UI/Views/**/*.swift",
        "PreviewHost/Scenarios/**/*.swift",
        "PreviewHost/Catalog/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SGCustomerSyncResources",
    ],
    deps = [
        ":SGCustomerSyncCore",
        "//Swiftgram/SGStrings:SGStrings",
    ],
)

swift_library(
    name = "SGCustomerSyncPreviewHostLib",
    testonly = True,
    srcs = glob([
        "PreviewHost/App/**/*.swift",
    ]),
    deps = [
        ":SGCustomerSyncViewsPreviewLib",
    ],
)

# Its own bundle id and data container, iPhone and iPad. Bundles the app's `SGLocalizable.strings` as the app does,
# so SGStrings resolves the real copy. Launch `-scenario <name> -lang uz|ru|en` (see SGCustomerSyncPreviewHostApp.swift).
ios_application(
    name = "SGCustomerSyncPreviewHost",
    testonly = True,
    bundle_id = "org.zenlygram.SGCustomerSyncPreviewHost",
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
        ":SGCustomerSyncPreviewHostLib",
    ],
)

swift_library(
    name = "SGCustomerSyncPreviewUITestsLib",
    testonly = True,
    srcs = glob([
        "Tests/UI/**/*.swift",
    ]) + [
        "PreviewHost/Catalog/SGCustomerSyncPreviewCatalog.swift",
    ],
    data = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
)

ios_test_runner(
    name = "SGCustomerSyncPreviewPadRunner",
    device_type = "iPad Pro 13-inch (M5)",
    os_version = "27.0",
)

# Cross-process accessibility queries exercise SwiftUI's actual accessibility bridge, on iPhone and on iPad.
#   Make.py test ... --target //Swiftgram/SGCustomerSync:SGCustomerSyncPreviewTests (and ...PreviewPadTests)
ios_ui_test(
    name = "SGCustomerSyncPreviewTests",
    size = "large",
    minimum_os_version = "15.0",
    runner = ":SGCustomerSyncTestRunner",
    test_host = ":SGCustomerSyncPreviewHost",
    deps = [
        ":SGCustomerSyncPreviewUITestsLib",
    ],
)

ios_ui_test(
    name = "SGCustomerSyncPreviewPadTests",
    size = "large",
    minimum_os_version = "15.0",
    runner = ":SGCustomerSyncPreviewPadRunner",
    test_host = ":SGCustomerSyncPreviewHost",
    deps = [
        ":SGCustomerSyncPreviewUITestsLib",
    ],
)
