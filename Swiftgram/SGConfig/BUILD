load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "SGConfig",
    module_name = "SGConfig",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Zenlygram — SG_LENTA compiles the `sg_config.lenta_iaps` routing (flag-on builds only).
    copts = [
        "-warnings-as-errors",
    ] + select({
        "//Telegram:enableLentaSetting": ["-DSG_LENTA"],
        "//conditions:default": [],
    }),
    deps = [
        "//submodules/BuildConfig:BuildConfig"
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — how `sg_config` decodes (design 40 §3: `consent_mode` / `consent_operator`), with the
# decoder `parseSGConfig` uses; a logic test, no app host:
#   Make.py test ... --target //Swiftgram/SGConfig:SGConfigTests
swift_library(
    name = "SGConfigTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SGConfig",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGConfigTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGConfigTests",
    minimum_os_version = "15.0",
    runner = ":SGConfigTestRunner",
    deps = [
        ":SGConfigTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
