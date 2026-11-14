#!/bin/sh
# Zenlygram — the Tasks strings gate (wf15 FINAL SPEC §15.1, §15.4). macOS host only: no simulator, no
# network, no app data; python3 in isolated mode (-I) over text files.
#
# The gate (check_strings.py) scans every string literal inside each `var|func tasks_*` or `tab_tasks`
# declaration of Swiftgram/SGTasks/Sources/SGTasksL10n*.swift (a declaration ends at the next `var|func`
# declaration of the file, comments excluded) and the three `Tasks.Cloud.LogoutNotice` values of
# SGLocalizable.strings: it fails on a banned word (bulut, cloud, облак, облач, on this device,
# shu qurilmada, qurilma arxivi, device archive, на этом устройстве, архив устройства; any language),
# on an ASCII/curly apostrophe between letters in a uz value, on U+02BC after o/g and on U+02BB
# elsewhere. No key is skipped: the allow file of WP-I0 (no-cloud-word.allow, the retired keys of
# §15.3) went with those keys in WP-I10; the checker still accepts one and treats an absent file as
# empty, so the gate runs over every gated declaration. Rule (a) of §15.4
# (WP-I2b, F19): no string literal of any Swiftgram/SGTasks/Sources/*.swift names a cloud SF Symbol
# ("icloud", "icloud.slash", "exclamationmark.icloud", "cloud.fill", …); accessibility identifiers
# ("sgtasks.…") and reverse-DNS names ("uz.zenlygram.…") are not glyphs and pass.
#
# The self-test runs first and the gate counts as green only when its seven outcomes match: the real
# `settings_interface_unlimitedPins_subtitle` declaration next to clean `tasks_*` declarations passes;
# a `tasks_*` uz value with "shu qurilmada", a `tasks_*` uz value with an ASCII apostrophe between
# letters, a `tab_tasks` value with "Bulut" and a Swift file with the literal "icloud.slash" each fail;
# of the two `dump Tasks` trees (`*.tree.txt`, checked with the `dump` subcommand) the one whose only
# "cloud" is the kept a11y id `sgtasks.cloud.privacy` and a `<SGTasks.TasksCloudBoardNode: 0x…>`
# container description passes, the one with "Cloud" in a label and a value fails
# (Fixtures/check-strings-selftest/).
#
# Usage: check-strings.sh                     self-test, then the gate over the repository files
#        check-strings.sh --self-test         the self-test only
#        check-strings.sh --ui-dump <path>    self-test, gate, then the second check of §15.4 over the
#                                             accessibility trees an `ios-ui/run <udid> dump Tasks`
#                                             wrote (<path> = a *tree.txt file or an evidence directory)
#        check-strings.sh --ui-sim <udid>     like --ui-dump, but runs `ios-ui/run <udid> dump Tasks`
#                                             first (ZENLYPAY_REPO, default $HOME/zenlypay; the
#                                             trees land in ZG_EVIDENCE_DIR, default
#                                             ${ZP_LOCAL_ROOT:-$HOME/zenlypay-local}/ios-ui/evidence)
# Any other argument fails before anything runs. Exit 0 green, 1 red, 2 usage.
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checker="$test_root/check_strings.py"
fixtures="$test_root/Fixtures/check-strings-selftest"
python=${PYTHON3:-/usr/bin/python3}

mode="gate"
argument=""
case "$#" in
    0) ;;
    1)
        if [ "$1" = "--self-test" ]; then
            mode="self-test"
        else
            echo "usage: $0 [--self-test | --ui-dump <path> | --ui-sim <udid>]" >&2
            exit 2
        fi
        ;;
    2)
        case "$1" in
            --ui-dump) mode="ui-dump"; argument=$2 ;;
            --ui-sim) mode="ui-sim"; argument=$2 ;;
            *)
                echo "usage: $0 [--self-test | --ui-dump <path> | --ui-sim <udid>]" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "usage: $0 [--self-test | --ui-dump <path> | --ui-sim <udid>]" >&2
        exit 2
        ;;
esac

# expect <pass|fail> <fixture>: runs the checker over one fixture alone and compares the outcome.
selftest_failures=0
expect() {
    expected=$1
    fixture=$2
    if [ ! -f "$fixture" ]; then
        echo "self-test: missing fixture $fixture" >&2
        selftest_failures=$((selftest_failures + 1))
        return 0
    fi
    status=0
    case "$fixture" in
        *.tree.txt) subcommand="dump" ;;
        *) subcommand="fixture" ;;
    esac
    output=$("$python" -I "$checker" "$subcommand" "$fixture" 2>&1) || status=$?
    case "$expected:$status" in
        pass:0) echo "self-test: pass as expected   $(basename "$fixture")" ;;
        fail:1) echo "self-test: fail as expected   $(basename "$fixture")" ;;
        *)
            echo "self-test: UNEXPECTED (expected $expected, exit $status)   $(basename "$fixture")"
            printf '%s\n' "$output" | sed 's/^/    /'
            selftest_failures=$((selftest_failures + 1))
            ;;
    esac
}

expect pass "$fixtures/pass-neighbour-not-gated.swift"
expect fail "$fixtures/fail-uz-shu-qurilmada.swift"
expect fail "$fixtures/fail-uz-ascii-apostrophe.swift"
expect fail "$fixtures/fail-tab-tasks-bulut.swift"
expect fail "$fixtures/fail-symbol-icloud.swift"
expect pass "$fixtures/pass-dump-kept-identifier.tree.txt"
expect fail "$fixtures/fail-dump-visible-cloud.tree.txt"
if [ "$selftest_failures" -ne 0 ]; then
    echo "check-strings: self-test RED ($selftest_failures unexpected outcome(s)); the gate is not run."
    exit 1
fi
echo "check-strings: self-test green (7 of 7 outcomes)."
if [ "$mode" = "self-test" ]; then
    exit 0
fi

"$python" -I "$checker" gate
echo "check-strings: gate green."

case "$mode" in
    ui-dump)
        "$python" -I "$checker" dump "$argument"
        echo "check-strings: ui-dump green."
        ;;
    ui-sim)
        repo=${ZENLYPAY_REPO:-$HOME/zenlypay}
        evidence=${ZG_EVIDENCE_DIR:-${ZP_LOCAL_ROOT:-$HOME/zenlypay-local}/ios-ui/evidence}
        driver="$repo/tools/local-stack/ios-ui/run"
        if [ ! -x "$driver" ]; then
            echo "check-strings: no ios-ui driver at $driver" >&2
            exit 2
        fi
        result=$("$driver" "$argument" dump Tasks | tee /dev/stderr | sed -n 's/^RESULT //p' | tail -1)
        prefix=$(printf '%s' "$result" | "$python" -I -c 'import json, sys; print(json.load(sys.stdin).get("prefix", ""))')
        if [ -z "$prefix" ]; then
            echo "check-strings: the driver printed no RESULT prefix" >&2
            exit 2
        fi
        set -- "$evidence/$prefix".*tree.txt
        if [ ! -f "$1" ]; then
            echo "check-strings: no $evidence/$prefix.*tree.txt" >&2
            exit 2
        fi
        "$python" -I "$checker" dump "$@"
        echo "check-strings: ui-sim green."
        ;;
esac
