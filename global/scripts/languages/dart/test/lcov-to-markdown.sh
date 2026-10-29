#!/usr/bin/env sh
#
# Render an LCOV tracefile as the Markdown coverage summary a pull request shows.
#
#   lcov-to-markdown.sh <lcov.info> <coverage.md>
#
# The JavaScript pipelines post a coverage table on every pull request through
# `vitest-coverage-report-action`, which reads the Istanbul JSON that Jest and
# Vitest emit. Dart emits LCOV and nothing else, and no LCOV comment action fits
# this library: the maintained ones shell out to an `lcov` binary a runner has
# to `apt-get` (which a self-hosted runner without sudo cannot), or run as a
# Docker container action (which a fleet without job-container support cannot
# start), and every one of them reads the RAW tracefile -- so it would count the
# generated sources `DART_COVERAGE_EXCLUDE` drops and paint a number the
# `DART_COVERAGE_MINIMUM` gate never saw. A comment that disagrees with the gate
# beside it sends whoever reads it looking for the discrepancy.
#
# So the runner renders the summary itself, from the same parse the Cobertura
# converter uses (`lcov.awk`), against the same exclusions and the same
# threshold. The output has two parts:
#
#   1. A totals table -- Lines always, Branches when the tracefile carries
#      `BRDA` rows. The threshold marker and the status icon follow the LINE
#      percentage, because that is the only figure the gate evaluates.
#
#   2. A collapsed per-file table for the source files the change TOUCHES, which
#      is what a reviewer wants to see on a pull request: the coverage of what
#      is being merged, not of the whole tree. `DART_COVERAGE_DIFF_BASE` names
#      the commit to diff against (the pull request's base SHA on GitHub);
#      empty omits the section, which is what a push build gets.
#
# This is a REPORT, never a gate. It exits 0 below the threshold -- the
# converter already fails the job for that -- and it exits 0 when the changed
# files cannot be listed, printing why instead of failing a green suite over a
# comment.

DART_TEST_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)" || exit 1
DART_DIR="$(dirname "$DART_TEST_DIR")"

if [ "$#" -lt 2 ]; then
  echo "Usage: lcov-to-markdown.sh <lcov.info> <coverage.md>" >&2
  exit 2
fi

if [ ! -f "$1" ] || [ ! -r "$1" ]; then
  printf "ERROR: no LCOV tracefile at '%s'.\n" "$1" >&2
  exit 1
fi

# LC_ALL=C makes awk work on bytes and print a `.` decimal point whatever the
# runner's locale; `common.awk` explains why the converters depend on both.
render() {
  LC_ALL=C awk -f "$DART_DIR/common.awk" -f "$DART_TEST_DIR/lcov.awk" -f "$DART_TEST_DIR/lcov-to-markdown.awk"
}

base="$(DART_MD_PHASE=base render < /dev/null)" || exit 1

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# A runner has no terminal, and a fetch that finds no credential must fail there
# and then rather than wait for a prompt nobody can answer: the deadline is the
# difference between a summary that says "unavailable" and a test job that
# hangs until its timeout kills it. GNU `timeout` reports a deadline as 124 and
# BusyBox's as 143; either is recorded the way the job log has always worded it.
git_step() {
  _gs_seconds="$1"
  _gs_name="$2"
  shift 2
  if command -v timeout > /dev/null 2>&1; then
    # Not the last command of the subshell, so no shell `exec`s it: the shell
    # that reports a deadline's signal is the one whose stderr is captured.
    (GIT_TERMINAL_PROMPT=0 timeout "$_gs_seconds" git "$@"; exit $?) > "$work/$_gs_name.out" 2> "$work/$_gs_name.err"
    _gs_status=$?
    if [ "$_gs_status" -eq 124 ] || [ "$_gs_status" -eq 143 ]; then
      printf 'git %s timed out after %s s' "$1" "$_gs_seconds" > "$work/$_gs_name.err"
      _gs_status=124
    fi
  else
    GIT_TERMINAL_PROMPT=0 git "$@" > "$work/$_gs_name.out" 2> "$work/$_gs_name.err"
    _gs_status=$?
  fi
  return "$_gs_status"
}

# Compared as two TREES (`git diff <base> HEAD`), not as a history, because a
# CI checkout is shallow: on a GitHub pull request `HEAD` is the merge commit of
# the change onto its base, fetched at depth 1, so the base's own tree is the one
# object missing. The single-commit fetch supplies it -- best effort by design:
# a fetch that fails (no remote, no network, a base already present) is
# followed by the diff regardless, whose own error is what gets reported.
#
# Diff paths are rooted at the REPOSITORY while the tracefile's are rooted at
# the package, and the two differ in a monorepo. `git rev-parse --show-prefix`
# is the package's path inside the repository; the renderer strips it, and drops
# a file outside the package -- it is not in this tracefile either way.
prefix_status=0
fetch_status=0
diff_status=0
if [ -n "$base" ]; then
  if ! command -v git > /dev/null 2>&1; then
    echo "ERROR: listing the files changed since the diff base needs 'git', which is not installed." >&2
    exit 1
  fi
  git_step 60 prefix rev-parse --show-prefix
  prefix_status=$?
  if [ "$prefix_status" -eq 0 ]; then
    git_step 180 fetch fetch --quiet --depth=1 --no-tags origin "$base"
    fetch_status=$?
    if [ "$fetch_status" -ne 124 ]; then
      git_step 60 diff diff --name-only --diff-filter=ACMR "$base" HEAD
      diff_status=$?
    fi
  fi
fi

# awk reads an output file named `-` as standard output; the summary was always
# a file of that name.
output="$2"
[ "$output" = "-" ] && output="./-"

DART_LCOV_CWD="$(pwd -P)" \
  DART_MD_PHASE=render \
  DART_MD_BASE="$base" \
  DART_MD_OUTPUT="$output" \
  DART_MD_OUTPUT_NAME="$2" \
  DART_MD_WORK="$work" \
  DART_MD_PREFIX_STATUS="$prefix_status" \
  DART_MD_FETCH_STATUS="$fetch_status" \
  DART_MD_DIFF_STATUS="$diff_status" \
  render < "$1"
status=$?

[ "$status" -le 1 ] || status=1
exit "$status"
