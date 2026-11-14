load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# telegram-login-ios (MIT, see LICENSE), vendored unmodified from
# https://github.com/TelegramMessenger/telegram-login-ios at commit
# 215851df7e3cd32787a0054e5d1a97d7aa62796e (the first commit with LICENSE).
# Used only by //Swiftgram/SGFeedUI (Lenta Telegram Login fallback), which is linked only with
# --//Telegram:enableLenta, so a flag-off binary does not contain it.
swift_library(
    name = "TelegramLogin",
    module_name = "TelegramLogin",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-suppress-warnings",
    ],
    deps = [
    ],
    visibility = [
        "//Swiftgram/SGFeedUI:__pkg__",
    ],
)
