#!/bin/sh
# The test runner. Use this instead of a bare `swift test`. Ported from
# AirPlay Controller's scripts/run-tests.sh.
#
#   1. Every run takes a capacity permit from the pool every session on this
#      Mac and the mule shares (~/.claude/scripts/lib/remote.sh), and goes to
#      the mule first when `git config audiout.testPrefer` says so.
#   2. A pass cache (scripts/lib/suite-cache.sh) skips a run whose sources an
#      earlier pass already covered.
#   3. A full run on the mule builds once, then runs the suite as up to three
#      `swift test` processes at once, split by scripts/lib/suite-shards.sh.
#
# Usage:  scripts/run-tests.sh [swift-test args...]
#         scripts/run-tests.sh --shard N [swift-test args...]
#         scripts/run-tests.sh -c release --filter PerformanceTests
# Env:
#   AUDIOUT_TEST_SHARDS      most processes a full mule run fans out to (default 3)
#   AUDIOUT_TEST_MODE=serial pass --no-parallel (flake hunting only)
#   AUDIOUT_TEST_NO_CACHE=1  always run, never read or write the cache
#   AUDIOUT_TEST_LOG         where the last run's output goes
#                            (default /tmp/plain-suite-last.log)
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/runner.sh"
. "$here/lib/suite-shards.sh"
. "$here/lib/suite-cache.sh"

case "$(xcode-select -p 2>/dev/null || true)" in
    /Library/Developer/CommandLineTools*)
        echo "  suite: Command Line Tools is selected; 'swift test' needs Xcode." >&2
        echo "  Fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        exit 78 ;;
esac

case "${AUDIOUT_TEST_MODE:-parallel}" in
    serial) test_args=--no-parallel ;;
    *)      test_args=--parallel ;;
esac
suite_log=${AUDIOUT_TEST_LOG:-/tmp/plain-suite-last.log}

if [ "${1:-}" = "--shard" ]; then
    case "${2:-}" in ''|*[!0-9]*) n=0 ;; *) n=$2 ;; esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "$suite_shards_max" ]; then
        echo "  suite: --shard takes a number from 1 to $suite_shards_max." >&2
        exit 64
    fi
    shift 2
    suite_shards_args "$n" "$suite_shards_max"
    set -- "$suite_shards_flag" "$suite_shards_regex" "$@"
fi

key=$(suite_cache_source_hash "$repo_root")
if suite_cache_satisfied "$key" "$@"; then
    echo "  suite: sources unchanged since a passing run, skipping (AUDIOUT_TEST_NO_CACHE=1 to force)." >&2
    exit 0
fi
if [ "$suite_cache_kind" = suites ] && [ "$suite_cache_missing" != "$suite_cache_names" ]; then
    echo "  suite: already passed on these sources, skipping the rest of:$suite_cache_names" >&2
    set -- --filter "$(printf '%s' "$suite_cache_missing" | tr ' ' '|')"
fi

# Names failing tests from a swift test log (XCTest and Swift Testing lines).
failed_names() {
    tr -d '\r' < "$1" | sed -n \
        -e "s/^Test Case '-\[\([^]]*\)\]' failed.*/\1/p" \
        -e 's/.* Test \(.*\) failed after .*/\1/p' | grep -v '^run with ' || true
}

# True when a log names a failing test. remote.sh's own classifier reads only
# Swift Testing lines, and Plain's tests are XCTest, so this reads both.
xctest_failed() {
    [ -n "$(failed_names "$1")" ] || grep -q ': error: -\[' "$1"
}

# run_remote [args] -> 0 passed, 1 mule unusable (run here), 2 failed on the
# mule with no named test (re-run here), 3 failed with named tests (final).
run_remote() {
    echo "  suite: sending to $remote_host ..." >&2
    rargs="--disable-keychain $test_args"
    k=0
    shards=${AUDIOUT_TEST_SHARDS:-3}
    [ "$shards" -gt "$suite_shards_max" ] && shards=$suite_shards_max
    if [ $# -eq 0 ] && [ "$test_args" = --parallel ] && [ "$shards" -ge 2 ]; then
        k=$(remote_mule_free_count || echo 0)
        [ "$k" -gt "$shards" ] && k=$shards
    fi

    if [ "$k" -lt 2 ]; then
        rrc=0
        remote_run "$repo_root" "swift test $rargs$(remote_quote_args "$@")" 2>"$suite_log" || rrc=$?
        cat "$suite_log" >&2
        [ "$rrc" -eq 0 ] && return 0
        [ "$rrc" -eq 2 ] && xctest_failed "$suite_log" && return 3
        return "$rrc"
    fi

    echo "  suite: full run, building once on $remote_host, then $k test processes." >&2
    rrc=0
    remote_run "$repo_root" "swift build --build-tests --disable-keychain" || rrc=$?
    [ "$rrc" -ne 0 ] && return "$rrc"

    base="${suite_log%.log}.$$.shard"
    pids=
    i=1
    while [ "$i" -le "$k" ]; do
        (
            suite_shards_args "$i" "$k"
            src=0
            remote_run "$repo_root" "swift test $rargs --skip-build --ignore-lock$(remote_quote_args "$suite_shards_flag" "$suite_shards_regex")" \
                >"$base$i.log" 2>&1 || src=$?
            echo "$src ${remote_failure_kind:-}" >"$base$i.rc"
        ) &
        pids="$pids $!"
        i=$((i + 1))
    done
    for p in $pids; do wait "$p" || true; done

    : >"$suite_log"
    result=0
    i=1
    while [ "$i" -le "$k" ]; do
        read -r src kind <"$base$i.rc" || true
        echo "=== shard $i/$k ===" >>"$suite_log"
        cat "$base$i.log" >>"$suite_log"
        if [ "$src" -eq 0 ]; then
            echo "  suite: shard $i/$k passed." >&2
        else
            echo "  suite: shard $i/$k FAILED (exit $src${kind:+, $kind})." >&2
            if [ "$src" -eq 2 ] && xctest_failed "$base$i.log"; then result=3
            elif [ "$result" -ne 3 ]; then result=2; fi
        fi
        i=$((i + 1))
    done
    rm -f "$base"*.log "$base"*.rc
    [ "$result" -eq 2 ] && echo "  suite: a shard gave no verdict, re-running here." >&2
    return "$result"
}

if [ "${AUDIOUT_TEST_LOCAL:-0}" != 1 ] && remote_wins; then
    rrc=0
    run_remote "$@" || rrc=$?
    case $rrc in
        0) suite_cache_record "$key" "$@"
           echo "  suite: passed on $remote_host." >&2
           exit 0 ;;
        3) echo "  suite: FAILED on $remote_host. Output in $suite_log or above." >&2
           exit 1 ;;
        *) echo "  suite: falling back to this machine." >&2 ;;
    esac
fi

capacity_acquire suite
set +e
( set -o pipefail; swift test $test_args "$@" 2>&1 | tee "$suite_log" >&2 )
status=$?
set -e
capacity_release

if [ "$status" -eq 0 ]; then
    suite_cache_record "$key" "$@"
    echo "  suite: passed on this machine." >&2
else
    echo "  suite: FAILED, swift test exited $status." >&2
    names=$(failed_names "$suite_log")
    [ -n "$names" ] && echo "  suite: failed: $(printf '%s' "$names" | tr '\n' ' ')" >&2
    echo "  suite: full output in $suite_log" >&2
fi
exit "$status"
