#!/bin/sh
# Launch Plain with `swift run` under a local capacity permit held for the
# app's whole life. Use this instead of a bare `swift run`.
#
# Usage: scripts/run-app.sh [args passed to Plain...]
set -eu

repo_root=$(git rev-parse --show-toplevel)
. "$(cd "$(dirname "$0")" && pwd)/lib/runner.sh"

capacity_acquire run-app
# exec keeps this pid, so the permit file still names the running app and is
# reclaimed when it quits.
exec swift run --package-path "$repo_root" Plain "$@"
