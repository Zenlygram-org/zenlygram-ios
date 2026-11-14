load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Zenlygram — Secret Vault / Chat Lock state shared by the app and its extensions (audit batch 3).
# Extension-safe: Foundation + Security + notify only (UIKit is imported for notification names, never
# for UIApplication.shared). Keep the dependency list minimal: it is linked into the NSE, Widget and Intents.
swift_library(
    name = "SGProtectedStore",
    module_name = "SGProtectedStore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
    ],
    visibility = [
        "//visibility:public",
    ],
)
