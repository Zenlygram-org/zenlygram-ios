#!/bin/sh
# Zenlygram — Lenta build-boundary check (spec 19 "Tekshiruv", "Postbox qoidasi", "Uchinchi tomon SDK").
#
# Usage:
#   scripts/lenta-boundary-check.sh [options]                          # source checks only
#   scripts/lenta-boundary-check.sh [options] <flag-off .app|.ipa>     # + flag-off candidate checks
#   scripts/lenta-boundary-check.sh [options] --flag-on <.app|.ipa>    # + flag-on candidate check
#
# Options:
#   --repo DIR                       repository root to scan (default: this script's repository)
#   --configuration FILE             build configuration JSON given to Make.py; reads the optional
#                                    "lenta_applinks_host" and "lenta_telegram_login_app_id"
#   --applinks-host HOST             Lenta APPLINKS_HOST (default lenta.zenlygram.com; overrides the JSON)
#   --telegram-login-app-id ID       app id of applinks:app<ID>-login.tg.dev (overrides the JSON); without
#                                    one, a flag-on candidate must not carry that entitlement
#   --appattest-environment ENV      expected App Attest environment of a flag-on candidate
#                                    (production, the default, or development)
#   --baseline <flag-off .app|.ipa>  with --flag-on: the candidate's whole entitlement set must equal the
#                                    baseline's plus the disclosed Lenta list, nothing else
#
# Source checks (every mode):
#   1. No `import Postbox` in any Swift file under Swiftgram/SGFeed*/.
#   2. No Postbox in Swiftgram/SGFeed*/BUILD(.bazel): no quoted label/string with a `Postbox` component
#      (e.g. //submodules/Postbox:Postbox). Comments are ignored.
#   3. No analytics, ads or tracker SDK in Lenta: no SGFeed* BUILD string naming one (deps,
#      sdk_frameworks, linkopts, external @repo names) and no Swift/Objective-C import of one under
#      Swiftgram/SGFeed*/ (TRACKER_MODULES / TRACKER_REPOS below). Only direct deps and imports are
#      scanned; what the rest of the app links is outside Lenta's boundary.
# Flag-off candidate (built without --//Telegram:enableLenta):
#   4. No `SGFeed`, `Lenta`, `lenta`, `LENTA_PUSH_` (the push alert keys of //Telegram:LentaLocalizableStrings)
#      or the applinks host (case-sensitive) in any Mach-O binary (strings/nm), plist or .strings file of the bundle.
#   5. No Lenta entitlement in the main binary's signed entitlements (codesign signature and, for
#      simulator builds, the embedded __TEXT,__entitlements section): no key of LENTA_ENTITLEMENTS, no
#      associated domain on the applinks host, on a *lenta* host or on app<id>-login.tg.dev, no value
#      containing Lenta/lenta/SGFeed. The embedded provisioning profile is only reported (it lists what
#      the App ID allows, not what the binary is signed with).
# Flag-on candidate (built with --//Telegram:enableLenta):
#   6. The Lenta entitlements of the main binary (same extraction and classification as 5) equal
#      LENTA_ENTITLEMENTS exactly: nothing missing, nothing extra. With --baseline, also every other
#      entitlement must be one the flag-off baseline has, and none of the baseline's may be missing.
#
# Exit status 0 = PASS, 1 = FAIL, 2 = usage error. Needs Xcode command line tools and python3 (macOS).
# Self-test with one failing fixture per check: scripts/lenta-boundary-selftest.sh.
set -eu

# The disclosed Lenta entitlement list (main.txt:27108, 27149) — the same entries
# //Telegram:TelegramLentaEntitlements / :TelegramLentaLoginEntitlements declare. One `key=value` per
# line; arrays give one line per element, booleans `true`. {host}, {telegram_login_app_id} and
# {appattest_environment} are filled in from the options; the {telegram_login_app_id} line applies only
# when an app id is configured.
LENTA_ENTITLEMENTS='com.apple.developer.associated-domains=applinks:{host}
com.apple.developer.associated-domains=webcredentials:{host}
com.apple.developer.associated-domains=applinks:app{telegram_login_app_id}-login.tg.dev
com.apple.developer.devicecheck.appattest-environment={appattest_environment}
com.apple.developer.declared-age-range=true
com.apple.developer.sensitivecontentanalysis.client=analysis'

