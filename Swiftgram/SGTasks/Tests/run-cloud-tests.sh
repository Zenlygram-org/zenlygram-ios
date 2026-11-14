#!/bin/sh
# Zenlygram — host tests for the Tasks cloud repository (storage, restart, privacy/purge, replay,
# snapshot staging, held-delete Undo, principal fence, explicit import, realtime hint controller) and
# its R4 engine (SGTasksCloudR4Tests.swift: fail-closed permission, batch drain, the whole-batch 422
# split and the one-time `batch_refusals_repaired` requeue, task.patch, automatic resolution and
# retry, consent fence and withdrawal, the post-gate traffic check (single sends, batches,
# snapshot/changes reads, both realtime calls), downgrade, analytics seam), and the R4 headless
# migration of the device rows with the account lifecycle calls, the new-store re-check
# (`migration_checked`) and the copy times checked against the first enqueue's server time
# (SGTasksMigrationTests.swift), which also runs the sync coordinator's cut-over read
# (SGTasksCutOver+Inputs.swift: the record, U and I1) through a logout purge and re-login against
# the real store. wf15 (SGTasksCloudR4Tests.swift, I4a): the assignment engine — assignTask on synced
# and unsynced tasks, the quick-add create + invite chain, the pick-time refusals and the pure pacer
# (SGTasksInvitationPacer.swift), the long-429 deferral and its automatic re-send, the auto-resolve
# rows for invite request / revoke, and the chained annotation clear; the pure board model
# (TasksCloudBoardModel.swift and the files it reads) is compiled in so a deferral can be checked
# against the logout paragraph's decision (`TasksLogoutNotice`). wf15 (SGTasksAutoAcceptTests.swift,
# I5a): the contact rule (D2) — the pure `SGTasksAutoAcceptPolicy` matrix, the durable manual answers
# (`SGTasksInviteAnswers`, kept in the harness's own UserDefaults suite), the automatic accept engine
# (`runAutoAccept`: only `invitation.respond accept` leaves the device, the reseal after
# revision_changed up to 3 attempts, the quiet drop of every other refusal without a row or notice,
# the contact added later, the refusal that survives a simulated last logout). The
# wf15 (SGTasksLegacyAssigneeOfferTests.swift, I6): the legacy assignee sheet (D4) — the pure
# candidates (`SGTasksLegacyAssigneeOffer`: mapped / unmapped / unconvertible / self / completed /
# live assignment / annotation-only / dedupe / order), the pacing plan and the paced send that skips
# only the minute counter, the durable sent set (a sent candidate never returns after a decline or a
# detach), the one-time offer for completed and skipped records, and the markers
# (`SGTasksLocalMarkers`) across a simulated non-last and last logout. The
# FIRST case runs before any permission is installed and proves the fail-closed default sends nothing; the runner
# then installs `.legacy` (exactly R3) for the R3 cases, and each R4 case installs `.allowed` itself.
# macOS host only: no simulator, no Keychain, no network, no app data. The scripted server in the
# test file stands in for the SGEntitlement Tasks facade; it proves repository behavior, not backend
# behavior. The realtime cases drive scripted sockets and a manual clock, never a WebSocket.
#
# The pure SGEntitlement core (the same Foundation/CryptoKit/Security source list as
# Swiftgram/SGEntitlement/Tests/run-policy-core-tests.sh, including the Tasks wire codec) is built
# as module `SGEntitlement`, so the cloud sources compile against its PUBLIC API exactly as in the
# app. `-D SGTASKS_HOST_TESTS` leaves out only the facade adapter (SGEntitlement.shared).
#
# Usage: run-cloud-tests.sh                  every case (legacy repository + realtime)
#        run-cloud-tests.sh --realtime-only  only the realtime repository and controller cases
# Any other argument fails before anything is created or compiled.
set -eu

mode=""
case "$#" in
    0) ;;
    1)
        if [ "$1" = "--realtime-only" ]; then
            mode="--realtime-only"
        else
            echo "usage: $0 [--realtime-only]" >&2
            exit 2
        fi
        ;;
    *)
        echo "usage: $0 [--realtime-only]" >&2
        exit 2
        ;;
esac

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources="$test_root/../Sources"
entitlement="$test_root/../../SGEntitlement/Sources"
work=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-cloud-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
target="$(uname -m)-apple-macos13.0"

