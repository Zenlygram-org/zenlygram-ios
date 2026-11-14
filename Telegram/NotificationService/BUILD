load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

sgdeps = [
    "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
    # Zenlygram — Secret Vault / Chat Lock state shared with the app (audit batch 3: push redaction).
    # Deduplicated through TelegramUIFramework (TelegramUI already links it).
    "//Swiftgram/SGProtectedStore:SGProtectedStore",
    # Zenlygram — audit #49: "Keep deleted messages" (app-group suite, read uncached in extensions).
    # It also carries `editHistoryCaptureBlocked`, the entitlement flag the Postbox replay reads here.
    "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    # Zenlygram — the cached entitlement, read from the App Group. The extension uses ONLY
    # `SGEntitlementMirrorStore.evaluate()`; it must never construct `SGEntitlementClient`.
    "//Swiftgram/SGEntitlement:SGEntitlement",
]

swift_library(
    name = "NotificationServiceExtensionLib",
    module_name = "NotificationServiceExtensionLib",
    srcs = glob([
        "Sources/*.swift",
    ]),
    deps = sgdeps + [
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/AppLockState:AppLockState",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/rlottie:RLottieBinding",
        "//submodules/GZip:GZip",
        "//submodules/PersistentStringHash:PersistentStringHash",
        "//submodules/Utils/RangeSet",
        "//submodules/Media/ConvertOpusToAAC",
    ],
    visibility = [
        "//visibility:public",
    ],
)
