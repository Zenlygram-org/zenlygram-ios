#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-storage-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

# Optional pre-change source directory for compile-time RED evidence. No app data is used.
source_root=${TODO_DATABASE_SOURCES:-"$test_root/../Sources"}
xcrun swiftc -parse-as-library -warnings-as-errors \
    -profile-generate -profile-coverage-mapping \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_root/SQLite" -lsqlite3 \
    "$source_root/TodoStorage.swift" \
    "$source_root/TodoDatabase.swift" \
    "$test_root/TodoDatabaseTests.swift" \
    -o "$test_temp/storage-tests"
LLVM_PROFILE_FILE="$test_temp/storage.profraw" "$test_temp/storage-tests"

# Set this to a fresh /tmp directory to retain machine-readable coverage after the run.
coverage_dir=${TODO_STORAGE_COVERAGE_DIR:-"$test_temp/coverage"}
mkdir -p "$coverage_dir"
xcrun llvm-profdata merge -sparse "$test_temp/storage.profraw" -o "$coverage_dir/storage.profdata"
xcrun llvm-cov export "$test_temp/storage-tests" \
    -instr-profile="$coverage_dir/storage.profdata" > "$coverage_dir/storage.json"

printf '\nStorage source coverage (includes legacy APIs and static facade):\n'
xcrun llvm-cov report "$test_temp/storage-tests" \
    -instr-profile="$coverage_dir/storage.profdata" \
    "$source_root/TodoDatabase.swift" "$source_root/TodoStorage.swift"
printf '\nNew transactional database APIs only (including their closures):\n'
xcrun llvm-cov report "$test_temp/storage-tests" \
    -instr-profile="$coverage_dir/storage.profdata" -show-functions \
    -Xdemangler="$(xcrun --find swift-demangle)" -Xdemangler=--compact \
    -name-regex='createQuickTask|createFolder|renameTask|setTaskCompleted|deleteTaskForUndo|restoreDeletedTask' \
    "$source_root/TodoDatabase.swift"
printf '\nR4 (v5) owner marker, migration record and mapping lifecycle APIs, and the write fence:\n'
xcrun llvm-cov report "$test_temp/storage-tests" \
    -instr-profile="$coverage_dir/storage.profdata" -show-functions \
    -Xdemangler="$(xcrun --find swift-demangle)" -Xdemangler=--compact \
    -name-regex='CloudDevice|CloudMigrationRecord|migrationRecordRow|writeMigrationRecord|ownerRow|CloudImportMapping|unmappedLiveRowCount|markImportReverified|updateFolderTitle|removeFolder|checkWriteFence|writeFence' \
    "$source_root/TodoDatabase.swift" "$source_root/TodoStorage.swift"
printf '\nHost tests use platform SQLite, not SQLCipher encryption. No SGTasks/UI-wide coverage claim.\n'
