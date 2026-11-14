#!/bin/sh
set -eu

# Host tests for the Cloud Tasks board's pure UI state (Sources/TasksCloudBoardModel.swift) and the
# one-board resolver with the device archive's banner model and the scope-key cleanup
# (Sources/TasksBoardSource.swift; TasksBoardSourceTests run from the same executable). They run
# against the real repository value
# types (SGTasksCloudModels.swift, which references the local storage's import snapshot type, so the
# storage sources are compiled in against the platform SQLite shim). The real wire types come from
# a separately compiled SGEntitlement module using the pure core source list from
# SGEntitlement/Tests/run-policy-core-tests.sh. No database is opened; nothing reads the Keychain,
# UIKit or the network.

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-cloud-model-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

source_root="$test_root/../Sources"
entitlement_root="$test_root/../../SGEntitlement/Sources"
target="$(uname -m)-apple-macos13.0"
xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -module-cache-path "$test_temp/module-cache" \
    -emit-module -emit-module-path "$test_temp/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$test_temp/libSGEntitlement.a" \
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

xcrun --sdk macosx swiftc -target "$target" -parse-as-library \
    -profile-generate -profile-coverage-mapping \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_root/SQLite" -lsqlite3 \
    -I "$test_temp" -L "$test_temp" -lSGEntitlement \
    "$source_root/TodoStorage.swift" \
    "$source_root/TodoDatabase.swift" \
    "$source_root/TasksCalendarModel.swift" \
    "$source_root/TasksBoardModel.swift" \
    "$source_root/TasksBoardSource.swift" \
    "$source_root/SGTasksCloudModels.swift" \
    "$source_root/SGTasksCutOver.swift" \
    "$source_root/TasksAssigneeDisplayState.swift" \
    "$source_root/TasksCloudBoardModel.swift" \
    "$test_root/TasksCloudBoardModelTests.swift" \
    "$test_root/TasksBoardSourceTests.swift" \
    -o "$test_temp/cloud-model-tests"
LLVM_PROFILE_FILE="$test_temp/cloud-model.profraw" "$test_temp/cloud-model-tests"

xcrun llvm-profdata merge -sparse "$test_temp/cloud-model.profraw" -o "$test_temp/cloud-model.profdata"
printf '\nCloud board model coverage (UIKit nodes/controllers are not covered by host tests):\n'
xcrun llvm-cov report "$test_temp/cloud-model-tests" \
    -instr-profile="$test_temp/cloud-model.profdata" \
    "$source_root/TasksCloudBoardModel.swift" "$source_root/TasksCalendarModel.swift" "$source_root/TasksBoardSource.swift" "$source_root/TasksAssigneeDisplayState.swift"
