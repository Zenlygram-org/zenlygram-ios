#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-link-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

# The Tasks proof policy (SGLinkAccountProofPolicy) decides from the REAL entitlement failure
# mapping, so the entitlement's pure core is built first as module `SGEntitlement`, exactly the
# source list of SGEntitlement/Tests/run-policy-core-tests.sh (Foundation/CryptoKit/Security only:
# no SG_CONFIG, Keychain or UIKit). `SGEntitlementFailure.swift` needs `SGEntitlementMessage`
# (SGEntitlementState.swift), whose dependencies make that whole core the smallest proven set.
entitlement_root="$test_root/../../SGEntitlement/Sources"
target="$(uname -m)-apple-macos13.0"
xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGEntitlement \
    -module-cache-path "$test_temp/module-cache" \
    -emit-module -emit-module-path "$test_temp/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$test_temp/libSGEntitlement.a" \
    "$entitlement_root/SGEntitlementAPI.swift" \
    "$entitlement_root/SGEntitlementAccountGate.swift" \
    "$entitlement_root/SGEntitlementAccountClaimsLedger.swift" \
    "$entitlement_root/SGEntitlementAppleProvenance.swift" \
    "$entitlement_root/SGEntitlementBinding.swift" \
    "$entitlement_root/SGEntitlementBoundedFetch.swift" \
    "$entitlement_root/SGEntitlementCapability.swift" \
    "$entitlement_root/SGEntitlementClaims.swift" \
    "$entitlement_root/SGEntitlementCrypto.swift" \
    "$entitlement_root/SGEntitlementEnforcement.swift" \
    "$entitlement_root/SGEntitlementEvaluator.swift" \
    "$entitlement_root/SGEntitlementFailure.swift" \
    "$entitlement_root/SGEntitlementLocalGrace.swift" \
    "$entitlement_root/SGEntitlementPinnedKeys.swift" \
    "$entitlement_root/SGEntitlementPolicy.swift" \
    "$entitlement_root/SGEntitlementState.swift" \
    "$entitlement_root/SGEntitlementTokenVerifier.swift" \
    "$entitlement_root/SGTasksError.swift" \
    "$entitlement_root/SGTasksWire.swift" \
    "$entitlement_root/SGTasksWireCodec.swift" \
    "$entitlement_root/SGTasksWireJSON.swift" \
    "$entitlement_root/SGTasksWireOperation.swift"

# The link-screen lifecycle and its tests stay warnings-as-errors, importing that module.
xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_temp" -L "$test_temp" -lSGEntitlement \
    "$test_root/../Sources/SGLinkAccountLifecycle.swift" \
    "$test_root/LinkAccountLifecycleTests.swift" \
    -o "$test_temp/link-tests"
"$test_temp/link-tests"
