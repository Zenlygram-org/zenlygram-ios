#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-apple-boundary-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$test_root/../Sources/SGIAPAppleBoundary.swift" \
    "$test_root/AppleBoundaryTests.swift" \
    -o "$test_temp/apple-boundary-tests"
"$test_temp/apple-boundary-tests"
