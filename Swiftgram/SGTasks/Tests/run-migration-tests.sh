#!/bin/sh
# Zenlygram — host tests for the R4 migration normalizer (Sources/SGTasksMigrationNormalizer.swift,
# design 30 §7.1) against the vendored vectors Fixtures/tasks-r4-vectors.json (a verbatim copy of
# the backend's tests/Fixtures/tasks-r4/vectors.json). The real wire types come from the pure
# SGEntitlement core (the source list of run-cloud-model-tests.sh), built as module `SGEntitlement`;
# the storage sources are compiled in for TodoTask / TodoCloudImportFolder (against the platform
# SQLite shim in Tests/SQLite) and no database is opened. The headless migration itself runs in
# run-cloud-tests.sh (SGTasksMigrationTests.swift). macOS host only: no simulator, no network.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root="$test_root/../Sources"
entitlement_root="$test_root/../../SGEntitlement/Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-migration-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
target="$(uname -m)-apple-macos13.0"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$work/libSGEntitlement.a" \
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
    "$entitlement_root/SGTasksWireOperation.swift" \
    -module-name SGEntitlement

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -profile-generate -profile-coverage-mapping \
    -module-cache-path "$work/module-cache" \
    -I "$test_root/SQLite" -lsqlite3 \
    -I "$work" -L "$work" -lSGEntitlement \
    "$source_root/TodoStorage.swift" \
    "$source_root/TodoDatabase.swift" \
    "$source_root/SGTasksMigrationNormalizer.swift" \
    "$test_root/SGTasksMigrationNormalizerTests.swift" \
    -o "$work/migration-tests"
LLVM_PROFILE_FILE="$work/migration.profraw" "$work/migration-tests" "$test_root/Fixtures/tasks-r4-vectors.json"

xcrun llvm-profdata merge -sparse "$work/migration.profraw" -o "$work/migration.profdata"
printf '\nMigration normalizer coverage:\n'
xcrun llvm-cov report "$work/migration-tests" \
    -instr-profile="$work/migration.profdata" \
    "$source_root/SGTasksMigrationNormalizer.swift"
