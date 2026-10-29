#!/usr/bin/env sh
#
# Convert an LCOV tracefile into a Cobertura XML report.
#
#   lcov-to-cobertura.sh <lcov.info> <cobertura.xml> [sources-root]
#
# Dart and Flutter emit coverage as LCOV and nothing else: `flutter test
# --coverage` writes `coverage/lcov.info`, and `package:coverage`'s
# `format_coverage --lcov` produces the same shape for pure Dart packages. Two of
# the three platforms this repository targets cannot read that format -- Azure
# DevOps' `PublishCodeCoverageResults@2` takes Cobertura or JaCoCo, and GitLab
# CI's coverage visualisation takes Cobertura -- so something has to convert it.
#
# This is that converter, written in POSIX sh and awk rather than installed: the
# published one (`lcov_cobertura`) is a pip package, which means a Python
# toolchain, a virtualenv and a network round-trip on a runner that otherwise
# needs none of them -- and an offline `make test` could not exercise it. sh and
# awk are on every runner already. The parse, the `DART_COVERAGE_EXCLUDE` rules
# and the threshold reading live in `lcov.awk`, shared with
# `lcov-to-markdown.sh`; the document is written by `lcov-to-cobertura.awk`.
#
# Prints `COVERAGE_EXCLUDED=...` (when DART_COVERAGE_EXCLUDE is set) and then
# `COVERAGE_PERCENT=...`, whose exact spelling the GitLab templates scrape.
# Exits 1 when coverage is below DART_COVERAGE_MINIMUM, 2 on a bad invocation.

DART_TEST_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)" || exit 1
DART_DIR="$(dirname "$DART_TEST_DIR")"

if [ "$#" -lt 2 ]; then
  echo "Usage: lcov-to-cobertura.sh <lcov.info> <cobertura.xml> [sources-root]" >&2
  exit 2
fi

if [ ! -f "$1" ] || [ ! -r "$1" ]; then
  printf "ERROR: no LCOV tracefile at '%s'.\n" "$1" >&2
  exit 1
fi

# awk reads an output file named `-` as standard output; the report was always a
# file of that name.
output="$2"
[ "$output" = "-" ] && output="./-"

# LC_ALL=C makes awk work on bytes and print a `.` decimal point whatever the
# runner's locale; `common.awk` explains why the converters depend on both.
DART_LCOV_CWD="$(pwd -P)" \
  DART_COBERTURA_OUTPUT="$output" \
  DART_COBERTURA_SOURCES="${3-.}" \
  DART_COBERTURA_TIMESTAMP="$(date +%s)" \
  LC_ALL=C awk -f "$DART_DIR/common.awk" -f "$DART_TEST_DIR/lcov.awk" -f "$DART_TEST_DIR/lcov-to-cobertura.awk" < "$1"
status=$?

# 0 and 1 are the converter's own verdicts; anything else is awk failing, which
# is a failure of the job, never a bad invocation.
[ "$status" -le 1 ] || status=1
exit "$status"
