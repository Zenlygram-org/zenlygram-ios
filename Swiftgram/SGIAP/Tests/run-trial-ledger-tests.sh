#!/bin/sh
# Zenlygram — the trial ledger's origin scope on the macOS host. The pure SGEntitlement core (the
# Foundation/CryptoKit/Security sources, including the backend origin and store scope) is built as
# module `SGEntitlement`, so `SGIAPTrialLedger.swift` compiles against its PUBLIC API exactly as in
# the app. `-D SGIAP_HOST_TESTS` leaves out only the shipped instance (`SG_CONFIG`, the app group).
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
entitlement="$test_root/../../SGEntitlement/Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-trial-ledger-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
target="$(uname -m)-apple-macos13.0"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-name SGEntitlement \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$work/libSGEntitlement.a" \
    "$entitlement/SGEntitlementAPI.swift" \
    "$entitlement/SGEntitlementAccountGate.swift" \
    "$entitlement/SGEntitlementAccountClaimsLedger.swift" \
    "$entitlement/SGEntitlementAppleProvenance.swift" \
    "$entitlement/SGEntitlementBackendOrigin.swift" \
    "$entitlement/SGEntitlementBinding.swift" \
    "$entitlement/SGEntitlementBoundedFetch.swift" \
    "$entitlement/SGEntitlementCapability.swift" \
    "$entitlement/SGEntitlementClaims.swift" \
    "$entitlement/SGEntitlementCrypto.swift" \
    "$entitlement/SGEntitlementEnforcement.swift" \
    "$entitlement/SGEntitlementEvaluator.swift" \
    "$entitlement/SGEntitlementFailure.swift" \
    "$entitlement/SGEntitlementLocalGrace.swift" \
    "$entitlement/SGEntitlementPinnedKeys.swift" \
    "$entitlement/SGEntitlementPolicy.swift" \
    "$entitlement/SGEntitlementPolicyEndpoint.swift" \
    "$entitlement/SGEntitlementRetainedHistoryCapture.swift" \
    "$entitlement/SGEntitlementState.swift" \
    "$entitlement/SGEntitlementTokenVerifier.swift" \
    "$entitlement/SGTasksError.swift" \
    "$entitlement/SGTasksWire.swift" \
    "$entitlement/SGTasksWireCodec.swift" \
    "$entitlement/SGTasksWireJSON.swift" \
    "$entitlement/SGTasksWireOperation.swift"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -D SGIAP_HOST_TESTS \
    -module-cache-path "$work/module-cache" \
    -I "$work" -L "$work" -lSGEntitlement \
    "$test_root/../Sources/SGIAPTrialLedger.swift" \
    "$test_root/TrialLedgerOriginTests.swift" \
    -o "$work/trial-ledger-tests"
"$work/trial-ledger-tests"