# Analytics, ads and tracker SDK modules (kiberxavfsizlik.txt:2745, main.txt:30295): matched exactly
# against Swift/ObjC module names and against each `/`- or `:`-separated component of BUILD strings.
# `X([A-Z][A-Za-z0-9]*)?` takes a vendor's module family without catching e.g. SegmentedControlNode.
TRACKER_MODULES='Firebase[A-Za-z0-9]*|GoogleMobileAds|GoogleAnalytics|GoogleAppMeasurement[A-Za-z0-9]*|GoogleTagManager|FBSDK[A-Za-z0-9]*|FBAudienceNetwork|FBAEMKit|Facebook([A-Z][A-Za-z0-9]*)?|AppsFlyer[A-Za-z0-9]*|Adjust([A-Z][A-Za-z0-9]*)?|Amplitude([A-Z][A-Za-z0-9]*)?|Mixpanel([A-Z][A-Za-z0-9]*)?|Segment([A-Z][A-Za-z0-9]*)?|Sentry([A-Z][A-Za-z0-9]*)?|Crashlytics|Fabric|AppCenter([A-Z][A-Za-z0-9]*)?|Branch|BranchSDK|Flurry[A-Za-z0-9]*|YandexMobileMetrica[A-Za-z0-9]*|YandexMobileAds[A-Za-z0-9]*|AppMetrica[A-Za-z0-9]*|OneSignal[A-Za-z0-9]*|Bugsnag[A-Za-z0-9]*|Datadog[A-Za-z0-9]*|NewRelic[A-Za-z0-9]*|Instabug[A-Za-z0-9]*|PostHog|Countly|Braze[A-Za-z0-9]*|Appboy[A-Za-z0-9]*|CleverTap[A-Za-z0-9]*|Kochava[A-Za-z0-9]*|Singular|TikTokBusinessSDK|AppLovinSDK|UnityAds|IronSource[A-Za-z0-9]*|AdSupport|AppTrackingTransparency|AdServices|AdAttributionKit'
# External Bazel repositories of the same vendors (`@firebase_ios_sdk//...`), case-insensitive.
TRACKER_REPOS='^@(firebase|google_?mobile_?ads|google_?analytics|facebook|fbsdk|appsflyer|adjust|amplitude|mixpanel|segment|sentry|crashlytics|fabric|appcenter|branch|flurry|yandex|appmetrica|onesignal|bugsnag|datadog|newrelic|instabug|posthog|countly|braze|appboy|clevertap|kochava|singular|applovin|unity_?ads|ironsource)'

usage() {
    sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=source
candidate=""
baseline=""
configuration=""
applinks_host=""
telegram_login_app_id=""
appattest_environment=production
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
        --flag-on) [ $# -ge 2 ] && [ -z "$candidate" ] || usage; mode=flag-on; candidate=$2; shift 2 ;;
        --baseline) [ $# -ge 2 ] || usage; baseline=$2; shift 2 ;;
        --configuration) [ $# -ge 2 ] || usage; configuration=$2; shift 2 ;;
        --applinks-host) [ $# -ge 2 ] || usage; applinks_host=$2; shift 2 ;;
        --telegram-login-app-id) [ $# -ge 2 ] || usage; telegram_login_app_id=$2; shift 2 ;;
        --appattest-environment) [ $# -ge 2 ] || usage; appattest_environment=$2; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [ -z "$candidate" ] || usage; mode=flag-off; candidate=$1; shift ;;
    esac
done
[ -d "$repo/Swiftgram" ] || { echo "not a repository root (no Swiftgram/): $repo" >&2; exit 2; }
[ -z "$baseline" ] || [ "$mode" = flag-on ] || { echo "--baseline needs --flag-on" >&2; exit 2; }
case "$appattest_environment" in
    production|development) ;;
    *) echo "--appattest-environment must be production or development" >&2; exit 2 ;;
esac
if [ -n "$configuration" ]; then
    [ -f "$configuration" ] || { echo "no such configuration: $configuration" >&2; exit 2; }
    if [ -z "$applinks_host" ]; then
        applinks_host=$(plutil -extract lenta_applinks_host raw -o - "$configuration" 2>/dev/null || true)
    fi
    if [ -z "$telegram_login_app_id" ]; then
        telegram_login_app_id=$(plutil -extract lenta_telegram_login_app_id raw -o - "$configuration" 2>/dev/null || true)
    fi
fi
[ -n "$applinks_host" ] || applinks_host=lenta.zenlygram.com
if ! printf '%s' "$applinks_host" | grep -qxE '[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+'; then
    echo "applinks host must be a lowercase host name: $applinks_host" >&2
    exit 2
