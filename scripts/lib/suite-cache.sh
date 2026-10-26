# Pass cache for scripts/run-tests.sh. Sourced, not run.
#
# A pass is recorded as an empty stamp file named after a hash of the sources
# and what the run covered, so a later run over byte-identical sources can be
# skipped. A pass covers everything it contained:
#   no arguments (the full suite)      -> <src>.full
#   --filter A|B|C (plain names only)  -> <src>.suite.A, <src>.suite.B, ...
#   anything else                      -> <src>.<hash of the argument string>
# A .full stamp satisfies every later run. A plain-name filter is satisfied
# when every name has a stamp; when only some do, the caller narrows the
# filter to the rest.
#
# The stamps live in /tmp so every worktree and clone on this machine shares
# them. AUDIOUT_TEST_CACHE_DIR points them somewhere else. AUDIOUT_TEST_NO_CACHE=1
# turns off both reading and writing. (The AUDIOUT_ prefix is the shared
# runner's, ~/.claude/scripts/lib/remote.sh; one prefix for every knob.)

suite_cache_dir=${AUDIOUT_TEST_CACHE_DIR:-/tmp/plain-suite-cache}

# suite_cache_source_hash <repo_root>
# Hash what the suite's result depends on: every file under Sources and Tests
# (vendor resources included, since tests read them), the manifest and the
# resolved-versions file. Files on disk, not the git index, so it is right both
# before a commit and mid-edit.
suite_cache_source_hash() {
    _sc_root=$1
    {
        {
            find "$_sc_root/Sources" "$_sc_root/Tests" -type f ! -name '.DS_Store' \
                 -exec shasum -a 256 {} + 2>/dev/null
            shasum -a 256 "$_sc_root/Package.swift" "$_sc_root/Package.resolved" 2>/dev/null
        } | awk '{print $1}' | sort
    } | shasum -a 256 | awk '{print $1}'
}

# suite_cache_classify [swift-test args...]
# Sets suite_cache_kind to full, suites or other, and suite_cache_names to the
# space-separated names when the kind is suites.
suite_cache_classify() {
    suite_cache_names=
    if [ $# -eq 0 ]; then
        suite_cache_kind=full
        return
    fi
    suite_cache_kind=other
    [ $# -eq 2 ] && [ "$1" = "--filter" ] || return 0
    case $2 in *'
'*) return 0 ;; esac
    printf '%s\n' "$2" | grep -Eq '^[A-Za-z0-9_]+(\|[A-Za-z0-9_]+)*$' || return 0
    suite_cache_kind=suites
    suite_cache_names=$(printf '%s' "$2" | tr '|' ' ')
}

# Stamp name for an argument shape the cache cannot split into suites.
suite_cache_args_stamp() {
    printf '%s' "$*" | shasum -a 256 | awk '{print $1}'
}

# suite_cache_satisfied <src> [swift-test args...]
# Returns 0 when earlier passes on these sources already cover this run.
# Otherwise returns 1; for a plain-name filter, suite_cache_missing then holds
# the names that still need to run (all of them when nothing is stamped).
suite_cache_satisfied() {
    _sc_src=$1
    shift
    suite_cache_classify "$@"
    suite_cache_missing=$suite_cache_names
    [ "${AUDIOUT_TEST_NO_CACHE:-0}" = "1" ] && return 1
    [ -f "$suite_cache_dir/$_sc_src.full" ] && return 0
    case $suite_cache_kind in
        full)
            return 1
            ;;
        other)
            [ -f "$suite_cache_dir/$_sc_src.$(suite_cache_args_stamp "$@")" ]
            return
            ;;
    esac
    suite_cache_missing=
    for _sc_n in $suite_cache_names; do
        [ -f "$suite_cache_dir/$_sc_src.suite.$_sc_n" ] ||
            suite_cache_missing="$suite_cache_missing${suite_cache_missing:+ }$_sc_n"
    done
    [ -z "$suite_cache_missing" ]
}

# suite_cache_record <src> [swift-test args...]
# Write the stamps for a run that just passed with exactly these arguments.
suite_cache_record() {
    [ "${AUDIOUT_TEST_NO_CACHE:-0}" = "1" ] && return 0
    _sc_src=$1
    shift
    suite_cache_classify "$@"
    mkdir -p "$suite_cache_dir"
    case $suite_cache_kind in
        full)  : > "$suite_cache_dir/$_sc_src.full" ;;
        other) : > "$suite_cache_dir/$_sc_src.$(suite_cache_args_stamp "$@")" ;;
        suites)
            for _sc_n in $suite_cache_names; do
                : > "$suite_cache_dir/$_sc_src.suite.$_sc_n"
            done
            ;;
    esac
}
