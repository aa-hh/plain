# Which test targets go in which `swift test` process when the suite is split
# across several at once. Sourced, not run. Read by scripts/run-tests.sh (a
# full run on the mule, and `--shard N`) and, through `--shard N`, by the
# GitHub `tests` workflow, so the two always split the suite the same way.
#
# Shard 1 is EditorTextViewTests: the largest target (13 files), all of it
# main-actor AppKit text view work, so it gets a process of its own. Shard 2
# is the parser and the renderer. The last shard (3) has no list: it is every
# target not in the earlier lists (`--skip`), so a new test target always runs
# without an edit here.
#
# Each regex matches whole test targets at the start of XCTest's
# `Target.Class/test` identifier.

suite_shards_max=3

suite_shard_1="EditorTextViewTests"

suite_shard_2="MarkdownDocumentTests PreviewRendererTests"

# suite_shards_names <i>
# Print list i. Only lists 1 and 2 exist; anything else prints nothing.
suite_shards_names() {
    case $1 in
        1) printf '%s\n' "$suite_shard_1" ;;
        2) printf '%s\n' "$suite_shard_2" ;;
    esac
}

# suite_shards_args <i> <k>
# Set suite_shards_flag and suite_shards_regex for shard i of k: shard i < k
# runs `--filter` list i, shard k runs `--skip` lists 1..k-1. With k = 1 both
# are empty, which is a full run.
suite_shards_args() {
    suite_shards_flag=
    suite_shards_regex=
    [ "$2" -gt 1 ] || return 0
    if [ "$1" -lt "$2" ]; then
        suite_shards_flag=--filter
        _ss_names=$(suite_shards_names "$1")
    else
        suite_shards_flag=--skip
        _ss_names=
        _ss_i=1
        while [ "$_ss_i" -lt "$2" ]; do
            _ss_names="$_ss_names $(suite_shards_names "$_ss_i")"
            _ss_i=$((_ss_i + 1))
        done
    fi
    # $_ss_names is unquoted on purpose: word splitting turns the lists'
    # spaces into one name per line.
    # shellcheck disable=SC2086
    suite_shards_regex="^($(printf '%s\n' $_ss_names | paste -sd '|' -))\\."
}
