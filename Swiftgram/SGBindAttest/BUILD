load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Zenlygram — the Telegram half of "Link Telegram Account" (bind-attest v1): the account's silent
# Mini App attestation over MTProto and its in-app opening of the fallback bot link. SGPayWall has
# no TelegramCore; every caller that holds an AccountContext builds the screen's
# `SGLinkAccountTelegram` here.
swift_library(
    name = "SGBindAttest",
    module_name = "SGBindAttest",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGPayWall:SGPayWall",
    ],
    visibility = [
        "//visibility:public",
    ],
)
