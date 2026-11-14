load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Zenlygram — the App Store purchase flow, StoreKit 2 (design §5.2, §5.6).
#
# `SGEntitlement` owns the decision ("may this user create protected material?"); this module owns
# only the money path: products, purchase, restore, `Transaction.updates`, and the attach that must
# land BEFORE `Transaction.finish()`. It is main-app only — no extension links it.
swift_library(
    name = "SGIAP",
    module_name = "SGIAP",
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
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGConfig:SGConfig",
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
    ],
    visibility = [
        "//visibility:public",
    ],
)
