load("@bazel_skylib//rules:common_settings.bzl",
    "bool_flag",
)

load("@bazel_skylib//lib:selects.bzl", "selects")

load("@build_bazel_rules_apple//apple:ios.bzl",
    "ios_application",
    "ios_extension",
    "ios_framework",
    "ios_ui_test",
    "ios_ui_test_suite",
)

load(
    "@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl",
    "ios_test_runner",
)

# MARK: Swiftgram
load("@build_bazel_rules_apple//apple:watchos.bzl",
    "watchos_application",
    "watchos_extension",
)

load("@build_bazel_rules_apple//apple:resources.bzl",
    "swift_intent_library",
)

load("@build_bazel_rules_swift//swift:swift.bzl",
    "swift_library",
)

load(
    "@rules_xcodeproj//xcodeproj:defs.bzl",
    "top_level_targets",
    "top_level_target",
    "xcodeproj",
    "xcode_provisioning_profile",
)

load("@build_bazel_rules_apple//apple:apple.bzl", "local_provisioning_profile")

load("//Telegram:prebuilt_watchos.bzl",
    "apple_prebuilt_watchos_application",
)

load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

load(
    "@build_configuration//:variables.bzl",
    "telegram_bazel_path",
    "telegram_use_xcode_managed_codesigning",
    "telegram_bundle_id",
    "telegram_minimum_os_version",
    "telegram_aps_environment",
    "telegram_team_id",
    "telegram_enable_icloud",
    "telegram_enable_siri",
)

load("@build_bazel_rules_apple//apple:resources.bzl",
    "swift_intent_library",
)

load("//build-system/bazel-utils:spm.bzl",
    "generate_spm",
)

config_setting(
    name = "debug",
    values = {
        "compilation_mode": "dbg",
    },
)

