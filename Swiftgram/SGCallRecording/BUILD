load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# MARK: Zenlygram — local call recording (audio only, 1:1 calls).
#
# The Objective-C half exists for one class: a file-backed `TGDataItem` for `TGOggOpusWriter`.
# Subclassing it from Swift would depend on how the importer renames `appendData:` / `data`, and a
# rename would turn the override into a new method that nothing ever calls — i.e. a recording that
# silently stays in RAM. See ObjCSource/SGCallRecordingObjC/SGOggFileDataItem.h.
objc_library(
    name = "SGCallRecordingObjC",
    enable_modules = True,
    module_name = "SGCallRecordingObjC",
    srcs = glob([
        "ObjCSource/SGCallRecordingObjC/*.m",
    ]),
    hdrs = glob([
        "ObjCSource/SGCallRecordingObjC/*.h",
    ]),
    includes = [
        "ObjCSource",
    ],
    deps = [
        "//submodules/OpusBinding:OpusBinding",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SGCallRecording",
    module_name = "SGCallRecording",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":SGCallRecordingObjC",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/OpusBinding:OpusBinding",
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Deterministic synthetic-PCM tests of the recorder pipeline (availability and consent gates, tap
# attach/detach, mute gate, mix, Ogg file decoded back, sidecar). They drive the sink by hand: NOT a
# two-party call, and they prove nothing about the native tap, CallKit or the call screen.
swift_library(
    name = "SGCallRecordingTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SGCallRecording",
        ":SGCallRecordingObjC",
        "//submodules/OpusBinding:OpusBinding",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGCallRecordingTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGCallRecordingTests",
    minimum_os_version = "15.0",
    runner = ":SGCallRecordingTestRunner",
    deps = [
        ":SGCallRecordingTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