fi
if [ -n "$telegram_login_app_id" ] && ! printf '%s' "$telegram_login_app_id" | grep -qxE '[1-9][0-9]{0,19}'; then
    echo "Telegram Login app id must be a positive decimal number: $telegram_login_app_id" >&2
    exit 2
fi

failed=0
fail() {
    echo "FAIL: $*"
    failed=1
}

finish() {
    if [ $failed -eq 0 ]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
    exit $failed
}

# Prints `FILE: "string"` for each quoted string outside comments in the given BUILD files that has a
# `/`- or `:`-separated component fully matching $1 (ERE), or that matches $2 (ERE, lower-cased; may be empty).
scan_build_strings() {
    component_re=$1
    whole_re=$2
    shift 2
    [ $# -gt 0 ] || return 0
    awk -v component_re="^($component_re)\$" -v whole_re="$whole_re" '
        function check(s,    n, parts, i) {
            n = split(s, parts, /[\/:]/)
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ component_re) { print FILENAME ": \"" s "\""; return }
            }
            if (whole_re != "" && tolower(s) ~ whole_re) print FILENAME ": \"" s "\""
        }
        {
            line = $0; in_string = 0; quote = ""; value = ""
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (!in_string) {
                    if (c == "#") break
                    if (c == "\"" || c == "\047") { in_string = 1; quote = c; value = "" }
                } else if (c == "\\") {
                    value = value substr(line, i, 2); i++
                } else if (c == quote) {
                    in_string = 0; check(value)
                } else {
                    value = value c
                }
            }
        }' "$@"
}

module_dirs=$(find "$repo/Swiftgram" -mindepth 1 -maxdepth 1 -type d -name 'SGFeed*' | sort)
build_files=""
swift_files=""
objc_files=""
if [ -n "$module_dirs" ]; then
    # Module directory names contain no whitespace (Bazel package names).
    # shellcheck disable=SC2086
    build_files=$(find $module_dirs -type f \( -name BUILD -o -name BUILD.bazel \) | sort)
    # shellcheck disable=SC2086
    swift_files=$(find $module_dirs -type f -name '*.swift' | sort)
    # shellcheck disable=SC2086
    objc_files=$(find $module_dirs -type f \( -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.cpp' \) | sort)
fi
swift_import='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(class |struct |enum |protocol |func |var |let |typealias )?'

report() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1" | while IFS= read -r hit; do
            echo "FAIL: $2: ${hit#"$repo"/}"
        done
        failed=1
    else
        echo "ok"
    fi
}

echo "== source: no Postbox import in Swiftgram/SGFeed*/**/*.swift"
# shellcheck disable=SC2086
hits=$( [ -z "$swift_files" ] || grep -nE "${swift_import}Postbox([[:space:].]|\$)" $swift_files || true)
report "$hits" "imports Postbox"

echo "== source: no Postbox dep in Swiftgram/SGFeed*/BUILD"
# shellcheck disable=SC2086
hits=$(scan_build_strings 'Postbox' '' $build_files)
report "$hits" "Postbox in BUILD"

echo "== source: no analytics/ads/tracker SDK dep in Swiftgram/SGFeed*/BUILD"
# shellcheck disable=SC2086
hits=$(scan_build_strings "$TRACKER_MODULES" "$TRACKER_REPOS" $build_files)
report "$hits" "tracker SDK in BUILD"

echo "== source: no analytics/ads/tracker SDK import in Swiftgram/SGFeed*/"
# shellcheck disable=SC2086
hits=$( { [ -z "$swift_files" ] || grep -nE "${swift_import}(${TRACKER_MODULES})([[:space:].]|\$)" $swift_files || true; } ; \
    { [ -z "$objc_files" ] || grep -nE "^[[:space:]]*(#[[:space:]]*(import|include)[[:space:]]*[<\"](${TRACKER_MODULES})/|@import[[:space:]]+(${TRACKER_MODULES})([[:space:].;]|\$))" $objc_files || true; } )
report "$hits" "imports a tracker SDK"

if [ "$mode" = source ]; then
    finish
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lenta-boundary.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Prints the .app directory of an .app or .ipa argument (an .ipa is unpacked into $work/$2).
resolve_app() {
    case "$1" in
        *.ipa)
            [ -f "$1" ] || return 0
            unzip -q "$1" -d "$work/$2"
            find "$work/$2/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1
            ;;
        *)
            printf '%s\n' "${1%/}"
            ;;
    esac
}

