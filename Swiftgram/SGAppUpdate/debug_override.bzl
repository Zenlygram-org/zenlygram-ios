load("@build_configuration//:variables.bzl", "telegram_is_appstore_build")

# Zenlygram — the QA override of the app-update decision (update_policy_spec §4h) exists in NON-STORE
# builds only, at compile time: `SGAppUpdateDebugOverride`, the presenter's read of it
# (`SGAppUpdate.debugOverrideDidChange`) and the Debug Settings row are compiled under this define,
# and an App Store build (`is_appstore_build` true in the build configuration — the same value
# `BuildConfig.isAppStoreBuild` / `GlobalExperimentalSettings.isAppStoreBuild` carry at run time)
# has none of them. The runtime guard (`resolve(raw:isAppStoreBuild:)`) stays as the belt. The
# defaults key itself (`SGSimpleSettings.appUpdateDebugOverride`) is a plain setting that remains
# declared in every build and is read by nothing in a store build.
SG_APP_UPDATE_DEBUG_OVERRIDE_COPTS = [] if telegram_is_appstore_build == "true" else ["-DSG_APP_UPDATE_DEBUG_OVERRIDE"]
