#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-restore-claim-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$test_root/../Sources/SGIAPDeliveryCoordinator.swift" \
    "$test_root/../Sources/SGIAPRestoreClaim.swift" \
    "$test_root/RestoreClaimTests.swift" \
    -o "$test_temp/restore-claim-tests"
"$test_temp/restore-claim-tests"