# Writes the main binary's signed entitlements (codesign signature + embedded __TEXT,__entitlements
# section) as normalized `key=value` lines to $2; prints the executable name. Returns 1 if unreadable.
signed_entitlements() {
    app_dir=$1
    out=$2
    mkdir -p "$out.d"
    exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_dir/Info.plist" 2>/dev/null) || return 1
    bin="$app_dir/$exe"
    [ -f "$bin" ] || return 1
    codesign -d --entitlements - --xml "$bin" > "$out.d/codesign.xml" 2>/dev/null || : > "$out.d/codesign.xml"
    : > "$out.d/embedded.xml"
    if otool -l "$bin" | grep -q 'sectname __entitlements'; then
        segedit "$bin" -extract __TEXT __entitlements "$out.d/embedded.xml" 2>/dev/null || : > "$out.d/embedded.xml"
    fi
    normalize_plists "$out.d/codesign.xml" "$out.d/embedded.xml" > "$out.d/lines" || return 1
    sort -u "$out.d/lines" > "$out"
    printf '%s\n' "$exe"
}

# Prints each plist file's top-level entries as `key=value` lines (one per array element, booleans
# true/false, nested dictionaries as key.subkey). Empty files are skipped; leading signature bytes
# before the XML are ignored.
normalize_plists() {
    python3 - "$@" <<'PY'
import plistlib
import sys

def emit(key, value):
    if isinstance(value, dict):
        for sub in sorted(value):
            emit(key + "." + sub, value[sub])
    elif isinstance(value, (list, tuple)):
        for item in value:
            emit(key, item)
    elif isinstance(value, bool):
        print("%s=%s" % (key, "true" if value else "false"))
    elif isinstance(value, bytes):
        print("%s=<data:%s>" % (key, value.hex()))
    else:
        print("%s=%s" % (key, value))

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.strip():
        continue
    start = data.find(b"bplist00")
    if start < 0:
        start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"<plist")
    if start < 0:
        sys.exit("not a property list: %s" % path)
    blob = data[start:]
    end = blob.find(b"</plist>")
    if not blob.startswith(b"bplist00") and end >= 0:
        blob = blob[:end + len(b"</plist>")]
    root = plistlib.loads(blob)
    if not isinstance(root, dict):
        sys.exit("not a dictionary: %s" % path)
    for key in sorted(root):
        emit(key, root[key])
PY
}

expected_list=$(printf '%s\n' "$LENTA_ENTITLEMENTS" \
    | { if [ -n "$telegram_login_app_id" ]; then cat; else grep -vF '{telegram_login_app_id}'; fi; } \
    | sed -e "s|{host}|$applinks_host|g" -e "s|{telegram_login_app_id}|$telegram_login_app_id|g" \
        -e "s|{appattest_environment}|$appattest_environment|g" \
    | sort -u)
lenta_keys=$(printf '%s\n' "$LENTA_ENTITLEMENTS" | sed 's/=.*//' | grep -vx 'com.apple.developer.associated-domains' | sort -u | tr '\n' ' ')

# Filters normalized entitlement lines down to the Lenta ones (see check 5).
lenta_entitlements() {
    awk -v host="$applinks_host" -v keys="$lenta_keys" '
        BEGIN { n = split(keys, list, " "); for (i = 1; i <= n; i++) lenta_key[list[i]] = 1 }
        {
            eq = index($0, "="); key = substr($0, 1, eq - 1); value = substr($0, eq + 1)
            if (key in lenta_key || $0 ~ /SGFeed|Lenta|lenta/) { print; next }
            if (key == "com.apple.developer.associated-domains") {
                domain = value; sub(/^[a-z]+:/, "", domain); sub(/\?.*$/, "", domain)
                if (domain == host || domain ~ /^app[0-9]+-login\.tg\.dev$/) print
            }
        }' "$1"
}

if [ -z "$candidate" ]; then
    usage
fi
app=$(resolve_app "$candidate" candidate)
if [ -z "$app" ] || [ ! -f "$app/Info.plist" ]; then
    echo "not an .app bundle: $candidate" >&2
    exit 2
fi

