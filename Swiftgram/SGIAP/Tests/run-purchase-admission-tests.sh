#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-purchase-admission-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$test_root/../Sources/SGIAPPurchaseAdmission.swift" \
    "$test_root/PurchaseAdmissionTests.swift" \
    -o "$test_temp/purchase-admission-tests"
"$test_temp/purchase-admission-tests"