bool_flag(
    name = "disableExtensions",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

bool_flag(
    name = "disableProvisioningProfiles",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

bool_flag(
    name = "projectIncludeRelease",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "disableExtensionsSetting",
    flag_values = {
        ":disableExtensions": "True",
    },
)

config_setting(
    name = "disableProvisioningProfilesSetting",
    flag_values = {
        ":disableProvisioningProfiles": "True",
    },
)

bool_flag(
    name = "embedWatchApp",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "embedWatchAppSetting",
    flag_values = {
        ":embedWatchApp": "True",
    },
)

# Zenlygram — the one build boundary for the Lenta feed (spec 19 "Build chegarasi"). Every SGFeed*
# module, the SG_LENTA Swift define and the Lenta entitlements enter the build only through selects on
# :enableLentaSetting (public: TelegramUI, TelegramUIPreferences, SGSettingsUI and SGAccountCleanup
# select on it). Make.py sets the flag with --enableLenta.
bool_flag(
    name = "enableLenta",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "enableLentaSetting",
    flag_values = {
        ":enableLenta": "True",
    },
    visibility = ["//visibility:public"],
)

# Zenlygram — the Telegram Login return domain applinks:app{lentaTelegramLoginAppId}-login.tg.dev (the
# BotFather-issued app id of Lenta's Telegram Login client). Make.py sets this flag together with
# --define=lentaTelegramLoginAppId= when the configuration has `lenta_telegram_login_app_id`; it only
# matters together with :enableLenta (see TelegramLentaLoginEntitlements).
bool_flag(
    name = "enableLentaTelegramLogin",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "enableLentaTelegramLoginSetting",
    flag_values = {
        ":enableLenta": "True",
        ":enableLentaTelegramLogin": "True",
    },
)

config_setting(
    name = "projectIncludeReleaseSetting",
    flag_values = {
        ":projectIncludeRelease": "True",
    },
)

bool_flag(
    name = "disableStripping",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "disableStrippingSetting",
    flag_values = {
        ":disableStripping": "True",
    },
)

genrule(
    name = "empty",
    outs = ["empty.swift"],
    cmd = "touch $(OUTS)",
)

genrule(
    name = "GeneratedPresentationStrings",
    srcs = [
        "//build-system:GenerateStrings/GenerateStrings.py",
        "Telegram-iOS/en.lproj/Localizable.strings",
    ],
    cmd = '''
        python3 $(location //build-system:GenerateStrings/GenerateStrings.py) \\
            --source=$(location Telegram-iOS/en.lproj/Localizable.strings) \\
            --outImplementation=$(location GeneratedPresentationStrings/Sources/PresentationStrings.m) \\
            --outHeader=$(location GeneratedPresentationStrings/PublicHeaders/PresentationStrings/PresentationStrings.h) \\
            --outData=$(location GeneratedPresentationStrings/Resources/PresentationStrings.data) \\
    ''',
    outs = [
        "GeneratedPresentationStrings/PublicHeaders/PresentationStrings/PresentationStrings.h",
        "GeneratedPresentationStrings/Sources/PresentationStrings.m",
        "GeneratedPresentationStrings/Resources/PresentationStrings.data",
    ],
    # MARK: Swiftgram
    visibility = [
        "//visibility:public",
    ],
)

# Make.py preserves 13.0 by default; --simulatorMinimumOS / --deviceMinimumOS override the SDK floor per build.
# The App Store build (release_arm64 on Xcode 27, whose SDK refuses floors below 15.0) passes --deviceMinimumOS=15.0,
# so the shipped IPA's MinimumOSVersion is 15.0 ("Requires iOS 15.0 or later"); iOS 13 -> 15 drops no device model.
minimum_os_version = telegram_minimum_os_version
minimum_watchos_version="7.0" # MARK: Swiftgram

notificationServiceExtensionVersion = "v1"

empty_languages = [
    "ar",
    "be",
    "ca",
    "de",
    "es",
    "fa",
    "fr",
    "id",
    "it",
    "ko",
    "ms",
    "nl",
    "pl",
    "pt",
    "ru",
    "tr",
    "uk",
    "uz",
]

[
    genrule(
        name = "Localizable_{}.strings".format(language),
        outs = ["{}.lproj/Localizable.strings".format(language)],
        cmd = "touch $(OUTS)",
    ) for language in empty_languages
]

objc_library(
    name = "PresentationStrings",
    enable_modules = True,
    module_name = "PresentationStrings",
    srcs = [
        "GeneratedPresentationStrings/Sources/PresentationStrings.m",
    ],
    hdrs = [
        "GeneratedPresentationStrings/PublicHeaders/PresentationStrings/PresentationStrings.h",
    ],
    includes = [
        "GeneratedPresentationStrings/PublicHeaders",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    deps = [
        "//submodules/NumberPluralizationForm:NumberPluralizationForm",
        "//submodules/AppBundle:AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "_LocalDebugOptions",
    srcs = [":empty"],
    copts = [
        "-Xfrontend",
        "-serialize-debugging-options",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
        "//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/Crc32:Crc32",
        "//submodules/MurMurHash32:MurMurHash32",
        "//submodules/StringTransliteration:StringTransliteration",
        "//submodules/sqlcipher:sqlcipher",
        "//submodules/NumberPluralizationForm:NumberPluralizationForm",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/MtProtoKit:MtProtoKit",
    ],
    module_name = "_LocalDebugOptions",
    tags = ["no-remote"],
    visibility = ["//visibility:public"],
)

debug_deps = select({
    ":debug": [":_LocalDebugOptions"],
    "//conditions:default": [],
})

selects.config_setting_group(
    name = "resolvedDisableStrippingSetting",
    match_any = [":debug", ":disableStrippingSetting"],
)

strip_framework = select({
    ":resolvedDisableStrippingSetting": None,
    "//conditions:default": ":StripFramework",
})

filegroup(
    name = "AppResources",
    srcs = glob([
        "Telegram-iOS/Resources/**/*",
    ], exclude = ["Telegram-iOS/Resources/**/.*"]),
)

# Zenlygram — the Lenta push alert texts (BIL-07; backend push.md §3 `title-loc-key` / `loc-key` LENTA_PUSH_*), which
# iOS resolves only from the main bundle's Localizable.strings: with --//Telegram:enableLenta the en table gets them
# appended, ru and uz get their own, every other language the English ones (a missing key would show raw).
lenta_push_alert_languages = ["ru", "uz"]

genrule(
    name = "LentaLocalizable_en.strings",
    srcs = [
        "Telegram-iOS/en.lproj/Localizable.strings",
        "//Swiftgram/SGFeedStrings:PushAlerts/en.lproj/Localizable.strings",
    ],
    outs = ["LentaStrings/en.lproj/Localizable.strings"],
    cmd = "{ cat $(location Telegram-iOS/en.lproj/Localizable.strings); echo; cat $(location //Swiftgram/SGFeedStrings:PushAlerts/en.lproj/Localizable.strings); } > $(OUTS)",
)

[
    genrule(
        name = "LentaLocalizable_{}.strings".format(language),
        srcs = ["//Swiftgram/SGFeedStrings:PushAlerts/{}.lproj/Localizable.strings".format(
            language if language in lenta_push_alert_languages else "en",
        )],
        outs = ["LentaStrings/{}.lproj/Localizable.strings".format(language)],
        cmd = "cp $(SRCS) $(OUTS)",
    ) for language in empty_languages
]

filegroup(
    name = "LentaLocalizableStrings",
    srcs = [":LentaLocalizable_{}.strings".format(language) for language in ["en"] + empty_languages],
)

filegroup(
    name = "AppStringResources",
    srcs = [
        "//Swiftgram/SGStrings:SGLocalizableStrings",
    ] + select({
        ":enableLentaSetting": [":LentaLocalizableStrings"],
        "//conditions:default": [
            "Telegram-iOS/en.lproj/Localizable.strings",
        ] + [
            "{}.lproj/Localizable.strings".format(language) for language in empty_languages
        ],
    }),
    # MARK: Swiftgram
    visibility = ["//visibility:public",],
)

filegroup(
    name = "AppIntentVocabularyResources",
    srcs = glob([
        "Telegram-iOS/*.lproj/AppIntentVocabulary.plist",
    ], exclude = ["Telegram-iOS/*.lproj/**/.*"]),
)

filegroup(
    name = "InfoPlistStringResources",
    srcs = glob([
        "Telegram-iOS/*.lproj/InfoPlist.strings",
    ], exclude = ["Telegram-iOS/*.lproj/**/.*"]),
)

filegroup(
    name = "Icons",
    srcs = glob([
        "Telegram-iOS/Icons.xcassets/**/*",
    ], exclude = ["Telegram-iOS/Icons.xcassets/**/.*"]),
)

filegroup(
    name = "DefaultAppIcon",
    srcs = glob([
        "Telegram-iOS/DefaultAppIcon.xcassets/**/*",
    ], exclude = ["Telegram-iOS/DefaultAppIcon.xcassets/**/.*"]),
)

# MARK: Zenlygram — iOS Privacy Manifest (required by App Store; rules_apple places a file named
# PrivacyInfo.xcprivacy at the .app bundle root when it is listed in resources).
filegroup(
    name = "PrivacyManifest",
    srcs = ["Telegram-iOS/PrivacyInfo.xcprivacy"],
)

# MARK: Zenlygram — privacy manifests for the embedded extensions. App Store Connect checks each
# PlugIns/*.appex executable against its own bundle's manifest (ITMS-91053), so the .app one above does
# not cover them. Declared for the extension binary plus the shared frameworks it loads: app-group and
# standard UserDefaults (NotificationService, SGSimpleSettings), Postbox/SQLite stat/statfs inside the
# app group container, MtProtoKit mach_absolute_time. No tracking and no collected data types.
filegroup(
    name = "ExtensionPrivacyManifest",
    srcs = ["ExtensionPrivacy/Default/PrivacyInfo.xcprivacy"],
)

# Share adds user-picked file metadata (3B52.1) and the caption field's input-mode lookup (54BD.1).
filegroup(
    name = "ShareExtensionPrivacyManifest",
    srcs = ["ExtensionPrivacy/Share/PrivacyInfo.xcprivacy"],
)

# MARK: Swiftgram alternative icons
# Zenlygram — the Z* icon pack replaces the Swiftgram SG* set (old "Z + paper plane" artwork, audit #53).
# ZSignature mirrors the primary Zenlygram.icon: it ships so Settings can preview it, and picking it resets
# to the primary icon (isDefault in AppDelegate). Each .alticon holds <Name>@2x.png (120), <Name>@3x.png (180)
# and <Name>@2x~ipad.png (167, 83.5pt). rules_apple's alticonstool writes the same CFBundleIconFiles
# ["<Name>"] into CFBundleIcons and CFBundleIcons~ipad; the ~ipad device modifier makes iPad resolve the
# 167px file instead of upscaling the 120px iPhone one.
alternate_icon_folders = [
    "ZSignature",
    "ZFlow",
    "ZGlass",
    "ZMinimal",
    "ZGradient",
    "ZCircle",
    "ZMonochrome",
    "ZOutline",
    "ZDuotone",
    "ZDark",
    "ZAero",
    "ZFold",
    "ZWave",
    "ZCorner",
    "ZFocus",
    "ZBaltic",
    "ZNeon",
    "ZIsometric",
    "ZClean",
    "ZPremium",
]

composer_icon_folders = ["Zenlygram"]

[
    filegroup(
        name = "{}".format(name),
        srcs = glob([
            "Telegram-iOS/{}.alticon/*.png".format(name),
        ]),
    ) for name in alternate_icon_folders
]

[
    filegroup(
        name = "{}_icon".format(name),
        srcs = glob([
            "Telegram-iOS/{}.icon/**/*".format(name),
        ]),
    ) for name in composer_icon_folders
]

filegroup(
    name = "LaunchScreen",
    srcs = glob([
        "Telegram-iOS/Base.lproj/LaunchScreen.xib",
    ]),
)

objc_library(
    name = "Main",
    module_name = "Main",
    srcs = [
        "Telegram-iOS/main.m"
    ],
)

SGRESOURCES = ["//Swiftgram/SGSettingsUI:SGUIAssets", "//Swiftgram/SGPayWall:SGPayWallAssets", "//Swiftgram/SGAppBadgeAssets:SGAppBadgeAssets", "//Swiftgram/SGNY:SGNYAssets"]

swift_library(
    name = "Lib",
    module_name = "Lib",
    srcs = glob([
        "Telegram-iOS/Application.swift",
    ]),
    data = SGRESOURCES + [
        ":Icons",
        ":AppResources",
        ":AppIntentVocabularyResources",
        ":InfoPlistStringResources",
        "//submodules/LegacyComponents:LegacyComponentsResources",
        "//submodules/LegacyComponents:LegacyComponentsAssets",
        "//submodules/OverlayStatusController:OverlayStatusControllerResources",
        "//submodules/PasswordSetupUI:PasswordSetupUIResources",
        "//submodules/PasswordSetupUI:PasswordSetupUIAssets",
        "//submodules/PremiumUI:PremiumUIResources",
        "//submodules/DrawingUI:DrawingUIResources",
        "//submodules/TelegramUI:TelegramUIResources",
        "//submodules/TelegramUI:TelegramUIAssets",
        "//submodules/TelegramUI/Components/Calls/CallScreen:Assets",
        ":GeneratedPresentationStrings/Resources/PresentationStrings.data",
    ],
    deps = [
        "//submodules/TelegramUI:TelegramUI",
        "//third-party/boringssl:crypto",
    ],
)

plist_fragment(
    name = "BuildNumberInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleVersion</key>
    <string>{buildNumber}</string>
    """,
    defaults = {"buildNumber": "1"},
)

plist_fragment(
    name = "UrlTypesInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>{telegram_bundle_id}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>telegram</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>{telegram_bundle_id}.compatibility</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tg</string>
                <string>tonsite</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>{telegram_bundle_id}.custom</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>sg</string>
            </array>
        </dict>
    </array>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

official_apple_pay_merchants = [
    "merchant.ph.telegra.Telegraph",
    "merchant.sberbank.ph.telegra.Telegraph",
    "merchant.sberbank.test.ph.telegra.Telegraph",
    "merchant.privatbank.test.telergramios",
    "merchant.privatbank.prod.telergram",
    "merchant.paymaster.test.telegramios",
    "merchant.paymaster.prod.telegramios",
    "merchant.smartglocal.prod.telegramios",
    "merchant.smartglocal.test.telegramios",
    "merchant.yoomoney.test.telegramios",
    "merchant.yoomoney.prod.telegramios",
    "merchant.org.telegram.Best2pay.test",
    "merchant.psbank.test.telegramios",
    "merchant.psbank.prod.telegramios",
    "merchant.org.telegram.billinenet.test",
    "merchant.org.telegram.billinenet.prod",
    "merchant.org.telegram.portmone.test",
    "merchant.org.telegram.portmone.prod",
    "merchant.org.telegram.ecommpay.test",
]

official_bundle_ids = [
    "ph.telegra.Telegraph",
    "org.telegram.Telegram-iOS",
]

store_bundle_ids = [
    "ph.telegra.Telegraph",
]

apple_pay_merchants = official_apple_pay_merchants if telegram_bundle_id == "ph.telegra.Telegraph" else []

apple_pay_merchants_fragment = "" if apple_pay_merchants == [] else """
<key>com.apple.developer.in-app-payments</key>
<array>
""" + "\n".join([
"    <string>{merchant_id}</string>".format(merchant_id=merchant_id) for merchant_id in apple_pay_merchants
]) + "\n" + """
</array>
"""

official_unrestricted_voip_fragment = """
<key>com.apple.developer.pushkit.unrestricted-voip</key>
<true/>
"""
unrestricted_voip_fragment = official_unrestricted_voip_fragment if telegram_bundle_id in official_bundle_ids else ""

official_carplay_fragment = """
<key>com.apple.developer.carplay-messaging</key>
<true/>
"""
# MARK: Swiftgram — restored the official-bundle condition: personal-team (free
# Apple ID) provisioning can't grant CarPlay, and official bundles keep it anyway.
carplay_fragment = official_carplay_fragment if telegram_bundle_id in official_bundle_ids else ""

icloud_fragment = "" if not telegram_enable_icloud else """
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.{telegram_bundle_id}</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>{telegram_team_id}.{telegram_bundle_id}</string>
<key>com.apple.developer.icloud-container-environment</key>
<string>{telegram_icloud_environment}</string>
""".format(
    telegram_team_id=telegram_team_id,
    telegram_bundle_id=telegram_bundle_id,
    telegram_icloud_environment="Production" if telegram_aps_environment == "production" else "Development"
)

official_associated_domains = [
    "applinks:telegram.me",
    "applinks:t.me",
    "applinks:*.t.me",
    "applinks:swiftgram.app",
    "webcredentials:swiftgram.app",
    "webcredentials:t.me",
    "webcredentials:telegram.org",
]
associated_domains = official_associated_domains if telegram_bundle_id in official_bundle_ids else []

associated_domains_fragment = "" if associated_domains == [] else """
<key>com.apple.developer.associated-domains</key>
<array>
""" + "\n".join([
"    <string>{domain}</string>".format(domain=domain) for domain in associated_domains
]) + "\n" + """</array>
"""

siri_fragment = "" if not telegram_enable_siri else """
<key>com.apple.developer.siri</key>
<true/>
"""

aps_fragment = "" if telegram_aps_environment == "" else """
<key>aps-environment</key>
<string>{telegram_aps_environment}</string>
""".format(telegram_aps_environment=telegram_aps_environment)

app_groups_fragment = """
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.{telegram_bundle_id}</string>
    </array>
    <key>application-identifier</key>
    <string>{telegram_team_id}.{telegram_bundle_id}</string>
""".format(
    telegram_team_id=telegram_team_id,
    telegram_bundle_id=telegram_bundle_id
)

official_communication_notifications_fragment = """
<key>com.apple.developer.usernotifications.communication</key>
<true/>
"""
# Restored condition for the same personal-team provisioning reason as CarPlay above.
communication_notifications_fragment = official_communication_notifications_fragment if telegram_bundle_id in official_bundle_ids else ""

official_notification_filtering_fragment = """
<key>com.apple.developer.usernotifications.filtering</key>
<true/>
"""
notification_filtering_fragment = official_notification_filtering_fragment if telegram_bundle_id == "app.swiftgram.ios" else ""

store_signin_fragment = """
<key>com.apple.developer.applesignin</key>
<array>
    <string>Default</string>
</array>
"""
signin_fragment = store_signin_fragment if telegram_bundle_id in store_bundle_ids else ""

official_background_gpu_fragment = """
<key>com.apple.developer.background-tasks.continued-processing.gpu</key>
<true/>
"""
background_gpu_fragment = official_background_gpu_fragment if telegram_bundle_id == "app.swiftgram.ios" else ""

plist_fragment(
    name = "TelegramEntitlements",
    extension = "entitlements",
    template = "".join([
        aps_fragment,
        app_groups_fragment,
        siri_fragment,
        associated_domains_fragment,
        icloud_fragment,
        apple_pay_merchants_fragment,
        unrestricted_voip_fragment,
        carplay_fragment,
        communication_notifications_fragment,
        notification_filtering_fragment,
        signin_fragment,
        background_gpu_fragment,
    ])
)

# Zenlygram — Lenta entitlements (spec 19 "Upstream patch ruxsat ro'yxati"). Used instead of
# :TelegramEntitlements only when --//Telegram:enableLenta is set, so a flag-off build signs with
# exactly the Lenta-free list above. Adds, to the associated-domains array: the APPLINKS_HOST
# universal-link domain and the same host as `webcredentials:` (passkey relying party);
# `{lentaApplinksHost}` comes from `--define=lentaApplinksHost=` that Make.py passes from the
# configuration's optional `lenta_applinks_host`, default below. With --//Telegram:enableLentaTelegramLogin
# (configuration `lenta_telegram_login_app_id`), :TelegramLentaLoginEntitlements also adds the Telegram
# Login return domain `applinks:app{lentaTelegramLoginAppId}-login.tg.dev`. Both add the App Attest
# environment (matches the APS environment of the resolved profiles), DeclaredAgeRange (iOS 26+; the
# framework is weak-linked by the module that calls it) and SensitiveContentAnalysis (iOS 17+).
# scripts/lenta-boundary-check.sh holds the same list (LENTA_ENTITLEMENTS) and checks candidates against it.
# `manual`: a wildcard build must not analyze these flag-on-only targets.
lenta_associated_domains = associated_domains + [
    "applinks:{lentaApplinksHost}",
    "webcredentials:{lentaApplinksHost}",
]

lenta_login_associated_domains = lenta_associated_domains + [
    "applinks:app{lentaTelegramLoginAppId}-login.tg.dev",
]

lenta_associated_domains_fragment = """
<key>com.apple.developer.associated-domains</key>
<array>
""" + "\n".join([
"    <string>{domain}</string>".format(domain=domain) for domain in lenta_associated_domains
]) + "\n" + """</array>
"""

lenta_login_associated_domains_fragment = """
<key>com.apple.developer.associated-domains</key>
<array>
""" + "\n".join([
"    <string>{domain}</string>".format(domain=domain) for domain in lenta_login_associated_domains
]) + "\n" + """</array>
"""

lenta_app_attest_fragment = """
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>{environment}</string>
""".format(environment="production" if telegram_aps_environment == "production" else "development")

lenta_declared_age_range_fragment = """
<key>com.apple.developer.declared-age-range</key>
<true/>
"""

lenta_sensitive_content_analysis_fragment = """
<key>com.apple.developer.sensitivecontentanalysis.client</key>
<array>
    <string>analysis</string>
</array>
"""

lenta_entitlements_head = [
    aps_fragment,
    app_groups_fragment,
    siri_fragment,
]

lenta_entitlements_tail = [
    icloud_fragment,
    apple_pay_merchants_fragment,
    unrestricted_voip_fragment,
    carplay_fragment,
    communication_notifications_fragment,
    notification_filtering_fragment,
    signin_fragment,
    background_gpu_fragment,
    lenta_app_attest_fragment,
    lenta_declared_age_range_fragment,
    lenta_sensitive_content_analysis_fragment,
]

plist_fragment(
    name = "TelegramLentaEntitlements",
    extension = "entitlements",
    template = "".join(lenta_entitlements_head + [lenta_associated_domains_fragment] + lenta_entitlements_tail),
    defaults = {
        "lentaApplinksHost": "lenta.zenlygram.com",
    },
    tags = ["manual"],
)

# No default for lentaTelegramLoginAppId: this target is selected only when Make.py passes the define.
plist_fragment(
    name = "TelegramLentaLoginEntitlements",
    extension = "entitlements",
    template = "".join(lenta_entitlements_head + [lenta_login_associated_domains_fragment] + lenta_entitlements_tail),
    defaults = {
        "lentaApplinksHost": "lenta.zenlygram.com",
    },
    tags = ["manual"],
)

# Zenlygram — the same APPLINKS_HOST in Info.plist, so SGFeedLinkRouter accepts universal links to the
# entitled domain before the account has a bootstrap. Only with --//Telegram:enableLenta (see the app's
# `infoplists` select).
plist_fragment(
    name = "LentaInfoPlist",
    extension = "plist",
    template =
    """
    <key>SGFeedApplinksHost</key>
    <string>{lentaApplinksHost}</string>
    """,
    defaults = {
        "lentaApplinksHost": "lenta.zenlygram.com",
    },
    tags = ["manual"],
)

# Zenlygram — the BotFather-issued app id of Lenta's Telegram Login client in Info.plist
# (SGFeedTelegramLoginAppId), so SGFeedTelegramLogin offers the fallback only when the binary carries
# the matching applinks:app{lentaTelegramLoginAppId}-login.tg.dev entitlement. Selected only with
# :enableLentaTelegramLoginSetting; no default, Make.py passes --define=lentaTelegramLoginAppId=.
plist_fragment(
    name = "LentaLoginInfoPlist",
    extension = "plist",
    template =
    """
    <key>SGFeedTelegramLoginAppId</key>
    <string>{lentaTelegramLoginAppId}</string>
    """,
    tags = ["manual"],
)

genrule(
    name = "VersionInfoPlist",
    srcs = ["//:versions.json"],
    outs = ["VersionInfoPlist.plist"],
    cmd = """
        version=$$(python3 -c "import json; print(json.load(open('$(location //:versions.json)'))['app'])")
        cat > $@ <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>$$version</string>
</dict>
</plist>
PLIST
    """,
)

plist_fragment(
    name = "RequiredDeviceCapabilitiesPlist",
    extension = "plist",
    template =
    """
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    """
)

plist_fragment(
    name = "AppNameInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleDisplayName</key>
    <string>Zenlygram</string>
    """
)

plist_fragment(
    name = "MtProtoKitInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.MtProtoKit</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>MtProtoKit</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

ios_framework(
    name = "MtProtoKitFramework",
    bundle_id = "{telegram_bundle_id}.MtProtoKit".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":MtProtoKitInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
    ],
    minimum_os_version = minimum_os_version,
    extension_safe = True,
    ipa_post_processor = strip_framework,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .framework root. App Store Connect checks each
    # embedded framework binary against its own bundle's manifest (ITMS-91053). One source file per
    # framework so rules_apple's short_path resource dedup never drops it. MtProtoKit: MTTime
    # mach_absolute_time (SystemBootTime).
    resources = ["ExtensionPrivacy/MtProtoKit/PrivacyInfo.xcprivacy"],
    deps = [
        "//submodules/MtProtoKit:MtProtoKit",
    ],
)

plist_fragment(
    name = "SwiftSignalKitInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.SwiftSignalKit</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>SwiftSignalKit</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

ios_framework(
    name = "SwiftSignalKitFramework",
    bundle_id = "{telegram_bundle_id}.SwiftSignalKit".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":SwiftSignalKitInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
    ],
    minimum_os_version = minimum_os_version,
    extension_safe = True,
    ipa_post_processor = strip_framework,
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

plist_fragment(
    name = "PostboxInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.Postbox</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Postbox</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

ios_framework(
    name = "PostboxFramework",
    bundle_id = "{telegram_bundle_id}.Postbox".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":PostboxInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
    ],
    frameworks = [
        ":SwiftSignalKitFramework",
    ],
    minimum_os_version = minimum_os_version,
    extension_safe = True,
    ipa_post_processor = strip_framework,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .framework root: MediaBox/cleanup stat/lstat,
    # SQLCipher statfs/fstatfs on the database files.
    resources = ["ExtensionPrivacy/Postbox/PrivacyInfo.xcprivacy"],
    deps = [
        "//submodules/Postbox:Postbox",
    ],
)

plist_fragment(
    name = "TelegramApiInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.TelegramApi</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>TelegramApi</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

plist_fragment(
    name = "TelegramCoreInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.TelegramCore</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>TelegramCore</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

ios_framework(
    name = "TelegramCoreFramework",
    bundle_id = "{telegram_bundle_id}.TelegramCore".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":TelegramCoreInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
    ],
    frameworks = [
        ":MtProtoKitFramework",
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
    ],
    minimum_os_version = minimum_os_version,
    extension_safe = True,
    ipa_post_processor = strip_framework,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .framework root: SGSimpleSettings standard and
    # app-group UserDefaults, log creationDate/stat, device free space for the Storage Usage screen.
    resources = ["ExtensionPrivacy/TelegramCore/PrivacyInfo.xcprivacy"],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ]
)

plist_fragment(
    name = "AsyncDisplayKitInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.AsyncDisplayKit</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>AsyncDisplayKit</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

plist_fragment(
    name = "DisplayInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.Display</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Display</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

genrule(
    name = "StripFramework",
    cmd_bash =
"""
    echo 'for f in $$1/*.framework; do binary_name=`echo $$(basename $$f) | sed -e "s/\\\\.framework//"`; strip -ST $$f/$$binary_name; done;' > $(location StripFramework.sh)
    # MARK: Swiftgram
    echo 'find "$$1" -type f \\( -perm +111 -o -name "*.dylib" \\) | while read -r bin; do \
        if otool -L "$$bin" | grep -q "/usr/lib/swift/libswift_Concurrency.dylib"; then \
            echo "Patching concurrency backport in: $$bin"; \
            chmod +w "$$(dirname $$bin)/"; \
            install_name_tool -change /usr/lib/swift/libswift_Concurrency.dylib @rpath/libswift_Concurrency.dylib "$$bin"; \
        fi; \
    done;' >> $(location StripFramework.sh)
    echo '' >> $(location StripFramework.sh)
""",
    outs = [
        "StripFramework.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)

genrule(
    name = "GenerateAddAlternateIcons",
    srcs = [
        "Telegram-iOS/AddAlternateIcons.sh",
    ],
    cmd_bash =
"""
    cat $(location Telegram-iOS/AddAlternateIcons.sh) >> $(location AddAlternateIcons.sh)
""",
    outs = [
        "AddAlternateIcons.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)

sh_binary(
    name = "AddAlternateIcons",
    data = [
        "Telegram-iOS/AlternateIcons.plist",
        "Telegram-iOS/AlternateIcons-iPad.plist",
    ],
    srcs = [":GenerateAddAlternateIcons"],
)

plist_fragment(
    name = "TelegramUIInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.TelegramUI</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>TelegramUI</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

ios_framework(
    name = "TelegramUIFramework",
    bundle_id = "{telegram_bundle_id}.TelegramUI".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":TelegramUIInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
    ],
    frameworks = [
        ":MtProtoKitFramework",
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
        ":TelegramCoreFramework",
    ],
    minimum_os_version = minimum_os_version,
    extension_safe = True,
    ipa_post_processor = strip_framework,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .framework root: UserDefaults (incl. app group),
    # activeInputModes, file timestamps (incl. document-picker files), low-disk check + Storage
    # Usage screen, mach_absolute_time.
    resources = ["ExtensionPrivacy/TelegramUI/PrivacyInfo.xcprivacy"],
    deps = [
        "//submodules/TelegramUI:TelegramUI",
    ] + debug_deps,
)

plist_fragment(
    name = "ShareInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.Share</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>IntentsSupported</key>
            <array>
                <string>INSendMessageIntent</string>
            </array>
            <key>NSExtensionActivationRule</key>
            <string>SUBQUERY (
    extensionItems,
    $extensionItem,
    SUBQUERY (
        $extensionItem.attachments,
        $attachment,
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.movie" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.text" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.audio" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.data" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.vcard" ||
        ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.apple.pkpass"
    ).@count == $extensionItem.attachments.@count
).@count &gt; 0</string>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.share-services</string>
        <key>NSExtensionPrincipalClass</key>
        <string>ShareRootController</string>
    </dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

swift_library(
    name = "ShareExtensionLib",
    module_name = "ShareExtensionLib",
    srcs = glob([
        "Share/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramUI",
        "//submodules/TelegramUI/Components/ShareExtensionContext"
    ],
)

ios_extension(
    name = "ShareExtension",
    bundle_id = "{telegram_bundle_id}.Share".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":ShareInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ShareExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Share.mobileprovision",
    }),
    deps = [":ShareExtensionLib"],
    frameworks = [
        ":TelegramUIFramework"
    ],
)

plist_fragment(
    name = "NotificationContentInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.NotificationContent</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>UNNotificationExtensionCategory</key>
            <array>
                <string>withReplyMedia</string>
                <string>withMuteMedia</string>
            </array>
            <key>UNNotificationExtensionInitialContentSizeRatio</key>
            <real>0.0001</real>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.usernotifications.content-extension</string>
        <key>NSExtensionPrincipalClass</key>
        <string>NotificationViewController</string>
    </dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

objc_library(
    name = "NotificationContentExtensionLink",
    srcs = [
        "NotificationContent/main.m",
    ],
    sdk_frameworks = [
        "UserNotificationsUI",
    ],
)

swift_library(
    name = "NotificationContentExtensionLib",
    module_name = "NotificationContentExtensionLib",
    srcs = glob([
        "NotificationContent/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramUI:TelegramUI",
        ":NotificationContentExtensionLink",
    ],
)

'''genrule(
    name = "SetMinOsVersionNotificationContentExtension",
    cmd_bash =
"""
    name=NotificationContentExtension.appex
    cat $(location PatchMinOSVersion.source.sh) | sed -e "s/<<<MIN_OS_VERSION>>>/10\\.0/g" | sed -e "s/<<<NAME>>>/$$name/g" > $(location SetMinOsVersionNotificationContentExtension.sh)
""",
    srcs = [
        "PatchMinOSVersion.source.sh",
    ],
    outs = [
        "SetMinOsVersionNotificationContentExtension.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)'''

ios_extension(
    name = "NotificationContentExtension",
    bundle_id = "{telegram_bundle_id}.NotificationContent".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":NotificationContentInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    #ipa_post_processor = ":SetMinOsVersionNotificationContentExtension",
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:NotificationContent.mobileprovision",
    }),
    deps = [":NotificationContentExtensionLib"],
    frameworks = [
        ":TelegramUIFramework"
    ],
)

plist_fragment(
    name = "WidgetInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.Widget</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

filegroup(
    name = "WidgetAssets",
    srcs = glob(["WidgetKitWidget/WidgetImages.xcassets/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "WidgetExtensionLib",
    module_name = "WidgetExtensionLib",
    srcs = glob([
        "WidgetKitWidget/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":WidgetAssets",
    ],
    deps = [
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/WidgetItems:WidgetItems_iOS14",
        "//submodules/WidgetItemsUtils:WidgetItemsUtils",
        "//submodules/AppLockState:AppLockState",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//Telegram:GeneratedSources",
        # Zenlygram — Secret Vault / Chat Lock state shared with the app (audit batch 3, #15).
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

genrule(
    name = "SetMinOsVersionWidgetExtension",
    cmd_bash =
"""
    name=WidgetExtension.appex
    cat $(location PatchMinOSVersion.source.sh) | sed -e "s/<<<MIN_OS_VERSION>>>/14\\.0/g" | sed -e "s/<<<NAME>>>/$$name/g" > $(location SetMinOsVersionWidgetExtension.sh)
""",
    srcs = [
        "PatchMinOSVersion.source.sh",
    ],
    outs = [
        "SetMinOsVersionWidgetExtension.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)

ios_extension(
    name = "WidgetExtension",
    bundle_id = "{telegram_bundle_id}.Widget".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":WidgetInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    ipa_post_processor = ":SetMinOsVersionWidgetExtension",
    #provides_main = True,
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Widget.mobileprovision",
    }),
    deps = [
        ":WidgetExtensionLib",
    ],
    frameworks = [
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
        ":TelegramCoreFramework",
    ],
    visibility = [
        "//visibility:public",
    ]
)

plist_fragment(
    name = "IntentsInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.SiriIntents</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>IntentsRestrictedWhileLocked</key>
            <array/>
            <key>IntentsRestrictedWhileProtectedDataUnavailable</key>
            <array/>
            <key>IntentsSupported</key>
            <array>
                <string>INSendMessageIntent</string>
                <string>INStartAudioCallIntent</string>
                <string>INSearchForMessagesIntent</string>
                <string>INSetMessageAttributeIntent</string>
                <string>INSearchCallHistoryIntent</string>
                <string>SelectFriendsIntent</string>
                <string>SelectAvatarFriendsIntent</string>
            </array>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.intents-service</string>
        <key>NSExtensionPrincipalClass</key>
        <string>IntentHandler</string>
    </dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

swift_intent_library(
    name = "GeneratedSources",
    src = "SiriIntents/en.lproj/Intents.intentdefinition",
    module_name = "GeneratedSources",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "IntentsAssets",
    srcs = glob(["SiriIntents/IntentsImages.xcassets/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "IntentsExtensionLib",
    module_name = "IntentsExtensionLib",
    srcs = glob([
        "SiriIntents/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = glob([
        "SiriIntents/*.lproj/Intents.intentdefinition"
    ]) + [
        ":IntentsAssets"
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//submodules/AppLockState:AppLockState",
        "//Telegram:GeneratedSources",
        "//submodules/WidgetItems:WidgetItems",
        # Zenlygram — Secret Vault / Chat Lock state shared with the app (audit batch 3, #15/#16, Siri).
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

'''genrule(
    name = "SetMinOsVersionIntentsExtension",
    cmd_bash =
"""
    name=IntentsExtension.appex
    cat $(location PatchMinOSVersion.source.sh) | sed -e "s/<<<MIN_OS_VERSION>>>/10\\.0/g" | sed -e "s/<<<NAME>>>/$$name/g" > $(location SetMinOsVersionIntentsExtension.sh)
""",
    srcs = [
        "PatchMinOSVersion.source.sh",
    ],
    outs = [
        "SetMinOsVersionIntentsExtension.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)'''

ios_extension(
    name = "IntentsExtension",
    bundle_id = "{telegram_bundle_id}.SiriIntents".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":IntentsInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    #ipa_post_processor = ":SetMinOsVersionIntentsExtension",
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Intents.mobileprovision",
    }),
    deps = [":IntentsExtensionLib"],
    frameworks = [
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
        ":TelegramCoreFramework",
    ],
)

# MARK: Swiftgram
# TODO(swiftgram): Localize CFBundleDisplayName
plist_fragment(
    name = "SGActionRequestHandlerInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.SGActionRequestHandler</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundleDisplayName</key>
    <string>Open in Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>NSExtensionActivationRule</key>
			<dict>
				<key>NSExtensionActivationSupportsFileWithMaxCount</key>
				<integer>0</integer>
				<key>NSExtensionActivationSupportsImageWithMaxCount</key>
				<integer>0</integer>
				<key>NSExtensionActivationSupportsMovieWithMaxCount</key>
				<integer>0</integer>
				<key>NSExtensionActivationSupportsText</key>
				<false/>
				<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
				<integer>1</integer>
			</dict>
			<key>NSExtensionJavaScriptPreprocessingFile</key>
			<string>Action</string>
			<key>NSExtensionServiceAllowsFinderPreviewItem</key>
			<true/>
			<key>NSExtensionServiceAllowsTouchBarItem</key>
			<true/>
			<key>NSExtensionServiceFinderPreviewIconName</key>
			<string>NSActionTemplate</string>
			<key>NSExtensionServiceTouchBarBezelColorName</key>
			<string>TouchBarBezel</string>
			<key>NSExtensionServiceTouchBarIconName</key>
			<string>NSActionTemplate</string>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.services</string>
		<key>NSExtensionPrincipalClass</key>
		<string>SGActionRequestHandler</string>
	</dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

# TODO(swiftgram): Proper icon
filegroup(
    name = "SGActionRequestHandlerAssets",
    srcs = glob(["SGActionRequestHandler/Media.xcassets/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "SGActionRequestHandlerScript",
    srcs = ["SGActionRequestHandler/Action.js"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGActionRequestHandlerLib",
    module_name = "SGActionRequestHandlerLib",
    srcs = glob([
        "SGActionRequestHandler/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SGActionRequestHandlerAssets",
        ":SGActionRequestHandlerScript"
    ],
    deps = [
        "//submodules/UrlEscaping:UrlEscaping"
    ],
)

genrule(
    name = "SetMinOsVersionSGActionRequestHandler",
    cmd_bash =
"""
    name=SGActionRequestHandler.appex
    cat $(location PatchMinOSVersion.source.sh) | sed -e "s/<<<MIN_OS_VERSION>>>/14\\.0/g" | sed -e "s/<<<NAME>>>/$$name/g" > $(location SetMinOsVersionSGActionRequestHandler.sh)
""",
    srcs = [
        "PatchMinOSVersion.source.sh",
    ],
    outs = [
        "SetMinOsVersionSGActionRequestHandler.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)

ios_extension(
    name = "SGActionRequestHandler",
    bundle_id = "{telegram_bundle_id}.SGActionRequestHandler".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":SGActionRequestHandlerInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        # ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    ipa_post_processor = ":SetMinOsVersionSGActionRequestHandler",
    #provides_main = True,
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:SGActionRequestHandler.mobileprovision",
    }),
    deps = [
        ":SGActionRequestHandlerLib",
    ],
    frameworks = [
    ],
    visibility = [
        "//visibility:public",
    ]
)
#

plist_fragment(
    name = "BroadcastUploadInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.BroadcastUpload</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>BroadcastUploadSampleHandler</string>
        <key>RPBroadcastProcessMode</key>
        <string>RPBroadcastProcessModeSampleBuffer</string>
    </dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

swift_library(
    name = "BroadcastUploadExtensionLib",
    module_name = "BroadcastUploadExtensionLib",
    srcs = glob([
        "BroadcastUpload/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramUI:TelegramUI",
        "//submodules/TelegramVoip:TelegramVoip",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/WidgetItems:WidgetItems",
        "//submodules/BroadcastUploadHelpers:BroadcastUploadHelpers",
    ],
)

'''genrule(
    name = "SetMinOsVersionBroadcastUploadExtension",
    cmd_bash =
"""
    name=BroadcastUploadExtension.appex
    cat $(location PatchMinOSVersion.source.sh) | sed -e "s/<<<MIN_OS_VERSION>>>/11\\.0/g" | sed -e "s/<<<NAME>>>/$$name/g" > $(location SetMinOsVersionBroadcastUploadExtension.sh)
""",
    srcs = [
        "PatchMinOSVersion.source.sh",
    ],
    outs = [
        "SetMinOsVersionBroadcastUploadExtension.sh",
    ],
    executable = True,
    visibility = [
        "//visibility:public",
    ]
)'''

ios_extension(
    name = "BroadcastUploadExtension",
    bundle_id = "{telegram_bundle_id}.BroadcastUpload".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":BroadcastUploadInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    #ipa_post_processor = ":SetMinOsVersionBroadcastUploadExtension",
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:BroadcastUpload.mobileprovision",
    }),
    deps = [":BroadcastUploadExtensionLib"],
    frameworks = [
        ":TelegramUIFramework",
        ":SwiftSignalKitFramework",
    ],
)

plist_fragment(
    name = "NotificationServiceInfoPlist",
    extension = "plist",
    template = 
    """
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}.NotificationService</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.usernotifications.service</string>
        <key>NSExtensionPrincipalClass</key>
        <string>NotificationService</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>IntentsSupported</key>
            <array>
                <string>INSendMessageIntent</string>
            </array>
        </dict>
    </dict>
    """.format(
        telegram_bundle_id = telegram_bundle_id
    )
)

ios_extension(
    name = "NotificationServiceExtension" + notificationServiceExtensionVersion,
    bundle_id = "{telegram_bundle_id}.NotificationService".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = [
        ":NotificationServiceInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":BuildNumberInfoPlist",
        ":AppNameInfoPlist",
    ],
    minimum_os_version = minimum_os_version, # maintain the same minimum OS version across extensions
    # MARK: Zenlygram — PrivacyInfo.xcprivacy at the .appex root
    resources = [":ExtensionPrivacyManifest"],
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:NotificationService.mobileprovision",
    }),
    deps = ["//Telegram/NotificationService:NotificationServiceExtensionLib"],
    frameworks = [
        ":MtProtoKitFramework",
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
        ":TelegramCoreFramework",
        ":TelegramUIFramework",
    ],
)

plist_fragment(
    name = "TelegramInfoPlist",
    extension = "plist",
    template = 
    """
    <key>BGTaskSchedulerPermittedIdentifiers</key>
    <array>
        <string>{telegram_bundle_id}.refresh</string>
        <string>{telegram_bundle_id}.cleanup</string>
        <string>{telegram_bundle_id}.upload.*</string>
    </array>
    <key>CFBundleAllowMixedLocalizations</key>
    <true/>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Zenlygram</string>
    <key>CFBundleIdentifier</key>
    <string>{telegram_bundle_id}</string>
    <key>CFBundleName</key>
    <string>Zenlygram</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>LSApplicationQueriesSchemes</key>
    <array>
        <string>instagram</string>
        <string>comgooglemaps-x-callback</string>
        <string>foursquare</string>
        <string>here-location</string>
        <string>yandexmaps</string>
        <string>yandexnavi</string>
        <string>yandextaxi</string>
        <string>yangoride</string>
        <string>comgooglemaps</string>
        <string>youtube</string>
        <string>twitter</string>
        <string>vk</string>
        <string>waze</string>
        <string>googlechrome</string>
        <string>firefox</string>
        <string>touch-http</string>
        <string>yandexbrowser-open-url</string>
        <string>vimeo</string>
        <string>vine</string>
        <string>coub</string>
        <string>uber</string>
        <string>citymapper</string>
        <string>lyft</string>
        <string>opera-http</string>
        <string>firefox-focus</string>
        <string>ddgQuickLink</string>
        <string>moovit</string>
        <string>alook</string>
        <string>dgis</string>
        <string>microsoft-edge-http</string>
        <string>brave</string>
        <string>onionhttp</string>
        <string>ucbrowser</string>
        <string>dolphin</string>
        <string>instagram-stories</string>
        <string>yangomaps</string>
        <string>vivaldi</string>
        <string>rizogo</string>
    </array>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSCameraUsageDescription</key>
    <string>We need this so that you can take and share photos and videos.</string>
    <key>NSContactsUsageDescription</key>
    <string>Zenlygram stores your contacts heavily encrypted in the Telegram cloud to let you connect with your friends across all your devices.</string>
    <key>NSFaceIDUsageDescription</key>
    <string>You can use Face ID to unlock the app.</string>
    <key>NSLocationAlwaysUsageDescription</key>
    <string>When you send your location to your friends, Zenlygram needs access to show them a map. You also need this to send locations from an Apple Watch.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>When you send your location to your friends, Zenlygram needs access to show them a map.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Zenlygram uses your microphone for calls, voice messages, videos with sound, and call recordings you choose to start.</string>
    <key>NSMotionUsageDescription</key>
    <string>When you send your location to your friends, Zenlygram needs access to show them a map.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>We need this so that you can share photos and videos from your photo library.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>We need this so that you can share photos and videos from your photo library.</string>
    <key>NSSiriUsageDescription</key>
    <string>You can use Siri to send messages.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>We need this to transcribe audio messages on your request.</string>
    <key>NSUserActivityTypes</key>
    <array>
        <string>INSendMessageIntent</string>
        <string>RemindAboutChatIntent</string>
    </array>
    <key>UIAppFonts</key>
    <array>
        <string>AremacFS-Regular.otf</string>
        <string>AremacFS-Semibold.otf</string>
    </array>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
        <string>fetch</string>
        <string>location</string>
        <string>remote-notification</string>
        <string>voip</string>
        <string>processing</string>
    </array>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UIFileSharingEnabled</key>
    <false/>
    <key>UILaunchStoryboardName</key>
    <string>LaunchScreen</string>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
        <key>UISceneConfigurations</key>
        <dict>
            <key>UIWindowSceneSessionRoleApplication</key>
            <array>
                <dict>
                    <key>UISceneConfigurationName</key>
                    <string>Zenlygram</string>
                    <key>UISceneDelegateClassName</key>
                    <string>ZenlygramSceneDelegate</string>
                </dict>
            </array>
        </dict>
    </dict>
    <key>UIRequiresPersistentWiFi</key>
    <true/>
    <key>UIStatusBarStyle</key>
    <string>UIStatusBarStyleDefault</string>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UIViewControllerBasedStatusBarAppearance</key>
    <true/>
    <key>UIViewEdgeAntialiasing</key>
    <false/>
    <key>UIViewGroupOpacity</key>
    <false/>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeDescription</key>
            <string>Telegram iOS Color Theme File</string>
            <key>UTTypeIconFiles</key>
            <array>
                <string>BlueIcon@3x.png</string>
            </array>
            <key>UTTypeIdentifier</key>
            <string>org.telegram.Telegram-iOS.theme</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>tgios-theme</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
    <key>UIApplicationSupportsIndirectInputEvents</key>
    <true/>
    """.format(
        telegram_bundle_id = telegram_bundle_id,
    )
)

local_provisioning_profile(
    name = "Telegram_local_profile",
    profile_name = "iOS Team Provisioning Profile: {}".format(telegram_bundle_id),
    team_id = telegram_team_id,
)

xcode_provisioning_profile(
   name = "Telegram_xcode_profile",
   managed_by_xcode = True,
   provisioning_profile = ":Telegram_local_profile",
)

apple_prebuilt_watchos_application(
    name = "SwiftgramWatchApp",
    # Watch bundle id tracks the host config ("<host>.watchkitapp"). The rule passes it
    # to xcodebuild as PRODUCT_BUNDLE_IDENTIFIER (baked + signed); the watch Info.plist
    # derives WKCompanionAppBundleIdentifier from it via $(PRODUCT_BUNDLE_IDENTIFIER:base),
    # so the embedded watch app is correct for any host (ph.telegra.Telegraph,
    # org.telegram.TelegramInternal, ...) with no post-build plist patching.
    bundle_id = "{telegram_bundle_id}.watchkitapp".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    tags = ["manual"],
)

ios_application(
    name = "Swiftgram",
    # Inner bundle/executable/primary-icon names must not carry the upstream "Swiftgram" product name
    # (audit #92, App Store 5.2.1). The target label and Swiftgram.ipa stay for Make.py.
    bundle_name = "Zenlygram",
    bundle_id = "{telegram_bundle_id}".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = ["iphone", "ipad"],
    minimum_os_version = minimum_os_version,
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": ":Telegram_xcode_profile" if telegram_use_xcode_managed_codesigning else "@build_configuration//provisioning:Telegram.mobileprovision",
    }),
    # Zenlygram — the Lenta entitlements only with --//Telegram:enableLenta (see TelegramLentaEntitlements);
    # :enableLentaTelegramLoginSetting specializes :enableLentaSetting (both flags), so Bazel picks it.
    entitlements = select({
        ":enableLentaTelegramLoginSetting": ":TelegramLentaLoginEntitlements.entitlements",
        ":enableLentaSetting": ":TelegramLentaEntitlements.entitlements",
        "//conditions:default": ":TelegramEntitlements.entitlements",
    }),
    infoplists = [
        ":TelegramInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":UrlTypesInfoPlist",
    ] + select({
        # Same specialization as the entitlements select: both flags → the login app id too.
        ":enableLentaTelegramLoginSetting": [":LentaInfoPlist", ":LentaLoginInfoPlist"],
        ":enableLentaSetting": [":LentaInfoPlist"],
        "//conditions:default": [],
    }),
    app_icons = [ ":{}_icon".format(name) for name in composer_icon_folders ],
    alternate_icons = [
        ":{}".format(name) for name in alternate_icon_folders
    ],
    resources = [
        ":LaunchScreen",
        ":PrivacyManifest",
        #":DefaultAppIcon",
    ],
    frameworks = [
        ":MtProtoKitFramework",
        ":SwiftSignalKitFramework",
        ":PostboxFramework",
        ":TelegramCoreFramework",
        ":TelegramUIFramework",
    ],
    strings = [
        ":AppStringResources",
    ],
    # MARK: Swiftgram
    settings_bundle = "//Swiftgram/SGSettingsBundle:SGSettingsBundle",
    extensions = select({
        ":disableExtensionsSetting": [],
        "//conditions:default": [
            # ":SGActionRequestHandler", # UX sucks https://t.me/swiftgramchat/7335
            ":ShareExtension",
            ":NotificationContentExtension",
            ":NotificationServiceExtension" + notificationServiceExtensionVersion,
            ":IntentsExtension",
            ":WidgetExtension",
            ":BroadcastUploadExtension",
        ],
    }),
    # Embed the in-repo tgwatch watch app (Telegram/WatchApp) under Watch/ only when
    # --//Telegram:embedWatchApp is set (Make.py sets it for device configs when
    # --embedWatchApp is passed). Off by default, so simulator/dev builds are unaffected.
    watch_application = select({
        ":embedWatchAppSetting": ":SwiftgramWatchApp",
        "//conditions:default": None,
    }),
    deps = [
        ":Main",
        ":Lib",
    ],
    visibility = ["//visibility:public"],
)

xcodeproj(
    name = "Telegram_xcodeproj",
    bazel_path = telegram_bazel_path,
    bazel_env = {"LANG": "en_US.UTF-8","PATH": "/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"}, # MARK: Swiftgram, otherwise Bazel through xcode does not see ccache
    project_name = "Swiftgram",
    tags = ["manual"],
    top_level_targets = [
        top_level_target(":Swiftgram", target_environments = ["device", "simulator"]),
        ":iOSAppUITestSuite",
    ],
    xcode_configurations = {
        "Debug": {
            "//command_line_option:compilation_mode": "dbg",
        },
        "Release": {
            "//command_line_option:compilation_mode": "opt",
        },
    },
    default_xcode_configuration = "Debug"
)

filegroup(
    name = "TestSources",
    srcs = glob(["Tests/Sources/**/*.swift"]),
)

ios_test_runner(
    name = "iPhone-17__26.2",
    device_type = "iPhone 17",
    os_version = "26.2",
)


swift_library(
    name = "iOSAppUITestSuite.library",
    testonly = True,
    srcs = [":TestSources"],
    module_name = "iOSAppUITestSuite",
    tags = ["manual"],
)

ios_ui_test_suite(
    name = "iOSAppUITestSuite",
    bundle_id = "org.telegram.Telegram-iOS-uitests",
    minimum_os_version = minimum_os_version,
    runners = [
        ":iPhone-17__26.2",
    ],
    tags = ["manual"],
    test_host = "//Telegram:Swiftgram", # MARK: Swiftgram
    visibility = ["@rules_xcodeproj//xcodeproj:generated"],
    deps = [":iOSAppUITestSuite.library"],
)

# Temporary targets used to simplify build tests

ios_application(
    name = "spm_build_app",
    bundle_id = "{telegram_bundle_id}".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = ["iphone", "ipad"],
    minimum_os_version = minimum_os_version,
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Telegram.mobileprovision",
    }),
    entitlements = ":TelegramEntitlements.entitlements",
    infoplists = [
        ":TelegramInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":UrlTypesInfoPlist",
    ],
    deps = [
        #"//submodules/Display",
        #"//submodules/TelegramCore",
        #"//submodules/FFMpegBinding",
        #"//third-party/webrtc",
        #"//third-party/webrtc:webrtc_objc",
        #"//submodules/AsyncDisplayKit",
        #"//submodules/ObjCRuntimeUtils",
        #"//submodules/OpusBinding",
        #"//third-party/boringssl:ssl",
        #"//third-party/boringssl:crypto",
        #"//submodules/TelegramVoip",
        #"//third-party/recaptcha:RecaptchaEnterprise",
        "//submodules/TelegramUI",
    ],
)

generate_spm(
    name = "spm_build_root",
    deps = [
        ":spm_build_app",
    ]
)

ios_application(
    name = "webrtc_build_test",
    bundle_id = "{telegram_bundle_id}".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = ["iphone", "ipad"],
    minimum_os_version = minimum_os_version,
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Telegram.mobileprovision",
    }),
    entitlements = ":TelegramEntitlements.entitlements",
    infoplists = [
        ":TelegramInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":UrlTypesInfoPlist",
    ],
    deps = [
        "//third-party/webrtc",
        "//third-party/webrtc:webrtc_objc",
    ],
)

ios_application(
    name = "libvpx_build_test",
    bundle_id = "{telegram_bundle_id}".format(
        telegram_bundle_id = telegram_bundle_id,
    ),
    families = ["iphone", "ipad"],
    minimum_os_version = minimum_os_version,
    provisioning_profile = select({
        ":disableProvisioningProfilesSetting": None,
        "//conditions:default": "@build_configuration//provisioning:Telegram.mobileprovision",
    }),
    entitlements = ":TelegramEntitlements.entitlements",
    infoplists = [
        ":TelegramInfoPlist",
        ":BuildNumberInfoPlist",
        ":VersionInfoPlist",
        ":RequiredDeviceCapabilitiesPlist",
        ":UrlTypesInfoPlist",
    ],
    deps = [
        "//third-party/libvpx:vpx",
    ],
)
