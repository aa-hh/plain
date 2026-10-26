#!/bin/sh
# Compile check. Use this instead of a bare `swift build`. Ported from
# AirPlay Controller's scripts/build.sh: the mule first when
# `git config audiout.testPrefer` says so, else here under a capacity permit.
# It answers "does this compile?" and copies nothing back; scripts/build-app.sh
# makes the runnable app.
#
# Usage: scripts/build.sh [swift-build args...]   e.g. scripts/build.sh -c release
# Env:   AUDIOUT_BUILD_LOCAL=1  skip the mule
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
. "$(cd "$(dirname "$0")" && pwd)/lib/runner.sh"

if [ "${AUDIOUT_BUILD_LOCAL:-0}" != 1 ] && remote_wins; then
    echo "  build: sending to $remote_host ..." >&2
    rrc=0
    remote_run "$repo_root" "swift build --disable-keychain$(remote_quote_args "$@")" || rrc=$?
    if [ "$rrc" -eq 0 ]; then
        echo "  build: compiled clean on $remote_host." >&2
        exit 0
    fi
    # A mule failure can be its disk or load, not the code: confirm here.
    echo "  build: falling back to this machine." >&2
fi

capacity_acquire build
swift build "$@"