if [ "$mode" = flag-off ]; then
    pattern="SGFeed|Lenta|lenta|LENTA_PUSH_|$(printf '%s' "$applinks_host" | sed 's/\./\\./g')"
    echo "== artifact: no '$pattern' in binaries, plists, .strings of $(basename "$app")"
    hits="$work/hits"
    : > "$hits"
    find "$app" -type f | while IFS= read -r file; do
        rel=${file#"$app"/}
        case "$file" in
            *.plist|*.strings|*.stringsdict)
                text=$(plutil -convert xml1 -o - "$file" 2>/dev/null || LC_ALL=C cat "$file")
                matches=$(printf '%s' "$text" | LC_ALL=C grep -aoE "[^<>\"[:space:]]{0,24}($pattern)[^<>\"[:space:]]{0,24}" | sort -u | head -n 5 || true)
                ;;
            *)
                if ! file -b "$file" | grep -q 'Mach-O'; then
                    continue
                fi
                matches=$({ strings -a "$file"; nm -a "$file" 2>/dev/null; } | LC_ALL=C grep -oE "[^[:space:]]{0,24}($pattern)[^[:space:]]{0,24}" | sort -u | head -n 5 || true)
                ;;
        esac
        if [ -n "$matches" ]; then
            printf '%s: %s\n' "$rel" "$(printf '%s' "$matches" | tr '\n' ' ')" >> "$hits"
        fi
    done
    if [ -s "$hits" ]; then
        failed=1
        count=$(wc -l < "$hits" | tr -d ' ')
        head -n 40 "$hits" | sed 's/^/FAIL: /'
        if [ "$count" -gt 40 ]; then
            echo "... $count files in total"
        fi
    else
        echo "ok"
    fi

    echo "== artifact: no Lenta entitlements in the main binary"
    if ! executable=$(signed_entitlements "$app" "$work/entitlements"); then
        fail "cannot read the main binary's entitlements in $(basename "$app")"
        finish
    fi
    keys=$(lenta_entitlements "$work/entitlements")
    if [ -n "$keys" ]; then
        printf '%s\n' "$keys" | while IFS= read -r key; do
            echo "FAIL: Lenta entitlement in $executable: $key"
        done
        failed=1
    else
        echo "ok"
    fi
    if [ -f "$app/embedded.mobileprovision" ]; then
        security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null \
            | plutil -extract Entitlements xml1 -o "$work/profile.xml" - 2>/dev/null || : > "$work/profile.xml"
        normalize_plists "$work/profile.xml" > "$work/profile" 2>/dev/null || : > "$work/profile"
        lenta_entitlements "$work/profile" | sed 's/^/note: the provisioning profile allows (not signed): /'
    fi
    finish
fi

echo "== artifact: flag-on entitlements of $(basename "$app") equal the disclosed Lenta list"
printf '%s\n' "$expected_list" | sed 's/^/   disclosed: /'
if ! executable=$(signed_entitlements "$app" "$work/entitlements") || [ ! -s "$work/entitlements" ]; then
    fail "cannot read the main binary's entitlements in $(basename "$app")"
    finish
fi
printf '%s\n' "$expected_list" > "$work/expected"
lenta_entitlements "$work/entitlements" | sort -u > "$work/actual"
missing=$(comm -23 "$work/expected" "$work/actual")
extra=$(comm -13 "$work/expected" "$work/actual")
[ -z "$missing" ] || printf '%s\n' "$missing" | sed "s/^/FAIL: missing disclosed Lenta entitlement in $executable: /"
[ -z "$extra" ] || printf '%s\n' "$extra" | sed "s/^/FAIL: undisclosed Lenta entitlement in $executable: /"
if [ -n "$missing$extra" ]; then
    failed=1
else
    echo "ok"
fi

if [ -n "$baseline" ]; then
    echo "== artifact: flag-on entitlements = flag-off baseline + disclosed Lenta list"
    base_app=$(resolve_app "$baseline" baseline)
    if [ -z "$base_app" ] || [ ! -f "$base_app/Info.plist" ]; then
        echo "not an .app bundle: $baseline" >&2
        exit 2
    fi
    if ! signed_entitlements "$base_app" "$work/baseline" > /dev/null || [ ! -s "$work/baseline" ]; then
        fail "cannot read the baseline's entitlements in $(basename "$base_app")"
        finish
    fi
    sort -u "$work/baseline" "$work/expected" > "$work/allowed"
    missing=$(comm -23 "$work/allowed" "$work/entitlements")
    extra=$(comm -13 "$work/allowed" "$work/entitlements")
    [ -z "$missing" ] || printf '%s\n' "$missing" | sed "s/^/FAIL: missing entitlement in $executable: /"
    [ -z "$extra" ] || printf '%s\n' "$extra" | sed "s/^/FAIL: entitlement in $executable is neither in the baseline nor disclosed: /"
    if [ -n "$missing$extra" ]; then
        failed=1
    else
        echo "ok"
    fi
fi
finish
