load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGTasks",
    module_name = "SGTasks",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/sqlcipher:sqlcipher",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        # Zenlygram — the CREATE gate (a new list / a new task) shows the paywall.
        "//Swiftgram/SGEntitlementUI:SGEntitlementUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/AlertUI:AlertUI",
        # SG: Tasks — audit #36: SGTaskNameAlertController builds its own free-text alert.
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/AlertComponent:AlertComponent",
        "//submodules/TelegramUI/Components/AlertComponent/AlertInputFieldComponent:AlertInputFieldComponent",
        # Zenlygram — Tasks board: delete shows the standard Undo toast.
        "//submodules/UndoUI:UndoUI",
        # Zenlygram — Cloud Tasks: the wire types (SGTasksWire), the linked-session read and change
        # notification, and the existing Telegram-account linking screen as the unlinked recovery.
        "//Swiftgram/SGEntitlement:SGEntitlement",
        "//Swiftgram/SGPayWall:SGPayWall",
        # The link screen's Telegram half (bind-attest + in-app bot link) for this account.
        "//Swiftgram/SGBindAttest:SGBindAttest",
        # Zenlygram — Cloud Tasks: read-only rows disable link detection (`EnabledEntityTypes`) so
        # another user's invitation title never becomes a tappable link.
        "//submodules/TextFormat:TextFormat",
        # Zenlygram — Tasks R4: the customer-data gate and the analytics facade. Only
        # SGTasksSyncCoordinator.swift imports it (design 30 §5.1); the leaf core has no deps.
        "//Swiftgram/SGCustomerSync:SGCustomerSyncCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
