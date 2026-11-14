load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "NavigationBarImpl",
    module_name = "NavigationBarImpl",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/EdgeEffect",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "NavigationBarImplTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":NavigationBarImpl",
        "//submodules/Display",
        "//submodules/AsyncDisplayKit",
    ],
)

ios_test_runner(
    name = "NavigationBarImplTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only deployment floor; the app's deployment target is unchanged.
ios_unit_test(
    name = "NavigationBarImplTests",
    minimum_os_version = "15.0",
    runner = ":NavigationBarImplTestRunner",
    deps = [":NavigationBarImplTestsLib"],
)
