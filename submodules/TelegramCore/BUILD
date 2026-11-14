load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

sgdeps = [
    "//Swiftgram/SGGTranslate:SGGTranslate",
    "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    "//Swiftgram/SGTranslationLangFix:SGTranslationLangFix",
    "//Swiftgram/SGWebSettingsScheme:SGWebSettingsScheme",
    "//Swiftgram/SGGHSettingsScheme:SGGHSettingsScheme",
    "//Swiftgram/SGConfig:SGConfig",
    "//Swiftgram/SGLogging:SGLogging",
]

sgsrc = [
    "//Swiftgram/SGIQTP:SGIQTP",
]

swift_library(
    name = "TelegramCore",
    module_name = "TelegramCore",
    srcs = sgsrc + glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = sgdeps + [
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/CloudData:CloudData",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/NetworkLogging:NetworkLogging",
        "//submodules/Reachability:Reachability",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/Utils/DarwinDirStat",
        "//submodules/Emoji",
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
        "//submodules/MurMurHash32"
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — retained message history on the real Postbox replay path (a temporary on-disk Postbox):
# the delete / global-id delete / validation / edit capture entrypoints under the app-group capture flag.
#   Make.py test ... --target //submodules/TelegramCore:SGRetainedHistoryCaptureTests
swift_library(
    name = "SGRetainedHistoryCaptureTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGRetainedHistoryCaptureTests.swift",
    ],
    deps = [
        ":TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGRetainedHistoryCaptureTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGRetainedHistoryCaptureTests",
    minimum_os_version = "15.0",
    runner = ":SGRetainedHistoryCaptureTestRunner",
    deps = [
        ":SGRetainedHistoryCaptureTestsLib",
    ],
)
