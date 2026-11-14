#!/bin/sh
# Zenlygram — SGAccountCleanup host tests on the macOS SDK (no simulator, no Bazel).
#
# Covers the Foundation-only storage sweep (Sources/SGFeatureStorageCleanup.swift); SGAccountCleanup.swift
# itself needs UIKit and the app's modules and is compiled by Bazel only.
# 1. Builds SGAppGroupIdentifier (the system storage reads the app-group container).
# 2. Compiles SGFeatureStorageCleanup.swift + Tests/Support/*.swift + every Tests/*Tests.swift into one
#    executable and runs every suite. Convention (no central list to edit): `Tests/<Area>Tests.swift`
#    declares `enum <Area>Tests { static func run() async }`; this script generates the `@main` that awaits
#    each suite in file-name order.
# Nothing touches the real Keychain or defaults: the tests inject an in-memory store over temporary
# directories.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources="$test_root/../Sources"
swiftgram="$test_root/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-sgaccountcleanup-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

target="$(uname -m)-apple-macos10.15"

swiftc() {
    xcrun --sdk macosx swiftc -target "$target" -swift-version 5 -parse-as-library \
        -module-cache-path "$work/module-cache" "$@"
}

echo "== build SGAppGroupIdentifier"
swiftc -module-name SGAppGroupIdentifier \
    -emit-module -emit-module-path "$work/SGAppGroupIdentifier.swiftmodule" \
    -emit-library -static -o "$work/libSGAppGroupIdentifier.a" "$swiftgram"/SGAppGroupIdentifier/Sources/*.swift

echo "== run host tests"
suite_files=$(find "$test_root" -maxdepth 1 -name '*Tests.swift' | sort)
support_files=$(find "$test_root/Support" -name '*.swift' | sort)
main_file="$work/SGAccountCleanupTestsMain.swift"
{
    echo "@main"
    echo "enum SGAccountCleanupTestsMain {"
    echo "    static func main() async {"
    for suite in $suite_files; do
        echo "        await $(basename "$suite" .swift).run()"
    done
    echo "        print(\"SGAccountCleanup host tests: \\(sgCleanupTestChecks) checks passed in $(echo "$suite_files" | wc -l | tr -d ' ') suites\")"
    echo "    }"
    echo "}"
} > "$main_file"
# shellcheck disable=SC2086
swiftc -warnings-as-errors -I "$work" -L "$work" -lSGAppGroupIdentifier -module-name SGAccountCleanupHostTests \
    -o "$work/sgaccountcleanup-host-tests" \
    "$sources/SGFeatureStorageCleanup.swift" $support_files $suite_files "$main_file"
"$work/sgaccountcleanup-host-tests"