# `-enable-testing`: the realtime cases drive the real Pusher socket through its internal WebSocket
# seam (`@testable import SGEntitlement` in SGTasksCloudRealtimeTests.swift only).
xcrun --sdk macosx swiftc -target "$target" -parse-as-library -enable-testing \
    -module-name SGEntitlement \
    -module-cache-path "$work/module-cache" \
    -emit-module -emit-module-path "$work/SGEntitlement.swiftmodule" \
    -emit-library -static -o "$work/libSGEntitlement.a" \
    "$entitlement/SGEntitlementAPI.swift" \
    "$entitlement/SGEntitlementAccountGate.swift" \
    "$entitlement/SGEntitlementAccountClaimsLedger.swift" \
    "$entitlement/SGEntitlementAppleProvenance.swift" \
    "$entitlement/SGEntitlementBinding.swift" \
    "$entitlement/SGEntitlementBackendOrigin.swift" \
    "$entitlement/SGEntitlementBoundedFetch.swift" \
    "$entitlement/SGEntitlementCapability.swift" \
    "$entitlement/SGEntitlementClaims.swift" \
    "$entitlement/SGEntitlementCrypto.swift" \
    "$entitlement/SGEntitlementEnforcement.swift" \
    "$entitlement/SGEntitlementEvaluator.swift" \
    "$entitlement/SGEntitlementFailure.swift" \
    "$entitlement/SGEntitlementLocalGrace.swift" \
    "$entitlement/SGEntitlementPinnedKeys.swift" \
    "$entitlement/SGEntitlementPolicy.swift" \
    "$entitlement/SGEntitlementState.swift" \
    "$entitlement/SGEntitlementTokenVerifier.swift" \
    "$entitlement/SGTasksError.swift" \
    "$entitlement/SGTasksWire.swift" \
    "$entitlement/SGTasksWireCodec.swift" \
    "$entitlement/SGTasksWireJSON.swift" \
    "$entitlement/SGTasksWireOperation.swift" \
    "$entitlement/SGTasksRealtimeWire.swift" \
    "$entitlement/SGTasksRealtimeSocket.swift"

xcrun --sdk macosx swiftc -target "$target" -parse-as-library -warnings-as-errors \
    -D SGTASKS_HOST_TESTS \
    -module-name SGTasksCloudTests \
    -module-cache-path "$work/module-cache" \
    -I "$work" -L "$work" -lSGEntitlement \
    -I "$test_root/SQLite" -lsqlite3 \
    "$sources/TodoStorage.swift" \
    "$sources/TodoDatabase.swift" \
    "$sources/SGTasksAnalytics.swift" \
    "$sources/SGTasksCloudModels.swift" \
    "$sources/SGTasksCloudStore.swift" \
    "$sources/SGTasksCloudStoreFiles.swift" \
    "$sources/SGTasksCloudOverlay.swift" \
    "$sources/SGTasksCloudTransport.swift" \
    "$sources/SGTasksCloudRepository.swift" \
    "$sources/SGTasksCloudOperations.swift" \
    "$sources/SGTasksCloudSync.swift" \
    "$sources/SGTasksCloudBatch.swift" \
    "$sources/SGTasksCloudAutoResolve.swift" \
    "$sources/SGTasksCloudImport.swift" \
    "$sources/SGTasksCloudRealtime.swift" \
    "$sources/SGTasksMigrationNormalizer.swift" \
    "$sources/SGTasksMigration.swift" \
    "$sources/SGTasksAccountLifecycle.swift" \
    "$sources/SGTasksCutOver.swift" \
    "$sources/SGTasksCutOver+Inputs.swift" \
    "$sources/SGTasksSyncPolicy.swift" \
    "$sources/SGTasksInvitationPacer.swift" \
    "$sources/SGTasksAutoAcceptPolicy.swift" \
    "$sources/SGTasksInviteAnswers.swift" \
    "$sources/SGTasksLocalMarkers.swift" \
    "$sources/SGTasksLegacyAssigneeOffer.swift" \
    "$sources/TasksCalendarModel.swift" \
    "$sources/TasksBoardModel.swift" \
    "$sources/TasksBoardSource.swift" \
    "$sources/TasksAssigneeDisplayState.swift" \
    "$sources/TasksCloudBoardModel.swift" \
    "$test_root/SGTasksCloudRealtimeTests.swift" \
    "$test_root/SGTasksCloudRepositoryTests.swift" \
    "$test_root/SGTasksCloudR4Tests.swift" \
    "$test_root/SGTasksAutoAcceptTests.swift" \
    "$test_root/SGTasksLegacyAssigneeOfferTests.swift" \
    "$test_root/SGTasksMigrationTests.swift" \
    -o "$work/cloud-tests"

if [ -n "$mode" ]; then
    "$work/cloud-tests" "$mode"
else
    "$work/cloud-tests"
fi
printf '\nHost SQLite is unencrypted platform SQLite; the scripted server is not the backend.\n'
