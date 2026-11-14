#!/bin/sh
# Zenlygram — the authenticated backend origin (`SGEntitlementBackendOrigin`), the origin storage
# scope (`SGEntitlementStoreScope`) and the single Apple predicate
# (`SGEntitlementAppleBackendConfiguration`) on the macOS host: no simulator, no Keychain, no App
# Group, no network, no `SG_CONFIG`. The store/outbox isolation and the live-coordinator hold run only
# in the Bazel `//Swiftgram/SGEntitlement:SGEntitlementOriginTests` target.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources="$test_root/../Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-backend-origin-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

platform=$(xcrun --sdk macosx --show-sdk-platform-path)
developer_frameworks="$platform/Developer/Library/Frameworks"
developer_lib="$platform/Developer/usr/lib"
target="$(uname -m)-apple-macos13.0"
bundle="$work/SGEntitlementBackendOriginTests.xctest"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -enable-testing -warnings-as-errors \
    -module-name SGEntitlement \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$work/libSGEntitlement.a" \
    "$sources/SGEntitlementBackendOrigin.swift"

mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SGEntitlementBackendOriginTests</string>
    <key>CFBundleIdentifier</key>
    <string>org.zenlygram.SGEntitlementBackendOriginTests</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGEntitlementBackendOriginTests \
    -module-cache-path "$work/module-cache" \
    -I "$work" -L "$work" -lSGEntitlement \
    -F "$developer_frameworks" -I "$developer_lib" -L "$developer_lib" \
    -framework XCTest \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker "$developer_frameworks" \
    -Xlinker -rpath -Xlinker "$developer_lib" \
    -o "$bundle/Contents/MacOS/SGEntitlementBackendOriginTests" \
    "$test_root/SGEntitlementBackendOriginTests.swift"

xcrun xctest "$bundle"
