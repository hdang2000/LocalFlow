#!/bin/sh
# Runs the unit tests from a copy outside ~/Desktop: macOS privacy protection
# can stop the Swift macro plugins (swift-testing) from reading files there.
# The macro plugin also intermittently fails to load on a fresh compile with
# the Command Line Tools; that specific failure is retried once.
set -eu
src="$(cd "$(dirname "$0")/.." && pwd)"
work="${TMPDIR:-/tmp}/localflow-test"
mkdir -p "$work"
rsync -a --delete --exclude .build "$src/" "$work/src/"
cd "$work/src"
log="$work/test.log"
if swift test --scratch-path "$work/build" "$@" >"$log" 2>&1; then cat "$log"; exit 0; fi
if grep -q "plugin for module 'TestingMacros' not found" "$log"; then
  echo "(retrying: swift-testing macro plugin failed to load)" >&2
  exec swift test --scratch-path "$work/build" "$@"
fi
cat "$log"; exit 1
