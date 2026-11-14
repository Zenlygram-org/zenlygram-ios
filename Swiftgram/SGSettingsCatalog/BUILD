load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# Zenlygram — the Settings → Zenlygram hub-and-pages inventory (settings IA, 2026-11): the pages in hub
# order, the hub's own rows, every row key's page, the deep-link focus keys and the string keys the hub
# introduced. Data only — Foundation, no UIKit, no SG_LENTA (the catalog never names Lenta) — so its tests
# run hostless, and SGSettingsUI's DEBUG guard ties the inventory to the real entries builder.
swift_library(
    name = "SGSettingsCatalog",
    module_name = "SGSettingsCatalog",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [],
    visibility = [
        "//visibility:public",
    ],
)

# Hostless XCTest over the catalog: every row placed once, the frozen 107-key inventory, page(containing:),
# the id bases, the NEW-badge oracle and the en/ru/uz tables (the app's SGLocalizable.strings land at the
# bundle root as `<lang>.lproj/SGLocalizable.strings`, the SGCustomerSyncCoreTests pattern).
swift_library(
    name = "SGSettingsCatalogTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    data = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ],
    deps = [
        ":SGSettingsCatalog",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGSettingsCatalogTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
#   Make.py test ... --target //Swiftgram/SGSettingsCatalog:SGSettingsCatalogTests
ios_unit_test(
    name = "SGSettingsCatalogTests",
    minimum_os_version = "15.0",
    runner = ":SGSettingsCatalogTestRunner",
    deps = [
        ":SGSettingsCatalogTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
