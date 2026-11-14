#!/bin/sh
# Zenlygram — runs the customer-data PURE core (design 40 §15.1: consent text + hash, the consent
# store, reconciliation, the wall policy, the gate, analytics, profile, planner, wire, policies and
# the coordinator reducer) and its XCTest cases on the macOS host, with no simulator, no Keychain,
# no App Group and no network. The Bazel `//Swiftgram/SGCustomerSync:SGCustomerSyncCoreTests`
# target runs the same files on the simulator.
#
# Every `Core/**/*.swift` is compiled as module `SGCustomerSyncCore` with testing enabled and
# warnings as errors (the BUILD target's copts), then every `Tests/**/*.swift` except `Tests/UI/**`
# is linked into an `.xctest` bundle run by `xcrun xctest`. The tests find their inputs through
# SG_CUSTOMER_FIXTURES (the vendored shared fixtures), SG_CUSTOMER_CONSENT_ROOT (the vendored
# consent tree) and SG_CUSTOMER_STRINGS_ROOT (the app's SGLocalizable tables).
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
module_root=$(CDPATH= cd -- "$test_root/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-customer-core-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

platform=$(xcrun --sdk macosx --show-sdk-platform-path)
developer_frameworks="$platform/Developer/Library/Frameworks"
developer_lib="$platform/Developer/usr/lib"
target="$(uname -m)-apple-macos13.0"
bundle="$work/SGCustomerSyncCoreTests.xctest"

# The file lists, one path per line (no word splitting on spaces, no globbing).
find "$module_root/Core" -type f -name '*.swift' | LC_ALL=C sort > "$work/core-sources"
find "$test_root" -type f -name '*.swift' ! -path "$test_root/UI/*" | LC_ALL=C sort > "$work/test-sources"
[ -s "$work/core-sources" ] || { echo "run-core-tests.sh: no Core sources" >&2; exit 1; }
[ -s "$work/test-sources" ] || { echo "run-core-tests.sh: no test sources" >&2; exit 1; }

old_ifs=$IFS
IFS='
'
set -f
set -- $(cat "$work/core-sources")
IFS=$old_ifs
set +f
xcrun --sdk macosx swiftc -target "$target" -parse-as-library -enable-testing -warnings-as-errors \
    -module-name SGCustomerSyncCore \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGCustomerSyncCore.swiftmodule" \
    -emit-library -static -o "$work/libSGCustomerSyncCore.a" \
    "$@"

mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SGCustomerSyncCoreTests</string>
    <key>CFBundleIdentifier</key>
    <string>org.zenlygram.SGCustomerSyncCoreTests</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST

IFS='
'
set -f
set -- $(cat "$work/test-sources")
IFS=$old_ifs
set +f
xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGCustomerSyncCoreTests \
    -module-cache-path "$work/module-cache" \
    -I "$work" -L "$work" -lSGCustomerSyncCore \
    -F "$developer_frameworks" -I "$developer_lib" -L "$developer_lib" \
    -framework XCTest \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker "$developer_frameworks" \
    -Xlinker -rpath -Xlinker "$developer_lib" \
    -o "$bundle/Contents/MacOS/SGCustomerSyncCoreTests" \
    "$@"

SG_CUSTOMER_FIXTURES="$test_root/Fixtures" \
SG_CUSTOMER_CONSENT_ROOT="$module_root/Resources/consent" \
SG_CUSTOMER_STRINGS_ROOT="$module_root/../SGStrings/Strings" \
    xcrun xctest "$bundle"
