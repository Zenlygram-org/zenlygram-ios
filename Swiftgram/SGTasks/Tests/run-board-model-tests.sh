#!/bin/sh
set -eu

# Host tests for the Tasks board's pure UI state (Sources/TasksBoardModel.swift) and its calendar
# day/undated projection (Sources/TasksCalendarModel.swift). The model needs
# the real TodoTask / TodoFolder types, so the storage sources are compiled in (against the platform
# SQLite shim in Tests/SQLite); the tests never open a database.

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_temp=$(mktemp -d "${TMPDIR:-/tmp}/zenlygram-board-model-tests.XXXXXX")
trap 'rm -rf "$test_temp"' EXIT HUP INT TERM

source_root="$test_root/../Sources"
xcrun swiftc -parse-as-library -warnings-as-errors \
    -profile-generate -profile-coverage-mapping \
    -module-cache-path "$test_temp/module-cache" \
    -I "$test_root/SQLite" -lsqlite3 \
    "$source_root/TodoStorage.swift" \
    "$source_root/TodoDatabase.swift" \
    "$source_root/TasksCalendarModel.swift" \
    "$source_root/TasksBoardModel.swift" \
    "$source_root/TasksTaskMetadata.swift" \
    "$test_root/TasksBoardModelTests.swift" \
    -o "$test_temp/board-model-tests"
LLVM_PROFILE_FILE="$test_temp/board-model.profraw" "$test_temp/board-model-tests"

xcrun llvm-profdata merge -sparse "$test_temp/board-model.profraw" -o "$test_temp/board-model.profdata"
printf '\nTasks board/date model coverage (UIKit views/controllers are not covered by host tests):\n'
xcrun llvm-cov report "$test_temp/board-model-tests" \
    -instr-profile="$test_temp/board-model.profdata" \
    "$source_root/TasksBoardModel.swift" "$source_root/TasksCalendarModel.swift" "$source_root/TasksTaskMetadata.swift"
