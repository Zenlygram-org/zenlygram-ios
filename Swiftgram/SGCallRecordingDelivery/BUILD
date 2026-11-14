load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# MARK: Zenlygram — call recording, delivery to the user's own Saved Messages.
#
# A module of its own rather than code inside SGCallRecording: the recorder deliberately depends on
# nothing but SwiftSignalKit, Opus and SGSimpleSettings, and the whole point of that is that the
# piece touching the audio stays small enough to read in one sitting. Sending needs TelegramCore and
# AccountContext, and both the call screen (TelegramCallsUI) and the recordings list (SGSettingsUI)
# have to reach it.
#
# The decisions (privacy policy, acknowledgement evidence, leg merging, resource ownership) and the
# delivery's own durable ledger live in a Foundation-only core so they can be unit-tested without an
# account, a Postbox or a recording.
swift_library(
    name = "SGCallRecordingDeliveryCore",
    module_name = "SGCallRecordingDeliveryCore",
    srcs = glob([
        "Core/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SGCallRecordingDelivery",
    module_name = "SGCallRecordingDelivery",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":SGCallRecordingDeliveryCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//Swiftgram/SGCallRecording:SGCallRecording",
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGStrings:SGStrings",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SGCallRecordingDeliveryTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SGCallRecordingDeliveryCore",
        # The REAL upload gate combinator (`OutgoingLocalFileUploadGate.gate`) is tested here, so
        # TelegramCore's own BUILD stays untouched.
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md). Same pin as SGCallRecordingTests.
ios_test_runner(
    name = "SGCallRecordingDeliveryTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

ios_unit_test(
    name = "SGCallRecordingDeliveryTests",
    minimum_os_version = "15.0",
    runner = ":SGCallRecordingDeliveryTestRunner",
    deps = [
        ":SGCallRecordingDeliveryTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
