#!/usr/bin/env sh
# Judges whether a pull request worsens its repository's test pyramid.
#
# Every test case of the target branch (the merge base) and of the pull request is put in a tier --
# unit, integration, functional or e2e -- by rules fixed per language and the repository's own
# `.test-pyramid`, and the two suites are compared by the book: no tier may hold more test cases
# than every tier below it combined, and the suite stays within a reference mix, by default
# Software Engineering at Google's 80% unit, 15% integration, 5% functional and e2e. A pull request
# fails only for what it WORSENS, so a suite that already breaks a rule on the target branch does
# not hold every later pull request hostage. Static and deterministic: both trees are read with
# git, nothing is built, run or checked out, and every file's tier is written down with the rule
# that decided it.
#
# The policy -- blocking or advisory, the reference mix, path rules -- is read from the TARGET
# branch's `.test-pyramid`, so a pull request cannot loosen the rules it is judged by. Advisory by
# default: a worsened pyramid is reported and the job passes until that file says `blocking true`.
#
# Usage: run.sh [target-branch]
# Environment: TEST_PYRAMID_LANGUAGE (the templates set it), TEST_PYRAMID_TARGET, TEST_PYRAMID_BASE,
# TEST_PYRAMID_BLOCKING, REPORT_PATH; see internal/cli for each, and README.md, "Test Pyramid".
#
# Exit status: 0 the pull request keeps the pyramid, or worsens it under an advisory policy; 1 it
# worsens it under a blocking one; 2 the check could not run. The checker is Go, built from this
# checkout on every run (see global/scripts/shared/go-helper.sh); it needs Go 1.25 or newer and git.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(dirname "$(realpath "$0")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

if ! top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo 'test-pyramid: not inside a git repository' >&2
  exit 2
fi
cd "$top"

# A build failure of the checker returns 1 from go_helper_run, which this check's exit status means
# a worsened pyramid; a missing Go is a check that could not run.
if ! command -v go > /dev/null 2>&1; then
  echo 'test-pyramid: Go 1.25 or newer is required to run the checker (https://go.dev/dl/)' >&2
  exit 2
fi

REPORT_PATH="${REPORT_PATH:-}"
# shellcheck source=/dev/null
TOOL_NAME='test-pyramid' . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/tools/test-pyramid "$@"
