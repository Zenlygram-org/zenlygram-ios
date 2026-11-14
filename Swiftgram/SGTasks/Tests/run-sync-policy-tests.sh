#!/bin/sh
# Zenlygram — host tests for the Tasks sync coordinator's pure decisions (Sources/SGTasksSyncPolicy.swift)
# and the cut-over table (Sources/SGTasksCutOver.swift), design 30 §5.1, §5.8, §7.5, with the device
# archive's banner for a cut-over (Sources/TasksBoardSource.swift, which also declares the one-board
# resolver, on the board model types of TasksBoardModel.swift / TasksCalendarModel.swift and the cloud
# read-only reason of TasksCloudBoardModel.swift). The coordinator itself (SGTasksSyncCoordinator.swift:
# UIKit, Network, SGCustomerSyncCore) is production only and never compiled here; what it reads for the
# cut-over (SGTasksCutOver+Inputs.swift) needs the repository and runs in run-cloud-tests.sh. The
# permission type comes from SGTasksCloudModels.swift, which needs the pure SGEntitlement core (the
# source list of run-cloud-model-tests.sh, built as module `SGEntitlement`) and the storage sources
# (against the platform SQLite shim in Tests/SQLite; no database is opened).
# macOS host only: no simulator, no network.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root="$test_root/../Sources"
entitlement_root="$test_root/../../SGEntitlement/Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-sync-policy-tests.XXXXXX")
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
    "$source_root/SGTasksCloudModels.swift" \
    "$source_root/SGTasksCutOver.swift" \
    "$source_root/SGTasksSyncPolicy.swift" \
    "$source_root/TasksCalendarModel.swift" \
    "$source_root/TasksBoardModel.swift" \
    "$source_root/TasksAssigneeDisplayState.swift" \
    "$source_root/TasksCloudBoardModel.swift" \
    "$source_root/TasksBoardSource.swift" \
    "$test_root/SGTasksCutOverTests.swift" \
    "$test_root/SGTasksSyncPolicyTests.swift" \
    -o "$work/sync-policy-tests"
LLVM_PROFILE_FILE="$work/sync-policy.profraw" "$work/sync-policy-tests"

xcrun llvm-profdata merge -sparse "$work/sync-policy.profraw" -o "$work/sync-policy.profdata"
printf '\nSync policy and cut-over coverage:\n'
xcrun llvm-cov report "$work/sync-policy-tests" \
    -instr-profile="$work/sync-policy.profdata" \
    "$source_root/SGTasksSyncPolicy.swift" "$source_root/SGTasksCutOver.swift"
