load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGSecretVault",
    module_name = "SGSecretVault",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//Swiftgram/SGChatLock:SGChatLock",
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

