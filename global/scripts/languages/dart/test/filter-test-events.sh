#!/usr/bin/env sh
#
# Keep only the test events in a `dart test` / `flutter test` machine stream.
#
#   filter-test-events.sh <test-events.json> <test-results.json>
#
# `dart test --reporter json` and `flutter test --machine` both write the
# package:test JSON protocol to stdout, one object per line, and that stream is
# what the GitHub `Test Results` check reads through `dorny/test-reporter`'s
# `dart-json` parser -- which `JSON.parse`s EVERY non-empty line and fails the
# whole report on the first one it cannot.
#
# The stream is not clean. `flutter test` shares its stdout with pub's own
# progress when it resolves packages itself ("Resolving dependencies...", "Got
# dependencies!", the outdated-package summary -- ten lines on one real run),
# and flutter_tools emits its own machine events as JSON ARRAYS
# (`[{"event":"test.startedProcess",...}]`), which are not test events at all.
# `tojunit` tolerates both, so the JUnit report never showed the problem; the
# check run would have failed on line 1.
#
# This keeps exactly the lines that are JSON objects carrying a string `type`,
# which is the whole protocol, writes them verbatim, and reports what it dropped
# -- so a stream that turns out to be all noise is a warning in the log and no
# output file, rather than an empty check. The JSON is judged in awk
# (`filter-test-events.awk` says why not jq), so a Dart job needs nothing else.
# A report, never a gate: whatever the stream holds it exits 0, because the
# suite's own verdict was already recorded by the runner; only a missing file
# or a bad invocation is an error, and `run.sh` reports even that as a warning.

DART_TEST_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)" || exit 1
DART_DIR="$(dirname "$DART_TEST_DIR")"

if [ "$#" -lt 2 ]; then
  echo "Usage: filter-test-events.sh <test-events.json> <test-results.json>" >&2
  exit 2
fi

source="$1"
output="$2"
if [ ! -f "$source" ] || [ ! -r "$source" ]; then
  printf "ERROR: no event stream at '%s'.\n" "$source" >&2
  exit 1
fi

kept_file="$(mktemp)" || exit 1
trap 'rm -f "$kept_file"' EXIT
trap 'exit 1' HUP INT TERM

# LC_ALL=C makes awk work on bytes; `common.awk` explains why it depends on it.
counts="$(DART_EVENTS_KEPT_FILE="$kept_file" LC_ALL=C \
  awk -f "$DART_DIR/common.awk" -f "$DART_TEST_DIR/filter-test-events.awk" < "$source")" || exit 1
kept="${counts% *}"
dropped="${counts#* }"

# A stale file from an earlier run must not be read as this run's suite.
if [ -f "$output" ]; then
  rm -f -- "$output" || exit 1
fi

if [ "$kept" -eq 0 ]; then
  printf "WARNING: '%s' carries no test event (%s non-event line(s)); writing no '%s'.\n" \
    "$source" "$dropped" "$output" >&2
  exit 0
fi

mkdir -p -- "$(dirname -- "$output")" || exit 1
cat "$kept_file" > "$output" || exit 1
printf 'TEST_EVENTS_KEPT=%s (dropped %s non-event line(s))\n' "$kept" "$dropped"
exit 0
