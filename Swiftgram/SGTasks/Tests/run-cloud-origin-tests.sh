#!/bin/sh
# Zenlygram — host tests for the Tasks cloud store's origin fence (`SGTasksCloudStoreFiles` alone, on
# real files in a temporary directory). macOS host only: no simulator, no Keychain, no network, no
# app data. The repository's use of the pre-origin root (explicit logout only) is covered by
# `run-cloud-tests.sh`.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources="$test_root/../Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-cloud-origin-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
target="$(uname -m)-apple-macos13.0"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -module-name SGTasksCloudOriginTests \
    -module-cache-path "$work/module-cache" \
    "$sources/SGTasksCloudStoreFiles.swift" \
    "$test_root/SGTasksCloudOriginFenceTests.swift" \
    -o "$work/cloud-origin-tests"

"$work/cloud-origin-tests"
