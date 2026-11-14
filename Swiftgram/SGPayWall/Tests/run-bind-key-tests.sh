#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
entitlement_sources="$test_root/../../SGEntitlement/Sources"
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-bind-key-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$entitlement_sources/SGEntitlementCrypto.swift" \
    "$entitlement_sources/SGEntitlementDeviceProof.swift" \
    "$test_root/../Sources/SGLinkAccountLifecycle.swift" \
    "$test_root/BindKeyChangeTests.swift" \
    -o "$test_temp/bind-key-tests"
"$test_temp/bind-key-tests"
