load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "SGAutoProxyResourceFiles",
    srcs = glob([
        "Resources/**/*",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "SGAutoProxyResourcesInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.swiftgram.app.SGAutoProxyResources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>SGAutoProxyResources</string>
    """
)

apple_resource_bundle(
    name = "SGAutoProxyResources",
    infoplists = [
        ":SGAutoProxyResourcesInfoPlist",
    ],
    resources = [
        ":SGAutoProxyResourceFiles",
    ],
)

swift_library(
    name = "SGAutoProxy",
    module_name = "SGAutoProxy",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SGAutoProxyResources",
    ],
    deps = [
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
    visibility = [
        "//visibility:public",
    ],
)
