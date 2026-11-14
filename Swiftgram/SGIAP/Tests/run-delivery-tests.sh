#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-iap-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$test_root/../Sources/SGIAPDeliveryCoordinator.swift" \
    "$test_root/../Sources/SGIAPSnapshotRefreshState.swift" \
    "$test_root/../Sources/SGIAPDrainGate.swift" \
    "$test_root/DeliveryCoordinatorTests.swift" \
    -o "$test_temp/delivery-tests"
"$test_temp/delivery-tests"
