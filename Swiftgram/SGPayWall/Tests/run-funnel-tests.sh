#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-funnel-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

# The funnel maps the REAL `SGIAP` outcomes onto the REAL analytics taxonomy, so three modules are
# built first, exactly as the app links them: the entitlement's pure core as `SGEntitlement` (the
# source list of run-link-lifecycle-tests.sh), `SGIAPTypes.swift` as `SGIAP` (the outcome and message
# types; Foundation + SGEntitlement only) and every `SGCustomerSync/Core` file as `SGCustomerSyncCore`.
entitlement_root="$test_root/../../SGEntitlement/Sources"
iap_root="$test_root/../../SGIAP/Sources"
core_root="$test_root/../../SGCustomerSync/Core"
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

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGIAP \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_temp" \
    -emit-module -emit-module-path "$test_temp/SGIAP.swiftmodule" \
    -emit-library -static -o "$test_temp/libSGIAP.a" \
    "$iap_root/SGIAPTypes.swift"

# The core's file list, one path per line (no word splitting on spaces, no globbing).
find "$core_root" -type f -name '*.swift' | LC_ALL=C sort > "$test_temp/core-sources"
[ -s "$test_temp/core-sources" ] || { echo "run-funnel-tests.sh: no SGCustomerSync Core sources" >&2; exit 1; }
old_ifs=$IFS
IFS='
'
set -f
set -- $(cat "$test_temp/core-sources")
IFS=$old_ifs
set +f
xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGCustomerSyncCore \
    -module-cache-path "$test_temp/module-cache" \
    -emit-module -emit-module-path "$test_temp/SGCustomerSyncCore.swiftmodule" \
    -emit-library -static -o "$test_temp/libSGCustomerSyncCore.a" \
    "$@"

# The funnel and its tests stay warnings-as-errors (the BUILD target's copts).
xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_temp" -L "$test_temp" -lSGEntitlement -lSGIAP -lSGCustomerSyncCore \
    "$test_root/../Sources/SGPayWallFunnel.swift" \
    "$test_root/FunnelRulesTests.swift" \
    -o "$test_temp/funnel-tests"
"$test_temp/funnel-tests"
