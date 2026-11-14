#!/bin/sh
# Zenlygram — runs the entitlement's PURE core (token + policy verification, the policy state and
# order, the app-update policy with its version compare and decision, the evaluator under the
# monetization mode, the failure -> recovery mapping, the attach
# outbox entry's failure bookkeeping, the Tasks wire codec and error classification) and its XCTest
# cases on the macOS host, with no simulator, no Keychain, no App Group and no network. The Tasks transport, account gate and sponsor-proof tests run only in the Bazel
# `//Swiftgram/SGEntitlement:SGEntitlementTests` target; this is the fast route for the rest.
#
# The core is compiled as module `SGEntitlement` with testing enabled (the tests use
# `@testable import SGEntitlement`), then the tests are linked into an `.xctest` bundle run by
# `xcrun xctest`. Only Foundation / CryptoKit / Security sources belong in the list below: anything
# that reads `SG_CONFIG`, the Keychain or UIKit stays out.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources="$test_root/../Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-policy-core-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

platform=$(xcrun --sdk macosx --show-sdk-platform-path)
developer_frameworks="$platform/Developer/Library/Frameworks"
developer_lib="$platform/Developer/usr/lib"
target="$(uname -m)-apple-macos13.0"
bundle="$work/SGEntitlementPolicyCoreTests.xctest"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -enable-testing \
    -module-name SGEntitlement \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$work/libSGEntitlement.a" \
    "$sources/SGAppUpdatePolicy.swift" \
    "$sources/SGEntitlementAPI.swift" \
    "$sources/SGEntitlementAccountGate.swift" \
    "$sources/SGEntitlementAccountClaimsLedger.swift" \
    "$sources/SGEntitlementAppleProvenance.swift" \
    "$sources/SGEntitlementBackoff.swift" \
    "$sources/SGEntitlementBinding.swift" \
    "$sources/SGEntitlementBoundedFetch.swift" \
    "$sources/SGEntitlementCapability.swift" \
    "$sources/SGEntitlementClaims.swift" \
    "$sources/SGEntitlementCrypto.swift" \
    "$sources/SGEntitlementEnforcement.swift" \
    "$sources/SGEntitlementEvaluator.swift" \
    "$sources/SGEntitlementFailure.swift" \
    "$sources/SGEntitlementLocalGrace.swift" \
    "$sources/SGEntitlementOutboxEntry.swift" \
    "$sources/SGEntitlementPinnedKeys.swift" \
    "$sources/SGEntitlementPolicy.swift" \
    "$sources/SGEntitlementPolicyEndpoint.swift" \
    "$sources/SGEntitlementRetainedHistoryCapture.swift" \
    "$sources/SGEntitlementState.swift" \
    "$sources/SGEntitlementTokenVerifier.swift" \
    "$sources/SGTasksError.swift" \
    "$sources/SGTasksWire.swift" \
    "$sources/SGTasksWireCodec.swift" \
    "$sources/SGTasksWireJSON.swift" \
    "$sources/SGTasksWireOperation.swift"

mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SGEntitlementPolicyCoreTests</string>
    <key>CFBundleIdentifier</key>
    <string>org.zenlygram.SGEntitlementPolicyCoreTests</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGEntitlementPolicyCoreTests \
    -module-cache-path "$work/module-cache" \
    -I "$work" -L "$work" -lSGEntitlement \
    -F "$developer_frameworks" -I "$developer_lib" -L "$developer_lib" \
    -framework XCTest \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker "$developer_frameworks" \
    -Xlinker -rpath -Xlinker "$developer_lib" \
    -o "$bundle/Contents/MacOS/SGEntitlementPolicyCoreTests" \
    "$test_root/SGEntitlementTestSupport.swift" \
    "$test_root/SGEntitlementTokenVerifierTests.swift" \
    "$test_root/SGEntitlementPolicyTests.swift" \
    "$test_root/SGAppUpdatePolicyTests.swift" \
    "$test_root/SGEntitlementMonetizationEvaluatorTests.swift" \
    "$test_root/SGEntitlementFailureMappingTests.swift" \
    "$test_root/SGEntitlementOutboxEntryTests.swift" \
    "$test_root/SGEntitlementRetainedHistoryCaptureTests.swift" \
    "$test_root/SGEntitlementPolicyStubProtocol.swift" \
    "$test_root/SGEntitlementBoundedFetchTests.swift" \
    "$test_root/SGEntitlementPolicyEndpointTests.swift" \
    "$test_root/SGEntitlementAccountClaimsLedgerTests.swift" \
    "$test_root/SGTasksWireTests.swift"

xcrun xctest "$bundle"
