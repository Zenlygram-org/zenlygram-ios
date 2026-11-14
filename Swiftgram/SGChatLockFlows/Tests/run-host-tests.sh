#!/bin/sh
# Zenlygram — Chat Lock Center: host tests of the pure decision layer (wf14-chatlock spec §7 #1–#10).
# Pattern: Swiftgram/SGPayWall/Tests/run-status-tests.sh — plain `swiftc`, no Bazel, no simulator.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-chatlock-flow-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -warnings-as-errors \
    -module-cache-path "$test_temp/module-cache" \
    "$test_root/../Sources/SGChatLockFlowSpec.swift" \
    "$test_root/../Sources/SGChatLockCenterCopy.swift" \
    "$test_root/SGChatLockFlowSpecTests.swift" \
    -o "$test_temp/chatlock-flow-spec-tests"
"$test_temp/chatlock-flow-spec-tests"
