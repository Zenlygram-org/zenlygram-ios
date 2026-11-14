load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

sgsrcs = [
    "//Swiftgram/SGStatus:SGStatus"
]

swift_library(
    name = "TelegramUIPreferences",
    module_name = "TelegramUIPreferences",
    srcs = sgsrcs + glob([
        "Sources/**/*.swift",
    ]),
    # Zenlygram — SG_LENTA compiles RootTab.lenta / CallListSettings.showLentaTab (flag-on builds only).
    copts = [
        "-warnings-as-errors",
    ] + select({
        "//Telegram:enableLentaSetting": ["-DSG_LENTA"],
        "//conditions:default": [],
    }),
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramUIPreferencesTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    # Same define as the library, so the SG_LENTA test cases run in flag-on test builds.
    copts = select({
        "//Telegram:enableLentaSetting": ["-DSG_LENTA"],
        "//conditions:default": [],
    }),
    deps = [
        ":TelegramUIPreferences",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "TelegramUIPreferencesTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "TelegramUIPreferencesTests",
    minimum_os_version = "15.0",
    runner = ":TelegramUIPreferencesTestRunner",
    deps = [
        ":TelegramUIPreferencesTestsLib",
    ],
)
