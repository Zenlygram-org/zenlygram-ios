load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Zenlygram — the one place a blocked CREATE turns into a paywall.
#
# `SGEntitlement` itself knows nothing about controllers (it is linked into the Notification
# Service Extension), so the UI half of the gate lives here: a single call that answers the
# predicate and, when the answer is no, shows the paywall — never an error, never a retry loop,
# never a purchase link that leaves the App Store (guideline 3.1.3(b)).
swift_library(
    name = "SGEntitlementUI",
    module_name = "SGEntitlementUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGStrings:SGStrings",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
