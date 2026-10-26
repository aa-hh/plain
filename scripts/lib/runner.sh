# Shared setup for scripts/run-tests.sh, build.sh, run-app.sh and build-app.sh.
# Sourced, not run.
#
# Loads ~/.claude/scripts/lib/remote.sh, the one copy of the mule logic and
# the capacity permits that every repo on this Mac shares (remote_wins,
# remote_run, remote_quote_args, capacity_acquire, capacity_release and the
# rest). A machine without it, such as a GitHub runner, gets stubs that keep
# every job local and uncapped, so the wrappers degrade to plain swift calls.

remote_toolchain=swift
runner_lib="${AUDIOUT_REMOTE_LIB:-$HOME/.claude/scripts/lib/remote.sh}"
if [ -f "$runner_lib" ]; then
    . "$runner_lib"
else
    remote_host=
    remote_pref=local
    remote_configured() { return 1; }
    remote_wins() { return 1; }
    remote_mule_free_count() { echo 0; }
    remote_quote_args() { for _a in "$@"; do printf " '%s'" "$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")"; done; }
    capacity_acquire() { capacity_slot_file=; }
    capacity_release() { :; }
    capacity_sweep() { :; }
fi
